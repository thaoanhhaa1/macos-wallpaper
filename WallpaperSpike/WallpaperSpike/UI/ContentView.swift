import SwiftUI

@MainActor
struct ContentView: View {
    @StateObject private var model = SpikeModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statusCard
                videoSection
                surfaceSection
                displaySection
                probeSection
                diagnosticsSection
                footer
            }
            .padding(22)
        }
        .frame(minWidth: 780, minHeight: 860)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Wallpaper Spike")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text("Phase 0 feasibility: video-backed desktop surface using public AppKit, CoreGraphics and AVFoundation APIs.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var statusCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: statusSymbol)
                        .foregroundStyle(statusColor)
                        .font(.title3)
                    Text(model.statusMessage)
                        .font(.headline)
                        .textSelection(.enabled)
                    Spacer()
                    if model.isGeneratingTestVideo {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let error = model.errorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                HStack(spacing: 16) {
                    Label("\(model.surfaceCount) surface window(s)", systemImage: "rectangle.on.rectangle")
                    Label("\(model.playingCount) playing", systemImage: "play.fill")
                    Spacer()
                    Text(model.configurationSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            .padding(6)
        }
    }

    private var videoSection: some View {
        GroupBox("Video under test") {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.videoInfo)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Button("Choose Video…", action: model.chooseVideo)
                    Button(model.isGeneratingTestVideo ? "Generating…" : "Generate Test Pattern", action: model.generateTestVideo)
                        .disabled(model.isGeneratingTestVideo)
                    Button("Reveal in Finder", action: model.revealSelectedVideo)
                        .disabled(model.selectedVideoURL == nil)
                    Spacer()
                }

                Text("The generated fixture is a 4-second 1280×720 H.264 color-bar clip with a timecode overlay. It makes loop and ordering checks reproducible without external assets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var surfaceSection: some View {
        GroupBox("Wallpaper surface") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Target display", selection: $model.configuration.target) {
                    ForEach(SurfaceTarget.allCases) { target in
                        Text(target.title).tag(target)
                    }
                }
                .pickerStyle(.segmented)

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Window level", selection: $model.configuration.level) {
                            ForEach(SurfaceLevelStrategy.allCases) { strategy in
                                Text(strategy.title).tag(strategy)
                            }
                        }
                        Text("Computed level: \(model.configuration.level.windowLevel.rawValue) · \(model.configuration.level.detail)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Scaling", selection: $model.configuration.scalingMode) {
                            ForEach(ScalingMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        Text("Video gravity: \(String(describing: model.configuration.scalingMode.videoGravity.rawValue))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 20) {
                    Toggle("Click-through (ignores mouse events)", isOn: $model.configuration.clickThrough)
                    Toggle("Muted", isOn: $model.configuration.muted)
                    Spacer()
                }

                HStack(spacing: 10) {
                    Button("Start / Apply Surface", action: model.startSurface)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.selectedVideoURL == nil)
                    Button(model.isPaused ? "Resume" : "Pause", action: model.togglePlayback)
                        .disabled(!model.isSurfaceRunning)
                    Button("Stop", role: .destructive, action: model.stopSurface)
                        .disabled(!model.isSurfaceRunning)
                    Spacer()
                    if model.isSurfaceRunning {
                        Text("Collection behavior: canJoinAllSpaces, stationary, ignoresCycle, fullScreenNone")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("The recommended probe is “Below desktop icons” (desktopIconWindow − 1). The other levels are included so the self-test can compare window ordering against the system wallpaper and Finder desktop windows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }

    private var displaySection: some View {
        GroupBox("Displays") {
            VStack(alignment: .leading, spacing: 8) {
                if model.screens.isEmpty {
                    Text("No displays reported by NSScreen.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.screens) { screen in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(screen.name)
                                .fontWeight(.semibold)
                            if screen.isMain {
                                badge("MAIN", color: .blue)
                            }
                            if screen.isBuiltin {
                                badge("BUILT-IN", color: .green)
                            }
                            Spacer()
                        }
                        Text(screen.summary)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Divider()

                    Text("Scale factors in use: \(model.screens.map { String(format: "%.1fx", $0.backingScaleFactor) }.sorted().joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var probeSection: some View {
        GroupBox("Window ordering probe") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Probe Window Ordering", action: model.probeWindows)
                        .disabled(!model.isSurfaceRunning)
                    Text("Reads CGWindowListCopyWindowInfo and compares the surface against Finder desktop-icon and system-wallpaper windows.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let analysis = model.lastWindowAnalysis {
                    HStack(spacing: 18) {
                        verificationBadge("Behind desktop icons", value: analysis.isBehindDesktopIcons)
                        verificationBadge("Above system wallpaper", value: analysis.isAboveSystemWallpaper)
                        verificationBadge("Surface on screen", value: analysis.surfaceFound)
                    }
                    Text(analysis.explanation)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Run a surface, then probe to compare actual WindowServer ordering.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var diagnosticsSection: some View {
        GroupBox("Diagnostics log") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Most recent events appear first. Copy this log into the Phase 0 report.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy Diagnostics", action: model.copyDiagnostics)
                }

                ScrollView {
                    Text(model.diagnosticsText.isEmpty ? "No events yet." : model.diagnosticsText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 240)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25))
                )
            }
            .padding(6)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("Public APIs only: NSWindow, NSWindow.Level via CGWindowLevelForKey, NSWindow.CollectionBehavior, AVPlayer/AVPlayerLayer/AVPlayerLooper, NSScreen and CGWindowListCopyWindowInfo.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Before closing Phase 0, run the self-test and complete the manual matrix in FEASIBILITY.md.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Testing note: on macOS 26+, ScreenCaptureKit and screencapture can omit negative-level windows that are visible on the physical display. Trust the display for visual checks.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var statusSymbol: String {
        if model.errorMessage != nil { return "exclamationmark.triangle.fill" }
        if model.isSurfaceRunning { return "play.rectangle.fill" }
        return "circle.dashed"
    }

    private var statusColor: Color {
        if model.errorMessage != nil { return .red }
        if model.isSurfaceRunning { return .green }
        return .secondary
    }

    private func verificationBadge(_ title: String, value: Bool?) -> some View {
        let symbol: String
        let color: Color
        switch value {
        case .some(true):
            symbol = "checkmark.circle.fill"
            color = .green
        case .some(false):
            symbol = "xmark.circle.fill"
            color = .red
        case .none:
            symbol = "questionmark.circle.fill"
            color = .orange
        }

        return HStack(spacing: 4) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.16))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
