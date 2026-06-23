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
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
    }

    public func check() throws {
        lock.lock()
        defer { lock.unlock() }
        let shouldCancel = cancelled

        if shouldCancel {
            throw FileSystemScannerError.cancelled
        }
    }

    /// Non-throwing probe used inside `DispatchQueue.concurrentPerform`, which cannot propagate thrown errors.
    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
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

    /// os_signpost surface for Instruments. Subsystem mirrors the bundle identifier prefix;
    /// category ties Scanner-only work together so it can be filtered from app-side spans.
    private static let log = OSLog(subsystem: "com.rasputinkaiser.StorageScope", category: "scan")
    private static let signpostID = OSSignpostID(log: log)

    private let fileManager: FileManager
    private let hashCache: DuplicateHashCache?
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

    public init(fileManager: FileManager = .default, hashCache: DuplicateHashCache? = nil) {
        self.fileManager = fileManager
        self.hashCache = hashCache
    }

    public func scan(
        root rootURL: URL,
        options: ScanOptions = ScanOptions(),
        cancellation: ScanCancellation? = nil,
        progress: ProgressHandler? = nil
    ) throws -> StorageScan {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            throw FileSystemScannerError.rootDoesNotExist(rootURL)
        }

        os_signpost(.begin, log: Self.log, name: "scan", signpostID: Self.signpostID,
                    "root=%{public}@", rootURL.path)

        let startedAt = Date()
        let accumulator = ScanAccumulator(options: options, progress: progress)
        let rootItem = try scanItem(
            at: rootURL,
            options: options,
            cancellation: cancellation,
            accumulator: accumulator
        )
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
            duplicateCandidateLimitReached: accumulator.duplicateCandidateLimitReached,
            duplicateVerificationDuration: duplicateVerificationDuration,
            enumerateDuration: enumerateDuration,
            cleanupCandidates: accumulator.cleanupCandidates(
                rootID: rootItem.id,
                verifiedDuplicateGroups: verifiedDuplicateGroups,
                limit: options.maxRankedResults
            )
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

        var hashedItems: [HashedStorageItem] = []
        hashedItems.reserveCapacity(group.items.count)

        for item in group.items {
            // Cooperative cancellation: re-check before opening I/O for the next file so a
            // cancelled scan doesn't keep burning file descriptors or queuing reads behind
            // the ioSemaphore. Cancellation aborts the whole on-demand verify because the
            // caller asked us to stop.
            try cancellation?.check()

            if let hashed = try hashedFormItem(
                item,
                ioSemaphore: ioSemaphore,
                cacheLock: cacheLock,
                cancellation: cancellation
            ) {
                hashedItems.append(hashed)
            }
        }

        let groupedByHash = Dictionary(grouping: hashedItems, by: \.checksum)
        return groupedByHash.compactMap { checksum, hashedItems in
            let items = hashedItems.map(\.item).sorted { $0.url.path < $1.url.path }
            return items.count > 1 ? VerifiedDuplicateGroup(checksum: checksum, byteSize: group.byteSize, items: items) : nil
        }.sorted { lhs, rhs in
            if lhs.reclaimableBytes == rhs.reclaimableBytes {
                return lhs.byteSize > rhs.byteSize
            }
            return lhs.reclaimableBytes > rhs.reclaimableBytes
        }
    }

    private func scanItem(
        at url: URL,
        options: ScanOptions,
        cancellation: ScanCancellation?,
        accumulator: ScanAccumulator
    ) throws -> StorageItem {
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

        accumulator.recordVisit(path: url.path)

        if values?.isSymbolicLink == true {
            let size = Int64(values?.fileSize ?? 0)
            accumulator.recordBytes(size)
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
            accumulator.recordItem(item)
            return item
        }

        let isDirectory = values?.isDirectory == true
        let isPackage = values?.isPackage == true

        guard isDirectory else {
            let logicalSize = Int64(values?.fileSize ?? 0)
            let allocatedSize = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? values?.fileSize ?? 0)
            accumulator.recordBytes(max(logicalSize, allocatedSize))

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
            accumulator.recordItem(item)
            return item
        }

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
                    try cancellation?.check()
                    let child = try scanItem(
                        at: childURLs[index],
                        options: options,
                        cancellation: cancellation,
                        accumulator: accumulator
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

            let retainedChildren = accumulator.retainedChildren(from: summary.retainedCandidates)

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

                var hashedItems: [HashedStorageItem] = []
                hashedItems.reserveCapacity(sizeGroup.items.count)

                for item in sizeGroup.items {
                    // Per-item cancellation probe keeps an outlier slow hash from orphaning
                    // the rest of a group's work after the user cancels.
                    if cancellation?.isCancelled ?? false {
                        markCancelled()
                        return
                    }

                    if let hashed = try hashedFormItem(
                        item,
                        ioSemaphore: ioSemaphore,
                        cacheLock: cacheLock,
                        cancellation: cancellation
                    ) {
                        hashedItems.append(hashed)
                    }
                }

                let groupedByHash = Dictionary(grouping: hashedItems, by: \.checksum)
                let verifiedForSize = groupedByHash.compactMap { checksum, hashedItems -> VerifiedDuplicateGroup? in
                    let items = hashedItems.map(\.item).sorted { $0.url.path < $1.url.path }
                    return items.count > 1 ? VerifiedDuplicateGroup(checksum: checksum, byteSize: sizeGroup.byteSize, items: items) : nil
                }

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

    private func sha256Checksum(for url: URL, cancellation: ScanCancellation?) throws -> String {
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
            hasher.update(data: data)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
        cancellation: ScanCancellation?
    ) throws -> HashedStorageItem? {
        let cacheKey = DuplicateHashCache.LookupKey(item: item)

        if let cached = hashCache?.checksum(for: cacheKey) {
            return HashedStorageItem(checksum: cached, item: item)
        }

        ioSemaphore.wait()
        defer { ioSemaphore.signal() }

        do {
            let checksum = try sha256Checksum(for: item.url, cancellation: cancellation)
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

private struct HashedStorageItem {
    let checksum: String
    let item: StorageItem
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
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return lhs.displaySize > rhs.displaySize
            }
            .prefix(retainedCandidateLimit)
        )
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
    private var lastProgressDate = Date.distantPast
    private let oldFileCutoff: Date
    private var retainedItemCount: Int
    private var largestFileItems: [StorageItem] = []
    private var largestFolderItems: [StorageItem] = []
    private var oldLargeFileItems: [StorageItem] = []
    private var fileTypeStats: [String: FileTypeAccumulator] = [:]
    private var duplicateCandidatesBySize: [Int64: [StorageItem]] = [:]
    private var duplicateCandidateItemCount = 0
    private var duplicateCandidateConsideredCount = 0
    private var smallestDuplicateCandidateByteSize: Int64?
    private(set) var duplicateCandidateLimitReached = false
    private var cleanupCandidatesByID: [String: CleanupCandidate] = [:]

    var scannedItemCount = 0
    var inaccessibleItemCount = 0
    var totalBytes: Int64 = 0

    /// Guards every mutable field above. Held briefly during directory enumeration's
    /// record*() calls; the user `progress` closure is invoked under this lock, so it must
    /// not re-enter the accumulator. Contention is bounded because the scan's bottleneck is
    /// `contentsOfDirectory`+`resourceValues` I/O outside the lock.
    private let lock = NSLock()

    init(options: ScanOptions, progress: FileSystemScanner.ProgressHandler?) {
        self.options = options
        self.progress = progress
        self.retainedItemCount = 1
        self.oldFileCutoff = Calendar.current.date(
            byAdding: .day,
            value: -options.oldFileAgeDays,
            to: Date()
        ) ?? Date()
    }

    func recordVisit(path: String) {
        lock.lock()
        defer { lock.unlock() }
        scannedItemCount += 1
        emitProgressLocked(path: path)
    }

    func recordBytes(_ bytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        totalBytes += bytes
    }

    func recordInaccessible(path: String) {
        lock.lock()
        defer { lock.unlock() }
        inaccessibleItemCount += 1
        emitProgressLocked(path: path)
    }

    func recordPhase(path: String, phase: ScanPhase = .enumerating) {
        lock.lock()
        defer { lock.unlock() }
        emitProgressLocked(path: path, force: true, phase: phase)
    }

    func recordItem(_ item: StorageItem) {
        lock.lock()
        defer { lock.unlock() }
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

    func retainedChildren(from children: [StorageItem]) -> [StorageItem] {
        lock.lock()
        defer { lock.unlock() }
        let perDirectoryLimit = max(0, options.maxChildrenPerDirectory)
        let retainedLimit = max(1, options.maxRetainedItems)
        guard perDirectoryLimit > 0, retainedItemCount < retainedLimit else {
            return []
        }

        var retained: [StorageItem] = []
        retained.reserveCapacity(min(children.count, perDirectoryLimit))

        for child in children.prefix(perDirectoryLimit) {
            guard retainedItemCount < retainedLimit else {
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

    var largestFiles: [StorageItem] {
        sortedRankedItems(largestFileItems, limit: options.maxRankedResults) { $0.displaySize > $1.displaySize }
    }

    func largestFolders(excluding rootID: String) -> [StorageItem] {
        sortedRankedItems(largestFolderItems.filter { $0.id != rootID }, limit: options.maxRankedResults) {
            $0.displaySize > $1.displaySize
        }
    }

    var oldLargeFiles: [StorageItem] {
        sortedRankedItems(oldLargeFileItems, limit: options.maxRankedResults) { $0.displaySize > $1.displaySize }
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
        duplicateCandidatesBySize
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

    var duplicateCandidateItemLimit: Int {
        max(0, options.maxDuplicateCandidateItems)
    }

    var duplicateCandidateItemsRetained: Int {
        duplicateCandidateItemCount
    }

    var duplicateCandidateItemsConsidered: Int {
        duplicateCandidateConsideredCount
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
        var candidatesByID = cleanupCandidatesByID.filter { id, _ in
            id != rootID && !duplicateItemIDs.contains(id)
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
        guard let progress else {
            return
        }

        let now = Date()
        guard force || scannedItemCount == 1 || scannedItemCount.isMultiple(of: 25) || now.timeIntervalSince(lastProgressDate) > 0.35 else {
            return
        }

        lastProgressDate = now
        progress(ScanProgress(scannedItemCount: scannedItemCount, totalBytes: totalBytes, currentPath: path, phase: phase))
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
            recordDuplicateCandidateLocked(item)
        }
    }

    private func recordDuplicateCandidateLocked(_ item: StorageItem) {
        duplicateCandidateConsideredCount += 1
        let candidateLimit = max(0, options.maxDuplicateCandidateItems)
        guard candidateLimit > 0 else {
            duplicateCandidateLimitReached = true
            return
        }

        if duplicateCandidateItemCount >= candidateLimit,
           let smallestDuplicateCandidateByteSize,
           item.byteSize < smallestDuplicateCandidateByteSize {
            duplicateCandidateLimitReached = true
            return
        }

        duplicateCandidatesBySize[item.byteSize, default: []].append(item)
        duplicateCandidateItemCount += 1
        if smallestDuplicateCandidateByteSize.map({ item.byteSize < $0 }) ?? true {
            smallestDuplicateCandidateByteSize = item.byteSize
        }

        guard duplicateCandidateItemCount > candidateLimit else {
            return
        }

        duplicateCandidateLimitReached = true
        removeSmallestDuplicateCandidateLocked()
    }

    private func removeSmallestDuplicateCandidateLocked() {
        guard let smallestByteSize = smallestDuplicateCandidateByteSize ?? duplicateCandidatesBySize.keys.min(),
              var items = duplicateCandidatesBySize[smallestByteSize],
              !items.isEmpty else {
            smallestDuplicateCandidateByteSize = duplicateCandidatesBySize.keys.min()
            return
        }

        let removalIndex = items.indices.max { lhs, rhs in
            items[lhs].url.path.localizedStandardCompare(items[rhs].url.path) == .orderedAscending
        } ?? items.startIndex
        items.remove(at: removalIndex)
        duplicateCandidateItemCount -= 1

        if items.isEmpty {
            duplicateCandidatesBySize.removeValue(forKey: smallestByteSize)
            smallestDuplicateCandidateByteSize = duplicateCandidatesBySize.keys.min()
        } else {
            duplicateCandidatesBySize[smallestByteSize] = items
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
        Array(items.sorted(by: areInIncreasingPriorityOrder).prefix(max(0, limit)))
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

private extension String {
    var nonEmptyLowercased: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }
}
