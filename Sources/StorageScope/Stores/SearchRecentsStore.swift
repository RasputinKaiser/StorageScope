import Foundation

/// Bounded ring of recent search terms (max 10) so the user can re-run a
/// search they entered earlier. Mirrors `RecentsStore`'s ring-buffer +
/// JSON-in-UserDefaults pattern, but for free-text search terms rather than
/// folder scan metadata.
///
/// Per the v0.5.0 S5 spec: the @Published entries mutation runs on the main
/// actor so SwiftUI sees the change immediately, while the heavy JSON encode
/// + UserDefaults write detaches to .utility (matches RecentsStore post-P3).
@MainActor
final class SearchRecentsStore: ObservableObject {
    private static let storageKey = "StorageScope.searchRecents"
    private static let maxEntries = 10

    @Published private(set) var entries: [String] = []

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
        let snapshot = entries
        let key = Self.storageKey
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }
        entries = decoded
    }
}