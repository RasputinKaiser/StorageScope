import Foundation
import StorageScopeCore
import os

/// Owning store for display-filter state: search query (debounced from `searchText`),
/// size filter, sort option, cleanup lane, hidden-files toggle, old-file-age threshold.
/// Also owns the precomputed search-subtree match index that powers tree-view filtering.
///
/// v0.5.0 Tier 2 extraction from `ScanStore`. Cross-store coordination happens via
/// closures injected at init:
/// - `scanLookup` reads `scan` for the retained-items tree the subtree indexer walks
/// - `coordinateInvalidate` triggers `ScanStore.invalidateDerivedCaches()` so derived
///   caches (cleanup candidates, reclaim plan, filtered items, etc.) drop when filter
///   state changes
@MainActor
final class FilterStore: ObservableObject {

    /// os_signpost surface for Instruments. Shares the scan subsystem/category so subtree
    /// rebuilds cluster with the rest of scan-side work in the Instruments timeline.
    private static let log = OSLog(subsystem: "com.rasputinkaiser.StorageScope", category: "scan")
    private static let signpostID = OSSignpostID(log: log)

    /// Identifies a single active filter the user can dismiss individually from the
    /// filter chip bar. `id` routes taps back to the filter to clear; `label` is what
    /// the chip shows.
    struct ActiveFilter: Identifiable, Hashable {
        enum Kind: Hashable { case query, size, lane, fileType }
        let id: Kind
        let label: String

        init(_ id: Kind, _ label: String) {
            self.id = id
            self.label = label
        }
    }

    @Published var searchText: String = "" {
        didSet {
            guard oldValue != searchText else { return }
            if searchText.isEmpty {
                // Clearing the field should drop the chip instantly — don't make the
                // user wait 200ms for the debounce to fire on an empty string.
                searchTextDebounceTask?.cancel()
                searchTextDebounceTask = nil
                if !query.isEmpty { query = "" }
                return
            }
            scheduleSearchTextDebounce()
        }
    }

    @Published var query: String = "" {
        didSet {
            guard oldValue != query else { return }
            // Free-text search and file-type focus are parallel concerns — typing in
            // the search field shouldn't retain a stale file-type filter, and clicking
            // a new file-type row in TypeBreakdownView shouldn't carry an old query.
            if !query.isEmpty, fileTypeFocus != nil { fileTypeFocus = nil }
            coordinateInvalidate()
            rebuildSearchSubtreeMatchIDs()
        }
    }

    @Published var sizeFilter: SizeFilter = .all {
        didSet { coordinateInvalidate() }
    }
    @Published var sortOption: ItemSortOption = .sizeDescending {
        didSet { coordinateInvalidate() }
    }
    @Published var cleanupLaneFilter: CleanupLaneFilter = .all {
        didSet { coordinateInvalidate() }
    }
    @Published var includeHiddenFiles: Bool = false {
        didSet { coordinateInvalidate() }
    }
    @Published var oldFileAgeDays: Int = 180 {
        didSet { coordinateInvalidate() }
    }

    /// Set when the user clicks a row on `TypeBreakdownView` — narrows downstream views
    /// (currently `.largestFiles`) to files whose `fileExtension` matches. Cleared on its own
    /// when the user dismisses the corresponding chip, or anytime `query` changes so the user
    /// typing a free-text search doesn't carry a stale type filter along. Distinct from the
    /// search query so the chip bar can render `Type: mp4` instead of the misleading
    /// `Search: mp4` that focusFileType used before.
    @Published var fileTypeFocus: String? {
        didSet {
            guard oldValue != fileTypeFocus else { return }
            coordinateInvalidate()
        }
    }

    @Published private(set) var searchSubtreeMatchIDs: Set<String>?

/// Read-only derived count of items in `searchSubtreeMatchIDs`. Nil when no
    /// search is active (empty/whitespace-only `query`) so S3's empty-state can
    /// distinguish "no search" from "search active, zero matches". Pure derivation
    /// over `searchSubtreeMatchIDs` — never set externally, never introduces a
    /// second filter-state dimension alongside the chip-bearing `query`/
    /// `fileTypeFocus` pair. S2 surfaces this as the file-table search-result
    /// count badge.
    var searchResultCount: Int? {
        searchSubtreeMatchIDs?.count
    }

    /// Ordered array of item IDs whose own name/path matches the active query,
    /// for S4 Cmd+G find-next navigation. Built alongside `searchSubtreeMatchIDs`
    /// in the same DFS pre-order walk so the navigation order matches the visible
    /// tree structure (Mail/Finder convention: jump top-to-bottom in the order
    /// the rows render). Nil when no query is active. Distinct from
    /// `searchSubtreeMatchIDs` (Set) which includes ancestors-of-matches — that
    /// family set powers tree-subtree filtering; this array powers navigation.
    @Published private(set) var searchResultIDs: [String]?

