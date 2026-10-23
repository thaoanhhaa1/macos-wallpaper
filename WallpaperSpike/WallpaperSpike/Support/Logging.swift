import OSLog

enum Log {
    static let subsystem = "com.local.wallpaperspike"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let surface = Logger(subsystem: subsystem, category: "surface")
    static let playback = Logger(subsystem: subsystem, category: "playback")
    static let diagnostics = Logger(subsystem: subsystem, category: "diagnostics")
}
