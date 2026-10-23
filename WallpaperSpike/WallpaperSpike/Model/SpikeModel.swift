import AppKit
import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class SpikeModel: ObservableObject {
    @Published var configuration = SpikeConfiguration() {
        didSet {
            guard configuration != oldValue else { return }
            applyConfigurationIfNeeded()
        }
    }

    @Published private(set) var selectedVideoURL: URL?
    @Published private(set) var videoInfo = "No video selected"
    @Published private(set) var isSurfaceRunning = false
    @Published private(set) var isPaused = false
    @Published private(set) var isGeneratingTestVideo = false
    @Published private(set) var statusMessage = "Choose a video or generate a test pattern."
    @Published private(set) var errorMessage: String?
    @Published private(set) var screens: [DisplayInfo] = []
    @Published private(set) var diagnosticsText = ""
    @Published private(set) var surfaceCount = 0
    @Published private(set) var playingCount = 0
    @Published private(set) var lastWindowAnalysis: WindowOrderAnalysis?

    private let surfaceController = WallpaperSurfaceController()
    private var cancellables = Set<AnyCancellable>()

    init() {
        surfaceController.onEvent = { [weak self] message in
            Task { @MainActor in
                self?.appendDiagnostics(message)
                self?.refreshRuntimeState()
            }
        }

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshScreens()
            }
            .store(in: &cancellables)

        Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshRuntimeState()
            }
            .store(in: &cancellables)

        refreshScreens()
        appendDiagnostics("Wallpaper Spike diagnostics ready · \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    var configurationSummary: String {
        "target=\(configuration.target.title) · level=\(configuration.level.detail) · scaling=\(configuration.scalingMode.title) · click-through=\(configuration.clickThrough ? "on" : "off") · muted=\(configuration.muted ? "on" : "off")"
    }

    func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Use Video"
        panel.message = "Choose a video to use for the wallpaper surface spike."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadVideo(url)
    }

    func generateTestVideo() {
        guard !isGeneratingTestVideo else { return }
        isGeneratingTestVideo = true
        errorMessage = nil
        statusMessage = "Generating a 4-second test pattern…"

        Task {
            do {
                let url = try await TestVideoFactory.makeTestVideo(duration: 4)
                isGeneratingTestVideo = false
                appendDiagnostics("Generated test video at \(url.path)")
                loadVideo(url)
            } catch {
                isGeneratingTestVideo = false
                reportError(error)
            }
        }
    }

    func loadVideo(_ url: URL) {
        Task {
            await validateAndSelect(url)
        }
    }

    func startSurface() {
        guard let selectedVideoURL else {
            reportError(SpikeError.noVideoSelected)
            return
        }

        do {
            try surfaceController.start(videoURL: selectedVideoURL, configuration: configuration)
            errorMessage = nil
            isPaused = false
            refreshRuntimeState()
            statusMessage = "Surface running on \(surfaceController.surfaceCount) display(s) at \(configuration.level.detail)"
        } catch {
            reportError(error)
        }
    }

    func stopSurface() {
        surfaceController.stop()
        isSurfaceRunning = false
        isPaused = false
        surfaceCount = 0
        playingCount = 0
        statusMessage = selectedVideoURL == nil ? "No video selected" : "Surface stopped"
        appendDiagnostics("Stopped all surfaces")
    }

    func togglePlayback() {
        guard isSurfaceRunning else { return }
        if isPaused {
            surfaceController.resume()
            isPaused = false
            statusMessage = "Playback resumed"
        } else {
            surfaceController.pause()
            isPaused = true
            statusMessage = "Playback paused"
        }
        refreshRuntimeState()
    }

    func probeWindows() {
        guard isSurfaceRunning else {
            appendDiagnostics("Start a surface before probing window ordering.")
            statusMessage = "Start a surface first"
            return
        }

        let snapshot = WindowProbe.snapshot()
        var lines = ["Window probe at \(Self.timestamp()) · \(snapshot.count) on-screen windows"]
        for windowNumber in surfaceController.surfaceWindowNumbers {
            let analysis = WindowProbe.analyze(surfaceWindowNumber: windowNumber, snapshot: snapshot)
            lastWindowAnalysis = analysis
            lines.append(WindowProbe.reportText(for: analysis))
            lines.append("")
        }

        appendDiagnostics(lines.joined(separator: "\n"))
        statusMessage = "Window probe complete"
    }

    func copyDiagnostics() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(diagnosticsReport(), forType: .string)
        statusMessage = "Diagnostics copied to clipboard"
    }

    func revealSelectedVideo() {
        guard let selectedVideoURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([selectedVideoURL])
    }

    func diagnosticsReport() -> String {
        var lines: [String] = []
        lines.append("Wallpaper Spike diagnostics")
        lines.append("Generated: \(Self.timestamp())")
        lines.append("Host: \(ProcessInfo.processInfo.operatingSystemVersionString) · app \(Self.appVersion())")
        lines.append("Video: \(selectedVideoURL?.path ?? "none")")
        lines.append("Video info: \(videoInfo.replacingOccurrences(of: "\n", with: " | "))")
        lines.append("Configuration: \(configurationSummary)")
        lines.append("Surface: running=\(isSurfaceRunning) windows=\(surfaceCount) playing=\(playingCount) paused=\(isPaused)")
        lines.append("")
        lines.append("Displays:")
        for screen in screens {
            lines.append("  - \(screen.summary)")
        }
        if let lastWindowAnalysis {
            lines.append("")
            lines.append(WindowProbe.reportText(for: lastWindowAnalysis))
        }
        lines.append("")
        lines.append("Event log (newest first):")
        lines.append(diagnosticsText)
        return lines.joined(separator: "\n")
    }

    private func validateAndSelect(_ url: URL) async {
        statusMessage = "Validating \(url.lastPathComponent)…"
        errorMessage = nil

        let asset = AVURLAsset(url: url)
        do {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw SpikeError.unreadableVideo(url)
            }

            let playable = try await asset.load(.isPlayable)
            let duration = try await asset.load(.duration)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)

            guard playable else {
                throw SpikeError.playbackFailed("AVAsset reports this file is not playable")
            }
            guard duration.seconds.isFinite, duration.seconds > 0 else {
                throw SpikeError.playbackFailed("The video duration is invalid")
            }
            guard let track = videoTracks.first else {
                throw SpikeError.noVideoTrack(url)
            }

            let size = try await track.load(.naturalSize)
            let fps = try await track.load(.nominalFrameRate)
            let audioDescription = audioTracks.isEmpty ? "no audio" : "\(audioTracks.count) audio track(s)"

            selectedVideoURL = url
            videoInfo = "\(url.lastPathComponent)\n\(Int(size.width))×\(Int(size.height)) · \(String(format: "%.2f", duration.seconds))s · \(Int(fps.rounded())) fps · \(audioDescription)"
            statusMessage = "Ready to apply"
            appendDiagnostics("Validated \(url.lastPathComponent) · \(Int(size.width))×\(Int(size.height)) · \(String(format: "%.2f", duration.seconds))s · \(audioDescription)")

            if isSurfaceRunning {
                try surfaceController.start(videoURL: url, configuration: configuration)
                refreshRuntimeState()
                statusMessage = "Surface running with the newly selected video"
                appendDiagnostics("Restarted surfaces with the newly selected video")
            }
        } catch {
            reportError(error)
        }
    }

    private func applyConfigurationIfNeeded() {
        guard isSurfaceRunning else { return }
        do {
            try surfaceController.update(configuration: configuration)
            errorMessage = nil
            statusMessage = "Configuration applied: \(configurationSummary)"
            refreshRuntimeState()
        } catch {
            reportError(error)
        }
    }

    private func refreshScreens() {
        screens = DisplayProbe.currentScreens()
    }

    private func refreshRuntimeState() {
        surfaceCount = surfaceController.surfaceCount
        playingCount = surfaceController.playingCount
        let running = surfaceController.isRunning
        if isSurfaceRunning != running {
            isSurfaceRunning = running
        }
        if !running {
            isPaused = false
        }
    }

    private func reportError(_ error: Error) {
        let message = error.localizedDescription
        errorMessage = message
        statusMessage = message
        appendDiagnostics("ERROR: \(message)")
        Log.app.error("\(message, privacy: .public)")
    }

    private func appendDiagnostics(_ message: String) {
        let entry = "[\(Self.timestamp())] \(message)"
        if diagnosticsText.isEmpty {
            diagnosticsText = entry
        } else {
            diagnosticsText = entry + "\n" + diagnosticsText
        }

        let lines = diagnosticsText.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 400 {
            diagnosticsText = lines.prefix(400).joined(separator: "\n")
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }

    private static func appVersion() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(version) (\(build))"
    }
}
