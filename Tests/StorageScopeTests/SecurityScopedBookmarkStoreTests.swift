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
}
