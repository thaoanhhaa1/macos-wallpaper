import AppKit
import Observation

@MainActor
@Observable
final class AppModel {
    private let settingsStore: SettingsStore
    private let displayCoordinator: DisplayCoordinator

    var settings: AppSettings {
        didSet {
            guard oldValue != settings else { return }
            settingsStore.save(settings)
            Log.settings.info("Settings updated schema=\(self.settings.schemaVersion, privacy: .public)")
        }
    }

    var playbackState: PlaybackState = .idle
    var selectedMedia: MediaReference?
    private(set) var displays: [DisplayInfo]
    private(set) var lastError: String?

    let diagnostics: AppDiagnostics
    let surfaceStrategy = WallpaperSurfaceStrategy.behindDesktopIcons

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

        coordinator.onChange = { [weak self] displays in
            self?.displays = displays
        }
        coordinator.start()

        Log.app.notice(
            "App model ready displays=\(self.displays.count, privacy: .public) schema=\(self.settings.schemaVersion, privacy: .public)"
        )
    }

    var status: WallpaperStatus {
        if let lastError {
            return .error(lastError)
        }

        guard selectedMedia != nil else {
            return .noWallpaper
        }

        switch playbackState {
        case .playing:
            return .playing
        case .paused, .preparing:
            return .paused
        case .failed(let reason):
            return .error(reason)
        case .idle:
            return .noWallpaper
        }
    }

    var statusDetail: String {
        switch status {
        case .noWallpaper:
            "Choose a video in Settings to create a wallpaper."
        case .playing:
            "Your video wallpaper is playing."
        case .paused:
            "Playback is paused."
        case .error(let message):
            message
        }
    }

    var resourcePolicy: ResourcePolicy {
        ResourcePolicy(playback: settings.playback)
    }

    var developmentFixtureURL: URL? {
        DevelopmentFixture.bundleURL
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

        let report = """
        \(diagnostics.report)
        Displays:
        \(displaySummary.isEmpty ? "none" : displaySummary)
        Settings schema: \(settings.schemaVersion)
        Surface strategy: \(surfaceStrategy.title)
        Resource policy: \(resourcePolicy.summary)
        """

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report, forType: .string)
        Log.diagnostics.notice("Copied diagnostics report")
    }
}
