import CryptoKit
import Foundation
import os

public enum FileSystemScannerError: LocalizedError {
    case cancelled
    case rootDoesNotExist(URL)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "The scan was cancelled."
        case .rootDoesNotExist(let url):
            return "The folder does not exist: \(url.path)"
        }
    }
}

public final class ScanCancellation: @unchecked Sendable {
    // `NSCondition` replaces the plain `NSLock` used previously so `waitIfPaused()` can
    // block cooperatively (via `wait()`) instead of spinning, while `cancel()`/`resume()`
    // broadcast to wake any threads parked in `waitIfPaused()`. All prior lock/unlock call
    // sites now lock/unlock through the same condition instance.
    private let condition = NSCondition()
    private var cancelled = false
    private var paused = false

    public init() {}

    public func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    public func check() throws {
        condition.lock()
        let shouldCancel = cancelled
        condition.unlock()

        if shouldCancel {
            throw FileSystemScannerError.cancelled
        }
    }

    /// Non-throwing probe used inside `DispatchQueue.concurrentPerform`, which cannot propagate thrown errors.
    public var isCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled
    }

    public func pause() {
        condition.lock()
        paused = true
        condition.unlock()
    }

    public func resume() {
        condition.lock()
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    public var isPaused: Bool {
        condition.lock()
        defer { condition.unlock() }
        return paused
    }

    /// Blocks the calling thread while paused. Re-checks `cancelled` on every wake so a
    /// `cancel()` issued while paused unblocks immediately rather than waiting on a
    /// `resume()` that may never come.
    ///
    /// Caution: called from inside `DispatchQueue.concurrentPerform` closures during wide
    /// directory recursion. `concurrentPerform` dispatches onto the shared, bounded GCD
    /// worker-thread pool — a pause held while many wide-directory iterations are parked
    /// here simultaneously can approach that pool's thread ceiling and starve unrelated work
    /// on the process. Not solved here; flagged as a known limitation for very wide
    /// directories (thousands of siblings) combined with a long pause.
    public func waitIfPaused() {
        condition.lock()
        while paused && !cancelled {
            condition.wait()
        }
        condition.unlock()
    }
}

enum FileSystemScannerWalkerMode: Sendable {
    case legacy
    case fixedWorker
}

public final class FileSystemScanner {
    public typealias ProgressHandler = (ScanProgress) -> Void

    /// Bounded concurrency for duplicate-verification hashing. Hashing is I/O-bound on
    /// SSDs (file-read throughput, not CPU), so we deliberately undersubscribe the host
    /// core count to avoid filling the GCD thread pool and pressuring the file-descriptor
    /// table on broad scans. The min/max keeps the count in `[2, 6]` regardless of host.
    private static let hashConcurrency: Int = {
        let cores = ProcessInfo.processInfo.processorCount
        return min(6, max(2, cores / 2))
    }()
    private static let duplicatePrefixByteCount = 64 * 1_024

    /// os_signpost surface for Instruments. Subsystem mirrors the bundle identifier prefix;
    /// category ties Scanner-only work together so it can be filtered from app-side spans.
    private static let log = OSLog(subsystem: "com.rasputinkaiser.StorageScope", category: "scan")
    private static let signpostID = OSSignpostID(log: log)

