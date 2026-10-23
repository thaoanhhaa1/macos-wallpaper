import SwiftUI

@MainActor
struct MenuBarLabel: View {
    let status: WallpaperStatus

    @Environment(\.openSettings) private var openSettings
    @AppStorage("wallpaper.hasPresentedSettings") private var hasPresentedSettings = false

    var body: some View {
        Label(status.title, systemImage: status.symbolName)
            .labelStyle(.iconOnly)
            .accessibilityLabel("Wallpaper: \(status.title)")
            .task {
                guard !hasPresentedSettings else { return }
                hasPresentedSettings = true
                openSettings()
            }
    }
}
