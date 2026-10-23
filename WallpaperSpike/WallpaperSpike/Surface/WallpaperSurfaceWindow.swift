import AppKit
import CoreGraphics

@MainActor
final class WallpaperSurfaceWindow: NSWindow {
    let displayID: CGDirectDisplayID
    let playback: SurfacePlayback
    private let surfaceView: VideoSurfaceView
    private let allowsKeyWindow: Bool

    init(
        screen: NSScreen,
        displayID: CGDirectDisplayID,
        videoURL: URL,
        configuration: SpikeConfiguration,
        collectionBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone],
        canBecomeKeyWindow: Bool = false,
        canBecomeVisibleWithoutLogin: Bool = false
    ) throws {
        self.displayID = displayID
        allowsKeyWindow = canBecomeKeyWindow
        playback = try SurfacePlayback(url: videoURL, muted: configuration.muted)

        let view = VideoSurfaceView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.videoGravity = configuration.scalingMode.videoGravity
        surfaceView = view

        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        identifier = NSUserInterfaceItemIdentifier("WallpaperSurface-\(displayID)")
        title = "WallpaperSpikeSurface-\(displayID)"
        isReleasedWhenClosed = false
        level = configuration.level.windowLevel
        self.collectionBehavior = collectionBehavior
        self.canBecomeVisibleWithoutLogin = canBecomeVisibleWithoutLogin
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = configuration.clickThrough
        isMovable = false
        isMovableByWindowBackground = false
        canHide = false
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        contentView = surfaceView

        surfaceView.player = playback.player
        setFrame(screen.frame, display: true)
        playback.play()

        Log.surface.notice(
            "Created surface display=\(displayID, privacy: .public) level=\(self.level.rawValue, privacy: .public) frame=\(NSStringFromRect(screen.frame), privacy: .public)"
        )
    }

    override var canBecomeKey: Bool { allowsKeyWindow }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    func present(orderFrontOnly: Bool = false) {
        if orderFrontOnly {
            orderFront(nil)
        } else {
            orderFrontRegardless()
        }
        Log.surface.notice(
            "Presented surface display=\(self.displayID, privacy: .public) windowNumber=\(self.windowNumber, privacy: .public)"
        )
    }

    func apply(screen: NSScreen, configuration: SpikeConfiguration) {
        level = configuration.level.windowLevel
        ignoresMouseEvents = configuration.clickThrough
        surfaceView.videoGravity = configuration.scalingMode.videoGravity
        playback.setMuted(configuration.muted)
        setFrame(screen.frame, display: true)
    }

    func setPlaybackPaused(_ paused: Bool) {
        if paused {
            playback.pause()
        } else {
            playback.play()
        }
    }

    func teardown() {
        playback.teardown()
        surfaceView.player = nil
        orderOut(nil)
        close()
        Log.surface.notice("Tore down surface display=\(self.displayID, privacy: .public)")
    }
}
