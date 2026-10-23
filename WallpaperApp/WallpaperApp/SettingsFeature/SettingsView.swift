import AppKit
import SwiftUI

@MainActor
struct SettingsView: View {
    let model: AppModel

    @State private var isDropTargeted = false

    var body: some View {
        TabView {
            generalPage
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            playbackPage
                .tabItem {
                    Label("Playback", systemImage: "play.rectangle")
                }

            displaysPage
                .tabItem {
                    Label("Displays", systemImage: "display")
                }
        }
        .frame(minWidth: 700, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.isFileURL && !$0.hasDirectoryPath }) else {
                return false
            }
            Task { await model.openDroppedVideo(at: url) }
            return true
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
        .overlay {
            if isDropTargeted {
                dropOverlay
            }
        }
        .onAppear {
            Log.settings.notice("Settings window appeared")
        }
    }

    private var generalPage: some View {
        settingsPage(
            subtitle: "Choose a video, apply it to the desktop, and revisit recent media.",
            systemImage: "play.rectangle.on.rectangle.fill"
        ) {
            MediaCard(model: model)
            WallpaperCard(model: model)
            RecentVideosCard(model: model)
            developmentSection
            diagnosticsSection
        }
    }

    private var playbackPage: some View {
        settingsPage(
            subtitle: "Control looping, audio, scaling, and when playback pauses.",
            systemImage: "play.rectangle"
        ) {
            PlaybackSettingsCard(model: model)
            ResourcePolicyCard(model: model)
        }
    }

    private var displaysPage: some View {
        settingsPage(
            subtitle: "Choose which displays show a wallpaper and how many surfaces are created.",
            systemImage: "display"
        ) {
            DisplaySettingsCard(model: model)
            systemSection
        }
    }

    private func settingsPage<Content: View>(
        subtitle: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(subtitle: subtitle, systemImage: systemImage)
                content()
                footer
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(subtitle: String, systemImage: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Wallpaper")
                    .font(.system(.title, design: .rounded).weight(.bold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            badge("PHASE 7")
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

                if let mirrored = model.displays.first(where: \.isMirrored) {
                    Label(
                        "\(mirrored.name) is mirrored; a single surface is drawn on the master.",
                        systemImage: "rectangle.on.rectangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Divider()

                LabeledContent("Surface strategy") {
                    Text(model.surfaceStrategy.title)
                }
                Text(model.surfaceStrategy.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Saved display configurations") {
                    Text("\(model.persistedDisplayConfigurationCount)")
                        .font(.system(.caption, design: .monospaced))
                }
                Text("Wallpaper assignments are stored as security-scoped bookmarks and restored on launch.")
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

    @ViewBuilder
    private var diagnosticsSection: some View {
        #if DEBUG
        SurfaceDiagnosticsView(model: model)
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

            Text("Phase 7: grouped settings, keyboard-friendly native controls, drag-and-drop, recent videos, scaling previews and clearer permission/format messages.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var dropOverlay: some View {
        ZStack {
            Color.accentColor.opacity(0.08)

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 3, dash: [9, 7])
                )
                .padding(18)

            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Drop video to preview")
                    .font(.title3.weight(.semibold))
                Text(MediaImporter.supportedFormatsDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(22)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.16))
            .foregroundStyle(Color.accentColor)
            .clipShape(Capsule())
            .accessibilityLabel("Version \(text)")
    }
}
