import Foundation

enum MediaBookmarkError: LocalizedError, Equatable {
    case emptyBookmark(String)
    case creationFailed(String)
    case resolveFailed(String)
    case missingFile(String)
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case .emptyBookmark(let name):
            "The saved bookmark for “\(name)” is unavailable. Relink the video to restore the wallpaper."
        case .creationFailed(let name):
            "A security-scoped bookmark for “\(name)” couldn't be created. Choose the video again to grant access."
        case .resolveFailed(let name):
            "The saved bookmark for “\(name)” can't be resolved. Relink the video to restore the wallpaper."
        case .missingFile(let name):
            "The wallpaper video “\(name)” is missing. Relink it or choose another video."
        case .permissionDenied(let name):
            "The app doesn't have permission to read “\(name)”. Relink the video to grant access again."
        }
    }
}

final class SecurityScopedMedia {
    let url: URL
    private var isAccessing: Bool

    init(url: URL) {
        self.url = url
        isAccessing = url.startAccessingSecurityScopedResource()
    }

    var didStartAccessing: Bool { isAccessing }

    func stopAccessing() {
        guard isAccessing else { return }
        url.stopAccessingSecurityScopedResource()
        isAccessing = false
    }

    deinit {
        if isAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

struct ResolvedMedia {
    var reference: MediaReference
    var resource: SecurityScopedMedia
    var wasStale: Bool
}

enum MediaBookmark {
    static func makeBookmarkData(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            Log.persistence.error(
                "Failed to create security-scoped bookmark for \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)"
            )
            throw MediaBookmarkError.creationFailed(url.lastPathComponent)
        }
    }

    static func resolve(_ reference: MediaReference) throws -> ResolvedMedia {
        guard !reference.bookmarkData.isEmpty else {
            throw MediaBookmarkError.emptyBookmark(reference.displayName)
        }

        var isStale = false
        var needsUpgrade = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: reference.bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            if Self.isMissingFileError(error) {
                throw MediaBookmarkError.missingFile(reference.displayName)
            }
            do {
                url = try URL(
                    resolvingBookmarkData: reference.bookmarkData,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                needsUpgrade = true
            } catch {
                Log.persistence.error(
                    "Failed to resolve bookmark for \(reference.displayName, privacy: .private): \(error.localizedDescription, privacy: .public)"
                )
                if Self.isMissingFileError(error) {
                    throw MediaBookmarkError.missingFile(reference.displayName)
                }
                throw MediaBookmarkError.resolveFailed(reference.displayName)
            }
        }

        let resource = SecurityScopedMedia(url: url)

        guard FileManager.default.fileExists(atPath: url.path) else {
            resource.stopAccessing()
            Log.persistence.error(
                "Bookmark resolved to a missing file: \(reference.displayName, privacy: .private)"
            )
            throw MediaBookmarkError.missingFile(reference.displayName)
        }

        guard FileManager.default.isReadableFile(atPath: url.path) else {
            resource.stopAccessing()
            Log.persistence.error(
                "Bookmark resolved to an unreadable file: \(reference.displayName, privacy: .private)"
            )
            throw MediaBookmarkError.permissionDenied(reference.displayName)
        }

        var updated = reference
        if isStale || needsUpgrade {
            do {
                updated.bookmarkData = try makeBookmarkData(for: url)
            } catch {
                resource.stopAccessing()
                throw error
            }
            Log.persistence.notice(
                "Refreshed bookmark for \(reference.displayName, privacy: .private) stale=\(isStale, privacy: .public) upgraded=\(needsUpgrade, privacy: .public)"
            )
        }

        Log.persistence.info(
            "Resolved bookmark for \(reference.displayName, privacy: .private) stale=\(isStale, privacy: .public) upgraded=\(needsUpgrade, privacy: .public) securityScoped=\(resource.didStartAccessing, privacy: .public)"
        )

        return ResolvedMedia(reference: updated, resource: resource, wasStale: isStale || needsUpgrade)
    }

    private static func isMissingFileError(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)
    }
}
