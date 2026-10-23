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

        if !model.recentMedia.isEmpty {
            Menu("Recent Videos") {
                ForEach(model.recentMedia.prefix(6)) { reference in
                    Button {
                        Task { await model.openRecentVideo(reference) }
                    } label: {
                        if model.selectedMedia?.identifier == reference.identifier {
                            Label(reference.displayName, systemImage: "checkmark")
                        } else {
                            Text(reference.displayName)
                        }
                    }
                    .disabled(model.importState == .importing)
                }
            }
        }

        if model.missingWallpaper != nil {
            Button("Relink Missing Video…") {
                Task { await model.relinkMissingVideo() }
            }
            .disabled(model.importState == .importing)
        }

        Divider()

        Button("Apply as Wallpaper") {
            model.applyWallpaper()
        }
        .disabled(!model.hasMedia || model.wallpaper.isActive)

        Button("Remove Wallpaper") {
            model.removeWallpaper()
        }
        .disabled(
            !model.wallpaper.isActive
                && model.wallpaper.state.failureReason == nil
                && !model.isWaitingForDisplay
        )

        Button("Restore Last Wallpaper") {
            Task { await model.restoreLastWallpaper() }
        }
        .disabled(!model.hasLastWallpaper || model.wallpaper.isActive || model.isRestoringWallpaper)

        Menu("Display Mode") {
            ForEach(DisplayMode.allCases) { mode in
                Button {
                    model.setDisplayMode(mode)
                } label: {
                    if model.settings.displayMode == mode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Text(mode.title)
                    }
                }
            }
        }

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
