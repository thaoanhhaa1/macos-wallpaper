import Foundation

enum ResourcePauseReason: String, CaseIterable, Identifiable, Equatable {
    case fullscreen
    case battery
    case lowPowerMode
    case displaySleep
    case systemSleep
    case screenLocked
    case thermalPressure
    case user

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullscreen: "Fullscreen app active"
        case .battery: "Running on battery"
        case .lowPowerMode: "Low Power Mode enabled"
        case .displaySleep: "Display asleep"
        case .systemSleep: "System asleep"
        case .screenLocked: "Screen locked"
        case .thermalPressure: "Thermal pressure"
        case .user: "Paused manually"
        }
    }

    var symbolName: String {
        switch self {
        case .fullscreen: "rectangle.inset.filled"
        case .battery: "battery.50"
        case .lowPowerMode: "leaf"
        case .displaySleep: "moon.zzz"
        case .systemSleep: "powersleep"
        case .screenLocked: "lock.fill"
        case .thermalPressure: "thermometer.high"
        case .user: "pause.fill"
        }
    }
}

struct ResourceConditions: Equatable {
    var isFullscreenAppActive = false
    var isOnBattery = false
    var isLowPowerMode = false
    var isDisplayAsleep = false
    var isSystemAsleep = false
    var isScreenLocked = false
    var thermalState: ProcessInfo.ThermalState = .nominal

    var isThermallyConstrained: Bool {
        thermalState == .serious || thermalState == .critical
    }

    var thermalStateTitle: String {
        switch thermalState {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }

    var powerSourceTitle: String {
        isOnBattery ? "Battery" : "Power adapter"
    }

    var summary: String {
        var parts = [
            powerSourceTitle,
            isLowPowerMode ? "Low Power Mode" : "Normal power mode",
            "thermal \(thermalStateTitle.lowercased())"
        ]
        if isFullscreenAppActive { parts.append("fullscreen app") }
        if isScreenLocked { parts.append("screen locked") }
        if isDisplayAsleep { parts.append("display asleep") }
        if isSystemAsleep { parts.append("system asleep") }
        return parts.joined(separator: " · ")
    }
}

struct ResourcePolicy: Equatable {
    var pauseOnFullscreen: Bool
    var pauseOnBattery: Bool
    var pauseOnLowPowerMode: Bool

    init(playback: PlaybackSettings) {
        pauseOnFullscreen = playback.pauseOnFullscreen
        pauseOnBattery = playback.pauseOnBattery
        pauseOnLowPowerMode = playback.pauseOnLowPowerMode
    }

    static let `default` = ResourcePolicy(playback: PlaybackSettings())

    func pauseReasons(for conditions: ResourceConditions) -> Set<ResourcePauseReason> {
        var reasons: Set<ResourcePauseReason> = []

        if pauseOnFullscreen && conditions.isFullscreenAppActive {
            reasons.insert(.fullscreen)
        }
        if pauseOnBattery && conditions.isOnBattery {
            reasons.insert(.battery)
        }
        if pauseOnLowPowerMode && conditions.isLowPowerMode {
            reasons.insert(.lowPowerMode)
        }
        if conditions.isScreenLocked {
            reasons.insert(.screenLocked)
        }
        if conditions.isDisplayAsleep {
            reasons.insert(.displaySleep)
        }
        if conditions.isSystemAsleep {
            reasons.insert(.systemSleep)
        }
        if conditions.isThermallyConstrained {
            reasons.insert(.thermalPressure)
        }

        return reasons
    }

    var summary: String {
        var rules: [String] = []
        if pauseOnFullscreen { rules.append("pause on fullscreen") }
        if pauseOnBattery { rules.append("pause on battery") }
        if pauseOnLowPowerMode { rules.append("pause in Low Power Mode") }
        rules.append("pause on screen lock, sleep and thermal pressure")
        return rules.joined(separator: ", ")
    }
}
