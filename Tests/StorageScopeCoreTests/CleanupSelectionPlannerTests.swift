import Foundation
import Testing
@testable import StorageScopeCore

@Suite("CleanupSelectionPlanner")
struct CleanupSelectionPlannerTests {
    // MARK: - Nested collapse under unusual tree shapes

    @Test("collapses deeply nested chain to single top-level ancestor")
    func collapsesDeeplyNestedChainToSingleTopLevelAncestor() throws {
        let root = URL(fileURLWithPath: "/Volumes/A/Projects/a/b/c/d/e")

        let ancestor = candidate(url: root, bytes: 1_000, kind: .cacheFolder)
        let childA = candidate(url: root.appendingPathComponent("package.bin"), bytes: 100)
        let childB = candidate(url: root.appendingPathComponent("nested").appendingPathComponent("nested.bin"), bytes: 50)
        let deepest = candidate(
            url: root.appendingPathComponent("nested").appendingPathComponent("deep").appendingPathComponent("deepest.bin"),
            bytes: 10
        )

        let planned = CleanupSelectionPlanner.topLevelCandidates([childA, deepest, childB, ancestor])

        let plannedIDs: [String] = planned.map(\.id)
        #expect(plannedIDs == [ancestor.id])
    }

    @Test("keeps every sibling when none is an ancestor of another")
    func keepsEverySiblingWhenNoneIsAncestor() throws {
        let parent = URL(fileURLWithPath: "/Volumes/A/Projects")
        let sibling1 = candidate(url: parent.appendingPathComponent("build-1.bin"), bytes: 100)
        let sibling2 = candidate(url: parent.appendingPathComponent("build-2.bin"), bytes: 100)
        let sibling3 = candidate(url: parent.appendingPathComponent("build-3.bin"), bytes: 100)

        let planned = CleanupSelectionPlanner.topLevelCandidates(Array([sibling1, sibling2, sibling3].shuffled()))

        let plannedIDs: Set<String> = Set(planned.map(\.id))
        #expect(plannedIDs == Set<String>([sibling1.id, sibling2.id, sibling3.id]))
        #expect(planned.count == 3)
    }

    @Test("collapses when only the leaf appears without its parent")
    func collapsesWhenOnlyLeafAppearsWithoutParent() {
        // Leaf vs. a sibling-descendant: a sibling whose name is a leading
        // prefix of another must NOT be flagged as an ancestor.
        let earliest = URL(fileURLWithPath: "/Volumes/A/cache.db")
        let sibling = URL(fileURLWithPath: "/Volumes/A/cache.db.wal")

        let earliestCandidate = candidate(url: earliest, bytes: 100)
        let siblingCandidate = candidate(url: sibling, bytes: 10)

        let planned = CleanupSelectionPlanner.topLevelCandidates([siblingCandidate, earliestCandidate])

        let plannedIDs: Set<String> = Set(planned.map(\.id))
        #expect(plannedIDs == Set<String>([earliestCandidate.id, siblingCandidate.id]))
        #expect(planned.count == 2)
    }

    @Test("treats root slash as ancestor of every non-root path")
    func treatsRootSlashAsAncestorOfEveryNonRootPath() {
        let root = candidate(url: URL(fileURLWithPath: "/"), bytes: 1_000_000, kind: .cacheFolder)
        let nested = candidate(url: URL(fileURLWithPath: "/Users/x/file.bin"), bytes: 1)

        let plannedA = CleanupSelectionPlanner.topLevelCandidates([nested, root])
        let plannedB = CleanupSelectionPlanner.topLevelCandidates([root, nested])

        let plannedAIDs: [String] = plannedA.map(\.id)
        let plannedBIDs: [String] = plannedB.map(\.id)
        #expect(plannedAIDs == [root.id])
        #expect(plannedBIDs == [root.id])
    }

    @Test("does not flag sibling whose name is a path prefix of another")
    func doesNotFlagSiblingWithPrefixName() {
        // "/x/foo" is not an ancestor of "/x/foobar.bin" — sibling prefix must
        // be distinguished from path-component boundary.
        let prefixSibling = candidate(url: URL(fileURLWithPath: "/x/foo"), bytes: 10)
        let longSibling = candidate(url: URL(fileURLWithPath: "/x/foobar.bin"), bytes: 10)

        let planned = CleanupSelectionPlanner.topLevelCandidates([prefixSibling, longSibling])

        let plannedIDs: Set<String> = Set(planned.map(\.id))
        #expect(plannedIDs == Set<String>([prefixSibling.id, longSibling.id]))
        #expect(planned.count == 2)
    }

