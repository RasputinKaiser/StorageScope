import Foundation

/// Persisted full and prefix SHA-256 digests for duplicate verification.
/// Scanner lookups require size, mtime, inode, and change stamps.
/// Keeps rescans fast: unchanged files skip hashing entirely.
public final class DuplicateHashCache: @unchecked Sendable {
    public struct LookupKey: Hashable, Sendable {
        public let path: String
        public let byteSize: Int64
        public let modificationDate: Date?
        public let identity: String?

        public init(path: String, byteSize: Int64, modificationDate: Date?, identity: String? = nil) {
            self.path = path
            self.byteSize = byteSize
            self.modificationDate = modificationDate
            self.identity = identity
        }
    }

    /// Errors raised when persist/load/clear/purge operations previously failed
    /// silently under `try?`. Forwarded to the `reportError` closure supplied at init
    /// so callers can route them into telemetry / alert UI. The cache itself continues
    /// best-effort on failure (in-memory state stays intact; on-disk file stays stale
    /// until the next successful write).
    public enum Error: Swift.Error, CustomStringConvertible, Equatable {
        /// The on-disk cache file exists but could not be read or decoded. The cache
        /// discards its in-memory state and starts fresh; the corrupt file remains
        /// on disk until the next successful `persist()` overwrites it.
        case loadCorrupted(url: URL, underlyingDescription: String?)
        /// `attributesOfItem` failed on the cache URL itself in
        /// `lastPersistedFromFile()` — could not read its mtime.
        case cacheAttributeLookupFailed(url: URL, underlyingDescription: String?)
        /// `FileManager.createDirectory` on the cache's parent directory failed;
        /// `persist()` will not attempt the write.
        case directoryCreateFailed(url: URL, underlyingDescription: String)
        /// `JSONEncoder.encode(_:)` failed on the cache snapshot. Should never happen
        /// for `Codable` plain-dict-of-struct payloads, but report it if it does.
        case encodeFailed(underlyingDescription: String)
        /// The atomic write of the cache snapshot to disk failed (disk full, permission
        /// denied, parent missing, etc.). The in-memory state is intact; only the
        /// on-disk file is stale.
        case persistWriteFailed(url: URL, underlyingDescription: String)
        /// `clear()` could not delete the existing on-disk cache file.
        case clearFailed(url: URL, underlyingDescription: String)
        /// `purgeStale(except:)` hit an attribute-stat failure on a path that still
        /// exists on disk. The corresponding entry was dropped and the error reported.
        case purgeAttributeLookupFailed(path: String, underlyingDescription: String)

        public var description: String {
            switch self {
            case .loadCorrupted(let url, let underlying):
                return "duplicate hash cache load corrupted at \(url.path): \(underlying ?? "no underlying error")"
            case .cacheAttributeLookupFailed(let url, let underlying):
                return "duplicate hash cache attribute lookup failed at \(url.path): \(underlying ?? "no underlying error")"
            case .directoryCreateFailed(let url, let message):
                return "duplicate hash cache parent directory create failed at \(url.path): \(message)"
            case .encodeFailed(let message):
                return "duplicate hash cache encode failed: \(message)"
            case .persistWriteFailed(let url, let message):
                return "duplicate hash cache persist write failed at \(url.path): \(message)"
            case .clearFailed(let url, let message):
                return "duplicate hash cache clear failed at \(url.path): \(message)"
            case .purgeAttributeLookupFailed(let path, let message):
                return "duplicate hash cache purge attribute lookup failed at \(path): \(message)"
            }
        }
    }

    /// Closure the cache invokes for any non-fatal filesystem error encountered while
    /// persisting, loading, clearing, or purging entries. Marked `@Sendable` because
    /// `DuplicateHashCache` is `@unchecked Sendable` and callers invoke `persist()` /
    /// `purgeStale()` from `Task.detached(priority: .utility)` blocks (see
    /// `ScanStore.scan(_:)` and `OnDemandVerificationStore.verify(_:)`).
    public typealias ErrorHandler = @Sendable (Error) -> Void

