import Foundation

enum SecurityScopedBookmarkError: LocalizedError {
    case accessDenied(URL)

    var errorDescription: String? {
        switch self {
        case .accessDenied(let url):
            return "StorageScope could not access \(url.path). Choose the folder again or grant access in macOS privacy settings."
        }
    }
}

struct ResolvedSecurityScopedURL {
    let url: URL
    let access: SecurityScopedResourceAccess
    let bookmarkWasStale: Bool
}

final class SecurityScopedResourceAccess {
    let url: URL
    private var didStartAccess: Bool

    init(url: URL) throws {
        self.url = url
        didStartAccess = url.startAccessingSecurityScopedResource()
        guard didStartAccess else {
            throw SecurityScopedBookmarkError.accessDenied(url)
        }
    }

    deinit {
        stop()
    }

    func stop() {
        guard didStartAccess else {
            return
        }
        url.stopAccessingSecurityScopedResource()
        didStartAccess = false
    }
}

struct SecurityScopedBookmarkStore {
    private static let bookmarkDataByPathKey = "StorageScope.securityScopedBookmarksByPath"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var storedBookmarkPaths: [String] {
        bookmarkDataByPath().keys.sorted()
    }

    func remember(_ url: URL) {
        guard let bookmarkData = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            return
        }

        var bookmarks = bookmarkDataByPath()
        bookmarks[url.standardizedFileURL.path] = bookmarkData
        defaults.set(bookmarks, forKey: Self.bookmarkDataByPathKey)
    }

    func storeBookmarkData(_ data: Data, for path: String) {
        var bookmarks = bookmarkDataByPath()
        bookmarks[path] = data
        defaults.set(bookmarks, forKey: Self.bookmarkDataByPathKey)
    }

    func resolve(path: String) throws -> ResolvedSecurityScopedURL? {
        guard let bookmarkData = bookmarkDataByPath()[path] else {
            return nil
        }

        var bookmarkWasStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &bookmarkWasStale
            )
        } catch {
            remove(path: path)
            throw error
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            remove(path: path)
            return nil
        }

        if bookmarkWasStale {
            remember(url)
        }

        let access: SecurityScopedResourceAccess
        do {
            access = try SecurityScopedResourceAccess(url: url)
        } catch {
            remove(path: path)
            throw error
        }

        return ResolvedSecurityScopedURL(
            url: url,
            access: access,
            bookmarkWasStale: bookmarkWasStale
        )
    }

    func prune() {
        for path in bookmarkDataByPath().keys {
            _ = try? resolve(path: path)
        }
    }

    private func remove(path: String) {
        var bookmarks = bookmarkDataByPath()
        bookmarks.removeValue(forKey: path)
        defaults.set(bookmarks, forKey: Self.bookmarkDataByPathKey)
    }

    private func bookmarkDataByPath() -> [String: Data] {
        defaults.object(forKey: Self.bookmarkDataByPathKey) as? [String: Data] ?? [:]
    }
}
