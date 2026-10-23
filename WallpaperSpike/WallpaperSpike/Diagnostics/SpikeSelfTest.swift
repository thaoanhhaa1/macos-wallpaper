import AppKit
import AVFoundation
import Foundation

@MainActor
enum SpikeSelfTest {
    static func runAndExit(arguments: [String]) async {
        let reportURL = reportURL(from: arguments)
        let startedAt = Date()
        var report = SelfTestReport(
            generatedAt: startedAt,
            startedAt: startedAt,
            finishedAt: nil,
            durationSeconds: nil,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: appVersion(),
            architecture: architecture(),
            videoPath: nil,
            videoDuration: nil,
            screens: DisplayProbe.currentScreens(),
            distinctScaleFactors: [],
            levelTrials: [],
            loopTrial: nil,
            multiDisplayTrial: nil,
            manualChecks: manualChecks(),
            recommendedStrategy: nil,
            verdict: nil,
            error: nil
        )

        for window in NSApp.windows where !window.title.hasPrefix("WallpaperSpikeSurface") {
            window.close()
        }

        do {
            guard let mainScreen = NSScreen.main ?? NSScreen.screens.first,
                  let mainDisplayID = DisplayProbe.displayID(for: mainScreen) else {
                throw SpikeError.playbackFailed("No NSScreen with a CGDirectDisplayID is available")
            }

            let videoURL = try await TestVideoFactory.makeTestVideo(duration: 4)
            let asset = AVURLAsset(url: videoURL)
            let videoDuration = try await asset.load(.duration).seconds
            report.videoPath = videoURL.path
            report.videoDuration = videoDuration
            report.screens = DisplayProbe.currentScreens()
            report.distinctScaleFactors = Array(Set(report.screens.map(\.backingScaleFactor))).sorted()

            for strategy in SurfaceLevelStrategy.allCases {
                var configuration = SpikeConfiguration()
                configuration.target = .mainDisplay
                configuration.level = strategy
                configuration.scalingMode = .fill
                configuration.clickThrough = true
                configuration.muted = true

                let window = try WallpaperSurfaceWindow(
                    screen: mainScreen,
                    displayID: mainDisplayID,
                    videoURL: videoURL,
                    configuration: configuration
                )
                window.present()

                try await Task.sleep(nanoseconds: 1_200_000_000)

                let snapshot = WindowProbe.snapshot()
                let order = WindowProbe.analyze(
                    surfaceWindowNumber: window.windowNumber,
                    snapshot: snapshot
                )
                let playback = sample(window.playback)

                var notes: [String] = []
                if window.windowNumber <= 0 {
                    notes.append("NSWindow.windowNumber is not available")
                }
                if !playback.isPlaying {
                    notes.append("Player was not playing after 1.2s")
                }
                if playback.currentTime <= 0 {
                    notes.append("Playback time did not advance")
                }
                if order.iconWindowsOverlappingSurface.isEmpty {
                    notes.append("No desktop-icon windows were exposed by CGWindowList for this surface")
                }
                if order.surfaceFound == false {
                    notes.append("Surface window was not present in the on-screen CGWindowList")
                }

                report.levelTrials.append(
                    LevelTrial(
                        strategy: strategy.rawValue,
                        levelValue: strategy.windowLevel.rawValue,
                        levelDetail: strategy.detail,
                        windowNumber: window.windowNumber,
                        playback: playback,
                        order: order,
                        notes: notes
                    )
                )

                window.teardown()
                try await Task.sleep(nanoseconds: 300_000_000)
            }

            report.multiDisplayTrial = try await runMultiDisplayTrial(videoURL: videoURL)

            report.loopTrial = try await runLoopTrial(
                screen: mainScreen,
                displayID: mainDisplayID,
                videoURL: videoURL,
                videoDuration: videoDuration
            )

            report.recommendedStrategy = recommend(from: report)
            report.verdict = verdict(for: report.recommendedStrategy)
        } catch {
            report.error = error.localizedDescription
            report.recommendedStrategy = "unknown"
            report.verdict = "Self-test failed: \(error.localizedDescription)"
        }

        report.finishedAt = Date()
        report.durationSeconds = Date().timeIntervalSince(startedAt)

        do {
            try ReportWriter.write(report, to: reportURL)
        } catch {
            fputs("Could not write report: \(error.localizedDescription)\n", stderr)
        }

        print(ReportWriter.humanSummary(report))
        print("")
        print("JSON report: \(reportURL.path)")
        fflush(stdout)
        fflush(stderr)

        let exitCode: Int32 = report.error == nil ? 0 : 2
        exit(exitCode)
    }

