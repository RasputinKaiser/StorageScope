import Foundation

struct ResolvedSecurityScopedURL {
    let url: URL
    let access: SecurityScopedResourceAccess
    let bookmarkWasStale: Bool
}

final class SecurityScopedResourceAccess {
    let url: URL
    private var didStartAccess: Bool

    init(url: URL) {
        self.url = url
        didStartAccess = url.startAccessingSecurityScopedResource()
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
        UserDefaults.standard.set(bookmarks, forKey: Self.bookmarkDataByPathKey)
    }

    func resolve(path: String) throws -> ResolvedSecurityScopedURL? {
        guard let bookmarkData = bookmarkDataByPath()[path] else {
            return nil
        }

        var bookmarkWasStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &bookmarkWasStale
        )

        if bookmarkWasStale {
            remember(url)
        }

        return ResolvedSecurityScopedURL(
            url: url,
            access: SecurityScopedResourceAccess(url: url),
            bookmarkWasStale: bookmarkWasStale
        )
    }

    private func bookmarkDataByPath() -> [String: Data] {
        UserDefaults.standard.object(forKey: Self.bookmarkDataByPathKey) as? [String: Data] ?? [:]
    }
}
