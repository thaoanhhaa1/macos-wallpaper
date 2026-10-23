import OSLog

enum Log {
    static let subsystem = "com.local.wallpaperapp"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let settings = Logger(subsystem: subsystem, category: "settings")
    static let menuBar = Logger(subsystem: subsystem, category: "menu-bar")
    static let media = Logger(subsystem: subsystem, category: "media")
    static let playback = Logger(subsystem: subsystem, category: "playback")
    static let surface = Logger(subsystem: subsystem, category: "surface")
    static let display = Logger(subsystem: subsystem, category: "display")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let policy = Logger(subsystem: subsystem, category: "policy")
    static let diagnostics = Logger(subsystem: subsystem, category: "diagnostics")
}
