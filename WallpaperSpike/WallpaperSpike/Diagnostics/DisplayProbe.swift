import AppKit
import CoreGraphics

struct RectInfo: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: NSRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }

    var displayString: String {
        String(format: "%.0f,%.0f %.0fx%.0f", x, y, width, height)
    }
}

struct DisplayInfo: Codable, Equatable, Identifiable {
    let displayID: UInt32
    let name: String
    let isMain: Bool
    let isBuiltin: Bool
    let frame: RectInfo
    let visibleFrame: RectInfo
    let backingScaleFactor: Double
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double?

    var id: UInt32 { displayID }

    var summary: String {
        let builtin = isBuiltin ? "built-in" : "external"
        let refresh = refreshRate.map { String(format: "%.0f Hz", $0) } ?? "unknown Hz"
        return "\(name) [\(displayID)] \(builtin) · \(pixelWidth)x\(pixelHeight) px · scale \(backingScaleFactor)x · \(refresh) · frame \(frame.displayString)"
    }
}

@MainActor
enum DisplayProbe {
    static func currentScreens() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let displayID = displayID(for: screen) else { return nil }
            let mode = CGDisplayCopyDisplayMode(displayID)
            return DisplayInfo(
                displayID: displayID,
                name: screen.localizedName,
                isMain: screen == NSScreen.main,
                isBuiltin: CGDisplayIsBuiltin(displayID) != 0,
                frame: RectInfo(screen.frame),
                visibleFrame: RectInfo(screen.visibleFrame),
                backingScaleFactor: screen.backingScaleFactor,
                pixelWidth: mode?.pixelWidth ?? Int(screen.frame.width * screen.backingScaleFactor),
                pixelHeight: mode?.pixelHeight ?? Int(screen.frame.height * screen.backingScaleFactor),
                refreshRate: mode?.refreshRate
            )
        }
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { self.displayID(for: $0) == displayID }
    }

    static var screenSummary: String {
        currentScreens().map(\.summary).joined(separator: "\n")
    }
}
