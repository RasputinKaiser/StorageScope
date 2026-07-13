import Foundation
import Testing
@testable import StorageScopeCore

@Suite("Incremental rescanning")
struct IncrementalScanTests {
    @Test("system FSEvents source replays a file mutation after a checkpoint")
    func systemFSEventsSourceReplaysMutation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageScopeFSEventsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = SystemFSEventsChangeSource()
        let checkpoint = source.currentEventID()
        let changedFile = root.appendingPathComponent("changed.bin")
        try Data(repeating: 0xF5, count: 128).write(to: changedFile)

        var observed = IncrementalChangeSet(paths: [], requiresFullScan: false, reason: nil)
        let canonicalRootPath = IncrementalPathIdentity.canonicalPath(root.path)
        let canonicalChangedPath = IncrementalPathIdentity.canonicalPath(changedFile.path)
        for _ in 0..<20 {
            observed = source.changes(rootURL: root, since: checkpoint)
            if observed.requiresFullScan || observed.paths.contains(where: {
                $0 == canonicalRootPath || $0 == canonicalChangedPath
            }) {
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        #expect(!observed.requiresFullScan)
        #expect(observed.paths.contains(where: { $0 == canonicalRootPath || $0 == canonicalChangedPath }))
    }

    @Test("live FSEvents monitor prevents an immediate rescan from returning stale memory")
    func liveMonitorCatchesImmediateMutation() throws {
        let fixture = try IncrementalFixture()
        defer { fixture.tearDown() }
        try fixture.seed()

        let scanner = fixture.scanner(changeSource: SystemFSEventsChangeSource())
        _ = try scanner.scan(root: fixture.root, options: fixture.options)
        let changedFile = fixture.root.appendingPathComponent("changed/immediate.bin")
        try Data(repeating: 0xAB, count: 2_048).write(to: changedFile)

        let incremental = try scanner.scan(root: fixture.root, options: fixture.options)
        let full = try fixture.fullScanner().scan(root: fixture.root, options: fixture.options)
        #expect(incremental.rescanKind == .incrementalChanged)
        #expect(ScannerProofHarness.signature(of: incremental, root: fixture.root) ==
            ScannerProofHarness.signature(of: full, root: fixture.root))
    }

