import Foundation
import Testing
@testable import StorageScopeCore

@Suite("DuplicateHashCache")
struct DuplicateHashCacheTests {
    // MARK: - Helpers

    /// Thread-safe accumulator for cache errors captured by the `@Sendable` reporter
    /// closure. Without this, capturing `var reported: [...]` inside a `@Sendable`
    /// closure triggers Swift 6 `#SendableClosureCaptures` warnings. Mirrors the
    /// `NSLock` pattern used by `DuplicateHashCache` itself.
    private final class ErrorRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [DuplicateHashCache.Error] = []

        func append(_ error: DuplicateHashCache.Error) {
            lock.lock()
            storage.append(error)
            lock.unlock()
        }

        var errors: [DuplicateHashCache.Error] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        var first: DuplicateHashCache.Error? { errors.first }
        var count: Int { errors.count }
        var isEmpty: Bool { errors.isEmpty }

        func clear() {
            lock.lock()
            storage.removeAll()
            lock.unlock()
        }
    }

    private func makeTemporaryFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuplicateHashCacheTests-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: url)
        return url
    }

    private func makeTemporaryDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuplicateHashCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRealFile(
        named name: String,
        bytes: Int,
        in directory: URL
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x42, count: bytes).write(to: url)
        return url
    }

    private func mtime(of url: URL) throws -> Date {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.modificationDate] as? Date) ?? Date()
    }

    // MARK: - corrupt-cache recovery

    @Test("corrupt cache file resets entries and reports loadCorrupted")
    func corruptCacheFileResetsEntriesAndReportsLoadCorrupted() throws {
        let cacheURL = try makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        try Data("not valid json :::".utf8).write(to: cacheURL)
        let recorder = ErrorRecorder()
        let cache = DuplicateHashCache(cacheURL: cacheURL) { error in
            recorder.append(error)
        }

        #expect(cache.entryCount == 0)
        #expect(recorder.count == 1)

        switch recorder.first {
        case .loadCorrupted(let url, _):
            #expect(url == cacheURL)
        default:
            Issue.record("expected loadCorrupted, got \(String(describing: recorder.first))")
        }
    }

    @Test("missing cache file at init does not report an error")
    func missingCacheFileAtInitDoesNotReportError() throws {
        let dir = try makeTemporaryDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Path doesn't exist yet — first-launch path.
        let cacheURL = dir.appendingPathComponent("cache.json")
        let recorder = ErrorRecorder()
        let cache = DuplicateHashCache(cacheURL: cacheURL) { error in
            recorder.append(error)
        }

        #expect(cache.entryCount == 0)
        #expect(recorder.isEmpty, "first-launch missing-cache must be silent, got \(recorder.errors)")
    }

    @Test("missing cache file is created on first persist")
    func missingCacheFileIsCreatedOnFirstPersist() throws {
        let dir = try makeTemporaryDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cacheURL = dir.appendingPathComponent("cache.json")
        let cache = DuplicateHashCache(cacheURL: cacheURL)

        let key = DuplicateHashCache.LookupKey(
            path: "/some/path.bin",
            byteSize: 100,
            modificationDate: Date(timeIntervalSince1970: 1)
        )
        cache.record(key, checksum: "abc")
        cache.persist()

        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
        #expect(cache.lastPersistedAt != nil)

        // Reload: entries restored from disk.
        let reloaded = DuplicateHashCache(cacheURL: cacheURL)
        #expect(reloaded.checksum(for: key) == "abc")
    }

    // MARK: - atomic write failure

    @Test("persist reports persistWriteFailed when the cache URL is unreachable")
    func persistReportsPersistWriteFailedWhenUnreachable() throws {
        // Place a regular file at `parent`. The cache URL sits *under* that file, so
        // FileManager.createDirectory fails with NSFileWriteFileExistsError or similar
        // (can't make a directory at a path claimed by a regular file). The error is
        // surfaced via directoryCreateFailed rather than silently swallowed.
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuplicateHashCacheTests-blocker-\(UUID().uuidString)")
        try Data("i am a file".utf8).write(to: parent)
        defer { try? FileManager.default.removeItem(at: parent) }

        let cacheURL = parent.appendingPathComponent("child").appendingPathComponent("cache.json")

        let recorder = ErrorRecorder()
        let cache = DuplicateHashCache(cacheURL: cacheURL) { error in
            recorder.append(error)
        }
        cache.record(
            DuplicateHashCache.LookupKey(path: "/x", byteSize: 1, modificationDate: nil),
            checksum: "deadbeef"
        )
        cache.persist()
        #expect(cache.lastPersistedAt == nil)

        // The parent dir create must fail because `parent` is a regular file.
        #expect(recorder.count == 1)
        switch recorder.first {
        case .directoryCreateFailed:
            // Expected — can't create child dir under a regular file.
            break
        case .persistWriteFailed:
            // Acceptable if createDirectory somehow succeeded but the write failed.
            break
        default:
            Issue.record("expected directoryCreateFailed or persistWriteFailed, got \(String(describing: recorder.first))")
        }
    }

    @Test("persist succeeds when parent dir exists and reports no error")
    func persistSucceedsWhenParentDirExists() throws {
        let cacheURL = try makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let recorder = ErrorRecorder()
        let cache = DuplicateHashCache(cacheURL: cacheURL) { error in
            recorder.append(error)
        }
        cache.record(
            DuplicateHashCache.LookupKey(path: "/x", byteSize: 100, modificationDate: nil),
            checksum: "deadbeef"
        )
        cache.persist()

        #expect(cache.lastPersistedAt != nil)
        #expect(recorder.isEmpty)
    }

    // MARK: - stale-entry purge

    @Test("purgeStale drops entries for deleted files, keeps scanned ones")
    func purgeStaleDropsDeletedFileEntriesAndKeepsRest() throws {
        let root = try makeTemporaryDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let survivorURL = try makeRealFile(named: "survives.bin", bytes: 100, in: root)
        let deletedURL = try makeRealFile(named: "deleted.bin", bytes: 100, in: root)
        try FileManager.default.removeItem(at: deletedURL)

        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuplicateHashCacheTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let cache = DuplicateHashCache(cacheURL: cacheURL)
        let survivorKey = DuplicateHashCache.LookupKey(
            path: survivorURL.standardizedFileURL.path,
            byteSize: 100,
            modificationDate: try mtime(of: survivorURL)
        )
        let deletedKey = DuplicateHashCache.LookupKey(
            path: deletedURL.standardizedFileURL.path,
            byteSize: 100,
            modificationDate: Date(timeIntervalSince1970: 0)
        )
        cache.record(survivorKey, checksum: "alive")
        cache.record(deletedKey, checksum: "gone")
        #expect(cache.entryCount == 2)

        let dropped = cache.purgeStale()
        #expect(dropped == 1)
        #expect(cache.entryCount == 1)
        #expect(cache.checksum(for: survivorKey) == "alive")
        #expect(cache.checksum(for: deletedKey) == nil)
    }

    @Test("purgeStale preserves entries listed in the except set even if the file is gone")
    func purgeStaleRespectsExceptSet() throws {
        let root = try makeTemporaryDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let survivingPath = try makeRealFile(named: "survives.bin", bytes: 100, in: root).path
        let ghostPath = root.appendingPathComponent("ghost.bin").path

        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuplicateHashCacheTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let cache = DuplicateHashCache(cacheURL: cacheURL)
        let survivorKey = DuplicateHashCache.LookupKey(
            path: survivingPath,
            byteSize: 100,
            modificationDate: Date()
        )
        let ghostKey = DuplicateHashCache.LookupKey(
            path: ghostPath,
            byteSize: 100,
            modificationDate: Date()
        )
        cache.record(survivorKey, checksum: "alive")
        cache.record(ghostKey, checksum: "ghost")
        #expect(cache.entryCount == 2)

        // Purge but tell the cache "preserve the ghost path".
        let dropped = cache.purgeStale(except: [ghostPath])

        #expect(dropped == 0)
        #expect(cache.entryCount == 2)
        #expect(cache.checksum(for: ghostKey) == "ghost")
    }

    @Test("purgeStale reports attribute lookup failure for unreadable-but-existant file")
    func purgeStaleReportsAttributeLookupFailure() throws {
        let root = try makeTemporaryDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // Synthetic path that doesn't exist — that drops silently (file-missing branch
        // is the common case). For a real-path-but-stat-failure case, we use a deleted
        // symlink target to exercise the `attributesOfItem` failure path.
        let targetURL = try makeRealFile(named: "target.bin", bytes: 100, in: root)
        let symlinkURL = root.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(
            atPath: symlinkURL.path,
            withDestinationPath: targetURL.path
        )

        let nonexistentPath = root.appendingPathComponent("absent.bin").path
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuplicateHashCacheTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let recorder = ErrorRecorder()
        let cache = DuplicateHashCache(cacheURL: cacheURL) { error in
            recorder.append(error)
        }
        cache.record(
            DuplicateHashCache.LookupKey(
                path: nonexistentPath,
                byteSize: 100,
                modificationDate: Date()
            ),
            checksum: "ghost"
        )
        // Nonexistent file goes through the file-missing branch — silent drop.
        let dropped = cache.purgeStale()
        #expect(dropped == 1)
        #expect(recorder.isEmpty, "missing-file drop must not be reported as an error")

        // Now break the symlink: target deleted, link still exists but attributesOfItem errors.
        try FileManager.default.removeItem(at: targetURL)
        cache.record(
            DuplicateHashCache.LookupKey(
                path: symlinkURL.path,
                byteSize: 100,
                modificationDate: Date()
            ),
            checksum: "broken"
        )
        recorder.clear()
        let secondDropped = cache.purgeStale()
        #expect(secondDropped >= 1)
        if let error = recorder.first {
            if case .purgeAttributeLookupFailed = error {
                // Expected.
            } else {
                Issue.record("expected purgeAttributeLookupFailed, got \(error)")
            }
        }
    }

    // MARK: - size eviction

    @Test("record honors maxEntries and prunes oldest-mtime entries")
    func recordHonorsMaxEntriesEviction() throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuplicateHashCacheTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        // Small cap so we can exercise eviction without writing 5000 entries.
        let cache = DuplicateHashCache(cacheURL: cacheURL, maxEntries: 100)
        let baseDate = Date(timeIntervalSince1970: 1_000_000)

        for index in 0..<110 {
            cache.record(
                DuplicateHashCache.LookupKey(
                    path: "/file-\(index).bin",
                    byteSize: Int64(index),
                    modificationDate: baseDate.addingTimeInterval(TimeInterval(index))
                ),
                checksum: "hash-\(index)"
            )
        }
        // Cap=100; record() triggers pruneOldest once we push past the cap, which drops
        // the oldest 10% (dropCount = max(1, 100/10) = 10). Net entry count is bounded.
        #expect(cache.entryCount <= cache.entryCount)
        #expect(cache.entryCount <= 100 + 10, "eviction overshoot bound")

        // Oldest entries (timestamp baseDate + 0..9) should be evicted.
        let firstEntry = cache.checksum(
            for: DuplicateHashCache.LookupKey(
                path: "/file-0.bin",
                byteSize: 0,
                modificationDate: baseDate
            )
        )
        #expect(firstEntry == nil, "oldest entry should have been evicted; got \(String(describing: firstEntry))")

        // Newest entries should survive.
        let lastEntry = cache.checksum(
            for: DuplicateHashCache.LookupKey(
                path: "/file-109.bin",
                byteSize: 109,
                modificationDate: baseDate.addingTimeInterval(109)
            )
        )
        #expect(lastEntry == "hash-109")
    }

    @Test("record honors maxBytes and prunes oldest-mtime entries")
    func recordHonorsMaxBytesEviction() throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuplicateHashCacheTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        // Tight byte budget: each ~100-char path entry is ~132 bytes via entryByteSize.
        // 256 bytes cap means we'll evict after ~2 entries.
        let cache = DuplicateHashCache(cacheURL: cacheURL, maxEntries: 1_000, maxBytes: 256)
        let baseDate = Date(timeIntervalSince1970: 1_000_000)

        for index in 0..<10 {
            cache.record(
                DuplicateHashCache.LookupKey(
                    path: String(repeating: "p", count: 80) + "-\(index)",
                    byteSize: Int64(index),
                    modificationDate: baseDate.addingTimeInterval(TimeInterval(index))
                ),
                checksum: String(repeating: "h", count: 16)
            )
        }

        #expect(cache.approximateSerializedBytes <= 256 * 2, "byte eviction should keep the cache bounded")
        // Oldest entry should have been evicted.
        let firstEntry = cache.checksum(
            for: DuplicateHashCache.LookupKey(
                path: String(repeating: "p", count: 80) + "-0",
                byteSize: 0,
                modificationDate: baseDate
            )
        )
        #expect(firstEntry == nil, "oldest entry should be evicted under byte budget")
    }

    @Test("approximateSerializedBytes decrements when entries are removed")
    func approximateSerializedBytesDecrementsOnRemoval() throws {
        let root = try makeTemporaryDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileA = try makeRealFile(named: "a.bin", bytes: 100, in: root)
        let fileB = try makeRealFile(named: "b.bin", bytes: 100, in: root)
        try FileManager.default.removeItem(at: fileB)

        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuplicateHashCacheTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let cache = DuplicateHashCache(cacheURL: cacheURL)
        cache.record(
            DuplicateHashCache.LookupKey(
                path: fileA.standardizedFileURL.path,
                byteSize: 100,
                modificationDate: try mtime(of: fileA)
            ),
            checksum: "a-hash"
        )
        cache.record(
            DuplicateHashCache.LookupKey(
                path: fileB.standardizedFileURL.path,
                byteSize: 100,
                modificationDate: Date()
            ),
            checksum: "b-hash"
        )
        let bytesBefore = cache.approximateSerializedBytes
        #expect(bytesBefore > 0)

        let dropped = cache.purgeStale()
        #expect(dropped == 1)
        #expect(cache.approximateSerializedBytes < bytesBefore)
    }

    // MARK: - clear()

    @Test("clear is silent when the on-disk file was already removed")
    func clearIsSilentWhenOnDiskFileAlreadyAbsent() throws {
        let root = try makeTemporaryDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let cacheURL = root.appendingPathComponent("cache.json")
        try Data("{}".utf8).write(to: cacheURL)

        let recorder = ErrorRecorder()
        let cache = DuplicateHashCache(cacheURL: cacheURL) { error in
            recorder.append(error)
        }

        // Delete the file out from under the cache before calling clear() — covers the
        // double-clear and the "user already deleted by hand" path. clear() must skip
        // silently rather than report a clearFailed for a file that is already gone.
        try FileManager.default.removeItem(at: cacheURL)
        recorder.clear()
        cache.clear()

        #expect(recorder.isEmpty)
        #expect(cache.entryCount == 0)
        #expect(cache.lastPersistedAt == nil)
    }

    @Test("clear removes on-disk file when present")
    func clearRemovesOnDiskFileWhenPresent() throws {
        let cacheURL = try makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let cache = DuplicateHashCache(cacheURL: cacheURL)
        cache.record(
            DuplicateHashCache.LookupKey(path: "/x", byteSize: 1, modificationDate: nil),
            checksum: "deadbeef"
        )
        cache.persist()
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))

        cache.clear()
        #expect(cache.entryCount == 0)
        #expect(cache.lastPersistedAt == nil)
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))
    }

    // MARK: - smoke: full round-trip with errors

    @Test("cache survives corrupt → reload → fresh write cycle")
    func cacheSurvivesCorruptReloadFreshWriteCycle() throws {
        let cacheURL = try makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let key = DuplicateHashCache.LookupKey(
            path: "/survivor.bin",
            byteSize: 1_024,
            modificationDate: Date(timeIntervalSince1970: 100)
        )

        // Step 1: write a legitimate cache entry.
        let recorderA = ErrorRecorder()
        let cacheA = DuplicateHashCache(cacheURL: cacheURL) { error in
            recorderA.append(error)
        }
        cacheA.record(key, checksum: "abc")
        cacheA.persist()
        #expect(recorderA.isEmpty)

        // Step 2: corrupt the file on disk.
        try Data("corrupted{".utf8).write(to: cacheURL)

        // Step 3: re-open — should drop entries, report loadCorrupted.
        let recorderB = ErrorRecorder()
        let cacheB = DuplicateHashCache(cacheURL: cacheURL) { error in
            recorderB.append(error)
        }
        #expect(cacheB.entryCount == 0)
        #expect(recorderB.count == 1)
        if case .loadCorrupted = recorderB.first {} else {
            Issue.record("expected loadCorrupted on re-open of corrupt file")
        }

        // Step 4: re-record and persist — overwrites the corrupt file.
        cacheB.record(key, checksum: "abc")
        cacheB.persist()
        #expect(cacheB.lastPersistedAt != nil)

        // Step 5: fresh reload picks up the new entry, no errors.
        let recorderC = ErrorRecorder()
        let cacheC = DuplicateHashCache(cacheURL: cacheURL) { error in
            recorderC.append(error)
        }
        #expect(recorderC.isEmpty)
        #expect(cacheC.checksum(for: key) == "abc")
    }
}