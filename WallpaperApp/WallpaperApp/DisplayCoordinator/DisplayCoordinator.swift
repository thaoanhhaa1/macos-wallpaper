import AppKit
import CoreGraphics

struct DisplayInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let persistentID: String
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect
    let backingScaleFactor: CGFloat
    let isMain: Bool
    let isBuiltIn: Bool
    let mirrorsDisplayID: CGDirectDisplayID?

    init(screen: NSScreen, isMain: Bool) {
        id = Self.displayID(for: screen)
        if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
            persistentID = CFUUIDCreateString(nil, uuid) as String
        } else {
            persistentID = "display-\(id)"
        }
        name = screen.localizedName
        frame = screen.frame
        visibleFrame = screen.visibleFrame
        backingScaleFactor = screen.backingScaleFactor
        isBuiltIn = CGDisplayIsBuiltin(id) != 0
        let mirroredDisplayID = CGDisplayMirrorsDisplay(id)
        mirrorsDisplayID = mirroredDisplayID == 0 ? nil : mirroredDisplayID
        self.isMain = isMain
    }

    var isMirrored: Bool { mirrorsDisplayID != nil }

    var summary: String {
        "\(Int(frame.width)) × \(Int(frame.height)) @ \(String(format: "%.1f", backingScaleFactor))×"
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[screenNumberKey] as? NSNumber)?.uint32Value ?? 0
    }
}

struct DisconnectedDisplayConfiguration: Identifiable, Equatable {
    let persistentID: String
    let configuration: DisplayWallpaperConfiguration

    var id: String { persistentID }
}

@MainActor
final class DisplayCoordinator {
    var onChange: (([DisplayInfo]) -> Void)?

    private var screenObserver: NSObjectProtocol?

    func currentDisplays() -> [DisplayInfo] {
        let mainDisplayID = NSScreen.main.map(DisplayInfo.displayID(for:))
        return NSScreen.screens.map { screen in
            DisplayInfo(
                screen: screen,
                isMain: DisplayInfo.displayID(for: screen) == mainDisplayID
            )
        }
    }

    func start() {
        guard screenObserver == nil else { return }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.publish()
            }
        }
    }

    func stop() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
    }

    private func publish() {
        let displays = currentDisplays()
        let ids = displays.map(\.persistentID).joined(separator: ",")
        Log.display.info(
            "Display configuration changed count=\(displays.count, privacy: .public) ids=\(ids, privacy: .public)"
        )
        onChange?(displays)
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }
}
