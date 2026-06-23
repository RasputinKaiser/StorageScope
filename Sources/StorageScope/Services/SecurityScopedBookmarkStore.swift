import Foundation
import os

enum BookmarkError: LocalizedError {
    /// `startAccessingSecurityScopedResource` returned false — macOS revoked (or never
    /// granted) the sandbox scope for `url`. The bookmark data may still be valid; the
    /// user should re-pick the folder so the system can re-grant access.
    case accessDenied(URL)
    /// `URL.bookmarkData(options: .withSecurityScope)` threw while persisting a new
    /// bookmark for `url`. The scan can still run this session, but the folder will not
    /// be reopenable from recents on next launch.
    case bookmarkCreationFailed(URL, underlying: Error)
    /// Bookmark bytes are unreadable or corrupt — `URL(resolvingBookmarkData:)` threw.
    /// The stored data is unrecoverable; the entry is pruned.
    case bookmarkDataInvalid(path: String, underlying: Error)
    /// Bookmark resolved, but the file no longer exists at its path. Entry pruned.
    case fileMissing(URL)
    /// Bookmark resolved, but the volume hosting the file is not currently mounted.
    /// Entry pruned so the user must re-pick after reconnecting the drive.
    case volumeNotMounted(URL)

    var errorDescription: String? {
        switch self {
        case .accessDenied(let url):
            return "StorageScope lost macOS access to \(url.path). Choose the folder again to refresh the sandbox grant."
        case .bookmarkCreationFailed(let url, let underlying):
            return "StorageScope could not save access to \(url.path) for next launch: \(underlying.localizedDescription). You can still scan this session, but the folder will not be in Recents after restart; choose it again next time."
        case .bookmarkDataInvalid(let path, let underlying):
            return "StorageScope's saved access to \(path) is no longer readable: \(underlying.localizedDescription). Choose the folder again to re-grant access."
        case .fileMissing(let url):
            return "The folder at \(url.path) no longer exists. Pick a different folder, or recreate it and scan again."
        case .volumeNotMounted(let url):
            return "The volume containing \(url.path) is not currently mounted. Reconnect the drive, then scan again."
        }
    }
}

struct ResolvedSecurityScopedURL {
    let url: URL
    let access: SecurityScopedResourceAccess
    let bookmarkWasStale: Bool
}

/// Wraps a security-scoped resource grant. `startAccessingSecurityScopedResource` is
/// always paired with a `stopAccessingSecurityScopedResource` via `deinit` + `stop()`,
/// so callers cannot leak a started scope by losing the reference.
final class SecurityScopedResourceAccess {
    let url: URL
    private var didStartAccess: Bool

