import AppKit
import AVFoundation
import CoreMedia
import Darwin
import Foundation
import Observation
import OpenDirectory
import VideoToolbox

@MainActor
@Observable
final class LockScreenController {
    static let shared = LockScreenController()

    private let assetID = "WP000000-0000-4000-8000-000000000001"
    private let categoryID = "WP000000-0000-4000-8000-000000000002"
    private let subcategoryID = "WP000000-0000-4000-8000-000000000003"

    private(set) var isSynced = false
    private(set) var lastSyncedURL: URL?
    private(set) var lastSyncedName: String?
    private(set) var recoveryWarning: String?

    let isSupported: Bool
    private var didLogUnsupported = false

    private var homeDirectory: String { NSHomeDirectory() }
    private var aerialsBase: String { homeDirectory + "/Library/Application Support/com.apple.wallpaper/aerials" }
    private var videosDir: String { aerialsBase + "/videos" }
    private var thumbsDir: String { aerialsBase + "/thumbnails" }
    private var entriesPath: String { aerialsBase + "/manifest/entries.json" }
    private var storePath: String { homeDirectory + "/Library/Application Support/com.apple.wallpaper/Store/Index.plist" }
    private var backupDir: String {
        let identifier = Bundle.main.bundleIdentifier ?? "com.tcs.wallpaper"
        return homeDirectory + "/Library/Application Support/\(identifier)/lock-screen-backup"
    }
    private var storeBackupPath: String { backupDir + "/Index.plist" }
    private var entriesBackupPath: String { backupDir + "/entries.json" }
    private var screensaverBackupPath: String { backupDir + "/screensaver-moduleDict.plist" }
    private var screensaverAbsentPath: String { backupDir + "/screensaver-moduleDict.absent" }

    private init() {
        isSupported = !DistributionInfo.snapshot().isSandboxed
        if isSupported {
            checkInitialSyncState()
        }
    }

    private func checkInitialSyncState() {
        let destVideoURL = URL(fileURLWithPath: videosDir + "/\(assetID).mov")
        let fm = FileManager.default
        if fm.fileExists(atPath: destVideoURL.path) && fm.fileExists(atPath: entriesPath) {
            isSynced = true
        }
    }

    func sync(videoURL: URL, displayName: String) async {
        guard requireSupport() else { return }
        recoveryWarning = nil
        let fm = FileManager.default

        // 1. Ensure directories exist
        try? fm.createDirectory(atPath: videosDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: thumbsDir, withIntermediateDirectories: true)

        let destVideoURL = URL(fileURLWithPath: videosDir + "/\(assetID).mov")
        let destThumbURL = URL(fileURLWithPath: thumbsDir + "/\(assetID).png")

        // 2. Prepare looped video file if needed
        let videoChanged = (lastSyncedURL != videoURL) || !fm.fileExists(atPath: destVideoURL.path)

        if videoChanged {
            do {
                try await prepareLoopedVideo(from: videoURL, to: destVideoURL)
            } catch {
                Log.lockScreen.error("Failed to prepare lock screen video: \(error.localizedDescription, privacy: .public)")
                return
            }
        }

        // 3. Generate high-resolution thumbnail
        if videoChanged || !fm.fileExists(atPath: destThumbURL.path) {
            await generateThumbnail(from: videoURL, to: destThumbURL)
        }

        // 4. Update /Library/Caches/Desktop Pictures/<currentUserUUID>/lockscreen.png if accessible
        updateStaticLockScreenCache(from: destThumbURL)

        // 5. Update entries.json
        guard updateEntriesJSON(displayName: displayName, videoURL: destVideoURL, thumbURL: destThumbURL) else {
            Log.lockScreen.error("Failed to update entries.json")
            return
        }

        // 6. Update Index.plist (Displays, Spaces, SystemDefault, AllSpacesAndDisplays)
        guard updateWallpaperStore() else {
            Log.lockScreen.error("Failed to update wallpaper store")
            return
        }

        // 7. Configure screensaver module to WallpaperAerialsExtension
        configureScreensaver()

        // 8. Restart WallpaperAgent
        restartWallpaperAgent()

        isSynced = true
        lastSyncedURL = videoURL
        lastSyncedName = displayName
        Log.lockScreen.notice("Successfully synchronized video with lock screen (\(displayName, privacy: .public))")
    }

