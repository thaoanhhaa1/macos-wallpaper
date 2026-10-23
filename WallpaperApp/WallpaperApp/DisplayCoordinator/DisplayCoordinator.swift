import AppKit

struct DisplayInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect
    let backingScaleFactor: CGFloat
    let isMain: Bool

    init(screen: NSScreen, isMain: Bool) {
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        id = (screen.deviceDescription[screenNumberKey] as? NSNumber)?.uint32Value ?? 0
        name = screen.localizedName
        frame = screen.frame
        visibleFrame = screen.visibleFrame
        backingScaleFactor = screen.backingScaleFactor
        self.isMain = isMain
    }

    var summary: String {
        "\(Int(frame.width)) × \(Int(frame.height)) @ \(String(format: "%.1f", backingScaleFactor))×"
    }
}

@MainActor
final class DisplayCoordinator {
    var onChange: (([DisplayInfo]) -> Void)?

    private var screenObserver: NSObjectProtocol?

    func currentDisplays() -> [DisplayInfo] {
        NSScreen.screens.enumerated().map { index, screen in
            DisplayInfo(screen: screen, isMain: index == 0)
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
        Log.display.info("Display configuration changed count=\(displays.count, privacy: .public)")
        onChange?(displays)
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }
}
