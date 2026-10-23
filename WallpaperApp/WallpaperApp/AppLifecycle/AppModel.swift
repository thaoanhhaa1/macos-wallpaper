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
    private(set) var lastWallpaper: AppliedWallpaper?
    private(set) var mediaMetadata: MediaMetadata?
    private(set) var importState: MediaImportState = .idle
    private(set) var displays: [DisplayInfo]

    let diagnostics: AppDiagnostics
    var surfaceStrategy: WallpaperSurfaceStrategy { wallpaper.strategy }

    @ObservationIgnored private var terminationObserver: NSObjectProtocol?

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
            }
        }

        Log.app.notice(
            "App model ready displays=\(self.displays.count, privacy: .public) schema=\(self.settings.schemaVersion, privacy: .public)"
        )
    }

    var playbackState: PlaybackState { playback.state }
    var isPlaying: Bool { playback.isPlaying }
    var hasMedia: Bool { selectedMedia != nil }
    var hasLastWallpaper: Bool { lastWallpaper != nil }
    var isWallpaperPlaying: Bool { wallpaper.isActive && !wallpaper.isPaused }
    var effectiveIsPlaying: Bool { wallpaper.isActive ? isWallpaperPlaying : isPlaying }

    var status: WallpaperStatus {
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
            let selection = try await importer.importVideo(at: url)
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
        guard let url = selectedMediaURL else { return }
        let name = selectedMedia?.displayName ?? url.lastPathComponent

        do {
            try wallpaper.apply(
                url: url,
                displayName: name,
                settings: settings.playback,
                displayMode: settings.displayMode
            )
            lastWallpaper = AppliedWallpaper(
                url: url,
                displayName: name,
                displayMode: settings.displayMode
            )
            Log.surface.notice(
                "Applied wallpaper \(name, privacy: .public) mode=\(self.settings.displayMode.rawValue, privacy: .public)"
            )
        } catch {
            Log.surface.error(
                "Apply failed for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func removeWallpaper() {
        wallpaper.remove()
        Log.surface.notice("Removed wallpaper; the desktop picture is visible again")
    }

    func restoreLastWallpaper() {
        guard let lastWallpaper else { return }

        do {
            try wallpaper.apply(
                url: lastWallpaper.url,
                displayName: lastWallpaper.displayName,
                settings: settings.playback,
                displayMode: settings.displayMode
            )
            Log.surface.notice(
                "Restored wallpaper \(lastWallpaper.displayName, privacy: .public)"
            )
        } catch {
            Log.surface.error(
                "Restore failed for \(lastWallpaper.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
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
        Wallpaper media: \(lastWallpaper?.displayName ?? "none")
        Surface windows: \(wallpaper.surfaceWindowNumbers.map(String.init).joined(separator: ", "))
        Import state: \(importState.diagnosticSummary)
        """

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report, forType: .string)
        Log.diagnostics.notice("Copied diagnostics report")
    }
}

struct AppliedWallpaper: Equatable {
    let url: URL
    let displayName: String
    let displayMode: DisplayMode
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
