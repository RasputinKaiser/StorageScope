import Foundation
@testable import StorageScopeCore

/// Test-only fixture and comparison infrastructure for scanner architecture changes.
///
/// The harness deliberately compares semantic scan output rather than absolute paths,
/// timestamps, or wall-clock timings. A future walker can be passed as `candidate` and
/// compared with the current implementation without changing production APIs.
struct ScannerProofHarness {
    typealias Runner = (_ root: URL, _ fileManager: FileManager) throws -> StorageScan

    static let proofOptions = ScanOptions(
        oldFileAgeDays: 180,
        largeFileThreshold: 1,
        duplicateCandidateThreshold: 1,
        duplicateVerificationByteLimit: 512 * 1_024 * 1_024,
        maxDuplicateVerificationFiles: 10_000,
        maxDuplicateCandidateItems: 10_000,
        maxRankedResults: 10_000,
        maxChildrenPerDirectory: 10_000,
        maxRetainedItems: 100_000
    )

    static let legacyRunner: Runner = { root, fileManager in
        try FileSystemScanner(
            fileManager: fileManager,
            walkerMode: .legacy
        ).scan(root: root, options: proofOptions)
    }

    static let fixedWorkerRunner: Runner = { root, fileManager in
        try FileSystemScanner(
            fileManager: fileManager,
            walkerMode: .fixedWorker
        ).scan(root: root, options: proofOptions)
    }

    static let currentRunner: Runner = { root, fileManager in
        try FileSystemScanner(fileManager: fileManager).scan(root: root, options: proofOptions)
    }

    static func scan(_ fixture: ScannerProofFixture, runner: Runner = currentRunner) throws -> StorageScan {
        try runner(fixture.root, fixture.makeFileManager())
    }

    /// Compare two scanner implementations against the same fixture state.
    ///
    /// Each runner gets a fresh file manager so fault injection is identical and no
    /// implementation can accidentally share mutable enumeration state with the other.
    @discardableResult
    static func compare(
        _ fixture: ScannerProofFixture,
        baseline: Runner,
        candidate: Runner,
        context: String
    ) throws -> ScanSignature {
        let baselineScan = try baseline(fixture.root, fixture.makeFileManager())
        let candidateScan = try candidate(fixture.root, fixture.makeFileManager())
        let baselineSignature = signature(of: baselineScan, root: fixture.root)
        let candidateSignature = signature(of: candidateScan, root: fixture.root)

        if let difference = firstDifference(baselineSignature, candidateSignature) {
            throw ScannerProofError.mismatch(context: context, detail: difference)
        }

        return baselineSignature
    }

    /// Run the differential comparison through every mutation state, including the
    /// initial state before the first mutation.
    static func compareMutationSequence(
        _ fixture: ScannerProofFixture,
        baseline: Runner,
        candidate: Runner
    ) throws -> [ScanSignature] {
        var signatures: [ScanSignature] = []
        signatures.reserveCapacity(fixture.mutations.count + 1)

        for stateIndex in 0...fixture.mutations.count {
            signatures.append(try compare(
                fixture,
                baseline: baseline,
                candidate: candidate,
                context: "mutation state \(stateIndex)"
            ))

            guard stateIndex < fixture.mutations.count else { break }
            try fixture.mutations[stateIndex].apply(in: fixture.root)
        }

        return signatures
    }

