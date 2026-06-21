import Foundation

struct RecentScanEntry: Codable, Identifiable, Hashable {
    let path: String
    let scannedAt: Date
    let totalBytes: Int64

    var id: String { path }
}

/// Bounded ring of recently-scanned folder paths with their last-known scan metadata.
/// Backed by JSON in UserDefaults and migrated once from the legacy string-array format
/// that predated v0.2.0. Self-contained: there are no derived caches or cross-store
/// dependencies. v0.5.0 Tier 1 extraction from `ScanStore` — see stored research plan.
@MainActor
final class RecentsStore: ObservableObject {
    private static let legacyRecentScanPathsKey = "StorageScope.recentScanPaths"
    private static let recentScanEntriesKey = "StorageScope.recentScanEntries"
    private static let maxEntries = 8

    @Published private(set) var entries: [RecentScanEntry] = []

    init() {
        load()
    }

    func remember(_ url: URL, scannedAt: Date, totalBytes: Int64) {
        let path = url.standardizedFileURL.path
        let entry = RecentScanEntry(path: path, scannedAt: scannedAt, totalBytes: totalBytes)
        entries.removeAll { $0.path == path }
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(Self.maxEntries))
        persist()
    }

    func forget(path: String) {
        entries.removeAll { $0.path == path }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.recentScanEntriesKey)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.recentScanEntriesKey),
           let decoded = try? JSONDecoder().decode([RecentScanEntry].self, from: data) {
            entries = decoded
            return
        }

        // One-time migration from the v0.1.x string-array recent-scans list. Drops the
        // legacy key after migration completes so future loads skip this branch.
        let legacyPaths = UserDefaults.standard.stringArray(forKey: Self.legacyRecentScanPathsKey) ?? []
        guard !legacyPaths.isEmpty else { return }
        let now = Date()
        entries = legacyPaths.map { RecentScanEntry(path: $0, scannedAt: now, totalBytes: 0) }
        UserDefaults.standard.removeObject(forKey: Self.legacyRecentScanPathsKey)
    }
}