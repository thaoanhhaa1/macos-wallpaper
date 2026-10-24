import AppKit
import CoreGraphics
import Foundation
import IOKit.ps

@MainActor
final class ResourcePolicyMonitor {
    var onChange: ((ResourceConditions) -> Void)?

    private(set) var conditions = ResourceConditions()

    private var observerTokens: [NSObjectProtocol] = []
    private var distributedTokens: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var isDisplayAsleep = false
    private var isSystemAsleep = false
    private var isScreenLocked = false
    private var isObserving = false

    private let refreshInterval: TimeInterval = 4

    func start() {
        guard !isObserving else { return }
        isObserving = true

        installObservers()
        refresh(force: true)

        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(
                    nanoseconds: UInt64((self?.refreshInterval ?? 4) * 1_000_000_000)
                )
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        removeObservers()
        isObserving = false
    }

    func refresh(force: Bool = false) {
        var next = conditions
        next.isFullscreenAppActive = FullscreenDetector.isFullscreenAppActive()
        next.isOnBattery = PowerSourceProbe.isOnBattery()
        next.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        next.isDisplayAsleep = isDisplayAsleep
        next.isSystemAsleep = isSystemAsleep
        next.isScreenLocked = isScreenLocked
        next.thermalState = ProcessInfo.processInfo.thermalState

        guard force || next != conditions else { return }

        let previous = conditions
        conditions = next
        Log.policy.info(
            "Resource conditions changed: \(next.summary, privacy: .public)"
        )
        onChange?(next)

        if previous.isFullscreenAppActive != next.isFullscreenAppActive {
            Log.policy.notice(
                "Fullscreen state \(next.isFullscreenAppActive ? "entered" : "exited", privacy: .public)"
            )
        }
        if previous.isScreenLocked != next.isScreenLocked {
            Log.policy.notice(
                "Screen lock state \(next.isScreenLocked ? "locked" : "unlocked", privacy: .public)"
            )
        }
    }

    private func installObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        observerTokens.append(workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isDisplayAsleep = true
                self?.refresh()
            }
        })
        observerTokens.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isDisplayAsleep = false
                self?.refresh()
            }
        })
        observerTokens.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isSystemAsleep = true
                self?.isDisplayAsleep = true
                self?.refresh()
            }
        })
        observerTokens.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isSystemAsleep = false
                self?.isDisplayAsleep = false
                self?.refresh()
            }
        })
        observerTokens.append(workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        })
        observerTokens.append(workspace.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        })

        let center = NotificationCenter.default
        observerTokens.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        })
        observerTokens.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        })

        let distCenter = DistributedNotificationCenter.default()
        distributedTokens.append(distCenter.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isScreenLocked = true
                self?.refresh()
            }
        })
        distributedTokens.append(distCenter.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isScreenLocked = false
                self?.refresh()
            }
        })

        let darwinCenter = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            darwinCenter,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<ResourcePolicyMonitor>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in
                    me.isScreenLocked = true
                    me.refresh()
                }
            },
            "com.apple.sessionagent.screenIsLocked" as CFString,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            darwinCenter,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<ResourcePolicyMonitor>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in
                    me.isScreenLocked = false
                    me.refresh()
                }
            },
            "com.apple.sessionagent.screenIsUnlocked" as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func removeObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        let center = NotificationCenter.default
        let distCenter = DistributedNotificationCenter.default()

        for token in observerTokens {
            workspace.removeObserver(token)
            center.removeObserver(token)
        }
        observerTokens.removeAll()

        for token in distributedTokens {
            distCenter.removeObserver(token)
        }
        distributedTokens.removeAll()

        let darwinCenter = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(
            darwinCenter,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    deinit {
        refreshTask?.cancel()
        let workspace = NSWorkspace.shared.notificationCenter
        let center = NotificationCenter.default
        let distCenter = DistributedNotificationCenter.default()

        for token in observerTokens {
            workspace.removeObserver(token)
            center.removeObserver(token)
        }
        for token in distributedTokens {
            distCenter.removeObserver(token)
        }
        let darwinCenter = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(
            darwinCenter,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }
}

private enum PowerSourceProbe {
    static func isOnBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue()
                as String? else {
            return false
        }
        return source == kIOPSBatteryPowerValue
    }
}

private enum FullscreenDetector {
    static func isFullscreenAppActive() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]] else {
            return false
        }

        let displayBounds = NSScreen.screens.map { screen in
            CGDisplayBounds(DisplayInfo.displayID(for: screen))
        }
        let ownerPID = app.processIdentifier

        for window in windows {
            guard let windowOwner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  windowOwner == ownerPID,
                  let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,
                  let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                  alpha > 0.1,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width > 0,
                  bounds.height > 0 else {
                continue
            }

            let coversDisplay = displayBounds.contains { display in
                let intersection = bounds.intersection(display)
                guard !intersection.isNull,
                      display.width > 0,
                      display.height > 0 else {
                    return false
                }
                let coverage = (intersection.width * intersection.height)
                    / (display.width * display.height)
                return coverage >= 0.99
            }
            if coversDisplay {
                return true
            }
        }

        return false
    }
}
