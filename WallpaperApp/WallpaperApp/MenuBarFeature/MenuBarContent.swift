import AppKit
import SwiftUI

@MainActor
struct MenuBarContent: View {
    let model: AppModel

    var body: some View {
        Label(model.status.title, systemImage: model.status.symbolName)
        Text(model.statusDetail)

        Divider()

        Button(model.effectiveIsPlaying ? "Pause" : "Play") {
            model.toggleEffectivePlayback()
        }
        .disabled(!model.hasMedia && !model.wallpaper.isActive)

        Button(model.settings.playback.isMuted ? "Unmute" : "Mute") {
            model.toggleMute()
        }
        .disabled(!model.hasMedia && !model.wallpaper.isActive)

        Button("Choose Video…") {
            Task { await model.chooseVideo() }
        }
        .disabled(model.importState == .importing)

        Divider()

        Button("Apply as Wallpaper") {
            model.applyWallpaper()
        }
        .disabled(!model.hasMedia || model.wallpaper.isActive)

        Button("Remove Wallpaper") {
            model.removeWallpaper()
        }
        .disabled(!model.wallpaper.isActive && model.wallpaper.state.failureReason == nil)

        Button("Restore Last Wallpaper") {
            model.restoreLastWallpaper()
        }
        .disabled(!model.hasLastWallpaper || model.wallpaper.isActive)

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
