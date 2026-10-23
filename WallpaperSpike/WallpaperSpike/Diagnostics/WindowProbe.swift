import AppKit
import CoreGraphics

struct WindowInfo: Codable, Identifiable, Equatable {
    let orderIndex: Int
    let windowNumber: Int
    let ownerName: String?
    let ownerPID: Int
    let windowName: String?
    let layer: Int
    let bounds: RectInfo
    let isOnScreen: Bool
    let alpha: Double
    let sharingState: Int

    var id: Int { windowNumber }

    var summary: String {
        let owner = ownerName ?? "unknown"
        let name = windowName.map { " \"\($0)\"" } ?? ""
        return "#\(orderIndex) \(owner)\(name) layer=\(layer) bounds=\(bounds.displayString) alpha=\(String(format: "%.2f", alpha)) sharing=\(sharingState)"
    }

    func intersects(_ other: RectInfo) -> Bool {
        let lhs = CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
        let rhs = CGRect(x: other.x, y: other.y, width: other.width, height: other.height)
        return lhs.intersects(rhs)
    }
}

struct WindowOrderAnalysis: Codable {
    var surfaceWindowNumber: Int
    var surfaceFound: Bool
    var surfaceLayer: Int?
    var surfaceOrderIndex: Int?
    var surfaceIsOnScreen: Bool?
    var surfaceBounds: RectInfo?
    var desktopWindowLevel: Int
    var desktopIconWindowLevel: Int
    var expectedLevelForBelowIcons: Int
    var iconWindowsOverlappingSurface: [WindowInfo]
    var systemWallpaperWindows: [WindowInfo]
    var desktopStack: [WindowInfo]
    var isBehindDesktopIcons: Bool?
    var isAboveSystemWallpaper: Bool?
    var explanation: String
}

@MainActor
enum WindowProbe {
    static var desktopWindowLevel: Int { Int(CGWindowLevelForKey(.desktopWindow)) }
    static var desktopIconWindowLevel: Int { Int(CGWindowLevelForKey(.desktopIconWindow)) }

