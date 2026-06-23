import Foundation

public struct ScanBenchmarkReport: Hashable, Sendable {
    public let scopeLabel: String
    public let duration: TimeInterval
    public let scannedItemCount: Int
    public let inaccessibleItemCount: Int
    public let totalBytes: Int64
    public let largestFileCount: Int
    public let largestFolderCount: Int
    public let duplicateCandidateItemsConsidered: Int
    public let duplicateCandidateItemsRetained: Int
    public let duplicateCandidateLimitReached: Bool
    public let verifiedDuplicateGroupCount: Int
    public let duplicateVerificationDuration: TimeInterval
    public let enumerateDuration: TimeInterval
    public let verifyDuration: TimeInterval
    public let persistDuration: TimeInterval
    public let cleanupCandidateCount: Int
    public let peakMemoryBytes: UInt64?

    /// Sum of the three instrumented phases (enumerate + verify + persist). This typically
    /// under-shoots `duration` because bookkeeping between phases (cleanup candidate
    /// planning, retained child collection, lookup construction) is not separately timed.
    public var totalDuration: TimeInterval {
        enumerateDuration + verifyDuration + persistDuration
    }

    public init(
        scopeLabel: String,
        scan: StorageScan,
        persistDuration: TimeInterval = 0,
        peakMemoryBytes: UInt64? = Self.currentPeakResidentMemoryBytes()
    ) {
        self.scopeLabel = scopeLabel
        self.duration = scan.finishedAt.timeIntervalSince(scan.startedAt)
        self.scannedItemCount = scan.scannedItemCount
        self.inaccessibleItemCount = scan.inaccessibleItemCount
        self.totalBytes = scan.totalBytes
        self.largestFileCount = scan.largestFiles.count
        self.largestFolderCount = scan.largestFolders.count
        self.duplicateCandidateItemsConsidered = scan.duplicateCandidateItemsConsidered
        self.duplicateCandidateItemsRetained = scan.duplicateCandidateItemsRetained
        self.duplicateCandidateLimitReached = scan.duplicateCandidateLimitReached
        self.verifiedDuplicateGroupCount = scan.verifiedDuplicateGroups.count
        self.duplicateVerificationDuration = scan.duplicateVerificationDuration
        self.enumerateDuration = scan.enumerateDuration
        self.verifyDuration = scan.duplicateVerificationDuration
        self.persistDuration = persistDuration
        self.cleanupCandidateCount = scan.cleanupCandidates.count
        self.peakMemoryBytes = peakMemoryBytes
    }

    public var text: String {
        [
            "StorageScope benchmark",
            "Scope: \(scopeLabel)",
            "Duration: \(Self.seconds(duration))",
            "Items scanned: \(scannedItemCount.formatted())",
            "Inaccessible: \(inaccessibleItemCount.formatted())",
            "Total size: \(Self.bytes(totalBytes))",
            "Largest files retained: \(largestFileCount.formatted())",
            "Largest folders retained: \(largestFolderCount.formatted())",
            "Duplicate candidates: \(duplicateCandidateItemsRetained.formatted()) retained / \(duplicateCandidateItemsConsidered.formatted()) considered",
            "Duplicate cap reached: \(duplicateCandidateLimitReached ? "yes" : "no")",
            "Verified duplicate groups: \(verifiedDuplicateGroupCount.formatted())",
            "Duplicate verification: \(Self.seconds(duplicateVerificationDuration))",
            "Enumerate duration: \(Self.seconds(enumerateDuration))",
            "Verify duration: \(Self.seconds(verifyDuration))",
            "Persist duration: \(Self.seconds(persistDuration))",
            "Phase total (enum+verify+persist): \(Self.seconds(totalDuration))",
            "Cleanup candidates: \(cleanupCandidateCount.formatted())",
            "Peak memory: \(peakMemoryBytes.map(Self.bytes) ?? "unavailable")",
            "Results are local only."
        ].joined(separator: "\n")
    }

    public static func scopeLabel(for url: URL, showFullPath: Bool = false) -> String {
        if showFullPath {
            return url.path
        }
        let name = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? url.path : name
    }

    private static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.2fs", max(0, value))
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    public static func currentPeakResidentMemoryBytes() -> UInt64? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            return nil
        }
        return UInt64(max(0, usage.ru_maxrss))
    }
}

public struct ScanBenchmarkRunner {
    private let scanner: FileSystemScanner
    private let hashCache: DuplicateHashCache?

