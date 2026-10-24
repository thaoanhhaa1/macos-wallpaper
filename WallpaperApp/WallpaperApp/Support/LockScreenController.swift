import AppKit
import AVFoundation
import Foundation

@MainActor
final class LockScreenController {
    static let shared = LockScreenController()

    private let assetID = "WP000000-0000-4000-8000-000000000001"
    private let categoryID = "WP000000-0000-4000-8000-000000000002"
    private let subcategoryID = "WP000000-0000-4000-8000-000000000003"

    private(set) var isSynced = false
    private(set) var lastSyncedURL: URL?
    private(set) var lastSyncedName: String?

    private var homeDirectory: String { NSHomeDirectory() }
    private var aerialsBase: String { homeDirectory + "/Library/Application Support/com.apple.wallpaper/aerials" }
    private var videosDir: String { aerialsBase + "/videos" }
    private var thumbsDir: String { aerialsBase + "/thumbnails" }
    private var entriesPath: String { aerialsBase + "/manifest/entries.json" }
    private var storePath: String { homeDirectory + "/Library/Application Support/com.apple.wallpaper/Store/Index.plist" }

    private init() {
        checkInitialSyncState()
    }

    private func checkInitialSyncState() {
        let destVideoURL = URL(fileURLWithPath: videosDir + "/\(assetID).mov")
        let fm = FileManager.default
        if fm.fileExists(atPath: destVideoURL.path) && fm.fileExists(atPath: entriesPath) {
            isSynced = true
        }
    }

    func sync(videoURL: URL, displayName: String) async {
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

        // 4. Update /Library/Caches/Desktop Pictures/<userUUID>/lockscreen.png if accessible
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
        guard isSynced else { return }

        let storeURL = URL(fileURLWithPath: storePath)
        guard let data = try? Data(contentsOf: storeURL),
              let store = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any] else {
            _ = updateWallpaperStore()
            if restartAgentIfNeeded { restartWallpaperAgent() }
            return
        }

        var needsUpdate = false

        if let all = store["AllSpacesAndDisplays"] as? [String: Any] {
            if (all["Type"] as? String) != "linked" {
                needsUpdate = true
            }
        } else {
            needsUpdate = true
        }

        let displays = store["Displays"] as? [String: Any] ?? [:]
        for uuid in getActiveDisplayUUIDs() {
            if let disp = displays[uuid] as? [String: Any] {
                if (disp["Type"] as? String) != "linked" {
                    needsUpdate = true
                    break
                }
            } else {
                needsUpdate = true
                break
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
        let fm = FileManager.default
        let destVideoURL = URL(fileURLWithPath: videosDir + "/\(assetID).mov")
        let destThumbURL = URL(fileURLWithPath: thumbsDir + "/\(assetID).png")

        try? fm.removeItem(at: destVideoURL)
        try? fm.removeItem(at: destThumbURL)

        removeStaticLockScreenCache()
        removeFromEntriesJSON()
        removeFromWallpaperStore()
        restartWallpaperAgent()

        isSynced = false
        lastSyncedURL = nil
        lastSyncedName = nil
        Log.lockScreen.notice("Removed lock screen synchronization")
    }

    // MARK: - Private Helpers

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

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(
                domain: "LockScreenController",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No video track found in source file"]
            )
        }

