import Foundation

struct ResourcePolicy: Equatable {
    var pauseOnFullscreen: Bool
    var pauseOnBattery: Bool

    init(playback: PlaybackSettings) {
        pauseOnFullscreen = playback.pauseOnFullscreen
        pauseOnBattery = playback.pauseOnBattery
    }

    static let `default` = ResourcePolicy(playback: PlaybackSettings())

    var summary: String {
        var rules: [String] = []
        if pauseOnFullscreen { rules.append("pause on fullscreen") }
        if pauseOnBattery { rules.append("pause on battery") }
        return rules.isEmpty ? "Always play while wallpaper is enabled" : rules.joined(separator: ", ")
    }
}
