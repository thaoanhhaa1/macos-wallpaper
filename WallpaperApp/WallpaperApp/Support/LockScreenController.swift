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

    func sync(videoURL: URL, displayName: String) async {
        let fm = FileManager.default

        // 1. Ensure directories exist
        try? fm.createDirectory(atPath: videosDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: thumbsDir, withIntermediateDirectories: true)

        let destVideoURL = URL(fileURLWithPath: videosDir + "/\(assetID).mov")
        let destThumbURL = URL(fileURLWithPath: thumbsDir + "/\(assetID).png")

        // 2. Copy video file if needed
        let srcSize = (try? fm.attributesOfItem(atPath: videoURL.path)[.size] as? Int) ?? -1
        let dstSize = (try? fm.attributesOfItem(atPath: destVideoURL.path)[.size] as? Int) ?? -2
        let videoChanged = (srcSize != dstSize) || (lastSyncedURL != videoURL)

        if videoChanged {
            if fm.fileExists(atPath: destVideoURL.path) {
                try? fm.removeItem(at: destVideoURL)
            }
            do {
                try fm.copyItem(at: videoURL, to: destVideoURL)
                Log.lockScreen.info("Copied lock screen video to \(destVideoURL.path, privacy: .public)")
            } catch {
                Log.lockScreen.error("Failed to copy lock screen video: \(error.localizedDescription, privacy: .public)")
                return
            }
        }

        // 3. Generate high-resolution thumbnail
        if videoChanged || !fm.fileExists(atPath: destThumbURL.path) {
            await generateThumbnail(from: videoURL, to: destThumbURL)
        }

        // 4. Update /Library/Caches/Desktop Pictures/<userUUID>/lockscreen.png if accessible
        updateStaticLockScreenCache(from: destThumbURL)

        // 5. Update Desktop picture using NSWorkspace for all screens
        updateDesktopPicture(using: destThumbURL)

        // 6. Update entries.json
        guard updateEntriesJSON(displayName: displayName, videoURL: destVideoURL, thumbURL: destThumbURL) else {
            Log.lockScreen.error("Failed to update entries.json")
            return
        }

        // 7. Update Index.plist
        guard updateWallpaperStore() else {
            Log.lockScreen.error("Failed to update wallpaper store")
            return
        }

        // 8. Configure screensaver module to WallpaperAerialsExtension
        configureScreensaver()

        // 9. Restart WallpaperAgent
        restartWallpaperAgent()

        isSynced = true
        lastSyncedURL = videoURL
        lastSyncedName = displayName
        Log.lockScreen.notice("Successfully synchronized video with lock screen (\(displayName, privacy: .public))")
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

    private func updateDesktopPicture(using thumbURL: URL) {
        for screen in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(thumbURL, for: screen, options: [:])
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

    private func updateWallpaperStore() -> Bool {
        let configDict: [String: String] = ["assetID": assetID]
        guard let configData = try? PropertyListSerialization.data(
            fromPropertyList: configDict, format: .binary, options: 0
        ) else { return false }

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
        let entry: [String: Any] = [
            "Type": "linked",
            "Linked": linked
        ]

        store["SystemDefault"] = entry
        store["AllSpacesAndDisplays"] = entry

        if var displays = store["Displays"] as? [String: Any] {
            for key in displays.keys {
                displays[key] = entry
            }
            store["Displays"] = displays
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
        if let data = try? PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0) {
            try? data.write(to: storeURL)
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
