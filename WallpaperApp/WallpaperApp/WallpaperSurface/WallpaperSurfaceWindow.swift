import AppKit
import AVFoundation
import CoreGraphics

@MainActor
final class WallpaperSurfaceWindow: NSWindow {
    let displayID: CGDirectDisplayID

    private let renderer: PlayerLayerView

    init(
        screen: NSScreen,
        displayID: CGDirectDisplayID,
        player: AVPlayer,
        settings: PlaybackSettings,
        strategy: WallpaperSurfaceStrategy
    ) {
        self.displayID = displayID
        renderer = PlayerLayerView(frame: NSRect(origin: .zero, size: screen.frame.size))
        renderer.player = player

        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        identifier = NSUserInterfaceItemIdentifier("WallpaperSurface-\(displayID)")
        title = "WallpaperSurface-\(displayID)"
        isReleasedWhenClosed = false
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        isMovableByWindowBackground = false
        canHide = false
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        acceptsMouseMovedEvents = false
        animationBehavior = .none
        contentView = renderer

        update(screen: screen, settings: settings, strategy: strategy)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    func update(
        screen: NSScreen,
        settings: PlaybackSettings,
        strategy: WallpaperSurfaceStrategy
    ) {
        level = strategy.windowLevel
        collectionBehavior = strategy.collectionBehavior
        renderer.videoGravity = settings.scalingMode.videoGravity

        guard frame != screen.frame else { return }
        setFrame(screen.frame, display: true)
        Log.surface.info(
            "Updated surface frame display=\(self.displayID, privacy: .public) frame=\(NSStringFromRect(screen.frame), privacy: .public)"
        )
    }

    func update(settings: PlaybackSettings) {
        renderer.videoGravity = settings.scalingMode.videoGravity
    }

    func setPlayer(_ player: AVPlayer) {
        guard renderer.player !== player else { return }
        renderer.player = player
    }

    func present() {
        orderFrontRegardless()
        Log.surface.notice(
            "Presented surface display=\(self.displayID, privacy: .public) level=\(self.level.rawValue, privacy: .public) windowNumber=\(self.windowNumber, privacy: .public)"
        )
    }

    func reassertOrdering(strategy: WallpaperSurfaceStrategy) {
        level = strategy.windowLevel
        orderFrontRegardless()
    }

    func teardown() {
        renderer.player = nil
        orderOut(nil)
        close()
        Log.surface.info(
            "Tore down surface display=\(self.displayID, privacy: .public)"
        )
    }
}