    static func signature(of scan: StorageScan, root: URL) -> ScanSignature {
        ScanSignature(
            root: itemSignature(scan.rootItem, root: root),
            retainedPaths: scan.retainedItems.map { relativePath($0.url, from: root) }.sorted(),
            scannedItemCount: scan.scannedItemCount,
            inaccessibleItemCount: scan.inaccessibleItemCount,
            totalBytes: scan.totalBytes,
            largestFiles: scan.largestFiles.map { relativePath($0.url, from: root) }.sorted(),
            largestFolders: scan.largestFolders.map { relativePath($0.url, from: root) }.sorted(),
            oldLargeFiles: scan.oldLargeFiles.map { relativePath($0.url, from: root) }.sorted(),
            typeBreakdown: scan.typeBreakdown.map {
                TypeSignature(
                    label: $0.label,
                    category: $0.category.rawValue,
                    fileCount: $0.fileCount,
                    totalBytes: $0.totalBytes
                )
            }.sorted { $0.label < $1.label },
            categoryBreakdown: scan.categoryBreakdown.map {
                CategorySignature(
                    category: $0.category.rawValue,
                    fileCount: $0.fileCount,
                    extensionCount: $0.extensionCount,
                    totalBytes: $0.totalBytes
                )
            }.sorted { $0.category < $1.category },
            duplicateSizeGroups: scan.duplicateSizeGroups.map {
                GroupSignature(
                    byteSize: $0.byteSize,
                    paths: $0.items.map { relativePath($0.url, from: root) }.sorted()
                )
            }.sorted {
                if $0.byteSize != $1.byteSize {
                    return $0.byteSize < $1.byteSize
                }
                return $0.paths.lexicographicallyPrecedes($1.paths)
            },
            verifiedDuplicateGroups: scan.verifiedDuplicateGroups.map {
                VerifiedGroupSignature(
                    checksum: $0.checksum,
                    byteSize: $0.byteSize,
                    paths: $0.items.map { relativePath($0.url, from: root) }.sorted()
                )
            }.sorted { ($0.byteSize, $0.checksum) < ($1.byteSize, $1.checksum) },
            cleanupCandidates: scan.cleanupCandidates.map {
                CandidateSignature(
                    kind: $0.kind.rawValue,
                    path: relativePath($0.item.url, from: root),
                    confidence: $0.confidence.rawValue,
                    reason: $0.reason,
                    reclaimableBytes: $0.reclaimableBytes
                )
            }.sorted { ($0.path, $0.kind) < ($1.path, $1.kind) },
            duplicateCandidateItemLimit: scan.duplicateCandidateItemLimit,
            duplicateCandidateItemsRetained: scan.duplicateCandidateItemsRetained,
            duplicateCandidateItemsConsidered: scan.duplicateCandidateItemsConsidered,
            duplicateCandidateEvictionCount: scan.duplicateCandidateEvictionCount,
            duplicateCandidateLimitReached: scan.duplicateCandidateLimitReached,
            snapshotBuildCount: scan.snapshotBuildCount,
            duplicateVerificationBytesRead: scan.duplicateVerificationBytesRead,
            isPartial: scan.isPartial
        )
    }

    static func relativePath(_ url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let itemPath = url.standardizedFileURL.path
        guard itemPath != rootPath else { return "." }
        guard itemPath.hasPrefix(rootPath + "/") else { return itemPath }
        return String(itemPath.dropFirst(rootPath.count + 1))
    }

    private static func itemSignature(_ item: StorageItem, root: URL) -> ItemSignature {
        ItemSignature(
            path: relativePath(item.url, from: root),
            kind: item.kind.rawValue,
            byteSize: item.byteSize,
            allocatedSize: item.allocatedSize,
            immediateChildCount: item.immediateChildCount,
            descendantCount: item.descendantCount,
            isReadable: item.isReadable,
            fileExtension: item.fileExtension,
            children: item.children
                .map { itemSignature($0, root: root) }
                .sorted { $0.path < $1.path }
        )
    }

    private static func firstDifference(_ baseline: ScanSignature, _ candidate: ScanSignature) -> String? {
        guard baseline != candidate else { return nil }

        let baselinePaths = Set(baseline.root.allPaths)
        let candidatePaths = Set(candidate.root.allPaths)
        let baselineOnly = baselinePaths.subtracting(candidatePaths).sorted()
        let candidateOnly = candidatePaths.subtracting(baselinePaths).sorted()

        return "baseline \(baseline.summary); candidate \(candidate.summary); " +
            "baseline-only paths: \(baselineOnly.prefix(8)); candidate-only paths: \(candidateOnly.prefix(8))"
    }
}

struct ScanSignature: Equatable, Sendable {
    let root: ItemSignature
    let retainedPaths: [String]
    let scannedItemCount: Int
    let inaccessibleItemCount: Int
    let totalBytes: Int64
    let largestFiles: [String]
    let largestFolders: [String]
    let oldLargeFiles: [String]
    let typeBreakdown: [TypeSignature]
    let categoryBreakdown: [CategorySignature]
    let duplicateSizeGroups: [GroupSignature]
    let verifiedDuplicateGroups: [VerifiedGroupSignature]
    let cleanupCandidates: [CandidateSignature]
    let duplicateCandidateItemLimit: Int
    let duplicateCandidateItemsRetained: Int
    let duplicateCandidateItemsConsidered: Int
    let duplicateCandidateEvictionCount: Int
    let duplicateCandidateLimitReached: Bool
    let snapshotBuildCount: Int
    let duplicateVerificationBytesRead: Int64
    let isPartial: Bool

