import SwiftUI

@MainActor
struct DisplaySettingsCard: View {
    let model: AppModel

    var body: some View {
        GroupBox("Displays") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Display mode", selection: displayModeBinding) {
                    ForEach(DisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(modeDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                HStack {
                    Text("Connected")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(model.displays.count) display\(model.displays.count == 1 ? "" : "s")")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                ForEach(model.displays) { display in
                    displayRow(display)
                }

                if !model.disconnectedDisplayConfigurations.isEmpty {
                    Divider()

                    Text("Saved but disconnected")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(model.disconnectedDisplayConfigurations) { entry in
                        disconnectedRow(entry)
                    }
                }

                Text("Display configurations are keyed by stable display UUID, so unplugging a display keeps its video until it reconnects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var displayModeBinding: Binding<DisplayMode> {
        Binding(
            get: { model.settings.displayMode },
            set: { model.setDisplayMode($0) }
        )
    }

    private var modeDescription: String {
        switch model.settings.displayMode {
        case .allScreens:
            "One video plays on every connected display. Mirrored displays share a single surface."
        case .mainScreen:
            "Only the main display shows the video. Configurations for other connected displays are cleared."
        case .perDisplay:
            "Each display keeps its own video. Apply as Wallpaper targets the display marked with the radio button."
        }
    }

    private func displayRow(_ display: DisplayInfo) -> some View {
        let configuration = model.settings.displayConfigurations[display.persistentID]
        let isTarget = model.settings.displayMode == .perDisplay
            && model.targetDisplayPersistentID == display.persistentID
        let isSurfaceActive = model.isSurfaceActive(for: display.persistentID)

        return HStack(alignment: .top, spacing: 10) {
            Button {
                model.selectDisplay(display.persistentID)
            } label: {
                Image(systemName: isTarget ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isTarget ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Use this display as the Apply target")
            .disabled(display.isMirrored)

            Image(systemName: display.isMirrored ? "rectangle.on.rectangle" : "display")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(display.name)
                        .fontWeight(.medium)
                    if display.isMain {
                        badge("MAIN")
                    }
                    if display.isMirrored {
                        badge("MIRRORED")
                    }
                }

                HStack(spacing: 8) {
                    Text(display.summary)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(surfaceDescription(for: display, isSurfaceActive: isSurfaceActive))
                        .font(.caption)
                        .foregroundStyle(isSurfaceActive ? Color.accentColor : Color.secondary)
                }

                if let configuration {
                    Text("Video: \(configuration.assignment.media.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No video assigned")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if display.isMirrored {
                    Text(mirrorDescription(for: display))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                Button("Use Selected Video") {
                    model.assignSelectedMedia(toDisplayPersistentID: display.persistentID)
                }
                .disabled(!model.hasMedia || display.isMirrored || model.importState == .importing)

                if configuration != nil {
                    Button("Clear") {
                        model.clearDisplayAssignment(persistentID: display.persistentID)
                    }
                    .disabled(model.importState == .importing)
                }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(isTarget ? 0.10 : 0.05))
        )
    }

    private func disconnectedRow(_ entry: DisconnectedDisplayConfiguration) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "display.slash")
                .font(.system(size: 18))
                .foregroundStyle(.orange)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.configuration.displayName)
                        .fontWeight(.medium)
                    badge("DISCONNECTED")
                }
                Text("Video: \(entry.configuration.assignment.media.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("The video is kept and applied when this display reconnects.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("Forget") {
                model.forgetDisconnectedDisplay(persistentID: entry.persistentID)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.06))
        )
    }

    private func surfaceDescription(for display: DisplayInfo, isSurfaceActive: Bool) -> String {
        if display.isMirrored {
            return "Follows mirror master"
        }
        if isSurfaceActive {
            return model.wallpaper.isPaused ? "Surface paused" : "Surface playing"
        }
        if model.settings.displayMode == .perDisplay, model.assignedMediaName(for: display.persistentID) != nil {
            return "Assigned, no surface"
        }
        return "No surface"
    }

    private func mirrorDescription(for display: DisplayInfo) -> String {
        guard let mirrorsDisplayID = display.mirrorsDisplayID,
              let master = model.displays.first(where: { $0.id == mirrorsDisplayID }) else {
            return "Mirrored display; the surface is drawn once on the mirror master."
        }
        return "Mirrors \(master.name); the surface is drawn once on the master."
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.16))
            .foregroundStyle(Color.accentColor)
            .clipShape(Capsule())
    }
}
