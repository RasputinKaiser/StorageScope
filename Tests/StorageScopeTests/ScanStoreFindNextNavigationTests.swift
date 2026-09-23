import Foundation
import Testing
import StorageScopeCore
@testable import StorageScope

@MainActor
@Suite("ScanStore find-next navigation (Cmd+G)")
struct ScanStoreFindNextNavigationTests {
    @Test("changing or clearing a query restarts navigation in both directions")
    func queryChangesResetNavigation() {
        let store = makeStore()
        let previousView = store.selectedView
        defer { store.selectedView = previousView }
        store.selectedView = .largestFiles
        store.filters.query = "find"
        store.advanceSearchResult()
        store.advanceSearchResult()
        #expect(store.currentSearchResultIndex == 1)

        store.filters.query = "pdf"
        #expect(store.currentSearchResultIndex == nil)
        let pdfIDs = store.items(for: .largestFiles).map(\.id)
        store.advanceSearchResult()
        #expect(store.currentSearchResultIndex == 0)
        #expect(store.selectedItemID == pdfIDs.first)

        store.filters.query = ""
        #expect(store.currentSearchResultIndex == nil)
        store.filters.query = "find"
        let allIDs = store.items(for: .largestFiles).map(\.id)
        store.reverseSearchResult()
        #expect(store.currentSearchResultIndex == allIDs.count - 1)
        #expect(store.selectedItemID == allIDs.last)
    }

    @Test("list navigation follows the active rows and skips size and type exclusions")
    func listNavigationUsesVisibleRows() {
        let store = makeStore()
        let previousView = store.selectedView
        defer { store.selectedView = previousView }
        store.selectedView = .largestFiles
        store.filters.query = "find"
        let allIDs = store.items(for: .largestFiles).map(\.id)
        #expect(allIDs.count == 4)
        store.advanceSearchResult()
        #expect(store.selectedItemID == allIDs[0])
        store.advanceSearchResult()
        #expect(store.selectedItemID == allIDs[1])

        store.filters.fileTypeFocus = "txt"
        #expect(store.currentSearchResultIndex == nil)
        let textID = store.items(for: .largestFiles).first?.id
        store.advanceSearchResult()
        #expect(store.selectedItemID == textID)
        store.advanceSearchResult()
        #expect(store.selectedItemID == textID)

        store.filters.fileTypeFocus = nil
        store.filters.sizeFilter = .over100MB
        #expect(store.currentSearchResultIndex == nil)
        let largeID = store.items(for: .largestFiles).first?.id
        store.reverseSearchResult()
        #expect(store.currentSearchResultIndex == 0)
        #expect(store.selectedItemID == largeID)

        store.filters.sizeFilter = .over1GB
        #expect(store.hasNavigableSearchResults == false)
        store.advanceSearchResult()
        #expect(store.currentSearchResultIndex == nil)
    }

    @Test("changing views uses that view's matches, while tree find reveals collapsed descendants")
    func treeFindRevealsMatch() {
        let store = makeStore()
        let previousView = store.selectedView
        defer { store.selectedView = previousView }
        store.selectedView = .largestFolders
        store.filters.query = "find-deep"
        #expect(store.hasNavigableSearchResults == false)
        store.advanceSearchResult()
        #expect(store.currentSearchResultIndex == nil)

        store.selectedView = .tree
        store.treeExpandedIDs.removeAll()
        #expect(store.hasNavigableSearchResults)
        store.advanceSearchResult()
        let selectedID = store.selectedItemID
        #expect(selectedID?.hasSuffix("find-deep.pdf") == true)
        #expect(store.visibleTreeItems().contains(where: { $0.id == selectedID }))
        #expect(store.currentSearchResultIndex == 0)
    }

