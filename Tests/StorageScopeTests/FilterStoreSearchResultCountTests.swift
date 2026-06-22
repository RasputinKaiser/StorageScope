import Foundation
import Testing
@testable import StorageScope

@MainActor
@Suite("FilterStore search result count")
struct FilterStoreSearchResultCountTests {
    @Test("searchResultCount is nil when no query is active")
    func nilWhenNoQuery() async throws {
        let store = await makeStoreWithReadyScan()
        store.filters.searchText = ""
        store.filters.query = ""
        #expect(store.filters.searchResultCount == nil)
    }

    @Test("searchResultCount is nil when query is only whitespace")
    func nilWhenWhitespaceQuery() async throws {
        let store = await makeStoreWithReadyScan()
        store.filters.query = "   "
        #expect(store.filters.searchResultCount == nil)
    }

    @Test("searchResultCount is non-zero when query matches items")
    func nonZeroWhenMatches() async throws {
        let store = await makeStoreWithReadyScan()
        store.filters.query = "alpha"
        #expect((store.filters.searchResultCount ?? 0) > 0)
    }

    @Test("searchResultCount reflects subtree matches, includes parent folders")
    func reflectsSubtreeCount() async throws {
        let store = await makeStoreWithReadyScan()
        store.filters.query = "alpha"
        #expect(store.filters.searchResultCount == store.filters.searchSubtreeMatchIDs?.count)
    }

    @Test("searchResultCount is zero when query has no matches")
    func zeroWhenNoMatches() async throws {
        let store = await makeStoreWithReadyScan()
        store.filters.query = "zzz-not-present-anywhere-12345"
        #expect(store.filters.searchResultCount == 0)
    }

    @Test("searchResultCount is nil when no scan is loaded")
    func nilWhenScanAbsent() async throws {
        let store = ScanStore()
        store.filters.query = "alpha"
        #expect(store.filters.searchResultCount == nil)
    }
}

@MainActor
private func makeStoreWithReadyScan() async -> ScanStore {
    let store = ScanStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for name in ["alpha-one.bin", "alpha-two.bin", "beta-one.bin", "gamma.bin"] {
        let url = root.appendingPathComponent(name, isDirectory: false)
        try? Data(repeating: 0x41, count: 1024).write(to: url)
    }
    store.scanDeveloperFixturePath(root.path)
    for _ in 0..<50 {
        if !store.isScanning { return store }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return store
}
