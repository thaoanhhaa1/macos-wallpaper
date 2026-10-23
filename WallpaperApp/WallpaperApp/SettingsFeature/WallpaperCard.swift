import SwiftUI

@MainActor
struct WallpaperCard: View {
    let model: AppModel

    var body: some View {
        GroupBox("Wallpaper Surface") {
            VStack(alignment: .leading, spacing: 10) {
                header
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let failure = model.wallpaper.state.failureReason {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button("Apply as Wallpaper") {
                        model.applyWallpaper()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.hasMedia || model.wallpaper.isActive)

                    Button("Remove Wallpaper") {
                        model.removeWallpaper()
                    }
                    .disabled(!model.wallpaper.isActive && model.wallpaper.state.failureReason == nil)

                    Button("Restore Last Wallpaper") {
                        model.restoreLastWallpaper()
                    }
                    .disabled(!model.hasLastWallpaper || model.wallpaper.isActive)

                    Spacer()
                }

                Text(surfaceNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(model.wallpaper.state.title, systemImage: model.wallpaper.state.symbolName)
                .fontWeight(.medium)

            if model.wallpaper.isActive {
                Text(model.wallpaper.isPaused ? "PAUSED" : "PLAYING")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.16))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Capsule())
            }

            Spacer()

            if model.wallpaper.isActive {
                Text("\(model.wallpaper.surfaceCount) surface\(model.wallpaper.surfaceCount == 1 ? "" : "s")")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var detail: String {
        if let failure = model.wallpaper.state.failureReason {
            return failure
        }
        if model.wallpaper.isActive {
            let name = model.wallpaper.appliedMediaName ?? "Video wallpaper"
            let state = model.wallpaper.isPaused ? "paused" : "playing"
            return "\(name) is \(state) on \(model.wallpaper.surfaceCount) display\(model.wallpaper.surfaceCount == 1 ? "" : "s")."
        }
        if let last = model.lastWallpaper {
            return "Last wallpaper: \(last.displayName). Apply the selected video or restore the previous one."
        }
        return "Apply the validated video as a desktop surface. Desktop icons and windows stay interactive."
    }

    private var surfaceNote: String {
        "\(model.surfaceStrategy.title) · click-through · all Spaces · \(model.settings.displayMode.title)"
    }
}
