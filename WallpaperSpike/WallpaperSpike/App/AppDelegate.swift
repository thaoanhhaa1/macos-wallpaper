import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments

        if arguments.contains("--self-test") {
            Log.app.notice("Starting self-test mode")
            NSApp.setActivationPolicy(arguments.contains("--regular") ? .regular : .accessory)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                Task { @MainActor in
                    await SpikeSelfTest.runAndExit(arguments: arguments)
                }
            }
        } else if arguments.contains("--demo") {
            Log.app.notice("Starting demo mode")
            NSApp.setActivationPolicy(arguments.contains("--regular") ? .regular : .accessory)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                Task { @MainActor in
                    await SpikeDemo.runAndExit(arguments: arguments)
                }
            }
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