    private static func runMultiDisplayTrial(videoURL: URL) async throws -> MultiDisplayTrial {
        var surfaces: [MultiDisplaySurfaceTrial] = []
        var notes: [String] = []

        for screen in NSScreen.screens {
            guard let displayID = DisplayProbe.displayID(for: screen) else {
                notes.append("Skipped a screen without a CGDirectDisplayID")
                continue
            }

            var configuration = SpikeConfiguration()
            configuration.target = .mainDisplay
            configuration.level = .belowDesktopIcons
            configuration.scalingMode = .fill
            configuration.clickThrough = true
            configuration.muted = true

            let window = try WallpaperSurfaceWindow(
                screen: screen,
                displayID: displayID,
                videoURL: videoURL,
                configuration: configuration
            )
            window.present()

            try await Task.sleep(nanoseconds: 1_200_000_000)

            let snapshot = WindowProbe.snapshot()
            let order = WindowProbe.analyze(surfaceWindowNumber: window.windowNumber, snapshot: snapshot)
            let playback = sample(window.playback)

            if !playback.isPlaying || playback.currentTime <= 0 {
                notes.append("Playback did not advance on display \(displayID)")
            }
            if order.surfaceFound == false {
                notes.append("Surface was not in the on-screen list on display \(displayID)")
            }

            surfaces.append(
                MultiDisplaySurfaceTrial(
                    displayID: displayID,
                    screenName: screen.localizedName,
                    scaleFactor: screen.backingScaleFactor,
                    windowNumber: window.windowNumber,
                    playback: playback,
                    order: order
                )
            )

            window.teardown()
            try await Task.sleep(nanoseconds: 300_000_000)
        }

        let scales = Set(surfaces.map(\.scaleFactor))
        if surfaces.count > 1, scales.count < 2 {
            notes.append("Multiple displays reported the same scale factor; different-scale matrix is not covered by this run")
        }
        if surfaces.isEmpty {
            notes.append("No display produced a surface")
        }

        return MultiDisplayTrial(surfaces: surfaces, notes: notes)
    }

    private static func runLoopTrial(
        screen: NSScreen,
        displayID: CGDirectDisplayID,
        videoURL: URL,
        videoDuration: Double
    ) async throws -> LoopTrial {
        var configuration = SpikeConfiguration()
        configuration.target = .mainDisplay
        configuration.level = .belowDesktopIcons
        configuration.scalingMode = .fill
        configuration.clickThrough = true
        configuration.muted = true

        let window = try WallpaperSurfaceWindow(
            screen: screen,
            displayID: displayID,
            videoURL: videoURL,
            configuration: configuration
        )
        window.present()

        let firstDelay = UInt64(max(0.5, videoDuration - 0.6) * 1_000_000_000)
        try await Task.sleep(nanoseconds: firstDelay)
        let first = sample(window.playback)

        let secondDelay = UInt64(max(0.5, videoDuration * 0.55) * 1_000_000_000)
        try await Task.sleep(nanoseconds: secondDelay)
        let second = sample(window.playback)

        var wrapped: Bool?
        var notes: [String] = []
        if first.currentTime > 0, second.currentTime > 0, first.isPlaying, second.isPlaying {
            wrapped = second.currentTime < first.currentTime
        } else {
            notes.append("Could not observe a stable loop because playback time or rate was invalid")
        }
        if second.isPlaying == false {
            notes.append("Player stopped after crossing the loop boundary")
        }
        notes.append("This check does not measure visual black frames at the loop boundary; verify manually with a short clip")

        window.teardown()

        return LoopTrial(
            strategy: configuration.level.rawValue,
            videoDuration: videoDuration,
            firstSample: first,
            secondSample: second,
            wrapped: wrapped,
            notes: notes
        )
    }

    private static func sample(_ playback: SurfacePlayback) -> PlaybackSample {
        PlaybackSample(
            currentTime: playback.currentTime,
            rate: playback.rate,
            isPlaying: playback.isPlaying,
            isMuted: playback.isMuted
        )
    }

