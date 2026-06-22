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
}