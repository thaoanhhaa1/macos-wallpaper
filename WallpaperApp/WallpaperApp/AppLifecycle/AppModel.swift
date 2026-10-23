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
                wallpaper.update(settings: settings.playback)
                reapplyResourcePolicy()
            }

            Log.settings.info("Settings updated schema=\(self.settings.schemaVersion, privacy: .public)")
        }
    }

    let playback = PlaybackEngine()
    let wallpaper = WallpaperSurfaceController()
    let performanceMonitor = PerformanceMonitor()

    private let resourcePolicyMonitor = ResourcePolicyMonitor()
    private(set) var resourceConditions = ResourceConditions()
    private(set) var resourcePauseReasons: Set<ResourcePauseReason> = []

    var selectedMedia: MediaReference?
    private(set) var selectedMediaURL: URL?
    private(set) var mediaMetadata: MediaMetadata?
    private(set) var importState: MediaImportState = .idle
    private(set) var displays: [DisplayInfo]
    private(set) var missingWallpaper: MissingWallpaper?
    private(set) var isRestoringWallpaper = false
    private(set) var selectedDisplayPersistentID: String?

    let diagnostics: AppDiagnostics
    var surfaceStrategy: WallpaperSurfaceStrategy { wallpaper.strategy }

    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var mediaCache: [UUID: CachedMedia] = [:]
    @ObservationIgnored private var hasAttemptedStartupRestore = false
    @ObservationIgnored private var displayReconcileTask: Task<Void, Never>?

    private struct CachedMedia {
        var reference: MediaReference
        let url: URL
        let resource: SecurityScopedMedia
    }

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
            self?.handleDisplayConfigurationChange(displays)
        }
        coordinator.start()

        resourcePolicyMonitor.onChange = { [weak self] conditions in
            self?.applyResourceConditions(conditions)
        }
        resourcePolicyMonitor.start()

        performanceMonitor.droppedFramesProvider = { [weak self] in
            guard let self else { return .zero }
            if self.wallpaper.isActive {
                return self.wallpaper.droppedFrameStats
            }
            return self.playback.droppedFrameStats()
        }
        performanceMonitor.start()

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resourcePolicyMonitor.stop()
                self?.performanceMonitor.stop()
                self?.playback.teardown()
                self?.wallpaper.shutdown()
                self?.stopAllMediaResources()
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
    var displayMode: DisplayMode { settings.displayMode }

    var isWaitingForDisplay: Bool {
        settings.wallpaper.active != nil
            && !wallpaper.isActive
            && !isRestoringWallpaper
            && missingWallpaper == nil
            && wallpaper.state.failureReason == nil
    }

    var targetDisplayPersistentID: String? {
        if let selectedDisplayPersistentID,
           displays.contains(where: { $0.persistentID == selectedDisplayPersistentID }) {
            return selectedDisplayPersistentID
        }
        return (displays.first(where: \.isMain) ?? displays.first(where: { !$0.isMirrored }))?.persistentID
    }

    var disconnectedDisplayConfigurations: [DisconnectedDisplayConfiguration] {
        let connectedIDs = Set(displays.map(\.persistentID))
        return settings.displayConfigurations
            .filter { !connectedIDs.contains($0.key) }
            .map { DisconnectedDisplayConfiguration(persistentID: $0.key, configuration: $0.value) }
            .sorted { $0.configuration.displayName < $1.configuration.displayName }
    }

    var status: WallpaperStatus {
        if let missingWallpaper {
            return .error(missingWallpaper.reason)
        }
        if let failure = wallpaper.state.failureReason {
            return .error(failure)
        }
        if isWaitingForDisplay {
            return .waitingForDisplay
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
        if isWaitingForDisplay {
            return "The saved wallpaper is waiting for a configured display to reconnect."
        }
        if wallpaper.isActive {
            let count = wallpaper.surfaceCount
            let suffix = count == 1 ? "" : "s"
            if wallpaper.isPaused {
                if let pauseReasonSummary {
                    return "Video wallpaper is paused on \(count) display\(suffix): \(pauseReasonSummary)."
                }
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
        case .waitingForDisplay:
            return "The saved wallpaper is waiting for a configured display to reconnect."
        case .error(let message):
            return message
        }
    }

    var resourcePolicy: ResourcePolicy {
        ResourcePolicy(playback: settings.playback)
    }

    var isPolicyPaused: Bool {
        !resourcePauseReasons.isEmpty
    }

    var pauseReasonSummary: String? {
        var reasons = resourcePauseReasons
        if wallpaper.isActive && wallpaper.isUserPaused {
            reasons.insert(.user)
        }
        guard !reasons.isEmpty else { return nil }
        return reasons
            .sorted {
                (ResourcePauseReason.allCases.firstIndex(of: $0) ?? 0)
                    < (ResourcePauseReason.allCases.firstIndex(of: $1) ?? 0)
            }
            .map(\.title)
            .joined(separator: ", ")
    }

    var performanceSample: PerformanceSample {
        performanceMonitor.sample
    }

    var previewDroppedFrameStats: DroppedFrameStats {
        playback.droppedFrameStats()
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
            stopUnusedMedia(keeping: wallpaper.appliedMediaIdentifiers)
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
            stopUnusedMedia(keeping: wallpaper.appliedMediaIdentifiers)

            let media = mediaCache[selection.reference.identifier]?.reference ?? selection.reference
            let previous = settings

            do {
                if let displayPersistentID = issue.displayPersistentID {
                    let displayName = issue.targetDisplayName
                        ?? displays.first(where: { $0.persistentID == displayPersistentID })?.name
                        ?? "Display"
                    let assignment = WallpaperAssignment(media: media, displayMode: .perDisplay)
                    settings.displayMode = .perDisplay
                    settings.displayConfigurations[displayPersistentID] = DisplayWallpaperConfiguration(
                        displayName: displayName,
                        assignment: assignment
                    )
                    settings.wallpaper.active = assignment
                    settings.wallpaper.last = assignment
                    settings.wallpaper.restoreIssue = nil
                    missingWallpaper = nil

                    try await restorePerDisplay(
                        assignment: assignment,
                        reason: "Relink display"
                    )
                } else {
                    let assignment = WallpaperAssignment(
                        media: media,
                        displayMode: issue.displayMode
                    )
                    settings.displayMode = issue.displayMode
                    let assignments = desiredAssignments(
                        for: issue.displayMode,
                        using: assignment.media
                    )
                    guard !assignments.isEmpty else {
                        throw WallpaperSurfaceError.noDisplay
                    }
                    try applyAssignments(
                        assignments,
                        mode: issue.displayMode,
                        reason: "Relink"
                    )
                    settings.wallpaper.active = assignment
                    settings.wallpaper.last = assignment
                    settings.wallpaper.restoreIssue = nil
                    missingWallpaper = nil
                }

                importState = .idle
                Log.persistence.notice(
                    "Relinked wallpaper \(media.displayName, privacy: .public)"
                )
            } catch {
                rollbackSettings(to: previous, reason: "Relink rollback")
                throw error
            }
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

    func setDisplayMode(_ mode: DisplayMode) {
        guard mode != settings.displayMode else { return }
        cancelPendingDisplayReconcile()

        if mode == .perDisplay {
            seedPerDisplayConfigurations()
        }

        settings.displayMode = mode
        if var active = settings.wallpaper.active {
            active.displayMode = mode
            settings.wallpaper.active = active
        }

        Log.display.notice("Display mode changed to \(mode.rawValue, privacy: .public)")

        guard settings.wallpaper.active != nil else { return }
        reconcileActiveWallpaper(reason: "Display mode change")
    }

    func selectDisplay(_ persistentID: String) {
        guard displays.contains(where: { $0.persistentID == persistentID && !$0.isMirrored }) else {
            return
        }
        selectedDisplayPersistentID = persistentID
        Log.display.info("Selected display \(persistentID, privacy: .public)")
    }

    func assignSelectedMedia(toDisplayPersistentID persistentID: String) {
        selectDisplay(persistentID)
        if settings.displayMode != .perDisplay {
            setDisplayMode(.perDisplay)
        }
        applyWallpaper()
    }

    func clearDisplayAssignment(persistentID: String) {
        guard settings.displayConfigurations[persistentID] != nil else { return }
        cancelPendingDisplayReconcile()
        let previous = settings
        settings.displayConfigurations.removeValue(forKey: persistentID)

        if missingWallpaper?.displayPersistentID == persistentID {
            missingWallpaper = nil
            settings.wallpaper.restoreIssue = nil
        }

        guard settings.displayMode == .perDisplay, settings.wallpaper.active != nil else {
            Log.display.notice("Removed display configuration \(persistentID, privacy: .public)")
            return
        }

        let assignments = desiredAssignments(
            for: .perDisplay,
            using: settings.wallpaper.active?.media
        )
        if assignments.isEmpty {
            wallpaper.remove()
            stopUnusedMedia(keeping: [])
            if settings.displayConfigurations.isEmpty {
                settings.wallpaper.active = nil
            }
        } else {
            do {
                try applyAssignments(
                    assignments,
                    mode: .perDisplay,
                    reason: "Clear display"
                )
            } catch {
                rollbackSettings(to: previous, reason: "Clear display rollback")
                Log.surface.error(
                    "Failed to clear display \(persistentID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                return
            }
        }

        Log.display.notice("Removed display configuration \(persistentID, privacy: .public)")
    }

    func forgetDisconnectedDisplay(persistentID: String) {
        guard let configuration = settings.displayConfigurations.removeValue(forKey: persistentID) else {
            return
        }
        if missingWallpaper?.displayPersistentID == persistentID {
            missingWallpaper = nil
            settings.wallpaper.restoreIssue = nil
        }
        if settings.displayMode == .perDisplay,
           settings.displayConfigurations.isEmpty,
           !wallpaper.isActive {
            settings.wallpaper.active = nil
        }
        Log.display.notice(
            "Forgot disconnected display \(configuration.displayName, privacy: .public)"
        )
    }

    func applyWallpaper() {
        guard let reference = selectedMedia, selectedMediaURL != nil else { return }
        cancelPendingDisplayReconcile()
        let previous = settings

        do {
            let cached = try cachedMedia(for: reference)
            let mode = settings.displayMode

            switch mode {
            case .allScreens, .mainScreen:
                let assignment = WallpaperAssignment(media: cached.reference, displayMode: mode)
                let assignments = desiredAssignments(for: mode, using: assignment.media)
                guard !assignments.isEmpty else {
                    throw WallpaperSurfaceError.noDisplay
                }

                try applyAssignments(assignments, mode: mode, reason: "Apply")
                settings.wallpaper.active = assignment
                settings.wallpaper.last = assignment

            case .perDisplay:
                guard let persistentID = targetDisplayPersistentID,
                      let display = displays.first(where: { $0.persistentID == persistentID }),
                      !display.isMirrored else {
                    throw WallpaperSurfaceError.noDisplay
                }

                let assignment = WallpaperAssignment(
                    media: cached.reference,
                    displayMode: .perDisplay
                )
                settings.displayConfigurations[persistentID] = DisplayWallpaperConfiguration(
                    displayName: display.name,
                    assignment: assignment
                )
                settings.wallpaper.active = assignment
                settings.wallpaper.last = assignment

                let assignments = desiredAssignments(
                    for: .perDisplay,
                    using: assignment.media
                )
                guard !assignments.isEmpty else {
                    throw WallpaperSurfaceError.noDisplay
                }
                try applyAssignments(
                    assignments,
                    mode: .perDisplay,
                    reason: "Apply display"
                )
            }

            settings.wallpaper.restoreIssue = nil
            missingWallpaper = nil
            Log.surface.notice(
                "Applied wallpaper \(cached.reference.displayName, privacy: .public) mode=\(mode.rawValue, privacy: .public)"
            )
        } catch {
            rollbackSettings(to: previous, reason: "Apply rollback")
            Log.surface.error(
                "Apply failed for \(reference.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func removeWallpaper() {
        cancelPendingDisplayReconcile()
        wallpaper.remove()
        settings.wallpaper.active = nil
        settings.wallpaper.restoreIssue = nil
        missingWallpaper = nil
        stopUnusedMedia(keeping: [])
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

    func assignedMediaName(for persistentID: String) -> String? {
        settings.displayConfigurations[persistentID]?.assignment.media.displayName
    }

    func surfaceMediaName(for persistentID: String) -> String? {
        wallpaper.surfaceMediaNames[persistentID]
    }

    func isSurfaceActive(for persistentID: String) -> Bool {
        wallpaper.appliedDisplayPersistentIDs.contains(persistentID)
    }

    func copyDiagnostics() {
        let displaySummary = displays
            .map { display in
                let config = settings.displayConfigurations[display.persistentID]
                let surface = wallpaper.appliedDisplayPersistentIDs.contains(display.persistentID)
                let mirror = display.isMirrored
                    ? " mirroredWith=\(display.mirrorsDisplayID.map(String.init) ?? "unknown")"
                    : ""
                return "\(display.name) id=\(display.persistentID) \(display.summary) main=\(display.isMain) builtIn=\(display.isBuiltIn)\(mirror) assigned=\(config?.assignment.media.displayName ?? "none") surface=\(surface)"
            }
            .joined(separator: "\n")

        let disconnectedSummary = disconnectedDisplayConfigurations
            .map { entry in
                "\(entry.configuration.displayName) id=\(entry.persistentID) assigned=\(entry.configuration.assignment.media.displayName)"
            }
            .joined(separator: "\n")

        let mediaSummary = selectedMedia.map {
            "\($0.displayName) (\(mediaMetadata?.summary ?? "metadata unavailable"))"
        } ?? "none"

        let persistenceSummary = """
        active=\(settings.wallpaper.active?.media.displayName ?? "none")
        last=\(settings.wallpaper.last?.media.displayName ?? "none")
        restoreIssue=\(missingWallpaper?.reason ?? "none")
        bookmarkBytes=\(selectedMedia?.bookmarkData.count ?? 0)
        displayMode=\(settings.displayMode.rawValue)
        displayConfigurations=\(settings.displayConfigurations.count)
        """

        performanceMonitor.sampleNow()
        let performance = performanceMonitor.sample
        let performanceSummary = """
        cpu=\(performance.cpuSummary) memory=\(performance.memorySummary) gpu=\(performance.gpuSummary)
        droppedFrames=\(performance.droppedFrameSummary) stalls=\(performance.stalls)
        """

        let report = """
        \(diagnostics.report)
        Displays:
        \(displaySummary.isEmpty ? "none" : displaySummary)
        Disconnected display configurations:
        \(disconnectedSummary.isEmpty ? "none" : disconnectedSummary)
        Settings schema: \(settings.schemaVersion)
        Surface strategy: \(surfaceStrategy.title)
        Resource policy: \(resourcePolicy.summary)
        Resource conditions: \(resourceConditions.summary)
        Pause reasons: \(pauseReasonSummary ?? "none")
        Performance:
        \(performanceSummary)
        Media: \(mediaSummary)
        Playback: \(playbackState.title)
        Wallpaper: \(wallpaper.state.title) surfaces=\(wallpaper.surfaceCount) players=\(wallpaper.playerCount) paused=\(wallpaper.isPaused)
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

    private func reapplyResourcePolicy() {
        applyResourceConditions(resourcePolicyMonitor.conditions)
    }

    private func applyResourceConditions(_ conditions: ResourceConditions) {
        resourceConditions = conditions
        let reasons = resourcePolicy.pauseReasons(for: conditions)

        guard reasons != resourcePauseReasons else { return }
        resourcePauseReasons = reasons
        wallpaper.setResourcePauseReasons(reasons)
    }

    private func handleDisplayConfigurationChange(_ newDisplays: [DisplayInfo]) {
        let previousIDs = Set(displays.map(\.persistentID))
        let currentIDs = Set(newDisplays.map(\.persistentID))
        let added = currentIDs.subtracting(previousIDs)
        let removed = previousIDs.subtracting(currentIDs)

        displays = newDisplays

        if let selectedDisplayPersistentID,
           !currentIDs.contains(selectedDisplayPersistentID) {
            self.selectedDisplayPersistentID = nil
        }

        if !added.isEmpty || !removed.isEmpty {
            Log.display.notice(
                "Displays added=\(added.sorted().joined(separator: ","), privacy: .public) removed=\(removed.sorted().joined(separator: ","), privacy: .public)"
            )
        }

        guard settings.wallpaper.active != nil else { return }

        cancelPendingDisplayReconcile()
        displayReconcileTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.reconcileActiveWallpaper(reason: "Display change")
        }
    }

    private func cancelPendingDisplayReconcile() {
        displayReconcileTask?.cancel()
        displayReconcileTask = nil
    }

    private func rollbackSettings(to previous: AppSettings, reason: String) {
        settings = previous
        guard previous.wallpaper.active != nil else { return }
        reconcileActiveWallpaper(reason: reason)
    }

    private func seedPerDisplayConfigurations() {
        guard let active = settings.wallpaper.active else { return }
        var added = 0

        for display in displays where !display.isMirrored {
            guard settings.displayConfigurations[display.persistentID] == nil else { continue }
            settings.displayConfigurations[display.persistentID] = DisplayWallpaperConfiguration(
                displayName: display.name,
                assignment: WallpaperAssignment(media: active.media, displayMode: .perDisplay)
            )
            added += 1
        }

        if added > 0 {
            Log.display.info("Seeded \(added, privacy: .public) per-display configuration(s)")
        }
    }

    private func reconcileActiveWallpaper(reason: String) {
        guard let active = settings.wallpaper.active else { return }
        let mode = settings.displayMode
        let assignments = desiredAssignments(for: mode, using: active.media)

        guard !assignments.isEmpty else {
            wallpaper.remove()
            stopUnusedMedia(keeping: [])
            Log.surface.info(
                "Wallpaper suspended until a configured display reconnects (\(reason, privacy: .public))"
            )
            return
        }

        do {
            try applyAssignments(assignments, mode: mode, reason: reason)
        } catch {
            Log.surface.error(
                "Reconcile failed after \(reason, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func desiredAssignments(
        for mode: DisplayMode,
        using media: MediaReference?
    ) -> [String: WallpaperAssignment] {
        let eligibleDisplays = displays.filter { !$0.isMirrored }

        switch mode {
        case .allScreens:
            guard let media else { return [:] }
            return Dictionary(
                uniqueKeysWithValues: eligibleDisplays.map { display in
                    (display.persistentID, WallpaperAssignment(media: media, displayMode: .allScreens))
                }
            )

        case .mainScreen:
            guard let media,
                  let mainDisplay = eligibleDisplays.first(where: \.isMain) ?? eligibleDisplays.first else {
                return [:]
            }
            return [
                mainDisplay.persistentID: WallpaperAssignment(
                    media: media,
                    displayMode: .mainScreen
                )
            ]

        case .perDisplay:
            var assignments: [String: WallpaperAssignment] = [:]
            for display in eligibleDisplays {
                guard let configuration = settings.displayConfigurations[display.persistentID] else {
                    continue
                }
                assignments[display.persistentID] = WallpaperAssignment(
                    media: configuration.assignment.media,
                    displayMode: .perDisplay
                )
            }
            return assignments
        }
    }

    private func applyAssignments(
        _ assignments: [String: WallpaperAssignment],
        mode: DisplayMode,
        reason: String
    ) throws {
        var surfaceAssignments: [String: WallpaperSurfaceMedia] = [:]
        var resolvedMedia: [UUID: CachedMedia] = [:]

        for (persistentID, assignment) in assignments {
            let cached: CachedMedia
            if let existing = resolvedMedia[assignment.media.identifier] {
                cached = existing
            } else {
                cached = try cachedMedia(for: assignment.media)
                resolvedMedia[cached.reference.identifier] = cached
            }
            surfaceAssignments[persistentID] = WallpaperSurfaceMedia(
                identifier: cached.reference.identifier,
                url: cached.url,
                displayName: cached.reference.displayName
            )
        }

        guard !surfaceAssignments.isEmpty else {
            throw WallpaperSurfaceError.noDisplay
        }

        try wallpaper.apply(
            assignments: surfaceAssignments,
            settings: settings.playback,
            displayMode: mode
        )

        updateDisplayConfigurations(
            assignments: assignments,
            resolvedMedia: resolvedMedia,
            mode: mode
        )
        stopUnusedMedia(keeping: Set(resolvedMedia.keys))

        Log.surface.notice(
            "\(reason, privacy: .public): \(surfaceAssignments.count, privacy: .public) display(s) mode=\(mode.rawValue, privacy: .public)"
        )
    }

    private func updateDisplayConfigurations(
        assignments: [String: WallpaperAssignment],
        resolvedMedia: [UUID: CachedMedia],
        mode: DisplayMode
    ) {
        let appliedPersistentIDs = wallpaper.appliedDisplayPersistentIDs
        var configurations = settings.displayConfigurations

        for persistentID in appliedPersistentIDs {
            guard let assignment = assignments[persistentID],
                  let cached = resolvedMedia[assignment.media.identifier] else {
                continue
            }
            configurations[persistentID] = DisplayWallpaperConfiguration(
                displayName: displayName(for: persistentID),
                assignment: WallpaperAssignment(media: cached.reference, displayMode: mode)
            )
        }

        if mode != .perDisplay {
            let connectedPersistentIDs = Set(
                displays.filter { !$0.isMirrored }.map(\.persistentID)
            )
            for persistentID in connectedPersistentIDs.subtracting(appliedPersistentIDs) {
                configurations.removeValue(forKey: persistentID)
            }
        }

        if configurations != settings.displayConfigurations {
            settings.displayConfigurations = configurations
        }
    }

    private func displayName(for persistentID: String) -> String {
        displays.first(where: { $0.persistentID == persistentID })?.name
            ?? settings.displayConfigurations[persistentID]?.displayName
            ?? "Display"
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
            "\(reason, privacy: .public): resolving \(assignment.media.displayName, privacy: .public) mode=\(assignment.displayMode.rawValue, privacy: .public)"
        )

        do {
            if assignment.displayMode == .perDisplay {
                try await restorePerDisplay(assignment: assignment, reason: reason)
                return
            }

            let selection = try await activateMedia(reference: assignment.media)
            updated.media = mediaCache[selection.reference.identifier]?.reference
                ?? selection.reference

            try playback.load(
                url: selection.url,
                duration: selection.metadata.duration,
                settings: settings.playback,
                autoplay: false
            )
            selectedMedia = updated.media
            selectedMediaURL = selection.url
            mediaMetadata = selection.metadata
            importState = .idle

            let assignments = desiredAssignments(
                for: updated.displayMode,
                using: updated.media
            )
            guard !assignments.isEmpty else {
                throw WallpaperSurfaceError.noDisplay
            }
            try applyAssignments(
                assignments,
                mode: updated.displayMode,
                reason: reason
            )

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
            if assignment.displayMode == .perDisplay {
                Log.persistence.error(
                    "\(reason, privacy: .public) failed for per-display configuration: \(error.localizedDescription, privacy: .public)"
                )
            }
            handleRestoreFailure(error, assignment: updated)
        }
    }

    private func restorePerDisplay(
        assignment: WallpaperAssignment,
        reason: String
    ) async throws {
        let eligibleDisplays = displays.filter { !$0.isMirrored }
        var assignments: [String: WallpaperAssignment] = [:]
        var resolvedMedia: [UUID: CachedMedia] = [:]
        var issues: [WallpaperRestoreIssue] = []

        for display in eligibleDisplays {
            guard let configuration = settings.displayConfigurations[display.persistentID] else {
                continue
            }

            do {
                let cached: CachedMedia
                if let existing = resolvedMedia[configuration.assignment.media.identifier] {
                    cached = existing
                } else {
                    cached = try cachedMedia(for: configuration.assignment.media)
                    resolvedMedia[cached.reference.identifier] = cached
                }
                assignments[display.persistentID] = WallpaperAssignment(
                    media: cached.reference,
                    displayMode: .perDisplay
                )
            } catch {
                issues.append(
                    WallpaperRestoreIssue(
                        media: configuration.assignment.media,
                        displayMode: .perDisplay,
                        reason: error.localizedDescription,
                        displayPersistentID: display.persistentID,
                        displayName: display.name
                    )
                )
            }
        }

        if assignments.isEmpty {
            if let firstIssue = issues.first {
                settings.wallpaper.active = assignment
                settings.wallpaper.last = assignment
                settings.wallpaper.restoreIssue = firstIssue
                missingWallpaper = MissingWallpaper(issue: firstIssue)
                Log.persistence.error(
                    "\(reason, privacy: .public) found no restorable display configuration"
                )
                return
            }

            if !settings.displayConfigurations.isEmpty {
                settings.wallpaper.active = assignment
                settings.wallpaper.last = assignment
                settings.wallpaper.restoreIssue = nil
                missingWallpaper = nil
                wallpaper.remove()
                Log.persistence.notice(
                    "\(reason, privacy: .public) is waiting for a configured display to reconnect"
                )
                return
            }

            let selection = try await activateMedia(reference: assignment.media)
            guard let mainDisplay = eligibleDisplays.first(where: \.isMain)
                ?? eligibleDisplays.first else {
                throw WallpaperSurfaceError.noDisplay
            }
            let media = mediaCache[selection.reference.identifier]?.reference ?? selection.reference
            let fallback = WallpaperAssignment(media: media, displayMode: .perDisplay)
            settings.displayConfigurations[mainDisplay.persistentID] = DisplayWallpaperConfiguration(
                displayName: mainDisplay.name,
                assignment: fallback
            )
            assignments[mainDisplay.persistentID] = fallback
            selectedMedia = media
            selectedMediaURL = selection.url
            mediaMetadata = selection.metadata
            importState = .idle
            try playback.load(
                url: selection.url,
                duration: selection.metadata.duration,
                settings: settings.playback,
                autoplay: false
            )
        }

        try applyAssignments(assignments, mode: .perDisplay, reason: reason)

        let appliedPersistentIDs = wallpaper.appliedDisplayPersistentIDs
        let firstApplied = assignments.first(where: { appliedPersistentIDs.contains($0.key) })?.value
            ?? assignments.values.first
        let active = WallpaperAssignment(
            media: firstApplied?.media ?? assignment.media,
            displayMode: .perDisplay
        )

        settings.wallpaper.active = active
        settings.wallpaper.last = assignment
        let firstIssue = issues.first
        settings.wallpaper.restoreIssue = firstIssue
        missingWallpaper = firstIssue.map(MissingWallpaper.init)

        if selectedMedia == nil,
           let cached = mediaCache[active.media.identifier] {
            selectedMedia = active.media
            selectedMediaURL = cached.url
            try? playback.load(
                url: cached.url,
                duration: active.media.lastKnownDuration ?? 0,
                settings: settings.playback,
                autoplay: false
            )
        }

        Log.persistence.notice(
            "\(reason, privacy: .public) restored \(appliedPersistentIDs.count, privacy: .public) per-display surface(s) issues=\(issues.count, privacy: .public)"
        )
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

            let cached = CachedMedia(
                reference: updated,
                url: resolved.resource.url,
                resource: resolved.resource
            )
            if let existing = mediaCache[updated.identifier] {
                existing.resource.stopAccessing()
            }
            mediaCache[updated.identifier] = cached

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

    private func cachedMedia(for reference: MediaReference) throws -> CachedMedia {
        if let cached = mediaCache[reference.identifier] {
            if FileManager.default.fileExists(atPath: cached.url.path) {
                return cached
            }
            cached.resource.stopAccessing()
            mediaCache.removeValue(forKey: reference.identifier)
        }

        let resolved = try MediaBookmark.resolve(reference)
        let cached = CachedMedia(
            reference: resolved.reference,
            url: resolved.resource.url,
            resource: resolved.resource
        )
        mediaCache[cached.reference.identifier] = cached
        return cached
    }

    private func stopUnusedMedia(keeping identifiers: Set<UUID>) {
        var keep = identifiers
        if let selectedMedia {
            keep.insert(selectedMedia.identifier)
        }

        for (identifier, cached) in Array(mediaCache) where !keep.contains(identifier) {
            cached.resource.stopAccessing()
            mediaCache.removeValue(forKey: identifier)
        }
    }

    private func stopAllMediaResources() {
        for cached in mediaCache.values {
            cached.resource.stopAccessing()
        }
        mediaCache.removeAll()
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
