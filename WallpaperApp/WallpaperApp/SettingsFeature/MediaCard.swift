import AVFoundation
import SwiftUI

@MainActor
struct MediaCard: View {
    let model: AppModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if model.hasMedia {
                    preview
                    details
                    if case .failed(let message) = model.importState {
                        inlineError(message)
                    }
                    controls
                    Divider()
                    actions
                } else {
                    switch model.importState {
                    case .importing:
                        importingState
                    case .failed(let message):
                        failedState(message)
                    case .idle:
                        emptyState
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black)

            VideoPreviewView(player: model.playback.player, videoGravity: videoGravity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if !model.isPlaying {
                Circle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: 54, height: 54)
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                            .offset(x: 2)
                    }
            }

            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Label(model.playbackState.title, systemImage: model.status.symbolName)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)

                    Spacer()

                    Text(
                        "\(TimecodeFormatter.string(from: model.playback.currentTime)) / \(TimecodeFormatter.string(from: model.playback.duration))"
                    )
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.white)
                }
                .padding(10)
            }
        }
        .frame(height: 260)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            model.togglePlayPause()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Video preview, \(model.playbackState.title)")
        .accessibilityHint("Click to toggle playback")
    }

    private var details: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.selectedMedia?.displayName ?? "Video wallpaper")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.mediaMetadata?.summary ?? "Metadata unavailable")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    model.togglePlayPause()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 16)
                }
                .help(model.isPlaying ? "Pause" : "Play")

                Button {
                    model.restart()
                } label: {
                    Image(systemName: "gobackward")
                }
                .help("Restart from the beginning")

                Text(TimecodeFormatter.string(from: model.playback.currentTime))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Slider(value: seekBinding, in: 0...max(model.playback.duration, 0.1))
                    .disabled(model.playback.duration <= 0)
                    .accessibilityLabel("Playback position")

                Text(TimecodeFormatter.string(from: model.playback.duration))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Button {
                    model.toggleMute()
                } label: {
                    Image(systemName: model.settings.playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .help(model.settings.playback.isMuted ? "Unmute" : "Mute")

                Slider(value: volumeBinding, in: 0...1)
                    .frame(width: 90)
                    .disabled(model.settings.playback.isMuted)
                    .accessibilityLabel("Volume")

                Toggle("Loop", isOn: loopBinding)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Restart automatically when the video reaches the end")
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Choose Video…") {
                Task { await model.chooseVideo() }
            }
            .disabled(model.importState == .importing)

            if model.importState == .importing {
                ProgressView()
                    .controlSize(.small)
                Text("Validating video…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(MediaImporter.supportedFormatsDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        HStack(alignment: .center, spacing: 18) {
            placeholderIcon("play.rectangle.on.rectangle")

            VStack(alignment: .leading, spacing: 6) {
                Text("No wallpaper selected")
                    .font(.title3.weight(.semibold))
                Text("Choose a video to preview it here. Playback starts automatically and cleanup happens when you replace it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button("Choose Video…") {
                        Task { await model.chooseVideo() }
                    }
                    Text(MediaImporter.supportedFormatsDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(8)
    }

    private var importingState: some View {
        HStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            VStack(alignment: .leading, spacing: 4) {
                Text("Validating video…")
                    .font(.title3.weight(.semibold))
                Text("Reading track, duration and codec information.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(8)
        .frame(minHeight: 120)
    }

    private func failedState(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 6) {
                Text("Couldn't use this video")
                    .font(.title3.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Choose Another Video…") {
                    Task { await model.chooseVideo() }
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(minHeight: 120)
    }

    private func inlineError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func placeholderIcon(_ systemName: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
            Image(systemName: systemName)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
        }
        .frame(width: 96, height: 68)
    }

    private var videoGravity: AVLayerVideoGravity {
        model.settings.playback.scalingMode.videoGravity
    }

    private var seekBinding: Binding<Double> {
        Binding(
            get: {
                min(max(0, model.playback.currentTime), max(model.playback.duration, 0.1))
            },
            set: { value in
                model.seek(to: value)
            }
        )
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { model.settings.playback.volume },
            set: { model.settings.playback.volume = $0 }
        )
    }

    private var loopBinding: Binding<Bool> {
        Binding(
            get: { model.settings.playback.loopEnabled },
            set: { model.settings.playback.loopEnabled = $0 }
        )
    }
}
