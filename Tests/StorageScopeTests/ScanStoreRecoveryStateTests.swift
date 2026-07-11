import Foundation
import Testing
@testable import StorageScope

@MainActor
@Suite("ScanStore recovery state")
struct ScanStoreRecoveryStateTests {
    private func recoveryPath() -> String {
        "/tmp/storagescope-recovery-" + UUID().uuidString
    }

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

    @Test("stale bookmark enters the explicit recovery decision state")
    func staleBookmarkStartsRecovery() {
        let recents = RecentsStore()
        let path = recoveryPath()

        recents.requestRecovery(for: path)

        #expect(recents.recoveryState == .needsAction(path: path))
        #expect(recents.recoveryState.path == path)
    }

    @Test("Choose Folder transitions to folder selection and returns the stale path")
    func chooseFolderTransitionsToSelection() {
        let recents = RecentsStore()
        let path = recoveryPath()
        recents.requestRecovery(for: path)

        let selectedPath = recents.chooseFolderForRecovery()

        #expect(selectedPath == path)
        #expect(recents.recoveryState == .choosingFolder(path: path))

        recents.completeRecovery()
        #expect(recents.recoveryState == .idle)
    }

    @Test("Forget Scan removes the stale recent and returns to idle")
    func forgetScanTransitionsToIdleAndRemovesEntry() {
        let recents = RecentsStore()
        let path = recoveryPath()
        recents.remember(URL(fileURLWithPath: path), scannedAt: Date(), totalBytes: 1)
        recents.requestRecovery(for: path)

        recents.forgetScanFromRecovery()

        #expect(recents.recoveryState == .idle)
        #expect(!recents.entries.contains { $0.path == path })
    }

    @Test("Cancel dismisses recovery without forgetting the recent")
    func cancelTransitionsToIdleAndKeepsEntry() {
        let recents = RecentsStore()
        let path = recoveryPath()
        recents.remember(URL(fileURLWithPath: path), scannedAt: Date(), totalBytes: 1)
        recents.requestRecovery(for: path)

        recents.cancelRecovery()

        #expect(recents.recoveryState == .idle)
        #expect(recents.entries.contains { $0.path == path })
        recents.forget(path: path)
    }
}