    var treePaths: [String] {
        root.allPaths.sorted()
    }

    var summary: String {
        "items=\(scannedItemCount), inaccessible=\(inaccessibleItemCount), bytes=\(totalBytes), retained=\(retainedPaths.count), tree=\(treePaths.count)"
    }
}

struct ItemSignature: Equatable, Sendable {
    let path: String
    let kind: String
    let byteSize: Int64
    let allocatedSize: Int64
    let immediateChildCount: Int
    let descendantCount: Int
    let isReadable: Bool
    let fileExtension: String?
    let children: [ItemSignature]

    var allPaths: [String] {
        [path] + children.flatMap(\.allPaths)
    }

    var maxDepth: Int {
        1 + (children.map(\.maxDepth).max() ?? 0)
    }

    var maxWidth: Int {
        max(children.count, children.map(\.maxWidth).max() ?? 0)
    }
}

struct TypeSignature: Equatable, Sendable {
    let label: String
    let category: String
    let fileCount: Int
    let totalBytes: Int64
}

struct CategorySignature: Equatable, Sendable {
    let category: String
    let fileCount: Int
    let extensionCount: Int
    let totalBytes: Int64
}

struct GroupSignature: Equatable, Sendable {
    let byteSize: Int64
    let paths: [String]
}

struct VerifiedGroupSignature: Equatable, Sendable {
    let checksum: String
    let byteSize: Int64
    let paths: [String]
}

struct CandidateSignature: Equatable, Sendable {
    let kind: String
    let path: String
    let confidence: String
    let reason: String
    let reclaimableBytes: Int64
}

enum ScannerProofError: Error, CustomStringConvertible {
    case mismatch(context: String, detail: String)

    var description: String {
        switch self {
        case let .mismatch(context, detail):
            return "Scanner proof mismatch in \(context): \(detail)"
        }
    }
}

struct ScannerProofFixture {
    enum Kind: String, CaseIterable {
        case deepAndWide
        case mutationHeavy
        case hardLinks
        case cleanupCandidates
        case permissionLoss
        case volumeLoss
    }

    enum FaultKind: String {
        case permissionLoss
        case volumeLoss

        var error: Error {
            switch self {
            case .permissionLoss:
                return CocoaError(.fileReadNoPermission)
            case .volumeLoss:
                return CocoaError(.fileNoSuchFile)
            }
        }
    }

    struct FaultInjection {
        let relativePath: String
        let kind: FaultKind
    }

    struct HardLinkPair {
        let source: URL
        let alias: URL
    }

    enum Mutation: CustomStringConvertible {
        case create(relativePath: String, bytes: Int, seed: UInt8)
        case delete(relativePath: String)
        case rename(from: String, to: String)
        case resize(relativePath: String, bytes: Int, seed: UInt8)

        var description: String {
            switch self {
            case let .create(path, bytes, _): return "create \(path) (\(bytes) bytes)"
            case let .delete(path): return "delete \(path)"
            case let .rename(from, to): return "rename \(from) -> \(to)"
            case let .resize(path, bytes, _): return "resize \(path) (\(bytes) bytes)"
            }
        }

        func apply(in root: URL, fileManager: FileManager = FileManager()) throws {
            switch self {
            case let .create(relativePath, bytes, seed):
                let url = root.appendingPathComponent(relativePath)
                try fileManager.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Self.write(url: url, bytes: bytes, seed: seed)
            case let .delete(relativePath):
                try fileManager.removeItem(at: root.appendingPathComponent(relativePath))
            case let .rename(from, to):
                let destination = root.appendingPathComponent(to)
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(
                    at: root.appendingPathComponent(from),
                    to: destination
                )
            case let .resize(relativePath, bytes, seed):
                try Self.write(url: root.appendingPathComponent(relativePath), bytes: bytes, seed: seed)
            }
        }

        private static func write(url: URL, bytes: Int, seed: UInt8) throws {
            try Data(repeating: seed, count: bytes).write(to: url, options: .atomic)
        }
    }