    @Test("Duplicate Review navigation includes verified rows")
    func duplicateReviewIncludesVerifiedRows() {
        let store = makeStore(includeVerified: true)
        let previousView = store.selectedView
        defer { store.selectedView = previousView }
        store.selectedView = .duplicateCandidates
        store.filters.query = "find-verified"
        #expect(store.filters.searchResultIDs?.isEmpty == true,
                "verified ranked rows can be outside the retained tree")
        let verifiedIDs = store.verifiedDuplicateGroups.flatMap(\.items).map(\.id)
        #expect(verifiedIDs.count == 2)
        #expect(store.hasNavigableSearchResults)
        store.advanceSearchResult()
        #expect(store.selectedItemID == verifiedIDs.first)
        store.advanceSearchResult()
        #expect(store.selectedItemID == verifiedIDs.last)
    }

    @Test("All Sizes shows scanner-retained 20 MB duplicate leads")
    func candidateGroupRespectsOnlyActiveSizeFilter() {
        let store = makeStore(includeCandidate: true)
        let previousView = store.selectedView
        defer { store.selectedView = previousView }
        store.selectedView = .duplicateCandidates
        store.filters.query = "find-candidate"
        #expect(store.filters.searchResultIDs?.isEmpty == true)
        #expect(store.duplicateGroups.count == 1)
        #expect(store.hasNavigableSearchResults)
        store.advanceSearchResult()
        #expect(store.selectedItemID == store.duplicateGroups[0].items[0].id)

        store.filters.sizeFilter = .over100MB
        #expect(store.duplicateGroups.isEmpty)
        #expect(store.hasNavigableSearchResults == false)
    }

    private func makeStore(includeVerified: Bool = false, includeCandidate: Bool = false) -> ScanStore {
        let store = ScanStore()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("navigation-\(UUID().uuidString)", isDirectory: true)
        func file(_ name: String, size: Int64, under folder: URL) -> StorageItem {
            StorageItem(url: folder.appendingPathComponent(name), kind: .file,
                        byteSize: size, allocatedSize: size, modifiedAt: .now,
                        immediateChildCount: 0, descendantCount: 0, isReadable: true,
                        fileExtension: (name as NSString).pathExtension)
        }
        let alpha = file("find-alpha.txt", size: 10, under: rootURL)
        let beta = file("find-beta.pdf", size: 20, under: rootURL)
        let large = file("find-large.pdf", size: 120_000_000, under: rootURL)
        let deep = file("find-deep.pdf", size: 30, under: rootURL.appendingPathComponent("Nested"))
        let verified = includeVerified
            ? [file("find-verified-one.bin", size: 40, under: rootURL),
               file("find-verified-two.bin", size: 40, under: rootURL)]
            : []
        let candidates = includeCandidate
            ? [file("find-candidate-one.bin", size: 20_000_000, under: rootURL),
               file("find-candidate-two.bin", size: 20_000_000, under: rootURL)]
            : []
        let nested = StorageItem(url: rootURL.appendingPathComponent("Nested"), kind: .folder,
                                 byteSize: 30, allocatedSize: 30, modifiedAt: .now,
                                 immediateChildCount: 1, descendantCount: 1, children: [deep], isReadable: true)
        let rootChildren = [alpha, beta, large, nested]
        let root = StorageItem(url: rootURL, kind: .folder,
                               byteSize: 120_000_060, allocatedSize: 120_000_060, modifiedAt: .now,
                               immediateChildCount: rootChildren.count, descendantCount: rootChildren.count + 1,
                               children: rootChildren, isReadable: true)
        let files = [alpha, beta, large, deep]
        let verifiedGroups = verified.isEmpty ? [] : [VerifiedDuplicateGroup(
            checksum: "navigation-verified", byteSize: 40, items: verified)]
        let candidateGroups = candidates.isEmpty ? [] : [DuplicateSizeGroup(
            byteSize: 20_000_000, items: candidates)]
        store.scan = StorageScan(rootURL: rootURL, startedAt: .now, finishedAt: .now,
                                 rootItem: root, retainedItems: root.flattened(),
                                 scannedItemCount: root.retainedItemCount, inaccessibleItemCount: 0,
                                 totalBytes: root.byteSize, largestFiles: files,
                                 largestFolders: [nested], oldLargeFiles: [],
                                 typeBreakdown: [], duplicateSizeGroups: candidateGroups,
                                 verifiedDuplicateGroups: verifiedGroups, cleanupCandidates: [])
        return store
    }

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
        let previousView = store.selectedView
        defer { store.selectedView = previousView }
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
        let previousView = store.selectedView
        defer { store.selectedView = previousView }
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
