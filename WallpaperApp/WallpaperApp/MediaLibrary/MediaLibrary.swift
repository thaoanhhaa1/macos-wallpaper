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
