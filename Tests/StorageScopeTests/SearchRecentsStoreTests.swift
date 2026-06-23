import Foundation
import Testing
@testable import StorageScope

@MainActor
@Suite("SearchRecentsStore ring buffer")
struct SearchRecentsStoreTests {
    @Test("fresh store exposes no entries")
    func freshStoreEmpty() {
        let store = SearchRecentsStore()
        // Clear any persisted entries from previous test runs to keep this deterministic.
        store.clear()
        #expect(store.entries.isEmpty)
    }

    @Test("add inserts at front and dedupes")
    func addInsertsAtFrontAndDedupes() {
        let store = SearchRecentsStore()
        store.clear()
        store.add("report")
        store.add("budget")
        store.add("report")  // already present — should move to front, not duplicate

        #expect(store.entries == ["report", "budget"])
    }

    @Test("add empty / whitespace is filtered")
    func addEmptyFiltered() {
        let store = SearchRecentsStore()
        store.clear()
        store.add("")
        store.add("   ")
        store.add("\t\n")
        #expect(store.entries.isEmpty)
    }

    @Test("ring caps at 10 entries")
    func ringCapsAtTen() {
        let store = SearchRecentsStore()
        store.clear()
        for i in 0..<15 {
            store.add("term-\(i)")
        }
        #expect(store.entries.count == 10)
        // Most-recent entry should be term-14 (last added).
        #expect(store.entries.first == "term-14")
    }

    @Test("forget removes a single term")
    func forgetRemovesTerm() {
        let store = SearchRecentsStore()
        store.clear()
        store.add("alpha")
        store.add("beta")
        store.forget("alpha")
        #expect(store.entries == ["beta"])
    }

    @Test("clear empties the ring")
    func clearEmptiesRing() {
        let store = SearchRecentsStore()
        store.clear()
        store.add("a")
        store.add("b")
        store.clear()
        #expect(store.entries.isEmpty)
    }

    @Test("corrupt persisted JSON recovers by resetting to empty")
    func corruptJSONResetsToEmpty() async {
        // Earlier tests schedule detached `persist()` writes through the
        // shared writer actor. Without draining them, a stale write could
        // land between our `set(corrupt:)` and `SearchRecentsStore()`'s
        // `load()`, overwriting the corrupt blob with valid JSON and masking
        // the very decode-failure path this test means to exercise.
        await SearchRecentsStore._flushPendingWritesForTesting()

        let key = "StorageScope.searchRecents"
        // Stash whatever was there so other tests + a real launch aren't perturbed.
        let original = UserDefaults.standard.data(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        // Write obviously-undecodable bytes under the persist key, then construct
        // a fresh store — `load()` should drop the corrupt blob and reset entries
        // rather than surface a partial state or throw.
        let corrupt = "{ this is not a JSON array }".data(using: .utf8)!
        UserDefaults.standard.set(corrupt, forKey: key)

        let store = SearchRecentsStore()
        #expect(store.entries.isEmpty)

        // Verify the corrupt bytes were purged so subsequent launches don't re-trip
        // the same decode failure.
        #expect(UserDefaults.standard.data(forKey: key) == nil)
    }

    @Test("rapid typing cancels earlier debounce snapshots so only the last wins")
    func rapidTypingCancelsEarlierDebounces() async throws {
        let filters = FilterStore(
            scanLookup: { nil },
            coordinateInvalidate: { },
            recordSearchRecent: { _ in }
        )
        #expect(filters.query == "")

        // Simulate a fast typist: typing each character flips searchText, which
        // cancels the in-flight debounce and starts a new one with the latest
        // snapshot. None of the intermediate snapshots should survive the 200ms
        // gap — only the final `apple` snapshot should land on `query`.
        filters.searchText = "a"
        filters.searchText = "ap"
        filters.searchText = "app"
        filters.searchText = "appl"
        filters.searchText = "apple"
        // Pin the in-flux state to prove it hasn't propagated yet.
        #expect(filters.query == "")

        // Poll up to 2s for the 200ms debounce + main-actor hop to fire. A
        // one-shot sleep sized for the happy path flakes on a loaded CI runner
        // where the cooperative pool hasn't scheduled the debounce task within
        // the grace window; polling lets a slow hop still land while preserving
        // the test's strict assertion that only the final "apple" snapshot wins.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while filters.query != "apple" && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(filters.query == "apple")
    }
}
