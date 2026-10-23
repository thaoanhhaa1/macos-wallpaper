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

                if let missing = model.missingWallpaper {
                    Label("Missing: \(missing.displayName)", systemImage: "questionmark.folder.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Relink Missing Video…") {
                        Task { await model.relinkMissingVideo() }
                    }
                    .disabled(model.importState == .importing)
                }

                if let failure = model.wallpaper.state.failureReason {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button(applyButtonTitle) {
                        model.applyWallpaper()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canApply)

                    Button("Remove Wallpaper") {
                        model.removeWallpaper()
                    }
                    .disabled(
                        !model.wallpaper.isActive
                            && model.wallpaper.state.failureReason == nil
                            && model.missingWallpaper == nil
                            && !model.isWaitingForDisplay
                    )

                    Button("Restore Last Wallpaper") {
                        Task { await model.restoreLastWallpaper() }
                    }
                    .disabled(!model.hasLastWallpaper || model.wallpaper.isActive || model.isRestoringWallpaper)

                    if model.isRestoringWallpaper {
                        ProgressView()
                            .controlSize(.small)
                    }

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
        if let missing = model.missingWallpaper {
            let target = missing.targetDisplayName.map { " on \($0)" } ?? ""
            return "The saved wallpaper “\(missing.displayName)”\(target) can't be opened. Relink it or choose another video."
        }
        if let failure = model.wallpaper.state.failureReason {
            return failure
        }
        if model.wallpaper.isActive {
            let name = model.wallpaper.appliedMediaName ?? "Video wallpaper"
            let state = model.wallpaper.isPaused ? "paused" : "playing"
            return "\(name) is \(state) on \(model.wallpaper.surfaceCount) display\(model.wallpaper.surfaceCount == 1 ? "" : "s")."
        }
        if model.isWaitingForDisplay {
            return "The saved wallpaper is waiting for a configured display to reconnect."
        }
        if let last = model.lastWallpaperName {
            return "Last wallpaper: \(last). Apply the selected video or restore the previous one."
        }
        return "Apply the validated video as a desktop surface. Desktop icons and windows stay interactive."
    }

    private var applyButtonTitle: String {
        model.settings.displayMode == .perDisplay
            ? "Apply to Target Display"
            : "Apply as Wallpaper"
    }

    private var canApply: Bool {
        guard model.hasMedia else { return false }
        if model.settings.displayMode == .perDisplay {
            return true
        }
        return !model.wallpaper.isActive
    }

    private var surfaceNote: String {
        let target = targetDisplayName.map { " · target: \($0)" } ?? ""
        return "\(model.surfaceStrategy.title) · click-through · all Spaces · \(model.settings.displayMode.title)\(target)"
    }

    private var targetDisplayName: String? {
        guard model.settings.displayMode == .perDisplay,
              let persistentID = model.targetDisplayPersistentID else {
            return nil
        }
        return model.displays.first(where: { $0.persistentID == persistentID })?.name
    }
}
