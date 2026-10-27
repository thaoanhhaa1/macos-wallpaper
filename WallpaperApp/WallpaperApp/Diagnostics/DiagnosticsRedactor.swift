import CryptoKit
import Foundation

enum DiagnosticsRedactor {
    static func mediaName(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "none" }
        return "media-\(digest(name))"
    }

    static func mediaName(_ name: String) -> String {
        mediaName(Optional(name))
    }

    private static func digest(_ value: String) -> String {
        let hash = SHA256.hash(data: Data(value.utf8))
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
