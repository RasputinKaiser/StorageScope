import Foundation
import Testing
import StorageScopeCore
@testable import StorageScope

@MainActor
@Suite("Trash review isolation")
struct TrashReviewIsolationTests {
    @Test("Removing a reviewed item preserves the batch independent of current selection")
    func removalUsesReviewedPlan() throws {
        let store = ScanStore()
        let candidates = [candidate("first"), candidate("second"), candidate("third")]
        store.pendingTrashReviewPlan = TrashReviewPlan(candidates: candidates)
        store.selectedCleanupCandidateIDs = ["unrelated-selection"]
        let first = try #require(store.pendingTrashReviewPlan?.items.first)
        store.removePendingTrashReviewItem(first)
        #expect(store.pendingTrashReviewPlan?.items.map(\.id) == Array(candidates.dropFirst()).map(\.id))
        #expect(store.selectedCleanupCandidateIDs == ["unrelated-selection"])
        #expect(store.pendingTrashReviewPlan?.estimatedReclaimBytes == 2048)
    }

    @Test("Removing the last manually reviewed item dismisses the sheet")
    func removingLastItemDismisses() throws {
        let store = ScanStore()
        store.pendingTrashReviewPlan = TrashReviewPlan(candidates: [candidate("manual")])
        let item = try #require(store.pendingTrashReviewPlan?.items.first)
        store.removePendingTrashReviewItem(item)
        #expect(store.pendingTrashReviewPlan == nil)
    }

    @Test("Review excludes disappeared batch targets and reports their paths")
    func batchReviewExcludesMissingTargets() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("trash-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let liveURL = rootURL.appendingPathComponent("live.bin")
        try Data(repeating: 0x41, count: 1024).write(to: liveURL)
        let missingURL = rootURL.appendingPathComponent("missing.bin")
        let live = candidate(at: liveURL)
        let missing = candidate(at: missingURL)
        let store = storeWithScan(rootURL: rootURL, candidates: [live, missing])
        store.selectedCleanupCandidateIDs = [live.id, missing.id]

        store.moveSelectedCleanupCandidatesToTrash()

        let plan = try #require(store.pendingTrashReviewPlan)
        #expect(plan.items.map(\.storageItemID) == [live.item.id])
        #expect(plan.missingPaths == [missingURL.standardizedFileURL])
        #expect(store.errorMessage?.contains("Rescan") == true)
    }

    @Test("Review of a disappeared single target leaves no actionable sheet")
    func singleReviewRejectsMissingTarget() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("trash-review-\(UUID().uuidString)", isDirectory: true)
        let missingURL = rootURL.appendingPathComponent("missing.bin")
        let missing = candidate(at: missingURL)
        let store = storeWithScan(rootURL: rootURL, candidates: [missing])
        store.selectedItemID = missing.item.id

        store.moveSelectedItemToTrash()

        #expect(store.pendingTrashReviewPlan == nil)
        #expect(store.errorMessage?.contains("no longer on disk") == true)
    }

    private func candidate(at url: URL) -> CleanupCandidate {
        let item = StorageItem(url: url, kind: .file,
                               byteSize: 1024, allocatedSize: 1024, modifiedAt: .now,
                               immediateChildCount: 0, descendantCount: 0, isReadable: true)
        return CleanupCandidate(kind: .general, item: item, reason: "Review target",
                                reclaimableBytes: 1024, confidence: .review)
    }

    private func storeWithScan(rootURL: URL, candidates: [CleanupCandidate]) -> ScanStore {
        let store = ScanStore()
        let children = candidates.map(\.item)
        let root = StorageItem(url: rootURL, kind: .folder, byteSize: 2048, allocatedSize: 2048,
                               modifiedAt: .now, immediateChildCount: children.count,
                               descendantCount: children.count, children: children, isReadable: true)
        store.scan = StorageScan(rootURL: rootURL, startedAt: .now, finishedAt: .now,
                                 rootItem: root, retainedItems: root.flattened(),
                                 scannedItemCount: children.count + 1, inaccessibleItemCount: 0,
                                 totalBytes: root.byteSize, largestFiles: children,
                                 largestFolders: [], oldLargeFiles: [], typeBreakdown: [],
                                 duplicateSizeGroups: [], verifiedDuplicateGroups: [],
                                 cleanupCandidates: candidates)
        return store
    }

    private func candidate(_ name: String) -> CleanupCandidate {
        let item = StorageItem(
            url: URL(fileURLWithPath: "/fixture/\(name)"), kind: .file,
            byteSize: 1024, allocatedSize: 1024, modifiedAt: nil,
            immediateChildCount: 0, descendantCount: 0, isReadable: true
        )
        return CleanupCandidate(kind: .general, item: item, reason: "Manually selected", reclaimableBytes: 1024, confidence: .review)
    }
}
