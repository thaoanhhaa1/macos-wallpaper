import Foundation

enum WallpaperStatus: Equatable {
    case noWallpaper
    case playing
    case paused
    case error(String)

    var title: String {
        switch self {
        case .noWallpaper: "No Wallpaper"
        case .playing: "Playing"
        case .paused: "Paused"
        case .error: "Error"
        }
    }

    var symbolName: String {
        switch self {
        case .noWallpaper: "photo.on.rectangle"
        case .playing: "play.rectangle.fill"
        case .paused: "pause.rectangle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var errorMessage: String? {
        guard case .error(let message) = self else { return nil }
        return message
    }
}

extension WallpaperSurfaceState {
    var title: String {
        switch self {
        case .inactive: "Not Applied"
        case .active: "Applied"
        case .failed: "Error"
        }
    }

    var symbolName: String {
        switch self {
        case .inactive: "display"
        case .active: "play.rectangle.on.rectangle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}
