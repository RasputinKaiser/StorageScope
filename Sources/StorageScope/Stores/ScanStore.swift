import Foundation
import StorageScopeCore
import SwiftUI
import os

@MainActor
final class ScanStore: ObservableObject {
    private static let overviewItemCap = 100

    /// os_signpost surface for Instruments. Mirrors FileSystemScanner's subsystem so app-side
    /// and scanner-side spans group together when filtering by subsystem in Instruments.
    private static let log = OSLog(subsystem: "com.rasputinkaiser.StorageScope", category: "scan")
    private static let signpostID = OSSignpostID(log: log)

    private static func defaultHashCacheURL() -> URL? {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("StorageScopeDuplicateHashCache.json")
    }

    struct ScanOptionsSnapshot: Equatable {
        let includeHiddenFiles: Bool
        let oldFileAgeDays: Int
    }

    private struct DerivedCacheKey: Equatable {
        let scanFinishedAt: Date
        let query: String
        let sizeFilter: SizeFilter
        let sortOption: ItemSortOption
        let cleanupLaneFilter: CleanupLaneFilter
        let ignoredCleanupCandidateIDs: Set<String>
    }

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
        ensureAncestorsExpanded(forItemID: ids[next])
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
        ensureAncestorsExpanded(forItemID: ids[prev])
    }

    /// Drop `currentSearchResultIndex` when the search query is cleared
    /// (FilterStore.searchResultIDs becomes nil). Cheap to call idempotently.
    func resetSearchResultNavigationIfApplicable() {
        if filters.searchResultIDs == nil {
            currentSearchResultIndex = nil
        }
    }

    /// Walks the retained tree from the scan root toward `itemID`, inserting every
    /// ancestor's id into `selection.treeExpandedIDs` so the matched row becomes
    /// visible without manual expand taps. Called by `advanceSearchResult` /
    /// `reverseSearchResult` so Cmd+G surfaces the matched item in the Folder Tree
    /// even when intermediate folders are collapsed.
    ///
    /// Returns silently if no scan is loaded or the id is not reachable through the
    /// retained tree (the duplicate-candidates / cleanup-candidates arrays can produce
    /// matches that aren't part of the collapsed retained tree — selection still
    /// applies for views that don't need expansion, like StorageItemTable).
    private func ensureAncestorsExpanded(forItemID itemID: String) {
        guard let scan else { return }
        guard let path = ancestorPath(from: scan.rootItem, to: itemID) else { return }
        // The root is auto-expanded by TreeExplorerView.onAppear; insert every
        // intermediate ancestor (skip the target itself — TreeExplorerView's
        // `isExpanded` is about disclosure triangles for containers, not leaf items).
        for ancestor in path.dropFirst() where ancestor.isContainer {
            selection.treeExpandedIDs.insert(ancestor.id)
        }
    }

    /// DFS search through the retained tree returning the path `[root, …, target]`
    /// or `nil` if the target isn't reachable. Used by `ensureAncestorsExpanded`
    /// so we get the full ancestor chain in one recursive pass.
    private func ancestorPath(from root: StorageItem, to targetID: String) -> [StorageItem]? {
        if root.id == targetID {
            return [root]
        }
        for child in root.children {
            if let path = ancestorPath(from: child, to: targetID) {
                return [root] + path
            }
        }
        return nil
    }
    private var markResultsNeedRefreshWhenCurrentScanCompletes = false
    private var selectedViewWhenCurrentScanCompletes: SmartView?
    private var selectVerifiedCleanupWhenCurrentScanCompletes = false

    private var keeperOverridesByChecksum: [String: String] = [:]

    private var activeScanID: UUID?
    private var cancellation: ScanCancellation?
    private var scanTask: Task<Void, Never>?
    private let bookmarkStore = SecurityScopedBookmarkStore()
    private let hashCache = DuplicateHashCache(cacheURL: ScanStore.defaultHashCacheURL())

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
    private var cachedOldLargeFilesKey: DerivedCacheKey?
    private var cachedOldLargeFiles: [StorageItem] = []
    private var cachedDuplicateGroupsKey: DerivedCacheKey?
    private var cachedDuplicateGroups: [DuplicateSizeGroup] = []
    private var cachedVerifiedDuplicateGroupsKey: DerivedCacheKey?
    private var cachedVerifiedDuplicateGroups: [VerifiedDuplicateGroup] = []

    lazy var onDemandVerification: OnDemandVerificationStore = OnDemandVerificationStore(
        hashCache: hashCache,
        scanLookup: { [weak self] in self?.scan },
        coordinateInvalidate: { [weak self] in self?.invalidateDerivedCaches() },
        reportError: { [weak self] message in self?.errorMessage = message }
    )

    lazy var filters = FilterStore(
        scanLookup: { [weak self] in self?.scan },
        coordinateInvalidate: { [weak self] in self?.invalidateDerivedCaches() },
        recordSearchRecent: { [weak self] term in self?.searchRecents.add(term) }
    )

    /// Typed Binding<T> for any writable FilterStore property — used by Picker/Stepper/Toggle
    /// in views since `$store.filters.X` can't traverse ObservableObject's sub-store boundary.
    func filterBinding<T>(_ keyPath: ReferenceWritableKeyPath<FilterStore, T>) -> Binding<T> {
        Binding(get: { self.filters[keyPath: keyPath] }, set: { self.filters[keyPath: keyPath] = $0 })
    }

    var oldFileAgeDays: Int { filters.oldFileAgeDays }

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
        guard let rootItem = scan?.rootItem else { return false }
        let allContainers = allTreeContainerIDs(in: rootItem)
        return !allContainers.allSatisfy { treeExpandedIDs.contains($0) }
    }

    var canCollapseTree: Bool {
        !treeExpandedIDs.isEmpty
    }

    /// Expands every container (folder/package) in the retained scan tree. Bounded by the
    /// same retention criteria as the scan itself, so big scans only expand what's actually
    /// visible — the renderer never sees the dropped children.
    func expandEntireTree() {
        guard let rootItem = scan?.rootItem else { return }
        treeExpandedIDs = allTreeContainerIDs(in: rootItem)
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
        do {
            guard let resolvedURL = try bookmarkStore.resolve(path: path) else {
                errorMessage = "StorageScope needs you to choose this folder again before rescanning it in the sandbox."
                chooseFolderAndScan(startingAt: URL(fileURLWithPath: path, isDirectory: true))
                return
            }

            scanUserGrantedURL(resolvedURL.url, access: resolvedURL.access)
        } catch {
            errorMessage = "StorageScope could not reopen this folder bookmark. Choose it again to refresh access. \(error.localizedDescription)"
            chooseFolderAndScan(startingAt: URL(fileURLWithPath: path, isDirectory: true))
        }
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

    var mountedVolumes: [URL] {
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
        guard let lastScannedURL = session.lastScannedURL else {
            chooseFolderAndScan()
            return
        }

        do {
            if let resolvedURL = try bookmarkStore.resolve(path: lastScannedURL.standardizedFileURL.path) {
                scanUserGrantedURL(resolvedURL.url, access: resolvedURL.access)
            } else {
                chooseFolderAndScan(startingAt: lastScannedURL)
            }
        } catch {
            errorMessage = "StorageScope needs refreshed access before rescanning. \(error.localizedDescription)"
            chooseFolderAndScan(startingAt: lastScannedURL)
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
            session.lastCancellationMessage = scan != nil
                ? "Scan of \(pathLabel) was canceled. Previous results are still shown; rescan when you are ready."
                : "Scan of \(pathLabel) was canceled. Rescan or pick another folder when ready."
            activeScanID = nil
            cancellation = nil
            scanTask = nil
            isScanning = false
            progress = ScanProgress(scannedItemCount: 0, totalBytes: 0, currentPath: "Scan cancelled")
        }
    }

    private func scanUserGrantedURL(_ url: URL, access: SecurityScopedResourceAccess? = nil) {
        abandonActiveScan()

        do {
            let scopedAccess = try access ?? SecurityScopedResourceAccess(url: url)
            replaceActiveRootAccess(with: scopedAccess)
            bookmarkStore.remember(url)
            scan(url)
        } catch {
            isScanning = false
            progress = ScanProgress(scannedItemCount: 0, totalBytes: 0, currentPath: "Access denied")
            errorMessage = error.localizedDescription
        }
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
        session.resultsNeedRefresh = false
        isScanning = true
        progress = ScanProgress(scannedItemCount: 0, totalBytes: 0, currentPath: url.path)

        let scanID = UUID()
        let thresholds = ScanOptionPolicy.interactiveScanThresholds()
        let options = ScanOptions(
            includeHidden: filters.includeHiddenFiles,
            oldFileAgeDays: filters.oldFileAgeDays,
            largeFileThreshold: thresholds.largeFileThreshold,
            duplicateCandidateThreshold: thresholds.duplicateCandidateThreshold,
            maxRankedResults: 800
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
                let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StorageScan, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let scanner = FileSystemScanner(hashCache: hashCache)
                            let scan = try scanner.scan(
                                root: url,
                                options: options,
                                cancellation: scanCancellation,
                                progress: { progress in
                                    Task { @MainActor [weak self, scanID, scanCancellation] in
                                        guard let self, self.isCurrentScan(scanID, cancellation: scanCancellation) else {
                                            return
                                        }
                                        self.progress = progress
                                    }
                                }
                            )
                            continuation.resume(returning: scan)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }

                guard !Task.isCancelled, isCurrentScan(scanID, cancellation: scanCancellation) else {
                    return
                }

                scan = result
                let cacheToPersist = hashCache
                let pathsScanned = Set(result.retainedItems.map { $0.url.standardizedFileURL.path })
                let persistLog = Self.log
                let persistSignpostID = Self.signpostID
                Task.detached(priority: .utility) {
                    os_signpost(.begin, log: persistLog, name: "persist", signpostID: persistSignpostID,
                                "entries=%d", cacheToPersist.entryCount)
                    _ = cacheToPersist.purgeStale(except: pathsScanned)
                    cacheToPersist.persist()
                    os_signpost(.end, log: persistLog, name: "persist", signpostID: persistSignpostID)
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
                clearActiveScan(scanID, cancellation: scanCancellation)
            } catch FileSystemScannerError.cancelled {
                guard isCurrentScan(scanID, cancellation: scanCancellation) else {
                    return
                }
                isScanning = false
                markResultsNeedRefreshWhenCurrentScanCompletes = false
                selectedViewWhenCurrentScanCompletes = nil
                selectVerifiedCleanupWhenCurrentScanCompletes = false
                progress = ScanProgress(scannedItemCount: 0, totalBytes: 0, currentPath: "Scan cancelled")
                clearActiveScan(scanID, cancellation: scanCancellation)
            } catch {
                guard isCurrentScan(scanID, cancellation: scanCancellation) else {
                    return
                }
                isScanning = false
                markResultsNeedRefreshWhenCurrentScanCompletes = false
                selectedViewWhenCurrentScanCompletes = nil
                selectVerifiedCleanupWhenCurrentScanCompletes = false
                errorMessage = error.localizedDescription
                clearActiveScan(scanID, cancellation: scanCancellation)
            }
        }
    }

    func items(for view: SmartView) -> [StorageItem] {
        guard let scan else {
            return []
        }

        let key = ItemsCacheKey(
            scanFinishedAt: scan.finishedAt,
            view: view,
            query: filters.query,
            sizeFilter: filters.sizeFilter,
            sortOption: filters.sortOption,
            cleanupLaneFilter: filters.cleanupLaneFilter,
            fileTypeFocus: filters.fileTypeFocus,
            ignoredCleanupCandidateIDs: ignoredCleanupCandidateIDs
        )
        if cachedItemsKey == key {
            return cachedItems
        }

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
        FileActionService.reveal(item.url)
    }

    func openTrashReviewItem(_ item: TrashReviewPlan.Item) {
        FileActionService.open(item.url)
    }

    func revealAllTrashReviewItems(_ items: [TrashReviewPlan.Item]) {
        let urls = items.map(\.url)
        FileActionService.revealAll(urls)
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
        return scan.typeBreakdown.filter {
            $0.label.localizedCaseInsensitiveContains(trimmedQuery) ||
                $0.category.rawValue.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    var filteredCategoryBreakdown: [FileCategoryStat] {
        guard let scan else {
            return []
        }
        guard !filters.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return scan.categoryBreakdown
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

        return statsByCategory.map { category, stats in
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
    }

    func focusFileType(_ stat: FileTypeStat) {
        filters.fileTypeFocus = stat.label == "No Extension" ? "" : stat.label
        selectedView = .largestFiles
    }

    func revealSelectedItem() {
        guard let selectedItem else {
            return
        }
        FileActionService.reveal(selectedItem.url)
    }

    func openSelectedItem() {
        guard let selectedItem else {
            return
        }
        FileActionService.open(selectedItem.url)
    }

    func copySelectedPath() {
        guard let selectedItem else {
            return
        }
        FileActionService.copyPath(selectedItem.url)
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
        invalidateItemsCache()
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
            oldFileAgeDays: filters.oldFileAgeDays
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
