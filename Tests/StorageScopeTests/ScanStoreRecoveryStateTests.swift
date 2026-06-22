import Foundation
import Testing
@testable import StorageScope

@MainActor
@Suite("ScanStore recovery state")
struct ScanStoreRecoveryStateTests {
    @Test("no scan, no filters: displayRecoveryState is .noScan")
    func noScanNoFilters() {
        let store = ScanStore()
        #expect(store.displayRecoveryState == .noScan)
        #expect(store.cleanupRecoveryState == .noScan)
    }

    @Test("search query active: displayRecoveryState is .noMatches")
    func searchActiveYieldsNoMatches() {
        let store = ScanStore()
        store.filters.searchText = "report"
        #expect(store.displayRecoveryState == .noMatches(query: "report"))
        #expect(store.cleanupRecoveryState == .noMatches(query: "report"))
    }

    @Test("search with leading/trailing whitespace is trimmed in the query term")
    func searchWhitespaceIsTrimmed() {
        let store = ScanStore()
        store.filters.searchText = "  report  "
        #expect(store.displayRecoveryState == .noMatches(query: "report"))
    }

    @Test("filter chips active without search: displayRecoveryState is .filteredEmpty")
    func filtersActiveWithoutSearch() {
        let store = ScanStore()
        store.filters.fileTypeFocus = "pdf"
        #expect(store.displayRecoveryState == .filteredEmpty)
    }

    @Test("search wins over filter chips: .noMatches takes priority")
    func searchOverridesFilters() {
        let store = ScanStore()
        store.filters.fileTypeFocus = "pdf"
        store.filters.searchText = "report"
        #expect(store.displayRecoveryState == .noMatches(query: "report"))
    }

    @Test("clearing search falls back to .filteredEmpty when chips remain")
    func searchClearFallsBackToFilters() {
        let store = ScanStore()
        store.filters.fileTypeFocus = "pdf"
        store.filters.searchText = "report"
        // Clearing the search field should drop query via the same searchText.didSet
        // logic that's already tested in FilterStore. The state helper itself only
        // checks searchText + filter state — verifying the simpler branch here.
        store.filters.searchText = ""
        #expect(store.displayRecoveryState == .filteredEmpty)
    }
}