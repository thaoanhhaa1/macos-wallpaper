import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class SurfacePlayback {
    private(set) var isPaused = false
    private(set) var loadedURL: URL?

    @ObservationIgnored private(set) var player: AVQueuePlayer?
    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var endToken: NSObjectProtocol?
    @ObservationIgnored private var isMuted = true
    @ObservationIgnored private var volume: Double = 0.5
    @ObservationIgnored private var isLooping = true

    var onFailure: ((String) -> Void)?

    func load(url: URL, settings: PlaybackSettings) throws {
        teardown()

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WallpaperSurfaceError.fileMissing(url.lastPathComponent)
        }

        loadedURL = url
        isMuted = settings.isMuted
        volume = Self.clamp(settings.volume)
        isLooping = settings.loopEnabled
        isPaused = false

        let queue = try makeQueue(url: url, settings: settings)
        player = queue
        installObservers(for: queue)
        queue.play()
    }

    func apply(_ settings: PlaybackSettings) throws {
        isMuted = settings.isMuted
        volume = Self.clamp(settings.volume)
        player?.isMuted = isMuted
        player?.volume = Float(volume)

        guard settings.loopEnabled != isLooping, let url = loadedURL else { return }

        let wasPaused = isPaused
        try load(url: url, settings: settings)
        setPaused(wasPaused)
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        if paused {
            player?.pause()
        } else {
            player?.play()
        }
    }

    func teardown() {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()

        if let endToken {
            NotificationCenter.default.removeObserver(endToken)
        }
        endToken = nil

        player?.pause()
        looper?.disableLooping()
        player?.removeAllItems()
        player = nil
        looper = nil
        loadedURL = nil
        isPaused = false
    }

    private func makeQueue(url: URL, settings: PlaybackSettings) throws -> AVQueuePlayer {
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        queue.actionAtItemEnd = settings.loopEnabled ? .none : .pause
        queue.automaticallyWaitsToMinimizeStalling = false
        queue.preventsDisplaySleepDuringVideoPlayback = false
        queue.isMuted = settings.isMuted
        queue.volume = Float(Self.clamp(settings.volume))

        if settings.loopEnabled {
            let looper = AVPlayerLooper(player: queue, templateItem: item)
            if let error = looper.error {
                queue.removeAllItems()
                throw WallpaperSurfaceError.playback(error.localizedDescription)
            }
            self.looper = looper
        } else {
            queue.insert(item, after: nil)
            endToken = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.isPaused = true
                    Log.playback.info("Wallpaper surface reached the end; loop is disabled")
                }
            }
        }

        return queue
    }

    private func installObservers(for player: AVQueuePlayer) {
        let center = NotificationCenter.default

        notificationTokens.append(center.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let message = error?.localizedDescription
                ?? "The wallpaper video stopped unexpectedly."
            Task { @MainActor in
                guard let self, self.owns(notification.object) else { return }
                self.onFailure?(message)
            }
        })

        notificationTokens.append(center.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self, self.owns(notification.object), !self.isPaused else { return }
                Log.playback.error("Wallpaper surface playback stalled")
                self.player?.play()
            }
        })
    }

    private func owns(_ object: Any?) -> Bool {
        guard let item = object as? AVPlayerItem, let player else { return false }
        if player.currentItem === item { return true }
        return player.items().contains { $0 === item }
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(0, value), 1)
    }
}