    private let fileManager: FileManager
    private let hashCache: DuplicateHashCache?
    private let walkerMode: FileSystemScannerWalkerMode
    private let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .isReadableKey,
        .isHiddenKey,
        .fileSizeKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
        .contentModificationDateKey
    ]

    public convenience init(fileManager: FileManager = .default, hashCache: DuplicateHashCache? = nil) {
        self.init(
            fileManager: fileManager,
            hashCache: hashCache,
            walkerMode: Self.configuredWalkerMode()
        )
    }

    init(
        fileManager: FileManager = .default,
        hashCache: DuplicateHashCache? = nil,
        walkerMode: FileSystemScannerWalkerMode
    ) {
        self.fileManager = fileManager
        self.hashCache = hashCache
        self.walkerMode = walkerMode
    }

    private static func configuredWalkerMode() -> FileSystemScannerWalkerMode {
        let environment = ProcessInfo.processInfo.environment
        if environment["STORAGESCOPE_LEGACY_WALKER"] == "1" {
            return .legacy
        }
        if environment["STORAGESCOPE_EXPERIMENTAL_WORKER_WALKER"] == "1" {
            return .fixedWorker
        }
        // Keep the existing implementation as the default until the experimental
        // path clears the differential, stability, and release-performance gates.
        return .legacy
    }

    public func scan(
        root rootURL: URL,
        options: ScanOptions = ScanOptions(),
        cancellation: ScanCancellation? = nil,
        progress: ProgressHandler? = nil,
        onSnapshot: ((StorageScan) -> Void)? = nil
    ) throws -> StorageScan {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            throw FileSystemScannerError.rootDoesNotExist(rootURL)
        }

        os_signpost(.begin, log: Self.log, name: "scan", signpostID: Self.signpostID,
                    "root=%{public}@", rootURL.path)

        let startedAt = Date()
        let accumulator = ScanAccumulator(options: options, progress: progress, onSnapshot: onSnapshot, rootURL: rootURL, startedAt: startedAt)
        let rootItem: StorageItem
        switch walkerMode {
        case .legacy:
            rootItem = try scanItem(
                at: rootURL,
                options: options,
                cancellation: cancellation,
                accumulator: accumulator,
                depth: 0
            )
        case .fixedWorker:
            rootItem = try scanWithFixedWorker(
                at: rootURL,
                options: options,
                cancellation: cancellation,
                accumulator: accumulator
            )
        }
        let retainedItems = rootItem.flattened()
        let duplicateSizeGroups = accumulator.duplicateSizeGroups
        let enumerateDuration = Date().timeIntervalSince(startedAt)
        let duplicateVerificationStartedAt = Date()
        let verifiedDuplicateGroups = try verifiedDuplicateGroups(
            from: duplicateSizeGroups,
            options: options,
            accumulator: accumulator,
            cancellation: cancellation
        )
        let duplicateVerificationDuration = Date().timeIntervalSince(duplicateVerificationStartedAt)
        let duplicateVerificationBytesRead = accumulator.duplicateVerificationBytesRead
        let finishedAt = Date()

        os_signpost(.end, log: Self.log, name: "scan", signpostID: Self.signpostID,
                    "items=%d verified=%d", accumulator.scannedItemCount, verifiedDuplicateGroups.count)

        return StorageScan(
            rootURL: rootURL,
            startedAt: startedAt,
            finishedAt: finishedAt,
            rootItem: rootItem,
            retainedItems: retainedItems,
            scannedItemCount: accumulator.scannedItemCount,
            inaccessibleItemCount: accumulator.inaccessibleItemCount,
            totalBytes: rootItem.displaySize,
            largestFiles: accumulator.largestFiles,
            largestFolders: accumulator.largestFolders(excluding: rootItem.id),
            oldLargeFiles: accumulator.oldLargeFiles,
            typeBreakdown: accumulator.typeBreakdown,
            categoryBreakdown: accumulator.categoryBreakdown,
            duplicateSizeGroups: duplicateSizeGroups,
            verifiedDuplicateGroups: verifiedDuplicateGroups,
            duplicateCandidateItemLimit: accumulator.duplicateCandidateItemLimit,
            duplicateCandidateItemsRetained: accumulator.duplicateCandidateItemsRetained,
            duplicateCandidateItemsConsidered: accumulator.duplicateCandidateItemsConsidered,
            duplicateCandidateEvictionCount: accumulator.duplicateCandidateEvictionCount,
            duplicateCandidateLimitReached: accumulator.duplicateCandidateLimitReached,
            snapshotBuildCount: accumulator.snapshotBuildCount,
            duplicateVerificationDuration: duplicateVerificationDuration,
            duplicateVerificationBytesRead: duplicateVerificationBytesRead,
            enumerateDuration: enumerateDuration,
            cleanupCandidates: accumulator.cleanupCandidates(
                rootID: rootItem.id,
                verifiedDuplicateGroups: verifiedDuplicateGroups,
                limit: options.maxRankedResults
            ),
            isPartial: false
        )
    }

    /// Hashes every item in `group` and returns verified duplicate groups (matching SHA-256,
    /// count > 1). Use after a scan to verify a same-size candidate group that fell outside
    /// the auto-verification budget. Hits the persisted `hashCache` when items are unchanged,
    /// so a re-verify is cheap. Cancellation cooperates with `ScanCancellation.check()` and
    /// propagates as `FileSystemScannerError.cancelled` once the user aborts — partial hashes
    /// discovered before cancellation are NOT surfaced, because mixing verified and
    /// cancelled-state results would mislead the caller into treating an aborted batch
    /// as complete. Per-file read failures (vanished file, permission denied, etc.) are
    /// logged via os_signpost and skipped, leaving the rest of the group verifiable.
    public func verifySizeGroup(
        _ group: DuplicateSizeGroup,
        cancellation: ScanCancellation? = nil
    ) throws -> [VerifiedDuplicateGroup] {
        try cancellation?.check()

        let verifySignpostID = OSSignpostID(log: Self.log, object: group.id as NSString)
        os_signpost(.begin, log: Self.log, name: "verify_on_demand", signpostID: verifySignpostID,
                    "items=%d", group.items.count)

        defer {
            os_signpost(.end, log: Self.log, name: "verify_on_demand", signpostID: verifySignpostID)
        }

        let ioSemaphore = DispatchSemaphore(value: Self.hashConcurrency)
        let cacheLock = NSLock()

        return try verifiedDuplicateGroups(
            in: group,
            ioSemaphore: ioSemaphore,
            cacheLock: cacheLock,
            recordBytesRead: nil,
            cancellation: cancellation
        )
    }

    private func scanItem(
        at url: URL,
        options: ScanOptions,
        cancellation: ScanCancellation?,
        accumulator: ScanAccumulator,
        depth: Int
    ) throws -> StorageItem {
        cancellation?.waitIfPaused()
        try cancellation?.check()

        // `url.resourceValues(forKeys:)` can fail (sandbox ACLs, unreachable APFS
        // snapshots, removed media). Fall back to a nil-typed values entry and surface
        // the failure through os_signpost so Instruments shows what was missed. The
        // downstream code already handles `values == nil` by treating the entry as
        // hidden/inaccessible, preserving the previous behavior.
        let values: URLResourceValues?
        do {
            values = try url.resourceValues(forKeys: resourceKeys)
        } catch {
            values = nil
            os_signpost(.event, log: Self.log, name: "resource_values_skip",
                        "path=%{public}@ reason=%{public}@", url.path, "\(error)")
        }
        let isHidden = values?.isHidden ?? false
        if isHidden && !options.includeHidden {
            return StorageItem(
                url: url,
                kind: .other,
                byteSize: 0,
                allocatedSize: 0,
                modifiedAt: values?.contentModificationDate,
                immediateChildCount: 0,
                descendantCount: 0,
                isReadable: false,
                fileExtension: nil
            )
        }

        if values?.isSymbolicLink == true {
            let size = Int64(values?.fileSize ?? 0)
            let item = StorageItem(
                url: url,
                kind: .alias,
                byteSize: size,
                allocatedSize: size,
                modifiedAt: values?.contentModificationDate,
                immediateChildCount: 0,
                descendantCount: 0,
                isReadable: values?.isReadable ?? true,
                fileExtension: url.pathExtension.nonEmptyLowercased
            )
            accumulator.recordScannedItem(item, countedBytes: size, path: url.path)
            return item
        }

        let isDirectory = values?.isDirectory == true
        let isPackage = values?.isPackage == true

        guard isDirectory else {
            let logicalSize = Int64(values?.fileSize ?? 0)
            let allocatedSize = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? values?.fileSize ?? 0)

            let item = StorageItem(
                url: url,
                kind: values?.isRegularFile == true ? .file : .other,
                byteSize: logicalSize,
                allocatedSize: allocatedSize,
                modifiedAt: values?.contentModificationDate,
                immediateChildCount: 0,
                descendantCount: 0,
                isReadable: values?.isReadable ?? true,
                fileExtension: url.pathExtension.nonEmptyLowercased
            )
            accumulator.recordScannedItem(item, countedBytes: max(logicalSize, allocatedSize), path: url.path)
            return item
        }

        accumulator.recordVisit(path: url.path)

        do {
            let directoryOptions: FileManager.DirectoryEnumerationOptions = options.includeHidden ? [] : [.skipsHiddenFiles]
            let childURLs = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(resourceKeys),
                options: directoryOptions
            )

            // Recurse into every child directory in parallel. Profits from SSD parallelism for
            // wide directory layouts (e.g. home folder, mounted volumes). concurrentPerform
            // is synchronous — the calling thread waits for all iterations to finish — and
            // cannot propagate thrown errors, so cancellation is propagated via a flag
            // inspected after the call returns. Child items are stored at their original
            // index so the order entering `DirectoryScanSummary` is preserved.
            var childItems: [StorageItem?] = Array(repeating: nil, count: childURLs.count)
            let cancellationLock = NSLock()
            var didCancel = false

            DispatchQueue.concurrentPerform(iterations: childURLs.count) { index in
                // Each iteration bridges several Foundation objects (URLResourceValues,
                // NSNumber signpost objects, Date/NSString instances inside scanItem). With
                // no pool, concurrentPerform's calling thread never gets an autorelease drain
                // point until the whole call returns, so these accumulate for the duration of
                // a potentially huge directory enumeration. Draining per-iteration bounds peak
                // RSS instead of letting it grow with the directory's child count.
                autoreleasepool {
                    if cancellation?.isCancelled ?? false {
                        return
                    }

                    let enumerateSignpostID = OSSignpostID(log: Self.log, object: index as NSNumber)
                    os_signpost(.begin, log: Self.log, name: "enumerate", signpostID: enumerateSignpostID,
                                "child=%{public}@", childURLs[index].lastPathComponent)
                    defer {
                        os_signpost(.end, log: Self.log, name: "enumerate", signpostID: enumerateSignpostID)
                    }

                    do {
                        cancellation?.waitIfPaused()
                        try cancellation?.check()

                        if options.excludeEnabled, Self.isExcluded(childURLs[index], options: options) {
                            // Skip entirely: don't stat, count, or recurse. Leave the slot nil
                            // so the `for case let child?` filter below treats it as absent,
                            // matching the established "skip this child" pattern used for
                            // per-child errors elsewhere in this loop.
                            return
                        }

                        let child = try scanItem(
                            at: childURLs[index],
                            options: options,
                            cancellation: cancellation,
                            accumulator: accumulator,
                            depth: depth + 1
                        )
                        childItems[index] = child
                    } catch FileSystemScannerError.cancelled {
                        cancellationLock.lock()
                        didCancel = true
                        cancellationLock.unlock()
                    } catch {
                        // Unreachable: scanItem only throws FileSystemScannerError.cancelled;
                        // ingestion/directory-enumeration failures are caught internally and
                        // surface as .inaccessible StorageItems. Belt-and-braces guard.
                        let unreachable = StorageItem(
                            url: childURLs[index],
                            kind: .inaccessible,
                            byteSize: 0,
                            allocatedSize: 0,
                            modifiedAt: nil,
                            immediateChildCount: 0,
                            descendantCount: 0,
                            isReadable: false,
                            fileExtension: nil
                        )
                        childItems[index] = unreachable
                        accumulator.recordItem(unreachable)
                    }
                }
            }

            if didCancel {
                throw FileSystemScannerError.cancelled
            }

            var summary = DirectoryScanSummary(retainedCandidateLimit: options.maxChildrenPerDirectory)
            for case let child? in childItems {
                guard child.kind != .other || child.displaySize > 0 else {
                    continue
                }

                summary.record(child)
            }

            let retainedChildren = accumulator.retainedChildren(from: summary.retainedCandidates, depth: depth)

            let item = StorageItem(
                url: url,
                kind: isPackage ? .package : .folder,
                byteSize: summary.logicalSize,
                allocatedSize: summary.allocatedSize,
                modifiedAt: values?.contentModificationDate,
                immediateChildCount: summary.immediateChildCount,
                descendantCount: summary.descendantCount,
                children: retainedChildren,
                isReadable: values?.isReadable ?? true,
                fileExtension: isPackage ? url.pathExtension.nonEmptyLowercased : nil
            )
            accumulator.recordItem(item)
            return item
        } catch FileSystemScannerError.cancelled {
            throw FileSystemScannerError.cancelled
        } catch {
            accumulator.recordInaccessible(path: url.path)
            let item = StorageItem(
                url: url,
                kind: .inaccessible,
                byteSize: 0,
                allocatedSize: 0,
                modifiedAt: values?.contentModificationDate,
                immediateChildCount: 0,
                descendantCount: 0,
                isReadable: false,
                fileExtension: nil
            )
            accumulator.recordItem(item)
            return item
        }
    }

    private func scanWithFixedWorker(
        at rootURL: URL,
        options: ScanOptions,
        cancellation: ScanCancellation?,
        accumulator: ScanAccumulator
    ) throws -> StorageItem {
        let prepared: (rootSummary: FixedWorkerItemSummary?, summaryStore: FixedWorkerSummaryStore?)
        do {
            prepared = try prepareFixedWorkerSummary(
                at: rootURL,
                options: options,
                cancellation: cancellation,
                accumulator: accumulator
            )
        } catch FileSystemScannerError.cancelled {
            throw FileSystemScannerError.cancelled
        } catch {
            // The experimental path owns no user-visible state until its complete
            // record set is available. If a worker-only failure escapes the
            // filesystem error handling below, retry the root through the legacy
            // implementation rather than returning a partial tree.
            return try scanItem(
                at: rootURL,
                options: options,
                cancellation: cancellation,
                accumulator: accumulator,
                depth: 0
            )
        }

        guard let rootSummary = prepared.rootSummary,
              let summaryStore = prepared.summaryStore else {
            return StorageItem(
                url: rootURL,
                kind: .other,
                byteSize: 0,
                allocatedSize: 0,
                modifiedAt: nil,
                immediateChildCount: 0,
                descendantCount: 0,
                isReadable: false,
                fileExtension: nil
            )
        }

        return summaryStore.makeItem(summary: rootSummary, urlOverride: rootURL)
    }

    private func prepareFixedWorkerSummary(
        at rootURL: URL,
        options: ScanOptions,
        cancellation: ScanCancellation?,
        accumulator: ScanAccumulator
    ) throws -> (
        rootSummary: FixedWorkerItemSummary?,
        summaryStore: FixedWorkerSummaryStore?
    ) {
        let walker = FixedWorkerDirectoryWalker(
            fileManager: fileManager,
            resourceKeys: resourceKeys,
            options: options,
            cancellation: cancellation,
            shouldExclude: { url in
                options.excludeEnabled && Self.isExcluded(url, options: options)
            }
        )
        let result = try walker.walk(root: rootURL)
        guard let rootMetadata = result.rootMetadata else {
            return (nil, nil)
        }

        let (rootSummary, summaryStore) = try buildFixedWorkerSummaryStore(
            rootMetadata: rootMetadata,
            directoryRecords: result.directoryRecords,
            options: options,
            cancellation: cancellation,
            accumulator: accumulator,
            rootURL: rootURL
        )
        return (rootSummary, summaryStore)
    }

    private func buildFixedWorkerSummaryStore(
        rootMetadata: FixedWorkerWalkRecord,
        directoryRecords: [FixedWorkerDirectoryRecord],
        options: ScanOptions,
        cancellation: ScanCancellation?,
        accumulator: ScanAccumulator,
        rootURL: URL
    ) throws -> (FixedWorkerItemSummary, FixedWorkerSummaryStore) {
        var recordsByID: [Int: FixedWorkerDirectoryRecord] = [:]
        recordsByID.reserveCapacity(directoryRecords.count)
        for record in directoryRecords {
            recordsByID[record.metadata.id] = record
        }

        let summaryStore = FixedWorkerSummaryStore(rootURL: rootURL)
        accumulator.configureFixedWorkerStore(summaryStore)
        let rootSummary = try buildFixedWorkerSummary(
            rootMetadata,
            url: rootURL,
            recordsByID: recordsByID,
            options: options,
            cancellation: cancellation,
            accumulator: accumulator,
            depth: 0
        )
        return (rootSummary, summaryStore)
    }

    private func buildFixedWorkerSummary(
        _ metadata: FixedWorkerWalkRecord,
        url: URL,
        recordsByID: [Int: FixedWorkerDirectoryRecord],
        options: ScanOptions,
        cancellation: ScanCancellation?,
        accumulator: ScanAccumulator,
        depth: Int
    ) throws -> FixedWorkerItemSummary {
        try cancellation?.check()

        guard metadata.isDirectory else {
            let summary = FixedWorkerItemSummary(
                metadata: metadata,
                isInaccessible: false,
                logicalSize: metadata.byteSize,
                allocatedSize: metadata.allocatedSize,
                immediateChildCount: 0,
                descendantCount: 0,
                retainedChildren: [],
                retainedTreeCount: 1
            )
            accumulator.recordFixedWorkerScannedItem(summary, url: url)
            return summary
        }

        accumulator.recordVisit(path: url.path)
        guard let record = recordsByID[metadata.id] else {
            accumulator.recordInaccessible(path: url.path)
            let summary = FixedWorkerItemSummary(
                metadata: metadata,
                isInaccessible: true,
                logicalSize: 0,
                allocatedSize: 0,
                immediateChildCount: 0,
                descendantCount: 0,
                retainedChildren: [],
                retainedTreeCount: 1
            )
            accumulator.recordFixedWorkerItem(summary, url: url)
            return summary
        }

        if record.isInaccessible {
            accumulator.recordInaccessible(path: url.path)
            let summary = FixedWorkerItemSummary(
                metadata: metadata,
                isInaccessible: true,
                logicalSize: 0,
                allocatedSize: 0,
                immediateChildCount: 0,
                descendantCount: 0,
                retainedChildren: [],
                retainedTreeCount: 1
            )
            accumulator.recordFixedWorkerItem(summary, url: url)
            return summary
        }

        var directorySummary = FixedWorkerDirectorySummaryBuilder(
            retainedCandidateLimit: options.maxChildrenPerDirectory
        )
        for childMetadata in record.children {
            try cancellation?.check()
            let childURL = url.appendingPathComponent(childMetadata.name, isDirectory: childMetadata.isDirectory)
            let childSummary = try buildFixedWorkerSummary(
                childMetadata,
                url: childURL,
                recordsByID: recordsByID,
                options: options,
                cancellation: cancellation,
                accumulator: accumulator,
                depth: depth + 1
            )
            directorySummary.record(childSummary)
        }

        let retainedSelections = accumulator.retainedFixedWorkerChildren(
            from: directorySummary.retainedCandidates,
            depth: depth
        )
        let retainedChildren: [FixedWorkerRetainedChild] = retainedSelections.compactMap { selection in
            guard let childSummary = directorySummary.summary(for: selection.id) else {
                return nil
            }
            return FixedWorkerRetainedChild(
                id: selection.id,
                includesDescendants: selection.includesDescendants,
                retainedTreeCount: selection.retainedTreeCount,
                summary: childSummary
            )
        }
        let retainedTreeCount = 1 + retainedChildren.reduce(0) { partialResult, child in
            partialResult + child.retainedTreeCount
        }
        let summary = FixedWorkerItemSummary(
            metadata: metadata,
            isInaccessible: false,
            logicalSize: directorySummary.logicalSize,
            allocatedSize: directorySummary.allocatedSize,
            immediateChildCount: directorySummary.immediateChildCount,
            descendantCount: directorySummary.descendantCount,
            retainedChildren: retainedChildren,
            retainedTreeCount: retainedTreeCount
        )
        accumulator.recordFixedWorkerItem(summary, url: url)
        return summary
    }

    /// True when `url` matches an exclusion rule: its last path component names an
    /// excluded folder name (e.g. `node_modules`, `.git`), or its standardized path starts
    /// with an excluded absolute prefix (tilde-expanded, e.g. `~/Library/Caches`).
    private static func isExcluded(_ url: URL, options: ScanOptions) -> Bool {
        if options.excludedPathComponents.contains(url.lastPathComponent) {
            return true
        }

        guard !options.excludedAbsolutePrefixes.isEmpty else {
            return false
        }

        let standardizedPath = url.standardizedFileURL.path
        for prefix in options.excludedAbsolutePrefixes {
            let expandedPrefix = (prefix as NSString).expandingTildeInPath
            if standardizedPath == expandedPrefix || standardizedPath.hasPrefix(expandedPrefix + "/") {
                return true
            }
        }
        return false
    }

    private func verifiedDuplicateGroups(
        from sizeGroups: [DuplicateSizeGroup],
        options: ScanOptions,
        accumulator: ScanAccumulator,
        cancellation: ScanCancellation?
    ) throws -> [VerifiedDuplicateGroup] {
        var verifiedGroups: [VerifiedDuplicateGroup] = []
        let verificationGroups = duplicateGroupsWithinVerificationBudget(sizeGroups, options: options)

        if verificationGroups.count < sizeGroups.count {
            accumulator.recordPhase(
                path: "Duplicate verification capped to \(verificationGroups.count) of \(sizeGroups.count) size groups",
                phase: .verifyingDuplicates
            )
        }

        accumulator.recordPhase(
            path: "Verifying duplicates across \(verificationGroups.count) size groups",
            phase: .verifyingDuplicates
        )

        let verifiedGroupsLock = NSLock()
        let cacheLock = NSLock()
        let ioSemaphore = DispatchSemaphore(value: Self.hashConcurrency)
        // Cancellation is cooperative: concurrentPerform can't throw, so iterations record
        // observed cancellation in a flag that we re-check after the call returns. This
        // mirrors the pattern used by the parallel-directory-enumeration path in scanItem.
        let cancellationLock = NSLock()
        var didCancel = false

        // Local helper for recording cancellation observed mid-batch — the 3-line lock/unlock
        // sequence repeats from multiple iteration exits, so give it a name.
        func markCancelled() {
            cancellationLock.lock()
            didCancel = true
            cancellationLock.unlock()
        }

        DispatchQueue.concurrentPerform(iterations: verificationGroups.count) { groupIndex in
            // Bail before opening any file handles so a cancelled batch doesn't keep fanning
            // out I/O while sibling iterations are still mid-hash.
            if cancellation?.isCancelled ?? false {
                return
            }

            let verifySignpostID = OSSignpostID(log: Self.log, object: groupIndex as NSNumber)
            os_signpost(.begin, log: Self.log, name: "verify", signpostID: verifySignpostID,
                        "group=%d", groupIndex)
            defer {
                os_signpost(.end, log: Self.log, name: "verify", signpostID: verifySignpostID)
            }

            do {
                try cancellation?.check()
                let sizeGroup = verificationGroups[groupIndex]

                let verifiedForSize = try verifiedDuplicateGroups(
                    in: sizeGroup,
                    ioSemaphore: ioSemaphore,
                    cacheLock: cacheLock,
                    recordBytesRead: accumulator.recordDuplicateVerificationBytes,
                    cancellation: cancellation
                )

                guard !verifiedForSize.isEmpty else {
                    return
                }
                verifiedGroupsLock.lock()
                defer { verifiedGroupsLock.unlock() }
                verifiedGroups.append(contentsOf: verifiedForSize)
            } catch FileSystemScannerError.cancelled {
                markCancelled()
            } catch {
                // Unreachable at this scope: the inner loop catches every error type from
                // `hashedFormItem`, and the only other throwing call is `cancellation?.check()`
                // which produces `.cancelled`. Belt-and-braces guard keeps the iteration safe.
                return
            }
        }

        if didCancel {
            throw FileSystemScannerError.cancelled
        }

        return verifiedGroups.sorted { lhs, rhs in
            if lhs.reclaimableBytes == rhs.reclaimableBytes {
                return lhs.byteSize > rhs.byteSize
            }
            return lhs.reclaimableBytes > rhs.reclaimableBytes
        }
    }

    private func verifiedDuplicateGroups(
        in sizeGroup: DuplicateSizeGroup,
        ioSemaphore: DispatchSemaphore,
        cacheLock: NSLock,
        recordBytesRead: ((Int) -> Void)?,
        cancellation: ScanCancellation?
    ) throws -> [VerifiedDuplicateGroup] {
        var cachedFullHashesByPath: [String: String] = [:]
        cachedFullHashesByPath.reserveCapacity(sizeGroup.items.count)

        for item in sizeGroup.items {
            try cancellation?.check()
            let cacheKey = DuplicateHashCache.LookupKey(item: item)
            if let cached = hashCache?.checksum(for: cacheKey) {
                cachedFullHashesByPath[cacheKey.path] = cached
            }
        }

        if cachedFullHashesByPath.count == sizeGroup.items.count {
            let hashedItems = sizeGroup.items.compactMap { item -> HashedStorageItem? in
                let path = DuplicateHashCache.LookupKey(item: item).path
                guard let checksum = cachedFullHashesByPath[path] else { return nil }
                return HashedStorageItem(checksum: checksum, item: item)
            }
            return verifiedDuplicateGroups(from: hashedItems, byteSize: sizeGroup.byteSize)
        }

        var prefixHashedItems: [PrefixHashedStorageItem] = []
        prefixHashedItems.reserveCapacity(sizeGroup.items.count)

        for item in sizeGroup.items {
            if cancellation?.isCancelled ?? false {
                throw FileSystemScannerError.cancelled
            }

            if let prefixed = try prefixHashedFormItem(
                item,
                ioSemaphore: ioSemaphore,
                recordBytesRead: recordBytesRead,
                cancellation: cancellation
            ) {
                prefixHashedItems.append(prefixed)
            }
        }

        let groupedByPrefix = Dictionary(grouping: prefixHashedItems, by: \.prefixChecksum)
        var fullyHashedItems: [HashedStorageItem] = []

        for prefixGroup in groupedByPrefix.values where prefixGroup.count > 1 {
            for prefixed in prefixGroup {
                let cacheKey = DuplicateHashCache.LookupKey(item: prefixed.item)
                if let cached = cachedFullHashesByPath[cacheKey.path] {
                    fullyHashedItems.append(HashedStorageItem(checksum: cached, item: prefixed.item))
                    continue
                }

                if prefixed.isCompleteFile {
                    if let hashCache {
                        cacheLock.lock()
                        hashCache.record(cacheKey, checksum: prefixed.prefixChecksum)
                        cacheLock.unlock()
                    }
                    fullyHashedItems.append(HashedStorageItem(checksum: prefixed.prefixChecksum, item: prefixed.item))
                    continue
                }

                if let hashed = try hashedFormItem(
                    prefixed.item,
                    ioSemaphore: ioSemaphore,
                    cacheLock: cacheLock,
                    recordBytesRead: recordBytesRead,
                    cancellation: cancellation
                ) {
                    fullyHashedItems.append(hashed)
                }
            }
        }

        return verifiedDuplicateGroups(from: fullyHashedItems, byteSize: sizeGroup.byteSize)
    }

    private func verifiedDuplicateGroups(
        from hashedItems: [HashedStorageItem],
        byteSize: Int64
    ) -> [VerifiedDuplicateGroup] {
        let groupedByHash = Dictionary(grouping: hashedItems, by: \.checksum)
        return groupedByHash.compactMap { checksum, hashedItems -> VerifiedDuplicateGroup? in
            let items = hashedItems.map(\.item).sorted { $0.url.path < $1.url.path }
            return items.count > 1 ? VerifiedDuplicateGroup(checksum: checksum, byteSize: byteSize, items: items) : nil
        }.sorted { lhs, rhs in
            if lhs.reclaimableBytes == rhs.reclaimableBytes {
                return lhs.byteSize > rhs.byteSize
            }
            return lhs.reclaimableBytes > rhs.reclaimableBytes
        }
    }

    private func duplicateGroupsWithinVerificationBudget(
        _ sizeGroups: [DuplicateSizeGroup],
        options: ScanOptions
    ) -> [DuplicateSizeGroup] {
        guard options.duplicateVerificationByteLimit > 0, options.maxDuplicateVerificationFiles > 0 else {
            return []
        }

        var plannedGroups: [DuplicateSizeGroup] = []
        var plannedBytes: Int64 = 0
        var plannedFiles = 0

        // Prioritize the groups that reclaim the most space: sort by reclaimableBytes
        // descending so the biggest wins are verified within the budget. Tie-break by byteSize
        // so that within equal reclaim, larger individual files are hashed first — a single
        // large duplicate copy frees as much as many small ones.
        let budgetOrderedGroups = sizeGroups.sorted { lhs, rhs in
            if lhs.reclaimableBytes == rhs.reclaimableBytes {
                return lhs.byteSize > rhs.byteSize
            }
            return lhs.reclaimableBytes > rhs.reclaimableBytes
        }

        for group in budgetOrderedGroups {
            let nextBytes = plannedBytes + group.totalBytes
            let nextFiles = plannedFiles + group.items.count
            guard nextBytes <= options.duplicateVerificationByteLimit,
                  nextFiles <= options.maxDuplicateVerificationFiles else {
                continue
            }

            plannedGroups.append(group)
            plannedBytes = nextBytes
            plannedFiles = nextFiles
        }

        return plannedGroups
    }

    private func sha256Checksum(
        for url: URL,
        recordBytesRead: ((Int) -> Void)?,
        cancellation: ScanCancellation?
    ) throws -> String {
        // Probe cancellation before opening so a cancelled batch doesn't keep paying the
        // cost of `FileHandle(forReadingFrom:)` for files that no one will ever read.
        try cancellation?.check()

        let handle = try FileHandle(forReadingFrom: url)
        defer {
            // close() can fail (e.g. NFS flush errors); surface it as an os_signpost event
            // rather than silently swallowing via `try?`. The hash result on disk is
            // already finalised by the time we get here, so a close failure is informational.
            do {
                try handle.close()
            } catch {
                os_signpost(.event, log: Self.log, name: "handle_close_failed",
                            "path=%{public}@ reason=%{public}@", url.path, "\(error)")
            }
        }

        var hasher = SHA256()
        while true {
            // Probe on every chunk so a slow read on a huge file still gets a cooperative
            // cancellation window within one megabyte of additional I/O.
            try cancellation?.check()
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty {
                break
            }
            recordBytesRead?(data.count)
            hasher.update(data: data)
        }

        return hasher.finalize().hexEncodedString()
    }

    private func prefixChecksum(
        for url: URL,
        maxBytes: Int,
        recordBytesRead: ((Int) -> Void)?,
        cancellation: ScanCancellation?
    ) throws -> (checksum: String, bytesRead: Int) {
        try cancellation?.check()

        let handle = try FileHandle(forReadingFrom: url)
        defer {
            do {
                try handle.close()
            } catch {
                os_signpost(.event, log: Self.log, name: "handle_close_failed",
                            "path=%{public}@ reason=%{public}@", url.path, "\(error)")
            }
        }

        var remaining = max(0, maxBytes)
        var bytesRead = 0
        var hasher = SHA256()
        while remaining > 0 {
            try cancellation?.check()
            let readSize = min(remaining, 1_048_576)
            let data = try handle.read(upToCount: readSize) ?? Data()
            if data.isEmpty {
                break
            }
            bytesRead += data.count
            remaining -= data.count
            recordBytesRead?(data.count)
            hasher.update(data: data)
        }

        return (hasher.finalize().hexEncodedString(), bytesRead)
    }

    private func prefixHashedFormItem(
        _ item: StorageItem,
        ioSemaphore: DispatchSemaphore,
        recordBytesRead: ((Int) -> Void)?,
        cancellation: ScanCancellation?
    ) throws -> PrefixHashedStorageItem? {
        ioSemaphore.wait()
        defer { ioSemaphore.signal() }

        do {
            let result = try prefixChecksum(
                for: item.url,
                maxBytes: Self.duplicatePrefixByteCount,
                recordBytesRead: recordBytesRead,
                cancellation: cancellation
            )
            return PrefixHashedStorageItem(
                prefixChecksum: result.checksum,
                bytesRead: result.bytesRead,
                item: item
            )
        } catch FileSystemScannerError.cancelled {
            throw FileSystemScannerError.cancelled
        } catch {
            os_signpost(.event, log: Self.log, name: "hash_prefix_skip",
                        "path=%{public}@ reason=%{public}@", item.url.path, "\(error)")
            return nil
        }
    }

    /// Hashes one item, consulting the persisted `hashCache` fast-path before falling back
    /// to a full `sha256Checksum` read. I/O is throttled through `ioSemaphore`; cache writes
    /// are serialised through `cacheLock`. Returns `nil` for per-file read failures (logged
    /// via os_signpost so Instruments shows what was skipped), and re-throws
    /// `FileSystemScannerError.cancelled` so the caller can abort the whole batch.
    private func hashedFormItem(
        _ item: StorageItem,
        ioSemaphore: DispatchSemaphore,
        cacheLock: NSLock,
        recordBytesRead: ((Int) -> Void)?,
        cancellation: ScanCancellation?
    ) throws -> HashedStorageItem? {
        let cacheKey = DuplicateHashCache.LookupKey(item: item)

        if let cached = hashCache?.checksum(for: cacheKey) {
            return HashedStorageItem(checksum: cached, item: item)
        }

        ioSemaphore.wait()
        defer { ioSemaphore.signal() }

        do {
            let checksum = try sha256Checksum(
                for: item.url,
                recordBytesRead: recordBytesRead,
                cancellation: cancellation
            )
            if let hashCache {
                cacheLock.lock()
                defer { cacheLock.unlock() }
                hashCache.record(cacheKey, checksum: checksum)
            }
            return HashedStorageItem(checksum: checksum, item: item)
        } catch FileSystemScannerError.cancelled {
            throw FileSystemScannerError.cancelled
        } catch {
            os_signpost(.event, log: Self.log, name: "hash_skip",
                        "path=%{public}@ reason=%{public}@", item.url.path, "\(error)")
            return nil
        }
    }
}