    @Test("deduplicates identical paths keeping first occurrence")
    func deduplicatesIdenticalPathsKeepingFirstOccurrence() {
        let url = URL(fileURLWithPath: "/Volumes/A/dup.bin")
        let first = candidate(url: url, bytes: 10)
        let second = candidate(url: url, bytes: 10)

        let planned = CleanupSelectionPlanner.topLevelCandidates([first, second])

        let plannedIDs: [String] = planned.map(\.id)
        #expect(plannedIDs == [first.id])
    }

    @Test("topLevelURLs collapses nested URLs in input order")
    func topLevelURLsCollapsesNestedURLsInInputOrder() {
        let cache = URL(fileURLWithPath: "/Volumes/A/Caches")
        let installer = cache.appendingPathComponent("installer.dmg")

        let planned = CleanupSelectionPlanner.topLevelURLs([installer, cache])

        let plannedPaths: [String] = planned.map(\.path)
        #expect(plannedPaths == [cache.path])
    }

    @Test("topLevelURLs dedupes while preserving first-seen order")
    func topLevelURLsDedupesWhilePreservingOrder() {
        let a = URL(fileURLWithPath: "/Volumes/A/file.bin")
        let b = URL(fileURLWithPath: "/Volumes/A/other.bin")

        let planned = CleanupSelectionPlanner.topLevelURLs([a, b, a, b, a])

        let plannedPaths: [String] = planned.map(\.path)
        #expect(plannedPaths == [a.path, b.path])
    }

    // MARK: - Large-selection correctness

    @Test("handles thousands of unique peers without dropping or duplicating")
    func handlesThousandsOfUniquePeersWithoutLoss() {
        let largeCount = 5_000
        let candidates: [CleanupCandidate] = (0..<largeCount).map { index in
            candidate(
                url: URL(fileURLWithPath: "/Volumes/A/peer-\(index).bin"),
                bytes: Int64(index % 100)
            )
        }

        let planned = CleanupSelectionPlanner.topLevelCandidates(candidates)

        #expect(planned.count == largeCount)
        let plannedIDs: Set<String> = Set(planned.map(\.id))
        #expect(plannedIDs.count == largeCount)
    }

    @Test("collapses one ancestor with thousands of descendants to a single result")
    func collapsesOneAncestorWithThousandsOfDescendantsToSingleResult() {
        let ancestorURL = URL(fileURLWithPath: "/Volumes/A/Parent")
        let ancestor = candidate(url: ancestorURL, bytes: 100_000, kind: .cacheFolder)
        let descendants: [CleanupCandidate] = (0..<5_000).map { index in
            candidate(
                url: ancestorURL.appendingPathComponent("child-\(index).bin"),
                bytes: Int64(index % 50)
            )
        }
        let input = descendants + [ancestor]

        let planned = CleanupSelectionPlanner.topLevelCandidates(input)

        let plannedIDs: [String] = planned.map(\.id)
        #expect(plannedIDs == [ancestor.id])
    }

    @Test("collapses two competing root trees keeping each root")
    func collapsesTwoCompetingRootTreesKeepingEachRoot() {
        let rootA = URL(fileURLWithPath: "/Volumes/A")
        let rootB = URL(fileURLWithPath: "/Volumes/B")
        let rootACandidate = candidate(url: rootA, bytes: 1_000_000, kind: .cacheFolder)
        let rootBCandidate = candidate(url: rootB, bytes: 1_000_000, kind: .cacheFolder)
        let aChild = candidate(url: rootA.appendingPathComponent("nested.bin"), bytes: 10)
        let bChild = candidate(url: rootB.appendingPathComponent("nested.bin"), bytes: 10)

        let planned = CleanupSelectionPlanner.topLevelCandidates(Array([aChild, bChild, rootACandidate, rootBCandidate].shuffled()))

        let plannedIDs: Set<String> = Set(planned.map(\.id))
        #expect(plannedIDs == Set<String>([rootACandidate.id, rootBCandidate.id]))
    }

    @Test("large fan-out: each top-level keeps its peer-shape under heavy nesting")
    func largeFanOutEachTopLevelKeepsPeerShapeUnderHeavyNesting() {
        // 200 top-level peers, each with 10 nested descendants → 2200 inputs,
        // 200 expected top-level survivors.
        let candidates: [CleanupCandidate] = (0..<200).flatMap { parentIndex in
            let parent = URL(fileURLWithPath: "/Volumes/A/peer-\(parentIndex)")
            let parentCandidate = candidate(url: parent, bytes: 1_000, kind: .cacheFolder)
            let children: [CleanupCandidate] = (0..<10).map { childIndex in
                candidate(
                    url: parent.appendingPathComponent("child-\(childIndex).bin"),
                    bytes: Int64(childIndex)
                )
            }
            return [parentCandidate] + children
        }

        let planned = CleanupSelectionPlanner.topLevelCandidates(candidates.shuffled())

        #expect(planned.count == 200)
        let plannedIDs: Set<String> = Set(planned.map(\.id))
        #expect(plannedIDs.count == 200)
    }