    private struct Entry: Codable, Equatable {
        let byteSize: Int64
        let modificationDate: Date?
        let checksum: String?
        let identity: String?
        let prefixChecksum: String?
        let prefixByteCount: Int?
    }

    private let lock = NSLock()
    private let persistenceLock = NSRecursiveLock()
    private var entries: [String: Entry] = [:]
    private let cacheURL: URL?
    private let maxEntries: Int
    private let maxBytes: Int
    private let reportError: ErrorHandler?
    private var hitCount = 0
    private var missCount = 0
    var hits: Int { lock.lock(); defer { lock.unlock() }; return hitCount }
    var misses: Int { lock.lock(); defer { lock.unlock() }; return missCount }
    private var lastPersistedAtInternal: Date?
    /// Approximate per-entry JSON footprint accumulator. Used to trigger byte-budget
    /// eviction in `record(_:)`. Recomputed from `entries` on `load()` so a corrupt
    /// or stale value never accumulates across reloads.
    private var approximateBytes: Int = 0
    private var generation: UInt64 = 0
    private var persistedGeneration: UInt64?

    /// - Parameters:
    ///   - cacheURL: Optional on-disk location for the persisted JSON. When `nil`, the
    ///     cache is purely in-memory and `persist()`/`clear()` are no-ops.
    ///   - maxEntries: Hard cap on entry count. When `record(_:checksum:)` pushes the
    ///     cache over the cap, the oldest-mtime entries are dropped first. Default is
    ///     5,000 (matches the LRU-size target in the v0.6 performance plan).
    ///   - maxBytes: Hard cap on the approximate serialized JSON size of the cache.
    ///     Default is 20 MiB. When exceeded, oldest-mtime entries are dropped.
    ///   - reportError: Receives the typed cache errors raised by previously-swallowed
    ///     `try?` calls. Defaults to `nil` (errors still never propagate as throws).
    public init(
        cacheURL: URL? = nil,
        maxEntries: Int = 5_000,
        maxBytes: Int = 20 * 1_024 * 1_024,
        reportError: ErrorHandler? = nil
    ) {
        self.cacheURL = cacheURL
        self.maxEntries = max(100, maxEntries)
        self.maxBytes = max(0, maxBytes)
        self.reportError = reportError
        load()
        lastPersistedAtInternal = lastPersistedFromFile()
    }

