import Foundation

struct PlaybackSample: Codable {
    var currentTime: Double
    var rate: Float
    var isPlaying: Bool
    var isMuted: Bool

    var summary: String {
        String(format: "t=%.2fs rate=%.2f playing=%@", currentTime, rate, isPlaying ? "yes" : "no")
    }
}

struct LevelTrial: Codable {
    var strategy: String
    var levelValue: Int
    var levelDetail: String
    var windowNumber: Int
    var playback: PlaybackSample
    var order: WindowOrderAnalysis
    var notes: [String]
}

struct MultiDisplaySurfaceTrial: Codable {
    var displayID: UInt32
    var screenName: String
    var scaleFactor: Double
    var windowNumber: Int
    var playback: PlaybackSample
    var order: WindowOrderAnalysis
}

struct MultiDisplayTrial: Codable {
    var surfaces: [MultiDisplaySurfaceTrial]
    var notes: [String]
}

struct LoopTrial: Codable {
    var strategy: String
    var videoDuration: Double
    var firstSample: PlaybackSample
    var secondSample: PlaybackSample
    var wrapped: Bool?
    var notes: [String]
}

struct ManualCheck: Codable, Identifiable {
    var id: String { key }
    var key: String
    var title: String
    var question: String
    var status: String
    var instructions: String
}

struct SelfTestReport: Codable {
    var generatedAt: Date
    var startedAt: Date
    var finishedAt: Date?
    var durationSeconds: Double?
    var osVersion: String
    var appVersion: String
    var architecture: String
    var videoPath: String?
    var videoDuration: Double?
    var screens: [DisplayInfo]
    var distinctScaleFactors: [Double]
    var levelTrials: [LevelTrial]
    var loopTrial: LoopTrial?
    var multiDisplayTrial: MultiDisplayTrial?
    var manualChecks: [ManualCheck]
    var recommendedStrategy: String?
    var verdict: String?
    var error: String?
}

enum ReportWriter {
    static func write(_ report: SelfTestReport, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try data.write(to: url, options: .atomic)
    }

    static func humanSummary(_ report: SelfTestReport) -> String {
        var lines: [String] = []
        lines.append("Wallpaper Spike feasibility report")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: report.generatedAt))")
        lines.append("Host: \(report.osVersion) · \(report.architecture) · app \(report.appVersion)")
        if let duration = report.durationSeconds {
            lines.append(String(format: "Duration: %.1fs", duration))
        }
        lines.append("Screens: \(report.screens.count), scale factors: \(report.distinctScaleFactors.map { String(format: "%.1fx", $0) }.joined(separator: ", "))")
        for screen in report.screens {
            lines.append("  - \(screen.summary)")
        }
        if let videoPath = report.videoPath {
            lines.append("Video: \(videoPath)")
        }
        if let videoDuration = report.videoDuration {
            lines.append(String(format: "Video duration: %.2fs", videoDuration))
        }

        lines.append("")
        lines.append("Level trials:")
        for trial in report.levelTrials {
            lines.append("- \(trial.strategy) (level \(trial.levelValue), \(trial.levelDetail))")
            lines.append("  playback: \(trial.playback.summary)")
            lines.append("  found: \(trial.order.surfaceFound), layer: \(trial.order.surfaceLayer.map(String.init) ?? "n/a"), order: \(trial.order.surfaceOrderIndex.map(String.init) ?? "n/a")")
            lines.append("  behind icons: \(trial.order.isBehindDesktopIcons.map(String.init) ?? "unknown"), above system wallpaper: \(trial.order.isAboveSystemWallpaper.map(String.init) ?? "unknown")")
            lines.append("  \(trial.order.explanation)")
            for note in trial.notes {
                lines.append("  note: \(note)")
            }
        }

        if let multiDisplay = report.multiDisplayTrial {
            lines.append("")
            lines.append("Multi-display trial:")
            for surface in multiDisplay.surfaces {
                lines.append("  - display \(surface.displayID) \(surface.screenName) scale \(String(format: "%.1fx", surface.scaleFactor))")
                lines.append("    playback: \(surface.playback.summary)")
                lines.append("    found: \(surface.order.surfaceFound), behind icons: \(surface.order.isBehindDesktopIcons.map(String.init) ?? "unknown"), above wallpaper: \(surface.order.isAboveSystemWallpaper.map(String.init) ?? "unknown")")
                lines.append("    \(surface.order.explanation)")
            }
            for note in multiDisplay.notes {
                lines.append("  note: \(note)")
            }
        }

        if let loop = report.loopTrial {
            lines.append("")
            lines.append("Loop trial (\(loop.strategy), video \(String(format: "%.2fs", loop.videoDuration))):")
            lines.append("  first: \(loop.firstSample.summary)")
            lines.append("  second: \(loop.secondSample.summary)")
            lines.append("  wrapped: \(loop.wrapped.map(String.init) ?? "unknown")")
            for note in loop.notes {
                lines.append("  note: \(note)")
            }
        }

        if let recommended = report.recommendedStrategy {
            lines.append("")
            lines.append("Recommended strategy: \(recommended)")
        }
        if let verdict = report.verdict {
            lines.append("Verdict: \(verdict)")
        }
        if let error = report.error {
            lines.append("Error: \(error)")
        }

        lines.append("")
        lines.append("Manual checks still required: \(report.manualChecks.count)")
        for check in report.manualChecks {
            lines.append("  [ ] \(check.title) — \(check.question)")
        }
        return lines.joined(separator: "\n")
    }
}
