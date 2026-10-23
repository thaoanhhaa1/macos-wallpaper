import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor
final class WallpaperSurfaceController {
    private var windows: [CGDirectDisplayID: WallpaperSurfaceWindow] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var isUserPaused = false
    private(set) var videoURL: URL?
    private(set) var configuration = SpikeConfiguration()

    var onEvent: ((String) -> Void)?

    init() {
        registerObservers()
    }

    var isRunning: Bool { !windows.isEmpty }
    var surfaceCount: Int { windows.count }
    var surfaceWindowNumbers: [Int] { windows.values.map(\.windowNumber) }
    var playingCount: Int { windows.values.filter { $0.playback.isPlaying }.count }

    func start(videoURL: URL, configuration: SpikeConfiguration) throws {
        teardownAll()
        self.videoURL = videoURL
        self.configuration = configuration
        isUserPaused = false
        try rebuildSurfaces()
        emit("Started \(windows.count) surface(s) with level \(configuration.level.detail) on \(configuration.target.title.lowercased())")
    }

    func update(configuration: SpikeConfiguration) throws {
        self.configuration = configuration
        guard videoURL != nil else { return }
        try rebuildSurfaces()
        emit("Updated surfaces to level \(configuration.level.detail) (\(windows.count) window(s))")
    }

    func stop() {
        teardownAll()
        videoURL = nil
        emit("Stopped all surfaces")
    }

    func pause() {
        isUserPaused = true
        windows.values.forEach { $0.setPlaybackPaused(true) }
        emit("Paused \(windows.count) surface(s)")
    }

    func resume() {
        isUserPaused = false
        windows.values.forEach { $0.setPlaybackPaused(false) }
        emit("Resumed \(windows.count) surface(s)")
    }

    private func rebuildSurfaces() throws {
        guard let videoURL else { return }

        let screens = desiredScreens()
        var desired: [CGDirectDisplayID: NSScreen] = [:]
        for screen in screens {
            if let displayID = DisplayProbe.displayID(for: screen) {
                desired[displayID] = screen
            }
        }

        let staleIDs = windows.keys.filter { desired[$0] == nil }
        for displayID in staleIDs {
            if let window = windows.removeValue(forKey: displayID) {
                window.teardown()
                emit("Removed surface for disconnected or deselected display \(displayID)")
            }
        }

        for (displayID, screen) in desired {
            if let window = windows[displayID] {
                window.apply(screen: screen, configuration: configuration)
            } else {
                let window = try WallpaperSurfaceWindow(
                    screen: screen,
                    displayID: displayID,
                    videoURL: videoURL,
                    configuration: configuration
                )
                windows[displayID] = window
                window.present()
                if isUserPaused {
                    window.setPlaybackPaused(true)
                }
            }
        }

        if windows.isEmpty {
            throw SpikeError.playbackFailed("No display was available for the wallpaper surface")
        }
    }

    private func desiredScreens() -> [NSScreen] {
        switch configuration.target {
        case .mainDisplay:
            return NSScreen.main.map { [$0] } ?? Array(NSScreen.screens.prefix(1))
        case .allDisplays:
            return NSScreen.screens
        }
    }

    private func teardownAll() {
        for window in windows.values {
            window.teardown()
        }
        windows.removeAll()
    }

    private func registerObservers() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Log.surface.notice("Screen parameters changed; rebuilding surfaces")
                self.emit("Display configuration changed")
                do {
                    try self.rebuildSurfaces()
                } catch {
                    self.emit("Failed to rebuild surfaces: \(error.localizedDescription)")
                }
            }
            .store(in: &cancellables)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.screensDidSleepNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Log.surface.notice("Screens went to sleep; pausing playback")
                self.windows.values.forEach { $0.setPlaybackPaused(true) }
                self.emit("Display sleep: playback paused")
            }
            .store(in: &cancellables)

        workspace.publisher(for: NSWorkspace.screensDidWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Log.surface.notice("Screens woke")
                if !self.isUserPaused {
                    self.windows.values.forEach { $0.setPlaybackPaused(false) }
                    self.emit("Display wake: playback resumed")
                } else {
                    self.emit("Display wake: playback remains paused by user")
                }
            }
            .store(in: &cancellables)

        workspace.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Log.surface.notice("System will sleep; pausing playback")
                self.windows.values.forEach { $0.setPlaybackPaused(true) }
                self.emit("System sleep: playback paused")
            }
            .store(in: &cancellables)

        workspace.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Log.surface.notice("System woke")
                if !self.isUserPaused {
                    self.windows.values.forEach { $0.setPlaybackPaused(false) }
                    self.emit("System wake: playback resumed")
                } else {
                    self.emit("System wake: playback remains paused by user")
                }
            }
            .store(in: &cancellables)
    }

    private func emit(_ message: String) {
        Log.surface.notice("\(message, privacy: .public)")
        onEvent?(message)
    }
}