private extension StorageItem.Kind {
    var isDirectoryKind: Bool {
        self == .folder || self == .package
    }
}

private struct FixedWorkerResourceIdentifier: Hashable, Sendable {
    let low: UInt64
    let high: UInt64

    static let zero = FixedWorkerResourceIdentifier(low: 0, high: 0)
}

private struct FixedWorkerMetadataSeed: Sendable {
    let name: String
    let kind: StorageItem.Kind
    let byteSize: Int64
    let allocatedSize: Int64
    let modifiedAt: Date?
    let isReadable: Bool
    let volumeIdentifier: FixedWorkerResourceIdentifier
    let fileResourceIdentifier: FixedWorkerResourceIdentifier
    let hardLinkCount: UInt16
}

private struct FixedWorkerWalkRecord: Sendable {
    let id: Int
    let parentID: Int
    let name: String
    let kind: StorageItem.Kind
    let byteSize: Int64
    let allocatedSize: Int64
    let modifiedAt: Date?
    let isReadable: Bool
    let volumeIdentifier: FixedWorkerResourceIdentifier
    let fileResourceIdentifier: FixedWorkerResourceIdentifier
    /// Reserved for the hard-link reclaimability policy; zero means not enriched yet.
    let hardLinkCount: UInt16

    var isDirectory: Bool {
        kind.isDirectoryKind
    }
}

