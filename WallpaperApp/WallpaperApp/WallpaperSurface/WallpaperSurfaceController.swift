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
            "No display has a wallpaper assigned."
        case .playback(let message):
            "The wallpaper couldn't start playing: \(message)"
        }
    }
}

struct WallpaperSurfaceMedia: Equatable, Identifiable {
    let identifier: UUID
    let url: URL
    let displayName: String

    var id: UUID { identifier }
}

@MainActor
@Observable
final class WallpaperSurfaceController {
    private(set) var state: WallpaperSurfaceState = .inactive
    private(set) var surfaceCount = 0
    private(set) var appliedMediaName: String?
    private(set) var isActive = false
    private(set) var appliedDisplayIDs: [CGDirectDisplayID] = []
    private(set) var appliedDisplayPersistentIDs: Set<String> = []
    private(set) var appliedMediaIdentifiers: Set<UUID> = []
    private(set) var surfaceMediaNames: [String: String] = [:]
    private(set) var isUserPaused = false
    private(set) var policyPauseReasons: Set<ResourcePauseReason> = []

    @ObservationIgnored private(set) var playback: SurfacePlayback?
    @ObservationIgnored private var playbacks: [UUID: PlaybackSlot] = [:]
    @ObservationIgnored private var windows: [CGDirectDisplayID: WallpaperSurfaceWindow] = [:]
    @ObservationIgnored private var windowMediaIDs: [CGDirectDisplayID: UUID] = [:]
    @ObservationIgnored private var settings = PlaybackSettings()
    @ObservationIgnored private var displayMode: DisplayMode = .mainScreen
    @ObservationIgnored private var observerTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var isObserving = false

    let strategy: WallpaperSurfaceStrategy

    init(strategy: WallpaperSurfaceStrategy = .behindDesktopIcons) {
        self.strategy = strategy
    }

    private struct PlaybackSlot {
        let media: WallpaperSurfaceMedia
        let playback: SurfacePlayback
    }

    private struct DesiredSurface {
        let displayID: CGDirectDisplayID
        let persistentID: String
        let screen: NSScreen
        let media: WallpaperSurfaceMedia
    }

    var isPaused: Bool {
        !playbacks.isEmpty && playbacks.values.allSatisfy(\.playback.isPaused)
    }

    var isPolicyPaused: Bool {
        !policyPauseReasons.isEmpty
    }

    var playerCount: Int {
        playbacks.count
    }

    var droppedFrameStats: DroppedFrameStats {
        playbacks.values.reduce(.zero) { result, slot in
            result + slot.playback.droppedFrameStats()
        }
    }

    var appliedDisplayMode: DisplayMode {
        displayMode
    }

    var surfaceWindowNumbers: [Int] {
        windows.values.map(\.windowNumber)
    }

