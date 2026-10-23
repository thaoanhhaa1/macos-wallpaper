import Foundation

struct AppSettings: Codable, Equatable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var launchAtLogin: Bool
    var playback: PlaybackSettings
    var displayMode: DisplayMode
    var wallpaper: PersistedWallpaperState
    var displayConfigurations: [String: DisplayWallpaperConfiguration]

    init(
        schemaVersion: Int = AppSettings.currentSchemaVersion,
        launchAtLogin: Bool = false,
        playback: PlaybackSettings = PlaybackSettings(),
        displayMode: DisplayMode = .mainScreen,
        wallpaper: PersistedWallpaperState = PersistedWallpaperState(),
        displayConfigurations: [String: DisplayWallpaperConfiguration] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.launchAtLogin = launchAtLogin
        self.playback = playback
        self.displayMode = displayMode
        self.wallpaper = wallpaper
        self.displayConfigurations = displayConfigurations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? 1
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        playback = try container.decodeIfPresent(PlaybackSettings.self, forKey: .playback)
            ?? PlaybackSettings()
        displayMode = try container.decodeIfPresent(DisplayMode.self, forKey: .displayMode)
            ?? .mainScreen
        wallpaper = try container.decodeIfPresent(PersistedWallpaperState.self, forKey: .wallpaper)
            ?? PersistedWallpaperState()
        displayConfigurations = try container.decodeIfPresent(
            [String: DisplayWallpaperConfiguration].self,
            forKey: .displayConfigurations
        ) ?? [:]
    }

    mutating func migrateToCurrentVersion() {
        if schemaVersion < 2 {
            schemaVersion = 2
        }
    }
}

struct PlaybackSettings: Codable, Equatable {
    var isMuted: Bool
    var volume: Double
    var loopEnabled: Bool
    var scalingMode: ScalingMode
    var pauseOnFullscreen: Bool
    var pauseOnBattery: Bool

    init(
        isMuted: Bool = true,
        volume: Double = 0.5,
        loopEnabled: Bool = true,
        scalingMode: ScalingMode = .aspectFill,
        pauseOnFullscreen: Bool = false,
        pauseOnBattery: Bool = false
    ) {
        self.isMuted = isMuted
        self.volume = volume
        self.loopEnabled = loopEnabled
        self.scalingMode = scalingMode
        self.pauseOnFullscreen = pauseOnFullscreen
        self.pauseOnBattery = pauseOnBattery
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? true
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 0.5
        loopEnabled = try container.decodeIfPresent(Bool.self, forKey: .loopEnabled) ?? true
        scalingMode = try container.decodeIfPresent(ScalingMode.self, forKey: .scalingMode) ?? .aspectFill
        pauseOnFullscreen = try container.decodeIfPresent(Bool.self, forKey: .pauseOnFullscreen) ?? false
        pauseOnBattery = try container.decodeIfPresent(Bool.self, forKey: .pauseOnBattery) ?? false
    }
}

enum DisplayMode: String, Codable, CaseIterable, Identifiable {
    case allScreens
    case mainScreen
    case perDisplay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allScreens: "All displays"
        case .mainScreen: "Main display"
        case .perDisplay: "Per display"
        }
    }
}

enum ScalingMode: String, Codable, CaseIterable, Identifiable {
    case aspectFill
    case aspectFit
    case centerCrop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aspectFill: "Aspect fill"
        case .aspectFit: "Aspect fit"
        case .centerCrop: "Center crop"
        }
    }
}
