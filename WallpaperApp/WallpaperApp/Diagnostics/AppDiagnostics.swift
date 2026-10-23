import Foundation

struct AppDiagnostics: Equatable {
    let appName: String
    let version: String
    let build: String
    let bundleIdentifier: String
    let osVersion: String
    let architecture: String
    let logSubsystem: String

    static func snapshot(bundle: Bundle = .main) -> AppDiagnostics {
        let info = bundle.infoDictionary ?? [:]
        return AppDiagnostics(
            appName: info["CFBundleDisplayName"] as? String
                ?? info["CFBundleName"] as? String
                ?? "Wallpaper",
            version: info["CFBundleShortVersionString"] as? String ?? "0",
            build: info["CFBundleVersion"] as? String ?? "0",
            bundleIdentifier: bundle.bundleIdentifier ?? "unknown",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: currentArchitecture,
            logSubsystem: Log.subsystem
        )
    }

    var versionSummary: String {
        "Version \(version) (\(build))"
    }

    var report: String {
        """
        App: \(appName)
        Version: \(version) (\(build))
        Bundle ID: \(bundleIdentifier)
        OS: \(osVersion)
        Architecture: \(architecture)
        Log subsystem: \(logSubsystem)
        """
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}