    // MARK: - Missing-path reporting

    @Test("selectTopLevel collects missing URLs in input order")
    func selectTopLevelCollectsMissingURLsInInputOrder() {
        let liveA = candidate(url: URL(fileURLWithPath: "/x/live-a.bin"), bytes: 10)
        let missingB = candidate(url: URL(fileURLWithPath: "/x/missing-b.bin"), bytes: 10)
        let missingC = candidate(url: URL(fileURLWithPath: "/x/missing-c.bin"), bytes: 10)
        let liveD = candidate(url: URL(fileURLWithPath: "/x/live-d.bin"), bytes: 10)

        let liveSet = Set<String>([
            URL(fileURLWithPath: "/x/live-a.bin").standardizedFileURL.path,
            URL(fileURLWithPath: "/x/live-d.bin").standardizedFileURL.path
        ])
        let selection = CleanupSelectionPlanner.selectTopLevel(
            [liveA, missingB, missingC, liveD],
            fileExists: { url in liveSet.contains(url.path) }
        )

        let missingPaths: [String] = selection.missingPaths.map(\.path)
        #expect(missingPaths == [
            URL(fileURLWithPath: "/x/missing-b.bin").standardizedFileURL.path,
            URL(fileURLWithPath: "/x/missing-c.bin").standardizedFileURL.path
        ])
        let keptIDs: Set<String> = Set(selection.candidates.map(\.id))
        #expect(keptIDs == Set<String>([liveA.id, liveD.id]))
    }

    @Test("selectTopLevel collapses nested kept peers after excluding missing")
    func selectTopLevelCollapsesNestedKeptPeersAfterExcludingMissing() {
        let parent = URL(fileURLWithPath: "/x/Caches")
        let child = parent.appendingPathComponent("installer.dmg")
        let parentCandidate = candidate(url: parent, bytes: 1_000, kind: .cacheFolder)
        let childCandidate = candidate(url: child, bytes: 10)
        let missingURL = URL(fileURLWithPath: "/x/missing.bin")
        let missing = candidate(url: missingURL, bytes: 5)

        let selection = CleanupSelectionPlanner.selectTopLevel(
            [parentCandidate, childCandidate, missing],
            fileExists: { url in
                url.standardizedFileURL.path != missingURL.standardizedFileURL.path
            }
        )

        let keptIDs: [String] = selection.candidates.map(\.id)
        let missingPaths: [String] = selection.missingPaths.map(\.path)
        #expect(keptIDs == [parentCandidate.id])
        #expect(missingPaths == [missingURL.standardizedFileURL.path])
    }

    // MARK: - ReclaimPlan missing-path surfacing

    @Test("reclaim plan surfaces missing paths when probed")
    func reclaimPlanSurfacesMissingPathsWhenProbed() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let liveVerified = candidate(
            url: temporaryRoot.appendingPathComponent("copy-a.mov"),
            bytes: 8_000,
            kind: .verifiedDuplicate,
            confidence: .high
        )
        let missingInstaller = candidate(
            url: URL(fileURLWithPath: "/Volumes/A/missing/installer.pkg"),
            bytes: 6_000,
            kind: .installer,
            confidence: .medium
        )
        let scan = storageScan(
            rootURL: temporaryRoot,
            scannedItemCount: 24,
            inaccessibleItemCount: 0,
            totalBytes: 100_000,
            cleanupCandidates: [liveVerified, missingInstaller]
        )

        let livePath = liveVerified.item.url.standardizedFileURL.path
        let missingPath = missingInstaller.item.url.standardizedFileURL.path
        let plan = ReclaimPlanBuilder.build(
            scan: scan,
            visibleCleanupCandidates: scan.cleanupCandidates,
            fileExists: { url in url.standardizedFileURL.path == livePath }
        )

        let sectionKinds: [ReclaimPlanSection.Kind] = plan.sections.map(\.kind)
        #expect(sectionKinds == [.verifiedDuplicates])
        #expect(plan.sections.first { $0.kind == .verifiedDuplicates }?.itemCount == 1)
        let missingPaths: [String] = plan.missingPaths.map(\.path)
        #expect(missingPaths == [missingPath])
    }

    @Test("reclaim plan without probe behaves like the legacy entry point")
    func reclaimPlanWithoutProbeBehavesLikeLegacyEntryPoint() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let verified = candidate(
            url: temporaryRoot.appendingPathComponent("copy-a.mov"),
            bytes: 8_000,
            kind: .verifiedDuplicate,
            confidence: .high
        )
        let installer = candidate(
            url: temporaryRoot.appendingPathComponent("installer.pkg"),
            bytes: 6_000,
            kind: .installer,
            confidence: .medium
        )
        let scan = storageScan(
            rootURL: temporaryRoot,
            scannedItemCount: 24,
            inaccessibleItemCount: 0,
            totalBytes: 100_000,
            cleanupCandidates: [verified, installer]
        )

        let plan = ReclaimPlanBuilder.build(scan: scan, visibleCleanupCandidates: scan.cleanupCandidates)

        #expect(plan.missingPaths.isEmpty)
        let sectionKinds: [ReclaimPlanSection.Kind] = plan.sections.map(\.kind)
        #expect(sectionKinds == [.verifiedDuplicates, .reviewSuggestions])
    }

    // MARK: - TrashReviewPlan missing-path surfacing

    @Test("trash review plan excludes missing paths and surfaces them")
    func trashReviewPlanExcludesMissingPathsAndSurfacesThem() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let live = candidate(
            url: temporaryRoot.appendingPathComponent("copy-a.mov"),
            bytes: 8_000,
            kind: .verifiedDuplicate,
            confidence: .high
        )
        let missing = candidate(
            url: URL(fileURLWithPath: "/Volumes/A/missing/installer.dmg"),
            bytes: 4_000,
            kind: .diskImage,
            confidence: .medium
        )

        let livePath = live.item.url.standardizedFileURL.path
        let plan = TrashReviewPlan(
            candidates: [live, missing],
            fileExists: { url in url.standardizedFileURL.path == livePath }
        )

        let keptIDs: [String] = plan.items.map(\.id)
        let missingPaths: [String] = plan.missingPaths.map(\.path)
        #expect(keptIDs == [live.id])
        #expect(missingPaths == [missing.item.url.standardizedFileURL.path])
    }

    @Test("trash review plan without probe keeps legacy behavior")
    func trashReviewPlanWithoutProbeKeepsLegacyBehavior() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let live = candidate(
            url: temporaryRoot.appendingPathComponent("copy-a.mov"),
            bytes: 8_000,
            kind: .verifiedDuplicate,
            confidence: .high
        )
        let other = candidate(
            url: temporaryRoot.appendingPathComponent("installer.dmg"),
            bytes: 4_000,
            kind: .diskImage,
            confidence: .medium
        )

        let plan = TrashReviewPlan(candidates: [live, other])

        let keptIDs: [String] = plan.items.map(\.id)
        #expect(plan.missingPaths.isEmpty)
        #expect(Set(keptIDs) == Set<String>([live.id, other.id]))
    }

    // MARK: - Helpers

    private func makeTemporaryRoot() throws -> URL {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageScopePlannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        return temporaryRoot
    }

    private func candidate(
        url: URL,
        bytes: Int64,
        kind: CleanupCandidate.Kind = .oldLargeFile,
        confidence: CleanupCandidate.Confidence = .medium
    ) -> CleanupCandidate {
        CleanupCandidate(
            kind: kind,
            item: StorageItem(
                url: url,
                kind: kind == .cacheFolder || kind == .buildArtifact ? .folder : .file,
                byteSize: bytes,
                allocatedSize: bytes,
                modifiedAt: nil,
                immediateChildCount: 0,
                descendantCount: 0,
                isReadable: true,
                fileExtension: url.pathExtension.isEmpty ? nil : url.pathExtension
            ),
            reason: "Test cleanup target.",
            reclaimableBytes: bytes,
            confidence: confidence
        )
    }

    private func storageScan(
        rootURL: URL,
        scannedItemCount: Int,
        inaccessibleItemCount: Int,
        totalBytes: Int64,
        cleanupCandidates: [CleanupCandidate]
    ) -> StorageScan {
        let rootItem = StorageItem(
            url: rootURL,
            kind: .folder,
            byteSize: totalBytes,
            allocatedSize: totalBytes,
            modifiedAt: nil,
            immediateChildCount: 0,
            descendantCount: max(0, scannedItemCount - 1),
            isReadable: true
        )
        return StorageScan(
            rootURL: rootURL,
            startedAt: Date(),
            finishedAt: Date(),
            rootItem: rootItem,
            retainedItems: [rootItem],
            scannedItemCount: scannedItemCount,
            inaccessibleItemCount: inaccessibleItemCount,
            totalBytes: totalBytes,
            largestFiles: [],
            largestFolders: [],
            oldLargeFiles: [],
            typeBreakdown: [],
            duplicateSizeGroups: [],
            verifiedDuplicateGroups: [],
            cleanupCandidates: cleanupCandidates
        )
    }
}