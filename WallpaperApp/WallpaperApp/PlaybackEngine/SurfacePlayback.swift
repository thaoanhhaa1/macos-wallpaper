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
    @ObservationIgnored private var settings = PlaybackSettings()
    @ObservationIgnored private var retryAttempt = 0
    @ObservationIgnored private var isRetrying = false
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryResetTask: Task<Void, Never>?

    private let maxRetryAttempts = 2

    var onFailure: ((String) -> Void)?

    func load(url: URL, settings: PlaybackSettings) throws {
        let shouldStartPaused = isPaused
        teardown()

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WallpaperSurfaceError.fileMissing(url.lastPathComponent)
        }

        loadedURL = url
        self.settings = settings
        isMuted = settings.isMuted
        volume = Self.clamp(settings.volume)
        isLooping = settings.loopEnabled
        isPaused = false

        let queue = try makeQueue(url: url, settings: settings)
        player = queue
        installObservers(for: queue)
        if shouldStartPaused {
            setPaused(true)
        } else {
            queue.play()
        }
        scheduleRetryReset()
    }

    func apply(_ settings: PlaybackSettings) throws {
        guard settings != self.settings else { return }

        let loopChanged = settings.loopEnabled != isLooping
        self.settings = settings
        isMuted = settings.isMuted
        volume = Self.clamp(settings.volume)
        player?.isMuted = isMuted
        player?.volume = Float(volume)

        guard loopChanged, let url = loadedURL else { return }

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

    func droppedFrameStats() -> DroppedFrameStats {
        guard let events = player?.currentItem?.accessLog()?.events, !events.isEmpty else {
            return .zero
        }

        return events.reduce(.zero) { result, event in
            DroppedFrameStats(
                droppedFrames: result.droppedFrames + event.numberOfDroppedVideoFrames,
                stalls: result.stalls + event.numberOfStalls,
                observedBitrate: event.observedBitrate > 0
                    ? event.observedBitrate
                    : result.observedBitrate,
                indicatedBitrate: event.indicatedBitrate > 0
                    ? event.indicatedBitrate
                    : result.indicatedBitrate,
                mediaRequests: result.mediaRequests + event.numberOfMediaRequests
            )
        }
    }

    func teardown() {
        retryTask?.cancel()
        retryTask = nil
        retryResetTask?.cancel()
        retryResetTask = nil
        isRetrying = false

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
                self.handlePlaybackFailure(message)
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

    private func handlePlaybackFailure(_ message: String) {
        guard !isRetrying else { return }
        guard retryAttempt < maxRetryAttempts, let url = loadedURL else {
            failPermanently(message)
            return
        }

        retryAttempt += 1
        isRetrying = true
        let attempt = retryAttempt
        Log.playback.error(
            "Wallpaper playback failed; retry \(attempt, privacy: .public)/\(self.maxRetryAttempts, privacy: .public): \(message, privacy: .public)"
        )

        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
            guard let self, !Task.isCancelled else { return }

            do {
                try self.load(url: url, settings: self.settings)
                self.isRetrying = false
            } catch {
                self.isRetrying = false
                self.failPermanently(error.localizedDescription)
            }
        }
    }

    private func failPermanently(_ message: String) {
        retryTask?.cancel()
        retryTask = nil
        retryResetTask?.cancel()
        retryResetTask = nil
        isRetrying = false
        Log.playback.error("Wallpaper playback exhausted retries: \(message, privacy: .public)")
        onFailure?(message)
    }

    private func scheduleRetryReset() {
        retryResetTask?.cancel()
        retryResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.retryAttempt = 0
        }
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
