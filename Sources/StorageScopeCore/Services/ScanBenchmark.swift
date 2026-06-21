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

        let persistStartedAt = Date()
        hashCache?.persist()
        let persistDuration = Date().timeIntervalSince(persistStartedAt)

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
    public static func create(
        in parentDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) throws -> URL {
        let root = parentDirectory.appendingPathComponent("StorageScopeBenchmark-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

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
