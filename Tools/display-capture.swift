import AppKit
import Foundation
import ScreenCaptureKit

@main
struct DisplayCaptureTool {
    static func main() async {
        let args = CommandLine.arguments
        if args.count >= 3, args[1] == "--analyze" {
            do {
                let image = try loadImage(path: args[2])
                print(stats(for: image))
            } catch {
                fputs("analyze error: \(error)\n", stderr)
                exit(4)
            }
            return
        }

        guard args.count >= 3, let displayID = UInt32(args[1]) else {
            fputs("usage: display-capture <displayID> <path> | display-capture --analyze <path>\n", stderr)
            exit(2)
        }
        let path = args[2]

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                fputs("display \(displayID) not found; available: \(content.displays.map(\.displayID))\n", stderr)
                exit(3)
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            config.showsCursor = false
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            try writePNG(image, to: path)
            print("CAPTURED \(display.width)x\(display.height) \(path)")
            print(stats(for: image))
        } catch {
            fputs("capture error: \(error)\n", stderr)
            exit(5)
        }
    }

    private static func loadImage(path: String) throws -> CGImage {
        guard let image = NSImage(contentsOfFile: path),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "DisplayCaptureTool", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not load \(path)"])
        }
        return cgImage
    }

    private static func writePNG(_ image: CGImage, to path: String) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "DisplayCaptureTool", code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
        }
        try data.write(to: URL(fileURLWithPath: path))
    }

    private static func stats(for image: CGImage) -> String {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return "ANALYSIS_ERROR could-not-create-context"
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var brightColor = 0
        var saturated = 0
        var red = 0
        var sumR = 0
        var sumG = 0
        var sumB = 0
        let total = width * height

        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[offset])
            let g = Int(pixels[offset + 1])
            let b = Int(pixels[offset + 2])
            let maxValue = max(r, max(g, b))
            let minValue = min(r, min(g, b))
            if maxValue > 200, maxValue - minValue > 30 { brightColor += 1 }
            if maxValue - minValue > 80 { saturated += 1 }
            if r > 180, g < 90, b < 90 { red += 1 }
            sumR += r
            sumG += g
            sumB += b
        }

        let brightPercent = 100.0 * Double(brightColor) / Double(total)
        let saturatedPercent = 100.0 * Double(saturated) / Double(total)
        let redPercent = 100.0 * Double(red) / Double(total)
        let meanR = sumR / total
        let meanG = sumG / total
        let meanB = sumB / total

        return String(
            format: "ANALYSIS width=%d height=%d bright_color=%.2f saturated=%.2f red=%.2f mean=%d,%d,%d verdict=%@",
            width,
            height,
            brightPercent,
            saturatedPercent,
            redPercent,
            meanR,
            meanG,
            meanB,
            brightPercent > 10 ? "VISIBLE" : "NOT_VISIBLE"
        )
    }
}
