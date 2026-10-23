import Foundation

enum WallpaperSurfaceStrategy: String, Codable, CaseIterable, Identifiable {
    case behindDesktopIcons
    case normalOverlay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .behindDesktopIcons: "Behind desktop icons"
        case .normalOverlay: "Normal-level overlay"
        }
    }

    var detail: String {
        switch self {
        case .behindDesktopIcons:
            "Borderless desktop-level window at desktopIconWindow − 1. Verified in Phase 0."
        case .normalOverlay:
            "Click-through overlay above desktop icons. Fallback when the preferred surface is unavailable."
        }
    }
}
