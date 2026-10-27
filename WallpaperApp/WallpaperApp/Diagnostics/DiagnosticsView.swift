import SwiftUI

@MainActor
struct SurfaceDiagnosticsView: View {
    let model: AppModel

    private var sample: PerformanceSample {
        model.performanceSample
    }

    var body: some View {
        GroupBox("Development Diagnostics") {
            VStack(alignment: .leading, spacing: 12) {
                metrics
                Divider()
                playback
                Divider()
                resourcePolicy
                Divider()
                footer
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Performance sample")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                GridRow {
                    Text("CPU").foregroundStyle(.secondary)
                    Text(sample.cpuSummary)
                        .font(.system(.caption, design: .monospaced))
                }
                GridRow {
                    Text("Memory").foregroundStyle(.secondary)
                    Text(sample.memorySummary)
                        .font(.system(.caption, design: .monospaced))
                }
                GridRow {
                    Text("GPU").foregroundStyle(.secondary)
                    Text(sample.gpuSummary)
                        .font(.system(.caption, design: .monospaced))
                }
                GridRow {
                    Text("Dropped frames").foregroundStyle(.secondary)
                    Text(sample.droppedFrameSummary)
                        .font(.system(.caption, design: .monospaced))
                }
                GridRow {
                    Text("Stalls").foregroundStyle(.secondary)
                    Text("\(sample.stalls)")
                        .font(.system(.caption, design: .monospaced))
                }
                GridRow {
                    Text("Sample window").foregroundStyle(.secondary)
                    Text(String(format: "%.1fs", sample.sampleDuration))
                        .font(.system(.caption, design: .monospaced))
                }
            }
            .font(.callout)

            Text("GPU utilization comes from IOAccelerator performance statistics and can be unavailable on some Macs. Dropped frames are read from AVPlayerItem access logs.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var playback: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Playback")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                GridRow {
                    Text("Preview").foregroundStyle(.secondary)
                    Text(model.playbackState.title)
                        .font(.system(.caption, design: .monospaced))
                }
                GridRow {
                    Text("Wallpaper").foregroundStyle(.secondary)
                    Text("\(model.wallpaper.state.title) · \(model.wallpaper.surfaceCount) surface(s)")
                        .font(.system(.caption, design: .monospaced))
                }
                GridRow {
                    Text("Surface players").foregroundStyle(.secondary)
                    Text("\(model.wallpaper.playerCount)")
                        .font(.system(.caption, design: .monospaced))
                }
                GridRow {
                    Text("Media").foregroundStyle(.secondary)
                    Text(model.selectedMedia?.displayName ?? "none")
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                GridRow {
                    Text("Preview dropped").foregroundStyle(.secondary)
                    Text("\(model.previewDroppedFrameStats.droppedFrames) frames")
                        .font(.system(.caption, design: .monospaced))
                }
            }
            .font(.callout)
        }
    }

    private var resourcePolicy: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Resource policy")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(model.resourceConditions.summary)
                .font(.system(.caption, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)

            Text(model.resourcePolicy.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let pauseReasonSummary = model.pauseReasonSummary {
                Text("Pause reasons: \(pauseReasonSummary)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.diagnostics.versionSummary)
                Text("Schema \(model.settings.schemaVersion) · \(model.surfaceStrategy.title)")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Spacer()

            Button("Copy Diagnostics") {
                model.copyDiagnostics()
            }
            .controlSize(.small)
            .help("Copies a diagnostics report with media file names redacted.")
        }
    }
}
