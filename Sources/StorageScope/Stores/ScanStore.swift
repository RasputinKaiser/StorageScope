import AppKit
import Foundation
import StorageScopeCore

@MainActor
final class ScanStore: ObservableObject {
    private static let recentScanPathsKey = "StorageScope.recentScanPaths"

    private struct ScanOptionsSnapshot: Equatable {
        let includeHiddenFiles: Bool
        let oldFileAgeDays: Int
    }

    @Published var selectedView: SmartView? = .overview
    @Published var selectedItemID: String?
    @Published var scan: StorageScan?
    @Published var isScanning = false
    @Published var progress = ScanProgress(scannedItemCount: 0, totalBytes: 0, currentPath: "")
    @Published var query = ""
    @Published var sizeFilter: SizeFilter = .all
    @Published var sortOption: ItemSortOption = .sizeDescending
    @Published var cleanupLaneFilter: CleanupLaneFilter = .all
    @Published var includeHiddenFiles = false
    @Published var oldFileAgeDays = 180
    @Published var errorMessage: String?
    @Published var selectedCleanupCandidateIDs = Set<String>()
    @Published var ignoredCleanupCandidateIDs = Set<String>()
    @Published private(set) var recentScanPaths: [String]
    @Published private var appliedScanOptions: ScanOptionsSnapshot?
    @Published private var resultsNeedRefresh = false
    private var markResultsNeedRefreshWhenCurrentScanCompletes = false

    private var activeScanID: UUID?
    private var cancellation: ScanCancellation?
    private var scanTask: Task<Void, Never>?
    private var lastScannedURL: URL?
    private let bookmarkStore = SecurityScopedBookmarkStore()
    private var activeRootAccess: SecurityScopedResourceAccess?

    init() {
        recentScanPaths = UserDefaults.standard.stringArray(forKey: Self.recentScanPathsKey) ?? []
    }

    var activeView: SmartView {
        selectedView ?? .overview
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
        lastScannedURL != nil && !isScanning
    }

    var canCancelScan: Bool {
        isScanning
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
        guard scan != nil, !isScanning, let appliedScanOptions else {
            return false
        }
        return appliedScanOptions != currentScanOptions
    }

    var scanOptionsStatusText: String? {
        if scanOptionsAreStale {
            return "Rescan to apply scan options"
        }
        if resultsNeedRefresh {
            return "Rescan to refresh results"
        }
        return nil
    }

