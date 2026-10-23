import Foundation

enum PlaybackState: Equatable {
    case idle
    case preparing
    case playing
    case paused
    case failed(String)

    var title: String {
        switch self {
        case .idle: "Idle"
        case .preparing: "Preparing"
        case .playing: "Playing"
        case .paused: "Paused"
        case .failed: "Failed"
        }
    }

    var failureReason: String? {
        guard case .failed(let reason) = self else { return nil }
        return reason
    }
}
