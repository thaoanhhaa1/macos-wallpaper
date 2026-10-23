import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import Observation

enum WallpaperSurfaceState: Equatable {
    case inactive
    case active
    case failed(String)

    var failureReason: String? {
        guard case .failed(let message) = self else { return nil }
        return message
    }
}

enum WallpaperSurfaceError: LocalizedError, Equatable {
    case fileMissing(String)
    case noDisplay
    case playback(String)

    var errorDescription: String? {
        switch self {
        case .fileMissing(let name):
            "The wallpaper video is missing: \(name)"
        case .noDisplay:
            "No display is available for the wallpaper surface."
        case .playback(let message):
            "The wallpaper couldn't start playing: \(message)"
        }
    }
}

@MainActor
@Observable
final class WallpaperSurfaceController {
    private(set) var state: WallpaperSurfaceState = .inactive
    private(set) var surfaceCount = 0
    private(set) var appliedMediaName: String?
    private(set) var isActive = false
    private(set) var appliedDisplayIDs: [CGDirectDisplayID] = []

    @ObservationIgnored private(set) var playback: SurfacePlayback?
    @ObservationIgnored private var windows: [CGDirectDisplayID: WallpaperSurfaceWindow] = [:]
    @ObservationIgnored private var settings = PlaybackSettings()
    @ObservationIgnored private var displayMode: DisplayMode = .mainScreen
    @ObservationIgnored private var observerTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var isObserving = false

    let strategy: WallpaperSurfaceStrategy

    init(strategy: WallpaperSurfaceStrategy = .behindDesktopIcons) {
        self.strategy = strategy
    }

    var isPaused: Bool {
        playback?.isPaused ?? false
    }

    var appliedDisplayMode: DisplayMode {
        displayMode
    }

    var surfaceWindowNumbers: [Int] {
        windows.values.map(\.windowNumber)
    }