    let kind: Kind
    let root: URL
    let fault: FaultInjection?
    let hardLinkPair: HardLinkPair?
    let mutations: [Mutation]

    func makeFileManager() -> FileManager {
        guard let fault else { return FileManager() }
        return FaultInjectingFileManager(
            failurePath: root.appendingPathComponent(fault.relativePath),
            failure: fault.kind
        )
    }

    func tearDown() {
        try? FileManager().removeItem(at: root)
    }

    static func make(
        _ kind: Kind,
        in parentDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> ScannerProofFixture {
        let fileManager = FileManager()
        let root = parentDirectory.appendingPathComponent(
            "StorageScopeProof-\(kind.rawValue)-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        do {
            switch kind {
            case .deepAndWide:
                try makeDeepAndWideFixture(root: root, fileManager: fileManager)
                return ScannerProofFixture(kind: kind, root: root, fault: nil, hardLinkPair: nil, mutations: [])
            case .mutationHeavy:
                let mutations = try makeMutationFixture(root: root, fileManager: fileManager)
                return ScannerProofFixture(kind: kind, root: root, fault: nil, hardLinkPair: nil, mutations: mutations)
            case .hardLinks:
                let pair = try makeHardLinkFixture(root: root, fileManager: fileManager)
                return ScannerProofFixture(kind: kind, root: root, fault: nil, hardLinkPair: pair, mutations: [])
            case .cleanupCandidates:
                try makeCleanupCandidateFixture(root: root, fileManager: fileManager)
                return ScannerProofFixture(kind: kind, root: root, fault: nil, hardLinkPair: nil, mutations: [])
            case .permissionLoss:
                let faultPath = try makeFaultFixture(root: root, fileManager: fileManager, folderName: "permission-lost")
                return ScannerProofFixture(
                    kind: kind,
                    root: root,
                    fault: FaultInjection(relativePath: faultPath, kind: .permissionLoss),
                    hardLinkPair: nil,
                    mutations: []
                )
            case .volumeLoss:
                let faultPath = try makeFaultFixture(root: root, fileManager: fileManager, folderName: "volume-disappears")
                return ScannerProofFixture(
                    kind: kind,
                    root: root,
                    fault: FaultInjection(relativePath: faultPath, kind: .volumeLoss),
                    hardLinkPair: nil,
                    mutations: []
                )
            }
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    private static func makeDeepAndWideFixture(root: URL, fileManager: FileManager) throws {
        var deepDirectory = root.appendingPathComponent("deep", isDirectory: true)
        for level in 0..<16 {
            try fileManager.createDirectory(at: deepDirectory, withIntermediateDirectories: true)
            try writeFile(
                at: deepDirectory.appendingPathComponent("level-\(String(format: "%02d", level)).dat"),
                bytes: 512 + level,
                seed: UInt8(level + 1)
            )
            deepDirectory = deepDirectory.appendingPathComponent("level-\(String(format: "%02d", level))", isDirectory: true)
        }

        let wideRoot = root.appendingPathComponent("wide", isDirectory: true)
        for bucket in 0..<8 {
            let bucketURL = wideRoot.appendingPathComponent("bucket-\(String(format: "%02d", bucket))", isDirectory: true)
            try fileManager.createDirectory(at: bucketURL, withIntermediateDirectories: true)
            for index in 0..<64 {
                try writeFile(
                    at: bucketURL.appendingPathComponent("file-\(String(format: "%03d", index)).bin"),
                    bytes: 1_024 + index + bucket,
                    seed: UInt8((index + bucket) % 200 + 1)
                )
            }
        }
    }

    private static func makeMutationFixture(root: URL, fileManager: FileManager) throws -> [Mutation] {
        let mutationRoot = root.appendingPathComponent("mutation", isDirectory: true)
        for branch in 0..<4 {
            let branchURL = mutationRoot.appendingPathComponent("branch-\(String(format: "%02d", branch))", isDirectory: true)
            try fileManager.createDirectory(at: branchURL, withIntermediateDirectories: true)
            for file in 0..<12 {
                try writeFile(
                    at: branchURL.appendingPathComponent("file-\(String(format: "%02d", file)).dat"),
                    bytes: 1_000 + branch * 100 + file,
                    seed: UInt8((branch * 12 + file) % 200 + 1)
                )
            }
        }

        return [
            .create(relativePath: "mutation/incoming/new-00.dat", bytes: 4_096, seed: 80),
            .resize(relativePath: "mutation/branch-00/file-00.dat", bytes: 8_192, seed: 81),
            .rename(from: "mutation/branch-01/file-01.dat", to: "mutation/branch-01/renamed-01.dat"),
            .delete(relativePath: "mutation/branch-02/file-02.dat"),
            .create(relativePath: "mutation/branch-03/nested/new-03.dat", bytes: 2_048, seed: 82),
            .rename(from: "mutation/branch-00", to: "mutation/renamed-branch-00"),
            .delete(relativePath: "mutation/branch-03/nested/new-03.dat"),
            .create(relativePath: "mutation/renamed-branch-00/roundtrip.dat", bytes: 3_072, seed: 83),
            .resize(relativePath: "mutation/renamed-branch-00/roundtrip.dat", bytes: 6_144, seed: 84),
            .create(relativePath: "mutation/branch-02/recreated-02.dat", bytes: 1_536, seed: 85),
            .rename(from: "mutation/incoming", to: "mutation/received"),
            .delete(relativePath: "mutation/received/new-00.dat")
        ]
    }

    private static func makeHardLinkFixture(root: URL, fileManager: FileManager) throws -> HardLinkPair {
        let directory = root.appendingPathComponent("hard-links", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let source = directory.appendingPathComponent("original.bin")
        let alias = directory.appendingPathComponent("alias.bin")
        try writeFile(at: source, bytes: 32_768, seed: 91)
        try fileManager.linkItem(at: source, to: alias)
        try writeFile(at: directory.appendingPathComponent("different.bin"), bytes: 32_769, seed: 92)

        return HardLinkPair(source: source, alias: alias)
    }

    private static func makeCleanupCandidateFixture(root: URL, fileManager: FileManager) throws {
        let caches = root.appendingPathComponent("Caches", isDirectory: true)
        let derivedData = root.appendingPathComponent("DerivedData", isDirectory: true)
        let archives = root.appendingPathComponent("archives", isDirectory: true)
        let installers = root.appendingPathComponent("installers", isDirectory: true)
        try [caches, derivedData, archives, installers].forEach {
            try fileManager.createDirectory(at: $0, withIntermediateDirectories: true)
        }

        try writeFile(at: caches.appendingPathComponent("payload.bin"), bytes: 1_024, seed: 111)
        try writeFile(at: derivedData.appendingPathComponent("project.o"), bytes: 2_048, seed: 112)
        try writeFile(at: archives.appendingPathComponent("archive.zip"), bytes: 3_072, seed: 113)
        try writeFile(at: installers.appendingPathComponent("installer.dmg"), bytes: 4_096, seed: 114)
        try writeFile(at: root.appendingPathComponent("temporary.tmp"), bytes: 5_120, seed: 115)
        try writeFile(at: root.appendingPathComponent("keep.txt"), bytes: 6_144, seed: 116)
    }

    private static func makeFaultFixture(
        root: URL,
        fileManager: FileManager,
        folderName: String
    ) throws -> String {
        let healthy = root.appendingPathComponent("healthy", isDirectory: true)
        let faulted = root.appendingPathComponent(folderName, isDirectory: true)
        try fileManager.createDirectory(at: healthy, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: faulted, withIntermediateDirectories: true)
        try writeFile(at: healthy.appendingPathComponent("survives.txt"), bytes: 2_048, seed: 101)
        try writeFile(at: faulted.appendingPathComponent("should-not-be-visible.txt"), bytes: 2_048, seed: 102)
        return folderName
    }

    private static func writeFile(at url: URL, bytes: Int, seed: UInt8) throws {
        try Data(repeating: seed, count: bytes).write(to: url, options: .atomic)
    }
}

private final class FaultInjectingFileManager: FileManager {
    private let failurePath: String
    private let failure: ScannerProofFixture.FaultKind

    init(failurePath: URL, failure: ScannerProofFixture.FaultKind) {
        self.failurePath = failurePath.standardizedFileURL.path
        self.failure = failure
        super.init()
    }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        if url.standardizedFileURL.path == failurePath {
            throw failure.error
        }
        return try super.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: mask
        )
    }
}
