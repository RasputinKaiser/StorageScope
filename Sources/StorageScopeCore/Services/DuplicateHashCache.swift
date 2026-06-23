import Foundation

/// Persisted cache of SHA-256 checksums for duplicate verification.
/// Keyed by file path, validated against byte size and modification date on lookup.
/// Keeps rescans fast: unchanged files skip hashing entirely.
public final class DuplicateHashCache: @unchecked Sendable {
    public struct LookupKey: Hashable, Sendable {
        public let path: String
        public let byteSize: Int64
        public let modificationDate: Date?

        public init(path: String, byteSize: Int64, modificationDate: Date?) {
            self.path = path
            self.byteSize = byteSize
            self.modificationDate = modificationDate
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

    private struct Entry: Codable {
        let byteSize: Int64
        let modificationDate: Date?
        let checksum: String
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let cacheURL: URL?
    private let maxEntries: Int
    private let maxBytes: Int
    private let reportError: ErrorHandler?
    private(set) var hits = 0
    private(set) var misses = 0
    private var lastPersistedAtInternal: Date?
    /// Approximate per-entry JSON footprint accumulator. Used to trigger byte-budget
    /// eviction in `record(_:)`. Recomputed from `entries` on `load()` so a corrupt
    /// or stale value never accumulates across reloads.
    private var approximateBytes: Int = 0

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
        self.maxBytes = max(1_024, maxBytes)
        self.reportError = reportError
        load()
        lastPersistedAtInternal = lastPersistedFromFile()
    }

    public func checksum(for key: LookupKey) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key.path],
              entry.byteSize == key.byteSize,
              entry.modificationDate == key.modificationDate else {
            misses += 1
            return nil
        }
        hits += 1
        return entry.checksum
    }

    public func record(_ key: LookupKey, checksum: String) {
        lock.lock()
        defer { lock.unlock() }
        let isNew = entries[key.path] == nil
        if let existing = entries[key.path] {
            approximateBytes -= entryByteSize(path: key.path, entry: existing)
        }
        let entry = Entry(
            byteSize: key.byteSize,
            modificationDate: key.modificationDate,
            checksum: checksum
        )
        entries[key.path] = entry
        approximateBytes += entryByteSize(path: key.path, entry: entry)
        if isNew, entries.count > maxEntries || approximateBytes > maxBytes {
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
        lock.lock()
        let snapshot = entries
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
        lock.lock()
        entries.removeAll()
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
        defer { lock.unlock() }
        var dropped = 0
        for path in Array(entries.keys) {
            if itemPaths.contains(path) {
                continue
            }
            if !FileManager.default.fileExists(atPath: path) {
                if let entry = entries.removeValue(forKey: path) {
                    approximateBytes -= entryByteSize(path: path, entry: entry)
                }
                dropped += 1
                continue
            }
            do {
                _ = try FileManager.default.attributesOfItem(atPath: path)
            } catch {
                if let entry = entries.removeValue(forKey: path) {
                    approximateBytes -= entryByteSize(path: path, entry: entry)
                }
                dropped += 1
                reportError?(.purgeAttributeLookupFailed(
                    path: path,
                    underlyingDescription: error.localizedDescription
                ))
            }
        }
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
            approximateBytes = entries.reduce(into: 0) { partial, pair in
                partial += entryByteSize(path: pair.key, entry: pair.value)
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
        let checksumBytes = entry.checksum.utf8.count
        return pathBytes + checksumBytes + 32 + 40
    }

    private func pruneOldest() {
        // Drop oldest-mtime entries until both the count and the byte budget are
        // back under cap. Always drops at least `dropCount` entries so the caller
        // doesn't immediately re-trigger eviction on the next `record(_:)`.
        guard !entries.isEmpty else { return }
        let dropCount = max(1, maxEntries / 10)
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