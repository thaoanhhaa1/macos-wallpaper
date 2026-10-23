import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class LaunchAtLoginController {
    enum Status: Equatable {
        case notRegistered
        case enabled
        case requiresApproval
        case notFound

        var summary: String {
            switch self {
            case .notRegistered: "Off"
            case .enabled: "On"
            case .requiresApproval: "Waiting for approval"
            case .notFound: "Unavailable"
            }
        }
    }

    private(set) var status: Status = .notRegistered
    private(set) var lastError: String?

    var isEnabled: Bool {
        status == .enabled || status == .requiresApproval
    }

    var requiresApproval: Bool {
        status == .requiresApproval
    }

    var statusDescription: String {
        switch status {
        case .notRegistered:
            "Wallpaper does not start automatically."
        case .enabled:
            "Wallpaper opens automatically when you log in."
        case .requiresApproval:
            "Allow Wallpaper in System Settings → General → Login Items to finish enabling it."
        case .notFound:
            "Login at startup is unavailable. Move Wallpaper to the Applications folder and try again."
        }
    }

    init() {
        refresh()
    }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .notRegistered:
            status = .notRegistered
        case .enabled:
            status = .enabled
        case .requiresApproval:
            status = .requiresApproval
        case .notFound:
            status = .notFound
        @unknown default:
            status = .notFound
        }
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        lastError = nil

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
            Log.startup.notice(
                "Launch at login \(enabled ? "registered" : "unregistered") status=\(self.status.summary, privacy: .public)"
            )
            return true
        } catch {
            refresh()
            lastError = error.localizedDescription
            Log.startup.error(
                "Launch at login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    func openLoginItemsSettings() {
        Log.startup.info("Opening Login Items settings")
        SMAppService.openSystemSettingsLoginItems()
    }
}