    func ensureHealthy(restartAgentIfNeeded: Bool = false) {
        guard requireSupport(), isSynced else { return }

        let storeURL = URL(fileURLWithPath: storePath)
        guard let data = try? Data(contentsOf: storeURL),
              let store = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any] else {
            _ = updateWallpaperStore()
            if restartAgentIfNeeded { restartWallpaperAgent() }
            return
        }

        var needsUpdate = !hasAerialIdle(store["SystemDefault"])
            || !hasAerialIdle(store["AllSpacesAndDisplays"])

        if !needsUpdate {
            let displays = store["Displays"] as? [String: Any] ?? [:]
            for uuid in getActiveDisplayUUIDs() {
                if let display = displays[uuid], !hasAerialIdle(display) {
                    needsUpdate = true
                    break
                }
            }
        }

        if needsUpdate {
            Log.lockScreen.info("LockScreenController: store was altered, re-asserting aerial configuration")
            _ = updateWallpaperStore()
            if restartAgentIfNeeded {
                restartWallpaperAgent()
            }
        } else if restartAgentIfNeeded {
            restartWallpaperAgent()
        }
    }

    func remove() {
        guard requireSupport() else { return }
        let wasSynced = isSynced
        let fm = FileManager.default
        let destVideoURL = URL(fileURLWithPath: videosDir + "/\(assetID).mov")
        let destThumbURL = URL(fileURLWithPath: thumbsDir + "/\(assetID).png")

        try? fm.removeItem(at: destVideoURL)
        try? fm.removeItem(at: destThumbURL)

        removeStaticLockScreenCache()
        let entriesRestored = removeFromEntriesJSON(expectBackup: wasSynced)
        let storeRestored = removeFromWallpaperStore(expectBackup: wasSynced)
        let screensaverRestored = restoreScreensaver(expectBackup: wasSynced)
        restartWallpaperAgent()

        isSynced = false
        lastSyncedURL = nil
        lastSyncedName = nil

        if entriesRestored && storeRestored && screensaverRestored {
            recoveryWarning = nil
        } else {
            reportRecoveryWarning()
        }
        Log.lockScreen.notice("Removed lock screen synchronization")
    }

    // MARK: - Private Helpers

    private func requireSupport() -> Bool {
        if isSupported {
            return true
        }
        if !didLogUnsupported {
            didLogUnsupported = true
            Log.lockScreen.notice(
                "Lock Screen synchronization is unavailable because the app is sandboxed"
            )
        }
        return false
    }

    private func reportRecoveryWarning() {
        recoveryWarning = """
        Your previous Desktop and Lock Screen settings couldn't be fully restored. \
        Open System Settings › Wallpaper and Screen Saver to reconfigure them.
        """
        Log.lockScreen.fault(
            "Lock screen state recovery is incomplete; previous Desktop and Lock Screen settings may require manual reconfiguration"
        )
    }

    private func getActiveDisplayUUIDs() -> [String] {
        var uuids: [String] = []
        for screen in NSScreen.screens {
            guard let screenNum = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                continue
            }
            if let cfUUID = CGDisplayCreateUUIDFromDisplayID(screenNum)?.takeRetainedValue() {
                let uuidString = CFUUIDCreateString(nil, cfUUID) as String
                uuids.append(uuidString)
            }
        }
        return uuids
    }

    private func prepareLoopedVideo(from srcURL: URL, to destURL: URL) async throws {
        let asset = AVURLAsset(url: srcURL)
        let dur = try await asset.load(.duration)
        let srcSecs = CMTimeGetSeconds(dur)

        let minimumSourceSecs: Double = 1.0
        guard srcSecs.isFinite, srcSecs >= minimumSourceSecs else {
            throw NSError(
                domain: "LockScreenController",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: "Video must be at least \(minimumSourceSecs) second(s) long"]
            )
        }

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(
                domain: "LockScreenController",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No video track found in source file"]
            )
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        var nomFps = try await videoTrack.load(.nominalFrameRate)
        if nomFps < 1 || !nomFps.isFinite {
            nomFps = 30
        }

        // Hardware encoders in VideoToolbox require even pixel dimensions
        let rawW = Int(naturalSize.width)
        let rawH = Int(naturalSize.height)
        let width = max((rawW / 2) * 2, 320)
        let height = max((rawH / 2) * 2, 240)

        // Target: ~300s (5 minutes) of continuous looping so it never hits EOF on lock screen.
        let targetSecs: Double = 300.0
        let maxLoops = 60
        let calculatedLoops = srcSecs < targetSecs ? Int(ceil(targetSecs / srcSecs)) : 1
        let loopCount = min(max(calculatedLoops, 1), maxLoops)

        // Apple Aerials bitrate standard: ~8-12 Mbps for 1080p, up to 16 Mbps for 4K
        let pixelCount = width * height
        let bitrate = min(max(pixelCount * 4, 6_000_000), 16_000_000)

        let fm = FileManager.default
        let tmpURL = URL(fileURLWithPath: "\(destURL.path).\(UUID().uuidString).tmp.mov")
        if fm.fileExists(atPath: tmpURL.path) {
            try? fm.removeItem(at: tmpURL)
        }

        do {
            try await encodeTemporalHEVC(
                asset: asset,
                track: videoTrack,
                width: width,
                height: height,
                fps: nomFps,
                duration: dur,
                loopCount: loopCount,
                bitrate: bitrate,
                destinationURL: tmpURL
            )

            if fm.fileExists(atPath: destURL.path) {
                try? fm.removeItem(at: destURL)
            }
            try fm.moveItem(at: tmpURL, to: destURL)
            Log.lockScreen.info(
                "Exported temporal HEVC lock screen video: \(loopCount, privacy: .public) loops, \(Int(Double(loopCount) * srcSecs), privacy: .public)s to \(destURL.path, privacy: .private)"
            )
        } catch {
            try? fm.removeItem(at: tmpURL)
            Log.lockScreen.error("Temporal HEVC video export failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private nonisolated func encodeTemporalHEVC(
        asset: AVURLAsset,
        track: AVAssetTrack,
        width: Int,
        height: Int,
        fps: Float,
        duration: CMTime,
        loopCount: Int,
        bitrate: Int,
        destinationURL: URL
    ) async throws {
        let streamWriter = TemporalHEVCEncoder(destinationURL: destinationURL)

        let callback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer = sampleBuffer, let refcon = refcon else { return }
            let encoder = Unmanaged<TemporalHEVCEncoder>.fromOpaque(refcon).takeUnretainedValue()
            encoder.handleEncodedSampleBuffer(sampleBuffer)
        }

        var sessionOut: VTCompressionSession?
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ]

        let createStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: Unmanaged.passUnretained(streamWriter).toOpaque(),
            compressionSessionOut: &sessionOut
        )

        guard createStatus == noErr, let session = sessionOut else {
            throw NSError(
                domain: "LockScreenController",
                code: Int(createStatus),
                userInfo: [NSLocalizedDescriptionKey: "Failed to create VTCompressionSession (error \(createStatus))"]
            )
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main10_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: Int(fps * 2)))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)

        // Enable temporal scalability so WallpaperAerialsExtension receives tscl and tsas sample groups.
        // This is strictly required for the unlock slow-motion ramp-down transition on macOS 14+.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowTemporalCompression, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_BaseLayerFrameRate, value: NSNumber(value: Double(fps) / 2.0))

        VTCompressionSessionPrepareToEncodeFrames(session)

        let timescale = Int32(max(fps.rounded(), 1))

        for loop in 0..<loopCount {
            let offset = CMTimeMultiply(duration, multiplier: Int32(loop))

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            ])
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
            }
            reader.startReading()

            while let sampleBuffer = output.copyNextSampleBuffer() {
                guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
                let sourcePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let pts = CMTimeAdd(sourcePTS, offset)

                var frameDuration = CMSampleBufferGetDuration(sampleBuffer)
                if !frameDuration.isValid || frameDuration.value == 0 {
                    frameDuration = CMTime(value: 1, timescale: timescale)
                }

                VTCompressionSessionEncodeFrame(
                    session,
                    imageBuffer: imageBuffer,
                    presentationTimeStamp: pts,
                    duration: frameDuration,
                    frameProperties: nil,
                    sourceFrameRefcon: nil,
                    infoFlagsOut: nil
                )
            }

            if reader.status == .failed {
                throw reader.error ?? NSError(
                    domain: "LockScreenController",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Asset reader failed during decoding"]
                )
            }
        }

        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)

        try await streamWriter.finish()
    }

    private func generateThumbnail(from videoURL: URL, to destURL: URL) async {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 3840, height: 2160)

        do {
            let (cgImage, _) = try await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600))
            let rep = NSBitmapImageRep(cgImage: cgImage)
            if let pngData = rep.representation(using: .png, properties: [:]) {
                try pngData.write(to: destURL)
                Log.lockScreen.info("Generated lock screen thumbnail at \(destURL.path, privacy: .private)")
            }
        } catch {
            Log.lockScreen.error("Failed to generate lock screen thumbnail: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func updateStaticLockScreenCache(from thumbURL: URL) {
        guard let userDir = currentUserCacheDirectory() else {
            Log.lockScreen.notice(
                "Skipping lock screen cache update: the current user's cache directory is unavailable or unsafe"
            )
            return
        }

        let fm = FileManager.default
        let destination = userDir.appendingPathComponent("lockscreen.png", isDirectory: false)
        let temporary = userDir.appendingPathComponent(
            ".lockscreen.\(UUID().uuidString).tmp",
            isDirectory: false
        )

        do {
            let data = try Data(contentsOf: thumbURL)
            try data.write(to: temporary, options: .withoutOverwriting)
            // rename(2) atomically replaces the destination and never follows a
            // symlink located at the destination path.
            guard rename(temporary.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? fm.removeItem(at: temporary)
            Log.lockScreen.error(
                "Failed to update lock screen cache: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private func removeStaticLockScreenCache() {
        guard let userDir = currentUserCacheDirectory() else { return }
        let destination = userDir.appendingPathComponent("lockscreen.png", isDirectory: false)

        // unlink(2) removes the entry itself and never follows a symlink.
        if unlink(destination.path) != 0, errno != ENOENT {
            Log.lockScreen.error(
                "Failed to remove lock screen cache: \(String(cString: strerror(errno)), privacy: .private)"
            )
        }
    }

    private func currentUserCacheDirectory() -> URL? {
        guard let generatedUID = currentUserGeneratedUID() else { return nil }

        let directory = URL(
            fileURLWithPath: "/Library/Caches/Desktop Pictures",
            isDirectory: true
        ).appendingPathComponent(generatedUID, isDirectory: true)

        var info = stat()
        guard lstat(directory.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid() else {
            return nil
        }
        return directory
    }

    private func currentUserGeneratedUID() -> String? {
        do {
            guard let session = ODSession.default() else { return nil }
            let node = try ODNode(session: session, type: ODNodeType(kODNodeTypeLocalNodes))
            let query = try ODQuery(
                node: node,
                forRecordTypes: kODRecordTypeUsers,
                attribute: kODAttributeTypeRecordName,
                matchType: ODMatchType(kODMatchEqualTo),
                queryValues: NSUserName(),
                returnAttributes: ["GeneratedUID"],
                maximumResults: 1
            )
            let records = try query.resultsAllowingPartial(false) as? [ODRecord] ?? []
            guard let record = records.first else { return nil }
            let values = (try? record.values(forAttribute: "GeneratedUID")) as? [String]
            return values?.first
        } catch {
            Log.lockScreen.error(
                "Failed to resolve the current user's generated UID: \(error.localizedDescription, privacy: .private)"
            )
            return nil
        }
    }

    private func updateEntriesJSON(displayName: String, videoURL: URL, thumbURL: URL) -> Bool {
        guard backupIfNeeded(at: entriesPath, to: entriesBackupPath) else {
            Log.lockScreen.fault("Refusing to update entries.json because the backup failed")
            return false
        }

        let fm = FileManager.default
        let manifestDir = (entriesPath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: manifestDir, withIntermediateDirectories: true)

        var entries: [String: Any]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: entriesPath)),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            entries = parsed
        } else {
            entries = ["version": 1, "categories": [] as [Any], "assets": [] as [Any]]
        }

        var categories = entries["categories"] as? [[String: Any]] ?? []
        var assets = entries["assets"] as? [[String: Any]] ?? []

        let thumbFileURL = thumbURL.absoluteString
        let videoFileURL = videoURL.absoluteString

        let categoryEntry: [String: Any] = [
            "id": categoryID,
            "localizedNameKey": "WallpaperApp",
            "localizedDescriptionKey": "WallpaperApp Custom Wallpaper",
            "preferredOrder": 999,
            "representativeAssetID": assetID,
            "previewImage": thumbFileURL,
            "subcategories": [
                [
                    "id": subcategoryID,
                    "localizedNameKey": "WallpaperApp",
                    "localizedDescriptionKey": "WallpaperApp Custom Wallpaper",
                    "preferredOrder": 0,
                    "previewImage": thumbFileURL,
                    "representativeAssetID": assetID
                ]
            ]
        ]

        categories.removeAll { ($0["id"] as? String) == categoryID }
        categories.append(categoryEntry)

        let assetEntry: [String: Any] = [
            "id": assetID,
            "localizedNameKey": displayName,
            "accessibilityLabel": displayName,
            "shotID": "WP_CUSTOM",
            "showInTopLevel": true,
            "includeInShuffle": false,
            "preferredOrder": 0,
            "categories": [categoryID],
            "subcategories": [subcategoryID],
            "url-4K-SDR-240FPS": videoFileURL,
            "previewImage": thumbFileURL,
            "videoGravity": "resize",
            "pointsOfInterest": ["0": "WP_0"]
        ]

        assets.removeAll { ($0["id"] as? String) == assetID }
        assets.append(assetEntry)

        entries["categories"] = categories
        entries["assets"] = assets

        let tmpURL = URL(fileURLWithPath: "\(entriesPath).\(UUID().uuidString).tmp")
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
            let destURL = URL(fileURLWithPath: entriesPath)
            try jsonData.write(to: tmpURL)
            _ = try FileManager.default.replaceItemAt(destURL, withItemAt: tmpURL)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            Log.lockScreen.error("Failed to write entries.json: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func removeFromEntriesJSON(expectBackup: Bool) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: entriesBackupPath) {
            if restoreBackup(from: entriesBackupPath, to: entriesPath) {
                return true
            }
            Log.lockScreen.fault("Failed to restore entries.json from backup")
            return false
        }

        if expectBackup {
            Log.lockScreen.fault(
                "entries.json backup is missing; the previous lock screen configuration can't be restored"
            )
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: entriesPath)),
              var entries = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return !expectBackup
        }

        if var categories = entries["categories"] as? [[String: Any]] {
            categories.removeAll { ($0["id"] as? String) == categoryID }
            entries["categories"] = categories
        }
        if var assets = entries["assets"] as? [[String: Any]] {
            assets.removeAll { ($0["id"] as? String) == assetID }
            entries["assets"] = assets
        }

        do {
            let jsonData = try JSONSerialization.data(
                withJSONObject: entries,
                options: [.prettyPrinted, .sortedKeys]
            )
            try jsonData.write(to: URL(fileURLWithPath: entriesPath))
            return !expectBackup
        } catch {
            Log.lockScreen.error(
                "Failed to write entries.json: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    private func buildAerialIdle() -> [String: Any]? {
        let configDict: [String: String] = ["assetID": assetID]
        guard let configData = try? PropertyListSerialization.data(
            fromPropertyList: configDict, format: .binary, options: 0
        ) else { return nil }

        let choice: [String: Any] = [
            "Provider": "com.apple.wallpaper.choice.aerials",
            "Files": [] as [Any],
            "Configuration": configData
        ]
        let content: [String: Any] = ["Choices": [choice]]
        return [
            "Content": content,
            "LastSet": Date(),
            "LastUse": Date()
        ]
    }

    private func buildDefaultIdle() -> [String: Any] {
        let choice: [String: Any] = [
            "Provider": "default",
            "Files": [] as [Any],
            "Configuration": Data()
        ]
        let content: [String: Any] = ["Choices": [choice]]
        return [
            "Content": content,
            "LastSet": Date(),
            "LastUse": Date()
        ]
    }

    private func hasAerialIdle(_ value: Any?) -> Bool {
        guard let entry = value as? [String: Any],
              let idle = entry["Idle"] as? [String: Any],
              let content = idle["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]],
              let choice = choices.first,
              (choice["Provider"] as? String) == "com.apple.wallpaper.choice.aerials",
              let configuration = choice["Configuration"] as? Data,
              let values = try? PropertyListSerialization.propertyList(
                  from: configuration, options: [], format: nil
              ) as? [String: Any],
              (values["assetID"] as? String) == assetID else {
            return false
        }
        return true
    }

    private func applyingLockScreenIdle(_ value: Any?, idle: [String: Any]) -> [String: Any] {
        guard var entry = value as? [String: Any] else {
            return ["Type": "idle", "Idle": idle]
        }

        if entry["Desktop"] != nil {
            entry["Idle"] = idle
            entry["Type"] = "individual"
            entry.removeValue(forKey: "Linked")
            return entry
        }

        if let linked = entry["Linked"] {
            entry["Desktop"] = linked
            entry["Idle"] = idle
            entry["Type"] = "individual"
            entry.removeValue(forKey: "Linked")
            return entry
        }

        entry["Idle"] = idle
        if entry["Type"] == nil {
            entry["Type"] = "idle"
        }
        return entry
    }

    @discardableResult
    private func updateWallpaperStore() -> Bool {
        guard let idle = buildAerialIdle() else { return false }
        guard backupIfNeeded(at: storePath, to: storeBackupPath) else {
            Log.lockScreen.fault("Refusing to update Index.plist because the backup failed")
            return false
        }

        let storeURL = URL(fileURLWithPath: storePath)
        let storeDir = (storePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: storeDir, withIntermediateDirectories: true)

        var store: [String: Any]
        if let data = try? Data(contentsOf: storeURL),
           let parsed = try? PropertyListSerialization.propertyList(
               from: data, options: .mutableContainersAndLeaves, format: nil
           ) as? [String: Any] {
            store = parsed
        } else {
            store = [:]
        }

        store["SystemDefault"] = applyingLockScreenIdle(store["SystemDefault"], idle: idle)
        store["AllSpacesAndDisplays"] = applyingLockScreenIdle(
            store["AllSpacesAndDisplays"],
            idle: idle
        )

        let activeUUIDs = getActiveDisplayUUIDs()
        if var displays = store["Displays"] as? [String: Any] {
            for uuid in activeUUIDs {
                guard let display = displays[uuid] else { continue }
                displays[uuid] = applyingLockScreenIdle(display, idle: idle)
            }
            store["Displays"] = displays
        }

        if var spaces = store["Spaces"] as? [String: Any] {
            for (spaceID, spaceVal) in spaces {
                guard var spaceDict = spaceVal as? [String: Any] else { continue }
                if let defaultEntry = spaceDict["Default"] {
                    spaceDict["Default"] = applyingLockScreenIdle(defaultEntry, idle: idle)
                }
                if var spaceDisplays = spaceDict["Displays"] as? [String: Any] {
                    for displayKey in Array(spaceDisplays.keys) {
                        spaceDisplays[displayKey] = applyingLockScreenIdle(
                            spaceDisplays[displayKey],
                            idle: idle
                        )
                    }
                    spaceDict["Displays"] = spaceDisplays
                }
                spaces[spaceID] = spaceDict
            }
            store["Spaces"] = spaces
        }

        let tmpURL = URL(fileURLWithPath: "\(storePath).\(UUID().uuidString).tmp")
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
            try data.write(to: tmpURL)
            _ = try FileManager.default.replaceItemAt(storeURL, withItemAt: tmpURL)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            Log.lockScreen.error("Failed to write Index.plist: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    private func removeFromWallpaperStore(expectBackup: Bool) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: storeBackupPath) {
            if restoreBackup(from: storeBackupPath, to: storePath) {
                return true
            }
            Log.lockScreen.fault("Failed to restore Index.plist from backup")
            return false
        }

        if expectBackup {
            Log.lockScreen.fault(
                "Index.plist backup is missing; the previous lock screen configuration can't be restored"
            )
        }

        let storeURL = URL(fileURLWithPath: storePath)
        guard let data = try? Data(contentsOf: storeURL),
              var store = try? PropertyListSerialization.propertyList(
                  from: data, options: .mutableContainersAndLeaves, format: nil
              ) as? [String: Any] else {
            return !expectBackup
        }

        let defaultIdle = buildDefaultIdle()

        if hasAerialIdle(store["SystemDefault"]) {
            store["SystemDefault"] = applyingLockScreenIdle(store["SystemDefault"], idle: defaultIdle)
        }
        if hasAerialIdle(store["AllSpacesAndDisplays"]) {
            store["AllSpacesAndDisplays"] = applyingLockScreenIdle(
                store["AllSpacesAndDisplays"],
                idle: defaultIdle
            )
        }

        if var displays = store["Displays"] as? [String: Any] {
            for uuid in Array(displays.keys) where hasAerialIdle(displays[uuid]) {
                displays[uuid] = applyingLockScreenIdle(displays[uuid], idle: defaultIdle)
            }
            store["Displays"] = displays
        }

        if var spaces = store["Spaces"] as? [String: Any] {
            for (spaceID, spaceVal) in spaces {
                guard var spaceDict = spaceVal as? [String: Any] else { continue }
                if hasAerialIdle(spaceDict["Default"]) {
                    spaceDict["Default"] = applyingLockScreenIdle(spaceDict["Default"], idle: defaultIdle)
                }
                if var spaceDisplays = spaceDict["Displays"] as? [String: Any] {
                    for displayKey in Array(spaceDisplays.keys) where hasAerialIdle(spaceDisplays[displayKey]) {
                        spaceDisplays[displayKey] = applyingLockScreenIdle(
                            spaceDisplays[displayKey],
                            idle: defaultIdle
                        )
                    }
                    spaceDict["Displays"] = spaceDisplays
                }
                spaces[spaceID] = spaceDict
            }
            store["Spaces"] = spaces
        }

        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: store, format: .binary, options: 0
        ) else {
            Log.lockScreen.error("Failed to serialize Index.plist while removing lock screen state")
            return false
        }

        let tmpURL = URL(fileURLWithPath: "\(storePath).\(UUID().uuidString).tmp")
        do {
            try data.write(to: tmpURL)
            _ = try FileManager.default.replaceItemAt(storeURL, withItemAt: tmpURL)
            return !expectBackup
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            Log.lockScreen.error(
                "Failed to write Index.plist: \(error.localizedDescription, privacy: .private)"
            )
            return false
        }
    }

    private func backupIfNeeded(at sourcePath: String, to backupPath: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourcePath) else { return true }
        if fm.fileExists(atPath: backupPath) { return true }

        do {
            try fm.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
            try fm.copyItem(atPath: sourcePath, toPath: backupPath)
            return true
        } catch {
            Log.lockScreen.fault(
                "Failed to back up wallpaper state: \(error.localizedDescription, privacy: .private)"
            )
            return false
        }
    }

    @discardableResult
    private func restoreBackup(from backupPath: String, to destinationPath: String) -> Bool {
        let fm = FileManager.default
        let destinationURL = URL(fileURLWithPath: destinationPath)
        let temporaryURL = URL(fileURLWithPath: "\(destinationPath).\(UUID().uuidString).restore.tmp")

        do {
            try fm.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fm.copyItem(at: URL(fileURLWithPath: backupPath), to: temporaryURL)
            if fm.fileExists(atPath: destinationPath) {
                _ = try fm.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            } else {
                try fm.moveItem(at: temporaryURL, to: destinationURL)
            }
            try? fm.removeItem(atPath: backupPath)
            return true
        } catch {
            try? fm.removeItem(at: temporaryURL)
            Log.lockScreen.fault(
                "Failed to restore wallpaper state: \(error.localizedDescription, privacy: .private)"
            )
            return false
        }
    }

    private func configureScreensaver() {
        guard backupScreensaverIfNeeded() else {
            Log.lockScreen.error("Refusing to modify screensaver settings because the backup failed")
            return
        }
        let aerialsPath = "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex"
        writeScreensaverModuleDict([
            "moduleName": "WallpaperAerialsExtension",
            "path": aerialsPath,
            "type": 0
        ])
    }

    private func backupScreensaverIfNeeded() -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: screensaverBackupPath) || fm.fileExists(atPath: screensaverAbsentPath) {
            return true
        }

        do {
            try fm.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
            if let moduleDict = readScreensaverModuleDict() {
                let data = try PropertyListSerialization.data(
                    fromPropertyList: moduleDict, format: .binary, options: 0
                )
                try data.write(to: URL(fileURLWithPath: screensaverBackupPath), options: .withoutOverwriting)
            } else {
                try Data().write(to: URL(fileURLWithPath: screensaverAbsentPath), options: .withoutOverwriting)
            }
            return true
        } catch {
            Log.lockScreen.error(
                "Failed to back up screensaver settings: \(error.localizedDescription, privacy: .private)"
            )
            return false
        }
    }

    private func restoreScreensaver(expectBackup: Bool) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: screensaverBackupPath) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: screensaverBackupPath)),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data, options: [], format: nil
                  ),
                  let moduleDict = plist as? [String: Any] else {
                Log.lockScreen.fault("Failed to read screensaver settings backup")
                return false
            }
            writeScreensaverModuleDict(moduleDict)
            try? fm.removeItem(atPath: screensaverBackupPath)
            return true
        }

        if fm.fileExists(atPath: screensaverAbsentPath) {
            writeScreensaverModuleDict(nil)
            try? fm.removeItem(atPath: screensaverAbsentPath)
            return true
        }

        if expectBackup {
            Log.lockScreen.fault(
                "Screensaver settings backup is missing; the previous screensaver configuration can't be restored"
            )
            return false
        }
        return true
    }

    private func readScreensaverModuleDict() -> [String: Any]? {
        CFPreferencesCopyValue(
            "moduleDict" as CFString,
            "com.apple.screensaver" as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        ) as? [String: Any]
    }

    private func writeScreensaverModuleDict(_ moduleDict: [String: Any]?) {
        let domain = "com.apple.screensaver" as CFString
        CFPreferencesSetValue(
            "moduleDict" as CFString,
            moduleDict.map { $0 as CFDictionary },
            domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }

    private func restartWallpaperAgent() {
        let bundleIdentifier = "com.apple.wallpaper.agent"
        let agents = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)

        for agent in agents where !agent.isTerminated {
            if kill(agent.processIdentifier, SIGTERM) != 0 {
                let message = String(cString: strerror(errno))
                Log.lockScreen.error("Failed to restart WallpaperAgent: \(message, privacy: .private)")
            }
        }
    }
}