private struct FixedWorkerDirectoryJob: Sendable {
    let metadata: FixedWorkerWalkRecord
    let url: URL
}

private struct FixedWorkerDirectoryRecord: Sendable {
    let metadata: FixedWorkerWalkRecord
    let children: [FixedWorkerWalkRecord]
    let isInaccessible: Bool
}

private struct FixedWorkerWalkResult: Sendable {
    let rootMetadata: FixedWorkerWalkRecord?
    let directoryRecords: [FixedWorkerDirectoryRecord]
}

private struct FixedWorkerCompactChild: Sendable {
    let id: Int
    let displaySize: Int64
    let name: String
    let retainedTreeCount: Int
}

private struct FixedWorkerRetainedSelection: Sendable {
    let id: Int
    let includesDescendants: Bool
    let retainedTreeCount: Int
}

private struct FixedWorkerRetainedChild: Sendable {
    let id: Int
    let includesDescendants: Bool
    let retainedTreeCount: Int
    let summary: FixedWorkerItemSummary
}

private struct FixedWorkerItemSummary: Sendable {
    let metadata: FixedWorkerWalkRecord
    let isInaccessible: Bool
    let logicalSize: Int64
    let allocatedSize: Int64
    let immediateChildCount: Int
    let descendantCount: Int
    let retainedChildren: [FixedWorkerRetainedChild]
    let retainedTreeCount: Int

    var kind: StorageItem.Kind {
        isInaccessible ? .inaccessible : metadata.kind
    }

    var displaySize: Int64 {
        max(logicalSize, allocatedSize)
    }

    var fileExtension: String? {
        switch kind {
        case .folder, .inaccessible:
            return nil
        case .package, .file, .alias, .other:
            return (metadata.name as NSString).pathExtension.nonEmptyLowercased
        }
    }
}

private struct FixedWorkerRankedReference: Sendable {
    let summary: FixedWorkerItemSummary
    let displaySize: Int64
    let url: URL
    let path: String
}

private struct FixedWorkerCleanupCandidateReference: Sendable {
    let summary: FixedWorkerItemSummary
    let url: URL
    let kind: CleanupCandidate.Kind
    let reason: String
    let reclaimableBytes: Int64
    let confidence: CleanupCandidate.Confidence
}

private final class FixedWorkerSummaryStore {
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func makeItem(summary: FixedWorkerItemSummary, urlOverride: URL? = nil) -> StorageItem {
        makeItem(summary: summary, urlOverride: urlOverride, includeDescendants: true)
    }

    private func makeItem(
        summary: FixedWorkerItemSummary,
        urlOverride: URL?,
        includeDescendants: Bool
    ) -> StorageItem {
        let url = urlOverride ?? rootURL
        let children: [StorageItem]
        if includeDescendants {
            children = summary.retainedChildren.map { child in
                makeItem(
                    summary: child.summary,
                    urlOverride: url.appendingPathComponent(
                        child.summary.metadata.name,
                        isDirectory: child.summary.metadata.isDirectory
                    ),
                    includeDescendants: child.includesDescendants
                )
            }
        } else {
            children = []
        }
        return StorageItem(
            url: url,
            name: summary.metadata.name,
            kind: summary.kind,
            byteSize: summary.logicalSize,
            allocatedSize: summary.allocatedSize,
            modifiedAt: summary.metadata.modifiedAt,
            immediateChildCount: summary.immediateChildCount,
            descendantCount: summary.descendantCount,
            children: children,
            isReadable: summary.isInaccessible ? false : summary.metadata.isReadable,
            fileExtension: summary.fileExtension
        )
    }
}

private struct FixedWorkerDirectorySummaryBuilder {
    private let retainedCandidateLimit: Int
    private var retainedCandidateItems: [FixedWorkerItemSummary] = []

    var logicalSize: Int64 = 0
    var allocatedSize: Int64 = 0
    var immediateChildCount = 0
    var descendantCount = 0

    init(retainedCandidateLimit: Int) {
        self.retainedCandidateLimit = max(0, retainedCandidateLimit)
    }

    mutating func record(_ child: FixedWorkerItemSummary) {
        guard child.kind != .other || child.displaySize > 0 else {
            return
        }

        logicalSize += child.logicalSize
        allocatedSize += child.allocatedSize
        immediateChildCount += 1
        descendantCount += 1 + child.descendantCount

        guard retainedCandidateLimit > 0 else {
            return
        }

        retainedCandidateItems.append(child)
        if retainedCandidateItems.count > retainedCandidateLimit * 4 {
            retainedCandidateItems = sortedRetainedCandidates(from: retainedCandidateItems)
        }
    }

    var retainedCandidates: [FixedWorkerCompactChild] {
        sortedRetainedCandidates(from: retainedCandidateItems).map {
            FixedWorkerCompactChild(
                id: $0.metadata.id,
                displaySize: $0.displaySize,
                name: $0.metadata.name,
                retainedTreeCount: $0.retainedTreeCount
            )
        }
    }

    func summary(for id: Int) -> FixedWorkerItemSummary? {
        retainedCandidateItems.first { $0.metadata.id == id }
    }

    private func sortedRetainedCandidates(from items: [FixedWorkerItemSummary]) -> [FixedWorkerItemSummary] {
        Array(
            items.sorted { lhs, rhs in
                if lhs.displaySize == rhs.displaySize {
                    return lhs.metadata.name < rhs.metadata.name
                }
                return lhs.displaySize > rhs.displaySize
            }
            .prefix(retainedCandidateLimit)
        )
    }
}

private enum FixedWorkerWalkerError: Error {
    case workerFailed
}

private final class FixedWorkerFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = false

    func record() {
        lock.lock()
        recorded = true
        lock.unlock()
    }

    var hasFailure: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private final class FixedWorkerRecordIDSource: @unchecked Sendable {
    private let lock = NSLock()
    private var nextID = 1

    func allocate(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let ids = Array(nextID..<(nextID + count))
        nextID += count
        return ids
    }
}

private final class FixedWorkerDirectoryFrontier: @unchecked Sendable {
    private let condition = NSCondition()
    private let capacity: Int
    private var pending: [FixedWorkerDirectoryJob]
    private var activeWorkerSlots = 0
    private var finished = false
    private var cancelled = false

    init(root: FixedWorkerDirectoryJob, capacity: Int) {
        self.capacity = max(1, capacity)
        self.pending = [root]
    }

    func pop(cancellation: ScanCancellation?) -> FixedWorkerDirectoryJob? {
        condition.lock()
        while pending.isEmpty && !finished && !cancelled {
            if cancellation?.isCancelled ?? false {
                cancelled = true
                condition.broadcast()
                break
            }
            condition.wait()
        }

        guard !cancelled, !finished, !pending.isEmpty else {
            condition.unlock()
            return nil
        }

        activeWorkerSlots += 1
        let job = pending.removeLast()
        condition.unlock()
        return job
    }

