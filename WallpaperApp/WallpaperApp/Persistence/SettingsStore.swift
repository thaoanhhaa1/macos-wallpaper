import Foundation

struct SettingsStore {
    private static let storageKey = "wallpaper.app-settings"

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            Log.persistence.info("No stored settings; using defaults")
            return AppSettings()
        }

        do {
            var settings = try decoder.decode(AppSettings.self, from: data)
            let loadedVersion = settings.schemaVersion
            if loadedVersion < AppSettings.currentSchemaVersion {
                settings.migrateToCurrentVersion()
                save(settings)
                Log.persistence.notice(
                    "Migrated settings schema \(loadedVersion, privacy: .public) -> \(settings.schemaVersion, privacy: .public)"
                )
            }
            Log.persistence.info("Loaded settings schema=\(settings.schemaVersion, privacy: .public)")
            return settings
        } catch {
            Log.persistence.error("Failed to decode settings: \(error.localizedDescription, privacy: .public)")
            return AppSettings()
        }
    }

    func save(_ settings: AppSettings) {
        do {
            let data = try encoder.encode(settings)
            defaults.set(data, forKey: Self.storageKey)
            Log.persistence.info("Saved settings schema=\(settings.schemaVersion, privacy: .public)")
        } catch {
            Log.persistence.error("Failed to encode settings: \(error.localizedDescription, privacy: .public)")
        }
    }
}
