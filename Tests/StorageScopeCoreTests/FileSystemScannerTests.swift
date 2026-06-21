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
        #expect(scan.cleanupCandidates.contains { $0.isHighConfidenceVerifiedDuplicate })
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

    @Test("duplicate verification budget favors groups with the most reclaimable bytes")
    func duplicateVerificationBudgetPrioritizesReclaimableBytes() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        // big: 3 copies × 20 bytes = 60 total, reclaimable = 40
        try Data(repeating: 0x41, count: 20).write(to: temporaryRoot.appendingPathComponent("big-a.bin"))
        try Data(repeating: 0x41, count: 20).write(to: temporaryRoot.appendingPathComponent("big-b.bin"))
        try Data(repeating: 0x41, count: 20).write(to: temporaryRoot.appendingPathComponent("big-c.bin"))
        // small: 2 copies × 10 bytes = 20 total, reclaimable = 10
        try Data(repeating: 0x42, count: 10).write(to: temporaryRoot.appendingPathComponent("small-a.bin"))
        try Data(repeating: 0x42, count: 10).write(to: temporaryRoot.appendingPathComponent("small-b.bin"))

        // Budget of 60 bytes: big (60 total) fits, small (would push to 80) does not.
        let scan = try FileSystemScanner().scan(
            root: temporaryRoot,
            options: ScanOptions(
                duplicateCandidateThreshold: 1,
                duplicateVerificationByteLimit: 60
            )
        )

        let verifiedNames = Set(scan.verifiedDuplicateGroups.flatMap { $0.items.map(\.name) })
        #expect(verifiedNames.isSuperset(of: ["big-a.bin", "big-b.bin", "big-c.bin"]))
        #expect(verifiedNames.isDisjoint(with: ["small-a.bin", "small-b.bin"]))
    }

    @Test("hash cache returns stored checksum on hit and nil on size mismatch")
    func hashCacheReturnsHitOnMatchAndMissOnSizeChange() throws {
        let cache = DuplicateHashCache(cacheURL: nil)

        let item = StorageItem(
            url: URL(fileURLWithPath: "/tmp/example.bin"),
            kind: .file,
            byteSize: 1_024,
            allocatedSize: 1_024,
            modifiedAt: Date(timeIntervalSince1970: 1_000_000),
            immediateChildCount: 0,
            descendantCount: 0,
            isReadable: true,
            fileExtension: "bin"
        )

        let key = DuplicateHashCache.LookupKey(item: item)
        #expect(cache.checksum(for: key) == nil)

        cache.record(key, checksum: "abc123")
        #expect(cache.checksum(for: key) == "abc123")

        // Size change invalidates the cache entry.
        let resized = DuplicateHashCache.LookupKey(
            path: item.url.standardizedFileURL.path,
            byteSize: 2_048,
            modificationDate: item.modifiedAt
        )
        #expect(cache.checksum(for: resized) == nil)
    }

    @Test("clear drops entries and removes the on-disk file")
    func clearDropsEntriesAndRemovesOnDiskFile() throws {
        let diskCacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageScopeHashCacheTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: diskCacheURL) }

        let cache = DuplicateHashCache(cacheURL: diskCacheURL)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let key = DuplicateHashCache.LookupKey(path: "/tmp/x.bin", byteSize: 512, modificationDate: now)
        cache.record(key, checksum: "deadbeef")
        cache.persist()

        #expect(cache.entryCount == 1)
        #expect(cache.lastPersistedAt != nil)
        #expect(FileManager.default.fileExists(atPath: diskCacheURL.path))

        cache.clear()

        #expect(cache.entryCount == 0)
        #expect(cache.lastPersistedAt == nil)
        #expect(!FileManager.default.fileExists(atPath: diskCacheURL.path))
        #expect(cache.checksum(for: key) == nil)
    }

    @Test("purgeStale drops entries for deleted files and keeps the rest")
    func purgeStaleDropsDeletedFileEntriesAndKeepsRest() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let survivingFile = temporaryRoot.appendingPathComponent("survives.bin")
        let deletedFile = temporaryRoot.appendingPathComponent("deleted.bin")
        try Data("survivor".utf8).write(to: survivingFile)
        try Data("gone".utf8).write(to: deletedFile)

        let survivingPath = survivingFile.standardizedFileURL.path
        let deletedPath = deletedFile.standardizedFileURL.path
        let survivingAttrs = try FileManager.default.attributesOfItem(atPath: survivingPath)
        let deletedAttrs = try FileManager.default.attributesOfItem(atPath: deletedPath)

        let diskCacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageScopeHashCacheTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: diskCacheURL) }

        let cache = DuplicateHashCache(cacheURL: diskCacheURL)
        let survivingKey = DuplicateHashCache.LookupKey(
            path: survivingPath,
            byteSize: 1_024,
            modificationDate: survivingAttrs[.modificationDate] as? Date
        )
        let deletedKey = DuplicateHashCache.LookupKey(
            path: deletedPath,
            byteSize: 1_024,
            modificationDate: deletedAttrs[.modificationDate] as? Date
        )
        cache.record(survivingKey, checksum: "survivor-hash")
        cache.record(deletedKey, checksum: "deleted-hash")
        #expect(cache.entryCount == 2)

        try FileManager.default.removeItem(at: deletedFile)

        let droppedCount = cache.purgeStale()

        #expect(droppedCount == 1)
        #expect(cache.entryCount == 1)
        #expect(cache.checksum(for: deletedKey) == nil)
        #expect(cache.checksum(for: survivingKey) == "survivor-hash")
    }

    @Test("verifySizeGroup hashes a same-size group out-of-band and reports verified matches")
    func verifySizeGroupSurfacesVerifiedMatchesOutOfBand() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let sameData = Data(repeating: 0x99, count: 4_096)
        try sameData.write(to: temporaryRoot.appendingPathComponent("a-match.bin"))
        try sameData.write(to: temporaryRoot.appendingPathComponent("b-match.bin"))
        try Data(repeating: 0x01, count: 4_096).write(to: temporaryRoot.appendingPathComponent("c-nomatch.bin"))

        // Run with verification disabled so the same-size group surfaces as unverified. The
        // on-demand path then has work to do.
        let scan = try FileSystemScanner().scan(
            root: temporaryRoot,
            options: ScanOptions(
                duplicateCandidateThreshold: 1,
                duplicateVerificationByteLimit: 0,
                maxDuplicateVerificationFiles: 0
            )
        )

        #expect(scan.duplicateSizeGroups.count == 1)
        #expect(scan.verifiedDuplicateGroups.isEmpty)

        let unverifiedGroup = try #require(scan.duplicateSizeGroups.first)
        let scanner = FileSystemScanner()
        let verifiedGroups = try scanner.verifySizeGroup(unverifiedGroup)

        #expect(verifiedGroups.count == 1)
        let verified = try #require(verifiedGroups.first)
        #expect(verified.items.map(\.name).sorted() == ["a-match.bin", "b-match.bin"])
        #expect(!verified.items.contains { $0.name == "c-nomatch.bin" })
        #expect(verified.byteSize == unverifiedGroup.byteSize)
    }

    @Test("verifySizeGroup surfaces exact matches across a multi-directory fixture")
    func verifySizeGroupSurfacesExactMatchesAcrossMultiDirFixture() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        // Five sibling directories; each holds three files of identical 8 KB byte size with
        // mixed match patterns:
        //   - A "common" file (0x42) that shares content across all five dirs -> verified
        //     group of size 5.
        //   - A "short" file that shares content only in dir0/dir1/dir2 (0x55); dir3 and dir4
        //     diverge (0x56, 0x57) so they stay unverified -> verified group of size 3.
        //   - A "unique" file whose content varies per dir (UInt8(dirIndex)) -> never verified.
        let commonData = Data(repeating: 0x42, count: 8_192)
        let sharedShortData = Data(repeating: 0x55, count: 8_192)
        let dir3ShortData = Data(repeating: 0x56, count: 8_192)
        let dir4ShortData = Data(repeating: 0x57, count: 8_192)

        let dirCount = 5
        let parentDirNames = (0..<dirCount).map { "dir\($0)" }
        for index in 0..<dirCount {
            let dirURL = temporaryRoot.appendingPathComponent(parentDirNames[index], isDirectory: true)
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

            try commonData.write(to: dirURL.appendingPathComponent("common-byte-42.bin"))

            let shortData: Data
            switch index {
            case 3: shortData = dir3ShortData
            case 4: shortData = dir4ShortData
            default: shortData = sharedShortData
            }
            try shortData.write(to: dirURL.appendingPathComponent("group-byte.bin"))

            try Data(repeating: UInt8(index), count: 8_192)
                .write(to: dirURL.appendingPathComponent("unique-per-dir.bin"))
        }

        // Verify disabled so the 15 same-byte-size files collapse into a single unverified
        // group; the on-demand path then has all the work to do.
        let scan = try FileSystemScanner().scan(
            root: temporaryRoot,
            options: ScanOptions(
                duplicateCandidateThreshold: 1,
                duplicateVerificationByteLimit: 0,
                maxDuplicateVerificationFiles: 0
            )
        )

        #expect(scan.duplicateSizeGroups.count == 1)
        #expect(scan.verifiedDuplicateGroups.isEmpty)

        let unverifiedGroup = try #require(scan.duplicateSizeGroups.first)
        #expect(unverifiedGroup.items.count == 15)
        #expect(unverifiedGroup.byteSize == 8_192)

        let scanner = FileSystemScanner()
        let verifiedGroups = try scanner.verifySizeGroup(unverifiedGroup)

        // Exactly two verified groups: the 0x42 family and the 0x55/dir0-dir2 family.
        #expect(verifiedGroups.count == 2)

        // All checksums are distinct and every verified group reports the same byte size.
        #expect(Set(verifiedGroups.map(\.checksum)).count == verifiedGroups.count)
        for verified in verifiedGroups {
            #expect(verified.byteSize == 8_192)
            #expect(verified.items.allSatisfy { $0.byteSize == 8_192 })
        }

        func parentDirName(of item: StorageItem) -> String {
            item.url.deletingLastPathComponent().lastPathComponent
        }

        // Common group: spans all five sibling dirs.
        let commonGroup = try #require(
            verifiedGroups.first { $0.items.contains { $0.name == "common-byte-42.bin" } }
        )
        #expect(commonGroup.items.count == 5)
        let commonParentDirs = Set(commonGroup.items.map(parentDirName))
        #expect(commonParentDirs == Set(parentDirNames))
        #expect(commonParentDirs.count == commonGroup.items.count)

        // Short group: exactly the three 0x55 copies in dir0/dir1/dir2.
        let shortGroup = try #require(
            verifiedGroups.first { $0.items.contains { $0.name == "group-byte.bin" } }
        )
        #expect(shortGroup.items.count == 3)
        let shortParentDirs = Set(shortGroup.items.map(parentDirName))
        #expect(shortParentDirs == Set(["dir0", "dir1", "dir2"]))

        // No verified group touches the unique-per-dir files, and the two groups are disjoint.
        for verified in verifiedGroups {
            #expect(!verified.items.contains { $0.name == "unique-per-dir.bin" })
        }
        #expect(commonGroup.checksum != shortGroup.checksum)
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

        #expect(!hiddenOff.retainedItems.contains { $0.name == ".hidden" })
        #expect(hiddenOn.retainedItems.contains { $0.name == ".hidden" })
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
        #expect(scan.retainedItems.count == 4)
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
        #expect(nestedMatch.matchesSearchQuery("  final-cut  "))
        #expect(nestedMatch.matchesNormalizedSearchQuery("FINAL-CUT"))
        #expect(nestedMatch.matchesSearchQuery("Exports/final-cut.mov"))
        #expect(media.retainedTreeContainsSearchMatch("final-cut"))
        #expect(media.retainedTreeContainsNormalizedSearchMatch("final-cut"))
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
        #expect(scan.retainedItems.count == 6)
        #expect(scan.rootItem.children.first?.name == "wide-0119.dat")
        #expect(Array(scan.largestFiles.map(\.name).prefix(3)) == ["wide-0119.dat", "wide-0118.dat", "wide-0117.dat"])
    }

    @Test("lookup finds ranked items pruned from retained tree")
    func lookupFindsPrunedRankedItems() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try writeFile(named: "kept-large.dat", bytes: 9_000, in: temporaryRoot)
        try writeFile(named: "pruned-ranked.dat", bytes: 7_000, in: temporaryRoot)
        try writeFile(named: "tiny.dat", bytes: 1_000, in: temporaryRoot)

        let scan = try FileSystemScanner().scan(
            root: temporaryRoot,
            options: ScanOptions(
                largeFileThreshold: 1,
                duplicateCandidateThreshold: 20_000,
                maxChildrenPerDirectory: 1,
                maxRetainedItems: 2
            )
        )

        let prunedRankedItem = try #require(scan.largestFiles.first { $0.name == "pruned-ranked.dat" })

        #expect(!scan.retainedItems.contains { $0.id == prunedRankedItem.id })
        #expect(scan.lookupItem(id: prunedRankedItem.id)?.name == "pruned-ranked.dat")
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

    @Test("cleanup trust details explain verified duplicates")
    func cleanupTrustDetailsExplainVerifiedDuplicates() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let duplicate = cleanupCandidate(
            url: temporaryRoot.appendingPathComponent("copy-a.mov"),
            kind: .verifiedDuplicate,
            bytes: 8_000,
            confidence: .high
        )

        let details = duplicate.trustDetails

        #expect(details.confidenceLabel == "Verified")
        #expect(details.safetyNote.contains("SHA-256"))
        #expect(details.couldBreak.contains("Keep one"))
        #expect(details.suggestedAction.contains("duplicate copies"))
    }

    @Test("cleanup trust details warn for review heuristics")
    func cleanupTrustDetailsWarnForReviewHeuristics() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let cache = cleanupCandidate(
            url: temporaryRoot.appendingPathComponent("Caches", isDirectory: true),
            kind: .cacheFolder,
            bytes: 12_000,
            confidence: .medium
        )
        let archive = cleanupCandidate(
            url: temporaryRoot.appendingPathComponent("backup.zip"),
            kind: .archive,
            bytes: 6_000,
            confidence: .review
        )

        #expect(cache.trustDetails.confidenceLabel == "Review")
        #expect(cache.trustDetails.couldBreak.contains("using the cache"))
        #expect(cache.trustDetails.suggestedAction.contains("Quit the owning app"))
        #expect(archive.trustDetails.confidenceLabel == "Manual")
        #expect(archive.trustDetails.couldBreak.contains("only compressed backup"))
        #expect(archive.trustDetails.suggestedAction.contains("Reveal"))
    }

    @Test("cleanup trust details cover every candidate kind")
    func cleanupTrustDetailsCoverEveryCandidateKind() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let cases: [(CleanupCandidate.Kind, CleanupCandidate.Confidence, String, String)] = [
            (.verifiedDuplicate, .high, "Keep one", "SHA-256"),
            (.cacheFolder, .medium, "using the cache", "Quit the owning app"),
            (.buildArtifact, .medium, "next clean build", "rebuild it"),
            (.diskImage, .medium, "mounted content", "installed or preserved"),
            (.installer, .medium, "download the installer again", "installed or preserved"),
            (.archive, .review, "only compressed backup", "another usable copy exists"),
            (.temporary, .review, "active work", "Reveal first"),
            (.oldLargeFile, .review, "only copy", "Reveal and review")
        ]

        for (kind, confidence, riskFragment, actionFragment) in cases {
            let candidate = cleanupCandidate(
                url: temporaryRoot.appendingPathComponent("\(kind.rawValue).bin"),
                kind: kind,
                bytes: 4_000,
                confidence: confidence
            )
            let details = candidate.trustDetails

            #expect(!details.safetyNote.localizedCaseInsensitiveContains("safe to delete"))
            #expect(!details.suggestedAction.localizedCaseInsensitiveContains("safe to delete"))
            #expect(details.couldBreak.contains(riskFragment))
            #expect(details.safetyNote.contains(actionFragment) || details.suggestedAction.contains(actionFragment))
        }
    }

    @Test("benchmark report contains scanner summary values")
    func benchmarkReportContainsScannerSummaryValues() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try writeFile(named: "first.bin", bytes: 4_000, in: temporaryRoot)
        try writeFile(named: "second.bin", bytes: 4_000, in: temporaryRoot)

        let report = try ScanBenchmarkRunner().run(rootURL: temporaryRoot)
        let text = report.text

        #expect(text.contains("StorageScope benchmark"))
        #expect(text.contains("Scope: \(temporaryRoot.lastPathComponent)"))
        #expect(text.contains("Items scanned:"))
        #expect(text.contains("Duplicate candidates:"))
        #expect(text.contains("Duplicate verification:"))
        #expect(text.contains("Results are local only."))
        #expect(!text.contains(temporaryRoot.deletingLastPathComponent().path))
        #expect(!text.localizedCaseInsensitiveContains("http://"))
        #expect(!text.localizedCaseInsensitiveContains("https://"))
    }

    @Test("synthetic benchmark fixture creates expected candidate classes")
    func syntheticBenchmarkFixtureCreatesExpectedCandidateClasses() throws {
        let root = try SyntheticBenchmarkFixture.create()
        defer { SyntheticBenchmarkFixture.remove(root) }

        let scan = try FileSystemScanner().scan(root: root, options: .benchmarkDefaults())
        let kinds = Set(scan.cleanupCandidates.map(\.kind))

        #expect(kinds.contains(.verifiedDuplicate))
        #expect(kinds.contains(.cacheFolder))
        #expect(kinds.contains(.buildArtifact))
        #expect(kinds.contains(.diskImage))
        #expect(kinds.contains(.installer))
        #expect(kinds.contains(.archive))
        #expect(kinds.contains(.temporary))
        #expect(kinds.contains(.oldLargeFile))
        #expect(scan.duplicateCandidateItemsConsidered >= scan.duplicateCandidateItemsRetained)
        #expect(scan.duplicateVerificationDuration >= 0)
    }

    @Test("benchmark fixture and report do not write private scan output into repo")
    func benchmarkDoesNotWritePrivateScanOutputIntoRepo() throws {
        let root = try SyntheticBenchmarkFixture.create()
        defer { SyntheticBenchmarkFixture.remove(root) }

        let report = try ScanBenchmarkRunner().run(rootURL: root)
        let repoRoot = try repositoryRoot()
        let benchmarkArtifacts = try FileManager.default.contentsOfDirectory(atPath: repoRoot.path)
            .filter { $0.localizedCaseInsensitiveContains("benchmark") && !$0.hasSuffix(".sh") }

        #expect(report.scopeLabel == root.lastPathComponent)
        #expect(benchmarkArtifacts.isEmpty)
    }

    @Test("benchmark script passes shell syntax checks")
    func benchmarkScriptPassesShellSyntaxChecks() throws {
        let repoRoot = try repositoryRoot()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", repoRoot.appendingPathComponent("script/benchmark_scan.sh").path]
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
    }

    @Test("benchmark report exposes per-phase durations")
    func benchmarkReportExposesPerPhaseDurations() throws {
        let root = try SyntheticBenchmarkFixture.create()
        defer { SyntheticBenchmarkFixture.remove(root) }

        let report = try ScanBenchmarkRunner().run(rootURL: root)

        #expect(report.enumerateDuration >= 0)
        #expect(report.verifyDuration >= 0)
        #expect(report.verifyDuration == report.duplicateVerificationDuration)
        #expect(report.persistDuration == 0)
        #expect(report.totalDuration == report.enumerateDuration + report.verifyDuration + report.persistDuration)
        #expect(report.totalDuration >= report.verifyDuration)

        // The text report should surface every phase so a CLI user can spot regressions.
        let text = report.text
        #expect(text.contains("Enumerate duration:"))
        #expect(text.contains("Verify duration:"))
        #expect(text.contains("Persist duration:"))
        #expect(text.contains("Phase total (enum+verify+persist):"))
    }

    @Test("benchmark runner persists and times the on-disk hash cache phase when wired up")
    func benchmarkRunnerPersistsAndTimesOnDiskHashCachePhase() throws {
        let root = try SyntheticBenchmarkFixture.create()
        defer { SyntheticBenchmarkFixture.remove(root) }

        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageScopeBenchmarkCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let cacheURL = cacheDir.appendingPathComponent("hashes.json")

        let cache = DuplicateHashCache(cacheURL: cacheURL)
        let scanner = FileSystemScanner(hashCache: cache)
        let runner = ScanBenchmarkRunner(scanner: scanner, hashCache: cache)

        let firstReport = try runner.run(rootURL: root)
        #expect(firstReport.enumerateDuration >= 0)
        #expect(firstReport.verifyDuration >= 0)
        #expect(firstReport.persistDuration >= 0)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))

        // Second run hits the cache: verify should drop materially, persist stays measurable.
        let secondReport = try runner.run(rootURL: root)
        #expect(secondReport.enumerateDuration >= 0)
        #expect(secondReport.verifyDuration >= 0)
        #expect(secondReport.verifyDuration <= firstReport.verifyDuration + 0.001)
        #expect(secondReport.persistDuration >= 0)
        #expect(secondReport.totalDuration >= 0)
    }

    @Test("scan option policy uses fixed analysis thresholds")
    func scanOptionPolicyUsesFixedThresholds() {
        let thresholds = ScanOptionPolicy.interactiveScanThresholds()

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

    @Test("trash review plan groups verified and review candidates")
    func trashReviewPlanGroupsVerifiedAndReviewCandidates() throws {
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

        let plan = TrashReviewPlan(candidates: [verifiedDuplicate, diskImage])

        #expect(plan.title == "Move 2 Items to Trash?")
        #expect(plan.estimatedReclaimBytes == 14_000)
        #expect(plan.containsReviewRisk)
        #expect(plan.verifiedItems.map(\.url.lastPathComponent) == ["copy-a.mov"])
        #expect(plan.reviewItems.map(\.url.lastPathComponent) == ["installer.dmg"])
    }

    @Test("trash review plan collapses nested targets before presenting paths")
    func trashReviewPlanCollapsesNestedTargetsBeforePresentingPaths() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let cacheFolder = temporaryRoot.appendingPathComponent("Caches", isDirectory: true)
        let nestedInstaller = cacheFolder.appendingPathComponent("installer.dmg")
        let cacheCandidate = cleanupCandidate(url: cacheFolder, kind: .cacheFolder, bytes: 10_000)
        let installerCandidate = cleanupCandidate(url: nestedInstaller, kind: .diskImage, bytes: 4_000)

        let plan = TrashReviewPlan(candidates: [installerCandidate, cacheCandidate])

        #expect(plan.items.map(\.url.lastPathComponent) == ["Caches"])
        #expect(plan.estimatedReclaimBytes == 10_000)
    }

    @Test("trash review plan routes synthesized general candidates through review lane only")
    func trashReviewPlanRoutesGeneralCandidateThroughReviewLane() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let generalItem = cleanupCandidate(
            url: temporaryRoot.appendingPathComponent("manual-pick.bin"),
            kind: .general,
            bytes: 4_096,
            confidence: .review
        )

        let plan = TrashReviewPlan(candidates: [generalItem])

        #expect(plan.title == "Move 1 Item to Trash?")
        #expect(plan.items.count == 1)
        #expect(plan.verifiedItems.isEmpty)
        #expect(plan.reviewItems.count == 1)
        #expect(plan.containsReviewRisk)
        #expect(plan.reviewItems.first?.kind == .general)
        #expect(plan.reviewItems.first?.isVerified == false)
    }

    @Test("parallel sibling enumeration produces deterministic results across runs")
    func parallelEnumerationIsDeterministicAcrossRuns() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        // Three sibling directories with a mix of file sizes, plus one verified duplicate
        // pair spanning two siblings so the verify path is exercised too.
        let media = temporaryRoot.appendingPathComponent("Media", isDirectory: true)
        let cache = temporaryRoot.appendingPathComponent("Cache", isDirectory: true)
        let drivers = temporaryRoot.appendingPathComponent("Drivers", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: drivers, withIntermediateDirectories: true)

        try writeFile(named: "render.mov", bytes: 40_000, in: media)
        try writeFile(named: "thumbnail.jpg", bytes: 8_000, in: media)
        try writeFile(named: "blob.sqlite", bytes: 12_000, in: cache)
        try writeFile(named: "driver.kext", bytes: 25_000, in: drivers)

        let duplicateData = Data(repeating: 0xAB, count: 9_000)
        try duplicateData.write(to: media.appendingPathComponent("asset.bin"))
        try duplicateData.write(to: drivers.appendingPathComponent("asset-copy.bin"))

        let scanner = FileSystemScanner()
        let options = ScanOptions(duplicateCandidateThreshold: 5_000, maxChildrenPerDirectory: 50, maxRetainedItems: 200)

        let first = try scanner.scan(root: temporaryRoot, options: options)
        let second = try scanner.scan(root: temporaryRoot, options: options)

        #expect(first.scannedItemCount == second.scannedItemCount)
        #expect(first.totalBytes == second.totalBytes)
        #expect(first.largestFiles.map(\.id) == second.largestFiles.map(\.id))
        #expect(first.largestFolders.map(\.id) == second.largestFolders.map(\.id))
        #expect(first.verifiedDuplicateGroups.count == second.verifiedDuplicateGroups.count)
        #expect(first.verifiedDuplicateGroups.map(\.checksum) == second.verifiedDuplicateGroups.map(\.checksum))
        #expect(first.verifiedDuplicateGroups.flatMap(\.items).map(\.id)
                   == second.verifiedDuplicateGroups.flatMap(\.items).map(\.id))

        // Sanity: the duplicate pair was actually found through the parallel path.
        #expect(first.verifiedDuplicateGroups.count == 1)
        #expect(first.verifiedDuplicateGroups.first?.items.count == 2)
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

    private func repositoryRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
        }
        throw CocoaError(.fileNoSuchFile)
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

    private enum SimulatedMoveError: Error {
        case blocked
    }
}
