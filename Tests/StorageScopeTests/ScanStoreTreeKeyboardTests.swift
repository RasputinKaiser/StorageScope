import Foundation
import StorageScopeCore
import Testing
@testable import StorageScope

@MainActor
@Suite("ScanStore tree keyboard navigation and type-ahead")
struct ScanStoreTreeKeyboardTests {
    /// Fixture: root / Media / Renders / clip.mov plus root / note.txt
    private func makeScannedStore() async throws -> (ScanStore, root: URL, cleanup: () -> Void) {
        let store = ScanStore()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("treekbd-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("Media", isDirectory: true).appendingPathComponent("Renders", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 8192).write(to: nested.appendingPathComponent("clip.mov"))
        try Data(repeating: 0, count: 4096).write(to: root.appendingPathComponent("note.txt"))

        store.scanDeveloperFixturePath(root.path)
        try await waitForScanToFinish(store)
        return (store, root, { try? FileManager.default.removeItem(at: root) })
    }

    @Test("visibleTreeItems descends only into expanded containers, in display order")
    func visibleItemsRespectExpansion() async throws {
        let (store, _, cleanup) = try await makeScannedStore()
        defer { cleanup() }
        guard let root = store.scan?.rootItem else { return }

        // Nothing expanded: only the root row is visible.
        store.treeExpandedIDs = []
        #expect(store.visibleTreeItems().map(\.id) == [root.id])

        // Expanding the root surfaces its children, but not grandchildren.
        store.treeExpandedIDs = [root.id]
        let visible = store.visibleTreeItems()
        #expect(visible.count == 1 + root.children.count)
        #expect(!visible.contains(where: { $0.name == "Renders" }))

        // Fully expanded: DFS order — a child's subtree appears before the next sibling.
        store.expandEntireTree()
        let all = store.visibleTreeItems()
        let names = all.map(\.name)
        guard let media = names.firstIndex(of: "Media"), let renders = names.firstIndex(of: "Renders"),
              let clip = names.firstIndex(of: "clip.mov") else {
            Issue.record("expected Media/Renders/clip.mov in \(names)")
            return
        }
        #expect(media < renders && renders < clip)
    }

    @Test("left arrow collapses an expanded folder, then ascends to the parent")
    func leftArrowCollapsesThenAscends() async throws {
        let (store, _, cleanup) = try await makeScannedStore()
        defer { cleanup() }
        guard let root = store.scan?.rootItem,
              let media = root.children.first(where: { $0.name == "Media" }) else { return }

        store.expandEntireTree()
        store.selectedItemID = media.id

        // First ← collapses Media (selection stays).
        #expect(store.collapseOrAscendTreeSelection() == media.id)
        #expect(!store.treeExpandedIDs.contains(media.id))
        #expect(store.selectedItemID == media.id)

        // Second ← ascends to the root.
        #expect(store.collapseOrAscendTreeSelection() == root.id)
        #expect(store.selectedItemID == root.id)
    }

    @Test("right arrow expands a collapsed folder, then steps into the first child")
    func rightArrowExpandsThenDescends() async throws {
        let (store, _, cleanup) = try await makeScannedStore()
        defer { cleanup() }
        guard let root = store.scan?.rootItem,
              let media = root.children.first(where: { $0.name == "Media" }) else { return }

        store.treeExpandedIDs = [root.id]
        store.selectedItemID = media.id

        // First → expands Media.
        #expect(store.expandOrDescendTreeSelection() == media.id)
        #expect(store.treeExpandedIDs.contains(media.id))

        // Second → steps into Media's first visible child (Renders).
        let descended = store.expandOrDescendTreeSelection()
        #expect(store.visibleTreeItems().first(where: { $0.id == descended })?.name == "Renders")
    }

    @Test("type-ahead selects the first display-name prefix match, case-insensitively")
    func typeAheadSelectsPrefixMatch() async throws {
        let (store, _, cleanup) = try await makeScannedStore()
        defer { cleanup() }
        store.selectedView = .largestFiles

        guard let id = store.selectItem(matchingPrefix: "NO") else {
            Issue.record("expected a match for prefix 'NO'")
            return
        }
        #expect(store.items(for: .largestFiles).first(where: { $0.id == id })?.name == "note.txt")
        #expect(store.selectItem(matchingPrefix: "zzz") == nil)
    }

    @Test("escape clears an active search exactly once")
    func escapeClearsSearch() {
        let store = ScanStore()
        #expect(store.clearSearchIfActive() == false)
        store.filters.searchText = "cache"
        #expect(store.clearSearchIfActive() == true)
        #expect(store.filters.searchText.isEmpty)
        #expect(store.clearSearchIfActive() == false)
    }

    @Test("cleanup candidate selection is nil-safe without a scan")
    func cleanupSelectionNilSafe() {
        let store = ScanStore()
        #expect(store.selectAdjacentCleanupCandidate(offset: 1) == nil)
        store.toggleSelectedCleanupCandidate() // must not crash
        #expect(store.selectedItemID == nil)
    }

    private func waitForScanToFinish(_ store: ScanStore, timeout: Duration = .seconds(5)) async throws {
        let start = ContinuousClock.now
        while store.isScanning || store.scan == nil {
            if ContinuousClock.now - start > timeout {
                throw TimeoutError()
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private struct TimeoutError: Error {}
}