    var scanNoticeText: String? {
        if scanOptionsAreStale {
            return "Scan options changed. Current results still reflect the previous hidden-file and age settings."
        }
        if resultsNeedRefresh {
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

    func scanDeveloperFixturePath(_ path: String, markResultsNeedRefreshWhenComplete: Bool = false) {
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        markResultsNeedRefreshWhenCurrentScanCompletes = markResultsNeedRefreshWhenComplete
        scan(url)
    }

    func forgetRecentScanPath(_ path: String) {
        recentScanPaths.removeAll { $0 == path }
        UserDefaults.standard.set(recentScanPaths, forKey: Self.recentScanPathsKey)
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
        guard let lastScannedURL else {
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
        lastScannedURL = url
        selectedItemID = nil
        selectedCleanupCandidateIDs.removeAll()
        ignoredCleanupCandidateIDs.removeAll()
        errorMessage = nil
        resultsNeedRefresh = false
        isScanning = true
        progress = ScanProgress(scannedItemCount: 0, totalBytes: 0, currentPath: url.path)

        let scanID = UUID()
        let thresholds = ScanOptionPolicy.interactiveScanThresholds(displayThreshold: sizeFilter.threshold)
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
                let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StorageScan, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let scanner = FileSystemScanner()
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
                appliedScanOptions = optionsSnapshot
                if markResultsNeedRefreshWhenCurrentScanCompletes {
                    resultsNeedRefresh = true
                    markResultsNeedRefreshWhenCurrentScanCompletes = false
                }
                selectedView = .overview
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
                progress = ScanProgress(scannedItemCount: 0, totalBytes: 0, currentPath: "Scan cancelled")
                clearActiveScan(scanID, cancellation: scanCancellation)
            } catch {
                guard isCurrentScan(scanID, cancellation: scanCancellation) else {
                    return
                }
                isScanning = false
                markResultsNeedRefreshWhenCurrentScanCompletes = false
                errorMessage = error.localizedDescription
                clearActiveScan(scanID, cancellation: scanCancellation)
            }
        }
    }

    func items(for view: SmartView) -> [StorageItem] {
        guard let scan else {
            return []
        }

        let baseItems: [StorageItem]
        switch view {
        case .overview:
            baseItems = Array(scan.rootItem.children.prefix(100))
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

        return filtered(baseItems)
    }

    var oldLargeFiles: [StorageItem] {
        guard let scan else {
            return []
        }
        return filtered(scan.oldLargeFiles.filter { $0.displaySize >= max(sizeFilter.threshold, 100_000_000) })
    }

    var duplicateGroups: [DuplicateSizeGroup] {
        guard let scan else {
            return []
        }
        return DuplicateReviewPlanner.unverifiedSizeGroups(
            sizeGroups: scan.duplicateSizeGroups,
            verifiedGroups: scan.verifiedDuplicateGroups
        )
            .filter { $0.byteSize >= max(sizeFilter.threshold, 100_000_000) }
            .map { group in
                DuplicateSizeGroup(byteSize: group.byteSize, items: filtered(group.items))
            }
            .filter { $0.items.count > 1 }
    }

    var verifiedDuplicateGroups: [VerifiedDuplicateGroup] {
        guard let scan else {
            return []
        }
        return scan.verifiedDuplicateGroups
            .filter { $0.byteSize >= sizeFilter.threshold }
            .map { group in
                VerifiedDuplicateGroup(
                    checksum: group.checksum,
                    byteSize: group.byteSize,
                    items: filtered(group.items)
                )
            }
            .filter { $0.items.count > 1 }
    }

    var cleanupCandidates: [CleanupCandidate] {
        guard let scan else {
            return []
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return scan.cleanupCandidates.filter { candidate in
            guard !ignoredCleanupCandidateIDs.contains(candidate.id) else {
                return false
            }

            let item = candidate.item
            let passesSize = candidate.reclaimableBytes >= sizeFilter.threshold || item.displaySize >= sizeFilter.threshold
            let passesLane = cleanupCandidate(candidate, passes: cleanupLaneFilter)
            let passesQuery = trimmedQuery.isEmpty ||
                item.name.localizedCaseInsensitiveContains(trimmedQuery) ||
                item.url.path.localizedCaseInsensitiveContains(trimmedQuery) ||
                candidate.reason.localizedCaseInsensitiveContains(trimmedQuery) ||
                candidate.kind.displayName.localizedCaseInsensitiveContains(trimmedQuery)
            return passesSize && passesLane && passesQuery
        }
    }

    var potentialReclaimableBytes: Int64 {
        CleanupSelectionPlanner.topLevelCandidates(cleanupCandidates).reduce(Int64(0)) { $0 + $1.reclaimableBytes }
    }

    var selectedCleanupCandidates: [CleanupCandidate] {
        cleanupCandidates.filter { selectedCleanupCandidateIDs.contains($0.id) }
    }

    var selectedCleanupCandidate: CleanupCandidate? {
        guard let scan, let selectedItemID else {
            return nil
        }
        return scan.cleanupCandidates.first { $0.item.id == selectedItemID }
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
        return ReclaimPlanBuilder.build(scan: scan, visibleCleanupCandidates: cleanupCandidates)
    }

    var selectedReclaimableBytes: Int64 {
        selectedCleanupBatchCandidates.reduce(Int64(0)) { $0 + $1.reclaimableBytes }
    }

    func toggleCleanupCandidate(_ candidate: CleanupCandidate) {
        if selectedCleanupCandidateIDs.contains(candidate.id) {
            selectedCleanupCandidateIDs.remove(candidate.id)
        } else {
            selectedCleanupCandidateIDs.insert(candidate.id)
        }
        selectedItemID = candidate.item.id
    }

    func selectVerifiedCleanupCandidates() {
        selectedCleanupCandidateIDs = Set(verifiedCleanupCandidates.map(\.id))
    }

    func clearCleanupSelection() {
        selectedCleanupCandidateIDs.removeAll()
    }

    func setCleanupLaneFilter(_ lane: CleanupLaneFilter) {
        guard cleanupLaneFilter != lane else {
            return
        }
        cleanupLaneFilter = lane
        clearCleanupSelection()
    }

    func resetDisplayFilters() {
        query = ""
        sizeFilter = .all
    }

    func resetCleanupFilters() {
        resetDisplayFilters()
        cleanupLaneFilter = .all
    }

    func ignoreCleanupCandidate(_ candidate: CleanupCandidate) {
        ignoredCleanupCandidateIDs.insert(candidate.id)
        selectedCleanupCandidateIDs.remove(candidate.id)
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

        let urls = candidates.map(\.item.url)
        let containsReviewRisk = CleanupSelectionPlanner.containsReviewRisk(candidates)
        let reclaimableBytes = candidates.reduce(Int64(0)) { $0 + $1.reclaimableBytes }
        guard FileActionService.confirmTrash(
            urls: urls,
            containsReviewRisk: containsReviewRisk,
            estimatedReclaimBytes: reclaimableBytes
        ) else {
            return
        }

        do {
            try FileActionService.moveToTrashTransactionally(urls)
            ignoredCleanupCandidateIDs.formUnion(candidates.map(\.id))
            selectedCleanupCandidateIDs.removeAll()
            selectedItemID = nil
            markResultsNeedRefresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var filteredTypeBreakdown: [FileTypeStat] {
        guard let scan else {
            return []
        }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return scan.typeBreakdown
        }
        return scan.typeBreakdown.filter {
            $0.label.localizedCaseInsensitiveContains(query)
        }
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

        guard FileActionService.confirmTrash(url: selectedItem.url) else {
            return
        }

        do {
            try FileActionService.moveToTrash(selectedItem.url)
            selectedItemID = nil
            markResultsNeedRefresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func canMoveItemToTrash(_ item: StorageItem) -> Bool {
        item.id != scan?.rootItem.id
    }

    private func filtered(_ items: [StorageItem]) -> [StorageItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        return sorted(items.filter { item in
            let passesSize = item.displaySize >= sizeFilter.threshold
            let passesQuery = trimmedQuery.isEmpty ||
                item.name.localizedCaseInsensitiveContains(trimmedQuery) ||
                item.url.path.localizedCaseInsensitiveContains(trimmedQuery)
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
            return candidate.kind == .verifiedDuplicate && candidate.confidence == .high
        case .suggestions:
            return !(candidate.kind == .verifiedDuplicate && candidate.confidence == .high)
        }
    }

    private func markResultsNeedRefresh() {
        resultsNeedRefresh = true
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

    private func rememberScanURL(_ url: URL) {
        let path = url.standardizedFileURL.path
        recentScanPaths.removeAll { $0 == path }
        recentScanPaths.insert(path, at: 0)
        recentScanPaths = Array(recentScanPaths.prefix(8))
        UserDefaults.standard.set(recentScanPaths, forKey: Self.recentScanPathsKey)
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

private extension StorageScan {
    func lookupItem(id: String) -> StorageItem? {
        if let treeItem = allItems.first(where: { $0.id == id }) {
            return treeItem
        }

        if let rankedItem = (largestFiles + largestFolders + oldLargeFiles).first(where: { $0.id == id }) {
            return rankedItem
        }

        for group in duplicateSizeGroups where group.items.contains(where: { $0.id == id }) {
            return group.items.first { $0.id == id }
        }

        for group in verifiedDuplicateGroups where group.items.contains(where: { $0.id == id }) {
            return group.items.first { $0.id == id }
        }

        return cleanupCandidates.first { $0.item.id == id }?.item
    }
}
