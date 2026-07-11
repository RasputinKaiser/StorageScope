import Combine
import Foundation
import StorageScopeCore
import SwiftUI
import os

@MainActor
final class ScanStore: ObservableObject {
    private static let overviewItemCap = 100

    /// Single source of truth for the ranked-list cap passed to `ScanOptions` below, and
    /// surfaced read-only via `scanRankedResultsCap` so the Overview disclosure can state
    /// the real bound instead of a second hardcoded copy of "800" drifting out of sync.
    private static let rankedResultsCap = 800

    /// os_signpost surface for Instruments. Mirrors FileSystemScanner's subsystem so app-side
    /// and scanner-side spans group together when filtering by subsystem in Instruments.
    private static let log = OSLog(subsystem: "com.rasputinkaiser.StorageScope", category: "scan")
    private static let signpostID = OSSignpostID(log: log)

    /// Nonisolated `OSLog` handle so the cache's `@Sendable` error reporter can fire
    /// from any `Task.detached(priority: .utility)` without crossing the `@MainActor`
    /// boundary around `log`. Same subsystem/category so cache errors still group with
    /// scan signposts in Instruments.
    nonisolated private static let errorLog = OSLog(subsystem: "com.rasputinkaiser.StorageScope", category: "scan")

    private static func defaultHashCacheURL() -> URL? {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("StorageScopeDuplicateHashCache.json")
    }

    /// Splits `FilterStore.excludedPaths` into `ScanOptions`'s two exclusion fields: an
    /// entry starting with `~` or `/` is an absolute-prefix match, everything else is a
    /// bare folder-name match against any path component.
    private static func splitExcludedPaths(_ paths: [String]) -> (components: [String], prefixes: [String]) {
        var components: [String] = []
        var prefixes: [String] = []
        for path in paths {
            if path.hasPrefix("~") || path.hasPrefix("/") {
                prefixes.append(path)
            } else {
                components.append(path)
            }
        }
        return (components, prefixes)
    }

    struct ScanOptionsSnapshot: Equatable {
        let includeHiddenFiles: Bool
        let oldFileAgeDays: Int
        let duplicateCandidateThresholdMB: Int
    }

    private struct DerivedCacheKey: Equatable {
        let scanFinishedAt: Date
        let query: String
        let sizeFilter: SizeFilter
        let sortOption: ItemSortOption
        let cleanupLaneFilter: CleanupLaneFilter
        let ignoredCleanupCandidateIDs: Set<String>
    }

    /// Cache key for `items(for:)`. Construction in `items(for:)` normalizes dimensions
    /// irrelevant to the requested view (e.g. `cleanupLaneFilter` on `.largestFiles`) so
    /// no-op neighborhood changes don't invalidate. Don't write `cachedItems` directly —
    /// always go through `coordinateInvalidate()` and spell new inputs here.
    private struct ItemsCacheKey: Equatable {
        let scanFinishedAt: Date
        let view: SmartView
        let query: String
        let sizeFilter: SizeFilter
        let sortOption: ItemSortOption
        let cleanupLaneFilter: CleanupLaneFilter
        let fileTypeFocus: String?
        let ignoredCleanupCandidateIDs: Set<String>
    }

    let recents = RecentsStore()

    /// S5: bounded ring of search terms the user has typed, surfaced as
    /// `.searchSuggestions` on the `.searchable` field. Parallel structure to
    /// `recents` (RecentsStore) — same UserDefaults-backed JSON pattern.
    let searchRecents = SearchRecentsStore()

    /// Persists across launches via UserDefaults so reopen lands the user in their last
/// session's view — macOS convention. The didSet is gone (AppStorage handles updates),
/// but we still need cache invalidation + the file-type focus clear so the side effects
/// move into explicit `setSelectedView(_:)`.
@AppStorage("StorageScope.selectedView") private var storedSelectedView: String = SmartView.overview.rawValue

var selectedView: SmartView? {
    get { SmartView(rawValue: storedSelectedView) ?? .overview }
    set { setSelectedView(newValue ?? .overview) }
}

func setSelectedView(_ view: SmartView) {
    let old = selectedView
    guard old != view else { return }
    objectWillChange.send()
    storedSelectedView = view.rawValue
    invalidateItemsCache()
    // Clear a stale file-type focus when navigating away from file-bearing views.
    // See SmartView.supportsFileTypeFocus for the case-by-case policy.
    if !view.supportsFileTypeFocus, filters.fileTypeFocus != nil {
        filters.fileTypeFocus = nil
    }
}
    @Published private(set) var session = ScanSession()
    @Published private var selection = ScanSelection()
    @Published var errorMessage: String?
    @Published var pendingTrashReviewPlan: TrashReviewPlan?
    @Published private(set) var isMovingToTrash = false
    /// Bumped each time the AppDelegate's Find command (Cmd+F) is invoked. ContentView
    /// observes this and focuses the search field in response. Using a counter (rather
    /// than a Bool) so the same command can re-fire after the field is already focused —
    /// e.g. user dismisses the field, hits Cmd+F again, expected it to re-focus.
    @Published private(set) var searchFieldFocusRequest: Int = 0

    /// Called by AppDelegate's Find menu item (Cmd+F). Bumps the request counter so
    /// ContentView's `.onChange` re-focuses the search field.
    func requestSearchFieldFocus() {
        searchFieldFocusRequest &+= 1
    }

    /// Index of the search result currently "focused" for Cmd+G find-next
    /// navigation. Nil while no search is active OR if the result list becomes
    /// empty. Set by `advanceSearchResult()` / `reverseSearchResult()` and
    /// consulted by views that want to render a "Result 3 of 12" badge.
    @Published private(set) var currentSearchResultIndex: Int?

    /// Cmd+G &mdash; advances the current find-next target through `filters.searchResultIDs`
    /// in DFS order (top-to-bottom in the visible tree). Wraps around at the end.
    /// Also writes `selection.selectedItemID` so the row becomes selected &mdash;
    /// matching Mail's "Find Next" semantics where the matched row takes focus.
    /// Resets to nil when `searchResultIDs` becomes nil/empty (query cleared)
    /// so a stale index can't reference an item that's no longer a match.
    func advanceSearchResult() {
        guard let ids = filters.searchResultIDs, !ids.isEmpty else {
            currentSearchResultIndex = nil
            return
        }
        let next: Int
        if let current = currentSearchResultIndex {
            next = (current + 1) % ids.count
        } else {
            next = 0
        }
        currentSearchResultIndex = next
        selection.selectedItemID = ids[next]
    }

    /// Cmd+Shift+G &mdash; reverses direction; wraps around at the start.
    func reverseSearchResult() {
        guard let ids = filters.searchResultIDs, !ids.isEmpty else {
            currentSearchResultIndex = nil
            return
        }
        let prev: Int
        if let current = currentSearchResultIndex {
            prev = (current - 1 + ids.count) % ids.count
        } else {
            prev = ids.count - 1
        }
        currentSearchResultIndex = prev
        selection.selectedItemID = ids[prev]
    }

    /// Drop `currentSearchResultIndex` when the search query is cleared
    /// (FilterStore.searchResultIDs becomes nil). Cheap to call idempotently.
    func resetSearchResultNavigationIfApplicable() {
        if filters.searchResultIDs == nil {
            currentSearchResultIndex = nil
        }
    }
    private var markResultsNeedRefreshWhenCurrentScanCompletes = false
    private var selectedViewWhenCurrentScanCompletes: SmartView?
    private var selectVerifiedCleanupWhenCurrentScanCompletes = false

    private var keeperOverridesByChecksum: [String: String] = [:]

    private var activeScanID: UUID?
    private var cancellation: ScanCancellation?
    private var scanTask: Task<Void, Never>?
    /// Previous progress tick's (item count, timestamp) for the EMA rate calculation in
    /// the progress-consumer closure. Reset to nil on scan start and scan resume so a
    /// paused interval isn't counted as a near-zero-rate tick.
    private var lastRateTick: (count: Int, date: Date)?
    private var smoothedItemsPerSecond: Double = 0
    private let bookmarkStore = SecurityScopedBookmarkStore()
    private let hashCache = DuplicateHashCache(
        cacheURL: ScanStore.defaultHashCacheURL(),
        reportError: { error in
            // `Self.log` is `@MainActor`-isolated (ScanStore is @MainActor). Cache errors
            // can fire from any detached utility task, so capture the nonisolated OSLog
            // here instead of touching the main-actor static from a `@Sendable` closure.
            os_log("duplicate hash cache error: %{public}@", log: ScanStore.errorLog, type: .error, "\(error)")
        }
    )

    var duplicateHashCacheEntryCount: Int { hashCache.entryCount }
    var duplicateHashCacheLastPersistedAt: Date? { hashCache.lastPersistedAt }

    func clearDuplicateHashCache() {
        hashCache.clear()
    }
    private var activeRootAccess: SecurityScopedResourceAccess?
    private var cachedCleanupCandidatesKey: DerivedCacheKey?
    private var cachedCleanupCandidates: [CleanupCandidate] = []
    private var cachedPotentialReclaimableBytesKey: DerivedCacheKey?
    private var cachedPotentialReclaimableBytes: Int64 = 0
    private var cachedReclaimPlanKey: DerivedCacheKey?
    private var cachedReclaimPlan = ReclaimPlan(sections: [], primaryAction: nil)
    private var cachedItemsKey: ItemsCacheKey?
    private var cachedItems: [StorageItem] = []

    /// Key for the type/category breakdown caches. Only the scan identity and the search
    /// query feed those computations, so the key deliberately omits the other filter dims —
    /// a size-filter or sort change must not evict a still-valid breakdown.
    private struct TypeBreakdownCacheKey: Equatable {
        let scanFinishedAt: Date
        let query: String
    }

    private var cachedFilteredTypeBreakdownKey: TypeBreakdownCacheKey?
    private var cachedFilteredTypeBreakdown: [FileTypeStat] = []
    private var cachedFilteredCategoryBreakdownKey: TypeBreakdownCacheKey?
    private var cachedFilteredCategoryBreakdown: [FileCategoryStat] = []
    private var cachedOldLargeFilesKey: DerivedCacheKey?
    private var cachedOldLargeFiles: [StorageItem] = []
    private var cachedDuplicateGroupsKey: DerivedCacheKey?
    private var cachedDuplicateGroups: [DuplicateSizeGroup] = []
    private var cachedVerifiedDuplicateGroupsKey: DerivedCacheKey?
    private var cachedVerifiedDuplicateGroups: [VerifiedDuplicateGroup] = []