    func apply(
        assignments: [String: WallpaperSurfaceMedia],
        settings: PlaybackSettings,
        displayMode: DisplayMode
    ) throws {
        let desired = desiredSurfaces(for: assignments)
        guard !desired.isEmpty else {
            throw WallpaperSurfaceError.noDisplay
        }

        var mediaByID: [UUID: WallpaperSurfaceMedia] = [:]
        for surface in desired.values {
            mediaByID[surface.media.identifier] = surface.media
        }

        var prepared: [UUID: SurfacePlayback] = [:]
        do {
            for (mediaID, media) in mediaByID {
                if let slot = playbacks[mediaID], slot.media == media {
                    continue
                }
                let playback = SurfacePlayback()
                playback.onFailure = { [weak self] message in
                    self?.handlePlaybackFailure(message)
                }
                try playback.load(url: media.url, settings: settings)
                prepared[mediaID] = playback
            }
        } catch {
            for playback in prepared.values {
                playback.onFailure = nil
                playback.teardown()
            }
            Log.surface.error(
                "Failed to prepare wallpaper media: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }

        let neededIDs = Set(mediaByID.keys)
        for mediaID in Array(playbacks.keys) where !neededIDs.contains(mediaID) {
            if let slot = playbacks.removeValue(forKey: mediaID) {
                slot.playback.onFailure = nil
                slot.playback.teardown()
            }
        }

        for (mediaID, playback) in prepared {
            if let existing = playbacks[mediaID] {
                existing.playback.onFailure = nil
                existing.playback.teardown()
            }
            guard let media = mediaByID[mediaID] else {
                playback.onFailure = nil
                playback.teardown()
                continue
            }
            playbacks[mediaID] = PlaybackSlot(media: media, playback: playback)
        }

        do {
            for slot in playbacks.values where prepared[slot.media.identifier] == nil {
                try slot.playback.apply(settings)
            }
        } catch {
            teardownSurfaces(resetApplied: true)
            state = .failed(error.localizedDescription)
            Log.surface.error(
                "Failed to update wallpaper playback settings: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }

        self.settings = settings
        self.displayMode = displayMode

        let staleDisplayIDs = windows.keys.filter { desired[$0] == nil }
        for displayID in staleDisplayIDs {
            if let window = windows.removeValue(forKey: displayID) {
                window.teardown()
                Log.surface.info(
                    "Removed surface for display \(displayID, privacy: .public)"
                )
            }
            windowMediaIDs.removeValue(forKey: displayID)
        }

        for (displayID, surface) in desired {
            let mediaID = surface.media.identifier
            guard let playback = playbacks[mediaID]?.playback,
                  let player = playback.player else {
                continue
            }

            if let window = windows[displayID] {
                window.update(screen: surface.screen, settings: settings, strategy: strategy)
                window.setPlayer(player)
            } else {
                let window = WallpaperSurfaceWindow(
                    screen: surface.screen,
                    displayID: displayID,
                    player: player,
                    settings: settings,
                    strategy: strategy
                )
                windows[displayID] = window
                window.present()
            }
            windowMediaIDs[displayID] = mediaID
        }

        self.playback = playbacks.values.first?.playback
        appliedDisplayIDs = Array(windows.keys)
        appliedDisplayPersistentIDs = Set(desired.values.map(\.persistentID))
        appliedMediaIdentifiers = Set(desired.values.map(\.media.identifier))
        surfaceMediaNames = Dictionary(
            uniqueKeysWithValues: desired.values.map { ($0.persistentID, $0.media.displayName) }
        )
        let uniqueNames = Set(desired.values.map(\.media.displayName))
        appliedMediaName = uniqueNames.count == 1
            ? uniqueNames.first
            : "\(uniqueNames.count) videos"
        isActive = true
        surfaceCount = windows.count
        state = .active
        installObserversIfNeeded()
        applyEffectivePause()

        Log.surface.notice(
            "Applied wallpaper media=\(uniqueNames.count, privacy: .public) surfaces=\(self.surfaceCount, privacy: .public) mode=\(displayMode.rawValue, privacy: .public) level=\(self.strategy.windowLevel.rawValue, privacy: .public)"
        )
    }

    func remove() {
        guard isActive || state.failureReason != nil else { return }
        teardownSurfaces(resetApplied: true)
        state = .inactive
        isUserPaused = false
        Log.surface.notice("Removed wallpaper surfaces")
    }

    func shutdown() {
        teardownSurfaces(resetApplied: true)
        state = .inactive
        isUserPaused = false
        policyPauseReasons = []
        removeObservers()
    }

    func play() {
        guard isActive else { return }
        isUserPaused = false
        applyEffectivePause()
    }

    func pause() {
        guard isActive else { return }
        isUserPaused = true
        applyEffectivePause()
    }

    func togglePlayback() {
        guard isActive else { return }

        if !isPaused {
            isUserPaused = true
        } else if isUserPaused {
            isUserPaused = false
        } else if isPolicyPaused {
            return
        }

        applyEffectivePause()
    }

    func setResourcePauseReasons(_ reasons: Set<ResourcePauseReason>) {
        guard reasons != policyPauseReasons else { return }
        policyPauseReasons = reasons
        applyEffectivePause()

        if reasons.isEmpty {
            Log.policy.notice("Resource policy resumed wallpaper playback")
        } else {
            let summary = reasons
                .sorted { $0.title < $1.title }
                .map(\.title)
                .joined(separator: ", ")
            Log.policy.notice("Resource policy paused wallpaper: \(summary, privacy: .public)")
        }
    }

    func update(settings: PlaybackSettings) {
        self.settings = settings
        guard isActive else { return }

        for window in windows.values {
            window.update(settings: settings)
        }

        do {
            for slot in playbacks.values {
                try slot.playback.apply(settings)
            }
        } catch {
            handlePlaybackFailure(error.localizedDescription)
            return
        }

        for (displayID, mediaID) in windowMediaIDs {
            guard let player = playbacks[mediaID]?.playback.player else { continue }
            windows[displayID]?.setPlayer(player)
        }

        applyEffectivePause()
    }

    private func applyEffectivePause() {
        guard isActive else { return }
        let shouldPause = isUserPaused || !policyPauseReasons.isEmpty
        for slot in playbacks.values {
            slot.playback.setPaused(shouldPause)
        }
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

    private func desiredSurfaces(
        for assignments: [String: WallpaperSurfaceMedia]
    ) -> [CGDirectDisplayID: DesiredSurface] {
        let mainDisplayID = NSScreen.main.map(DisplayInfo.displayID(for:))
        var desired: [CGDirectDisplayID: DesiredSurface] = [:]

        for screen in NSScreen.screens {
            let info = DisplayInfo(
                screen: screen,
                isMain: DisplayInfo.displayID(for: screen) == mainDisplayID
            )
            guard !info.isMirrored else {
                Log.display.info(
                    "Skipping mirrored display \(info.persistentID, privacy: .public)"
                )
                continue
            }
            guard let media = assignments[info.persistentID] else { continue }
            desired[info.id] = DesiredSurface(
                displayID: info.id,
                persistentID: info.persistentID,
                screen: screen,
                media: media
            )
        }

        return desired
    }

    private func teardownSurfaces(resetApplied: Bool) {
        teardownWindows()

        for slot in playbacks.values {
            slot.playback.onFailure = nil
            slot.playback.teardown()
        }
        playbacks.removeAll()
        playback = nil
        isActive = false
        surfaceCount = 0
        appliedDisplayIDs = []
        appliedDisplayPersistentIDs = []
        appliedMediaIdentifiers = []
        surfaceMediaNames = [:]
        windowMediaIDs = [:]
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

    deinit {
        let center = NotificationCenter.default
        for token in observerTokens {
            center.removeObserver(token)
        }
    }
}
