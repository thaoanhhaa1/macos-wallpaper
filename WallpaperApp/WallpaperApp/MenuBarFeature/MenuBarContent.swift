import AppKit
import SwiftUI

@MainActor
struct MenuBarContent: View {
    let model: AppModel

    var body: some View {
        Label(model.status.title, systemImage: model.status.symbolName)
        Text(model.statusDetail)

        Divider()

        Button("Play") {}
            .disabled(true)
        Button("Pause") {}
            .disabled(true)
        Button("Mute") {}
            .disabled(true)

        Divider()

        SettingsLink {
            Label("Settings…", systemImage: "gearshape")
        }
        .keyboardShortcut(",", modifiers: .command)

        #if DEBUG
        if model.developmentFixtureURL != nil {
            Button("Reveal Development Fixture") {
                model.revealDevelopmentFixture()
            }
        }
        #endif

        Divider()

        Button("About Wallpaper") {
            NSApp.orderFrontStandardAboutPanel(nil)
        }

        Button("Quit Wallpaper") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
