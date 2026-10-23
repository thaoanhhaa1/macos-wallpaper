import AppKit
import SwiftUI

@MainActor
struct MenuBarContent: View {
    let model: AppModel

    var body: some View {
        Label(model.status.title, systemImage: model.status.symbolName)
        Text(model.statusDetail)

        Divider()

        Button(model.isPlaying ? "Pause" : "Play") {
            model.togglePlayPause()
        }
        .disabled(!model.hasMedia)

        Button(model.settings.playback.isMuted ? "Unmute" : "Mute") {
            model.toggleMute()
        }
        .disabled(!model.hasMedia)

        Button("Choose Video…") {
            Task { await model.chooseVideo() }
        }
        .disabled(model.importState == .importing)

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
