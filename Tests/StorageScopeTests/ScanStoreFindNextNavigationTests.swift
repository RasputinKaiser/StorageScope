import Foundation
import Testing
@testable import StorageScope

@MainActor
@Suite("ScanStore find-next navigation (Cmd+G)")
struct ScanStoreFindNextNavigationTests {
    @Test("advanceSearchResult is no-op when no search active")
    func advanceNoSearchNoOp() {
        let store = ScanStore()
        store.advanceSearchResult()
        #expect(store.currentSearchResultIndex == nil)
        #expect(store.selectedItemID == nil)
    }

    @Test("reverseSearchResult is no-op when no search active")
    func reverseNoSearchNoOp() {
        let store = ScanStore()
        store.reverseSearchResult()
        #expect(store.currentSearchResultIndex == nil)
    }

    @Test("advance cycles through matches and wraps around")
    func advanceCyclesAndWraps() async throws {
        let store = ScanStore()
        // Fixture: small tree with three matching items at top level so
        // searchResultIDs ends up with at least 3 entries.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmdg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["foo-report.txt", "foo-data.csv", "foo-summary.md"] {
            try Data().write(to: root.appendingPathComponent(name))
        }

        store.scanDeveloperFixturePath(root.path)
        try await waitForScanToFinish(store)

        store.filters.searchText = "foo"
        try await waitForSearchResultIDs(store, atLeast: 3)

        guard let ids = store.filters.searchResultIDs, ids.count >= 3 else {
            Issue.record("expected >=3 searchResultIDs, got \(store.filters.searchResultIDs?.count ?? 0)")
            return
        }

        store.advanceSearchResult()
        #expect(store.currentSearchResultIndex == 0)
        #expect(store.selectedItemID == ids[0])

        store.advanceSearchResult()
        #expect(store.currentSearchResultIndex == 1)
        #expect(store.selectedItemID == ids[1])

        store.advanceSearchResult()
        #expect(store.currentSearchResultIndex == 2)

        // Wrap around back to 0
        store.advanceSearchResult()
        #expect(store.currentSearchResultIndex == 0)
        #expect(store.selectedItemID == ids[0])
    }

    @Test("reverse starts from the last match and wraps backward")
    func reverseStartsFromLast() async throws {
        let store = ScanStore()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmdg-rev-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["foo-report.txt", "foo-data.csv", "foo-summary.md"] {
            try Data().write(to: root.appendingPathComponent(name))
        }

        store.scanDeveloperFixturePath(root.path)
        try await waitForScanToFinish(store)
        store.filters.searchText = "foo"
        try await waitForSearchResultIDs(store, atLeast: 3)

        guard let ids = store.filters.searchResultIDs, ids.count >= 3 else {
            Issue.record("expected >=3 searchResultIDs, got \(store.filters.searchResultIDs?.count ?? 0)")
            return
        }

        store.reverseSearchResult()
        #expect(store.currentSearchResultIndex == ids.count - 1)
        #expect(store.selectedItemID == ids[ids.count - 1])

        store.reverseSearchResult()
        #expect(store.currentSearchResultIndex == ids.count - 2)
    }

    /// Polls instead of a fixed sleep so this test stays reliable when the suite runs
    /// under heavier parallel load (many concurrent scan/pause-resume tests can squeeze a
    /// fixed timing budget) rather than assuming a specific wall-clock duration.
    private func waitForScanToFinish(_ store: ScanStore, timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + timeout
        while store.isScanning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitForSearchResultIDs(_ store: ScanStore, atLeast count: Int, timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + timeout
        while (store.filters.searchResultIDs?.count ?? 0) < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}