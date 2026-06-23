import Foundation
import os

/// Bounded ring of recent search terms (max 10) so the user can re-run a
/// search they entered earlier. Mirrors `RecentsStore`'s ring-buffer +
/// JSON-in-UserDefaults pattern, but for free-text search terms rather than
/// folder scan metadata.
///
/// v0.5.0 S5 spec: the @Published entries mutation runs on the main actor so
/// SwiftUI sees the change immediately, while the JSON encode + UserDefaults
/// write is handed to `RecentStoreWriter` (a serializing actor) so the main
/// actor doesn't block on serialization and rapid `add(_:)` calls can't race
/// the UserDefaults write order. Decode errors are surfaced via `os_log` and
/// the persisted bytes are reset so a corrupt blob doesn't live forever.
@MainActor
final class SearchRecentsStore: ObservableObject {
    private static let storageKey = "StorageScope.searchRecents"
    private static let maxEntries = 10
    private static let writer = RecentStoreWriter<[String]>(key: storageKey)

    @Published private(set) var entries: [String] = []
    private var writeGeneration: UInt64 = 0

    init() {
        load()
    }

    /// Adds `term` at the front of the ring, de-duping against existing
    /// occurrences so the same search doesn't appear twice. Trims to
    /// `maxEntries`. Empty / whitespace-only terms are filtered out by the
    /// caller (FilterStore.query.didSet guards on non-empty).
    func add(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.removeAll { $0 == trimmed }
        entries.insert(trimmed, at: 0)
        entries = Array(entries.prefix(Self.maxEntries))
        persist()
    }

    func forget(_ term: String) {
        entries.removeAll { $0 == term }
        persist()
    }

    func clear() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        persist()
    }

    private func persist() {
        writeGeneration += 1
        let generation = writeGeneration
        let snapshot = entries
        Task.detached(priority: .utility) { [writer = Self.writer] in
            await writer.write(snapshot, generation: generation)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else { return }
        do {
            entries = try JSONDecoder().decode([String].self, from: data)
        } catch {
            // Migration-safe: drop corrupt JSON so subsequent loads see a clean
            // state instead of being stuck on undecodable bytes forever. Also
            // surfaces the failure so a future build can correlate via Console.app
            // rather than chasing a phantom plist.
            os_log("SearchRecentsStore decode failed, resetting to empty: %{public}@", log: recentStorePersistenceLog, type: .error, String(describing: error))
            entries = []
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
        }
    }
}