    /// - parameters:
    ///   - scanner: The scanner to drive. Defaults to a fresh `FileSystemScanner` with
    ///     no cache attached. To measure real persist I/O after a duplicate scan,
    ///     pass a scanner constructed with the same `hashCache`
    ///     (e.g. `FileSystemScanner(hashCache: cache)`); the runner does not rewire
    ///     the cache into the scanner for you.
    ///   - hashCache: When set, the runner drives `hashCache.persist()` after each scan
    ///     and records `persistDuration`. When nil, `persistDuration` stays 0 because
    ///     the benchmark never triggers an on-disk write.
    public init(scanner: FileSystemScanner = FileSystemScanner(), hashCache: DuplicateHashCache? = nil) {
        self.scanner = scanner
        self.hashCache = hashCache
    }

    public func run(rootURL: URL, options: ScanOptions = .benchmarkDefaults(), showFullPath: Bool = false) throws -> ScanBenchmarkReport {
        let scan = try scanner.scan(root: rootURL, options: options)

        // Gate the persist-phase timing on a real cache being attached. When `hashCache`
        // is nil, `hashCache?.persist()` is a no-op, so any non-zero persistDuration here
        // would be pure `Date()` jitter — the no-cache contract is hard-zero. Recording it
        // unconditionally made `benchmarkReportExposesPerPhaseDurations` flake (~1µs).
        let persistDuration: TimeInterval
        if let hashCache {
            let persistStartedAt = Date()
            hashCache.persist()
            persistDuration = Date().timeIntervalSince(persistStartedAt)
        } else {
            persistDuration = 0
        }

        return ScanBenchmarkReport(
            scopeLabel: ScanBenchmarkReport.scopeLabel(for: rootURL, showFullPath: showFullPath),
            scan: scan,
            persistDuration: persistDuration
        )
    }
}

public extension ScanOptions {
    static func benchmarkDefaults() -> ScanOptions {
        ScanOptions(
            oldFileAgeDays: 180,
            largeFileThreshold: 1_000_000,
            duplicateCandidateThreshold: 1,
            duplicateVerificationByteLimit: 500_000_000,
            maxDuplicateVerificationFiles: 1_000,
            maxDuplicateCandidateItems: 5_000,
            maxRankedResults: 250,
            maxChildrenPerDirectory: 250,
            maxRetainedItems: 2_000
        )
    }
}

public enum SyntheticBenchmarkFixture {
    /// Default fixture for the existing `--synthetic` flow (~10 files across 6 dirs).
    /// Kept for backward compat so v0.5.0-era scripts that pass no extra flags still work.
    public static func create(
        in parentDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) throws -> URL {
        try create(
            in: parentDirectory,
            fileManager: fileManager,
            items: 0,
            depth: 0,
            duplicateRatio: 0.0
        )
    }

    /// Scaled synthetic fixture generator.
    ///
    /// `items == 0` (default) builds the original 7-file curated fixture so script
    /// behavior is unchanged. `items > 0` builds a generated fixture with `items` files
    /// distributed across a directory tree of maximum depth `depth`. `duplicateRatio`
    /// is the fraction of `items` that become SHA-256 verified duplicates (each duplicate
    /// group contains 2-3 copies at the same byte size, exercising the verify path).
    ///
    /// Generated files are small (1 KB-256 KB, seeded) so a 500k fixture fits comfortably
    /// in temp (~5 GB worst case, typically <1 GB since most files are 1-4 KB). All
    /// files use random-but-deterministic byte patterns seeded by file index so identical
    /// sizes don't accidentally hash to the same checksum.
    public static func create(
        in parentDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default,
        items: Int,
        depth: Int,
        duplicateRatio: Double
    ) throws -> URL {
        let root = parentDirectory.appendingPathComponent("StorageScopeBenchmark-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        guard items > 0 else {
            // Build the original curated fixture (v0.5.0 baseline shape)
            try makeDirectory(root.appendingPathComponent("Nested/Projects/App/build/debug", isDirectory: true), fileManager: fileManager)
            try makeDirectory(root.appendingPathComponent("Library/Caches/com.example.app", isDirectory: true), fileManager: fileManager)
            try makeDirectory(root.appendingPathComponent("Downloads", isDirectory: true), fileManager: fileManager)
            try makeDirectory(root.appendingPathComponent("Archives", isDirectory: true), fileManager: fileManager)
            try makeDirectory(root.appendingPathComponent("Duplicates", isDirectory: true), fileManager: fileManager)
            try makeDirectory(root.appendingPathComponent("Old", isDirectory: true), fileManager: fileManager)

            try writeFile(root.appendingPathComponent("Nested/Projects/App/build/debug/module.o"), bytes: 1_250_000, seed: 1)
            try writeFile(root.appendingPathComponent("Library/Caches/com.example.app/cache.db"), bytes: 900_000, seed: 2)
            try writeFile(root.appendingPathComponent("Downloads/StorageScope-demo.dmg"), bytes: 1_500_000, seed: 3)
            try writeFile(root.appendingPathComponent("Downloads/ExampleInstaller.pkg"), bytes: 1_200_000, seed: 4)
            try writeFile(root.appendingPathComponent("Archives/source-drop.zip"), bytes: 1_100_000, seed: 5)
            try writeFile(root.appendingPathComponent("temporary.tmp"), bytes: 256_000, seed: 6)
            try writeFile(root.appendingPathComponent("same-size-a.bin"), bytes: 512_000, seed: 7)
            try writeFile(root.appendingPathComponent("same-size-b.bin"), bytes: 512_000, seed: 8)

            let duplicateData = Data(repeating: 42, count: 768_000)
            try duplicateData.write(to: root.appendingPathComponent("Duplicates/copy-a.bin"))
            try duplicateData.write(to: root.appendingPathComponent("Duplicates/copy-b.bin"))

            let oldFile = root.appendingPathComponent("Old/old-large.mov")
            try writeSparseFile(oldFile, logicalBytes: 1_100_000_000)
            let oldDate = Date(timeIntervalSinceNow: -220 * 24 * 60 * 60)
            try fileManager.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldFile.path)

            return root
        }

