import Foundation
import Testing
@testable import StorageScopeCore

@Suite("FileSystemScanner")
struct FileSystemScannerTests {
    @Test("ranks largest files and folders")
    func scanRanksLargestFilesAndFolders() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let media = temporaryRoot.appendingPathComponent("Media", isDirectory: true)
        let cache = temporaryRoot.appendingPathComponent("Cache", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        try writeFile(named: "video.mov", bytes: 10_000, in: media)
        try writeFile(named: "image.raw", bytes: 4_000, in: media)
        try writeFile(named: "scratch.bin", bytes: 2_000, in: cache)

        let scan = try FileSystemScanner().scan(root: temporaryRoot, options: ScanOptions(largeFileThreshold: 1_000, duplicateCandidateThreshold: 1_000))

        #expect(scan.rootItem.immediateChildCount == 2)
        #expect(scan.largestFiles.first?.name == "video.mov")
        #expect(scan.largestFolders.first?.name == "Media")
        #expect(scan.typeBreakdown.first?.label == ".mov")
        #expect(scan.typeBreakdown.first?.category == .video)
        #expect(scan.totalBytes >= 16_000)
    }

    @Test("categorizes file type breakdown for scan review")
    func typeBreakdownIncludesStorageCategories() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try writeFile(named: "movie.mp4", bytes: 500_000, in: temporaryRoot)
        try writeFile(named: "clip.mp4", bytes: 10_000, in: temporaryRoot)
        try writeFile(named: "installer.pkg", bytes: 400_000, in: temporaryRoot)
        try writeFile(named: "source.swift", bytes: 300_000, in: temporaryRoot)
        try writeFile(named: "bundle.zip", bytes: 200_000, in: temporaryRoot)
        try writeFile(named: "notes.pdf", bytes: 100_000, in: temporaryRoot)
        try writeFile(named: "cache.sqlite", bytes: 90_000, in: temporaryRoot)
        try writeFile(named: "catalog.db", bytes: 80_000, in: temporaryRoot)
        try writeFile(named: "display.woff2", bytes: 70_000, in: temporaryRoot)
        try writeFile(named: "headline.ttf", bytes: 60_000, in: temporaryRoot)
        try writeFile(named: "linux.qcow2", bytes: 50_000, in: temporaryRoot)
        try writeFile(named: "windows.vmdk", bytes: 40_000, in: temporaryRoot)

        let scan = try FileSystemScanner().scan(root: temporaryRoot, options: ScanOptions(duplicateCandidateThreshold: 10_000))
        let categoriesByLabel = Dictionary(uniqueKeysWithValues: scan.typeBreakdown.map { ($0.label, $0.category) })
        let categoryStatsByCategory = Dictionary(uniqueKeysWithValues: scan.categoryBreakdown.map { ($0.category, $0) })

