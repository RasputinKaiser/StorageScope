import Foundation
import Testing
@testable import StorageScope

@Suite("SecurityScopedBookmarkStore")
struct SecurityScopedBookmarkStoreTests {
    @Test("prune removes bookmarks that cannot resolve")
    func pruneRemovesUnresolvableBookmarks() throws {
        let suiteName = "StorageScopeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let deadPath = "/tmp/storagescope-dead-bookmark-\(UUID().uuidString)"
        let store = SecurityScopedBookmarkStore(defaults: defaults)
        store.storeBookmarkData(Data("not-a-bookmark".utf8), for: deadPath)

        store.prune()

        #expect(store.storedBookmarkPaths.isEmpty)
    }

    @Test("fresh store exposes no bookmark paths")
    func freshStoreExposesNoPaths() throws {
        let suiteName = "StorageScopeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SecurityScopedBookmarkStore(defaults: defaults)

        #expect(store.storedBookmarkPaths.isEmpty)
    }

    @Test("resolve returns nil for unknown path without throwing")
    func resolveReturnsNilForUnknownPath() throws {
        let suiteName = "StorageScopeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SecurityScopedBookmarkStore(defaults: defaults)
        let unknownPath = "/tmp/storagescope-unknown-\(UUID().uuidString)"

        let resolved = try store.resolve(path: unknownPath)

        #expect(resolved == nil)
        #expect(store.storedBookmarkPaths.isEmpty)
    }

    @Test("remember round-trips and resolves a non-stale bookmark")
    func rememberRoundTripsNonStaleBookmark() throws {
        let suiteName = "StorageScopeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempDir = try makeTempDir()
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let expectedPath = tempDir.standardizedFileURL.path
        let store = SecurityScopedBookmarkStore(defaults: defaults)

        store.remember(tempDir)

        #expect(store.storedBookmarkPaths == [expectedPath])

        let resolved = try #require(try store.resolve(path: expectedPath))

        #expect(resolved.url.standardizedFileURL.path == expectedPath)
        #expect(resolved.bookmarkWasStale == false)
    }

    @Test("storeBookmarkData round-trips real security-scoped bookmark data")
    func storeBookmarkDataRoundTripsRealBookmark() throws {
        let suiteName = "StorageScopeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempDir = try makeTempDir()
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let expectedPath = tempDir.standardizedFileURL.path
        let bookmarkData = try tempDir.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let store = SecurityScopedBookmarkStore(defaults: defaults)
        store.storeBookmarkData(bookmarkData, for: expectedPath)

        #expect(store.storedBookmarkPaths == [expectedPath])

        let resolved = try #require(try store.resolve(path: expectedPath))

        #expect(resolved.url.standardizedFileURL.path == expectedPath)
        #expect(resolved.bookmarkWasStale == false)
    }

    private func makeTempDir() throws -> URL {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        return baseURL.appendingPathComponent("storagescope-tests-\(UUID().uuidString)")
    }
}