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

    // MARK: - items(for:) derived cache hit/miss

    @Test("items(for:) cache hits on consecutive identical calls")
    func cacheHitOnConsecutiveCalls() async throws {
        let store = await makeStoreWithReadyScan()
        store.resetItemsCacheDebugCounters()

        let firstCall = store.items(for: .largestFiles)
        #expect(firstCall.isEmpty == false)
        #expect(store.itemsCacheMissCount == 1)
        #expect(store.itemsCacheHitCount == 0)

        let secondCall = store.items(for: .largestFiles)
        #expect(secondCall.count == firstCall.count)
        #expect(store.itemsCacheHitCount == 1)
        #expect(store.itemsCacheMissCount == 1, "Miss must not double — rebuilt instead of hitting")
    }

    @Test("items(for:) cache survives an irrelevant filter change")
    func cacheSurvivesIrrelevantFilterChange() async throws {
        let store = await makeStoreWithReadyScan()
        store.resetItemsCacheDebugCounters()

        _ = store.items(for: .largestFiles)
        #expect(store.itemsCacheMissCount == 1)

        // cleanupLaneFilter feeds cleanupCandidates only; .largestFiles doesn't use it.
        store.filters.cleanupLaneFilter = .verified

        _ = store.items(for: .largestFiles)
        #expect(store.itemsCacheHitCount == 1, "Irrelevant cleanupLaneFilter change should hit cache")
        #expect(store.itemsCacheMissCount == 1)
    }

    @Test("items(for:) cache rebuilds when a relevant filter changes")
    func cacheRebuildsOnRelevantFilterChange() async throws {
        let store = await makeStoreWithReadyScan()
        store.resetItemsCacheDebugCounters()

        let initial = store.items(for: .largestFiles)
        #expect(initial.count == 4)
        #expect(store.itemsCacheMissCount == 1)

        store.filters.sizeFilter = .over1GB
        let narrowed = store.items(for: .largestFiles)
        #expect(narrowed.isEmpty)
        #expect(store.itemsCacheMissCount == 2, "sizeFilter is in the key — change must miss")
        #expect(store.itemsCacheHitCount == 0)
    }

    @Test("items(for:) cache rebuilds when the view changes")
    func cacheRebuildsOnViewChange() async throws {
        let store = await makeStoreWithReadyScan()
        store.resetItemsCacheDebugCounters()

        _ = store.items(for: .largestFiles)
        #expect(store.itemsCacheMissCount == 1)

        _ = store.items(for: .largestFolders)
        #expect(store.itemsCacheMissCount == 2)
    }

    @Test("items(for: .cleanupReview) cache is keyed by cleanupLaneFilter")
    func cleanupCacheKeyedByLane() async throws {
        let store = await makeStoreWithReadyScan()
        store.resetItemsCacheDebugCounters()

        _ = store.items(for: .cleanupReview)
        #expect(store.itemsCacheMissCount == 1)

        store.filters.cleanupLaneFilter = .verified
        _ = store.items(for: .cleanupReview)
        #expect(store.itemsCacheMissCount == 2, "lane IS in the key when view == .cleanupReview")
    }

    @Test("items(for:) cache survives a no-op assignment to filters.sizeFilter")
    func cacheSurvivesNoOpAssignment() async throws {
        let store = await makeStoreWithReadyScan()
        store.resetItemsCacheDebugCounters()

        let snapshot = store.items(for: .largestFiles)
        #expect(store.itemsCacheMissCount == 1)

        // FilterStore's @Published sizeFilter didSet calls coordinateInvalidate
        // unconditionally on no-op assignments; the key comparison in items(for:)
        // is what makes the no-op a cache hit instead of a rebuild.
        store.filters.sizeFilter = store.filters.sizeFilter

        let next = store.items(for: .largestFiles)
        #expect(next.count == snapshot.count)
        #expect(store.itemsCacheHitCount == 1, "No-op assignment must hit cache, not rebuild")
        #expect(store.itemsCacheMissCount == 1)
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
