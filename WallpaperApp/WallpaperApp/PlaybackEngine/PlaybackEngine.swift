import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class PlaybackEngine {
    private(set) var state: PlaybackState = .idle
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isMuted = true
    private(set) var volume: Double = 0.5
    private(set) var isLooping = true
    private(set) var loadedURL: URL?

    @ObservationIgnored private(set) var player: AVQueuePlayer?
    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var timeObserverToken: Any?
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var playbackEndedToken: NSObjectProtocol?

    var isPlaying: Bool { state == .playing }
    var hasLoadedMedia: Bool { loadedURL != nil }

    func apply(_ settings: PlaybackSettings) {
        setMuted(settings.isMuted)
        setVolume(settings.volume)
        setLoopEnabled(settings.loopEnabled)
    }

    func load(
        url: URL,
        duration: TimeInterval,
        settings: PlaybackSettings,
        autoplay: Bool,
        startAt: Double = 0
    ) throws {
        teardown()

        isMuted = settings.isMuted
        volume = Self.clamp(settings.volume)
        isLooping = settings.loopEnabled
        state = .preparing

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
                state = .failed(error.localizedDescription)
                Log.playback.error("Failed to create looper: \(error.localizedDescription, privacy: .public)")
                throw error
            }
            self.looper = looper
        } else {
            queue.insert(item, after: nil)
            playbackEndedToken = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.handlePlaybackEnded()
                }
            }
        }

        player = queue
        loadedURL = url
        self.duration = max(0, duration)
        currentTime = min(max(0, startAt), self.duration)
        installObservers(for: queue)

        if currentTime > 0 {
            queue.seek(
                to: CMTime(seconds: currentTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }

        if autoplay {
            play()
        } else {
            state = .paused
        }

        Log.playback.notice(
            "Loaded \(url.lastPathComponent, privacy: .public) duration=\(self.duration, privacy: .public) loop=\(settings.loopEnabled, privacy: .public) autoplay=\(autoplay, privacy: .public)"
        )
    }

    func play() {
        guard let player else { return }
        if case .failed = state { return }
        player.play()
        state = .playing
        Log.playback.debug("play rate=\(player.rate, privacy: .public)")
    }

    func pause() {
        guard let player else { return }
        player.pause()
        if state == .playing {
            state = .paused
        }
        Log.playback.debug("pause")
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        let target = min(max(0, seconds), duration)
        currentTime = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        Log.playback.debug("seek to \(target, privacy: .public)")
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        player?.isMuted = muted
    }

    func setVolume(_ value: Double) {
        volume = Self.clamp(value)
        player?.volume = Float(volume)
    }

    func setLoopEnabled(_ enabled: Bool) {
        guard enabled != isLooping else { return }
        isLooping = enabled

        guard let url = loadedURL else { return }
        let resumeTime = currentTime
        let wasPlaying = isPlaying
        let settings = PlaybackSettings(
            isMuted: isMuted,
            volume: volume,
            loopEnabled: enabled
        )

        do {
            try load(
                url: url,
                duration: duration,
                settings: settings,
                autoplay: wasPlaying,
                startAt: resumeTime
            )
        } catch {
            state = .failed(error.localizedDescription)
            Log.playback.error(
                "Loop reload failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func teardown() {
        let wasLoaded = loadedURL != nil

        if let player, let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
        }
        timeObserverToken = nil

        if let playbackEndedToken {
            NotificationCenter.default.removeObserver(playbackEndedToken)
        }
        playbackEndedToken = nil

        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()

        player?.pause()
        looper?.disableLooping()
        player?.removeAllItems()
        player = nil
        looper = nil
        loadedURL = nil
        state = .idle
        currentTime = 0
        duration = 0

        if wasLoaded {
            Log.playback.notice("Tore down playback")
        }
    }

    private func installObservers(for player: AVQueuePlayer) {
        let center = NotificationCenter.default

        notificationTokens.append(center.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in
                self?.handleFailure(error)
            }
        })

        notificationTokens.append(center.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                Log.playback.error("Playback stalled")
                self?.player?.play()
            }
        })

        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            Task { @MainActor in
                self?.currentTime = seconds
            }
        }
    }

    private func handlePlaybackEnded() {
        player?.pause()
        state = .paused
        Log.playback.info("Playback reached the end; loop is disabled")
    }

    private func handleFailure(_ error: Error?) {
        let reason = error?.localizedDescription
            ?? "The video stopped unexpectedly. The codec may be unsupported."
        state = .failed(reason)
        player?.pause()
        Log.playback.error("Playback failed: \(reason, privacy: .public)")
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(0, value), 1)
    }
}