        let composition = AVMutableComposition()
        guard let compVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw NSError(
                domain: "LockScreenController",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create video track in composition"]
            )
        }

        // Target: 600 seconds (10 minutes) of continuous looping so it never hits EOF on lock screen.
        // We strictly only include the video track (NO audio track) so WallpaperAerialsExtension
        // can decode and snapshot cleanly without sample reading errors or timebase drift.
        let targetSecs: Double = 600.0
        let loopCount = (srcSecs > 0 && srcSecs < targetSecs) ? max(1, Int(ceil(targetSecs / srcSecs))) : 1

        var insertTime = CMTime.zero
        let timeRange = CMTimeRange(start: .zero, duration: dur)
        for _ in 0..<loopCount {
            try compVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: insertTime)
            insertTime = CMTimeAdd(insertTime, dur)
        }

        // Use AVAssetExportPresetHighestQuality to ensure seamless keyframe GOPs and valid timestamps
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(
                domain: "LockScreenController",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to initialize AVAssetExportSession"]
            )
        }

        let fm = FileManager.default
        let tmpURL = URL(fileURLWithPath: destURL.path + ".tmp.mov")
        if fm.fileExists(atPath: tmpURL.path) {
            try? fm.removeItem(at: tmpURL)
        }

        if #available(macOS 27.0, *) {
            try await exporter.export(to: tmpURL, as: .mov)
        } else {
            exporter.outputURL = tmpURL
            exporter.outputFileType = .mov
            await exporter.export()
        }

        if exporter.status == .completed {
            if fm.fileExists(atPath: destURL.path) {
                try? fm.removeItem(at: destURL)
            }
            try fm.moveItem(at: tmpURL, to: destURL)
            Log.lockScreen.info(
                "Exported looped lock screen video: \(loopCount, privacy: .public) loops, \(Int(Double(loopCount) * srcSecs), privacy: .public)s to \(destURL.path, privacy: .public)"
            )
        } else {
            let exportErr = exporter.error?.localizedDescription ?? "unknown error"
            Log.lockScreen.error("Video export failed: \(exportErr, privacy: .public)")
            throw exporter.error ?? NSError(
                domain: "LockScreenController",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: exportErr]
            )
        }
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
                Log.lockScreen.info("Generated lock screen thumbnail at \(destURL.path, privacy: .public)")
            }
        } catch {
            Log.lockScreen.error("Failed to generate lock screen thumbnail: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func updateStaticLockScreenCache(from thumbURL: URL) {
        let cacheBase = "/Library/Caches/Desktop Pictures"
        guard let subdirs = try? FileManager.default.contentsOfDirectory(atPath: cacheBase) else { return }

        for sub in subdirs {
            let userDir = (cacheBase as NSString).appendingPathComponent(sub)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: userDir, isDirectory: &isDir), isDir.boolValue {
                let lockscreenPath = (userDir as NSString).appendingPathComponent("lockscreen.png")
                let dest = URL(fileURLWithPath: lockscreenPath)
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.copyItem(at: thumbURL, to: dest)
            }
        }
    }

    private func removeStaticLockScreenCache() {
        let cacheBase = "/Library/Caches/Desktop Pictures"
        guard let subdirs = try? FileManager.default.contentsOfDirectory(atPath: cacheBase) else { return }

        for sub in subdirs {
            let lockscreenPath = (cacheBase as NSString).appendingPathComponent(sub).appending("/lockscreen.png")
            try? FileManager.default.removeItem(atPath: lockscreenPath)
        }
    }

    private func updateEntriesJSON(displayName: String, videoURL: URL, thumbURL: URL) -> Bool {
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
            "pointsOfInterest": ["0": "WP_0"]
        ]

        assets.removeAll { ($0["id"] as? String) == assetID }
        assets.append(assetEntry)

        entries["categories"] = categories
        entries["assets"] = assets

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
            let tmpURL = URL(fileURLWithPath: entriesPath + ".tmp")
            let destURL = URL(fileURLWithPath: entriesPath)
            try jsonData.write(to: tmpURL)
            _ = try FileManager.default.replaceItemAt(destURL, withItemAt: tmpURL)
            return true
        } catch {
            Log.lockScreen.error("Failed to write entries.json: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func removeFromEntriesJSON() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: entriesPath)),
              var entries = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if var categories = entries["categories"] as? [[String: Any]] {
            categories.removeAll { ($0["id"] as? String) == categoryID }
            entries["categories"] = categories
        }
        if var assets = entries["assets"] as? [[String: Any]] {
            assets.removeAll { ($0["id"] as? String) == assetID }
            entries["assets"] = assets
        }

        if let jsonData = try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys]) {
            try? jsonData.write(to: URL(fileURLWithPath: entriesPath))
        }
    }

    private func buildAerialEntry() -> [String: Any]? {
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
        let linked: [String: Any] = [
            "Content": content,
            "LastSet": Date(),
            "LastUse": Date()
        ]
        return [
            "Type": "linked",
            "Linked": linked,
            "Idle": linked,
            "Desktop": linked
        ]
    }

    @discardableResult
    private func updateWallpaperStore() -> Bool {
        guard let entry = buildAerialEntry() else { return false }

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

        store["SystemDefault"] = entry
        store["AllSpacesAndDisplays"] = entry

        let activeUUIDs = getActiveDisplayUUIDs()

        var displays = store["Displays"] as? [String: Any] ?? [:]
        for key in displays.keys {
            displays[key] = entry
        }
        for uuid in activeUUIDs {
            displays[uuid] = entry
        }
        store["Displays"] = displays

        if var spaces = store["Spaces"] as? [String: Any] {
            for (spaceID, spaceVal) in spaces {
                guard var spaceDict = spaceVal as? [String: Any] else { continue }
                spaceDict["Default"] = entry
                if var spDisplays = spaceDict["Displays"] as? [String: Any] {
                    for dispKey in spDisplays.keys {
                        spDisplays[dispKey] = entry
                    }
                    for uuid in activeUUIDs {
                        spDisplays[uuid] = entry
                    }
                    spaceDict["Displays"] = spDisplays
                }
                spaces[spaceID] = spaceDict
            }
            store["Spaces"] = spaces
        }

        do {
            let data = try PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
            let tmpURL = URL(fileURLWithPath: storePath + ".tmp")
            try data.write(to: tmpURL)
            _ = try FileManager.default.replaceItemAt(storeURL, withItemAt: tmpURL)
            return true
        } catch {
            Log.lockScreen.error("Failed to write Index.plist: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func removeFromWallpaperStore() {
        let storeURL = URL(fileURLWithPath: storePath)
        guard let data = try? Data(contentsOf: storeURL),
              var store = try? PropertyListSerialization.propertyList(
                  from: data, options: .mutableContainersAndLeaves, format: nil
              ) as? [String: Any] else { return }

        let defaultChoice: [String: Any] = [
            "Provider": "default",
            "Files": [] as [Any],
            "Configuration": Data()
        ]
        let defaultContent: [String: Any] = ["Choices": [defaultChoice]]
        let defaultIdle: [String: Any] = [
            "Content": defaultContent,
            "LastSet": Date(),
            "LastUse": Date()
        ]
        let defaultEntry: [String: Any] = [
            "Type": "idle",
            "Idle": defaultIdle
        ]

        store["AllSpacesAndDisplays"] = defaultEntry
        store["SystemDefault"] = defaultEntry

        if var displays = store["Displays"] as? [String: Any] {
            for key in displays.keys {
                displays[key] = defaultEntry
            }
            store["Displays"] = displays
        }

        if var spaces = store["Spaces"] as? [String: Any] {
            for (spaceID, spaceVal) in spaces {
                guard var spaceDict = spaceVal as? [String: Any] else { continue }
                spaceDict["Default"] = defaultEntry
                if var spDisplays = spaceDict["Displays"] as? [String: Any] {
                    for dispKey in spDisplays.keys {
                        spDisplays[dispKey] = defaultEntry
                    }
                    spaceDict["Displays"] = spDisplays
                }
                spaces[spaceID] = spaceDict
            }
            store["Spaces"] = spaces
        }

        if let data = try? PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0) {
            let tmpURL = URL(fileURLWithPath: storePath + ".tmp")
            try? data.write(to: tmpURL)
            _ = try? FileManager.default.replaceItemAt(storeURL, withItemAt: tmpURL)
        }
    }

    private func configureScreensaver() {
        let aerialsPath = "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = [
            "-currentHost", "write", "com.apple.screensaver",
            "moduleDict",
            "-dict",
            "moduleName", "WallpaperAerialsExtension",
            "path", aerialsPath,
            "type", "0"
        ]
        try? task.run()
        task.waitUntilExit()
    }

    private func restartWallpaperAgent() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["WallpaperAgent"]
        try? task.run()
        task.waitUntilExit()
    }
}
