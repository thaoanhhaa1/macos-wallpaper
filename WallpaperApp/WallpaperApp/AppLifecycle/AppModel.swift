import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    private let settingsStore: SettingsStore
    private let displayCoordinator: DisplayCoordinator
    private let importer = MediaImporter()

    var settings: AppSettings {
        didSet {
            guard oldValue != settings else { return }
            settingsStore.save(settings)

            if oldValue.playback != settings.playback {
                playback.apply(settings.playback)
            }
            if oldValue.playback != settings.playback || oldValue.displayMode != settings.displayMode {
                wallpaper.update(settings: settings.playback, displayMode: settings.displayMode)
            }

            Log.settings.info("Settings updated schema=\(self.settings.schemaVersion, privacy: .public)")
        }
    }

    let playback = PlaybackEngine()
    let wallpaper = WallpaperSurfaceController()

    var selectedMedia: MediaReference?
    private(set) var selectedMediaURL: URL?
    private(set) var mediaMetadata: MediaMetadata?
    private(set) var importState: MediaImportState = .idle
    private(set) var displays: [DisplayInfo]
    private(set) var missingWallpaper: MissingWallpaper?
    private(set) var isRestoringWallpaper = false

    let diagnostics: AppDiagnostics
    var surfaceStrategy: WallpaperSurfaceStrategy { wallpaper.strategy }

    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var activeMediaResource: SecurityScopedMedia?
    @ObservationIgnored private var hasAttemptedStartupRestore = false

    init(
        settingsStore: SettingsStore = SettingsStore(),
        displayCoordinator: DisplayCoordinator? = nil
    ) {
        let coordinator = displayCoordinator ?? DisplayCoordinator()
        self.settingsStore = settingsStore
        self.displayCoordinator = coordinator
        settings = settingsStore.load()
        displays = coordinator.currentDisplays()
        diagnostics = AppDiagnostics.snapshot()

        if let issue = settings.wallpaper.restoreIssue {
            missingWallpaper = MissingWallpaper(issue: issue)
        }

        playback.apply(settings.playback)

        coordinator.onChange = { [weak self] displays in
            self?.displays = displays
            self?.wallpaper.handleDisplayChange(displayMode: self?.settings.displayMode ?? .mainScreen)
        }
        coordinator.start()

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.playback.teardown()
                self?.wallpaper.shutdown()
                self?.activeMediaResource?.stopAccessing()
            }
        }

        Task { [weak self] in
            await self?.restorePersistedWallpaper()
        }

        Log.app.notice(
            "App model ready displays=\(self.displays.count, privacy: .public) schema=\(self.settings.schemaVersion, privacy: .public) restoreIssue=\(self.settings.wallpaper.restoreIssue != nil, privacy: .public)"
        )
    }

    var playbackState: PlaybackState { playback.state }
    var isPlaying: Bool { playback.isPlaying }
    var hasMedia: Bool { selectedMedia != nil }
    var hasLastWallpaper: Bool { settings.wallpaper.last != nil }
    var lastWallpaperName: String? { settings.wallpaper.last?.media.displayName }
    var persistedDisplayConfigurationCount: Int { settings.displayConfigurations.count }
    var isWallpaperPlaying: Bool { wallpaper.isActive && !wallpaper.isPaused }
    var effectiveIsPlaying: Bool { wallpaper.isActive ? isWallpaperPlaying : isPlaying }

    var status: WallpaperStatus {
        if let missingWallpaper {
            return .error(missingWallpaper.reason)
        }
        if let failure = wallpaper.state.failureReason {
            return .error(failure)
        }
        if wallpaper.isActive {
            return wallpaper.isPaused ? .paused : .playing
        }
        if let failure = playback.state.failureReason {
            return .error(failure)
        }

        guard selectedMedia != nil else {
            if case .failed(let message) = importState {
                return .error(message)
            }
            return .noWallpaper
        }

        switch playback.state {
        case .playing:
            return .playing
        case .paused, .preparing:
            return .paused
        case .failed(let reason):
            return .error(reason)
        case .idle:
            return .paused
        }
    }

    var statusDetail: String {
        if let missingWallpaper {
            return missingWallpaper.reason
        }
        if isRestoringWallpaper {
            return "Restoring the saved wallpaper…"
        }
        if let failure = wallpaper.state.failureReason {
            return failure
        }
        if wallpaper.isActive {
            let count = wallpaper.surfaceCount
            let suffix = count == 1 ? "" : "s"
            if wallpaper.isPaused {
                return "Video wallpaper is applied to \(count) display\(suffix) and paused."
            }
            return "Video wallpaper is playing on \(count) display\(suffix)."
        }
        if case .failed = playback.state, selectedMedia != nil {
            return playback.state.failureReason ?? "Playback failed."
        }

        switch status {
        case .noWallpaper:
            return "Choose a video in Settings to create a wallpaper."
        case .playing:
            return "Your video wallpaper is playing."
        case .paused:
            return "Playback is paused."
        case .error(let message):
            return message
        }
    }

    var resourcePolicy: ResourcePolicy {
        ResourcePolicy(playback: settings.playback)
    }

    var developmentFixtureURL: URL? {
        DevelopmentFixture.bundleURL
    }

    func chooseVideo() async {
        guard let url = importer.presentOpenPanel() else { return }
        await openVideo(at: url)
    }

    func openVideo(at url: URL) async {
        importState = .importing
        Log.media.notice("Import started for \(url.lastPathComponent, privacy: .public)")

        do {
            let imported = try await importer.importVideo(at: url)
            let selection = try await activateMedia(
                reference: imported.reference,
                metadata: imported.metadata
            )
            try playback.load(
                url: selection.url,
                duration: selection.metadata.duration,
                settings: settings.playback,
                autoplay: true
            )
            selectedMedia = selection.reference
            selectedMediaURL = selection.url
            mediaMetadata = selection.metadata
            importState = .idle
            Log.media.notice(
                "Import ready for \(selection.reference.displayName, privacy: .public) duration=\(selection.metadata.duration, privacy: .public)"
            )
        } catch {
            importState = .failed(error.localizedDescription)
            Log.media.error(
                "Import failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func relinkMissingVideo() async {
        guard let missingWallpaper else { return }
        guard let url = importer.presentOpenPanel() else { return }
        await relinkMissingVideo(at: url, issue: missingWallpaper)
    }

    func relinkMissingVideo(at url: URL, issue: MissingWallpaper) async {
        importState = .importing
        Log.persistence.notice(
            "Relinking missing wallpaper \(issue.displayName, privacy: .public) with \(url.lastPathComponent, privacy: .public)"
        )

        do {
            let imported = try await importer.importVideo(at: url)
            let selection = try await activateMedia(
                reference: imported.reference,
                metadata: imported.metadata
            )
            try playback.load(
                url: selection.url,
                duration: selection.metadata.duration,
                settings: settings.playback,
                autoplay: false
            )
            selectedMedia = selection.reference
            selectedMediaURL = selection.url
            mediaMetadata = selection.metadata

            let assignment = WallpaperAssignment(
                media: selection.reference,
                displayMode: issue.displayMode
            )
            try performApply(assignment: assignment, url: selection.url)

            settings.wallpaper.active = assignment
            settings.wallpaper.last = assignment
            settings.wallpaper.restoreIssue = nil
            missingWallpaper = nil
            importState = .idle
            Log.persistence.notice(
                "Relinked wallpaper \(assignment.media.displayName, privacy: .public)"
            )
        } catch {
            importState = .failed(error.localizedDescription)
            Log.persistence.error(
                "Relink failed for \(issue.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func useDevelopmentFixture() async {
        guard let url = developmentFixtureURL else { return }
        await openVideo(at: url)
    }

    func play() {
        playback.play()
    }

    func pause() {
        playback.pause()
    }

    func togglePlayPause() {
        playback.togglePlayPause()
    }

    func toggleMute() {
        settings.playback.isMuted.toggle()
    }

    func toggleEffectivePlayback() {
        if wallpaper.isActive {
            wallpaper.togglePlayback()
        } else {
            playback.togglePlayPause()
        }
    }

    func applyWallpaper() {
        guard let reference = selectedMedia, let url = selectedMediaURL else { return }
        let assignment = WallpaperAssignment(media: reference, displayMode: settings.displayMode)

        do {
            try performApply(assignment: assignment, url: url)
            settings.wallpaper.active = assignment
            settings.wallpaper.last = assignment
            settings.wallpaper.restoreIssue = nil
            missingWallpaper = nil
            Log.surface.notice(
                "Applied wallpaper \(assignment.media.displayName, privacy: .public) mode=\(assignment.displayMode.rawValue, privacy: .public)"
            )
        } catch {
            settings.wallpaper.active = nil
            Log.surface.error(
                "Apply failed for \(assignment.media.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func removeWallpaper() {
        wallpaper.remove()
        settings.wallpaper.active = nil
        settings.wallpaper.restoreIssue = nil
        missingWallpaper = nil
        Log.surface.notice("Removed wallpaper; the desktop picture is visible again")
    }

    func restoreLastWallpaper() async {
        guard let assignment = settings.wallpaper.last else { return }
        await restore(assignment: assignment, reason: "Restore Last Wallpaper")
    }

    func seek(to seconds: Double) {
        playback.seek(to: seconds)
    }

    func restart() {
        playback.seek(to: 0)
    }

    func revealDevelopmentFixture() {
        guard let url = developmentFixtureURL else { return }
        Log.media.notice("Revealing development fixture \(url.lastPathComponent, privacy: .public)")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyDiagnostics() {
        let displaySummary = displays
            .map { "\($0.name) \($0.summary)\($0.isMain ? " [main]" : "")" }
            .joined(separator: "\n")

        let mediaSummary = selectedMedia.map {
            "\($0.displayName) (\(mediaMetadata?.summary ?? "metadata unavailable"))"
        } ?? "none"

        let persistenceSummary = """
        active=\(settings.wallpaper.active?.media.displayName ?? "none")
        last=\(settings.wallpaper.last?.media.displayName ?? "none")
        restoreIssue=\(missingWallpaper?.reason ?? "none")
        bookmarkBytes=\(selectedMedia?.bookmarkData.count ?? 0)
        displayConfigurations=\(settings.displayConfigurations.count)
        """

        let report = """
        \(diagnostics.report)
        Displays:
        \(displaySummary.isEmpty ? "none" : displaySummary)
        Settings schema: \(settings.schemaVersion)
        Surface strategy: \(surfaceStrategy.title)
        Resource policy: \(resourcePolicy.summary)
        Media: \(mediaSummary)
        Playback: \(playbackState.title)
        Wallpaper: \(wallpaper.state.title) surfaces=\(wallpaper.surfaceCount) paused=\(wallpaper.isPaused)
        Wallpaper media: \(wallpaper.appliedMediaName ?? "none")
        Persistence:
        \(persistenceSummary)
        Surface windows: \(wallpaper.surfaceWindowNumbers.map(String.init).joined(separator: ", "))
        Import state: \(importState.diagnosticSummary)
        """

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report, forType: .string)
        Log.diagnostics.notice("Copied diagnostics report")
    }

    private func restorePersistedWallpaper() async {
        guard !hasAttemptedStartupRestore else { return }
        hasAttemptedStartupRestore = true

        guard missingWallpaper == nil else {
            Log.persistence.notice("Startup restore skipped because a broken state is recorded")
            return
        }
        guard let assignment = settings.wallpaper.active else {
            Log.persistence.info("No persisted wallpaper to restore")
            return
        }

        await restore(assignment: assignment, reason: "Startup restore")
    }

    private func restore(assignment: WallpaperAssignment, reason: String) async {
        guard !isRestoringWallpaper else { return }
        isRestoringWallpaper = true
        defer { isRestoringWallpaper = false }

        var updated = assignment
        Log.persistence.notice(
            "\(reason, privacy: .public): resolving \(assignment.media.displayName, privacy: .public)"
        )

        do {
            let selection = try await activateMedia(reference: assignment.media)
            updated.media = selection.reference

            try playback.load(
                url: selection.url,
                duration: selection.metadata.duration,
                settings: settings.playback,
                autoplay: false
            )
            selectedMedia = selection.reference
            selectedMediaURL = selection.url
            mediaMetadata = selection.metadata
            importState = .idle

            try performApply(assignment: updated, url: selection.url)

            settings.wallpaper.active = updated
            if settings.wallpaper.last == nil
                || settings.wallpaper.last?.media.identifier == updated.media.identifier {
                settings.wallpaper.last = updated
            }
            settings.wallpaper.restoreIssue = nil
            missingWallpaper = nil
            Log.persistence.notice(
                "\(reason, privacy: .public) succeeded for \(updated.media.displayName, privacy: .public)"
            )
        } catch {
            handleRestoreFailure(error, assignment: updated)
        }
    }

    private func handleRestoreFailure(_ error: Error, assignment: WallpaperAssignment) {
        let reason = error.localizedDescription
        let issue = WallpaperRestoreIssue(
            media: assignment.media,
            displayMode: assignment.displayMode,
            reason: reason
        )

        settings.wallpaper.active = nil
        settings.wallpaper.last = assignment
        settings.wallpaper.restoreIssue = issue
        missingWallpaper = MissingWallpaper(issue: issue)

        Log.persistence.error(
            "Restore failed for \(assignment.media.displayName, privacy: .public): \(reason, privacy: .public). Waiting for relink."
        )
    }

    private func activateMedia(
        reference: MediaReference,
        metadata: MediaMetadata? = nil
    ) async throws -> MediaSelection {
        let resolved = try MediaBookmark.resolve(reference)

        do {
            let inspected: MediaMetadata
            if let metadata {
                inspected = metadata
            } else {
                inspected = try await MediaInspector.inspect(url: resolved.resource.url)
            }

            var updated = resolved.reference
            updated.lastKnownDuration = inspected.duration

            activeMediaResource?.stopAccessing()
            activeMediaResource = resolved.resource

            return MediaSelection(
                url: resolved.resource.url,
                reference: updated,
                metadata: inspected
            )
        } catch {
            resolved.resource.stopAccessing()
            throw error
        }
    }

    private func performApply(assignment: WallpaperAssignment, url: URL) throws {
        try wallpaper.apply(
            url: url,
            displayName: assignment.media.displayName,
            settings: settings.playback,
            displayMode: assignment.displayMode
        )
        recordDisplayConfigurations(for: assignment)
    }

    private func recordDisplayConfigurations(for assignment: WallpaperAssignment) {
        let appliedIDs = Set(wallpaper.appliedDisplayIDs)
        guard !appliedIDs.isEmpty else { return }

        var configurations = settings.displayConfigurations
        for display in displays where appliedIDs.contains(display.id) {
            configurations[display.persistentID] = DisplayWallpaperConfiguration(
                displayName: display.name,
                assignment: assignment
            )
        }
        settings.displayConfigurations = configurations
    }
}

private extension MediaImportState {
    var diagnosticSummary: String {
        switch self {
        case .idle: "idle"
        case .importing: "importing"
        case .failed(let message): "failed: \(message)"
        }
    }
}