    func tryEnqueue(_ job: FixedWorkerDirectoryJob) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !cancelled, !finished, pending.count < capacity else {
            return false
        }
        pending.append(job)
        condition.broadcast()
        return true
    }

    func complete(preserveWorkerSlot: Bool) {
        condition.lock()
        if !preserveWorkerSlot {
            activeWorkerSlots = max(0, activeWorkerSlots - 1)
        }
        if activeWorkerSlots == 0 && pending.isEmpty {
            finished = true
        }
        condition.broadcast()
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class FixedWorkerRecordChannel: @unchecked Sendable {
    private let condition = NSCondition()
    private let capacity: Int
    private var buffer: [FixedWorkerDirectoryRecord] = []
    private var producersFinished = false
    private var cancelled = false

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        buffer.reserveCapacity(self.capacity)
    }

    func send(_ record: FixedWorkerDirectoryRecord, cancellation: ScanCancellation?) -> Bool {
        condition.lock()
        while buffer.count >= capacity && !producersFinished && !cancelled {
            if cancellation?.isCancelled ?? false {
                cancelled = true
                condition.broadcast()
                break
            }
            condition.wait()
        }

        guard !cancelled, !producersFinished, !(cancellation?.isCancelled ?? false) else {
            condition.unlock()
            return false
        }

        buffer.append(record)
        condition.signal()
        condition.unlock()
        return true
    }

    func receive(cancellation: ScanCancellation?) -> FixedWorkerDirectoryRecord? {
        condition.lock()
        while buffer.isEmpty && !producersFinished && !cancelled {
            if cancellation?.isCancelled ?? false {
                cancelled = true
                condition.broadcast()
                break
            }
            condition.wait()
        }

        guard !cancelled, !buffer.isEmpty else {
            condition.unlock()
            return nil
        }

        let record = buffer.removeLast()
        condition.signal()
        condition.unlock()
        return record
    }

    func finishProducers() {
        condition.lock()
        producersFinished = true
        condition.broadcast()
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class FixedWorkerRecordCollector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.rasputinkaiser.StorageScope.fixed-worker-records")
    private var records: [FixedWorkerDirectoryRecord] = []

    func append(_ record: FixedWorkerDirectoryRecord) {
        queue.sync {
            records.append(record)
        }
    }

    func allRecords() -> [FixedWorkerDirectoryRecord] {
        queue.sync {
            records
        }
    }
}

private final class FixedWorkerDirectoryWalker: @unchecked Sendable {
    private let fileManager: FileManager
    private let resourceKeys: Set<URLResourceKey>
    private let options: ScanOptions
    private let cancellation: ScanCancellation?
    private let shouldExclude: (URL) -> Bool

    init(
        fileManager: FileManager,
        resourceKeys: Set<URLResourceKey>,
        options: ScanOptions,
        cancellation: ScanCancellation?,
        shouldExclude: @escaping (URL) -> Bool
    ) {
        self.fileManager = fileManager
        self.resourceKeys = resourceKeys.union([
            .fileResourceIdentifierKey,
            .volumeIdentifierKey
        ])
        self.options = options
        self.cancellation = cancellation
        self.shouldExclude = shouldExclude
    }

    func walk(root: URL) throws -> FixedWorkerWalkResult {
        guard let rootSeed = metadataSeed(for: root) else {
            return FixedWorkerWalkResult(rootMetadata: nil, directoryRecords: [])
        }

        let rootMetadata = makeRecord(rootSeed, id: 0, parentID: 0)
        guard rootMetadata.isDirectory else {
            return FixedWorkerWalkResult(rootMetadata: rootMetadata, directoryRecords: [])
        }

        let workerCount = configuredWorkerCount()
        let recordIDSource = FixedWorkerRecordIDSource()
        let frontier = FixedWorkerDirectoryFrontier(
            root: FixedWorkerDirectoryJob(metadata: rootMetadata, url: root),
            capacity: workerCount * 8
        )
        let channel = FixedWorkerRecordChannel(capacity: workerCount * 2)
        let collector = FixedWorkerRecordCollector()
        let failure = FixedWorkerFailure()
        let consumerGroup = DispatchGroup()

        consumerGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            while let record = channel.receive(cancellation: self.cancellation) {
                collector.append(record)
            }
            consumerGroup.leave()
        }

        DispatchQueue.concurrentPerform(iterations: workerCount) { _ in
            var localJobs: [FixedWorkerDirectoryJob] = []

            while true {
                self.cancellation?.waitIfPaused()
                if self.cancellation?.isCancelled ?? false {
                    frontier.cancel()
                    channel.cancel()
                    return
                }

                let job: FixedWorkerDirectoryJob
                if let localJob = localJobs.popLast() {
                    job = localJob
                } else {
                    guard let nextJob = frontier.pop(cancellation: self.cancellation) else {
                        return
                    }
                    job = nextJob
                }

                do {
                    let record = try autoreleasepool {
                        try self.enumerate(job, recordIDSource: recordIDSource)
                    }
                    guard channel.send(record, cancellation: self.cancellation) else {
                        frontier.cancel()
                        channel.cancel()
                        frontier.complete(preserveWorkerSlot: false)
                        return
                    }

                    for child in record.children where child.isDirectory {
                        let childJob = FixedWorkerDirectoryJob(
                            metadata: child,
                            url: job.url.appendingPathComponent(child.name, isDirectory: true)
                        )
                        if !frontier.tryEnqueue(childJob) {
                            localJobs.append(childJob)
                        }
                    }
                    frontier.complete(preserveWorkerSlot: !localJobs.isEmpty)
                } catch FileSystemScannerError.cancelled {
                    frontier.cancel()
                    channel.cancel()
                    frontier.complete(preserveWorkerSlot: false)
                    return
                } catch {
                    // Filesystem failures are converted into inaccessible records.
                    // Keep this guard for future worker-only failures.
                    failure.record()
                    frontier.cancel()
                    channel.cancel()
                    frontier.complete(preserveWorkerSlot: false)
                    return
                }
            }
        }

        channel.finishProducers()
        consumerGroup.wait()
        try cancellation?.check()
        if failure.hasFailure {
            throw FixedWorkerWalkerError.workerFailed
        }

        return FixedWorkerWalkResult(
            rootMetadata: rootMetadata,
            directoryRecords: collector.allRecords()
        )
    }

    private func enumerate(
        _ job: FixedWorkerDirectoryJob,
        recordIDSource: FixedWorkerRecordIDSource
    ) throws -> FixedWorkerDirectoryRecord {
        try cancellation?.check()

        let childURLs: [URL]
        do {
            let directoryOptions: FileManager.DirectoryEnumerationOptions = options.includeHidden ? [] : [.skipsHiddenFiles]
            childURLs = try fileManager.contentsOfDirectory(
                at: job.url,
                includingPropertiesForKeys: Array(resourceKeys),
                options: directoryOptions
            )
        } catch FileSystemScannerError.cancelled {
            throw FileSystemScannerError.cancelled
        } catch {
            return FixedWorkerDirectoryRecord(
                metadata: job.metadata,
                children: [],
                isInaccessible: true
            )
        }

        var childSeeds: [FixedWorkerMetadataSeed] = []
        childSeeds.reserveCapacity(childURLs.count)
        for childURL in childURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try cancellation?.check()
            if shouldExclude(childURL) {
                continue
            }
            guard let seed = metadataSeed(for: childURL) else {
                continue
            }
            childSeeds.append(seed)
        }

        let childIDs = recordIDSource.allocate(count: childSeeds.count)
        let children = zip(childIDs, childSeeds).map { id, seed in
            makeRecord(seed, id: id, parentID: job.metadata.id)
        }

        return FixedWorkerDirectoryRecord(
            metadata: job.metadata,
            children: children,
            isInaccessible: false
        )
    }

    private func metadataSeed(for url: URL) -> FixedWorkerMetadataSeed? {
        do {
            let values = try url.resourceValues(forKeys: resourceKeys)
            if values.isHidden == true && !options.includeHidden {
                return nil
            }

            let isSymbolicLink = values.isSymbolicLink == true
            let isDirectory = !isSymbolicLink && values.isDirectory == true
            let kind: StorageItem.Kind
            if isSymbolicLink {
                kind = .alias
            } else if isDirectory {
                kind = values.isPackage == true ? .package : .folder
            } else {
                kind = values.isRegularFile == true ? .file : .other
            }

            let logicalSize = Int64(values.fileSize ?? 0)
            let allocatedSize = Int64(
                values.totalFileAllocatedSize ??
                    values.fileAllocatedSize ??
                    values.fileSize ??
                    0
            )
            return FixedWorkerMetadataSeed(
                name: url.lastPathComponent,
                kind: kind,
                byteSize: logicalSize,
                allocatedSize: allocatedSize,
                modifiedAt: values.contentModificationDate,
                isReadable: values.isReadable ?? true,
                volumeIdentifier: resourceIdentifierValue(values.volumeIdentifier),
                fileResourceIdentifier: resourceIdentifierValue(values.fileResourceIdentifier),
                hardLinkCount: 0
            )
        } catch {
            return FixedWorkerMetadataSeed(
                name: url.lastPathComponent,
                kind: .other,
                byteSize: 0,
                allocatedSize: 0,
                modifiedAt: nil,
                isReadable: true,
                volumeIdentifier: .zero,
                fileResourceIdentifier: .zero,
                hardLinkCount: 0
            )
        }
    }

    private func makeRecord(
        _ seed: FixedWorkerMetadataSeed,
        id: Int,
        parentID: Int
    ) -> FixedWorkerWalkRecord {
        FixedWorkerWalkRecord(
            id: id,
            parentID: parentID,
            name: seed.name,
            kind: seed.kind,
            byteSize: seed.byteSize,
            allocatedSize: seed.allocatedSize,
            modifiedAt: seed.modifiedAt,
            isReadable: seed.isReadable,
            volumeIdentifier: seed.volumeIdentifier,
            fileResourceIdentifier: seed.fileResourceIdentifier,
            hardLinkCount: seed.hardLinkCount
        )
    }

    private func resourceIdentifierValue(_ value: Any?) -> FixedWorkerResourceIdentifier {
        if let number = value as? NSNumber {
            return FixedWorkerResourceIdentifier(low: number.uint64Value, high: 0)
        }
        guard let data = value as? NSData,
              data.length >= MemoryLayout<UInt64>.size else {
            return .zero
        }

        var low = UInt64.zero
        data.getBytes(&low, length: MemoryLayout<UInt64>.size)
        guard data.length >= MemoryLayout<UInt64>.size * 2 else {
            return FixedWorkerResourceIdentifier(low: low, high: 0)
        }

        var high = UInt64.zero
        data.getBytes(&high, range: NSRange(
            location: MemoryLayout<UInt64>.size,
            length: MemoryLayout<UInt64>.size
        ))
        return FixedWorkerResourceIdentifier(low: low, high: high)
    }

    private func configuredWorkerCount() -> Int {
        if let raw = ProcessInfo.processInfo.environment["STORAGESCOPE_WORKER_COUNT"],
           let value = Int(raw),
           (1...16).contains(value) {
            return value
        }
        return min(8, max(4, ProcessInfo.processInfo.activeProcessorCount))
    }
}

private struct HashedStorageItem {
    let checksum: String
    let item: StorageItem
}

private struct PrefixHashedStorageItem {
    let prefixChecksum: String
    let bytesRead: Int
    let item: StorageItem

    var isCompleteFile: Bool {
        Int64(bytesRead) >= item.byteSize
    }
}

private struct DirectoryScanSummary {
    private let retainedCandidateLimit: Int
    private var retainedCandidateItems: [StorageItem] = []

    var logicalSize: Int64 = 0
    var allocatedSize: Int64 = 0
    var immediateChildCount = 0
    var descendantCount = 0

    init(retainedCandidateLimit: Int) {
        self.retainedCandidateLimit = max(0, retainedCandidateLimit)
    }

    mutating func record(_ child: StorageItem) {
        logicalSize += child.byteSize
        allocatedSize += child.allocatedSize
        immediateChildCount += 1
        descendantCount += 1 + child.descendantCount

        guard retainedCandidateLimit > 0 else {
            return
        }

        retainedCandidateItems.append(child)
        if retainedCandidateItems.count > retainedCandidateLimit * 4 {
            retainedCandidateItems = sortedRetainedCandidates(from: retainedCandidateItems)
        }
    }

    var retainedCandidates: [StorageItem] {
        sortedRetainedCandidates(from: retainedCandidateItems)
    }

    private func sortedRetainedCandidates(from items: [StorageItem]) -> [StorageItem] {
        Array(
            items.sorted { lhs, rhs in
                if lhs.displaySize == rhs.displaySize {
                    return lhs.name < rhs.name
                }
                return lhs.displaySize > rhs.displaySize
            }
            .prefix(retainedCandidateLimit)
        )
    }
}

private struct FixedWorkerDuplicateCandidateReference: Sendable {
    let summary: FixedWorkerItemSummary
    let byteSize: Int64
    let url: URL
}

private struct FixedWorkerDuplicateCandidateRetention {
    private let limit: Int
    private var candidatesBySize: [Int64: [FixedWorkerDuplicateCandidateReference]] = [:]
    private var smallestRetainedSize: Int64?

    private(set) var retainedCount = 0
    private(set) var consideredCount = 0
    private(set) var evictionCount = 0
    private(set) var limitReached = false

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    mutating func record(_ summary: FixedWorkerItemSummary, url: URL) {
        consideredCount += 1
        guard limit > 0 else {
            limitReached = true
            return
        }

        if retainedCount >= limit,
           let smallestRetainedSize,
           summary.metadata.byteSize < smallestRetainedSize {
            limitReached = true
            return
        }

        candidatesBySize[summary.metadata.byteSize, default: []].append(
            FixedWorkerDuplicateCandidateReference(
                summary: summary,
                byteSize: summary.metadata.byteSize,
                url: url
            )
        )
        retainedCount += 1
        if smallestRetainedSize.map({ summary.metadata.byteSize < $0 }) ?? true {
            smallestRetainedSize = summary.metadata.byteSize
        }

        guard retainedCount > limit else {
            return
        }

        limitReached = true
        evictSmallestRetained()
    }

    func sizeGroups(using summaryStore: FixedWorkerSummaryStore) -> [DuplicateSizeGroup] {
        candidatesBySize
            .compactMap { byteSize, references in
                guard references.count > 1 else { return nil }
                let items = references
                    .map { summaryStore.makeItem(summary: $0.summary, urlOverride: $0.url) }
                    .sorted { $0.url.path < $1.url.path }
                return DuplicateSizeGroup(byteSize: byteSize, items: items)
            }
            .sorted { lhs, rhs in
                if lhs.totalBytes == rhs.totalBytes {
                    return lhs.byteSize > rhs.byteSize
                }
                return lhs.totalBytes > rhs.totalBytes
            }
    }

    private mutating func evictSmallestRetained() {
        guard let smallestByteSize = smallestRetainedSize ?? candidatesBySize.keys.min(),
              var items = candidatesBySize[smallestByteSize],
              !items.isEmpty else {
            smallestRetainedSize = candidatesBySize.keys.min()
            return
        }

        items.removeLast()
        retainedCount -= 1
        evictionCount += 1

        if items.isEmpty {
            candidatesBySize.removeValue(forKey: smallestByteSize)
            smallestRetainedSize = candidatesBySize.keys.min()
        } else {
            candidatesBySize[smallestByteSize] = items
        }
    }
}

private extension CleanupCandidate.Confidence {
    var sortRank: Int {
        switch self {
        case .high:
            return 0
        case .medium:
            return 1
        case .review:
            return 2
        }
    }
}

struct DuplicateCandidateRetention {
    private let limit: Int
    private var candidatesBySize: [Int64: [StorageItem]] = [:]
    private var smallestRetainedSize: Int64?

    private(set) var retainedCount = 0
    private(set) var consideredCount = 0
    private(set) var evictionCount = 0
    private(set) var limitReached = false

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    var sizeGroups: [DuplicateSizeGroup] {
        candidatesBySize
            .compactMap { byteSize, items in
                items.count > 1 ? DuplicateSizeGroup(byteSize: byteSize, items: items.sorted { $0.url.path < $1.url.path }) : nil
            }
            .sorted { lhs, rhs in
                if lhs.totalBytes == rhs.totalBytes {
                    return lhs.byteSize > rhs.byteSize
                }
                return lhs.totalBytes > rhs.totalBytes
            }
    }

