import Foundation

struct WallpaperAssignment: Codable, Equatable {
    var media: MediaReference
    var displayMode: DisplayMode

    init(media: MediaReference, displayMode: DisplayMode) {
        self.media = media
        self.displayMode = displayMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        media = try container.decode(MediaReference.self, forKey: .media)
        displayMode = try container.decodeIfPresent(DisplayMode.self, forKey: .displayMode)
            ?? .mainScreen
    }
}

struct WallpaperRestoreIssue: Codable, Equatable {
    var media: MediaReference
    var displayMode: DisplayMode
    var reason: String
    var occurredAt: Date
    var displayPersistentID: String?
    var displayName: String?

    init(
        media: MediaReference,
        displayMode: DisplayMode,
        reason: String,
        occurredAt: Date = Date(),
        displayPersistentID: String? = nil,
        displayName: String? = nil
    ) {
        self.media = media
        self.displayMode = displayMode
        self.reason = reason
        self.occurredAt = occurredAt
        self.displayPersistentID = displayPersistentID
        self.displayName = displayName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        media = try container.decode(MediaReference.self, forKey: .media)
        displayMode = try container.decodeIfPresent(DisplayMode.self, forKey: .displayMode)
            ?? .mainScreen
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
            ?? "The saved wallpaper couldn't be restored."
        occurredAt = try container.decodeIfPresent(Date.self, forKey: .occurredAt)
            ?? Date()
        displayPersistentID = try container.decodeIfPresent(
            String.self,
            forKey: .displayPersistentID
        )
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
    }
}

struct PersistedWallpaperState: Codable, Equatable {
    var active: WallpaperAssignment?
    var last: WallpaperAssignment?
    var restoreIssue: WallpaperRestoreIssue?

    init(
        active: WallpaperAssignment? = nil,
        last: WallpaperAssignment? = nil,
        restoreIssue: WallpaperRestoreIssue? = nil
    ) {
        self.active = active
        self.last = last
        self.restoreIssue = restoreIssue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        active = try container.decodeIfPresent(WallpaperAssignment.self, forKey: .active)
        last = try container.decodeIfPresent(WallpaperAssignment.self, forKey: .last)
        restoreIssue = try container.decodeIfPresent(WallpaperRestoreIssue.self, forKey: .restoreIssue)
    }

    mutating func clearIssue() {
        restoreIssue = nil
    }
}

struct DisplayWallpaperConfiguration: Codable, Equatable {
    var displayName: String
    var assignment: WallpaperAssignment

    init(displayName: String, assignment: WallpaperAssignment) {
        self.displayName = displayName
        self.assignment = assignment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            ?? "Display"
        assignment = try container.decode(WallpaperAssignment.self, forKey: .assignment)
    }
}

struct MissingWallpaper: Equatable, Identifiable {
    var reference: MediaReference
    var displayMode: DisplayMode
    var reason: String
    var occurredAt: Date
    var displayPersistentID: String?
    var targetDisplayName: String?

    var id: UUID { reference.identifier }

    init(issue: WallpaperRestoreIssue) {
        reference = issue.media
        displayMode = issue.displayMode
        reason = issue.reason
        occurredAt = issue.occurredAt
        displayPersistentID = issue.displayPersistentID
        targetDisplayName = issue.displayName
    }

    var displayName: String { reference.displayName }
    var displayDescription: String { targetDisplayName ?? displayName }
}
