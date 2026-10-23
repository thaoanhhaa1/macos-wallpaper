import AVFoundation
import CoreGraphics
import CoreText
import Foundation

enum TestVideoFactory {
    static var fixtureDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WallpaperSpike/Fixtures", isDirectory: true)
    }

    static func makeTestVideo(
        duration: Double = 4,
        width: Int = 1280,
        height: Int = 720,
        fps: Int = 30,
        recreate: Bool = false
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)

        let seconds = max(1, Int(duration.rounded()))
        let url = fixtureDirectory
            .appendingPathComponent("test-pattern-\(width)x\(height)-\(seconds)s-\(fps)fps.mp4")

        if !recreate, FileManager.default.fileExists(atPath: url.path),
           let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
           size.intValue > 1_000 {
            Log.app.debug("Reusing test video at \(url.path, privacy: .public)")
            return url
        }

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        Log.app.notice("Generating test video \(url.lastPathComponent, privacy: .public)")
        try writeVideo(to: url, duration: seconds, width: width, height: height, fps: fps)

        let asset = AVURLAsset(url: url)
        let loadedDuration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty, loadedDuration.seconds > 0 else {
            throw SpikeError.testVideoGenerationFailed("Generated file is not a readable video")
        }

        Log.app.notice("Generated \(url.lastPathComponent, privacy: .public) duration=\(loadedDuration.seconds, privacy: .public)s")
        return url
    }

    private static func writeVideo(to url: URL, duration: Int, width: Int, height: Int, fps: Int) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 5_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps
            ]
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )

        guard writer.canAdd(input) else {
            throw SpikeError.testVideoGenerationFailed("AVAssetWriter rejected the video input")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw SpikeError.testVideoGenerationFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = duration * fps
        guard let pool = adaptor.pixelBufferPool else {
            throw SpikeError.testVideoGenerationFailed("Pixel buffer pool is unavailable")
        }

        for frame in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.002)
            }

            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
            guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
                throw SpikeError.testVideoGenerationFailed("Could not allocate a pixel buffer")
            }

            autoreleasepool {
                drawFrame(
                    into: buffer,
                    width: width,
                    height: height,
                    frame: frame,
                    totalFrames: totalFrames,
                    fps: fps
                )
            }

            let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw SpikeError.testVideoGenerationFailed(writer.error?.localizedDescription ?? "append failed at frame \(frame)")
            }
        }

        input.markAsFinished()

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        semaphore.wait()

        guard writer.status == .completed else {
            throw SpikeError.testVideoGenerationFailed(writer.error?.localizedDescription ?? "finishWriting failed")
        }
    }

    private static func drawFrame(
        into buffer: CVPixelBuffer,
        width: Int,
        height: Int,
        frame: Int,
        totalFrames: Int,
        fps: Int
    ) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return }

        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1))
        context.fill(canvas)

        let barColors: [CGColor] = [
            CGColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1),
            CGColor(red: 1.00, green: 0.90, blue: 0.15, alpha: 1),
            CGColor(red: 0.10, green: 0.85, blue: 0.90, alpha: 1),
            CGColor(red: 0.20, green: 0.85, blue: 0.30, alpha: 1),
            CGColor(red: 0.95, green: 0.25, blue: 0.85, alpha: 1),
            CGColor(red: 0.95, green: 0.20, blue: 0.20, alpha: 1),
            CGColor(red: 0.20, green: 0.35, blue: 0.95, alpha: 1),
            CGColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1)
        ]

        let barHeight = CGFloat(height) * 0.68
        let barWidth = CGFloat(width) / CGFloat(barColors.count)
        for (index, color) in barColors.enumerated() {
            context.setFillColor(color)
            context.fill(CGRect(x: CGFloat(index) * barWidth, y: 0, width: barWidth + 1, height: barHeight))
        }

        let progress = CGFloat(frame) / CGFloat(max(1, totalFrames - 1))
        let sweepX = progress * CGFloat(width - 12)
        context.setFillColor(CGColor(red: 1, green: 0.25, blue: 0.05, alpha: 0.95))
        context.fill(CGRect(x: sweepX, y: 0, width: 12, height: barHeight))

        let infoHeight = CGFloat(height) - barHeight
        context.setFillColor(CGColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1))
        context.fill(CGRect(x: 0, y: barHeight, width: CGFloat(width), height: infoHeight))

        let seconds = Double(frame) / Double(fps)
        let timecode = String(format: "%02d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
        let title = "WALLPAPER SPIKE · \(width)x\(height) · \(fps) fps"
        let subtitle = "t=\(timecode)   frame \(frame)/\(totalFrames - 1)"

        drawText(title, in: context, origin: CGPoint(x: 32, y: barHeight + infoHeight * 0.18), size: 34)
        drawText(subtitle, in: context, origin: CGPoint(x: 32, y: barHeight + infoHeight * 0.54), size: 28)
    }

    private static func drawText(_ text: String, in context: CGContext, origin: CGPoint, size: CGFloat) {
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                red: 1, green: 1, blue: 1, alpha: 1
            )
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = origin
        CTLineDraw(line, context)
    }
}