    mutating func record(_ item: StorageItem) {
        consideredCount += 1
        guard limit > 0 else {
            limitReached = true
            return
        }

        if retainedCount >= limit,
           let smallestRetainedSize,
           item.byteSize < smallestRetainedSize {
            limitReached = true
            return
        }

        candidatesBySize[item.byteSize, default: []].append(item)
        retainedCount += 1
        if smallestRetainedSize.map({ item.byteSize < $0 }) ?? true {
            smallestRetainedSize = item.byteSize
        }

        guard retainedCount > limit else {
            return
        }

        limitReached = true
        evictSmallestRetained()
    }

    private mutating func evictSmallestRetained() {
        guard let smallestByteSize = smallestRetainedSize ?? candidatesBySize.keys.min(),
              var items = candidatesBySize[smallestByteSize],
              !items.isEmpty else {
            smallestRetainedSize = candidatesBySize.keys.min()
            return
        }

        items.removeLast()
        retainedCount -= 1
        evictionCount += 1

        if items.isEmpty {
            candidatesBySize.removeValue(forKey: smallestByteSize)
            smallestRetainedSize = candidatesBySize.keys.min()
        } else {
            candidatesBySize[smallestByteSize] = items
        }
    }
}

private final class ScanAccumulator {
    /// Shares the FileSystemScanner signpost subsystem/category so cleanup-candidate
    /// build shows up alongside the scan/enumerate/verify spans when profiling.
    private static let log = OSLog(subsystem: "com.rasputinkaiser.StorageScope", category: "scan")
    private static let signpostID = OSSignpostID(log: log)

    private struct FileTypeAccumulator {
        var category: FileTypeStat.Category = .other
        var fileCount = 0
        var totalBytes: Int64 = 0
    }

    private let options: ScanOptions
    private let progress: FileSystemScanner.ProgressHandler?
    private let onSnapshot: ((StorageScan) -> Void)?
    private let rootURL: URL
    private let startedAt: Date
    private var lastProgressDate = Date.distantPast
    private var lastSnapshotDate = Date.distantPast
    private let oldFileCutoff: Date
    private var retainedItemCount: Int
    private var largestFileItems: [StorageItem] = []
    private var largestFolderItems: [StorageItem] = []
    private var oldLargeFileItems: [StorageItem] = []
    private var fileTypeStats: [String: FileTypeAccumulator] = [:]
    private var duplicateCandidateRetention: DuplicateCandidateRetention
    private var cleanupCandidatesByID: [String: CleanupCandidate] = [:]
    private var fixedWorkerSummaryStore: FixedWorkerSummaryStore?
    private var fixedWorkerLargestFileItems: [FixedWorkerRankedReference] = []
    private var fixedWorkerLargestFolderItems: [FixedWorkerRankedReference] = []
    private var fixedWorkerOldLargeFileItems: [FixedWorkerRankedReference] = []
    private var fixedWorkerCleanupCandidatesByID: [Int: FixedWorkerCleanupCandidateReference] = [:]
    private var fixedWorkerDuplicateCandidateRetention: FixedWorkerDuplicateCandidateRetention?

    var scannedItemCount = 0
    var inaccessibleItemCount = 0
    var totalBytes: Int64 = 0
    private(set) var duplicateVerificationBytesRead: Int64 = 0
    private(set) var snapshotBuildCount = 0

    /// Guards every mutable field above. Held briefly during directory enumeration's
    /// record*() calls; the user `progress` and `onSnapshot` closures are both invoked
    /// under this lock, so neither must re-enter the accumulator or block for long — every
    /// concurrentPerform worker thread recording an item serializes on whichever thread is
    /// currently inside one of these callbacks. Contention is bounded today because both
    /// callbacks only do cheap NSLock bookkeeping on the ScanStore side; a callback that
    /// becomes non-trivial (e.g. blocking on a busy MainActor) would serialize the whole
    /// scan on this lock.
    private let lock = NSLock()

    init(
        options: ScanOptions,
        progress: FileSystemScanner.ProgressHandler?,
        onSnapshot: ((StorageScan) -> Void)? = nil,
        rootURL: URL = URL(fileURLWithPath: "/"),
        startedAt: Date = Date()
    ) {
        self.options = options
        self.progress = progress
        self.onSnapshot = onSnapshot
        self.rootURL = rootURL
        self.startedAt = startedAt
        self.retainedItemCount = 1
        self.duplicateCandidateRetention = DuplicateCandidateRetention(limit: options.maxDuplicateCandidateItems)
        self.oldFileCutoff = Calendar.current.date(
            byAdding: .day,
            value: -options.oldFileAgeDays,
            to: Date()
        ) ?? Date()
    }

    func configureFixedWorkerStore(_ summaryStore: FixedWorkerSummaryStore) {
        fixedWorkerSummaryStore = summaryStore
        fixedWorkerDuplicateCandidateRetention = FixedWorkerDuplicateCandidateRetention(
            limit: options.maxDuplicateCandidateItems
        )
    }

    func recordFixedWorkerScannedItem(
        _ summary: FixedWorkerItemSummary,
        url: URL
    ) {
        // Fixed-worker reconstruction runs after the worker walk has completed, so this
        // accumulator is owned by the reconstruction thread until scan() publishes its
        // final StorageScan. Avoid taking the legacy per-item lock in that serial phase.
        scannedItemCount += 1
        totalBytes += max(summary.logicalSize, summary.allocatedSize)
        recordFixedWorkerItemLocked(summary, url: url)
        emitProgressLocked(path: url.path)
    }

    func recordFixedWorkerItem(
        _ summary: FixedWorkerItemSummary,
        url: URL
    ) {
        recordFixedWorkerItemLocked(summary, url: url)
    }

    private func recordFixedWorkerItemLocked(
        _ summary: FixedWorkerItemSummary,
        url: URL
    ) {
        switch summary.kind {
        case .file:
            insertFixedWorkerRankedReference(
                for: summary,
                url: url,
                into: &fixedWorkerLargestFileItems
            )

            if let modifiedAt = summary.metadata.modifiedAt,
               summary.displaySize >= options.largeFileThreshold,
               modifiedAt <= oldFileCutoff {
                insertFixedWorkerRankedReference(
                    for: summary,
                    url: url,
                    into: &fixedWorkerOldLargeFileItems
                )
            }

            let typeLabel: String
            if let fileExtension = summary.fileExtension, !fileExtension.isEmpty {
                typeLabel = ".\(fileExtension)"
            } else {
                typeLabel = "No Extension"
            }

            var typeStat = fileTypeStats[typeLabel] ?? FileTypeAccumulator()
            typeStat.category = FileTypeCategoryClassifier.category(forExtension: summary.fileExtension)
            typeStat.fileCount += 1
            typeStat.totalBytes += summary.displaySize
            fileTypeStats[typeLabel] = typeStat

            if summary.metadata.byteSize >= options.duplicateCandidateThreshold {
                fixedWorkerDuplicateCandidateRetention?.record(summary, url: url)
            }
        case .folder, .package:
            insertFixedWorkerRankedReference(
                for: summary,
                url: url,
                into: &fixedWorkerLargestFolderItems
            )
        case .alias, .inaccessible, .other:
            break
        }

        if let candidate = fixedWorkerCleanupCandidate(for: summary, url: url) {
            insertFixedWorkerCleanupCandidateLocked(candidate)
        }
    }

    private func insertFixedWorkerRankedReference(
        for summary: FixedWorkerItemSummary,
        url: URL,
        into references: inout [FixedWorkerRankedReference]
    ) {
        let limit = max(0, options.maxRankedResults)
        guard limit > 0 else {
            references.removeAll(keepingCapacity: false)
            return
        }

        if references.count < limit {
            references.append(
                FixedWorkerRankedReference(
                    summary: summary,
                    displaySize: summary.displaySize,
                    url: url,
                    path: url.path
                )
            )
            siftUpFixedWorkerRankedReferences(&references)
            return
        }

        let worst = references[0]
        if summary.displaySize < worst.displaySize {
            return
        }

        let path: String
        if summary.displaySize == worst.displaySize {
            path = url.path
            guard path < worst.path else {
                return
            }
        } else {
            path = url.path
        }

        let reference = FixedWorkerRankedReference(
            summary: summary,
            displaySize: summary.displaySize,
            url: url,
            path: path
        )
        references[0] = reference
        siftDownFixedWorkerRankedReferences(&references)
    }

    private func fixedWorkerReferenceIsBetter(
        _ lhs: FixedWorkerRankedReference,
        _ rhs: FixedWorkerRankedReference
    ) -> Bool {
        if lhs.displaySize == rhs.displaySize {
            return lhs.path < rhs.path
        }
        return lhs.displaySize > rhs.displaySize
    }

    private func fixedWorkerReferenceIsWorse(
        _ lhs: FixedWorkerRankedReference,
        _ rhs: FixedWorkerRankedReference
    ) -> Bool {
        if lhs.displaySize == rhs.displaySize {
            return lhs.path > rhs.path
        }
        return lhs.displaySize < rhs.displaySize
    }

    private func siftUpFixedWorkerRankedReferences(
        _ references: inout [FixedWorkerRankedReference]
    ) {
        var childIndex = references.index(before: references.endIndex)
        while childIndex > references.startIndex {
            let parentIndex = (childIndex - references.startIndex - 1) / 2 + references.startIndex
            guard fixedWorkerReferenceIsWorse(references[childIndex], references[parentIndex]) else {
                break
            }
            references.swapAt(childIndex, parentIndex)
            childIndex = parentIndex
        }
    }

    private func siftDownFixedWorkerRankedReferences(
        _ references: inout [FixedWorkerRankedReference]
    ) {
        var parentIndex = references.startIndex
        while true {
            let relativeParentIndex = parentIndex - references.startIndex
            let leftIndex = relativeParentIndex * 2 + 1 + references.startIndex
            guard leftIndex < references.endIndex else {
                return
            }

            var worstIndex = parentIndex
            if fixedWorkerReferenceIsWorse(references[leftIndex], references[worstIndex]) {
                worstIndex = leftIndex
            }

            let rightIndex = leftIndex + 1
            if rightIndex < references.endIndex,
               fixedWorkerReferenceIsWorse(references[rightIndex], references[worstIndex]) {
                worstIndex = rightIndex
            }

            guard worstIndex != parentIndex else {
                return
            }
            references.swapAt(parentIndex, worstIndex)
            parentIndex = worstIndex
        }
    }

    private func insertFixedWorkerCleanupCandidateLocked(
        _ candidate: FixedWorkerCleanupCandidateReference
    ) {
        let id = candidate.summary.metadata.id
        if let existing = fixedWorkerCleanupCandidatesByID[id] {
            if candidate.confidence.sortRank < existing.confidence.sortRank ||
                candidate.reclaimableBytes > existing.reclaimableBytes {
                fixedWorkerCleanupCandidatesByID[id] = candidate
            }
        } else {
            fixedWorkerCleanupCandidatesByID[id] = candidate
        }
    }

    func recordVisit(path: String) {
        lock.lock()
        defer { lock.unlock() }
        scannedItemCount += 1
        emitProgressLocked(path: path)
    }

    func recordInaccessible(path: String) {
        lock.lock()
        defer { lock.unlock() }
        inaccessibleItemCount += 1
        emitProgressLocked(path: path)
    }

    func recordDuplicateVerificationBytes(_ bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock()
        duplicateVerificationBytesRead += Int64(bytes)
        lock.unlock()
    }

    func recordPhase(path: String, phase: ScanPhase = .enumerating) {
        lock.lock()
        defer { lock.unlock() }
        emitProgressLocked(path: path, force: true, phase: phase)
    }

    func recordScannedItem(_ item: StorageItem, countedBytes: Int64, path: String) {
        lock.lock()
        defer { lock.unlock() }
        scannedItemCount += 1
        totalBytes += countedBytes
        recordItemLocked(item)
        emitProgressLocked(path: path)
    }

    func recordItem(_ item: StorageItem) {
        lock.lock()
        defer { lock.unlock() }
        recordItemLocked(item)
    }

    private func recordItemLocked(_ item: StorageItem) {
        switch item.kind {
        case .file:
            recordFileLocked(item)
        case .folder, .package:
            largestFolderItems.append(item)
            trimRankedItems(&largestFolderItems, limit: options.maxRankedResults) { $0.displaySize > $1.displaySize }
        case .alias, .inaccessible, .other:
            break
        }

        if let candidate = ruleBasedCleanupCandidate(for: item) {
            insertCandidateLocked(candidate, into: &cleanupCandidatesByID)
        }
    }