    @Test("unchanged rescan reuses the persisted tree with exact scan parity")
    func unchangedRescanUsesPersistedTree() throws {
        let fixture = try IncrementalFixture()
        defer { fixture.tearDown() }
        try fixture.seed()

        let source = TestIncrementalChangeSource(eventID: 100)
        let scanner = fixture.scanner(changeSource: source)
        let first = try scanner.scan(root: fixture.root, options: fixture.options)
        let second = try scanner.scan(root: fixture.root, options: fixture.options)

        #expect(first.rescanKind == .full)
        #expect(first.incrementalFallbackReason == IncrementalScanFallback.persistenceMissing.rawValue)
        #expect(second.rescanKind == .incrementalUnchanged)
        #expect(second.incrementalDirtySubtreeCount == 0)
        #expect(ScannerProofHarness.signature(of: first, root: fixture.root) ==
            ScannerProofHarness.signature(of: second, root: fixture.root))
    }

    @Test("pre-cancelled unchanged rescan does not bypass cancellation through memory reuse")
    func preCancelledUnchangedRescanStillCancels() throws {
        let fixture = try IncrementalFixture()
        defer { fixture.tearDown() }
        try fixture.seed()

        let source = TestIncrementalChangeSource(eventID: 150)
        let scanner = fixture.scanner(changeSource: source)
        _ = try scanner.scan(root: fixture.root, options: fixture.options)
        let cancellation = ScanCancellation()
        cancellation.cancel()

        let error = #expect(throws: FileSystemScannerError.self) {
            _ = try scanner.scan(
                root: fixture.root,
                options: fixture.options,
                cancellation: cancellation
            )
        }
        if let error {
            guard case .cancelled = error else {
                Issue.record("Expected cancellation, got \(error)")
                return
            }
        }
    }

    @Test("single dirty subtree is rescanned and spliced with full-scan parity")
    func dirtySubtreeIsSpliced() throws {
        let fixture = try IncrementalFixture()
        defer { fixture.tearDown() }
        try fixture.seed()

        let source = TestIncrementalChangeSource(eventID: 200)
        let scanner = fixture.scanner(changeSource: source)
        _ = try scanner.scan(root: fixture.root, options: fixture.options)

        let changedFile = fixture.root.appendingPathComponent("changed/new.bin")
        try Data(repeating: 0xCC, count: 4_096).write(to: changedFile)
        source.set(
            eventID: 201,
            changes: IncrementalChangeSet(paths: [changedFile.path], requiresFullScan: false, reason: nil)
        )

        let incremental = try scanner.scan(root: fixture.root, options: fixture.options)
        let full = try fixture.fullScanner().scan(root: fixture.root, options: fixture.options)

        #expect(incremental.rescanKind == .incrementalChanged)
        #expect(incremental.incrementalDirtySubtreeCount == 1)
        #expect(ScannerProofHarness.signature(of: incremental, root: fixture.root) ==
            ScannerProofHarness.signature(of: full, root: fixture.root))
    }

    @Test("create delete rename and resize stay exact across one thousand generated mutations")
    func generatedMutationCampaignMaintainsParity() throws {
        let fixture = try IncrementalFixture()
        defer { fixture.tearDown() }
        try fixture.seedMutationCampaign()

        let source = TestIncrementalChangeSource(eventID: 1_000)
        let scanner = fixture.scanner(changeSource: source)
        _ = try scanner.scan(root: fixture.root, options: fixture.options)

        var anchorNames = (0..<10).map { _ in "anchor-a.bin" }
        var touchedDirectories: Set<String> = []
        for index in 0..<1_000 {
            let directoryIndex = index % 10
            let directory = fixture.root.appendingPathComponent("mutation-\(directoryIndex)", isDirectory: true)
            touchedDirectories.insert(directory.path)
            switch index % 4 {
            case 0:
                try Data(repeating: UInt8(index % 251), count: 64 + index).write(
                    to: directory.appendingPathComponent("created-\(index).bin")
                )
            case 1:
                try Data(repeating: UInt8(index % 251), count: 128 + index).write(
                    to: directory.appendingPathComponent(anchorNames[directoryIndex])
                )
            case 2:
                let oldName = anchorNames[directoryIndex]
                let newName = oldName == "anchor-a.bin" ? "anchor-b.bin" : "anchor-a.bin"
                try FileManager.default.moveItem(
                    at: directory.appendingPathComponent(oldName),
                    to: directory.appendingPathComponent(newName)
                )
                anchorNames[directoryIndex] = newName
            default:
                let createdIndex = index - 3
                let createdDirectory = fixture.root.appendingPathComponent(
                    "mutation-\(createdIndex % 10)",
                    isDirectory: true
                )
                touchedDirectories.insert(createdDirectory.path)
                try FileManager.default.removeItem(
                    at: createdDirectory.appendingPathComponent("created-\(createdIndex).bin")
                )
            }

            if (index + 1).isMultiple(of: 25) {
                source.set(
                    eventID: UInt64(1_001 + index),
                    changes: IncrementalChangeSet(
                        paths: touchedDirectories.sorted(),
                        requiresFullScan: false,
                        reason: nil
                    )
                )
                let incremental = try scanner.scan(root: fixture.root, options: fixture.options)
                let full = try fixture.fullScanner().scan(root: fixture.root, options: fixture.options)
                #expect(incremental.rescanKind == .incrementalChanged)
                #expect(ScannerProofHarness.signature(of: incremental, root: fixture.root) ==
                    ScannerProofHarness.signature(of: full, root: fixture.root))
                touchedDirectories.removeAll(keepingCapacity: true)
            }
        }
    }

    @Test("event overflow falls back to a full scan")
    func eventOverflowFallsBack() throws {
        let fixture = try IncrementalFixture()
        defer { fixture.tearDown() }
        try fixture.seed()

        let source = TestIncrementalChangeSource(eventID: 300)
        let scanner = fixture.scanner(changeSource: source)
        _ = try scanner.scan(root: fixture.root, options: fixture.options)
        source.set(
            eventID: 301,
            changes: IncrementalChangeSet(paths: [fixture.root.path], requiresFullScan: true, reason: "event-log-overflow")
        )

        let scan = try scanner.scan(root: fixture.root, options: fixture.options)
        #expect(scan.rescanKind == .full)
        #expect(scan.incrementalFallbackReason == "event-log-overflow")
    }

    @Test("changed traversal options fall back to a full scan")
    func traversalOptionsChangeFallsBack() throws {
        let fixture = try IncrementalFixture()
        defer { fixture.tearDown() }
        try fixture.seed()

        let source = TestIncrementalChangeSource(eventID: 400)
        let scanner = fixture.scanner(changeSource: source)
        _ = try scanner.scan(root: fixture.root, options: fixture.options)
        var changedOptions = fixture.options
        changedOptions.includeHidden.toggle()

        let scan = try scanner.scan(root: fixture.root, options: changedOptions)
        #expect(scan.rescanKind == .full)
        #expect(scan.incrementalFallbackReason == IncrementalScanFallback.optionsChanged.rawValue)
    }

    @Test("corrupt persistence falls back to a full scan and regenerates")
    func corruptPersistenceFallsBack() throws {
        let fixture = try IncrementalFixture()
        defer { fixture.tearDown() }
        try fixture.seed()

        let source = TestIncrementalChangeSource(eventID: 500)
        let scanner = fixture.scanner(changeSource: source)
        _ = try scanner.scan(root: fixture.root, options: fixture.options)
        try Data("not-json".utf8).write(to: fixture.persistence.cacheURL(rootURL: fixture.root), options: .atomic)

        let recovered = try scanner.scan(root: fixture.root, options: fixture.options)
        let next = try scanner.scan(root: fixture.root, options: fixture.options)
        #expect(recovered.rescanKind == .full)
        #expect(recovered.incrementalFallbackReason == IncrementalScanFallback.persistenceCorrupt.rawValue)
        #expect(next.rescanKind == .incrementalUnchanged)
    }

    @Test("incompatible schema and volume identity fall back instead of using stale state", arguments: [
        ("schemaVersion", IncrementalScanFallback.schemaIncompatible.rawValue),
        ("volumeIdentity", IncrementalScanFallback.volumeChanged.rawValue)
    ])
    func incompatibleMetadataFallsBack(field: String, expectedReason: String) throws {
        let fixture = try IncrementalFixture()
        defer { fixture.tearDown() }
        try fixture.seed()

        let source = TestIncrementalChangeSource(eventID: 600)
        let scanner = fixture.scanner(changeSource: source)
        _ = try scanner.scan(root: fixture.root, options: fixture.options)
        let cacheURL = fixture.persistence.cacheURL(rootURL: fixture.root)
        var plist = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: cacheURL),
            options: [],
            format: nil
        ) as? [String: Any])
        plist[field] = field == "schemaVersion" ? 999 : "different-volume"
        try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        ).write(to: cacheURL, options: .atomic)

        let scan = try scanner.scan(root: fixture.root, options: fixture.options)
        #expect(scan.rescanKind == .full)
        #expect(scan.incrementalFallbackReason == expectedReason)
    }

    @Test("inconsistent parent child persistence falls back to a full scan")
    func inconsistentStateFallsBack() throws {
        let fixture = try IncrementalFixture()
        defer { fixture.tearDown() }
        try fixture.seed()

        let source = TestIncrementalChangeSource(eventID: 700)
        let scanner = fixture.scanner(changeSource: source)
        _ = try scanner.scan(root: fixture.root, options: fixture.options)
        let cacheURL = fixture.persistence.cacheURL(rootURL: fixture.root)
        var plist = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: cacheURL),
            options: [],
            format: nil
        ) as? [String: Any])
        var nodes = try #require(plist["nodes"] as? [[String: Any]])
        var child = try #require(nodes.dropFirst().first)
        child["parentID"] = 999
        nodes[1] = child
        plist["nodes"] = nodes
        try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        ).write(to: cacheURL, options: .atomic)

        let scan = try scanner.scan(root: fixture.root, options: fixture.options)
        #expect(scan.rescanKind == .full)
        #expect(scan.incrementalFallbackReason == IncrementalScanFallback.stateInconsistent.rawValue)
    }
}