    private var searchTextDebounceTask: Task<Void, Never>?
    private let scanLookup: () -> StorageScan?
    private let coordinateInvalidate: () -> Void

    init(
        scanLookup: @escaping () -> StorageScan?,
        coordinateInvalidate: @escaping () -> Void
    ) {
        self.scanLookup = scanLookup
        self.coordinateInvalidate = coordinateInvalidate
    }

    var activeDisplayFilterDescriptions: [String] {
        var descriptions: [String] = []
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            descriptions.append("Search: \(trimmedQuery)")
        }
        if sizeFilter != .all {
            descriptions.append("Size: \(sizeFilter.title)")
        }
        if let fileTypeFocus {
            descriptions.append("Type: \(fileTypeFocus)")
        }
        return descriptions
    }

    var activeCleanupFilterDescriptions: [String] {
        var descriptions = activeDisplayFilterDescriptions
        if cleanupLaneFilter != .all {
            descriptions.append("Lane: \(cleanupLaneFilter.title)")
        }
        return descriptions
    }

    var hasActiveDisplayFilters: Bool {
        !activeDisplayFilterDescriptions.isEmpty
    }

    var hasActiveCleanupFilters: Bool {
        !activeCleanupFilterDescriptions.isEmpty
    }

    /// Tappable chip list for the display filter bar (search + size + file type).
    /// Lane is excluded because it only affects cleanup review, which maintains its own
    /// chip list below.
    var activeDisplayChips: [ActiveFilter] {
        var chips: [ActiveFilter] = []
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            chips.append(.init(.query, "Search: \(trimmedQuery)"))
        }
        if sizeFilter != .all {
            chips.append(.init(.size, "Size: \(sizeFilter.title)"))
        }
        if let fileTypeFocus {
            chips.append(.init(.fileType, "Type: \(fileTypeFocus)"))
        }
        return chips
    }

    /// Tappable chip list for the cleanup review filter bar — display filters plus the
    /// cleanup lane, since the lane picker lives inside CleanupReviewView.
    var activeCleanupChips: [ActiveFilter] {
        var chips = activeDisplayChips
        if cleanupLaneFilter != .all {
            chips.append(.init(.lane, "Lane: \(cleanupLaneFilter.title)"))
        }
        return chips
    }

    /// Dismiss a single active filter from the chip bar. Used by `ActiveDisplayFiltersView`
    /// so the user doesn't have to `Reset all` to drop just one filter.
    func clearActiveFilter(_ kind: ActiveFilter.Kind) {
        switch kind {
        case .query:
            searchText = ""
            query = ""
        case .size:
            sizeFilter = .all
        case .lane:
            cleanupLaneFilter = .all
        case .fileType:
            fileTypeFocus = nil
        }
    }

    func resetDisplayFilters() {
        query = ""
        sizeFilter = .all
        fileTypeFocus = nil
    }

    func resetCleanupFilters() {
        resetDisplayFilters()
        cleanupLaneFilter = .all
    }

    /// Called by ScanStore when a new scan completes — rebuilds the subtree match index
    /// against the new scan's retained-items tree.
    func rebuildAfterScanChange() {
        rebuildSearchSubtreeMatchIDs()
    }

    private func scheduleSearchTextDebounce() {
        searchTextDebounceTask?.cancel()
        let snapshot = searchText
        searchTextDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.query != snapshot else { return }
                self.query = snapshot
            }
        }
    }

    private func rebuildSearchSubtreeMatchIDs() {
        os_signpost(.begin, log: Self.log, name: "index", signpostID: Self.signpostID)
        defer {
            os_signpost(.end, log: Self.log, name: "index", signpostID: Self.signpostID)
        }

        guard let scan = scanLookup() else {
            searchSubtreeMatchIDs = nil
            searchResultIDs = nil
            return
        }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            searchSubtreeMatchIDs = nil
            searchResultIDs = nil
            return
        }

        var subtreeContains = Set<String>()
        var orderedMatches: [String] = []
        func visit(_ item: StorageItem) -> Bool {
            var any = item.matchesNormalizedSearchQuery(trimmedQuery)
            if any {
                orderedMatches.append(item.id)
            }
            for child in item.children where visit(child) {
                any = true
            }
            if any { subtreeContains.insert(item.id) }
            return any
        }
        _ = visit(scan.rootItem)
        searchSubtreeMatchIDs = subtreeContains
        searchResultIDs = orderedMatches
    }
}