    func apply(
        url: URL,
        displayName: String,
        settings: PlaybackSettings,
        displayMode: DisplayMode
    ) throws {
        teardownSurfaces(resetApplied: true)

        self.settings = settings
        self.displayMode = displayMode

        let playback = SurfacePlayback()
        playback.onFailure = { [weak self] message in
            self?.handlePlaybackFailure(message)
        }

        do {
            try playback.load(url: url, settings: settings)
            try rebuildWindows(with: playback.player)
        } catch {
            playback.teardown()
            self.playback = nil
            teardownWindows()
            isActive = false
            surfaceCount = 0
            appliedDisplayIDs = []
            state = .failed(error.localizedDescription)
            Log.surface.error(
                "Failed to apply wallpaper \(displayName, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }

        self.playback = playback
        appliedMediaName = displayName
        isActive = true
        surfaceCount = windows.count
        appliedDisplayIDs = Array(windows.keys)
        state = .active
        installObserversIfNeeded()

        Log.surface.notice(
            "Applied wallpaper \(displayName, privacy: .public) surfaces=\(self.surfaceCount, privacy: .public) mode=\(displayMode.rawValue, privacy: .public) level=\(self.strategy.windowLevel.rawValue, privacy: .public)"
        )
    }

    func remove() {
        guard isActive || state.failureReason != nil else { return }
        teardownSurfaces(resetApplied: true)
        state = .inactive
        Log.surface.notice("Removed wallpaper surface")
    }

    func shutdown() {
        teardownSurfaces(resetApplied: true)
        state = .inactive
        removeObservers()
    }

    func play() {
        guard isActive else { return }
        playback?.setPaused(false)
    }

    func pause() {
        guard isActive else { return }
        playback?.setPaused(true)
    }

    func togglePlayback() {
        guard isActive, let playback else { return }
        playback.setPaused(!playback.isPaused)
    }

    func update(settings: PlaybackSettings, displayMode: DisplayMode) {
        self.settings = settings
        let modeChanged = displayMode != self.displayMode
        self.displayMode = displayMode

        guard isActive else { return }

        for window in windows.values {
            window.update(settings: settings)
        }

        let previousPlayer = playback?.player
        do {
            try playback?.apply(settings)
        } catch {
            handlePlaybackFailure(error.localizedDescription)
            return
        }

        if let player = playback?.player, player !== previousPlayer {
            for window in windows.values {
                window.setPlayer(player)
            }
        }

        if modeChanged {
            rebuildAfterDisplayChange()
        }
    }

    func handleDisplayChange(displayMode: DisplayMode) {
        self.displayMode = displayMode
        guard isActive else { return }
        rebuildAfterDisplayChange()
    }

    func reassertOrdering() {
        guard isActive, !windows.isEmpty else { return }
        for window in windows.values {
            window.reassertOrdering(strategy: strategy)
        }
        Log.surface.debug(
            "Reasserted ordering for \(self.windows.count, privacy: .public) surface(s)"
        )
    }

    private func rebuildAfterDisplayChange() {
        guard let player = playback?.player else { return }

        do {
            try rebuildWindows(with: player)
            surfaceCount = windows.count
            appliedDisplayIDs = Array(windows.keys)
            Log.surface.info(
                "Rebuilt wallpaper surfaces count=\(self.surfaceCount, privacy: .public)"
            )
        } catch {
            handlePlaybackFailure(error.localizedDescription)
        }
    }

    private func rebuildWindows(with player: AVQueuePlayer?) throws {
        guard let player else {
            throw WallpaperSurfaceError.playback("The wallpaper player is unavailable.")
        }

        let screens = desiredScreens()
        var desired: [CGDirectDisplayID: NSScreen] = [:]
        for screen in screens {
            if let displayID = Self.displayID(for: screen) {
                desired[displayID] = screen
            }
        }

        guard !desired.isEmpty else {
            throw WallpaperSurfaceError.noDisplay
        }

        let staleIDs = windows.keys.filter { desired[$0] == nil }
        for displayID in staleIDs {
            if let window = windows.removeValue(forKey: displayID) {
                window.teardown()
                Log.surface.info(
                    "Removed surface for display \(displayID, privacy: .public)"
                )
            }
        }

        for (displayID, screen) in desired {
            if let window = windows[displayID] {
                window.update(screen: screen, settings: settings, strategy: strategy)
            } else {
                let window = WallpaperSurfaceWindow(
                    screen: screen,
                    displayID: displayID,
                    player: player,
                    settings: settings,
                    strategy: strategy
                )
                windows[displayID] = window
                window.present()
            }
        }
    }

    private func desiredScreens() -> [NSScreen] {
        switch displayMode {
        case .allScreens:
            NSScreen.screens
        case .mainScreen, .perDisplay:
            Array(NSScreen.screens.prefix(1))
        }
    }

    private func teardownSurfaces(resetApplied: Bool) {
        teardownWindows()
        playback?.onFailure = nil
        playback?.teardown()
        playback = nil
        isActive = false
        surfaceCount = 0
        appliedDisplayIDs = []
        if resetApplied {
            appliedMediaName = nil
        }
    }

    private func teardownWindows() {
        for window in windows.values {
            window.teardown()
        }
        windows.removeAll()
    }

    private func handlePlaybackFailure(_ message: String) {
        teardownSurfaces(resetApplied: true)
        state = .failed(message)
        Log.surface.error("Wallpaper surface failed: \(message, privacy: .public)")
    }

    private func installObserversIfNeeded() {
        guard !isObserving else { return }
        isObserving = true

        let center = NotificationCenter.default
        observerTokens.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reassertOrdering()
            }
        })
        observerTokens.append(center.addObserver(
            forName: NSApplication.didUnhideNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reassertOrdering()
            }
        })

        let workspace = NSWorkspace.shared.notificationCenter
        observerTokens.append(workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.apple.finder" else { return }
            Task { @MainActor in
                self?.reassertOrdering()
            }
        })
        observerTokens.append(workspace.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.apple.finder" else { return }
            Task { @MainActor in
                self?.reassertOrdering()
            }
        })
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        for token in observerTokens {
            center.removeObserver(token)
        }
        observerTokens.removeAll()
        isObserving = false
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        return number.uint32Value
    }

    deinit {
        let center = NotificationCenter.default
        for token in observerTokens {
            center.removeObserver(token)
        }
    }
}
