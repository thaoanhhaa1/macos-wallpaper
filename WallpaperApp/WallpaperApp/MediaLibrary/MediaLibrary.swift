import Foundation

struct MediaReference: Codable, Identifiable, Equatable {
    var identifier: UUID
    var bookmarkData: Data
    var displayName: String
    var lastKnownDuration: Double?

    var id: UUID { identifier }

    init(
        identifier: UUID = UUID(),
        bookmarkData: Data,
        displayName: String,
        lastKnownDuration: Double? = nil
    ) {
        self.identifier = identifier
        self.bookmarkData = bookmarkData
        self.displayName = displayName
        self.lastKnownDuration = lastKnownDuration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decodeIfPresent(UUID.self, forKey: .identifier) ?? UUID()
        bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData) ?? Data()
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? "Video"
        lastKnownDuration = try container.decodeIfPresent(Double.self, forKey: .lastKnownDuration)
    }

    var bookmarkIsEmpty: Bool { bookmarkData.isEmpty }
}

enum DevelopmentFixture {
    static var bundleURL: URL? {
        #if DEBUG
        Bundle.main.url(forResource: "wallpaper-fixture", withExtension: "mp4")
        #else
        nil
        #endif
    }
}
