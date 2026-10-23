import SwiftUI

@MainActor
struct RecentVideosCard: View {
    let model: AppModel

    var body: some View {
        GroupBox("Recent Videos") {
            VStack(alignment: .leading, spacing: 10) {
                if model.recentMedia.isEmpty {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("No recent videos")
                                .fontWeight(.medium)
                            Text("Videos you import or drop into this window appear here so you can preview them again quickly.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    ForEach(model.recentMedia) { reference in
                        recentRow(reference)
                        if reference.id != model.recentMedia.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func recentRow(_ reference: MediaReference) -> some View {
        let isSelected = model.selectedMedia?.identifier == reference.identifier

        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: isSelected ? "play.rectangle.fill" : "film")
                .font(.title3)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(reference.displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(durationText(reference))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            Button("Preview") {
                Task { await model.openRecentVideo(reference) }
            }
            .disabled(model.importState == .importing)
            .accessibilityLabel("Preview \(reference.displayName)")

            Button {
                model.removeRecentMedia(reference)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove from Recent Videos")
            .accessibilityLabel("Remove \(reference.displayName) from Recent Videos")
        }
        .padding(.vertical, 2)
    }

    private func durationText(_ reference: MediaReference) -> String {
        guard let duration = reference.lastKnownDuration, duration > 0 else {
            return "Saved video"
        }
        return "Duration \(TimecodeFormatter.string(from: duration))"
    }
}
