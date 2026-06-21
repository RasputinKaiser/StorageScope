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

    private struct Entry: Codable {
        let byteSize: Int64
        let modificationDate: Date?
        let checksum: String
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let cacheURL: URL?
    private let maxEntries: Int
    private(set) var hits = 0
    private(set) var misses = 0
    private var lastPersistedAtInternal: Date?

    public init(cacheURL: URL? = nil, maxEntries: Int = 10_000) {
        self.cacheURL = cacheURL
        self.maxEntries = max(100, maxEntries)
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
        entries[key.path] = Entry(
            byteSize: key.byteSize,
            modificationDate: key.modificationDate,
            checksum: checksum
        )
        if isNew, entries.count > maxEntries {
            pruneOldest()
        }
    }

    public func persist() {
        guard let cacheURL else { return }
        lock.lock()
        let snapshot = entries
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if (try? data.write(to: cacheURL, options: .atomic)) != nil {
            lock.lock()
            lastPersistedAtInternal = Date()
            lock.unlock()
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

    /// Drops every cached checksum and removes the on-disk cache file. Useful when the user
    /// wants to force a re-hash on the next scan (e.g. after moving files around) or to
    /// reclaim the disk footprint.
    public func clear() {
        lock.lock()
        entries.removeAll()
        lastPersistedAtInternal = nil
        lock.unlock()

        if let cacheURL {
            try? FileManager.default.removeItem(at: cacheURL)
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
                entries.removeValue(forKey: path)
                dropped += 1
                continue
            }
            if (try? FileManager.default.attributesOfItem(atPath: path)) == nil {
                entries.removeValue(forKey: path)
                dropped += 1
            }
        }
        return dropped
    }

    private func load() {
        guard let cacheURL,
              let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return
        }
        entries = decoded
    }

    private func lastPersistedFromFile() -> Date? {
        guard let cacheURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }

    private func pruneOldest() {
        // Drop the 10% of entries whose files were modified longest ago.
        // Files that haven't changed in years are least likely to be rescanned soon.
        let dropCount = max(1, maxEntries / 10)
        let oldest = entries
            .sorted { lhs, rhs in
                let lhsDate = lhs.value.modificationDate ?? .distantPast
                let rhsDate = rhs.value.modificationDate ?? .distantPast
                return lhsDate < rhsDate
            }
            .prefix(dropCount)
        for (path, _) in oldest {
            entries.removeValue(forKey: path)
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