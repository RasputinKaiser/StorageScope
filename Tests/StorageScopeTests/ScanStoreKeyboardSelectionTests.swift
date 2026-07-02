import Foundation
import StorageScopeCore
import Testing
@testable import StorageScope

@MainActor
@Suite("ScanStore keyboard selection")
struct ScanStoreKeyboardSelectionTests {
    @Test("arrow keys walk the ranked list, clamp at both ends, and start from the first item")
    func adjacentSelectionWalksAndClamps() async throws {
        let store = ScanStore()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kbd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Distinct sizes so the ranked order is deterministic (largest first).
        for (index, name) in ["big.bin", "mid.bin", "small.bin"].enumerated() {
            try Data(repeating: 0, count: 4096 * (3 - index)).write(to: root.appendingPathComponent(name))
        }

        store.scanDeveloperFixturePath(root.path)
        try await waitForScanToFinish(store)
        store.selectedView = .largestFiles

        let ranked = store.items(for: .largestFiles)
        guard ranked.count >= 3 else {
            Issue.record("expected 3 ranked files, got \(ranked.count)")
            return
        }

        // No selection yet: ↓ selects the first item.
        #expect(store.selectAdjacentItem(offset: 1) == ranked[0].id)
        // Walk down twice.
        #expect(store.selectAdjacentItem(offset: 1) == ranked[1].id)
        #expect(store.selectAdjacentItem(offset: 1) == ranked[2].id)
        // Clamp at the bottom.
        #expect(store.selectAdjacentItem(offset: 1) == ranked[2].id)
        // Walk back up and clamp at the top.
        #expect(store.selectAdjacentItem(offset: -1) == ranked[1].id)
        #expect(store.selectAdjacentItem(offset: -1) == ranked[0].id)
        #expect(store.selectAdjacentItem(offset: -1) == ranked[0].id)
        #expect(store.selectedItemID == ranked[0].id)
    }

    @Test("selection is a no-op when the active view has no items")
    func noItemsNoSelection() {
        let store = ScanStore()
        store.selectedView = .largestFiles
        #expect(store.selectAdjacentItem(offset: 1) == nil)
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