    /// `scanItem`'s recursion is depth-first and post-order: every descendant directory
    /// finishes recursing (and calls this for its own children) before its ancestor does.
    /// So on any scan large enough to need the retention budget, the deepest directories
    /// spend the shared `retainedItemCount` counter first, and the root's own call — the
    /// very last one to run — can find the budget already exhausted and return `[]`. That
    /// makes Folder Tree and Storage Map render empty exactly when they're needed most,
    /// even though the root has real children.
    ///
    /// Fix: the root (`depth == 0`) always gets at least a pruned (childless) slot for each
    /// of its direct children, regardless of how much budget deeper recursion already
    /// spent. This is bounded by `maxChildrenPerDirectory` — a small, fixed overshoot of the
    /// global cap — not exponential, since only depth 0 is exempted. Every depth below the
    /// root keeps the original shared-budget gating.
    func retainedChildren(from children: [StorageItem], depth: Int) -> [StorageItem] {
        lock.lock()
        defer { lock.unlock() }
        let perDirectoryLimit = max(0, options.maxChildrenPerDirectory)
        guard perDirectoryLimit > 0 else {
            return []
        }

        let retainedLimit = max(1, options.maxRetainedItems)
        let isGuaranteedDepth = depth == 0

        guard isGuaranteedDepth || retainedItemCount < retainedLimit else {
            return []
        }

        var retained: [StorageItem] = []
        retained.reserveCapacity(min(children.count, perDirectoryLimit))

        for child in children.prefix(perDirectoryLimit) {
            guard isGuaranteedDepth || retainedItemCount < retainedLimit else {
                break
            }

            let fullCount = child.retainedItemCount
            if retainedItemCount + fullCount <= retainedLimit {
                retained.append(child)
                retainedItemCount += fullCount
            } else {
                retained.append(child.pruningChildren())
                retainedItemCount += 1
            }
        }

        return retained
    }

    func retainedFixedWorkerChildren(
        from children: [FixedWorkerCompactChild],
        depth: Int
    ) -> [FixedWorkerRetainedSelection] {
        let perDirectoryLimit = max(0, options.maxChildrenPerDirectory)
        guard perDirectoryLimit > 0 else {
            return []
        }

        let retainedLimit = max(1, options.maxRetainedItems)
        let isGuaranteedDepth = depth == 0

        guard isGuaranteedDepth || retainedItemCount < retainedLimit else {
            return []
        }

        var retained: [FixedWorkerRetainedSelection] = []
        retained.reserveCapacity(min(children.count, perDirectoryLimit))

        for child in children.prefix(perDirectoryLimit) {
            guard isGuaranteedDepth || retainedItemCount < retainedLimit else {
                break
            }

            let fullCount = child.retainedTreeCount
            if retainedItemCount + fullCount <= retainedLimit {
                retained.append(
                    FixedWorkerRetainedSelection(
                        id: child.id,
                        includesDescendants: true,
                        retainedTreeCount: fullCount
                    )
                )
                retainedItemCount += fullCount
            } else {
                retained.append(
                    FixedWorkerRetainedSelection(
                        id: child.id,
                        includesDescendants: false,
                        retainedTreeCount: 1
                    )
                )
                retainedItemCount += 1
            }
        }

        return retained
    }

    var largestFiles: [StorageItem] {
        if let summaryStore = fixedWorkerSummaryStore {
            return materializedFixedWorkerRankedItems(fixedWorkerLargestFileItems, summaryStore: summaryStore)
        }
        return sortedRankedItems(largestFileItems, limit: options.maxRankedResults) { $0.displaySize > $1.displaySize }
    }

    func largestFolders(excluding rootID: String) -> [StorageItem] {
        if let summaryStore = fixedWorkerSummaryStore {
            return materializedFixedWorkerRankedItems(fixedWorkerLargestFolderItems, summaryStore: summaryStore)
                .filter { $0.id != rootID }
        }
        return sortedRankedItems(largestFolderItems.filter { $0.id != rootID }, limit: options.maxRankedResults) {
            $0.displaySize > $1.displaySize
        }
    }

    var oldLargeFiles: [StorageItem] {
        if let summaryStore = fixedWorkerSummaryStore {
            return materializedFixedWorkerRankedItems(fixedWorkerOldLargeFileItems, summaryStore: summaryStore)
        }
        return sortedRankedItems(oldLargeFileItems, limit: options.maxRankedResults) { $0.displaySize > $1.displaySize }
    }

    var typeBreakdown: [FileTypeStat] {
        fileTypeStats.map { label, stats in
            FileTypeStat(label: label, category: stats.category, fileCount: stats.fileCount, totalBytes: stats.totalBytes)
        }
        .sorted { lhs, rhs in
            if lhs.totalBytes == rhs.totalBytes {
                return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
            }
            return lhs.totalBytes > rhs.totalBytes
        }
    }