private final class TestIncrementalChangeSource: IncrementalChangeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var eventID: UInt64
    private var result = IncrementalChangeSet(paths: [], requiresFullScan: false, reason: nil)

    init(eventID: UInt64) {
        self.eventID = eventID
    }

    func set(eventID: UInt64, changes: IncrementalChangeSet) {
        lock.lock()
        self.eventID = eventID
        result = changes
        lock.unlock()
    }

    func currentEventID() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return eventID
    }

    func changes(rootURL: URL, since eventID: UInt64) -> IncrementalChangeSet {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

private final class IncrementalFixture {
    let root: URL
    let cache: URL
    let persistence: IncrementalScanPersistence
    let options = ScanOptions(
        oldFileAgeDays: 180,
        largeFileThreshold: 1,
        duplicateCandidateThreshold: 1,
        duplicateVerificationByteLimit: 0,
        maxDuplicateVerificationFiles: 0,
        maxDuplicateCandidateItems: 10_000,
        maxRankedResults: 10_000,
        maxChildrenPerDirectory: 10_000,
        maxRetainedItems: 100_000
    )

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageScopeIncrementalTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("root", isDirectory: true)
        cache = base.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        persistence = IncrementalScanPersistence(baseURL: cache)
    }

    func seed() throws {
        for name in ["changed", "unchanged"] {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for index in 0..<8 {
                try Data(repeating: UInt8(index), count: 256 + index).write(
                    to: directory.appendingPathComponent("file-\(index).bin")
                )
            }
        }
    }

    func seedMutationCampaign() throws {
        for index in 0..<10 {
            let directory = root.appendingPathComponent("mutation-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: UInt8(index), count: 128).write(
                to: directory.appendingPathComponent("anchor-a.bin")
            )
        }
    }

    func scanner(changeSource: IncrementalChangeSource) -> FileSystemScanner {
        FileSystemScanner(
            fileManager: FileManager(),
            walkerMode: .fixedWorker,
            incrementalPersistence: persistence,
            incrementalChangeSource: changeSource,
            incrementalTrustButVerify: false
        )
    }

    func fullScanner() -> FileSystemScanner {
        FileSystemScanner(fileManager: FileManager(), walkerMode: .fixedWorker)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}
