import SwiftUI

@main
struct WallpaperSpikeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Wallpaper Spike") {
            ContentView()
        }
        .defaultSize(width: 880, height: 920)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