        #expect(categoriesByLabel[".mp4"] == .video)
        #expect(categoriesByLabel[".pkg"] == .installer)
        #expect(categoriesByLabel[".swift"] == .developer)
        #expect(categoriesByLabel[".zip"] == .archive)
        #expect(categoriesByLabel[".pdf"] == .document)
        #expect(categoriesByLabel[".sqlite"] == .database)
        #expect(categoriesByLabel[".db"] == .database)
        #expect(categoriesByLabel[".woff2"] == .font)
        #expect(categoriesByLabel[".ttf"] == .font)
        #expect(categoriesByLabel[".qcow2"] == .virtualMachine)
        #expect(categoriesByLabel[".vmdk"] == .virtualMachine)
        #expect(scan.categoryBreakdown.map(\.category) == [.video, .installer, .developer, .archive, .database, .font, .document, .virtualMachine])
        #expect(scan.typeBreakdown.first { $0.label == ".mp4" }?.fileCountLabel == "2 files")
        #expect(scan.typeBreakdown.first { $0.label == ".pkg" }?.fileCountLabel == "1 file")
        #expect(scan.categoryBreakdown.first?.extensionCount == 1)
        #expect(scan.categoryBreakdown.first?.extensionCountLabel == "1 type")
        #expect(scan.categoryBreakdown.first?.fileCountLabel == "2 files")
        #expect(categoryStatsByCategory[.database]?.extensionCount == 2)
        #expect(categoryStatsByCategory[.database]?.extensionCountLabel == "2 types")
        #expect(categoryStatsByCategory[.database]?.fileCount == 2)
        #expect(categoryStatsByCategory[.database]?.fileCountLabel == "2 files")
        #expect(categoryStatsByCategory[.font]?.extensionCount == 2)
        #expect(categoryStatsByCategory[.font]?.fileCount == 2)
        #expect(categoryStatsByCategory[.virtualMachine]?.extensionCount == 2)
        #expect(categoryStatsByCategory[.virtualMachine]?.fileCount == 2)
        #expect(scan.categoryBreakdown.reduce(0) { $0 + $1.fileCount } == 12)
    }

    @Test("groups same-sized files as duplicate candidates")
    func duplicateSizeCandidatesGroupSameSizedFiles() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try writeFile(named: "a.dat", bytes: 2_048, in: temporaryRoot)
        try writeFile(named: "b.dat", bytes: 2_048, in: temporaryRoot)
        try writeFile(named: "c.dat", bytes: 1_024, in: temporaryRoot)

        let scan = try FileSystemScanner().scan(root: temporaryRoot, options: ScanOptions(duplicateCandidateThreshold: 1_000))

        #expect(scan.duplicateSizeGroups.count == 1)
        #expect(scan.duplicateSizeGroups.first?.items.map(\.name).sorted() == ["a.dat", "b.dat"])
        #expect(scan.duplicateCandidateItemLimit == 5_000)
        #expect(scan.duplicateCandidateItemsRetained == 3)
        #expect(scan.duplicateCandidateItemsConsidered == 3)
        #expect(!scan.duplicateCandidateLimitReached)
    }

    @Test("verifies duplicate files by content hash")
    func verifiedDuplicateGroupsRequireMatchingContent() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try Data("same-content".utf8).write(to: temporaryRoot.appendingPathComponent("copy-a.txt"))
        try Data("same-content".utf8).write(to: temporaryRoot.appendingPathComponent("copy-b.txt"))
        try Data("different!!".utf8).write(to: temporaryRoot.appendingPathComponent("same-size-different.txt"))

        var progressPaths: [String] = []
        let scan = try FileSystemScanner().scan(
            root: temporaryRoot,
            options: ScanOptions(duplicateCandidateThreshold: 1),
            progress: { progressPaths.append($0.currentPath) }
        )

        #expect(scan.duplicateSizeGroups.count == 1)
        #expect(scan.verifiedDuplicateGroups.count == 1)
        #expect(scan.verifiedDuplicateGroups.first?.items.map(\.name).sorted() == ["copy-a.txt", "copy-b.txt"])
        #expect(scan.cleanupCandidates.contains { $0.kind == .verifiedDuplicate && $0.confidence == .high })
        #expect(progressPaths.contains { $0.contains("Verifying duplicates") })
        #expect(DuplicateReviewPlanner.unverifiedSizeGroups(
            sizeGroups: scan.duplicateSizeGroups,
            verifiedGroups: scan.verifiedDuplicateGroups
        ).isEmpty)
    }

    @Test("caps automatic duplicate content verification")
    func duplicateVerificationHonorsByteBudget() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try Data("same-content".utf8).write(to: temporaryRoot.appendingPathComponent("copy-a.txt"))
        try Data("same-content".utf8).write(to: temporaryRoot.appendingPathComponent("copy-b.txt"))

        let scan = try FileSystemScanner().scan(
            root: temporaryRoot,
            options: ScanOptions(
                duplicateCandidateThreshold: 1,
                duplicateVerificationByteLimit: 8
            )
        )

        #expect(scan.duplicateSizeGroups.count == 1)
        #expect(scan.verifiedDuplicateGroups.isEmpty)
    }

    @Test("surfaces cleanup candidates for cache folders, installers, and compressed archives")
    func cleanupCandidatesIncludeStorageReviewTargets() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let cache = temporaryRoot.appendingPathComponent("Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try writeFile(named: "blob.bin", bytes: 2_048, in: cache)
        try writeFile(named: "installer.dmg", bytes: 3_072, in: temporaryRoot)
        try writeFile(named: "source-drop.tgz", bytes: 1_536, in: temporaryRoot)
        try writeFile(named: "container.tar.zst", bytes: 1_024, in: temporaryRoot)

        let scan = try FileSystemScanner().scan(root: temporaryRoot, options: ScanOptions(duplicateCandidateThreshold: 1))

        #expect(scan.cleanupCandidates.contains { $0.kind == .cacheFolder && $0.item.name == "Caches" })
        #expect(scan.cleanupCandidates.contains { $0.kind == .diskImage && $0.item.name == "installer.dmg" })
        #expect(scan.cleanupCandidates.contains { $0.kind == .archive && $0.item.name == "source-drop.tgz" })
        #expect(scan.cleanupCandidates.contains { $0.kind == .archive && $0.item.name == "container.tar.zst" })
    }

    @Test("skips hidden files by default")
    func hiddenFilesAreSkippedByDefault() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try writeFile(named: ".hidden", bytes: 4_096, in: temporaryRoot)
        try writeFile(named: "visible.txt", bytes: 1_024, in: temporaryRoot)

        let hiddenOff = try FileSystemScanner().scan(root: temporaryRoot, options: ScanOptions(includeHidden: false))
        let hiddenOn = try FileSystemScanner().scan(root: temporaryRoot, options: ScanOptions(includeHidden: true))

        #expect(!hiddenOff.allItems.contains { $0.name == ".hidden" })
        #expect(hiddenOn.allItems.contains { $0.name == ".hidden" })
    }

    @Test("limits retained tree while preserving full scan summaries")
    func retentionBudgetDoesNotLimitScanSummaries() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        for index in 0..<30 {
            try writeFile(named: String(format: "sample-%02d.dat", index), bytes: 10_000 + (index * 10_000), in: temporaryRoot)
        }

        let scan = try FileSystemScanner().scan(
            root: temporaryRoot,
            options: ScanOptions(
                duplicateCandidateThreshold: 10_000,
                maxRankedResults: 5,
                maxChildrenPerDirectory: 3,
                maxRetainedItems: 4
            )
        )

        #expect(scan.scannedItemCount == 31)
        #expect(scan.rootItem.immediateChildCount == 30)
        #expect(scan.rootItem.descendantCount == 30)
        #expect(scan.rootItem.children.count == 3)
        #expect(scan.allItems.count == 4)
        #expect(scan.largestFiles.count == 5)
        #expect(scan.largestFiles.first?.name == "sample-29.dat")
        #expect(scan.typeBreakdown.first?.fileCount == 30)
    }

    @Test("flattened retained tree preserves preorder without changing counts")
    func flattenedRetainedTreePreservesPreorder() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let leafA = storageItem(url: temporaryRoot.appendingPathComponent("A/a.mov"), name: "a.mov")
        let leafB = storageItem(url: temporaryRoot.appendingPathComponent("A/b.mov"), name: "b.mov")
        let folderA = storageItem(
            url: temporaryRoot.appendingPathComponent("A", isDirectory: true),
            name: "A",
            kind: .folder,
            children: [leafA, leafB]
        )
        let leafC = storageItem(url: temporaryRoot.appendingPathComponent("c.mov"), name: "c.mov")
        let root = storageItem(
            url: temporaryRoot,
            name: "Root",
            kind: .folder,
            children: [folderA, leafC]
        )

        let flattened = root.flattened()

        #expect(flattened.map(\.name) == ["Root", "A", "a.mov", "b.mov", "c.mov"])
        #expect(flattened.count == root.retainedItemCount)
    }

    @Test("retained tree search matches direct paths and descendants")
    func retainedTreeSearchMatchesPathsAndDescendants() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let nestedMatch = storageItem(
            url: temporaryRoot.appendingPathComponent("Media/Exports/final-cut.mov"),
            name: "final-cut.mov"
        )
        let exports = storageItem(
            url: temporaryRoot.appendingPathComponent("Media/Exports", isDirectory: true),
            name: "Exports",
            kind: .folder,
            children: [nestedMatch]
        )
        let media = storageItem(
            url: temporaryRoot.appendingPathComponent("Media", isDirectory: true),
            name: "Media",
            kind: .folder,
            children: [exports]
        )
        let notes = storageItem(url: temporaryRoot.appendingPathComponent("notes.txt"), name: "notes.txt")

        #expect(nestedMatch.matchesSearchQuery("FINAL-CUT"))
        #expect(nestedMatch.matchesSearchQuery("Exports/final-cut.mov"))
        #expect(media.retainedTreeContainsSearchMatch("final-cut"))
        #expect(!notes.retainedTreeContainsSearchMatch("final-cut"))
        #expect(media.retainedTreeContainsSearchMatch("   "))
    }

    @Test("keeps directory child retention bounded during wide scans")
    func wideDirectoryScanRetainsOnlyLargestChildren() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        for index in 0..<120 {
            try writeFile(named: String(format: "wide-%04d.dat", index), bytes: 8_192 * (index + 1), in: temporaryRoot)
        }

        let scan = try FileSystemScanner().scan(
            root: temporaryRoot,
            options: ScanOptions(
                duplicateCandidateThreshold: 10_000,
                maxRankedResults: 8,
                maxChildrenPerDirectory: 5,
                maxRetainedItems: 6
            )
        )

        #expect(scan.scannedItemCount == 121)
        #expect(scan.rootItem.immediateChildCount == 120)
        #expect(scan.rootItem.children.count == 5)
        #expect(scan.allItems.count == 6)
        #expect(scan.rootItem.children.first?.name == "wide-0119.dat")
        #expect(Array(scan.largestFiles.map(\.name).prefix(3)) == ["wide-0119.dat", "wide-0118.dat", "wide-0117.dat"])
    }

    @Test("caps duplicate candidate retention for full-drive-sized scans")
    func duplicateCandidateRetentionIsBounded() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        for index in 0..<80 {
            try writeFile(named: String(format: "duplicate-%03d.bin", index), bytes: 2_048, in: temporaryRoot)
        }

        let scan = try FileSystemScanner().scan(
            root: temporaryRoot,
            options: ScanOptions(
                duplicateCandidateThreshold: 1_000,
                duplicateVerificationByteLimit: 0,
                maxDuplicateCandidateItems: 12
            )
        )

        #expect(scan.scannedItemCount == 81)
        #expect(scan.duplicateSizeGroups.count == 1)
        #expect(scan.duplicateSizeGroups.first?.items.count == 12)
        #expect(scan.duplicateCandidateItemLimit == 12)
        #expect(scan.duplicateCandidateItemsRetained == 12)
        #expect(scan.duplicateCandidateItemsConsidered == 80)
        #expect(scan.duplicateCandidateLimitReached)
    }

    @Test("duplicate candidate cap keeps later larger files")
    func duplicateCandidateCapKeepsLaterLargerFiles() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        for index in 0..<12 {
            try writeFile(named: String(format: "filler-%03d.bin", index), bytes: 2_048, in: temporaryRoot)
        }
        try writeFile(named: "large-a.bin", bytes: 8_192, in: temporaryRoot)
        try writeFile(named: "large-b.bin", bytes: 8_192, in: temporaryRoot)

        let scan = try FileSystemScanner().scan(
            root: temporaryRoot,
            options: ScanOptions(
                duplicateCandidateThreshold: 1_000,
                duplicateVerificationByteLimit: 0,
                maxDuplicateCandidateItems: 12
            )
        )

        let retainedCandidateCount = scan.duplicateSizeGroups.reduce(0) { $0 + $1.items.count }
        let largeGroup = scan.duplicateSizeGroups.first { $0.byteSize == 8_192 }

        #expect(retainedCandidateCount == 12)
        #expect(largeGroup?.items.map(\.name).sorted() == ["large-a.bin", "large-b.bin"])
        #expect(scan.duplicateCandidateItemLimit == 12)
        #expect(scan.duplicateCandidateItemsRetained == 12)
        #expect(scan.duplicateCandidateItemsConsidered == 14)
        #expect(scan.duplicateCandidateLimitReached)
    }

    @Test("duplicate candidate cap skips later smaller files")
    func duplicateCandidateCapSkipsLaterSmallerFiles() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        for index in 0..<12 {
            try writeFile(named: String(format: "large-%03d.bin", index), bytes: 8_192, in: temporaryRoot)
        }
        try writeFile(named: "small-a.bin", bytes: 2_048, in: temporaryRoot)
        try writeFile(named: "small-b.bin", bytes: 2_048, in: temporaryRoot)

        let scan = try FileSystemScanner().scan(
            root: temporaryRoot,
            options: ScanOptions(
                duplicateCandidateThreshold: 1_000,
                duplicateVerificationByteLimit: 0,
                maxDuplicateCandidateItems: 12
            )
        )

        let retainedCandidateCount = scan.duplicateSizeGroups.reduce(0) { $0 + $1.items.count }

        #expect(retainedCandidateCount == 12)
        #expect(scan.duplicateSizeGroups.contains { $0.byteSize == 8_192 && $0.items.count == 12 })
        #expect(!scan.duplicateSizeGroups.contains { $0.byteSize == 2_048 })
        #expect(scan.duplicateCandidateItemLimit == 12)
        #expect(scan.duplicateCandidateItemsRetained == 12)
        #expect(scan.duplicateCandidateItemsConsidered == 14)
        #expect(scan.duplicateCandidateLimitReached)
    }

    @Test("duplicate candidates include files pruned from retained tree")
    func duplicateCandidatesSurviveRetainedTreePruning() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try writeFile(named: "duplicate-a.bin", bytes: 2_048, in: temporaryRoot)
        try writeFile(named: "duplicate-b.bin", bytes: 2_048, in: temporaryRoot)
        try writeFile(named: "larger.bin", bytes: 4_096, in: temporaryRoot)

        let scan = try FileSystemScanner().scan(
            root: temporaryRoot,
            options: ScanOptions(
                duplicateCandidateThreshold: 1_000,
                maxChildrenPerDirectory: 1,
                maxRetainedItems: 2
            )
        )

        #expect(scan.rootItem.children.count == 1)
        #expect(scan.duplicateSizeGroups.count == 1)
        #expect(scan.duplicateSizeGroups.first?.items.map(\.name).sorted() == ["duplicate-a.bin", "duplicate-b.bin"])
    }

    @Test("batch trash rolls back items moved before a later failure")
    func batchTrashRollsBackEarlierMovesWhenLaterMoveFails() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let trashRoot = temporaryRoot.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
        let keep = temporaryRoot.appendingPathComponent("keep.dat")
        let blocked = temporaryRoot.appendingPathComponent("blocked.dat")
        try Data("keep".utf8).write(to: keep)
        try Data("blocked".utf8).write(to: blocked)

        let mover = TransactionalTrashMover(
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            trashItem: { source in
                if source.lastPathComponent == "blocked.dat" {
                    throw SimulatedMoveError.blocked
                }
                let destination = trashRoot.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.moveItem(at: source, to: destination)
                return destination
            },
            restoreItem: { try FileManager.default.moveItem(at: $0, to: $1) }
        )

        do {
            try mover.moveToTrash([keep, blocked])
            Issue.record("Expected batch trash to fail.")
        } catch BatchTrashError.rollbackSucceeded {
            #expect(FileManager.default.fileExists(atPath: keep.path))
            #expect(FileManager.default.fileExists(atPath: blocked.path))
            #expect(!FileManager.default.fileExists(atPath: trashRoot.appendingPathComponent("keep.dat").path))
        } catch {
            Issue.record("Expected rollbackSucceeded, got \(error).")
        }
    }

    @Test("batch trash preserves original failure when nothing moved")
    func batchTrashPreservesOriginalFailureWhenNothingMoved() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let blocked = temporaryRoot.appendingPathComponent("blocked.dat")
        try Data("blocked".utf8).write(to: blocked)

        let mover = TransactionalTrashMover(
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            trashItem: { _ in throw SimulatedMoveError.blocked },
            restoreItem: { _, _ in
                Issue.record("Rollback should not run when no item was moved.")
            }
        )

        do {
            try mover.moveToTrash([blocked])
            Issue.record("Expected batch trash to fail.")
        } catch SimulatedMoveError.blocked {
            #expect(FileManager.default.fileExists(atPath: blocked.path))
        } catch {
            Issue.record("Expected original blocked error, got \(error).")
        }
    }

    @Test("batch trash uses sandbox-aware trash operation for every item")
    func batchTrashUsesSandboxAwareTrashOperationForEveryItem() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let trashRoot = temporaryRoot.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)

        let fileA = temporaryRoot.appendingPathComponent("a.dat")
        let fileB = temporaryRoot.appendingPathComponent("b.dat")
        try Data("a".utf8).write(to: fileA)
        try Data("b".utf8).write(to: fileB)
        var trashedNames: [String] = []

        let mover = TransactionalTrashMover(
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            trashItem: { source in
                trashedNames.append(source.lastPathComponent)
                let destination = trashRoot.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.moveItem(at: source, to: destination)
                return destination
            },
            restoreItem: {
                try FileManager.default.moveItem(at: $0, to: $1)
            }
        )

        try mover.moveToTrash([fileA, fileB])

        #expect(!FileManager.default.fileExists(atPath: fileA.path))
        #expect(!FileManager.default.fileExists(atPath: fileB.path))
        #expect(FileManager.default.fileExists(atPath: trashRoot.appendingPathComponent("a.dat").path))
        #expect(FileManager.default.fileExists(atPath: trashRoot.appendingPathComponent("b.dat").path))
        #expect(trashedNames == ["a.dat", "b.dat"])
    }

    @Test("cleanup planner collapses nested selected targets")
    func cleanupPlannerCollapsesNestedSelectedTargets() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let cacheFolder = temporaryRoot.appendingPathComponent("Caches", isDirectory: true)
        let installer = cacheFolder.appendingPathComponent("installer.dmg")
        let cacheCandidate = cleanupCandidate(url: cacheFolder, kind: .cacheFolder, bytes: 10_000)
        let installerCandidate = cleanupCandidate(url: installer, kind: .diskImage, bytes: 4_000)

        let planned = CleanupSelectionPlanner.topLevelCandidates([installerCandidate, cacheCandidate])

        #expect(planned.map(\.id) == [cacheCandidate.id])
    }

    @Test("cleanup verified batch selects only high-confidence duplicate candidates")
    func cleanupVerifiedBatchSkipsReviewHeuristics() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let verifiedDuplicate = cleanupCandidate(
            url: temporaryRoot.appendingPathComponent("copy-a.mov"),
            kind: .verifiedDuplicate,
            bytes: 8_000,
            confidence: .high
        )
        let diskImage = cleanupCandidate(
            url: temporaryRoot.appendingPathComponent("installer.dmg"),
            kind: .diskImage,
            bytes: 6_000,
            confidence: .medium
        )
        let archive = cleanupCandidate(
            url: temporaryRoot.appendingPathComponent("archive.zip"),
            kind: .archive,
            bytes: 4_000,
            confidence: .review
        )

        let planned = CleanupSelectionPlanner.verifiedDuplicateBatchCandidates([verifiedDuplicate, diskImage, archive])

        #expect(planned.map(\.id) == [verifiedDuplicate.id])
    }

    @Test("cleanup planner flags batches that include review heuristics")
    func cleanupPlannerFlagsReviewRisk() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let verifiedDuplicate = cleanupCandidate(
            url: temporaryRoot.appendingPathComponent("copy-a.mov"),
            kind: .verifiedDuplicate,
            bytes: 8_000,
            confidence: .high
        )
        let installer = cleanupCandidate(
            url: temporaryRoot.appendingPathComponent("installer.pkg"),
            kind: .installer,
            bytes: 6_000,
            confidence: .medium
        )

        #expect(!CleanupSelectionPlanner.containsReviewRisk([verifiedDuplicate]))
        #expect(CleanupSelectionPlanner.containsReviewRisk([verifiedDuplicate, installer]))
    }

    @Test("scan option policy keeps broad analysis thresholds independent from display filters")
    func scanOptionPolicyIgnoresDisplayThresholds() {
        let thresholds = ScanOptionPolicy.interactiveScanThresholds(displayThreshold: 10_000_000_000)

        #expect(thresholds.largeFileThreshold == 1_000_000_000)
        #expect(thresholds.duplicateCandidateThreshold == 100_000_000)
    }

    @Test("reclaim plan separates verified reclaim from review suggestions")
    func reclaimPlanSeparatesConfidenceLanes() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let verifiedDuplicate = cleanupCandidate(
            url: temporaryRoot.appendingPathComponent("copy-a.mov"),
            kind: .verifiedDuplicate,
            bytes: 8_000,
            confidence: .high
        )
        let installer = cleanupCandidate(
            url: temporaryRoot.appendingPathComponent("installer.pkg"),
            kind: .installer,
            bytes: 6_000,
            confidence: .medium
        )
        let archive = cleanupCandidate(
            url: temporaryRoot.appendingPathComponent("archive.zip"),
            kind: .archive,
            bytes: 4_000,
            confidence: .review
        )
        let scan = storageScan(
            rootURL: temporaryRoot,
            scannedItemCount: 24,
            inaccessibleItemCount: 2,
            totalBytes: 100_000,
            cleanupCandidates: [verifiedDuplicate, installer, archive]
        )

        let plan = ReclaimPlanBuilder.build(scan: scan, visibleCleanupCandidates: scan.cleanupCandidates)

        #expect(plan.sections.map(\.kind) == [.verifiedDuplicates, .reviewSuggestions, .inaccessibleItems])
        #expect(plan.primaryAction == .reviewVerifiedDuplicates)
        #expect(plan.sections.first { $0.kind == .verifiedDuplicates }?.reclaimableBytes == 8_000)
        #expect(plan.sections.first { $0.kind == .reviewSuggestions }?.reclaimableBytes == 10_000)
        #expect(plan.sections.first { $0.kind == .inaccessibleItems }?.itemCount == 2)
    }

    private func makeTemporaryRoot() throws -> URL {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageScopeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        return temporaryRoot
    }

    private func writeFile(named name: String, bytes: Int, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        let data = Data(repeating: 7, count: bytes)
        try data.write(to: url)
    }

    private func cleanupCandidate(
        url: URL,
        kind: CleanupCandidate.Kind,
        bytes: Int64,
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

    private func storageItem(
        url: URL,
        name: String? = nil,
        kind: StorageItem.Kind = .file,
        children: [StorageItem] = []
    ) -> StorageItem {
        StorageItem(
            url: url,
            name: name,
            kind: kind,
            byteSize: children.reduce(Int64(1)) { $0 + $1.byteSize },
            allocatedSize: children.reduce(Int64(1)) { $0 + $1.allocatedSize },
            modifiedAt: nil,
            immediateChildCount: children.count,
            descendantCount: children.reduce(0) { $0 + 1 + $1.descendantCount },
            children: children,
            isReadable: true,
            fileExtension: url.pathExtension.isEmpty ? nil : url.pathExtension
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
            allItems: [rootItem],
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

    private enum SimulatedMoveError: Error {
        case blocked
    }
}
