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

            Log.settings.info("Settings updated schema=\(self.settings.schemaVersion, privacy: .public)")
        }
    }

    let playback = PlaybackEngine()

    var selectedMedia: MediaReference?
    private(set) var mediaMetadata: MediaMetadata?
    private(set) var importState: MediaImportState = .idle
    private(set) var displays: [DisplayInfo]

    let diagnostics: AppDiagnostics
    let surfaceStrategy = WallpaperSurfaceStrategy.behindDesktopIcons

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
        }
        coordinator.start()

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.playback.teardown()
            }
        }

        Log.app.notice(
            "App model ready displays=\(self.displays.count, privacy: .public) schema=\(self.settings.schemaVersion, privacy: .public)"
        )
    }

    var playbackState: PlaybackState { playback.state }
    var isPlaying: Bool { playback.isPlaying }
    var hasMedia: Bool { selectedMedia != nil }

    var status: WallpaperStatus {
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
        Import state: \(importState.diagnosticSummary)
        """

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report, forType: .string)
        Log.diagnostics.notice("Copied diagnostics report")
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