    static func snapshot() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly]
        guard let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return rawList.enumerated().map { index, raw in
            let bounds = parseBounds(raw[kCGWindowBounds as String])
            return WindowInfo(
                orderIndex: index,
                windowNumber: (raw[kCGWindowNumber as String] as? NSNumber)?.intValue ?? -1,
                ownerName: raw[kCGWindowOwnerName as String] as? String,
                ownerPID: (raw[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? -1,
                windowName: raw[kCGWindowName as String] as? String,
                layer: (raw[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                bounds: bounds,
                isOnScreen: (raw[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true,
                alpha: (raw[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                sharingState: (raw[kCGWindowSharingState as String] as? NSNumber)?.intValue ?? -1
            )
        }
    }

    static func analyze(surfaceWindowNumber: Int, snapshot: [WindowInfo]) -> WindowOrderAnalysis {
        let surface = snapshot.first { $0.windowNumber == surfaceWindowNumber }
        let desktopLevel = desktopWindowLevel
        let iconLevel = desktopIconWindowLevel

        let iconWindows: [WindowInfo]
        let wallpaperWindows: [WindowInfo]
        let desktopStack: [WindowInfo]

        if let surface {
            iconWindows = snapshot.filter {
                $0.layer == iconLevel && $0.intersects(surface.bounds)
            }
            wallpaperWindows = snapshot.filter {
                $0.windowNumber != surface.windowNumber
                    && $0.layer <= desktopLevel
                    && $0.bounds.width > 0
                    && $0.bounds.height > 0
            }
            desktopStack = snapshot.filter {
                $0.layer < 0 || $0.windowNumber == surface.windowNumber || $0.layer == iconLevel
            }
        } else {
            iconWindows = snapshot.filter { $0.layer == iconLevel }
            wallpaperWindows = snapshot.filter {
                $0.layer <= desktopLevel && $0.bounds.width > 0 && $0.bounds.height > 0
            }
            desktopStack = snapshot.filter { $0.layer < 0 }
        }

        let frontmostIconIndex = iconWindows.map(\.orderIndex).min()
        let isBehindIcons: Bool?
        if let surface, let frontmostIconIndex {
            isBehindIcons = surface.orderIndex > frontmostIconIndex
        } else {
            isBehindIcons = nil
        }

        let frontmostWallpaperIndex = wallpaperWindows.map(\.orderIndex).min()
        let isAboveWallpaper: Bool?
        if let surface, let frontmostWallpaperIndex {
            isAboveWallpaper = surface.orderIndex < frontmostWallpaperIndex
        } else if let surface {
            isAboveWallpaper = surface.layer > desktopLevel
        } else {
            isAboveWallpaper = nil
        }

        var explanationParts: [String] = []
        if let surface {
            explanationParts.append("surface layer=\(surface.layer) order=\(surface.orderIndex)")
        } else {
            explanationParts.append("surface #\(surfaceWindowNumber) was not found in the on-screen window list")
        }
        if let frontmostIconIndex {
            explanationParts.append("frontmost desktop-icon window order=\(frontmostIconIndex)")
        } else {
            explanationParts.append("no desktop-icon window at layer \(iconLevel) was found")
        }
        if let isBehindIcons {
            explanationParts.append(isBehindIcons ? "surface is BELOW desktop icons" : "surface is ABOVE desktop icons")
        }
        if let isAboveWallpaper {
            explanationParts.append(isAboveWallpaper ? "surface is ABOVE the system wallpaper" : "surface is BELOW the system wallpaper")
        }
        if surface != nil, wallpaperWindows.isEmpty {
            explanationParts.append("no system wallpaper windows were exposed; verdict uses layer comparison")
        }

        return WindowOrderAnalysis(
            surfaceWindowNumber: surfaceWindowNumber,
            surfaceFound: surface != nil,
            surfaceLayer: surface?.layer,
            surfaceOrderIndex: surface?.orderIndex,
            surfaceIsOnScreen: surface?.isOnScreen,
            surfaceBounds: surface?.bounds,
            desktopWindowLevel: desktopLevel,
            desktopIconWindowLevel: iconLevel,
            expectedLevelForBelowIcons: iconLevel - 1,
            iconWindowsOverlappingSurface: iconWindows,
            systemWallpaperWindows: wallpaperWindows,
            desktopStack: desktopStack,
            isBehindDesktopIcons: isBehindIcons,
            isAboveSystemWallpaper: isAboveWallpaper,
            explanation: explanationParts.joined(separator: "; ")
        )
    }

    static func reportText(for analysis: WindowOrderAnalysis) -> String {
        var lines: [String] = []
        lines.append("Window ordering: \(analysis.explanation)")
        lines.append("levels: desktopWindow=\(analysis.desktopWindowLevel), desktopIconWindow=\(analysis.desktopIconWindowLevel), below-icons target=\(analysis.expectedLevelForBelowIcons)")

        if analysis.iconWindowsOverlappingSurface.isEmpty {
            lines.append("Desktop icon windows: none visible at icon level")
        } else {
            lines.append("Desktop icon windows over the surface:")
            lines.append(contentsOf: analysis.iconWindowsOverlappingSurface.map { "  " + $0.summary })
        }

        if analysis.systemWallpaperWindows.isEmpty {
            lines.append("System wallpaper windows: none found at desktop level")
        } else {
            lines.append("System wallpaper windows:")
            lines.append(contentsOf: analysis.systemWallpaperWindows.map { "  " + $0.summary })
        }

        lines.append("Desktop-level stack (front to back):")
        lines.append(contentsOf: analysis.desktopStack.map { "  " + $0.summary })
        return lines.joined(separator: "\n")
    }

    private static func parseBounds(_ value: Any?) -> RectInfo {
        guard let dictionary = value as? [String: Any] else {
            return RectInfo(.zero)
        }
        let x = (dictionary["X"] as? NSNumber)?.doubleValue ?? 0
        let y = (dictionary["Y"] as? NSNumber)?.doubleValue ?? 0
        let width = (dictionary["Width"] as? NSNumber)?.doubleValue ?? 0
        let height = (dictionary["Height"] as? NSNumber)?.doubleValue ?? 0
        return RectInfo(NSRect(x: x, y: y, width: width, height: height))
    }
}
