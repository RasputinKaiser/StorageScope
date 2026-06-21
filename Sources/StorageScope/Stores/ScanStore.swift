import AppKit
import Foundation
import StorageScopeCore

struct RecentScanEntry: Codable, Identifiable, Hashable {
    let path: String
    let scannedAt: Date
    let totalBytes: Int64

    var id: String { path }
}

@MainActor
final class ScanStore: ObservableObject {
    private static let recentScanPathsKey = "StorageScope.recentScanPaths"
    private static let recentScanEntriesKey = "StorageScope.recentScanEntries"
    private static let overviewItemCap = 100

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
        let ignoredCleanupCandidateIDs: Set<String>
    }

    @Published var selectedView: SmartView? = .overview {
        didSet { invalidateItemsCache() }
    }
    @Published private var session = ScanSession()
    @Published private var filter = ScanFilter()
    @Published private var selection = ScanSelection()
    @Published var errorMessage: String?
    @Published var pendingTrashReviewPlan: TrashReviewPlan?
    @Published private(set) var recentScanEntries: [RecentScanEntry]
    // searchText is the immediate input bound to .searchable; query is its debounced
    // downstream value that filters read. Keeping them split means per-keystroke
    // recompute is bounded to one publish per ~200ms, not per character.
    @Published var searchText: String = "" {
        didSet {
            guard oldValue != searchText else { return }
            scheduleSearchTextDebounce()
        }
    }
    @Published private(set) var isMovingToTrash = false
    @Published private(set) var searchSubtreeMatchIDs: Set<String>?
    private var markResultsNeedRefreshWhenCurrentScanCompletes = false
    private var selectedViewWhenCurrentScanCompletes: SmartView?
    private var selectVerifiedCleanupWhenCurrentScanCompletes = false
    private var searchTextDebounceTask: Task<Void, Never>?

    private var keeperOverridesByChecksum: [String: String] = [:]

    /// Verified duplicate groups discovered via user-triggered "Verify Now" actions, layered on
    /// top of the scan-time `scan.verifiedDuplicateGroups`. Keyed by checksum for dedupe so a
    /// re-verify of the same group replaces rather than duplicates the entry.
    @Published private var onDemandVerifiedGroupsByChecksum: [String: VerifiedDuplicateGroup] = [:]
    @Published private(set) var verifyingGroupIDs: Set<String> = []

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

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.recentScanEntriesKey),
           let decoded = try? JSONDecoder().decode([RecentScanEntry].self, from: data) {
            recentScanEntries = decoded
        } else {
            // One-time migration from the legacy string-array recent-scans list.
            let legacyPaths = UserDefaults.standard.stringArray(forKey: Self.recentScanPathsKey) ?? []
            let now = Date()
            recentScanEntries = legacyPaths.map { RecentScanEntry(path: $0, scannedAt: now, totalBytes: 0) }
            if !legacyPaths.isEmpty {
                UserDefaults.standard.removeObject(forKey: Self.recentScanPathsKey)
            }
        }
    }

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
            rebuildSearchSubtreeMatchIDs()
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

    var query: String {
        get { filter.query }
        set {
            filter.query = newValue
            invalidateDerivedCaches()
            rebuildSearchSubtreeMatchIDs()
        }
    }

    var sizeFilter: SizeFilter {
        get { filter.sizeFilter }
        set {
            filter.sizeFilter = newValue
            invalidateDerivedCaches()
        }
    }

    var sortOption: ItemSortOption {
        get { filter.sortOption }
        set {
            filter.sortOption = newValue
            invalidateDerivedCaches()
        }
    }

    var cleanupLaneFilter: CleanupLaneFilter {
        get { filter.cleanupLaneFilter }
        set {
            filter.cleanupLaneFilter = newValue
            invalidateDerivedCaches()
        }
    }

    var includeHiddenFiles: Bool {
        get { filter.includeHiddenFiles }
        set { filter.includeHiddenFiles = newValue }
    }

    var oldFileAgeDays: Int {
        get { filter.oldFileAgeDays }
        set { filter.oldFileAgeDays = newValue }
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

    // Precomputes the set of retained item IDs whose subtree contains a query match, so the
    // tree view avoids O(n²) per-row recursive matching. Single post-order pass: a node is
    // included when it matches OR any descendant matches. Rebuilt on scan/query change.
    private func rebuildSearchSubtreeMatchIDs() {
        guard let scan else {
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

    var selectedItem: StorageItem? {
        guard let scan else {
            return nil
        }
        guard let selectedItemID else {
            return scan.rootItem
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
        if scanOptionsAreStale {
            return "Scan options changed. Current results still reflect the previous hidden-file and age settings."
        }
        if session.resultsNeedRefresh {
            return "Results changed after moving items to Trash. Review can continue, or rescan when you are ready."
        }
        return nil
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

    func forgetRecentScanPath(_ path: String) {
        recentScanEntries.removeAll { $0.path == path }
        persistRecentScanEntries()
    }

    private func persistRecentScanEntries() {
        if let data = try? JSONEncoder().encode(recentScanEntries) {
            UserDefaults.standard.set(data, forKey: Self.recentScanEntriesKey)
        }
    }

    var mountedVolumes: [URL] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsBrowsableKey, .volumeIsInternalKey]
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
        rememberScanURL(url)
        session.lastScannedURL = url
        selection.resetForNewScan()
        keeperOverridesByChecksum.removeAll()
        onDemandVerifiedGroupsByChecksum.removeAll()
        verifyingGroupIDs.removeAll()
        invalidateDerivedCaches()
        errorMessage = nil
        session.resultsNeedRefresh = false
        isScanning = true
        progress = ScanProgress(scannedItemCount: 0, totalBytes: 0, currentPath: url.path)

        let scanID = UUID()
        let thresholds = ScanOptionPolicy.interactiveScanThresholds()
        let options = ScanOptions(
            includeHidden: includeHiddenFiles,
            oldFileAgeDays: oldFileAgeDays,
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
                Task.detached(priority: .utility) { cacheToPersist.persist() }
                rememberScanURL(url, scannedAt: result.finishedAt, totalBytes: result.totalBytes)
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
            query: query,
            sizeFilter: sizeFilter,
            sortOption: sortOption,
            cleanupLaneFilter: cleanupLaneFilter,
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
        let result = filtered(scan.oldLargeFiles.filter { $0.displaySize >= max(sizeFilter.threshold, 100_000_000) })
        cachedOldLargeFilesKey = key
        cachedOldLargeFiles = result
        return result
    }

    var duplicateGroups: [DuplicateSizeGroup] {
        guard let scan else {
            return []
        }
        // Layer scan-time verified groups with on-demand ones so items that became verified
        // via "Verify Now" disappear from the same-size candidate list.
        var mergedVerifiedGroups = scan.verifiedDuplicateGroups
        mergedVerifiedGroups.append(contentsOf: onDemandVerifiedGroupsByChecksum.values)
        return DuplicateReviewPlanner.unverifiedSizeGroups(
            sizeGroups: scan.duplicateSizeGroups,
            verifiedGroups: mergedVerifiedGroups
        )
            .filter { $0.byteSize >= max(sizeFilter.threshold, 100_000_000) }
            .map { group in
                DuplicateSizeGroup(byteSize: group.byteSize, items: filtered(group.items))
            }
            .filter { $0.items.count > 1 }
    }

    var verifiedDuplicateGroups: [VerifiedDuplicateGroup] {
        guard let scan else {
            return onDemandVerifiedGroupsByChecksum.isEmpty
                ? []
                : Array(onDemandVerifiedGroupsByChecksum.values).filter { $0.byteSize >= sizeFilter.threshold }
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

        // Merge scan-time verified groups with on-demand ones, keyed by checksum. On-demand wins
        // in case of a checksum collision so a manual re-verify (e.g. with cache cleared) is
        // reflected immediately.
        var merged: [String: VerifiedDuplicateGroup] = [:]
        for group in scan.verifiedDuplicateGroups {
            merged[group.checksum] = group
        }
        for (checksum, group) in onDemandVerifiedGroupsByChecksum {
            merged[checksum] = group
        }

        return merged.values
            .filter { $0.byteSize >= sizeFilter.threshold }
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

    /// Hashes every file in a same-size candidate group and merges the result (if any items
    /// share a SHA-256 checksum) into the verified-duplicate view. Uses the same persisted
    /// `hashCache` as the scan, so cached hits are cheap. Reset on every new scan.
    func verifyOnDemand(_ group: DuplicateSizeGroup) {
        guard !isGroupAlreadyVerified(group) else { return }
        guard !verifyingGroupIDs.contains(group.id) else { return }
        verifyingGroupIDs.insert(group.id)

        let cache = hashCache
        Task { [weak self] in
            let result: Result<[VerifiedDuplicateGroup], Error>
            do {
                let groups = try await Task.detached(priority: .userInitiated) {
                    let scanner = FileSystemScanner(hashCache: cache)
                    return try scanner.verifySizeGroup(group, cancellation: nil)
                }.value
                result = .success(groups)
            } catch {
                result = .failure(error)
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.verifyingGroupIDs.remove(group.id)

                switch result {
                case .success(let groups):
                    for verifiedGroup in groups {
                        self.onDemandVerifiedGroupsByChecksum[verifiedGroup.checksum] = verifiedGroup
                    }
                    self.invalidateDerivedCaches()
                    let cacheToPersist = self.hashCache
                    Task.detached(priority: .utility) { cacheToPersist.persist() }
                case .failure(let error):
                    self.errorMessage = "Verification failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// `true` when every item in `group` is already covered by a verified duplicate group
    /// (scan-time or on-demand) at the same byte size. Used to skip no-op Verify Now taps.
    private func isGroupAlreadyVerified(_ group: DuplicateSizeGroup) -> Bool {
        let targetIDs = Set(group.items.map(\.id))
        let candidates = (scan?.verifiedDuplicateGroups ?? []) + Array(onDemandVerifiedGroupsByChecksum.values)
        return candidates.contains { verified in
            verified.byteSize == group.byteSize &&
                targetIDs.isSubset(of: Set(verified.items.map(\.id)))
        }
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
        for group in onDemandVerifiedGroupsByChecksum.values {
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
            query: query,
            sizeFilter: sizeFilter,
            sortOption: sortOption,
            cleanupLaneFilter: cleanupLaneFilter,
            ignoredCleanupCandidateIDs: ignoredCleanupCandidateIDs
        )
        if cachedCleanupCandidatesKey == key {
            return cachedCleanupCandidates
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = scan.cleanupCandidates.filter { candidate in
            guard !ignoredCleanupCandidateIDs.contains(candidate.id) else {
                return false
            }

            let item = candidate.item
            let passesSize = candidate.reclaimableBytes >= sizeFilter.threshold || item.displaySize >= sizeFilter.threshold
            let passesLane = cleanupCandidate(candidate, passes: cleanupLaneFilter)
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
        guard cleanupLaneFilter != lane else {
            return
        }
        cleanupLaneFilter = lane
        clearCleanupSelection()
    }

    func resetDisplayFilters() {
        filter.resetDisplayFilters()
        invalidateDerivedCaches()
    }

    func resetCleanupFilters() {
        filter.resetCleanupFilters()
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

    func removePendingTrashReviewItem(_ item: TrashReviewPlan.Item) {
        selectedCleanupCandidateIDs.remove(item.id)
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
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
        query = stat.label == "No Extension" ? "." : stat.label
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
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        return sorted(items.filter { item in
            let passesSize = item.displaySize >= sizeFilter.threshold
            let passesQuery = item.matchesNormalizedSearchQuery(trimmedQuery)
            return passesSize && passesQuery
        })
    }

    private func sorted(_ items: [StorageItem]) -> [StorageItem] {
        items.sorted { lhs, rhs in
            switch sortOption {
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
                return StorageFormatless.kindLabel(lhs.kind) < StorageFormatless.kindLabel(rhs.kind)
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
            query: query,
            sizeFilter: sizeFilter,
            sortOption: sortOption,
            cleanupLaneFilter: cleanupLaneFilter,
            ignoredCleanupCandidateIDs: ignoredCleanupCandidateIDs
        )
    }

    private func invalidateDerivedCaches() {
        cachedCleanupCandidatesKey = nil
        cachedCleanupCandidates = []
        cachedPotentialReclaimableBytesKey = nil
        cachedPotentialReclaimableBytes = 0
        cachedReclaimPlanKey = nil
        cachedReclaimPlan = ReclaimPlan(sections: [], primaryAction: nil)
        cachedOldLargeFilesKey = nil
        cachedOldLargeFiles = []
        invalidateItemsCache()
    }

    private func invalidateItemsCache() {
        cachedItemsKey = nil
        cachedItems = []
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

    private func markResultsNeedRefresh() {
        session.resultsNeedRefresh = true
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
            includeHiddenFiles: includeHiddenFiles,
            oldFileAgeDays: oldFileAgeDays
        )
    }

    private func rememberScanURL(_ url: URL, scannedAt: Date = Date(), totalBytes: Int64 = 0) {
        let path = url.standardizedFileURL.path
        let entry = RecentScanEntry(path: path, scannedAt: scannedAt, totalBytes: totalBytes)
        recentScanEntries.removeAll { $0.path == path }
        recentScanEntries.insert(entry, at: 0)
        recentScanEntries = Array(recentScanEntries.prefix(8))
        persistRecentScanEntries()
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

private enum StorageFormatless {
    static func kindLabel(_ kind: StorageItem.Kind) -> String {
        kind.rawValue
    }
}
