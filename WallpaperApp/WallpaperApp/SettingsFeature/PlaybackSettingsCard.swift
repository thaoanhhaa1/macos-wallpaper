import SwiftUI

@MainActor
struct PlaybackSettingsCard: View {
    let model: AppModel

    var body: some View {
        GroupBox("Playback") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Scaling", selection: scalingBinding) {
                    ForEach(ScalingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Video scaling")
                .accessibilityHint("Choose how the video fits each display")

                Text(scalingDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Toggle("Loop video", isOn: loopBinding)
                    .accessibilityHint("Restart automatically when the video reaches the end")

                Toggle("Mute audio", isOn: muteBinding)

                HStack(spacing: 10) {
                    Text("Volume")
                        .frame(width: 58, alignment: .leading)
                    Slider(value: volumeBinding, in: 0...1)
                        .disabled(model.settings.playback.isMuted)
                        .accessibilityLabel("Volume")
                        .accessibilityValue("\(Int(model.settings.playback.volume * 100)) percent")
                    Text("\(Int(model.settings.playback.volume * 100))%")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }

                Text("Playback settings apply immediately to the preview and every wallpaper surface.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var scalingDescription: String {
        switch model.settings.playback.scalingMode {
        case .aspectFit:
            "Shows the entire video and adds letterboxing when its aspect ratio differs from the display."
        case .aspectFill:
            "Fills the display by scaling the video up and cropping the overflow around the center."
        case .centerCrop:
            "Fills the display and keeps the center of the frame visible, cropping the edges."
        }
    }

    private var scalingBinding: Binding<ScalingMode> {
        Binding(
            get: { model.settings.playback.scalingMode },
            set: { model.settings.playback.scalingMode = $0 }
        )
    }

    private var loopBinding: Binding<Bool> {
        Binding(
            get: { model.settings.playback.loopEnabled },
            set: { model.settings.playback.loopEnabled = $0 }
        )
    }

    private var muteBinding: Binding<Bool> {
        Binding(
            get: { model.settings.playback.isMuted },
            set: { model.settings.playback.isMuted = $0 }
        )
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { model.settings.playback.volume },
            set: { model.settings.playback.volume = $0 }
        )
    }
}
