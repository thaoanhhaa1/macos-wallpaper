import AVFoundation
import CoreMedia
import Foundation
import UniformTypeIdentifiers

struct MediaMetadata: Equatable {
    var duration: TimeInterval
    var pixelSize: CGSize?
    var frameRate: Double?
    var hasAudio: Bool
    var videoCodec: String?

    var resolutionText: String? {
        guard let pixelSize else { return nil }
        let width = Int(pixelSize.width.rounded())
        let height = Int(pixelSize.height.rounded())
        guard width > 0, height > 0 else { return nil }
        return "\(width)×\(height)"
    }

    var frameRateText: String? {
        guard let frameRate, frameRate > 0, frameRate.isFinite else { return nil }
        return String(format: "%.2f fps", frameRate)
    }

    var durationText: String {
        TimecodeFormatter.string(from: duration)
    }

    var summary: String {
        var parts: [String] = []
        if let resolutionText { parts.append(resolutionText) }
        if let frameRateText { parts.append(frameRateText) }
        if duration > 0 { parts.append(durationText) }
        if let videoCodec { parts.append(videoCodec) }
        parts.append(hasAudio ? "audio" : "no audio")
        return parts.joined(separator: " · ")
    }
}

enum MediaImportError: LocalizedError, Equatable {
    case fileMissing
    case fileUnreadable
    case unsupportedContentType
    case fileTooLarge(Int64)
    case invalidFileSignature
    case notPlayable
    case noVideoTrack
    case bookmarkCreationFailed(String)
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileMissing:
            "The selected file no longer exists."
        case .fileUnreadable:
            "The app doesn't have permission to read this file. Choose it again with Choose Video… to grant access."
        case .unsupportedContentType:
            "This file isn't an \(MediaContentType.supportedFormatsDescription). Choose an MP4 or MOV video."
        case .fileTooLarge(let limit):
            "This video exceeds the \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)) limit. Choose a smaller MP4 or MOV video."
        case .invalidFileSignature:
            "This file isn't a valid MP4 or MOV container. Choose a video exported in a supported format."
        case .notPlayable:
            "This video format or codec isn't supported. Try H.264 or HEVC video in an MP4 or MOV file."
        case .noVideoTrack:
            "This file doesn't contain a video track."
        case .bookmarkCreationFailed(let message):
            "The video can be previewed, but the app couldn't save permission to reopen it later: \(message)"
        case .loadFailed(let message):
            "The video couldn't be read: \(message)"
        }
    }
}

enum MediaInspector {
    static func inspect(url: URL) async throws -> MediaMetadata {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            throw MediaImportError.fileMissing
        }
        guard fileManager.isReadableFile(atPath: url.path) else {
            throw MediaImportError.fileUnreadable
        }
        try MediaContentType.validate(url: url)

        do {
            let asset = AVURLAsset(url: url)
            guard try await asset.load(.isPlayable) else {
                throw MediaImportError.notPlayable
            }

            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                throw MediaImportError.noVideoTrack
            }

            let duration = try await asset.load(.duration)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            let naturalSize = try await videoTrack.load(.naturalSize)
            let transform = try await videoTrack.load(.preferredTransform)
            let frameRate = try await videoTrack.load(.nominalFrameRate)
            let formatDescriptions = try await videoTrack.load(.formatDescriptions)

            let orientedSize = naturalSize.applying(transform)
            let pixelSize = CGSize(
                width: abs(orientedSize.width),
                height: abs(orientedSize.height)
            )

            let seconds = duration.seconds
            let metadata = MediaMetadata(
                duration: seconds.isFinite && seconds > 0 ? seconds : 0,
                pixelSize: pixelSize,
                frameRate: frameRate > 0 ? Double(frameRate) : nil,
                hasAudio: !audioTracks.isEmpty,
                videoCodec: formatDescriptions.first.map { codecName(for: $0) }
            )

            Log.media.info(
                "Inspected video duration=\(metadata.duration, privacy: .public) audio=\(metadata.hasAudio, privacy: .public) codec=\(metadata.videoCodec ?? "unknown", privacy: .public)"
            )
            return metadata
        } catch let error as MediaImportError {
            throw error
        } catch {
            throw MediaImportError.loadFailed(error.localizedDescription)
        }
    }

    private static func codecName(for description: CMFormatDescription) -> String {
        let subType = CMFormatDescriptionGetMediaSubType(description)
        switch subType {
        case kCMVideoCodecType_H264:
            return "H.264"
        case kCMVideoCodecType_HEVC:
            return "HEVC"
        case kCMVideoCodecType_AppleProRes422:
            return "ProRes 422"
        case kCMVideoCodecType_AppleProRes4444:
            return "ProRes 4444"
        case kCMVideoCodecType_JPEG:
            return "JPEG"
        default:
            return fourCC(subType)
        }
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
    }
}

enum TimecodeFormatter {
    static func string(from seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}
