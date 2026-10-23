import AppKit
import Foundation
import UniformTypeIdentifiers

enum MediaImportState: Equatable {
    case idle
    case importing
    case failed(String)
}

struct MediaSelection {
    var url: URL
    var reference: MediaReference
    var metadata: MediaMetadata
}

@MainActor
struct MediaImporter {
    static let supportedContentTypes: [UTType] = [.mpeg4Movie, .quickTimeMovie]
    static let supportedFormatsDescription = "MP4 and MOV video files"

    func presentOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a Video Wallpaper"
        panel.message = "Select an \(Self.supportedFormatsDescription)."
        panel.prompt = "Choose"
        panel.allowedContentTypes = Self.supportedContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true

        guard panel.runModal() == .OK else {
            Log.media.info("Video import cancelled")
            return nil
        }
        return panel.url
    }

    func importVideo(at url: URL) async throws -> MediaSelection {
        Log.media.notice("Validating media \(url.lastPathComponent, privacy: .public)")
        let metadata = try await MediaInspector.inspect(url: url)

        let bookmarkData: Data
        do {
            bookmarkData = try MediaBookmark.makeBookmarkData(for: url)
        } catch {
            throw MediaImportError.bookmarkCreationFailed(error.localizedDescription)
        }

        let reference = MediaReference(
            bookmarkData: bookmarkData,
            displayName: url.lastPathComponent,
            lastKnownDuration: metadata.duration
        )

        return MediaSelection(url: url, reference: reference, metadata: metadata)
    }
}