    public func checksum(for key: LookupKey) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = matchingEntry(for: key), let checksum = entry.checksum else {
            missCount += 1
            return nil
        }
        hitCount += 1
        return checksum
    }

    public func prefixChecksum(for key: LookupKey, byteCount: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = matchingEntry(for: key), entry.prefixByteCount == byteCount else { return nil }
        return entry.prefixChecksum
    }

    private func matchingEntry(for key: LookupKey) -> Entry? {
        guard let entry = entries[key.path], entry.byteSize == key.byteSize,
              entry.modificationDate == key.modificationDate, entry.identity == key.identity else { return nil }
        return entry
    }

    public func record(_ key: LookupKey, checksum: String) {
        record(key, checksum: checksum, prefixChecksum: nil, prefixByteCount: nil)
    }

    public func recordPrefix(_ key: LookupKey, checksum: String, byteCount: Int) {
        record(key, checksum: nil, prefixChecksum: checksum, prefixByteCount: byteCount)
    }

    private func record(_ key: LookupKey, checksum: String?, prefixChecksum: String?, prefixByteCount: Int?) {
        lock.lock()
        defer { lock.unlock() }
        let matching = matchingEntry(for: key)
        let entry = Entry(
            byteSize: key.byteSize, modificationDate: key.modificationDate,
            checksum: checksum ?? matching?.checksum, identity: key.identity,
            prefixChecksum: prefixChecksum ?? matching?.prefixChecksum,
            prefixByteCount: prefixByteCount ?? matching?.prefixByteCount
        )
        guard entries[key.path] != entry else { return }
        if let existing = entries[key.path] {
            approximateBytes -= entryByteSize(path: key.path, entry: existing)
        }
        generation &+= 1
        entries[key.path] = entry
        approximateBytes += entryByteSize(path: key.path, entry: entry)
        if entries.count > maxEntries || approximateBytes > maxBytes {
            pruneOldest()
        }
    }

    public func persist() {
        _ = try? persistThrowing()
    }

    /// Throwing variant so callers that care about persistence failure (e.g. on-demand
    /// verification) can surface the error instead of silently dropping the cache. Mirrors
    /// the legacy `persist()` swallow path: a `nil` `cacheURL` is a no-op, not an error.
    public func persistThrowing() throws {
        guard let cacheURL else { return }
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        // A user or cleanup process may remove the file after our last write.
        // Check outside the entries lock, then recreate it from the snapshot.
        let cacheFileExists = FileManager.default.fileExists(atPath: cacheURL.path)
        lock.lock()
        if persistedGeneration == generation && cacheFileExists {
            lock.unlock()
            return
        }
        let snapshot = entries
        let snapshotGeneration = generation
        lock.unlock()
        let data: Data
        do {
            data = try JSONEncoder().encode(snapshot)
        } catch {
            reportError?(.encodeFailed(underlyingDescription: error.localizedDescription))
            throw error
        }
        let parent = cacheURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
        } catch {
            reportError?(.directoryCreateFailed(
                url: cacheURL,
                underlyingDescription: error.localizedDescription
            ))
            throw error
        }
        do {
            try data.write(to: cacheURL, options: .atomic)
            lock.lock()
            lastPersistedAtInternal = Date()
            persistedGeneration = snapshotGeneration
            lock.unlock()
        } catch {
            reportError?(.persistWriteFailed(
                url: cacheURL,
                underlyingDescription: error.localizedDescription
            ))
            throw error
        }
    }

    public var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    public var lastPersistedAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return lastPersistedAtInternal
    }

    /// Approximate serialized JSON footprint, in bytes, of the in-memory cache. Exposed
    /// primarily for diagnostics/testing so callers can confirm the byte-budget eviction
    /// is actually firing. Computed from `entries` on load rather than stored across
    /// reloads so it stays accurate after a corrupt-file reset.
    public var approximateSerializedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return approximateBytes
    }

    /// Drops every cached checksum and removes the on-disk cache file. Useful when the user
    /// wants to force a re-hash on the next scan (e.g. after moving files around) or to
    /// reclaim the disk footprint.
    public func clear() {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        lock.lock()
        entries.removeAll()
        generation &+= 1
        persistedGeneration = nil
        approximateBytes = 0
        lastPersistedAtInternal = nil
        lock.unlock()

        guard let cacheURL else { return }
        // No-op when there's no on-disk file; report only genuine removal failures.
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: cacheURL)
        } catch {
            reportError?(.clearFailed(
                url: cacheURL,
                underlyingDescription: error.localizedDescription
            ))
        }
    }

    /// Drops cache entries for files that no longer exist on disk (or that have become
    /// unreadable). Pass `except` for paths the caller just scanned — those are preserved
    /// unconditionally so the verifier still finds their cached checksum on the next lookup.
    /// Returns the number of entries dropped. Does not touch entries for files that still
    /// exist, even if their size/mtime has shifted (that's handled by `checksum(for:)`).
    public func purgeStale(except itemPaths: Set<String> = []) -> Int {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        var stale: [String: Entry] = [:]
        var errors: [Error] = []
        for (path, entry) in snapshot where !itemPaths.contains(path) {
            if !FileManager.default.fileExists(atPath: path) {
                stale[path] = entry
            } else {
                do { _ = try FileManager.default.attributesOfItem(atPath: path) }
                catch {
                    stale[path] = entry
                    errors.append(.purgeAttributeLookupFailed(path: path, underlyingDescription: error.localizedDescription))
                }
            }
        }
        lock.lock()
        var dropped = 0
        for (path, oldEntry) in stale where entries[path] == oldEntry {
            entries.removeValue(forKey: path)
            approximateBytes -= entryByteSize(path: path, entry: oldEntry)
            dropped += 1
        }
        if dropped > 0 { generation &+= 1 }
        lock.unlock()
        errors.forEach { reportError?($0) }
        return dropped
    }

    private func load() {
        guard let cacheURL else { return }
        let data: Data
        do {
            data = try Data(contentsOf: cacheURL)
        } catch {
            // Missing cache file is the common non-error path on first launch; only
            // surface a read failure (perms, IO error) when the file actually exists.
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                reportError?(.loadCorrupted(
                    url: cacheURL,
                    underlyingDescription: error.localizedDescription
                ))
            }
            return
        }
        do {
            let decoded = try JSONDecoder().decode([String: Entry].self, from: data)
            entries = decoded
            persistedGeneration = generation
            approximateBytes = entries.reduce(into: 0) { partial, pair in
                partial += entryByteSize(path: pair.key, entry: pair.value)
            }
            if entries.count > maxEntries || approximateBytes > maxBytes {
                pruneOldest()
                generation &+= 1
            }
        } catch {
            // Corrupt or partially-written JSON: drop everything and start fresh so the
            // next successful persist() overwrites the bad file. Surface the decode
            // failure so callers know a re-scan will recompute hashes.
            entries.removeAll()
            approximateBytes = 0
            reportError?(.loadCorrupted(
                url: cacheURL,
                underlyingDescription: error.localizedDescription
            ))
        }
    }

    private func lastPersistedFromFile() -> Date? {
        guard let cacheURL else { return nil }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: cacheURL.path)
            return attrs[.modificationDate] as? Date
        } catch {
            // Missing cache file is expected on first launch; treat as no error.
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                reportError?(.cacheAttributeLookupFailed(
                    url: cacheURL,
                    underlyingDescription: error.localizedDescription
                ))
            }
            return nil
        }
    }

    /// Rough per-entry JSON footprint at the on-disk boundary: the key (path), the
    /// checksum string, two numeric fields (Int64 + Date serialise to short numeric
    /// literals), plus JSON quoting / structural overhead around each entry.
    private func entryByteSize(path: String, entry: Entry) -> Int {
        let pathBytes = path.utf8.count
        let checksumBytes = (entry.checksum?.utf8.count ?? 0) + (entry.prefixChecksum?.utf8.count ?? 0)
        return pathBytes + checksumBytes + (entry.identity?.utf8.count ?? 0) + 200
    }

    private func pruneOldest() {
        // Drop oldest-mtime entries until both the count and the byte budget are
        // back under cap. Always drops at least `dropCount` entries so the caller
        // doesn't immediately re-trigger eviction on the next `record(_:)`.
        guard !entries.isEmpty else { return }
        let dropCount = entries.count > maxEntries ? max(1, maxEntries / 10) : 0
        let oldest = entries
            .sorted { lhs, rhs in
                let lhsDate = lhs.value.modificationDate ?? .distantPast
                let rhsDate = rhs.value.modificationDate ?? .distantPast
                return lhsDate < rhsDate
            }
        var dropped = 0
        for (path, entry) in oldest {
            let underCount = entries.count <= maxEntries
            let underBytes = approximateBytes <= maxBytes
            let hasMetFloor = dropped >= dropCount
            if hasMetFloor, underCount, underBytes {
                break
            }
            let size = entryByteSize(path: path, entry: entry)
            entries.removeValue(forKey: path)
            approximateBytes -= size
            dropped += 1
        }
    }
}

extension DuplicateHashCache.LookupKey {
    /// Builds a lookup key from a scanned item.
    public init(item: StorageItem) {
        self.init(
            path: item.url.standardizedFileURL.path,
            byteSize: item.byteSize,
            modificationDate: item.modifiedAt
        )
    }
}