    init(url: URL) throws {
        self.url = url
        didStartAccess = url.startAccessingSecurityScopedResource()
        guard didStartAccess else {
            throw BookmarkError.accessDenied(url)
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
    typealias VolumeMountCheck = (URL) -> Bool
    typealias AccessFactory = (URL) throws -> SecurityScopedResourceAccess

    private static let bookmarkDataByPathKey = "StorageScope.securityScopedBookmarksByPath"
    private static let log = OSLog(subsystem: "com.rasputinkaiser.StorageScope", category: "bookmark")

    private let defaults: UserDefaults
    private let isVolumeMounted: VolumeMountCheck
    private let makeAccess: AccessFactory

    init(
        defaults: UserDefaults = .standard,
        isVolumeMounted: @escaping VolumeMountCheck = Self.defaultVolumeMountCheck,
        makeAccess: @escaping AccessFactory = SecurityScopedResourceAccess.init(url:)
    ) {
        self.defaults = defaults
        self.isVolumeMounted = isVolumeMounted
        self.makeAccess = makeAccess
    }

    var storedBookmarkPaths: [String] {
        bookmarkDataByPath().keys.sorted()
    }

    /// Persists a security-scoped bookmark for `url` so the folder can be reopened after
    /// relaunch without re-prompting the user. Throws `BookmarkError.bookmarkCreationFailed`
    /// on failure so the caller can surface to the user that "Recents" will not survive
    /// next launch.
    func remember(_ url: URL) throws {
        do {
            let bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var bookmarks = bookmarkDataByPath()
            bookmarks[url.standardizedFileURL.path] = bookmarkData
            defaults.set(bookmarks, forKey: Self.bookmarkDataByPathKey)
        } catch {
            throw BookmarkError.bookmarkCreationFailed(url, underlying: error)
        }
    }

    func storeBookmarkData(_ data: Data, for path: String) {
        var bookmarks = bookmarkDataByPath()
        bookmarks[path] = data
        defaults.set(bookmarks, forKey: Self.bookmarkDataByPathKey)
    }

    /// Resolves a stored bookmark back into a URL with a held security-scoped resource
    /// access. Returns `nil` when no bookmark is stored for `path` (first-run / unknown).
    /// Throws `BookmarkError` variants to classify *why* a known bookmark could not be
    /// reopened — corrupt data, missing file, unmounted volume, or sandbox revocation —
    /// so the UI can tell the user what to fix.
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
        } catch let error as NSError {
            // URL(resolvingBookmarkData:) throws NSFileNoSuchFileError when the
            // original location is gone, even though the bookmark bytes are
            // intact. Distinguish that from genuinely corrupt data so the user
            // hears "the folder is gone" rather than "access is unreadable."
            remove(path: path)
            if error.domain == NSCocoaErrorDomain, error.code == NSFileNoSuchFileError {
                throw classifyMissingURL(URL(fileURLWithPath: path, isDirectory: true))
            }
            throw BookmarkError.bookmarkDataInvalid(path: path, underlying: error)
        }

        // The path may vanish between the resolve above and this existence
        // probe (TOCTOU). Treat it the same way as the NSFileNoSuchFileError
        // path above: classify by mount state.
        guard FileManager.default.fileExists(atPath: url.path) else {
            remove(path: path)
            throw classifyMissingURL(url)
        }

        if bookmarkWasStale {
            refreshBookmark(url)
        }

        do {
            let access = try makeAccess(url)
            return ResolvedSecurityScopedURL(
                url: url,
                access: access,
                bookmarkWasStale: bookmarkWasStale
            )
        } catch {
            // Sandbox grant was revoked but the bookmark itself remains valid —
            // keep the data so a re-grant can succeed after the user re-picks.
            throw error
        }
    }

    /// Classifies a missing-path resolve failure by mount state: either
    /// `.volumeNotMounted` (external volume disconnected) or `.fileMissing`
    /// (path removed on a mounted volume).
    private func classifyMissingURL(_ url: URL) -> BookmarkError {
        if !isVolumeMounted(url) {
            return .volumeNotMounted(url)
        }
        return .fileMissing(url)
    }

    /// Drops bookmarks that can no longer be resolved (corrupt data, missing file,
    /// unmounted volume). Best-effort and non-throwing — invoked on app launch to
    /// tidy up `Recents` before the user opens the sidebar.
    func prune() {
        for path in bookmarkDataByPath().keys {
            do {
                _ = try resolve(path: path)
            } catch {
                os_log("pruned bookmark %{public}@: %{public}@",
                       log: Self.log, type: .error,
                       path, error.localizedDescription)
            }
        }
    }

    private func refreshBookmark(_ url: URL) {
        do {
            try remember(url)
        } catch {
            // Best-effort: the URL still resolves with the old data, so we keep it.
            // The next resolve may report stale again; surfacing the refresh failure
            // via logs makes it diagnosable when "Recents" eventually breaks.
            os_log("could not refresh stale bookmark for %{public}@: %{public}@",
                   log: Self.log, type: .info,
                   url.path, error.localizedDescription)
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

    /// Default volume-mounted probe used when classifying a missing path. The OS exposes
    /// no `volumeIsMountedKey`, so we infer from path prefix: external volumes live under
    /// `/Volumes/<name>/`, and a path on an unmounted external volume no longer matches
    /// any entry in `mountedVolumeURLs`. Paths off `/Volumes/` are on the root volume —
    /// always considered mounted.
    private static let defaultVolumeMountCheck: VolumeMountCheck = { url in
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/Volumes/") else {
            return true
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            return true
        }
        let volumePath = "/Volumes/\(parts[1])"
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [],
            options: []
        ) ?? []
        return mounted.contains { $0.standardizedFileURL.path == volumePath }
    }
}