        // Scaled fixture path
        try generateScaledFixture(
            root: root,
            items: items,
            depth: max(1, depth),
            duplicateRatio: max(0, min(1, duplicateRatio)),
            fileManager: fileManager
        )
        return root
    }

    /// Builds `items` files distributed across a directory tree of up to `depth` levels.
    /// Roughly 120 files per leaf directory. A `duplicateRatio` fraction of files are
    /// emitted in pairs/triples of identical byte content at the same size, exercising
    /// the iterate-size-group / verify path (most will hash to the same SHA-256 only
    /// if the content truly matches - the generator picks the duplicate seed deterministically).
    private static func generateScaledFixture(
        root: URL,
        items: Int,
        depth: Int,
        duplicateRatio: Double,
        fileManager: FileManager
    ) throws {
        let filesPerLeafDir = 120
        let leafDirCount = max(1, (items + filesPerLeafDir - 1) / filesPerLeafDir)
        // Build a flat list of leaf directory names then derive their paths by
        // hashing the index into a path of `depth` segments. Ensures the tree
        // looks realistic (not all flat under root) and the scanner's parallel
        // enumerator has real fan-out work to do.
        var dirs: [URL] = []
        for i in 0..<leafDirCount {
            var path = root
            var bucket = i
            for _ in 0..<depth {
                let segment = "bucket-\(bucket % 16)"
                path = path.appendingPathComponent(segment, isDirectory: true)
                bucket /= 16
            }
            try fileManager.createDirectory(at: path, withIntermediateDirectories: true)
            dirs.append(path)
        }
        guard !dirs.isEmpty else { return }

        // Duplicate bands: pick a deterministic size + content seed so 2-3 copies
        // hash to the same SHA-256. Files outside duplicate bands get distinct seeds.
        let duplicateCount = Int(Double(items) * duplicateRatio)
        let duplicateBandSize = 16_384 // 16 KB — small enough to fit terse bodies
        let duplicateBandSeeds: [UInt8] = (0..<duplicateCount).map { UInt8($0 % 220) }

        for fileIndex in 0..<items {
            let dir = dirs[fileIndex % dirs.count]
            let isDuplicate = fileIndex < duplicateCount
            let size: Int
            let seed: UInt8
            let name: String

            if isDuplicate {
                // Two copies per band share both size and content seed so the SHA-256 matches.
                // Group files into pairs: file 2i and 2i+1 in the band share the seed.
                let bandIndex = fileIndex / 2
                size = duplicateBandSize
                seed = duplicateBandSeeds[bandIndex % duplicateBandSeeds.count]
                name = "dup-\(bandIndex)-\(fileIndex % 2 == 0 ? "a" : "b").bin"
            } else {
                // Non-duplicate files: scattered sizes in the 1 KB - 256 KB range, distinct seeds.
                let tier = fileIndex % 5
                switch tier {
                case 0: size = 1_024
                case 1: size = 8_192
                case 2: size = 32_768
                case 3: size = 65_536
                default: size = 262_144
                }
                seed = UInt8((fileIndex % 220) + 30) // offset 30 so we don't collide with dup seeds
                name = "file-\(fileIndex).dat"
            }

            let url = dir.appendingPathComponent(name)
            try writeFile(url, bytes: size, seed: seed)
        }
    }

    public static func remove(_ root: URL, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: root)
    }

    private static func makeDirectory(_ url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private static func writeFile(_ url: URL, bytes: Int, seed: UInt8) throws {
        let chunk = Data(repeating: seed, count: min(bytes, 64 * 1024))
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var remaining = bytes
        while remaining > 0 {
            let count = min(remaining, chunk.count)
            try handle.write(contentsOf: chunk.prefix(count))
            remaining -= count
        }
    }

    private static func writeSparseFile(_ url: URL, logicalBytes: UInt64) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: logicalBytes)
    }
}
