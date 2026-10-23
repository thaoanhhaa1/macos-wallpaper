import AppKit
import AVFoundation
import CoreGraphics

enum SurfaceTarget: String, CaseIterable, Identifiable, Codable {
    case mainDisplay
    case allDisplays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mainDisplay: return "Main display"
        case .allDisplays: return "All displays"
        }
    }
}

enum SurfaceLevelStrategy: String, CaseIterable, Identifiable, Codable {
    case belowDesktopIcons
    case aboveDesktopPicture
    case justBelowNormal
    case normal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .belowDesktopIcons: return "Below desktop icons (recommended probe)"
        case .aboveDesktopPicture: return "Above desktop picture"
        case .justBelowNormal: return "Just below normal windows"
        case .normal: return "Normal window level"
        }
    }

    var detail: String {
        switch self {
        case .belowDesktopIcons:
            return "desktopIconWindow - 1"
        case .aboveDesktopPicture:
            return "desktopWindow + 1"
        case .justBelowNormal:
            return "normal - 1"
        case .normal:
            return "normal"
        }
    }

    var windowLevel: NSWindow.Level {
        switch self {
        case .belowDesktopIcons:
            return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        case .aboveDesktopPicture:
            return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        case .justBelowNormal:
            return NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        case .normal:
            return .normal
        }
    }
}

enum ScalingMode: String, CaseIterable, Identifiable, Codable {
    case fit
    case fill

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit: return "Aspect fit"
        case .fill: return "Aspect fill"
        }
    }

    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .fit: return .resizeAspect
        case .fill: return .resizeAspectFill
        }
    }
}

struct SpikeConfiguration: Equatable {
    var target: SurfaceTarget = .mainDisplay
    var level: SurfaceLevelStrategy = .belowDesktopIcons
    var scalingMode: ScalingMode = .fill
    var clickThrough: Bool = true
    var muted: Bool = true
}

enum SpikeError: LocalizedError {
    case noVideoSelected
    case unreadableVideo(URL)
    case noVideoTrack(URL)
    case playbackFailed(String)
    case testVideoGenerationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoSelected:
            return "No video has been selected."
        case .unreadableVideo(let url):
            return "The file is missing or not readable: \(url.lastPathComponent)"
        case .noVideoTrack(let url):
            return "The file has no playable video track: \(url.lastPathComponent)"
        case .playbackFailed(let message):
            return "Playback failed: \(message)"
        case .testVideoGenerationFailed(let message):
            return "Could not generate the test video: \(message)"
        }
    }
}