    private static func recommend(from report: SelfTestReport) -> String {
        let candidates: [SurfaceLevelStrategy] = [
            .belowDesktopIcons,
            .aboveDesktopPicture,
            .justBelowNormal,
            .normal
        ]

        for strategy in candidates {
            guard let trial = report.levelTrials.first(where: { $0.strategy == strategy.rawValue }) else {
                continue
            }
            let playable = trial.playback.isPlaying && trial.playback.currentTime > 0
            let behindIcons = trial.order.isBehindDesktopIcons != false
            let aboveWallpaper = trial.order.isAboveSystemWallpaper != false
            if trial.order.surfaceFound, playable, behindIcons, aboveWallpaper {
                return strategy.rawValue
            }
        }

        return "fallbackOverlay"
    }

    private static func verdict(for strategy: String?) -> String {
        switch strategy {
        case SurfaceLevelStrategy.belowDesktopIcons.rawValue:
            return "Window ordering and playback verified. Confirm visually on the physical display: on macOS 26+, display capture can omit negative-level windows even when they are visible."
        case SurfaceLevelStrategy.aboveDesktopPicture.rawValue:
            return "Surface is above the system wallpaper but could not be verified below desktop icons. Manually verify desktop icon interaction and physical visibility."
        case SurfaceLevelStrategy.justBelowNormal.rawValue, SurfaceLevelStrategy.normal.rawValue:
            return "Desktop-level placement did not verify. The fallback is a desktop overlay with explicit pause/hide, or a main-display-only mode."
        case "fallbackOverlay":
            return "No candidate window level verified as behind desktop icons. Use the fallback overlay strategy and document the limitation before Phase 3."
        default:
            return "Self-test did not produce a recommendation."
        }
    }

    private static func manualChecks() -> [ManualCheck] {
        [
            ManualCheck(
                key: "desktop-icons",
                title: "Desktop icons",
                question: "Can you select, drag and open desktop icons while the surface is running?",
                status: "manual",
                instructions: "Run the surface on a display with Finder desktop icons. Click and drag an icon; confirm it stays above the video."
            ),
            ManualCheck(
                key: "finder-context-menu",
                title: "Finder context menu",
                question: "Does right-clicking an empty desktop area show the Finder context menu?",
                status: "manual",
                instructions: "Right-click empty desktop with the surface running. The surface must not swallow the event."
            ),
            ManualCheck(
                key: "click-through",
                title: "Click-through and selection",
                question: "Can you drag a selection rectangle over the surface?",
                status: "manual",
                instructions: "Drag on empty desktop across the video. Icons inside the rectangle should be selected normally."
            ),
            ManualCheck(
                key: "focus",
                title: "Window and keyboard focus",
                question: "Do other apps still become key and receive keyboard input?",
                status: "manual",
                instructions: "Click another app, type text and use Cmd+Tab. The surface must never become key or main."
            ),
            ManualCheck(
                key: "spaces",
                title: "Spaces",
                question: "Does the video remain correctly placed after switching Spaces?",
                status: "manual",
                instructions: "Switch between at least two Spaces with Ctrl+Left/Right and by swiping. Check for disappearing or misplaced surfaces."
            ),
            ManualCheck(
                key: "mission-control",
                title: "Mission Control",
                question: "Does Mission Control exclude the surface from its window thumbnails?",
                status: "manual",
                instructions: "Open Mission Control. The wallpaper surface should stay as background, not appear as a selectable window."
            ),
            ManualCheck(
                key: "fullscreen",
                title: "Fullscreen app",
                question: "Is the surface hidden behind fullscreen apps and restored on exit?",
                status: "manual",
                instructions: "Enter fullscreen in Safari or another app. Confirm the video does not cover the fullscreen window and returns afterwards."
            ),
            ManualCheck(
                key: "sleep-wake",
                title: "Display/system sleep and wake",
                question: "Does playback pause on sleep and resume on wake without a stuck player?",
                status: "manual",
                instructions: "Use Apple menu > Sleep, or close the lid. Wake the Mac and check the surface still loops. Repeat several times."
            ),
            ManualCheck(
                key: "multi-display-scale",
                title: "Multiple displays and scale factors",
                question: "Are surfaces aligned and readable on displays with different scale factors?",
                status: "manual",
                instructions: "Connect two displays, set one to a different scaling option, and switch target between Main and All displays. Verify frame coverage and no clipping."
            ),
            ManualCheck(
                key: "display-hotplug",
                title: "Display hot-plug",
                question: "Does plugging/unplugging a display leave no orphan surface?",
                status: "manual",
                instructions: "Plug in and remove a display several times. Confirm windows disappear and do not pile up in the window list."
            ),
            ManualCheck(
                key: "finder-relaunch",
                title: "Finder relaunch",
                question: "Does the surface remain behind desktop icons after Finder restarts?",
                status: "manual",
                instructions: "Run `killall Finder` in Terminal. Wait for the desktop to return and check the video is still behind the icons."
            ),
            ManualCheck(
                key: "display-sleep",
                title: "Display sleep only",
                question: "Does playback pause when the display sleeps and resume on wake?",
                status: "manual",
                instructions: "Set display sleep to one minute in System Settings. Wait for display sleep, then wake and check playback."
            ),
            ManualCheck(
                key: "screen-lock",
                title: "Screen lock",
                question: "Does the surface resume correctly after locking and unlocking?",
                status: "manual",
                instructions: "Lock the screen with Ctrl+Cmd+Q, unlock, and verify playback and window ordering."
            ),
            ManualCheck(
                key: "system-wallpaper",
                title: "System wallpaper visibility",
                question: "Does the video fully cover the static system wallpaper without flicker?",
                status: "manual",
                instructions: "Set a bright static wallpaper. Confirm no desktop picture flashes between loop iterations or after display changes."
            ),
            ManualCheck(
                key: "window-ordering",
                title: "Ordering after app activation",
                question: "Does ordering stay correct after switching apps, using Dock and menu bar?",
                status: "manual",
                instructions: "Activate several apps, open/close windows and use the Dock. The surface must remain behind all normal windows and icons."
            ),
            ManualCheck(
                key: "capture-exclusion",
                title: "Screenshot vs. physical display",
                question: "If a screenshot omits the video, does the physical display still show it?",
                status: "manual",
                instructions: "On macOS 26+, screen capture may exclude third-party windows below the desktop-icon level. Compare Scripts/visibility-check.sh with what you see on the display; trust the physical display for the product decision."
            )
        ]
    }