    var categoryBreakdown: [FileCategoryStat] {
        var statsByCategory: [FileTypeStat.Category: (fileCount: Int, extensionCount: Int, totalBytes: Int64)] = [:]

        for stats in fileTypeStats.values {
            var categoryStat = statsByCategory[stats.category] ?? (fileCount: 0, extensionCount: 0, totalBytes: 0)
            categoryStat.fileCount += stats.fileCount
            categoryStat.extensionCount += 1
            categoryStat.totalBytes += stats.totalBytes
            statsByCategory[stats.category] = categoryStat
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

    var duplicateSizeGroups: [DuplicateSizeGroup] {
        if let summaryStore = fixedWorkerSummaryStore,
           let retention = fixedWorkerDuplicateCandidateRetention {
            return retention.sizeGroups(using: summaryStore)
        }
        return duplicateCandidateRetention.sizeGroups
    }

    var duplicateCandidateItemLimit: Int {
        max(0, options.maxDuplicateCandidateItems)
    }

    var duplicateCandidateItemsRetained: Int {
        if let retention = fixedWorkerDuplicateCandidateRetention {
            return retention.retainedCount
        }
        return duplicateCandidateRetention.retainedCount
    }

    var duplicateCandidateItemsConsidered: Int {
        if let retention = fixedWorkerDuplicateCandidateRetention {
            return retention.consideredCount
        }
        return duplicateCandidateRetention.consideredCount
    }

    var duplicateCandidateEvictionCount: Int {
        if let retention = fixedWorkerDuplicateCandidateRetention {
            return retention.evictionCount
        }
        return duplicateCandidateRetention.evictionCount
    }

    var duplicateCandidateLimitReached: Bool {
        if let retention = fixedWorkerDuplicateCandidateRetention {
            return retention.limitReached
        }
        return duplicateCandidateRetention.limitReached
    }

    private func materializedFixedWorkerRankedItems(
        _ references: [FixedWorkerRankedReference],
        summaryStore: FixedWorkerSummaryStore
    ) -> [StorageItem] {
        references
            .sorted { lhs, rhs in
                if lhs.displaySize == rhs.displaySize {
                    return lhs.path < rhs.path
                }
                return lhs.displaySize > rhs.displaySize
            }
            .map { summaryStore.makeItem(summary: $0.summary, urlOverride: $0.url) }
    }

    func cleanupCandidates(
        rootID: String,
        verifiedDuplicateGroups: [VerifiedDuplicateGroup],
        limit: Int
    ) -> [CleanupCandidate] {
        let cleanupSignpostID = OSSignpostID(log: Self.log, object: limit as NSNumber)
        os_signpost(.begin, log: Self.log, name: "cleanup_candidates_build", signpostID: cleanupSignpostID,
                    "verifiedGroups=%d limit=%d", verifiedDuplicateGroups.count, limit)
        defer {
            os_signpost(.end, log: Self.log, name: "cleanup_candidates_build", signpostID: cleanupSignpostID)
        }

        let duplicateItemIDs = Set(verifiedDuplicateGroups.flatMap { group in group.items.dropFirst().map(\.id) })
        var candidatesByID: [String: CleanupCandidate]
        if let summaryStore = fixedWorkerSummaryStore {
            var fixedCandidatesByID: [String: CleanupCandidate] = [:]
            for candidate in fixedWorkerCleanupCandidatesByID.values {
                let item = summaryStore.makeItem(summary: candidate.summary, urlOverride: candidate.url)
                guard item.id != rootID, !duplicateItemIDs.contains(item.id) else {
                    continue
                }
                fixedCandidatesByID[item.id] = CleanupCandidate(
                    kind: candidate.kind,
                    item: item,
                    reason: candidate.reason,
                    reclaimableBytes: candidate.reclaimableBytes,
                    confidence: candidate.confidence
                )
            }
            candidatesByID = fixedCandidatesByID
        } else {
            candidatesByID = cleanupCandidatesByID.filter { id, _ in
                id != rootID && !duplicateItemIDs.contains(id)
            }
        }

        for group in verifiedDuplicateGroups {
            for item in group.items.dropFirst() {
                insertCandidateLocked(
                    CleanupCandidate(
                        kind: .verifiedDuplicate,
                        item: item,
                        reason: "Verified SHA-256 duplicate. Keep one copy, review the rest.",
                        reclaimableBytes: item.displaySize,
                        confidence: .high
                    ),
                    into: &candidatesByID
                )
            }
        }

        return Array(candidatesByID.values)
            .sorted { lhs, rhs in
                if lhs.confidence != rhs.confidence {
                    return lhs.confidence.sortRank < rhs.confidence.sortRank
                }
                if lhs.reclaimableBytes == rhs.reclaimableBytes {
                    return lhs.item.name.localizedStandardCompare(rhs.item.name) == .orderedAscending
                }
                return lhs.reclaimableBytes > rhs.reclaimableBytes
            }
            .prefix(limit)
            .map { $0 }
    }

    private func emitProgressLocked(path: String, force: Bool = false, phase: ScanPhase = .enumerating) {
        let now = Date()
        guard force || scannedItemCount == 1 || now.timeIntervalSince(lastProgressDate) > 0.35 else {
            return
        }

        lastProgressDate = now
        // Snapshot fires before progress (not after): ScanStore's progress consumer reads
        // whatever the most recent onSnapshot call staged before it yields the paired
        // ScanTick. Firing progress first would pair each tick with the *previous* tick's
        // snapshot — a one-tick lag that leaves cancel-preserved partial results stale by
        // a full throttle interval.
        let shouldBuildSnapshot = force || scannedItemCount == 1 || now.timeIntervalSince(lastSnapshotDate) > 1.0
        if let onSnapshot, shouldBuildSnapshot {
            lastSnapshotDate = now
            snapshotBuildCount += 1
            onSnapshot(snapshotLocked())
        }
        progress?(ScanProgress(scannedItemCount: scannedItemCount, totalBytes: totalBytes, currentPath: path, phase: phase))
    }

    /// Builds a `StorageScan` from current in-progress state under the caller's held lock.
    /// Duplicate verification hasn't run yet mid-scan, so `verifiedDuplicateGroups` is
    /// always empty here. `rootItem`/`retainedItems` use a minimal placeholder root — list
    /// views driven by streaming snapshots read `largestFiles`/`largestFolders`/
    /// `oldLargeFiles`/counts, not the tree, so a full retained-tree rebuild mid-scan isn't
    /// warranted.
    private func snapshotLocked() -> StorageScan {
        let placeholderRoot = StorageItem(
            url: rootURL,
            kind: .folder,
            byteSize: totalBytes,
            allocatedSize: totalBytes,
            modifiedAt: nil,
            immediateChildCount: 0,
            descendantCount: scannedItemCount,
            isReadable: true
        )
        let snapshotLargestFiles: [StorageItem]
        let snapshotLargestFolders: [StorageItem]
        let snapshotOldLargeFiles: [StorageItem]
        if let summaryStore = fixedWorkerSummaryStore {
            snapshotLargestFiles = materializedFixedWorkerRankedItems(
                fixedWorkerLargestFileItems,
                summaryStore: summaryStore
            )
            snapshotLargestFolders = materializedFixedWorkerRankedItems(
                fixedWorkerLargestFolderItems,
                summaryStore: summaryStore
            )
            snapshotOldLargeFiles = materializedFixedWorkerRankedItems(
                fixedWorkerOldLargeFileItems,
                summaryStore: summaryStore
            )
        } else {
            snapshotLargestFiles = sortedRankedItems(
                largestFileItems,
                limit: options.maxRankedResults
            ) { $0.displaySize > $1.displaySize }
            snapshotLargestFolders = sortedRankedItems(
                largestFolderItems,
                limit: options.maxRankedResults
            ) { $0.displaySize > $1.displaySize }
            snapshotOldLargeFiles = sortedRankedItems(
                oldLargeFileItems,
                limit: options.maxRankedResults
            ) { $0.displaySize > $1.displaySize }
        }
        return StorageScan(
            rootURL: rootURL,
            startedAt: startedAt,
            finishedAt: Date(),
            rootItem: placeholderRoot,
            retainedItems: [],
            scannedItemCount: scannedItemCount,
            inaccessibleItemCount: inaccessibleItemCount,
            totalBytes: totalBytes,
            largestFiles: snapshotLargestFiles,
            largestFolders: snapshotLargestFolders,
            oldLargeFiles: snapshotOldLargeFiles,
            typeBreakdown: typeBreakdown,
            categoryBreakdown: categoryBreakdown,
            duplicateSizeGroups: [],
            verifiedDuplicateGroups: [],
            duplicateCandidateItemLimit: duplicateCandidateItemLimit,
            duplicateCandidateItemsRetained: duplicateCandidateItemsRetained,
            duplicateCandidateItemsConsidered: duplicateCandidateItemsConsidered,
            duplicateCandidateEvictionCount: duplicateCandidateEvictionCount,
            duplicateCandidateLimitReached: duplicateCandidateLimitReached,
            snapshotBuildCount: snapshotBuildCount,
            duplicateVerificationDuration: 0,
            enumerateDuration: Date().timeIntervalSince(startedAt),
            cleanupCandidates: [],
            isPartial: true
        )
    }

    /// Thread-safe public entry point for `snapshot()` — acquires the lock itself so
    /// callers outside the accumulator (e.g. tests) don't need to know about locking.
    func snapshot() -> StorageScan {
        lock.lock()
        defer { lock.unlock() }
        return snapshotLocked()
    }

    private func recordFileLocked(_ item: StorageItem) {
        largestFileItems.append(item)
        trimRankedItems(&largestFileItems, limit: options.maxRankedResults) { $0.displaySize > $1.displaySize }

        if let modifiedAt = item.modifiedAt,
           item.displaySize >= options.largeFileThreshold,
           modifiedAt <= oldFileCutoff {
            oldLargeFileItems.append(item)
            trimRankedItems(&oldLargeFileItems, limit: options.maxRankedResults) { $0.displaySize > $1.displaySize }
        }

        let typeLabel: String
        if let fileExtension = item.fileExtension, !fileExtension.isEmpty {
            typeLabel = ".\(fileExtension)"
        } else {
            typeLabel = "No Extension"
        }

        var typeStat = fileTypeStats[typeLabel] ?? FileTypeAccumulator()
        typeStat.category = FileTypeCategoryClassifier.category(forExtension: item.fileExtension)
        typeStat.fileCount += 1
        typeStat.totalBytes += item.displaySize
        fileTypeStats[typeLabel] = typeStat

        if item.byteSize >= options.duplicateCandidateThreshold {
            duplicateCandidateRetention.record(item)
        }
    }

    private func ruleBasedCleanupCandidate(for item: StorageItem) -> CleanupCandidate? {
        let lowercasedName = item.name.lowercased()
        let path = item.url.path.lowercased()
        let fileExtension = item.fileExtension ?? ""

        if item.kind == .folder || item.kind == .package {
            if ["cache", "caches", ".cache"].contains(lowercasedName) {
                return CleanupCandidate(
                    kind: .cacheFolder,
                    item: item,
                    reason: "Cache folder. Review before deleting if an app is currently using it.",
                    reclaimableBytes: item.displaySize,
                    confidence: .medium
                )
            }

            if ["deriveddata", "node_modules", ".build", "build", "dist", "target", ".gradle"].contains(lowercasedName) || path.contains("/deriveddata/") {
                return CleanupCandidate(
                    kind: .buildArtifact,
                    item: item,
                    reason: "Build or dependency artifact. Usually rebuildable, but project-specific.",
                    reclaimableBytes: item.displaySize,
                    confidence: .medium
                )
            }
        }

        guard item.kind == .file else {
            return nil
        }

        if ["dmg", "iso", "toast", "sparsebundle", "sparseimage"].contains(fileExtension) {
            return CleanupCandidate(
                kind: .diskImage,
                item: item,
                reason: "Disk image. Often disposable after installation or extraction.",
                reclaimableBytes: item.displaySize,
                confidence: .medium
            )
        }

        if ["pkg", "mpkg", "xip", "ipsw"].contains(fileExtension) {
            return CleanupCandidate(
                kind: .installer,
                item: item,
                reason: "Installer package. Usually removable after the install is complete.",
                reclaimableBytes: item.displaySize,
                confidence: .medium
            )
        }

        if ["zip", "zipx", "rar", "7z", "tar", "tgz", "gz", "bz", "bz2", "tbz", "tbz2", "xz", "txz", "zst", "tzst", "lz4"].contains(fileExtension) {
            return CleanupCandidate(
                kind: .archive,
                item: item,
                reason: "Archive file. Review whether the extracted copy already exists.",
                reclaimableBytes: item.displaySize,
                confidence: .review
            )
        }

        if ["tmp", "temp", "bak", "old"].contains(fileExtension) || lowercasedName.hasSuffix("~") {
            return CleanupCandidate(
                kind: .temporary,
                item: item,
                reason: "Temporary or backup-looking file.",
                reclaimableBytes: item.displaySize,
                confidence: .review
            )
        }

        if let modifiedAt = item.modifiedAt, item.displaySize >= 1_000_000_000, modifiedAt <= oldFileCutoff {
            return CleanupCandidate(
                kind: .oldLargeFile,
                item: item,
                reason: "Large file not modified recently.",
                reclaimableBytes: item.displaySize,
                confidence: .review
            )
        }

        return nil
    }

    private func fixedWorkerCleanupCandidate(
        for summary: FixedWorkerItemSummary,
        url: URL
    ) -> FixedWorkerCleanupCandidateReference? {
        let lowercasedName = summary.metadata.name.lowercased()
        let path = url.path.lowercased()
        let fileExtension = summary.fileExtension ?? ""

        if summary.kind == .folder || summary.kind == .package {
            if ["cache", "caches", ".cache"].contains(lowercasedName) {
                return FixedWorkerCleanupCandidateReference(
                    summary: summary,
                    url: url,
                    kind: .cacheFolder,
                    reason: "Cache folder. Review before deleting if an app is currently using it.",
                    reclaimableBytes: summary.displaySize,
                    confidence: .medium
                )
            }

            if ["deriveddata", "node_modules", ".build", "build", "dist", "target", ".gradle"].contains(lowercasedName) ||
                path.contains("/deriveddata/") {
                return FixedWorkerCleanupCandidateReference(
                    summary: summary,
                    url: url,
                    kind: .buildArtifact,
                    reason: "Build or dependency artifact. Usually rebuildable, but project-specific.",
                    reclaimableBytes: summary.displaySize,
                    confidence: .medium
                )
            }
        }

        guard summary.kind == .file else {
            return nil
        }

        if ["dmg", "iso", "toast", "sparsebundle", "sparseimage"].contains(fileExtension) {
            return FixedWorkerCleanupCandidateReference(
                summary: summary,
                url: url,
                kind: .diskImage,
                reason: "Disk image. Often disposable after installation or extraction.",
                reclaimableBytes: summary.displaySize,
                confidence: .medium
            )
        }

        if ["pkg", "mpkg", "xip", "ipsw"].contains(fileExtension) {
            return FixedWorkerCleanupCandidateReference(
                summary: summary,
                url: url,
                kind: .installer,
                reason: "Installer package. Usually removable after the install is complete.",
                reclaimableBytes: summary.displaySize,
                confidence: .medium
            )
        }

        if ["zip", "zipx", "rar", "7z", "tar", "tgz", "gz", "bz", "bz2", "tbz", "tbz2", "xz", "txz", "zst", "tzst", "lz4"].contains(fileExtension) {
            return FixedWorkerCleanupCandidateReference(
                summary: summary,
                url: url,
                kind: .archive,
                reason: "Archive file. Review whether the extracted copy already exists.",
                reclaimableBytes: summary.displaySize,
                confidence: .review
            )
        }

        if ["tmp", "temp", "bak", "old"].contains(fileExtension) || lowercasedName.hasSuffix("~") {
            return FixedWorkerCleanupCandidateReference(
                summary: summary,
                url: url,
                kind: .temporary,
                reason: "Temporary or backup-looking file.",
                reclaimableBytes: summary.displaySize,
                confidence: .review
            )
        }

        if let modifiedAt = summary.metadata.modifiedAt,
           summary.displaySize >= 1_000_000_000,
           modifiedAt <= oldFileCutoff {
            return FixedWorkerCleanupCandidateReference(
                summary: summary,
                url: url,
                kind: .oldLargeFile,
                reason: "Large file not modified recently.",
                reclaimableBytes: summary.displaySize,
                confidence: .review
            )
        }

        return nil
    }

    private func insertCandidateLocked(_ candidate: CleanupCandidate, into candidatesByID: inout [String: CleanupCandidate]) {
        if let existing = candidatesByID[candidate.item.id] {
            if candidate.confidence.sortRank < existing.confidence.sortRank ||
                candidate.reclaimableBytes > existing.reclaimableBytes {
                candidatesByID[candidate.item.id] = candidate
            }
        } else {
            candidatesByID[candidate.item.id] = candidate
        }
    }

    private func trimRankedItems(
        _ items: inout [StorageItem],
        limit: Int,
        by areInIncreasingPriorityOrder: (StorageItem, StorageItem) -> Bool
    ) {
        let boundedLimit = max(0, limit)
        guard boundedLimit > 0 else {
            items.removeAll(keepingCapacity: false)
            return
        }

        guard items.count > boundedLimit * 4 else {
            return
        }

        items = sortedRankedItems(items, limit: boundedLimit, by: areInIncreasingPriorityOrder)
    }

    private func sortedRankedItems(
        _ items: [StorageItem],
        limit: Int,
        by areInIncreasingPriorityOrder: (StorageItem, StorageItem) -> Bool
    ) -> [StorageItem] {
        Array(items.sorted { lhs, rhs in
            if areInIncreasingPriorityOrder(lhs, rhs) { return true }
            if areInIncreasingPriorityOrder(rhs, lhs) { return false }
            // Tie on the priority Comparator (equal displaySize). Fall back to URL path so
            // two equally-sized items land in a deterministic order regardless of the order
            // `DispatchQueue.concurrentPerform` appended them to largestFileItems. Without
            // this, `sorted(by:)` isn't guaranteed stable and two scans of the same fixture
            // produce different largestFiles orderings — caught by
            // `parallelEnumerationIsDeterministicAcrossRuns`.
            return lhs.url.path < rhs.url.path
        }.prefix(max(0, limit)))
    }
}

private enum FileTypeCategoryClassifier {
    static func category(forExtension fileExtension: String?) -> FileTypeStat.Category {
        guard let fileExtension, !fileExtension.isEmpty else {
            return .other
        }

        switch fileExtension {
        case "zip", "zipx", "rar", "7z", "tar", "tgz", "gz", "bz", "bz2", "tbz", "tbz2", "xz", "txz", "zst", "tzst", "lz4":
            return .archive
        case "aif", "aiff", "flac", "m4a", "mp3", "wav":
            return .audio
        case "db", "realm", "sqlite", "sqlite3":
            return .database
        case "app", "bundle", "framework", "h", "json", "m", "mm", "pbxproj", "plist", "sh", "swift", "xcarchive", "xcodeproj", "xcworkspace", "yml", "yaml":
            return .developer
        case "csv", "doc", "docx", "key", "md", "numbers", "pages", "pdf", "ppt", "pptx", "rtf", "txt", "xls", "xlsx":
            return .document
        case "otf", "ttc", "ttf", "woff", "woff2":
            return .font
        case "gif", "heic", "jpeg", "jpg", "png", "psd", "raw", "tif", "tiff", "webp":
            return .image
        case "dmg", "ipsw", "iso", "mpkg", "pkg", "sparsebundle", "sparseimage", "toast", "xip":
            return .installer
        case "avi", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "wmv":
            return .video
        case "qcow2", "vbox", "vdi", "vhd", "vhdx", "vmdk", "vmwarevm", "pvm":
            return .virtualMachine
        default:
            return .other
        }
    }
}

private let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

/// Lookup-table hex encoder for `SHA256Digest` (a `Sequence<UInt8>`). Replaces
/// `.map { String(format: "%02x", $0) }.joined()`, which builds 32 short-lived `NSString`s
/// per file hashed via the `%`-format parser — real overhead once P-2 lowers the duplicate
/// threshold and hashing runs across far more files than before.
private extension Sequence where Element == UInt8 {
    func hexEncodedString() -> String {
        var chars = [UInt8]()
        chars.reserveCapacity(underestimatedCount * 2)
        for byte in self {
            chars.append(hexDigits[Int(byte >> 4)])
            chars.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: chars, as: UTF8.self)
    }
}

private extension String {
    var nonEmptyLowercased: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }
}
