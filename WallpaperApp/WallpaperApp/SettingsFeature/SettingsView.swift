import AppKit
import SwiftUI

@MainActor
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                MediaCard(model: model)
                WallpaperCard(model: model)
                systemSection
                developmentSection
                footer
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 640, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            Log.settings.notice("Settings window appeared")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "play.rectangle.on.rectangle.fill")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("Wallpaper")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Video wallpaper for macOS")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            badge("PHASE 3")
        }
    }

    private var systemSection: some View {
        GroupBox("System") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label(
                        "\(model.displays.count) display\(model.displays.count == 1 ? "" : "s") detected",
                        systemImage: "display"
                    )
                    .fontWeight(.medium)
                    Spacer()
                    Text(model.diagnostics.osVersion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(model.displays) { display in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(display.name)
                            .font(.callout)
                        if display.isMain {
                            badge("MAIN")
                        }
                        Spacer()
                        Text(display.summary)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Divider()

                LabeledContent("Surface strategy") {
                    Text(model.surfaceStrategy.title)
                }
                Text(model.surfaceStrategy.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Log subsystem") {
                    Text(model.diagnostics.logSubsystem)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var developmentSection: some View {
        #if DEBUG
        if let fixture = model.developmentFixtureURL {
            GroupBox("Development") {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fixture.lastPathComponent)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        Text("Bundled fixture for debug builds only. Preview it to exercise validation, loop and cleanup without picking a file.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Preview Fixture") {
                        Task { await model.useDevelopmentFixture() }
                    }
                    .disabled(model.importState == .importing)
                    Button("Reveal in Finder") {
                        model.revealDevelopmentFixture()
                    }
                }
                .padding(6)
            }
        }
        #endif
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 8) {
                Text(model.diagnostics.versionSummary)
                Text("·")
                Text(model.diagnostics.bundleIdentifier)
                    .textSelection(.enabled)
                Spacer()
                Button("Copy Diagnostics") {
                    model.copyDiagnostics()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("Phase 3: apply, remove and restore a click-through video wallpaper behind desktop icons.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
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