    /// Test observability for `items(for:)` cache. DEBUG-only so production pays nothing.
    #if DEBUG
    private(set) var itemsCacheHitCount: Int = 0
    private(set) var itemsCacheMissCount: Int = 0

    func resetItemsCacheDebugCounters() {
        itemsCacheHitCount = 0
        itemsCacheMissCount = 0
    }
    #endif

    /// Forwards `onDemandVerification.objectWillChange` the same way `filtersCancellable`
    /// does for `filters` below — views read `store.onDemandVerification.verifyingGroupIDs`
    /// directly through `@ObservedObject var store: ScanStore` without observing the nested
    /// store itself, so without this the "Verify Now" spinner wouldn't live-update either.
    private var onDemandVerificationCancellable: AnyCancellable?

    lazy var onDemandVerification: OnDemandVerificationStore = {
        let store = OnDemandVerificationStore(
            hashCache: hashCache,
            scanLookup: { [weak self] in self?.scan },
            coordinateInvalidate: { [weak self] in self?.invalidateDerivedCaches() },
            reportError: { [weak self] message in self?.errorMessage = message }
        )
        onDemandVerificationCancellable = store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        return store
    }()

    /// Keeps `filters.objectWillChange` forwarded into this store's own `objectWillChange`
    /// (set up alongside `filters` below). Without this, views that hold `@ObservedObject
    /// var store: ScanStore` (every view in the app) never re-render when a `FilterStore`
    /// property changes directly — e.g. flipping a Settings toggle updated the underlying
    /// value, but the checkbox/stepper visually stayed stuck until some unrelated action
    /// (like navigating to a different sidebar view) happened to trigger `ScanStore`'s own
    /// `objectWillChange` and force a fresh re-render that picked up the already-changed value.
    private var filtersCancellable: AnyCancellable?

    lazy var filters: FilterStore = {
        let store = FilterStore(
            scanLookup: { [weak self] in self?.scan },
            coordinateInvalidate: { [weak self] in self?.invalidateDerivedCaches() },
            recordSearchRecent: { [weak self] term in self?.searchRecents.add(term) }
        )
        filtersCancellable = store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        return store
    }()

    /// Typed Binding<T> for any writable FilterStore property — used by Picker/Stepper/Toggle
    /// in views since `$store.filters.X` can't traverse ObservableObject's sub-store boundary.
    func filterBinding<T>(_ keyPath: ReferenceWritableKeyPath<FilterStore, T>) -> Binding<T> {
        Binding(get: { self.filters[keyPath: keyPath] }, set: { self.filters[keyPath: keyPath] = $0 })
    }

    var oldFileAgeDays: Int { filters.oldFileAgeDays }
    var duplicateCandidateThresholdMB: Int { filters.duplicateCandidateThresholdMB }
    var scanRankedResultsCap: Int { Self.rankedResultsCap }
    /// `maxRetainedItems` isn't overridden when constructing `ScanOptions` in `scan(_:)`,
    /// so the type's own default is the true bound — read it from a default-initialized
    /// instance rather than hardcoding a second copy of the number.
    var scanRetainedItemsCap: Int { ScanOptions().maxRetainedItems }

    var activeView: SmartView {
        selectedView ?? .overview
    }

    var selectedItemID: String? {
        get { selection.selectedItemID }
        set { selection.selectedItemID = newValue }
    }

    var scan: StorageScan? {
        get { session.scan }
        set {
            session.scan = newValue
            invalidateDerivedCaches()
            filters.rebuildAfterScanChange()
        }
    }

    var isScanning: Bool {
        get { session.isScanning }
        set { session.isScanning = newValue }
    }

    var progress: ScanProgress {
        get { session.progress }
        set { session.progress = newValue }
    }

    var selectedCleanupCandidateIDs: Set<String> {
        get { selection.selectedCleanupCandidateIDs }
        set { selection.selectedCleanupCandidateIDs = newValue }
    }

    var ignoredCleanupCandidateIDs: Set<String> {
        get { selection.ignoredCleanupCandidateIDs }
        set {
            selection.ignoredCleanupCandidateIDs = newValue
            invalidateDerivedCaches()
        }
    }

    var treeExpandedIDs: Set<String> {
        get { selection.treeExpandedIDs }
        set { selection.treeExpandedIDs = newValue }
    }

    var canExpandAllTree: Bool {
        let containers = treeContainerIDs
        return !containers.isEmpty && !containers.isSubset(of: treeExpandedIDs)
    }

    var canCollapseTree: Bool {
        !treeExpandedIDs.isEmpty
    }

    /// Expands every container (folder/package) in the retained scan tree. Bounded by the
    /// same retention criteria as the scan itself, so big scans only expand what's actually
    /// visible — the renderer never sees the dropped children.
    func expandEntireTree() {
        guard scan != nil else { return }
        treeExpandedIDs = treeContainerIDs
    }

    private var cachedTreeContainerIDsScanFinishedAt: Date?
    private var cachedTreeContainerIDs: Set<String> = []

    /// Container IDs of the retained tree, cached per scan identity. `canExpandAllTree` is
    /// read on every TreeExplorerView body pass (toolbar enablement), and each selection or
    /// expansion change re-evaluates that body — without this cache every click re-walked
    /// the entire retained tree just to produce one Bool.
    private var treeContainerIDs: Set<String> {
        guard let scan else { return [] }
        if cachedTreeContainerIDsScanFinishedAt == scan.finishedAt {
            return cachedTreeContainerIDs
        }
        let ids = allTreeContainerIDs(in: scan.rootItem)
        cachedTreeContainerIDsScanFinishedAt = scan.finishedAt
        cachedTreeContainerIDs = ids
        return ids
    }

    /// Collapses every container — reverts the tree to a single root row.
    func collapseEntireTree() {
        treeExpandedIDs.removeAll()
    }

    /// Collects the IDs of every folder / package in the retained tree. Walks `children`
    /// only (the precomputed retention), not `flattened()`, so it stays cheap on broad scans.
    private func allTreeContainerIDs(in item: StorageItem) -> Set<String> {
        var ids = Set<String>()
        func visit(_ node: StorageItem) {
            if node.isContainer { ids.insert(node.id) }
            for child in node.children where child.isContainer {
                visit(child)
            }
        }
        visit(item)
        return ids
    }

    enum ScanStage: String {
        case idle
        case enumerating
        case verifyingDuplicates
        case complete

        var title: String {
            switch self {
            case .idle: return ""
            case .enumerating: return "Enumerating"
            case .verifyingDuplicates: return "Verifying duplicates"
            case .complete: return "Complete"
            }
        }
    }

    /// Discriminator for `scan(_:)`'s TaskGroup children. Only the scan job yields a
    /// `.result`; the progress consumer ends with `.progressConsumerFinished`. Scan
    /// errors propagate by rethrowing out of `withThrowingTaskGroup` rather than being
    /// wrapped here, so this enum stays `Sendable` (no `Error` payload).
    private enum ScanOutcome: Sendable {
        case result(StorageScan)
        case progressConsumerFinished
    }

    /// One tick on the progress stream: the throttled `ScanProgress` update, paired with
    /// the same-cadence in-progress `StorageScan` snapshot when the scanner produced one.
    /// Folding both into one stream keeps a single consumer child task rather than two,
    /// while still letting `session.scan` update live as list views read it.
    private struct ScanTick: Sendable {
        let progress: ScanProgress
        let snapshot: StorageScan?
    }

    var scanStage: ScanStage {
        if !isScanning {
            return scan == nil ? .idle : .complete
        }
        return progress.phase == .verifyingDuplicates ? .verifyingDuplicates : .enumerating
    }

    var searchSubtreeMatchIDs: Set<String>? { filters.searchSubtreeMatchIDs }

    var selectedItem: StorageItem? {
        guard let scan else {
            return nil
        }
        guard let selectedItemID else {
            // No explicit selection: surface nil so the inspector shows its
            // "No Selection" empty state. Returning scan.rootItem here made the
            // inspector look like it was "stuck" on the scan root regardless of
            // which view was active — misleading because the root folder is not a
            // reviewable artifact, and it hid the fact that selection is explicit.
            return nil
        }

        return scan.lookupItem(id: selectedItemID)
    }

    var canRescan: Bool {
        session.canRescan
    }

    var canCancelScan: Bool {
        session.canCancelScan
    }

    var canPauseScan: Bool {
        session.canPauseScan
    }

    var canResumeScan: Bool {
        session.canResumeScan
    }

    var isScanPaused: Bool {
        session.isScanPaused
    }

    var scanStartedAt: Date? {
        session.scanStartedAt
    }

    var canUseSelectedItemActions: Bool {
        selectedItem != nil && !isScanning
    }

    var canOpenSelectedItem: Bool {
        guard canUseSelectedItemActions, let selectedItem else {
            return false
        }
        // Open routes through NSWorkspace.open(url) which silently no-ops when the URL's
        // underlying file isn't readable (e.g. permission-denied paths surfaced as
        // .inaccessible during the scan). Gate the Open affordance on isReadable so the
        // button doesn't appear responsive but dead.
        return selectedItem.isReadable
    }

    var canMoveSelectedItemToTrash: Bool {
        guard canUseSelectedItemActions, let selectedItem else {
            return false
        }
        return canMoveItemToTrash(selectedItem)
    }

    var scanOptionsAreStale: Bool {
        guard scan != nil, !isScanning, let appliedScanOptions = session.appliedOptions else {
            return false
        }
        return appliedScanOptions != currentScanOptions
    }

    var scanOptionsStatusText: String? {
        if scanOptionsAreStale {
            return "Rescan to apply scan options"
        }
        if session.resultsNeedRefresh {
            return "Rescan to refresh results"
        }
        return nil
    }

    var scanNoticeText: String? {
        if let cancellation = session.lastCancellationMessage {
            return cancellation
        }
        if scanOptionsAreStale {
            return "Scan options changed. Current results still reflect the previous hidden-file and age settings."
        }
        if session.resultsNeedRefresh {
            return "Results changed after moving items to Trash. Review can continue, or rescan when you are ready."
        }
        return nil
    }