// MARK: - TemporalHEVCEncoder

private final class TemporalHEVCEncoder: @unchecked Sendable {
    private let outURL: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var isStarted = false
    private let lock = NSLock()
    private var writeError: Error?
    private var hasFailed = false

    init(destinationURL: URL) {
        self.outURL = destinationURL
    }

    func handleEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }

        if hasFailed || !CMSampleBufferDataIsReady(sampleBuffer) { return }

        if !isStarted {
            guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            do {
                let assetWriter = try AVAssetWriter(outputURL: outURL, fileType: .mov)
                let writerInput = AVAssetWriterInput(
                    mediaType: .video,
                    outputSettings: nil,
                    sourceFormatHint: formatDescription
                )
                writerInput.expectsMediaDataInRealTime = false
                if assetWriter.canAdd(writerInput) {
                    assetWriter.add(writerInput)
                }
                assetWriter.startWriting()
                assetWriter.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                self.writer = assetWriter
                self.input = writerInput
                self.isStarted = true
            } catch {
                self.hasFailed = true
                self.writeError = error
                return
            }
        }

        guard let input = input, let writer = writer else { return }
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed {
                self.hasFailed = true
                self.writeError = writer.error
                return
            }
            usleep(500)
        }

        if !input.append(sampleBuffer) {
            self.hasFailed = true
            self.writeError = writer.error
        }
    }

    func finish() async throws {
        let (activeWriter, activeInput, activeError): (AVAssetWriter?, AVAssetWriterInput?, Error?) = lock.withLock {
            let res = (self.writer, self.input, self.writeError)
            self.input?.markAsFinished()
            return res
        }

        guard let writer = activeWriter, activeInput != nil else {
            if let err = activeError {
                throw err
            } else {
                throw NSError(
                    domain: "TemporalHEVCEncoder",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No video frames were written to destination"]
                )
            }
        }

        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? NSError(
                domain: "TemporalHEVCEncoder",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Asset writer failed to finish writing"]
            )
        }
    }
}