    private static func reportURL(from arguments: [String]) -> URL {
        if let path = value(after: "--report", in: arguments) {
            return URL(fileURLWithPath: path)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return base
            .appendingPathComponent("WallpaperSpike/Reports", isDirectory: true)
            .appendingPathComponent("feasibility-\(stamp).json")
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func appVersion() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(version) (\(build))"
    }

    private static func architecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

@MainActor
enum SpikeDemo {
    static func runAndExit(arguments: [String]) async {
        let duration = Double(value(after: "--duration", in: arguments) ?? "") ?? 20
        let levelName = value(after: "--level", in: arguments) ?? SurfaceLevelStrategy.belowDesktopIcons.rawValue
        let level = SurfaceLevelStrategy(rawValue: levelName) ?? .belowDesktopIcons

        do {
            for window in NSApp.windows where !window.title.hasPrefix("WallpaperSpikeSurface") {
                window.close()
            }

            let requestedDisplayID = UInt32(value(after: "--display", in: arguments) ?? "")
            let screen: NSScreen?
            if let requestedDisplayID, let requestedScreen = DisplayProbe.screen(for: requestedDisplayID) {
                screen = requestedScreen
            } else {
                screen = NSScreen.main ?? NSScreen.screens.first
            }

            guard let screen, let displayID = DisplayProbe.displayID(for: screen) else {
                throw SpikeError.playbackFailed("No screen is available")
            }

            let rawLevel = Int(value(after: "--raw-level", in: arguments) ?? "")

            if arguments.contains("--solid") {
                let solidWindow = NSWindow(
                    contentRect: screen.frame,
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                solidWindow.level = rawLevel.map { NSWindow.Level(rawValue: $0) } ?? level.windowLevel
                solidWindow.collectionBehavior = collectionBehaviorForDemo(arguments)
                solidWindow.backgroundColor = .systemRed
                solidWindow.isOpaque = true
                solidWindow.hasShadow = false
                solidWindow.ignoresMouseEvents = true
                solidWindow.orderFrontRegardless()
                solidWindow.setFrame(screen.frame, display: true)
                print("DEMO_READY solid windowNumber=\(solidWindow.windowNumber) level=\(solidWindow.level.rawValue) displayID=\(displayID) screen=\(screen.localizedName) frame=\(NSStringFromRect(solidWindow.frame))")
                fflush(stdout)
                try await Task.sleep(for: .seconds(1))
                print("DEMO_OCCLUSION solid visible=\(solidWindow.occlusionState.contains(.visible)) isVisible=\(solidWindow.isVisible) alpha=\(solidWindow.alphaValue)")
                fflush(stdout)
                try await Task.sleep(nanoseconds: UInt64(max(0, duration - 1) * 1_000_000_000))
                solidWindow.close()
                exit(0)
            }

            let videoURL: URL
            if let path = value(after: "--video", in: arguments) {
                videoURL = URL(fileURLWithPath: path)
            } else {
                videoURL = try await TestVideoFactory.makeTestVideo(duration: 4)
            }

            var configuration = SpikeConfiguration()
            configuration.target = .mainDisplay
            configuration.level = level
            configuration.scalingMode = .fill
            configuration.clickThrough = true
            configuration.muted = true

            let collectionName = value(after: "--collection", in: arguments) ?? "default"
            let collectionBehavior: NSWindow.CollectionBehavior
            switch collectionName {
            case "aux":
                collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            case "minimal":
                collectionBehavior = [.stationary, .ignoresCycle]
            case "all":
                collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            default:
                collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            }

            let window = try WallpaperSurfaceWindow(
                screen: screen,
                displayID: displayID,
                videoURL: videoURL,
                configuration: configuration,
                collectionBehavior: collectionBehavior,
                canBecomeKeyWindow: arguments.contains("--can-key"),
                canBecomeVisibleWithoutLogin: arguments.contains("--login-visible")
            )

            if let rawLevel {
                window.level = NSWindow.Level(rawValue: rawLevel)
            }

            let orderThenFrame = arguments.contains("--order-then-frame")
            if orderThenFrame {
                window.present(orderFrontOnly: arguments.contains("--order-front"))
            }

            switch value(after: "--frame", in: arguments) ?? "screen" {
            case "visible":
                window.setFrame(screen.visibleFrame, display: true)
            case "wallpaper-play":
                let topMargin = (screen.frame.height - screen.visibleFrame.height) - (screen.visibleFrame.origin.y - screen.frame.origin.y)
                let frame = NSRect(
                    x: screen.frame.origin.x,
                    y: screen.frame.origin.y,
                    width: screen.frame.size.width,
                    height: screen.frame.size.height - topMargin + 1
                )
                window.setFrame(frame, display: true)
            default:
                break
            }

            if !orderThenFrame {
                window.present(orderFrontOnly: arguments.contains("--order-front"))
            }

            print("DEMO_READY windowNumber=\(window.windowNumber) level=\(window.level.rawValue) displayID=\(displayID) screen=\(screen.localizedName) collection=\(collectionName) frame=\(NSStringFromRect(window.frame)) video=\(videoURL.path)")
            fflush(stdout)

            let deadline = Date().addingTimeInterval(duration)
            while Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                print(String(format: "DEMO_PLAYBACK t=%.2f rate=%.2f occlusionVisible=%@", window.playback.currentTime, window.playback.rate, window.occlusionState.contains(.visible) ? "yes" : "no"))
                fflush(stdout)
            }

            let snapshot = WindowProbe.snapshot()
            let analysis = WindowProbe.analyze(surfaceWindowNumber: window.windowNumber, snapshot: snapshot)
            print(WindowProbe.reportText(for: analysis))
            window.teardown()
            exit(0)
        } catch {
            fputs("DEMO_ERROR \(error.localizedDescription)\n", stderr)
            exit(2)
        }
    }

    private static func collectionBehaviorForDemo(_ arguments: [String]) -> NSWindow.CollectionBehavior {
        let name = value(after: "--collection", in: arguments) ?? "default"
        switch name {
        case "aux": return [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        case "minimal": return [.stationary, .ignoresCycle]
        case "all": return [.canJoinAllSpaces, .stationary, .ignoresCycle]
        default: return [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
