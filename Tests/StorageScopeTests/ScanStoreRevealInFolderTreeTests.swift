import Foundation
import StorageScopeCore
import Testing
@testable import StorageScope

@MainActor
@Suite("ScanStore Folder Tree drill-down")
struct ScanStoreRevealInFolderTreeTests {
    @Test("revealInFolderTree selects the item, expands ancestors, and switches to the tree view")
    func revealDeepItemExpandsAncestors() async throws {
        let store = ScanStore()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reveal-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("Media", isDirectory: true).appendingPathComponent("Renders", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0, count: 4096).write(to: nested.appendingPathComponent("clip.mov"))

        store.scanDeveloperFixturePath(root.path)
        try await waitForScanToFinish(store)

        guard let rootItem = store.scan?.rootItem else {
            Issue.record("expected a scanned root item")
            return
        }
        guard let target = findItem(named: "clip.mov", under: rootItem) else {
            Issue.record("expected clip.mov in the retained tree")
            return
        }

        store.revealInFolderTree(target)

        #expect(store.selectedView == .tree)
        #expect(store.selectedItemID == target.id)
        // Every ancestor container (root → Media → Renders) must be expanded so the
        // selected row is actually visible.
        var node = rootItem
        while node.id != target.id {
            #expect(store.treeExpandedIDs.contains(node.id), "ancestor \(node.name) should be expanded")
            guard let next = node.children.first(where: { findItem(named: "clip.mov", under: $0) != nil || $0.id == target.id }) else {
                Issue.record("broken ancestor chain at \(node.name)")
                return
            }
            node = next
        }
    }

    @Test("revealInFolderTree still opens the tree when the item is not in the retained tree")
    func revealUnretainedItemFallsBackToRoot() async throws {
        let store = ScanStore()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reveal-miss-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0, count: 1024).write(to: root.appendingPathComponent("real.bin"))

        store.scanDeveloperFixturePath(root.path)
        try await waitForScanToFinish(store)

        guard let rootItem = store.scan?.rootItem, let anyChild = rootItem.children.first else {
            Issue.record("expected a scanned root with a child")
            return
        }
        // Forge an item that isn't part of the retained tree (id derives from the
        // URL, so a URL outside the scan root can't match any retained node).
        let ghost = StorageItem(
            url: root.appendingPathComponent("ghost-\(UUID().uuidString).bin"),
            kind: .file,
            byteSize: 1,
            allocatedSize: 1,
            modifiedAt: nil,
            immediateChildCount: 0,
            descendantCount: 0,
            isReadable: true
        )
        _ = anyChild

        store.revealInFolderTree(ghost)

        #expect(store.selectedView == .tree)
        #expect(store.treeExpandedIDs.contains(rootItem.id))
    }

    // MARK: - Helpers

    private func findItem(named name: String, under node: StorageItem) -> StorageItem? {
        if node.name == name { return node }
        for child in node.children {
            if let found = findItem(named: name, under: child) {
                return found
            }
        }
        return nil
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
