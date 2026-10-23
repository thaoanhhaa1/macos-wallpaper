import AVFoundation
import Combine
import Foundation

@MainActor
final class SurfacePlayback {
    let player: AVQueuePlayer
    let url: URL
    private let looper: AVPlayerLooper
    private var cancellables = Set<AnyCancellable>()

    init(url: URL, muted: Bool) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SpikeError.unreadableVideo(url)
        }

        self.url = url
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        player = queue
        looper = AVPlayerLooper(player: queue, templateItem: item)

        queue.actionAtItemEnd = .none
        queue.preventsDisplaySleepDuringVideoPlayback = false
        queue.isMuted = muted
        queue.volume = muted ? 0 : 1

        let videoName = url.lastPathComponent
        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: nil)
            .receive(on: RunLoop.main)
            .sink { notification in
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                Log.playback.error(
                    "Playback failed for \(videoName, privacy: .public): \(error?.localizedDescription ?? "unknown", privacy: .public)"
                )
            }
            .store(in: &cancellables)

        Log.playback.notice("Created looping playback for \(videoName, privacy: .public)")
    }

    var currentTime: Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    var rate: Float { player.rate }
    var isPlaying: Bool { player.rate > 0 }
    var isMuted: Bool { player.isMuted }

    func play() {
        player.play()
        Log.playback.debug("play rate=\(self.player.rate, privacy: .public)")
    }

    func pause() {
        player.pause()
        Log.playback.debug("pause")
    }

    func setMuted(_ muted: Bool) {
        player.isMuted = muted
        player.volume = muted ? 0 : 1
    }

    func setVolume(_ volume: Float) {
        player.volume = max(0, min(1, volume))
    }

    func teardown() {
        cancellables.removeAll()
        player.pause()
        looper.disableLooping()
        player.removeAllItems()
        Log.playback.notice("Tore down playback for \(self.url.lastPathComponent, privacy: .public)")
    }
}
