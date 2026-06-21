import Foundation
import StorageScopeCore

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
    @Published var searchText: String = "" {
        didSet {
            guard oldValue != searchText else { return }
            scheduleSearchTextDebounce()
        }
    }

    @Published var query: String = "" {
        didSet {
            guard oldValue != query else { return }
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

    @Published private(set) var searchSubtreeMatchIDs: Set<String>?

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

    func resetDisplayFilters() {
        query = ""
        sizeFilter = .all
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
        guard let scan = scanLookup() else {
            searchSubtreeMatchIDs = nil
            return
        }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            searchSubtreeMatchIDs = nil
            return
        }

        var subtreeContains = Set<String>()
        func visit(_ item: StorageItem) -> Bool {
            var any = item.matchesNormalizedSearchQuery(trimmedQuery)
            for child in item.children where visit(child) {
                any = true
            }
            if any { subtreeContains.insert(item.id) }
            return any
        }
        _ = visit(scan.rootItem)
        searchSubtreeMatchIDs = subtreeContains
    }
}