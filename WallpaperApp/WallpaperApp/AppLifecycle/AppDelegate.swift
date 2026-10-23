import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let diagnostics = AppDiagnostics.snapshot()
        Log.app.notice(
            "Launched \(diagnostics.appName, privacy: .public) version=\(diagnostics.version, privacy: .public) build=\(diagnostics.build, privacy: .public) os=\(diagnostics.osVersion, privacy: .public)"
        )
        let distribution = DistributionInfo.snapshot()
        Log.distribution.notice(
            "Signature=\(distribution.signatureSummary, privacy: .public) hardenedRuntime=\(distribution.hardenedRuntimeSummary, privacy: .public) sandbox=\(distribution.sandboxSummary, privacy: .public)"
        )
        Log.app.info("Menu bar shell ready; Settings is available from the menu bar item")
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.app.notice("Terminating")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
