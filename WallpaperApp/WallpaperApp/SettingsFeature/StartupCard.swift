import SwiftUI

@MainActor
struct StartupCard: View {
    let model: AppModel

    var body: some View {
        GroupBox("Startup & Distribution") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Launch Wallpaper at login", isOn: launchAtLoginBinding)
                    .accessibilityHint("Open Wallpaper automatically after you sign in to this Mac")

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(model.launchAtLoginStatus, systemImage: statusSymbol)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(statusColor)

                    if model.launchAtLoginRequiresApproval {
                        Button("Open Login Items…") {
                            model.openLoginItemsSettings()
                        }
                    }

                    Spacer()
                }

                Text(model.launchAtLoginDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let error = model.launchAtLoginError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                LabeledContent("Signature") {
                    Text(model.distributionInfo.signatureSummary)
                }
                LabeledContent("Hardened runtime") {
                    Text(model.distributionInfo.hardenedRuntimeSummary)
                }
                LabeledContent("App Sandbox") {
                    Text(model.distributionInfo.sandboxSummary)
                }
                LabeledContent("Installed in Applications") {
                    Text(model.distributionInfo.isInApplications ? "Yes" : "No")
                }

                Text("Launch at login uses the system Login Items service. macOS may ask you to approve Wallpaper in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            model.refreshLaunchAtLoginStatus()
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.isLaunchAtLoginEnabled },
            set: { model.setLaunchAtLogin($0) }
        )
    }

    private var statusSymbol: String {
        switch model.launchAtLoginState {
        case .enabled: "checkmark.circle.fill"
        case .requiresApproval: "exclamationmark.triangle.fill"
        case .notFound: "xmark.circle.fill"
        case .notRegistered: "circle"
        }
    }

    private var statusColor: Color {
        switch model.launchAtLoginState {
        case .enabled: .green
        case .requiresApproval: .orange
        case .notFound: .red
        case .notRegistered: .secondary
        }
    }
}
