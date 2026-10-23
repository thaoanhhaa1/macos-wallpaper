import SwiftUI

@MainActor
struct EmptyWallpaperCard: View {
    var body: some View {
        GroupBox {
            HStack(alignment: .center, spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                    Image(systemName: "play.rectangle.on.rectangle")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 96, height: 68)

                VStack(alignment: .leading, spacing: 6) {
                    Text("No wallpaper selected")
                        .font(.title3.weight(.semibold))
                    Text("Choose a video to preview it here and apply it to a display.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button("Choose Video…") {}
                            .disabled(true)
                            .help("Video import arrives in Phase 2")
                        Text("Import arrives in Phase 2.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }

                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