    /// Whether the current scan notice is a transient acknowledgment (cancel) that the
    /// user can dismiss vs. a persistent warning (stale options / results need refresh)
    /// that requires rescan to clear.
    var scanNoticeIsDismissible: Bool {
        session.lastCancellationMessage != nil
    }

    /// Dismisses a transient scan notice. Only clears the cancel-ack message; the
    /// stale-options and results-need-refresh notices remain until the user rescans.
    func dismissScanNotice() {
        session.lastCancellationMessage = nil
    }

    var activeDisplayFilterDescriptions: [String] { filters.activeDisplayFilterDescriptions }
    var activeCleanupFilterDescriptions: [String] { filters.activeCleanupFilterDescriptions }
    var hasActiveDisplayFilters: Bool { filters.hasActiveDisplayFilters }
    var hasActiveCleanupFilters: Bool { filters.hasActiveCleanupFilters }

    /// Resolves the empty-list state shown by `FilterRecoveryView` for the
    /// display-side views (Largest Files / Type Breakdown / Tree / etc.).
    /// Priority: active search query → noMatches, else active filter chips
    /// (size / file-type / lane) → filteredEmpty, else noScan. Search wins
    /// over filter chips because the user's mental model when the chip bar
    /// shows a `search:` entry is "my search text is wrong", not "my filter
    /// is too narrow" — that distinction is what S3 ships.
    var displayRecoveryState: FilterRecoveryState {
        let trimmed = filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return .noMatches(query: trimmed)
        }
        if hasActiveDisplayFilters {
            return .filteredEmpty
        }
        return .noScan
    }

    /// Same as `displayRecoveryState` but for the cleanup-review lane, where
    /// the filter chips are cleanup-lane scoped and the search field is the
    /// same `filters.searchText`. Used by CleanupReviewView's empty case.
    var cleanupRecoveryState: FilterRecoveryState {
        let trimmed = filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return .noMatches(query: trimmed)
        }
        if hasActiveCleanupFilters {
            return .filteredEmpty
        }
        return .noScan
    }

    func chooseFolderAndScan(startingAt directoryURL: URL? = nil) {
        guard let url = FileActionService.chooseFolder(startingAt: directoryURL) else {
            return
        }
        scanUserGrantedURL(url)
    }

    func scanHome() {
        chooseFolderAndScan(
            startingAt: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    func scanDocuments() {
        chooseFolderAndScan(
            startingAt: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
    }

    func scanDownloads() {
        chooseFolderAndScan(
            startingAt: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        )
    }

    func scanRecentPath(_ path: String) {
        // Same re-entry guard as `rescan()`: if a scan is already running, do nothing
        // rather than racing a second scan for the same reason. Also avoids opening the
        // NSOpenPanel re-grant fallback when the user's click has already started a scan.
        guard !isScanning else { return }

        do {
            guard let resolvedURL = try bookmarkStore.resolve(path: path) else {
                session.lastErrorCategory = .staleBookmark(path: path)
                errorMessage = nil
                recents.requestRecovery(for: path)
                return
            }

            scanUserGrantedURL(resolvedURL.url, access: resolvedURL.access)
        } catch {
            let category = Self.categorize(error, fallbackPath: path)
            session.lastErrorCategory = category
            os_log("Reopen-bookmark failed for %{private}@: %{public}@",
                   log: Self.log, type: .error, path, String(describing: error))
            errorMessage = nil
            recents.requestRecovery(for: path)
        }
    }

    /// Begins the explicit recent-scan recovery flow. The confirmation dialog is
    /// dismissed before opening the folder panel so stale bookmark failures never
    /// chain an alert directly into a synchronous panel presentation.
    func chooseFolderForRecentRecovery() {
        guard let path = recents.chooseFolderForRecovery() else { return }

        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            defer { recents.completeRecovery() }

            let startingURL = URL(fileURLWithPath: path, isDirectory: true)
            guard let url = FileActionService.chooseFolder(
                startingAt: startingURL,
                message: "Choose the folder again to refresh StorageScope's access."
            ) else {
                return
            }
            scanUserGrantedURL(url)
        }
    }

    func forgetRecentScanRecovery() {
        recents.forgetScanFromRecovery()
    }

    func cancelRecentScanRecovery() {
        recents.cancelRecovery()
    }

    func scanVolume(_ url: URL) {
        chooseFolderAndScan(startingAt: url)
    }

    func scanDeveloperFixturePath(
        _ path: String,
        markResultsNeedRefreshWhenComplete: Bool = false,
        selectedViewWhenComplete: SmartView? = nil,
        selectVerifiedCleanupWhenComplete: Bool = false
    ) {
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        markResultsNeedRefreshWhenCurrentScanCompletes = markResultsNeedRefreshWhenComplete
        selectedViewWhenCurrentScanCompletes = selectedViewWhenComplete
        selectVerifiedCleanupWhenCurrentScanCompletes = selectVerifiedCleanupWhenComplete
        scan(url)
    }

    private var cachedMountedVolumes: [URL]?

    /// Cached so SidebarView's body — which re-evaluates on every store change,
    /// including per-tick scan progress — doesn't redo `FileManager` volume I/O on
    /// every render. Refreshed on `SidebarView.onAppear` (app launch) and after every
    /// successful scan completes, so a volume mounted/unmounted mid-session is picked
    /// up the next time the user finishes a scan rather than only on relaunch.
    var mountedVolumes: [URL] {
        if let cachedMountedVolumes { return cachedMountedVolumes }
        let resolved = resolveMountedVolumes()
        cachedMountedVolumes = resolved
        return resolved
    }

    func refreshMountedVolumes() {
        cachedMountedVolumes = resolveMountedVolumes()
        cachedVolumeCapacityDescriptions.removeAll()
    }

    /// Cached per volume URL for the same reason as `cachedMountedVolumes`: SidebarView
    /// renders one capacity string per volume on every body pass, and the underlying
    /// `resourceValues` fetch is synchronous disk I/O on the main actor. Outer Optional
    /// distinguishes "not fetched yet" from a cached nil (values unavailable). Cleared
    /// alongside the volume list in `refreshMountedVolumes()`.
    private var cachedVolumeCapacityDescriptions: [URL: String?] = [:]

    private func resolveMountedVolumes() -> [URL] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeIsBrowsableKey,
            .volumeIsInternalKey,
            .volumeAvailableCapacityKey,
            .volumeTotalCapacityKey
        ]
        return FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        )?
        .filter { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return values?.volumeIsBrowsable ?? true
        }
        .sorted { lhs, rhs in
            lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
        } ?? []
    }

    /// Returns "N free of M" string for a volume URL, or nil if the values aren't available.
    /// Used by the sidebar Volumes section to surface free vs total capacity before the user
    /// commits to scanning a volume.
    func volumeCapacityDescription(for url: URL) -> String? {
        if let cached = cachedVolumeCapacityDescriptions[url] {
            return cached
        }
        let description = resolveVolumeCapacityDescription(for: url)
        cachedVolumeCapacityDescriptions[url] = description
        return description
    }

    private func resolveVolumeCapacityDescription(for url: URL) -> String? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let free = values.volumeAvailableCapacity ?? 0
        let total = values.volumeTotalCapacity ?? 0
        guard total > 0 else { return nil }
        let freeText = StorageFormat.bytes(Int64(free))
        let totalText = StorageFormat.bytes(Int64(total))
        return "\(freeText) free of \(totalText)"
    }

    func rescan() {
        // Guard against re-entry: a second rescan while a scan is already in-flight is a
        // no-op rather than cancelling-and-relaunching both (the previous behavior
        // spawned racing scans where the loser's result was discarded). Matches the UI's
        // `canRescan == !isScanning` gate so programmatic callers can't bypass it.
        guard !isScanning else { return }

        guard let lastScannedURL = session.lastScannedURL else {
            chooseFolderAndScan()
            return
        }

        do {
            if let resolvedURL = try bookmarkStore.resolve(path: lastScannedURL.standardizedFileURL.path) {
                scanUserGrantedURL(resolvedURL.url, access: resolvedURL.access)
            } else {
                recents.requestRecovery(for: lastScannedURL.standardizedFileURL.path)
            }
        } catch {
            let category = Self.categorize(error, fallbackPath: lastScannedURL.path)
            session.lastErrorCategory = category
            os_log("Rescan access failed for %{private}@: %{public}@",
                   log: Self.log, type: .error, lastScannedURL.path, String(describing: error))
            errorMessage = nil
            recents.requestRecovery(for: lastScannedURL.standardizedFileURL.path)
        }
    }

    func cancelScan() {
        guard let cancelledScanID = activeScanID else {
            return
        }

        cancellation?.cancel()
        scanTask?.cancel()

        if activeScanID == cancelledScanID {
            let pathLabel = session.lastScannedURL?.lastPathComponent ?? "Scan"
            // `scan` may already hold the last streamed partial snapshot (or a fully
            // completed scan) by the time cancellation lands — preserve it rather than
            // resetting progress to a zeroed-out state, so partial results stay visible.
            session.lastCancellationMessage = scan != nil
                ? "Scan of \(pathLabel) was canceled. Partial results are shown; rescan when you are ready."
                : "Scan of \(pathLabel) was canceled. Rescan or pick another folder when ready."
            activeScanID = nil
            cancellation = nil
            scanTask = nil
            isScanning = false
            session.isScanPaused = false
            progress = ScanProgress(
                scannedItemCount: scan?.scannedItemCount ?? progress.scannedItemCount,
                totalBytes: scan?.totalBytes ?? progress.totalBytes,
                currentPath: "Scan cancelled"
            )
        }
    }

    func excludeFolder(_ item: StorageItem) {
        // Standardized to match `isExcluded`'s comparison path in the scanner (which
        // standardizes the child URL before comparing) — otherwise a folder reached via a
        // symlinked ancestor or non-canonical path segment would never match on rescan.
        excludeFolder(atPath: item.url.standardizedFileURL.path)
    }

    /// Path-based entry point for contexts that don't have a folder `StorageItem` on hand —
    /// Duplicate Review rows are always files, so "Exclude This Folder" there targets the
    /// file's containing directory rather than the file itself.
    func excludeFolder(atPath path: String) {
        guard !filters.excludedPaths.contains(path) else {
            return
        }
        filters.excludedPaths.append(path)
        // Force the master toggle on: without it the exclusion list is never applied to
        // ScanOptions and the folder the user just chose wouldn't actually be excluded.
        // Side effect: this also activates the pre-seeded default entries (node_modules,
        // .git, etc.) if the user hadn't enabled exclusion before — acceptable since those
        // defaults exist for exactly this purpose and the alternative (a no-op click) is worse.
        filters.excludeFoldersEnabled = true
        rescan()
    }

    private func pauseResumeGuardedScanID() -> UUID? {
        guard isScanning, let activeScanID else {
            return nil
        }
        return activeScanID
    }

    func pauseScan() {
        guard pauseResumeGuardedScanID() != nil, let cancellation else {
            return
        }
        cancellation.pause()
        session.isScanPaused = true
    }

    func resumeScan() {
        guard pauseResumeGuardedScanID() != nil, let cancellation else {
            return
        }
        cancellation.resume()
        session.isScanPaused = false
        lastRateTick = nil
    }

    /// Computes items/sec from the delta against the previous tick and smooths with an
    /// EMA (0.3 instant / 0.7 previous) so the displayed rate doesn't jitter tick to tick.
    /// Returns `progress` unchanged but with `itemsPerSecond` filled in. Called only from
    /// the progress-consumer closure (MainActor), never from the scanner itself, so the
    /// rate reflects wall-clock delivery time rather than scan-thread timing.
    private func rateAnnotatedProgress(_ progress: ScanProgress) -> ScanProgress {
        defer { lastRateTick = (progress.scannedItemCount, Date()) }

        guard let lastRateTick else {
            return progress
        }

        let itemDelta = progress.scannedItemCount - lastRateTick.count
        let timeDelta = Date().timeIntervalSince(lastRateTick.date)
        guard itemDelta > 0, timeDelta > 0 else {
            return ScanProgress(
                scannedItemCount: progress.scannedItemCount,
                totalBytes: progress.totalBytes,
                currentPath: progress.currentPath,
                phase: progress.phase,
                itemsPerSecond: smoothedItemsPerSecond
            )
        }

        let instantRate = Double(itemDelta) / timeDelta
        smoothedItemsPerSecond = 0.3 * instantRate + 0.7 * smoothedItemsPerSecond
        return ScanProgress(
            scannedItemCount: progress.scannedItemCount,
            totalBytes: progress.totalBytes,
            currentPath: progress.currentPath,
            phase: progress.phase,
            itemsPerSecond: smoothedItemsPerSecond
        )
    }

    private func scanUserGrantedURL(_ url: URL, access: SecurityScopedResourceAccess? = nil) {
        abandonActiveScan()

        let scopedAccess: SecurityScopedResourceAccess
        do {
            scopedAccess = try access ?? SecurityScopedResourceAccess(url: url)
        } catch {
            let category = Self.categorize(error, fallbackPath: url.path)
            session.lastErrorCategory = category
            os_log("Access denied at scan start for %{private}@: %{public}@",
                   log: Self.log, type: .error, url.path, String(describing: error))
            isScanning = false
            progress = ScanProgress(scannedItemCount: 0, totalBytes: 0, currentPath: "Access denied")
            errorMessage = category?.userMessage ?? error.localizedDescription
            return
        }
        replaceActiveRootAccess(with: scopedAccess)
        do {
            try bookmarkStore.remember(url)
        } catch {
            // The user has access for this session; only the launch-to-launch
            // Recents entry is affected. Surface that as a non-blocking notice
            // while still starting the scan.
            errorMessage = error.localizedDescription
        }
        scan(url)
    }

    private func scan(_ url: URL) {
        recents.remember(url, scannedAt: Date(), totalBytes: 0)
        session.lastScannedURL = url
        session.lastCancellationMessage = nil
        selection.resetForNewScan()
        keeperOverridesByChecksum.removeAll()
        onDemandVerification.clear()
        invalidateDerivedCaches()
        errorMessage = nil
        session.lastErrorCategory = nil
        session.resultsNeedRefresh = false
        isScanning = true
        session.isScanPaused = false
        session.scanStartedAt = Date()
        lastRateTick = nil
        smoothedItemsPerSecond = 0
        progress = ScanProgress(scannedItemCount: 0, totalBytes: 0, currentPath: url.path)

        let scanID = UUID()
        let thresholds = ScanOptionPolicy.interactiveScanThresholds()
        let (excludedComponents, excludedPrefixes) = Self.splitExcludedPaths(filters.excludedPaths)
        let options = ScanOptions(
            includeHidden: filters.includeHiddenFiles,
            oldFileAgeDays: filters.oldFileAgeDays,
            largeFileThreshold: thresholds.largeFileThreshold,
            duplicateCandidateThreshold: Int64(filters.duplicateCandidateThresholdMB) * 1_000_000,
            maxRankedResults: Self.rankedResultsCap,
            excludeEnabled: filters.excludeFoldersEnabled,
            excludedPathComponents: excludedComponents,
            excludedAbsolutePrefixes: excludedPrefixes
        )
        let optionsSnapshot = currentScanOptions
        let scanCancellation = ScanCancellation()
        activeScanID = scanID
        cancellation = scanCancellation

        scanTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let hashCache = self.hashCache
                // Bridge the scanner's synchronous progress callback into a structured async
                // stream so the per-update actor hop happens from a structured child of
                // scanTask, not an unstructured top-level Task. Two TaskGroup children:
                //   1) The scanner itself on a user-initiated priority, yielding progress
                //      into the stream as it goes.
                //   2) A structured consumer forwarding each event to MainActor.
                // Both inherit scanTask's cancellation: withTaskCancellationHandler propagates
                // Task.cancel() into the scanner's ScanCancellation handle AND finishes the
                // stream so the consumer exits cleanly.
                let (progressStream, progressContinuation) = AsyncStream<ScanTick>.makeStream()
                // The scanner's `progress` and `onSnapshot` callbacks fire at the same
                // throttled cadence (`onSnapshot` is invoked from inside `emitProgressLocked`
                // right after the progress callback) but as two separate calls. Pair the
                // latest snapshot with the next progress tick on this side rather than adding
                // a second stream, so the consumer only has one `for await` loop to drain.
                let pendingSnapshotLock = NSLock()
                var pendingSnapshot: StorageScan?
                let result = try await withTaskCancellationHandler {
                    try await withThrowingTaskGroup(of: ScanOutcome.self) { group in
                        group.addTask(priority: .userInitiated) {
                            // Guarantee the stream finishes when the scanner exits — whether
                            // by success, cancellation, or an unexpected thrown error. Without
                            // this the progress-consumer sibling would block on `for await`
                            // forever and the task group would hang waiting for it.
                            defer { progressContinuation.finish() }
                            let scanner = FileSystemScanner(hashCache: hashCache)
                            let scan = try scanner.scan(
                                root: url,
                                options: options,
                                cancellation: scanCancellation,
                                progress: { progress in
                                    pendingSnapshotLock.lock()
                                    let snapshot = pendingSnapshot
                                    pendingSnapshot = nil
                                    pendingSnapshotLock.unlock()
                                    progressContinuation.yield(ScanTick(progress: progress, snapshot: snapshot))
                                },
                                onSnapshot: { snapshot in
                                    pendingSnapshotLock.lock()
                                    pendingSnapshot = snapshot
                                    pendingSnapshotLock.unlock()
                                }
                            )
                            return .result(scan)
                        }

                        group.addTask {
                            for await tick in progressStream {
                                if Task.isCancelled { break }
                                await MainActor.run { [weak self, scanID, scanCancellation] in
                                    guard let self, self.isCurrentScan(scanID, cancellation: scanCancellation) else {
                                        return
                                    }
                                    self.progress = self.rateAnnotatedProgress(tick.progress)
                                    if let snapshot = tick.snapshot {
                                        // Non-final assignment: `scan` will be overwritten again
                                        // when the scan completes (or left as-is if cancelled),
                                        // same field either way.
                                        self.scan = snapshot
                                    }
                                }
                            }
                            return .progressConsumerFinished
                        }

                        while let outcome = try await group.next() {
                            switch outcome {
                            case .result(let scan):
                                return scan
                            case .progressConsumerFinished:
                                continue
                            }
                        }
                        throw CancellationError()
                    }
                } onCancel: {
                    scanCancellation.cancel()
                    progressContinuation.finish()
                }

                guard !Task.isCancelled, isCurrentScan(scanID, cancellation: scanCancellation) else {
                    return
                }

                scan = result
                let cacheToPersist = hashCache
                let pathsScanned = Set(result.retainedItems.map { $0.url.standardizedFileURL.path })
                let persistLog = Self.log
                let persistSignpostID = Self.signpostID
                Task.detached(priority: .utility) { [weak self] in
                    os_signpost(.begin, log: persistLog, name: "persist", signpostID: persistSignpostID,
                                "entries=%d", cacheToPersist.entryCount)
                    _ = cacheToPersist.purgeStale(except: pathsScanned)
                    do {
                        try cacheToPersist.persistThrowing()
                        os_signpost(.end, log: persistLog, name: "persist", signpostID: persistSignpostID)
                    } catch {
                        let desc = error.localizedDescription
                        os_signpost(.end, log: persistLog, name: "persist", signpostID: persistSignpostID,
                                    "error=%{public}@", desc)
                        await MainActor.run { [weak self] in
                            self?.errorMessage = "Could not save scan cache: \(desc)"
                        }
                    }
                }
                recents.remember(url, scannedAt: result.finishedAt, totalBytes: result.totalBytes)
                treeExpandedIDs = [result.rootItem.id]
                session.appliedOptions = optionsSnapshot
                if markResultsNeedRefreshWhenCurrentScanCompletes {
                    session.resultsNeedRefresh = true
                    markResultsNeedRefreshWhenCurrentScanCompletes = false
                }
                if selectVerifiedCleanupWhenCurrentScanCompletes {
                    selectVerifiedCleanupCandidates()
                    selectVerifiedCleanupWhenCurrentScanCompletes = false
                }
                selectedView = selectedViewWhenCurrentScanCompletes ?? .overview
                selectedViewWhenCurrentScanCompletes = nil
                selectedItemID = result.rootItem.id
                progress = ScanProgress(
                    scannedItemCount: result.scannedItemCount,
                    totalBytes: result.totalBytes,
                    currentPath: "Scan complete"
                )
                isScanning = false
                session.isScanPaused = false
                refreshMountedVolumes()
                clearActiveScan(scanID, cancellation: scanCancellation)
            } catch FileSystemScannerError.cancelled {
                guard isCurrentScan(scanID, cancellation: scanCancellation) else {
                    return
                }
                isScanning = false
                session.isScanPaused = false
                markResultsNeedRefreshWhenCurrentScanCompletes = false
                selectedViewWhenCurrentScanCompletes = nil
                selectVerifiedCleanupWhenCurrentScanCompletes = false
                // Preserve whatever the last streamed snapshot published to `scan` (or, if no
                // snapshot ever arrived, leave it nil) rather than discarding it — cancel now
                // keeps partial results instead of wiping the in-progress state.
                progress = ScanProgress(
                    scannedItemCount: scan?.scannedItemCount ?? progress.scannedItemCount,
                    totalBytes: scan?.totalBytes ?? progress.totalBytes,
                    currentPath: "Scan cancelled"
                )
                // Intentionally quiet: cancellation is not an alert-worthy failure. The footer
                // already surfaces "Scan cancelled"; surfacing errorMessage here would pop a
                // redundant alert after every Cmd+. Clear lastErrorCategory so a stale category
                // from a previous failed scan does not linger through this cancellation.
                session.lastErrorCategory = nil
                clearActiveScan(scanID, cancellation: scanCancellation)
            } catch {
                guard isCurrentScan(scanID, cancellation: scanCancellation) else {
                    return
                }
                isScanning = false
                markResultsNeedRefreshWhenCurrentScanCompletes = false
                selectedViewWhenCurrentScanCompletes = nil
                selectVerifiedCleanupWhenCurrentScanCompletes = false
                let category = Self.categorize(error, fallbackPath: url.path)
                session.lastErrorCategory = category
                os_log("Scan failed for %{private}@: %{public}@",
                       log: Self.log, type: .error, url.path, String(describing: error))
                errorMessage = category?.userMessage ?? error.localizedDescription
                clearActiveScan(scanID, cancellation: scanCancellation)
            }
        }
    }

    func items(for view: SmartView) -> [StorageItem] {
        guard let scan else {
            return []
        }

        // Toggle dims irrelevant to the requested view so the cache survives no-op
        // neighborhood changes: cleanupLaneFilter + ignoredCleanupCandidateIDs feed
        // `cleanupCandidates` (→ `.cleanupReview` only), nothing else; fileTypeFocus
        // is filtered by `setSelectedView` but normalized here too as defense-in-depth.
        let cleanupRelevant = view == .cleanupReview
        let key = ItemsCacheKey(
            scanFinishedAt: scan.finishedAt,
            view: view,
            query: filters.query,
            sizeFilter: filters.sizeFilter,
            sortOption: filters.sortOption,
            cleanupLaneFilter: cleanupRelevant ? filters.cleanupLaneFilter : .all,
            fileTypeFocus: view.supportsFileTypeFocus ? filters.fileTypeFocus : nil,
            ignoredCleanupCandidateIDs: cleanupRelevant ? ignoredCleanupCandidateIDs : []
        )
        if cachedItemsKey == key {
            #if DEBUG
            itemsCacheHitCount &+= 1
            #endif
            return cachedItems
        }

        os_signpost(.begin, log: Self.log, name: "items_rebuild", signpostID: Self.signpostID,
                    "view=%@ query=%@", view.rawValue, filters.query)
        defer {
            os_signpost(.end, log: Self.log, name: "items_rebuild", signpostID: Self.signpostID)
        }
        #if DEBUG
        itemsCacheMissCount &+= 1
        #endif

        let baseItems: [StorageItem]
        switch view {
        case .overview:
            baseItems = Array(scan.rootItem.children.prefix(Self.overviewItemCap))
        case .cleanupReview:
            baseItems = cleanupCandidates.map(\.item)
        case .tree:
            baseItems = [scan.rootItem]
        case .largestFolders:
            baseItems = scan.largestFolders
        case .largestFiles:
            baseItems = scan.largestFiles
        case .oldLargeFiles:
            baseItems = oldLargeFiles
        case .typeBreakdown:
            baseItems = []
        case .duplicateCandidates:
            baseItems = duplicateGroups.flatMap(\.items)
        }

        let items = filtered(baseItems)
        cachedItemsKey = key
        cachedItems = items
        return items
    }

    var oldLargeFiles: [StorageItem] {
        guard let scan else {
            return []
        }
        guard let key = currentDerivedCacheKey else {
            return []
        }
        if cachedOldLargeFilesKey == key {
            return cachedOldLargeFiles
        }
        let result = filtered(scan.oldLargeFiles.filter { $0.displaySize >= max(filters.sizeFilter.threshold, 100_000_000) })
        cachedOldLargeFilesKey = key
        cachedOldLargeFiles = result
        return result
    }

    var duplicateGroups: [DuplicateSizeGroup] {
        guard let scan else {
            return []
        }
        guard let key = currentDerivedCacheKey else {
            return []
        }
        if cachedDuplicateGroupsKey == key {
            return cachedDuplicateGroups
        }
        // Layer scan-time verified groups with on-demand ones so items that became verified
        // via "Verify Now" disappear from the same-size candidate list.
        var mergedVerifiedGroups = scan.verifiedDuplicateGroups
        mergedVerifiedGroups.append(contentsOf: onDemandVerification.verifiedGroupsByChecksum.values)
        let value = DuplicateReviewPlanner.unverifiedSizeGroups(
            sizeGroups: scan.duplicateSizeGroups,
            verifiedGroups: mergedVerifiedGroups
        )
            .filter { $0.byteSize >= max(filters.sizeFilter.threshold, 100_000_000) }
            .map { group in
                DuplicateSizeGroup(byteSize: group.byteSize, items: filtered(group.items))
            }
            .filter { $0.items.count > 1 }
        cachedDuplicateGroupsKey = key
        cachedDuplicateGroups = value
        return value
    }

    var verifiedDuplicateGroups: [VerifiedDuplicateGroup] {
        guard let scan else {
            return onDemandVerification.verifiedGroupsByChecksum.isEmpty
                ? []
                : Array(onDemandVerification.verifiedGroupsByChecksum.values).filter { $0.byteSize >= filters.sizeFilter.threshold }
                    .map { group in
                        VerifiedDuplicateGroup(
                            checksum: group.checksum,
                            byteSize: group.byteSize,
                            items: filtered(group.items)
                        )
                    }
                    .filter { $0.items.count > 1 }
                    .sorted { lhs, rhs in
                        if lhs.reclaimableBytes == rhs.reclaimableBytes {
                            return lhs.byteSize > rhs.byteSize
                        }
                        return lhs.reclaimableBytes > rhs.reclaimableBytes
                    }
        }

        guard let key = currentDerivedCacheKey else {
            return []
        }
        if cachedVerifiedDuplicateGroupsKey == key {
            return cachedVerifiedDuplicateGroups
        }

        // Merge scan-time verified groups with on-demand ones, keyed by checksum. On-demand wins
        // in case of a checksum collision so a manual re-verify (e.g. with cache cleared) is
        // reflected immediately.
        var merged: [String: VerifiedDuplicateGroup] = [:]
        for group in scan.verifiedDuplicateGroups {
            merged[group.checksum] = group
        }
        for (checksum, group) in onDemandVerification.verifiedGroupsByChecksum {
            merged[checksum] = group
        }

        let value = merged.values
            .filter { $0.byteSize >= filters.sizeFilter.threshold }
            .map { group in
                VerifiedDuplicateGroup(
                    checksum: group.checksum,
                    byteSize: group.byteSize,
                    items: filtered(group.items)
                )
            }
            .filter { $0.items.count > 1 }
            .sorted { lhs, rhs in
                if lhs.reclaimableBytes == rhs.reclaimableBytes {
                    return lhs.byteSize > rhs.byteSize
                }
                return lhs.reclaimableBytes > rhs.reclaimableBytes
            }
        cachedVerifiedDuplicateGroupsKey = key
        cachedVerifiedDuplicateGroups = value
        return value
    }

    func keeperItemID(for group: VerifiedDuplicateGroup) -> String? {
        keeperOverridesByChecksum[group.checksum] ?? group.items.first?.id
    }

    func isKeeper(_ itemID: String, in group: VerifiedDuplicateGroup) -> Bool {
        keeperItemID(for: group) == itemID
    }

    func setKeeper(itemID: String, for group: VerifiedDuplicateGroup) {
        keeperOverridesByChecksum[group.checksum] = itemID
        // The keeper override only affects which verified copies are excluded at trash time;
        // derived display caches (candidate lists, reclaim plan) do not depend on it, so no
        // invalidateDerivedCaches() is needed here.
    }

    private var currentKeeperItemIDs: Set<String> {
        var ids = Set<String>()
        if let scan {
            for group in scan.verifiedDuplicateGroups {
                if let keeperID = keeperOverridesByChecksum[group.checksum] ?? group.items.first?.id {
                    ids.insert(keeperID)
                }
            }
        }
        for group in onDemandVerification.verifiedGroupsByChecksum.values {
            if let keeperID = keeperOverridesByChecksum[group.checksum] ?? group.items.first?.id {
                ids.insert(keeperID)
            }
        }
        return ids
    }

    var cleanupCandidates: [CleanupCandidate] {
        guard let scan else {
            return []
        }

        let key = DerivedCacheKey(
            scanFinishedAt: scan.finishedAt,
            query: filters.query,
            sizeFilter: filters.sizeFilter,
            sortOption: filters.sortOption,
            cleanupLaneFilter: filters.cleanupLaneFilter,
            ignoredCleanupCandidateIDs: ignoredCleanupCandidateIDs
        )
        if cachedCleanupCandidatesKey == key {
            return cachedCleanupCandidates
        }

        let trimmedQuery = filters.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = scan.cleanupCandidates.filter { candidate in
            guard !ignoredCleanupCandidateIDs.contains(candidate.id) else {
                return false
            }

            let item = candidate.item
            let passesSize = candidate.reclaimableBytes >= filters.sizeFilter.threshold || item.displaySize >= filters.sizeFilter.threshold
            let passesLane = cleanupCandidate(candidate, passes: filters.cleanupLaneFilter)
            let passesQuery = trimmedQuery.isEmpty ||
                item.matchesNormalizedSearchQuery(trimmedQuery) ||
                candidate.reason.localizedCaseInsensitiveContains(trimmedQuery) ||
                candidate.kind.displayName.localizedCaseInsensitiveContains(trimmedQuery)
            return passesSize && passesLane && passesQuery
        }
        cachedCleanupCandidatesKey = key
        cachedCleanupCandidates = candidates
        return candidates
    }

    var potentialReclaimableBytes: Int64 {
        guard let key = currentDerivedCacheKey else {
            return 0
        }
        if cachedPotentialReclaimableBytesKey == key {
            return cachedPotentialReclaimableBytes
        }
        let bytes = CleanupSelectionPlanner.topLevelCandidates(cleanupCandidates).reduce(Int64(0)) { $0 + $1.reclaimableBytes }
        cachedPotentialReclaimableBytesKey = key
        cachedPotentialReclaimableBytes = bytes
        return bytes
    }

    var selectedCleanupCandidates: [CleanupCandidate] {
        cleanupCandidates.filter { selectedCleanupCandidateIDs.contains($0.id) }
    }

    var selectedCleanupCandidate: CleanupCandidate? {
        guard let selectedItemID else {
            return nil
        }
        return cleanupCandidates.first { $0.item.id == selectedItemID }
    }

    var selectedCleanupBatchCandidates: [CleanupCandidate] {
        CleanupSelectionPlanner.topLevelCandidates(selectedCleanupCandidates)
    }

    var verifiedCleanupCandidates: [CleanupCandidate] {
        CleanupSelectionPlanner.verifiedDuplicateBatchCandidates(cleanupCandidates)
    }

    var selectedCleanupBatchContainsReviewRisk: Bool {
        CleanupSelectionPlanner.containsReviewRisk(selectedCleanupBatchCandidates)
    }

    var reclaimPlan: ReclaimPlan {
        guard let scan else {
            return ReclaimPlan(sections: [], primaryAction: nil)
        }
        guard let key = currentDerivedCacheKey else {
            return ReclaimPlan(sections: [], primaryAction: nil)
        }
        if cachedReclaimPlanKey == key {
            return cachedReclaimPlan
        }
        let plan = ReclaimPlanBuilder.build(scan: scan, visibleCleanupCandidates: cleanupCandidates)
        cachedReclaimPlanKey = key
        cachedReclaimPlan = plan
        return plan
    }

    var selectedReclaimableBytes: Int64 {
        selectedCleanupBatchCandidates.reduce(Int64(0)) { $0 + $1.reclaimableBytes }
    }

    func toggleCleanupCandidate(_ candidate: CleanupCandidate) {
        selectedItemID = candidate.item.id
        selection.toggleCleanupCandidate(candidate)
    }

    func selectVerifiedCleanupCandidates() {
        let candidates = verifiedCleanupCandidates
        selectedCleanupCandidateIDs = Set(candidates.map(\.id))
        selectedItemID = candidates.first?.item.id ?? selectedItemID
    }

    func selectAllVisibleCleanupCandidates() {
        let candidates = cleanupCandidates
        selectedCleanupCandidateIDs = Set(candidates.map(\.id))
        selectedItemID = candidates.first?.item.id ?? selectedItemID
    }

    var allVisibleCleanupCandidatesSelected: Bool {
        let visibleIDs = Set(cleanupCandidates.map(\.id))
        return !visibleIDs.isEmpty && visibleIDs.isSubset(of: selectedCleanupCandidateIDs)
    }

    func clearCleanupSelection() {
        selection.clearCleanupSelection()
    }

    func setCleanupLaneFilter(_ lane: CleanupLaneFilter) {
        guard filters.cleanupLaneFilter != lane else {
            return
        }
        filters.cleanupLaneFilter = lane
        clearCleanupSelection()
    }

    func resetDisplayFilters() {
        filters.resetDisplayFilters()
        invalidateDerivedCaches()
    }

    func resetCleanupFilters() {
        filters.resetCleanupFilters()
        invalidateDerivedCaches()
    }

    func ignoreCleanupCandidate(_ candidate: CleanupCandidate) {
        selection.ignoreCleanupCandidate(candidate)
        invalidateDerivedCaches()
    }

    func unignoreCleanupCandidate(_ candidate: CleanupCandidate) {
        selection.unignoreCleanupCandidate(candidate)
        invalidateDerivedCaches()
    }

    func clearIgnoredCleanupCandidates() {
        guard !ignoredCleanupCandidateIDs.isEmpty else { return }
        selection.clearIgnoredCleanupCandidates()
        invalidateDerivedCaches()
    }

    var ignoredCleanupCandidates: [CleanupCandidate] {
        guard let scan, !ignoredCleanupCandidateIDs.isEmpty else {
            return []
        }
        return scan.cleanupCandidates.filter { ignoredCleanupCandidateIDs.contains($0.id) }
    }

    func moveCleanupCandidateToTrash(_ candidate: CleanupCandidate) {
        selectedCleanupCandidateIDs = [candidate.id]
        selectedItemID = candidate.item.id
        moveSelectedCleanupCandidatesToTrash()
    }

    func moveSelectedCleanupCandidatesToTrash() {
        let candidates = selectedCleanupBatchCandidates
        guard !candidates.isEmpty else {
            return
        }

        if candidates.count != selectedCleanupCandidates.count {
            selectedCleanupCandidateIDs = Set(candidates.map(\.id))
        }

        pendingTrashReviewPlan = TrashReviewPlan(candidates: candidates)
    }

    func cancelPendingTrashReview() {
        pendingTrashReviewPlan = nil
    }

    func revealTrashReviewItem(_ item: TrashReviewPlan.Item) {
        if let message = FileActionService.reveal(item.url) {
            errorMessage = message
        }
    }

    func openTrashReviewItem(_ item: TrashReviewPlan.Item) {
        openURLAndSurfaceError(item.url)
    }

    func revealAllTrashReviewItems(_ items: [TrashReviewPlan.Item]) {
        let urls = items.map(\.url)
        if let message = FileActionService.revealAll(urls) {
            errorMessage = message
        }
    }

    func removePendingTrashReviewItem(_ item: TrashReviewPlan.Item) {
        selectedCleanupCandidateIDs.remove(item.id)
        let remaining = selectedCleanupBatchCandidates
        if remaining.isEmpty {
            pendingTrashReviewPlan = nil
        } else {
            pendingTrashReviewPlan = TrashReviewPlan(candidates: remaining)
        }
    }

    /// Drops every item in `items` from the pending review plan in one update. Used by
    /// `TrashReviewSection`'s "Remove All" affordance so the user can drop a whole section
    /// (e.g. all review-suggested items, leaving verified-only) without N clicks.
    func removeAllPendingTrashReviewItems(_ items: [TrashReviewPlan.Item]) {
        guard !items.isEmpty else { return }
        let ids = Set(items.map(\.id))
        selectedCleanupCandidateIDs.subtract(ids)
        let remaining = selectedCleanupBatchCandidates
        if remaining.isEmpty {
            pendingTrashReviewPlan = nil
        } else {
            pendingTrashReviewPlan = TrashReviewPlan(candidates: remaining)
        }
    }

    func confirmPendingTrashReview() {
        guard let plan = pendingTrashReviewPlan else {
            return
        }
        guard !isMovingToTrash else {
            return
        }

        let keeperItemIDs = currentKeeperItemIDs
        let itemsToMove = plan.items.filter { !keeperItemIDs.contains($0.id) }
        guard !itemsToMove.isEmpty else {
            errorMessage = "Every selected item is currently designated as the keeper for its duplicate group. Reassign the keeper before moving copies to Trash."
            pendingTrashReviewPlan = nil
            return
        }

        let urls = itemsToMove.map(\.url)
        let movedIDs = Set(itemsToMove.map(\.id))
        isMovingToTrash = true

        Task { [weak self] in
            let result: Result<Void, Error>
            do {
                try await Task.detached(priority: .userInitiated) {
                    try FileActionService.moveToTrashTransactionally(urls)
                }.value
                result = .success(())
            } catch {
                os_log("Trash move failed: %{public}@", log: Self.log, type: .error, String(describing: error))
                result = .failure(error)
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isMovingToTrash = false
                switch result {
                case .success:
                    self.ignoredCleanupCandidateIDs.formUnion(movedIDs)
                    self.selection.clearCleanupSelection()
                    self.selectedItemID = nil
                    self.pendingTrashReviewPlan = nil
                    self.markResultsNeedRefresh()
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                    if let batchError = error as? BatchTrashError {
                        switch batchError {
                        case .rollbackFailed, .missingTargets:
                            self.markResultsNeedRefresh()
                        default:
                            break
                        }
                    }
                }
            }
        }
    }

    var filteredTypeBreakdown: [FileTypeStat] {
        guard let scan else {
            return []
        }
        let trimmedQuery = filters.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return scan.typeBreakdown
        }
        let key = TypeBreakdownCacheKey(scanFinishedAt: scan.finishedAt, query: trimmedQuery)
        if cachedFilteredTypeBreakdownKey == key {
            return cachedFilteredTypeBreakdown
        }
        let value = scan.typeBreakdown.filter {
            $0.label.localizedCaseInsensitiveContains(trimmedQuery) ||
                $0.category.rawValue.localizedCaseInsensitiveContains(trimmedQuery)
        }
        cachedFilteredTypeBreakdownKey = key
        cachedFilteredTypeBreakdown = value
        return value
    }

    var filteredCategoryBreakdown: [FileCategoryStat] {
        guard let scan else {
            return []
        }
        let trimmedQuery = filters.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return scan.categoryBreakdown
        }
        let key = TypeBreakdownCacheKey(scanFinishedAt: scan.finishedAt, query: trimmedQuery)
        if cachedFilteredCategoryBreakdownKey == key {
            return cachedFilteredCategoryBreakdown
        }

        let typeStats = filteredTypeBreakdown
        var statsByCategory: [FileTypeStat.Category: (fileCount: Int, extensionCount: Int, totalBytes: Int64)] = [:]

        for stat in typeStats {
            var categoryStat = statsByCategory[stat.category] ?? (fileCount: 0, extensionCount: 0, totalBytes: 0)
            categoryStat.fileCount += stat.fileCount
            categoryStat.extensionCount += 1
            categoryStat.totalBytes += stat.totalBytes
            statsByCategory[stat.category] = categoryStat
        }

        let value = statsByCategory.map { category, stats in
            FileCategoryStat(
                category: category,
                fileCount: stats.fileCount,
                extensionCount: stats.extensionCount,
                totalBytes: stats.totalBytes
            )
        }
        .sorted { lhs, rhs in
            if lhs.totalBytes == rhs.totalBytes {
                return lhs.category.rawValue.localizedStandardCompare(rhs.category.rawValue) == .orderedAscending
            }
            return lhs.totalBytes > rhs.totalBytes
        }
        cachedFilteredCategoryBreakdownKey = key
        cachedFilteredCategoryBreakdown = value
        return value
    }

    func focusFileType(_ stat: FileTypeStat) {
        filters.fileTypeFocus = stat.label == "No Extension" ? "" : stat.label
        selectedView = .largestFiles
    }

    func revealSelectedItem() {
        guard let selectedItem else {
            return
        }
        if let message = FileActionService.reveal(selectedItem.url) {
            errorMessage = message
        }
    }

    func openSelectedItem() {
        guard let selectedItem else {
            return
        }
        openURLAndSurfaceError(selectedItem.url)
    }

    func copySelectedPath() {
        guard let selectedItem else {
            return
        }
        if let message = FileActionService.copyPath(selectedItem.url) {
            errorMessage = message
        }
    }

    /// Routes `FileActionService.open` errors back through `errorMessage`. The open call
    /// uses the throwing Swift API on a background task; without this wrapper a missing-app
    /// or permission-denied failure would land as an uncaught Task error and die silently
    /// rather than presenting a message to the user.
    private func openURLAndSurfaceError(_ url: URL) {
        Task { [weak self] in
            guard let self else { return }
            if let message = await FileActionService.open(url) {
                self.errorMessage = message
            }
        }
    }

    func moveSelectedItemToTrash() {
        guard let selectedItem else {
            return
        }

        guard selectedItem.id != scan?.rootItem.id else {
            errorMessage = "The scanned root cannot be moved to Trash from StorageScope."
            return
        }

        let candidate = selectedCleanupCandidate ?? synthesizedTrashCandidate(for: selectedItem)
        pendingTrashReviewPlan = TrashReviewPlan(candidates: [candidate])
    }

    private func synthesizedTrashCandidate(for item: StorageItem) -> CleanupCandidate {
        CleanupCandidate(
            kind: .general,
            item: item,
            reason: "Manually selected from \(activeView.title). Review the path before moving to Trash.",
            reclaimableBytes: item.displaySize,
            confidence: .review
        )
    }

    func canMoveItemToTrash(_ item: StorageItem) -> Bool {
        item.id != scan?.rootItem.id
    }

    private func filtered(_ items: [StorageItem]) -> [StorageItem] {
        let trimmedQuery = filters.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let focusedExtension = filters.fileTypeFocus

        return sorted(items.filter { item in
            let passesSize = item.displaySize >= filters.sizeFilter.threshold
            let passesQuery = item.matchesNormalizedSearchQuery(trimmedQuery)
            let passesExtension: Bool
            if let focusedExtension {
                // Empty-string focus = "No Extension" (set by focusFileType when stat.label == "No Extension")
                if focusedExtension.isEmpty {
                    passesExtension = (item.fileExtension ?? "").isEmpty
                } else {
                    passesExtension = (item.fileExtension ?? "").localizedCaseInsensitiveCompare(focusedExtension) == .orderedSame
                }
            } else {
                passesExtension = true
            }
            return passesSize && passesQuery && passesExtension
        })
    }

    private func sorted(_ items: [StorageItem]) -> [StorageItem] {
        items.sorted { lhs, rhs in
            switch filters.sortOption {
            case .sizeDescending:
                if lhs.displaySize == rhs.displaySize {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return lhs.displaySize > rhs.displaySize
            case .nameAscending:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .modifiedNewest:
                return (lhs.modifiedAt ?? .distantPast) > (rhs.modifiedAt ?? .distantPast)
            case .modifiedOldest:
                return (lhs.modifiedAt ?? .distantFuture) < (rhs.modifiedAt ?? .distantFuture)
            case .kind:
                if lhs.kind == rhs.kind {
                    return lhs.displaySize > rhs.displaySize
                }
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
        }
    }

    private func cleanupCandidate(_ candidate: CleanupCandidate, passes lane: CleanupLaneFilter) -> Bool {
        switch lane {
        case .all:
            return true
        case .verified:
            return candidate.isHighConfidenceVerifiedDuplicate
        case .suggestions:
            return !candidate.isHighConfidenceVerifiedDuplicate
        }
    }

    private var currentDerivedCacheKey: DerivedCacheKey? {
        guard let scan else {
            return nil
        }
        return DerivedCacheKey(
            scanFinishedAt: scan.finishedAt,
            query: filters.query,
            sizeFilter: filters.sizeFilter,
            sortOption: filters.sortOption,
            cleanupLaneFilter: filters.cleanupLaneFilter,
            ignoredCleanupCandidateIDs: ignoredCleanupCandidateIDs
        )
    }

    private func invalidateDerivedCaches() {
        os_signpost(.event, log: Self.log, name: "cache_invalidate_derived", signpostID: Self.signpostID,
                    "activeView=%@", String(describing: activeView))
        cachedCleanupCandidatesKey = nil
        cachedCleanupCandidates = []
        cachedPotentialReclaimableBytesKey = nil
        cachedPotentialReclaimableBytes = 0
        cachedReclaimPlanKey = nil
        cachedReclaimPlan = ReclaimPlan(sections: [], primaryAction: nil)
        cachedOldLargeFilesKey = nil
        cachedOldLargeFiles = []
        cachedDuplicateGroupsKey = nil
        cachedDuplicateGroups = []
        cachedVerifiedDuplicateGroupsKey = nil
        cachedVerifiedDuplicateGroups = []
        cachedFilteredTypeBreakdownKey = nil
        cachedFilteredTypeBreakdown = []
        cachedFilteredCategoryBreakdownKey = nil
        cachedFilteredCategoryBreakdown = []
        // cachedItemsKey/cachedItems intentionally NOT dropped here. `items(for:)`'s key
        // comparison is the source of truth — its key normalizes irrelevant dims per view,
        // so a filter change that doesn't affect the active view's output is a no-op
        // cache hit on the next call. Force-clearing here would discard a still-valid slice
        // on every neighborhood touch (e.g. toggling cleanupLaneFilter while on .largestFiles).
    }

    private func invalidateItemsCache() {
        os_signpost(.event, log: Self.log, name: "cache_invalidate_items", signpostID: Self.signpostID,
                    "activeView=%@", String(describing: activeView))
        cachedItemsKey = nil
        cachedItems = []
    }

    private func markResultsNeedRefresh() {
        session.resultsNeedRefresh = true
        // Trash changes are more actionable than a stale cancel notice — let the
        // resultsNeedRefresh notice take the banner.
        session.lastCancellationMessage = nil
        progress = ScanProgress(
            scannedItemCount: scan?.scannedItemCount ?? progress.scannedItemCount,
            totalBytes: scan?.totalBytes ?? progress.totalBytes,
            currentPath: "Results changed; rescan when ready"
        )
    }

    private func abandonActiveScan() {
        cancellation?.cancel()
        scanTask?.cancel()
        activeScanID = nil
        cancellation = nil
        scanTask = nil
    }

    private var currentScanOptions: ScanOptionsSnapshot {
        ScanOptionsSnapshot(
            includeHiddenFiles: filters.includeHiddenFiles,
            oldFileAgeDays: filters.oldFileAgeDays,
            duplicateCandidateThresholdMB: filters.duplicateCandidateThresholdMB
        )
    }

    private func replaceActiveRootAccess(with access: SecurityScopedResourceAccess) {
        activeRootAccess?.stop()
        activeRootAccess = access
    }

    private func isCurrentScan(_ scanID: UUID, cancellation scanCancellation: ScanCancellation) -> Bool {
        activeScanID == scanID && cancellation === scanCancellation
    }

    private func clearActiveScan(_ scanID: UUID, cancellation scanCancellation: ScanCancellation) {
        guard isCurrentScan(scanID, cancellation: scanCancellation) else {
            return
        }

        activeScanID = nil
        cancellation = nil
        scanTask = nil
    }
}

extension ScanStore {
    /// Categorizes an error caught from scan or bookmark resolve so the
    /// `errorMessage` alert can include the affected path/operation when known
    /// and skip surfacing entirely on cancellation. Recorded on
    /// `ScanSession.lastErrorCategory` so the UI/tests can assert on the failure
    /// shape without parsing the alert string.
    enum ScanStoreErrorCategory: Equatable {
        /// Sandbox/permission denial — user must re-grant folder access.
        case permissionDenied(path: String)
        /// Folder no longer exists at the bookmarked/scanned location.
        case missingFolder(path: String)
        /// Persisted security-scoped bookmark data couldn't be decoded/resolved.
        case staleBookmark(path: String)
        /// Other unrecoverable scan error — surfaced without a specific path.
        case scanInternal(message: String)

        /// The string surfaced in `errorMessage` (and thus the SwiftUI alert).
        /// Path-bearing cases always include the affected path so users know which
        /// folder StorageScope couldn't reach.
        var userMessage: String {
            switch self {
            case .permissionDenied(let path):
                return "StorageScope could not access \"\(path)\". Choose the folder again or grant access in macOS privacy settings."
            case .missingFolder(let path):
                return "The folder no longer exists at \"\(path)\". Pick a different folder to scan."
            case .staleBookmark(let path):
                return "StorageScope could not reopen this folder (\(path)). Choose it again to refresh access."
            case .scanInternal(let message):
                return message
            }
        }
    }

    /// Categorizes an error caught from scan or bookmark resolve so the
    /// `errorMessage` alert can include the affected path when known and skip
    /// surfacing entirely on cancellation. Recorded on `ScanSession.lastErrorCategory`
    /// so the UI/tests can assert on the failure shape without parsing the alert string.
    static func categorize(_ error: Error, fallbackPath: String? = nil) -> ScanStoreErrorCategory? {
        if let scannerError = error as? FileSystemScannerError {
            switch scannerError {
            case .cancelled:
                return nil
            case .rootDoesNotExist(let url):
                return .missingFolder(path: url.path)
            }
        }
        if let bookmarkError = error as? BookmarkError {
            switch bookmarkError {
            case .accessDenied(let url):
                return .permissionDenied(path: url.path)
            case .bookmarkDataInvalid(let path, underlying: _):
                return .staleBookmark(path: path)
            case .fileMissing(let url):
                return .missingFolder(path: url.path)
            case .bookmarkCreationFailed, .volumeNotMounted:
                break
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            // Bookmark decoding failure (corrupt data, moved source, sandbox invalidation).
            // NSURLErrorKey sometimes carries the URL; otherwise fall back to the path the
            // user asked us to reopen so the alert still names the folder.
            let path = (nsError.userInfo[NSURLErrorKey] as? URL)?.path
                ?? fallbackPath
            if let path {
                return .staleBookmark(path: path)
            }
        }
        if let fallbackPath {
            return .scanInternal(message: "\(error.localizedDescription) (Folder: \(fallbackPath))")
        }
        return .scanInternal(message: error.localizedDescription)
    }
}

// MARK: - Display-layer relative paths (UI_PLAN.md P1.2)

extension ScanStore {
    /// Row-subtitle path relative to the scan root ("Media Projects/render.mov"
    /// instead of "/Volumes/Sample/fixture-scan/Media Projects/render.mov"). The root is
    /// already shown in the scan header, so repeating the absolute prefix on every
    /// row was pure noise. Falls back to the redacted full path when redaction is
    /// on, and to the absolute path for items outside the root (shouldn't happen).
    func displayRelativePath(for item: StorageItem) -> String {
        guard !filters.redactionEnabled else { return filters.displayPath(for: item) }
        guard let rootURL = scan?.rootURL else { return item.url.path }
        return Self.relativePath(of: item.url, under: rootURL) ?? item.url.path
    }

    /// Relative-path variant of `FilterStore.displayParentPath(for:)` — the
    /// containing folder only, relative to the scan root.
    func displayRelativeParentPath(for item: StorageItem) -> String {
        guard !filters.redactionEnabled else { return filters.displayParentPath(for: item) }
        let parent = item.url.deletingLastPathComponent()
        guard let rootURL = scan?.rootURL else { return parent.path }
        return Self.relativePath(of: parent, under: rootURL) ?? parent.path
    }

    /// Path of `url` relative to `root`, or nil when `url` isn't inside `root`.
    /// The root itself maps to its display name rather than an empty string.
    static func relativePath(of url: URL, under root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return nil }
        let suffix = path.dropFirst(rootPath.count).drop(while: { $0 == "/" })
        guard !suffix.isEmpty else { return root.lastPathComponent }
        return String(suffix)
    }
}

// MARK: - Folder Tree drill-down (UI_PLAN.md UX round 2)

extension ScanStore {
    /// Verified-duplicate reclaim total, surfaced as a sidebar badge so the user can
    /// see where reclaimable space lives before clicking through.
    var verifiedReclaimableBytes: Int64 {
        verifiedDuplicateGroups.reduce(Int64(0)) { $0 + $1.reclaimableBytes }
    }

    /// Jumps to the Folder Tree with `item` selected and every ancestor expanded —
    /// the drill-down behind Storage Map rows and the "Show in Folder Tree" context
    /// menu action. If the item wasn't retained in the tree (pruned by the retained-
    /// items cap), the tree still opens at the root rather than failing silently.
    func revealInFolderTree(_ item: StorageItem) {
        if let root = scan?.rootItem {
            var chain: [String] = []
            if Self.ancestorChain(from: root, to: item.id, chain: &chain) {
                treeExpandedIDs.formUnion(chain)
                selectedItemID = item.id
            } else {
                treeExpandedIDs.insert(root.id)
            }
        }
        selectedView = .tree
    }

    /// Depth-first path of container IDs from `node` down to (excluding) `targetID`.
    /// Returns false when the target isn't in the retained tree.
    private static func ancestorChain(from node: StorageItem, to targetID: String, chain: inout [String]) -> Bool {
        if node.id == targetID { return true }
        guard node.isContainer, !node.children.isEmpty else { return false }
        chain.append(node.id)
        for child in node.children {
            if ancestorChain(from: child, to: targetID, chain: &chain) {
                return true
            }
        }
        chain.removeLast()
        return false
    }
}

// MARK: - Keyboard selection (UI_PLAN.md UX round 3)

extension ScanStore {
    /// Moves the selection by `offset` within the active view's ranked items —
    /// the model behind arrow-key navigation in the item tables. Selects the first
    /// item when nothing is selected yet. Returns the newly selected ID so the view
    /// can scroll it into sight, or nil when there is nothing to select.
    @discardableResult
    func selectAdjacentItem(offset: Int) -> String? {
        let items = items(for: activeView)
        guard !items.isEmpty else { return nil }

        let newIndex: Int
        if let currentIndex = items.firstIndex(where: { $0.id == selectedItemID }) {
            newIndex = min(max(currentIndex + offset, 0), items.count - 1)
        } else {
            newIndex = offset >= 0 ? 0 : items.count - 1
        }

        let id = items[newIndex].id
        selectedItemID = id
        return id
    }
}

// MARK: - Tree, cleanup, and type-ahead keyboard navigation (UI_PLAN.md UX round 4)

extension ScanStore {
    /// The Folder Tree rows currently on screen, in visual order: a depth-first walk
    /// of the retained tree that descends only into expanded containers and applies
    /// the same child filters as `TreeNodeRow` (size threshold + search subtree
    /// matches). This is the model behind ↑/↓ in the tree.
    func visibleTreeItems() -> [StorageItem] {
        guard let root = scan?.rootItem else { return [] }
        var result: [StorageItem] = []
        var stack: [StorageItem] = [root]
        let threshold = filters.sizeFilter.threshold
        while let node = stack.popLast() {
            result.append(node)
            guard node.isContainer, treeExpandedIDs.contains(node.id) else { continue }
            // Reverse so the stack pops children in display order.
            for child in node.children.reversed()
            where child.displaySize >= threshold && (searchSubtreeMatchIDs?.contains(child.id) ?? true) {
                stack.append(child)
            }
        }
        return result
    }

    /// ↑/↓ in the Folder Tree: moves the selection through the visible rows,
    /// clamping at both ends. Selects the root when nothing is selected yet.
    @discardableResult
    func selectAdjacentTreeItem(offset: Int) -> String? {
        selectAdjacent(in: visibleTreeItems().map(\.id), offset: offset)
    }

    /// ← in the Folder Tree: collapses the selected container if it's expanded,
    /// otherwise walks up to the parent — mirrors NSOutlineView/Finder list view.
    @discardableResult
    func collapseOrAscendTreeSelection() -> String? {
        let visible = visibleTreeItems()
        guard let selected = visible.first(where: { $0.id == selectedItemID }) else {
            return selectAdjacentTreeItem(offset: 1)
        }
        if selected.isContainer, treeExpandedIDs.contains(selected.id) {
            treeExpandedIDs.remove(selected.id)
            return selected.id
        }
        guard let root = scan?.rootItem, let parent = Self.parent(of: selected.id, under: root) else {
            return selected.id
        }
        selectedItemID = parent.id
        return parent.id
    }

    /// → in the Folder Tree: expands the selected container, or steps into its
    /// first visible child when it's already expanded.
    @discardableResult
    func expandOrDescendTreeSelection() -> String? {
        let visible = visibleTreeItems()
        guard let selected = visible.first(where: { $0.id == selectedItemID }) else {
            return selectAdjacentTreeItem(offset: 1)
        }
        guard selected.isContainer, !selected.children.isEmpty else { return selected.id }
        if !treeExpandedIDs.contains(selected.id) {
            treeExpandedIDs.insert(selected.id)
            return selected.id
        }
        let after = visibleTreeItems()
        if let index = after.firstIndex(where: { $0.id == selected.id }), index + 1 < after.count {
            selectedItemID = after[index + 1].id
            return after[index + 1].id
        }
        return selected.id
    }

    /// ↑/↓ in Cleanup Review: moves the row selection through the visible
    /// candidates. Space then toggles via `toggleSelectedCleanupCandidate()`.
    @discardableResult
    func selectAdjacentCleanupCandidate(offset: Int) -> String? {
        selectAdjacent(in: cleanupCandidates.map(\.item.id), offset: offset)
    }

    /// Space in Cleanup Review: toggles the check on the selected candidate.
    func toggleSelectedCleanupCandidate() {
        guard let candidate = cleanupCandidates.first(where: { $0.item.id == selectedItemID }) else { return }
        toggleCleanupCandidate(candidate)
    }

    /// Type-to-select in the ranked tables: jumps to the first item whose display
    /// name starts with `prefix` (case-insensitive), like Finder.
    @discardableResult
    func selectItem(matchingPrefix prefix: String) -> String? {
        let normalized = prefix.lowercased()
        guard !normalized.isEmpty else { return nil }
        let ranked = items(for: activeView)
        guard let match = ranked.first(where: { filters.displayName(for: $0).lowercased().hasPrefix(normalized) }) else {
            return nil
        }
        selectedItemID = match.id
        return match.id
    }

    /// Escape: clears an active search. Returns false when there was nothing to
    /// clear so the caller can pass the key press on.
    @discardableResult
    func clearSearchIfActive() -> Bool {
        guard !filters.searchText.isEmpty else { return false }
        filters.searchText = ""
        return true
    }

    private func selectAdjacent(in ids: [String], offset: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        let newIndex: Int
        if let currentIndex = ids.firstIndex(where: { $0 == selectedItemID }) {
            newIndex = min(max(currentIndex + offset, 0), ids.count - 1)
        } else {
            newIndex = offset >= 0 ? 0 : ids.count - 1
        }
        selectedItemID = ids[newIndex]
        return ids[newIndex]
    }

    private static func parent(of targetID: String, under node: StorageItem) -> StorageItem? {
        for child in node.children {
            if child.id == targetID { return node }
            if let found = parent(of: targetID, under: child) { return found }
        }
        return nil
    }
}
