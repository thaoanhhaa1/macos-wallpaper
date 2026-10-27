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

enum MediaContentType {
    static let supportedTypes: [UTType] = [.mpeg4Movie, .quickTimeMovie]
    static let supportedFormatsDescription = "MP4 and MOV video files"
    static let maxFileSizeBytes: Int64 = 20 * 1024 * 1024 * 1024

    private static let quickTimeTopLevelBoxes: Set<String> = [
        "ftyp", "moov", "mdat", "wide", "free", "skip"
    ]

    static func validate(url: URL) throws {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        } catch {
            throw MediaImportError.fileUnreadable
        }

        guard let contentType = values.contentType,
              supportedTypes.contains(where: { contentType.conforms(to: $0) })
        else {
            throw MediaImportError.unsupportedContentType
        }

        guard let fileSize = values.fileSize else {
            throw MediaImportError.fileUnreadable
        }
        guard Int64(fileSize) <= maxFileSizeBytes else {
            throw MediaImportError.fileTooLarge(maxFileSizeBytes)
        }

        try validateFileSignature(url: url, contentType: contentType)
    }

    private static func validateFileSignature(url: URL, contentType: UTType) throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw MediaImportError.fileUnreadable
        }
        defer { try? handle.close() }

        let header: Data
        do {
            guard let data = try handle.read(upToCount: 12), data.count >= 8 else {
                throw MediaImportError.invalidFileSignature
            }
            header = data
        } catch let error as MediaImportError {
            throw error
        } catch {
            throw MediaImportError.fileUnreadable
        }

        let typeRange = (header.startIndex + 4)..<(header.startIndex + 8)
        let boxType = String(decoding: header[typeRange], as: UTF8.self)
        let acceptedBoxes = contentType.conforms(to: .quickTimeMovie)
            ? quickTimeTopLevelBoxes
            : ["ftyp"]

        guard acceptedBoxes.contains(boxType) else {
            throw MediaImportError.invalidFileSignature
        }
    }
}

@MainActor
struct MediaImporter {
    static let supportedContentTypes = MediaContentType.supportedTypes
    static let supportedFormatsDescription = MediaContentType.supportedFormatsDescription

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

    static func validateContentType(of url: URL) throws {
        try MediaContentType.validate(url: url)
    }

    func importVideo(at url: URL) async throws -> MediaSelection {
        Log.media.notice("Validating media \(url.lastPathComponent, privacy: .private)")
        try Self.validateContentType(of: url)
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
