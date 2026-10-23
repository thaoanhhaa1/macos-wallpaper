import AppKit
import AVFoundation
import CoreGraphics
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

    var windowLevel: NSWindow.Level {
        switch self {
        case .behindDesktopIcons:
            NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        case .normalOverlay:
            .normal
        }
    }

    var collectionBehavior: NSWindow.CollectionBehavior {
        [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
    }
}

extension ScalingMode {
    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .aspectFill, .centerCrop:
            .resizeAspectFill
        case .aspectFit:
            .resizeAspect
        }
    }
}
