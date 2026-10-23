import SwiftUI

@MainActor
struct ResourcePolicyCard: View {
    let model: AppModel

    var body: some View {
        GroupBox("Resource Management") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Pause when a fullscreen app is active", isOn: fullscreenBinding)
                Toggle("Pause on battery power", isOn: batteryBinding)
                Toggle("Pause in Low Power Mode", isOn: lowPowerModeBinding)

                Text("Sleep, display sleep and thermal pressure pauses are always enabled to avoid unnecessary playback load.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Power")
                            .foregroundStyle(.secondary)
                        Text(model.resourceConditions.powerSourceTitle)
                    }
                    GridRow {
                        Text("Thermal pressure")
                            .foregroundStyle(.secondary)
                        Text(model.resourceConditions.thermalStateTitle)
                            .foregroundStyle(
                                model.resourceConditions.isThermallyConstrained
                                    ? Color.orange
                                    : Color.primary
                            )
                    }
                    GridRow {
                        Text("Fullscreen app")
                            .foregroundStyle(.secondary)
                        Text(model.resourceConditions.isFullscreenAppActive ? "Active" : "None")
                    }
                    GridRow {
                        Text("Surface players")
                            .foregroundStyle(.secondary)
                        Text("\(model.wallpaper.playerCount)")
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .font(.callout)

                if let pauseReasonSummary = model.pauseReasonSummary {
                    Label("Paused: \(pauseReasonSummary)", systemImage: "pause.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if model.wallpaper.isActive {
                    Label("No resource policy is pausing playback.", systemImage: "play.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var fullscreenBinding: Binding<Bool> {
        Binding(
            get: { model.settings.playback.pauseOnFullscreen },
            set: { model.settings.playback.pauseOnFullscreen = $0 }
        )
    }

    private var batteryBinding: Binding<Bool> {
        Binding(
            get: { model.settings.playback.pauseOnBattery },
            set: { model.settings.playback.pauseOnBattery = $0 }
        )
    }

    private var lowPowerModeBinding: Binding<Bool> {
        Binding(
            get: { model.settings.playback.pauseOnLowPowerMode },
            set: { model.settings.playback.pauseOnLowPowerMode = $0 }
        )
    }
}
