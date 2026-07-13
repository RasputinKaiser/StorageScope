import Foundation
import os.signpost

public struct StorageScan: Sendable {
    public enum RescanKind: String, Sendable {
        case full
        case incrementalUnchanged
        case incrementalChanged
    }

    /// os_signpost surface for Instruments. Shares the scan subsystem/category so the
    /// `lookup_build` span shows up alongside FileSystemScanner and ScanStore spans (#81-pattern).
    private static let log = OSLog(subsystem: "com.rasputinkaiser.StorageScope", category: "scan")
    private static let signpostID = OSSignpostID(log: log)

    public let rootURL: URL
    public let startedAt: Date
    public let finishedAt: Date
    public let rootItem: StorageItem
    public let retainedItems: [StorageItem]
    public let scannedItemCount: Int
    public let inaccessibleItemCount: Int
    public let totalBytes: Int64
    public let largestFiles: [StorageItem]
    public let largestFolders: [StorageItem]
    public let oldLargeFiles: [StorageItem]
    public let typeBreakdown: [FileTypeStat]
    public let categoryBreakdown: [FileCategoryStat]
    public let duplicateSizeGroups: [DuplicateSizeGroup]
    public let verifiedDuplicateGroups: [VerifiedDuplicateGroup]
    public let duplicateCandidateItemLimit: Int
    public let duplicateCandidateItemsRetained: Int
    public let duplicateCandidateItemsConsidered: Int
    public let duplicateCandidateEvictionCount: Int
    public let duplicateCandidateLimitReached: Bool
    public let snapshotBuildCount: Int
    public let duplicateVerificationDuration: TimeInterval
    public let duplicateVerificationBytesRead: Int64
    public let duplicateVerificationPeakOpenFiles: Int
    public let enumerateDuration: TimeInterval
    public let cleanupCandidates: [CleanupCandidate]
    public let isPartial: Bool
    public let rescanKind: RescanKind
    public let incrementalDirtySubtreeCount: Int
    public let incrementalFallbackReason: String?
    private let itemLookupByID: [String: StorageItem]

    public init(
        rootURL: URL,
        startedAt: Date,
        finishedAt: Date,
        rootItem: StorageItem,
        retainedItems: [StorageItem],
        scannedItemCount: Int,
        inaccessibleItemCount: Int,
        totalBytes: Int64,
        largestFiles: [StorageItem],
        largestFolders: [StorageItem],
        oldLargeFiles: [StorageItem],
        typeBreakdown: [FileTypeStat],
        categoryBreakdown: [FileCategoryStat] = [],
        duplicateSizeGroups: [DuplicateSizeGroup],
        verifiedDuplicateGroups: [VerifiedDuplicateGroup],
        duplicateCandidateItemLimit: Int = 0,
        duplicateCandidateItemsRetained: Int = 0,
        duplicateCandidateItemsConsidered: Int = 0,
        duplicateCandidateEvictionCount: Int = 0,
        duplicateCandidateLimitReached: Bool = false,
        snapshotBuildCount: Int = 0,
        duplicateVerificationDuration: TimeInterval = 0,
        duplicateVerificationBytesRead: Int64 = 0,
        duplicateVerificationPeakOpenFiles: Int = 0,
        enumerateDuration: TimeInterval = 0,
        cleanupCandidates: [CleanupCandidate],
        isPartial: Bool = false,
        rescanKind: RescanKind = .full,
        incrementalDirtySubtreeCount: Int = 0,
        incrementalFallbackReason: String? = nil
    ) {
        self.rootURL = rootURL
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.rootItem = rootItem
        self.retainedItems = retainedItems
        self.scannedItemCount = scannedItemCount
        self.inaccessibleItemCount = inaccessibleItemCount
        self.totalBytes = totalBytes
        self.largestFiles = largestFiles
        self.largestFolders = largestFolders
        self.oldLargeFiles = oldLargeFiles
        self.typeBreakdown = typeBreakdown
        self.categoryBreakdown = categoryBreakdown
        self.duplicateSizeGroups = duplicateSizeGroups
        self.verifiedDuplicateGroups = verifiedDuplicateGroups
        self.duplicateCandidateItemLimit = duplicateCandidateItemLimit
        self.duplicateCandidateItemsRetained = duplicateCandidateItemsRetained
        self.duplicateCandidateItemsConsidered = duplicateCandidateItemsConsidered
        self.duplicateCandidateEvictionCount = duplicateCandidateEvictionCount
        self.duplicateCandidateLimitReached = duplicateCandidateLimitReached
        self.snapshotBuildCount = snapshotBuildCount
        self.duplicateVerificationDuration = duplicateVerificationDuration
        self.duplicateVerificationBytesRead = duplicateVerificationBytesRead
        self.duplicateVerificationPeakOpenFiles = duplicateVerificationPeakOpenFiles
        self.enumerateDuration = enumerateDuration
        self.cleanupCandidates = cleanupCandidates
        self.isPartial = isPartial
        self.rescanKind = rescanKind
        self.incrementalDirtySubtreeCount = incrementalDirtySubtreeCount
        self.incrementalFallbackReason = incrementalFallbackReason
        self.itemLookupByID = Self.buildItemLookup(
            retainedItems: retainedItems,
            largestFiles: largestFiles,
            largestFolders: largestFolders,
            oldLargeFiles: oldLargeFiles,
            duplicateSizeGroups: duplicateSizeGroups,
            verifiedDuplicateGroups: verifiedDuplicateGroups,
            cleanupCandidates: cleanupCandidates
        )
    }

    public func lookupItem(id: String) -> StorageItem? {
        itemLookupByID[id]
    }

    func reusedIncrementally(startedAt: Date, finishedAt: Date) -> StorageScan {
        StorageScan(
            rootURL: rootURL,
            startedAt: startedAt,
            finishedAt: finishedAt,
            rootItem: rootItem,
            retainedItems: retainedItems,
            scannedItemCount: scannedItemCount,
            inaccessibleItemCount: inaccessibleItemCount,
            totalBytes: totalBytes,
            largestFiles: largestFiles,
            largestFolders: largestFolders,
            oldLargeFiles: oldLargeFiles,
            typeBreakdown: typeBreakdown,
            categoryBreakdown: categoryBreakdown,
            duplicateSizeGroups: duplicateSizeGroups,
            verifiedDuplicateGroups: verifiedDuplicateGroups,
            duplicateCandidateItemLimit: duplicateCandidateItemLimit,
            duplicateCandidateItemsRetained: duplicateCandidateItemsRetained,
            duplicateCandidateItemsConsidered: duplicateCandidateItemsConsidered,
            duplicateCandidateEvictionCount: duplicateCandidateEvictionCount,
            duplicateCandidateLimitReached: duplicateCandidateLimitReached,
            snapshotBuildCount: 0,
            duplicateVerificationDuration: 0,
            duplicateVerificationBytesRead: 0,
            duplicateVerificationPeakOpenFiles: 0,
            enumerateDuration: finishedAt.timeIntervalSince(startedAt),
            cleanupCandidates: cleanupCandidates,
            isPartial: false,
            rescanKind: .incrementalUnchanged,
            incrementalDirtySubtreeCount: 0,
            incrementalFallbackReason: nil
        )
    }

    private static func buildItemLookup(
        retainedItems: [StorageItem],
        largestFiles: [StorageItem],
        largestFolders: [StorageItem],
        oldLargeFiles: [StorageItem],
        duplicateSizeGroups: [DuplicateSizeGroup],
        verifiedDuplicateGroups: [VerifiedDuplicateGroup],
        cleanupCandidates: [CleanupCandidate]
    ) -> [String: StorageItem] {
        os_signpost(.begin, log: Self.log, name: "lookup_build", signpostID: Self.signpostID,
                    "retained=%d largestFiles=%d largestFolders=%d old=%d dupGroups=%d verified=%d cleanup=%d",
                    retainedItems.count, largestFiles.count, largestFolders.count, oldLargeFiles.count,
                    duplicateSizeGroups.count, verifiedDuplicateGroups.count, cleanupCandidates.count)
        defer {
            os_signpost(.end, log: Self.log, name: "lookup_build", signpostID: Self.signpostID)
        }

        var lookup: [String: StorageItem] = [:]

        func insert(_ item: StorageItem) {
            lookup[item.id] = item
        }

        retainedItems.forEach(insert)
        largestFiles.forEach(insert)
        largestFolders.forEach(insert)
        oldLargeFiles.forEach(insert)
        duplicateSizeGroups.flatMap(\.items).forEach(insert)
        verifiedDuplicateGroups.flatMap(\.items).forEach(insert)
        cleanupCandidates.map(\.item).forEach(insert)

        return lookup
    }
}

public struct FileTypeStat: Identifiable, Hashable, Sendable {
    public enum Category: String, Hashable, Sendable {
        case archive = "Archives"
        case audio = "Audio"
        case developer = "Developer"
        case document = "Documents"
        case database = "Databases"
        case font = "Fonts"
        case image = "Images"
        case installer = "Installers"
        case video = "Video"
        case virtualMachine = "Virtual Machines"
        case other = "Other"
    }

    public let id: String
    public let label: String
    public let category: Category
    public let fileCount: Int
    public let totalBytes: Int64

    public init(label: String, category: Category = .other, fileCount: Int, totalBytes: Int64) {
        self.id = label
        self.label = label
        self.category = category
        self.fileCount = fileCount
        self.totalBytes = totalBytes
    }

    public var fileCountLabel: String {
        "\(fileCount.formatted()) \(fileCount == 1 ? "file" : "files")"
    }
}

public struct FileCategoryStat: Identifiable, Hashable, Sendable {
    public let id: FileTypeStat.Category
    public let category: FileTypeStat.Category
    public let fileCount: Int
    public let extensionCount: Int
    public let totalBytes: Int64

    public init(category: FileTypeStat.Category, fileCount: Int, extensionCount: Int, totalBytes: Int64) {
        self.id = category
        self.category = category
        self.fileCount = fileCount
        self.extensionCount = extensionCount
        self.totalBytes = totalBytes
    }

    public var extensionCountLabel: String {
        "\(extensionCount.formatted()) \(extensionCount == 1 ? "type" : "types")"
    }

    public var fileCountLabel: String {
        "\(fileCount.formatted()) \(fileCount == 1 ? "file" : "files")"
    }
}

public struct DuplicateSizeGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let byteSize: Int64
    public let items: [StorageItem]

    public init(byteSize: Int64, items: [StorageItem]) {
        self.id = "\(byteSize)-\(items.map(\.id).joined(separator: "|"))"
        self.byteSize = byteSize
        self.items = items
    }

    public var count: Int {
        items.count
    }

    public var totalBytes: Int64 {
        byteSize * Int64(items.count)
    }

    public var reclaimableBytes: Int64 {
        max(0, byteSize * Int64(items.count - 1))
    }
}

public struct VerifiedDuplicateGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let checksum: String
    public let byteSize: Int64
    public let items: [StorageItem]

    public init(checksum: String, byteSize: Int64, items: [StorageItem]) {
        self.id = "\(byteSize)-\(checksum)"
        self.checksum = checksum
        self.byteSize = byteSize
        self.items = items
    }

    public var count: Int {
        items.count
    }

    public var totalBytes: Int64 {
        byteSize * Int64(items.count)
    }

    public var reclaimableBytes: Int64 {
        max(0, byteSize * Int64(items.count - 1))
    }
}

public struct CleanupCandidate: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case verifiedDuplicate
        case oldLargeFile
        case archive
        case installer
        case diskImage
        case cacheFolder
        case buildArtifact
        case temporary
        case general
    }

    public enum Confidence: String, Hashable, Sendable {
        case high
        case medium
        case review
    }

    public let id: String
    public let kind: Kind
    public let item: StorageItem
    public let reason: String
    public let reclaimableBytes: Int64
    public let confidence: Confidence

    public struct TrustDetails: Hashable, Sendable {
        public let flaggedReason: String
        public let confidenceLabel: String
        public let couldBreak: String
        public let safetyNote: String
        public let suggestedAction: String
    }

    public init(kind: Kind, item: StorageItem, reason: String, reclaimableBytes: Int64, confidence: Confidence) {
        self.kind = kind
        self.item = item
        self.reason = reason
        self.reclaimableBytes = reclaimableBytes
        self.confidence = confidence
        self.id = "\(kind.rawValue)-\(item.id)"
    }

    public var isHighConfidenceVerifiedDuplicate: Bool {
        kind == .verifiedDuplicate && confidence == .high
    }

    public var trustDetails: TrustDetails {
        TrustDetails(
            flaggedReason: reason,
            confidenceLabel: confidence.trustDisplayName,
            couldBreak: kind.removalRisk,
            safetyNote: kind.safetyNote,
            suggestedAction: kind.suggestedAction
        )
    }
}

private extension CleanupCandidate.Confidence {
    var trustDisplayName: String {
        switch self {
        case .high:
            return "Verified"
        case .medium:
            return "Review"
        case .review:
            return "Manual"
        }
    }
}

private extension CleanupCandidate.Kind {
    var removalRisk: String {
        switch self {
        case .verifiedDuplicate:
            return "Removing every copy would lose the file. Keep one known-good copy before moving duplicate copies to Trash."
        case .oldLargeFile:
            return "The file may still be the only copy of old work, media, exports, or records."
        case .archive:
            return "The archive may be the only compressed backup, source drop, or portable copy."
        case .installer:
            return "You may need to download the installer again to reinstall or repair the app."
        case .diskImage:
            return "The disk image may contain an app, installer, license file, or mounted content you still need."
        case .cacheFolder:
            return "An app may be using the cache right now, and removing it can force re-downloads or temporary glitches."
        case .buildArtifact:
            return "A project may rely on generated output until the next clean build, and deleting it can slow or break local work."
        case .temporary:
            return "Temporary-looking files can still be active work, crash recovery data, or app handoff state."
        case .general:
            return "Removing this item may affect files or apps that depend on it. StorageScope has no specific safety signal for it."
        }
    }

    var safetyNote: String {
        switch self {
        case .verifiedDuplicate:
            return "StorageScope matched file contents with SHA-256 and treats one copy as the keeper. This is the safest cleanup lane, but review the path before deleting."
        case .oldLargeFile:
            return "Age and size make this worth reviewing, but StorageScope cannot know whether the content is still valuable."
        case .archive:
            return "Archives are worth reviewing after extraction or backup, but only remove one when another usable copy exists."
        case .installer:
            return "Installers are usually disposable after installation when the app and license are already preserved."
        case .diskImage:
            return "Disk images are often disposable after installation or extraction, but only after checking mounted contents and app provenance."
        case .cacheFolder:
            return "Caches are usually rebuildable. Quit the owning app first when possible and expect the cache to be recreated."
        case .buildArtifact:
            return "Build artifacts are usually rebuildable from source, but generated or vendored outputs deserve a quick project check."
        case .temporary:
            return "Only remove this after confirming no app or workflow is still writing to it."
        case .general:
            return "StorageScope flagged this from a manual selection, not from cleanup rules. Reveal and inspect before moving it to Trash."
        }
    }

    var suggestedAction: String {
        switch self {
        case .verifiedDuplicate:
            return "Keep one copy, reveal the selected path, then move only duplicate copies to Trash."
        case .oldLargeFile, .archive:
            return "Reveal and review before deciding whether to keep or move to Trash."
        case .installer, .diskImage:
            return "Reveal, confirm the app or contents are already installed or preserved, then move to Trash."
        case .cacheFolder:
            return "Quit the owning app, reveal the folder, then move to Trash only if the cache is not needed."
        case .buildArtifact:
            return "Confirm the project can rebuild it, then move to Trash."
        case .temporary:
            return "Reveal first; keep it if any app or recent workflow still depends on it."
        case .general:
            return "Reveal in Finder, confirm no app or workflow depends on it, then move to Trash."
        }
    }
}

public enum ScanPhase: String, Sendable {
    case enumerating
    case verifyingDuplicates
}

public struct ScanProgress: Sendable {
    public let scannedItemCount: Int
    public let totalBytes: Int64
    public let currentPath: String
    public let phase: ScanPhase
    public let itemsPerSecond: Double

    public init(
        scannedItemCount: Int,
        totalBytes: Int64,
        currentPath: String,
        phase: ScanPhase = .enumerating,
        itemsPerSecond: Double = 0
    ) {
        self.scannedItemCount = scannedItemCount
        self.totalBytes = totalBytes
        self.currentPath = currentPath
        self.phase = phase
        self.itemsPerSecond = itemsPerSecond
    }
}

public struct ScanOptions: Sendable {
    public var includeHidden: Bool
    public var oldFileAgeDays: Int
    public var largeFileThreshold: Int64
    public var duplicateCandidateThreshold: Int64
    public var duplicateVerificationByteLimit: Int64
    public var maxDuplicateVerificationFiles: Int
    public var maxDuplicateCandidateItems: Int
    public var maxRankedResults: Int
    public var maxChildrenPerDirectory: Int
    public var maxRetainedItems: Int
    public var excludeEnabled: Bool
    public var excludedPathComponents: [String]
    public var excludedAbsolutePrefixes: [String]

    public init(
        includeHidden: Bool = false,
        oldFileAgeDays: Int = 180,
        largeFileThreshold: Int64 = 1_000_000_000,
        duplicateCandidateThreshold: Int64 = 100_000_000,
        duplicateVerificationByteLimit: Int64 = 20_000_000_000,
        maxDuplicateVerificationFiles: Int = 1_000,
        maxDuplicateCandidateItems: Int = 5_000,
        maxRankedResults: Int = 500,
        maxChildrenPerDirectory: Int = 200,
        maxRetainedItems: Int = 25_000,
        excludeEnabled: Bool = false,
        excludedPathComponents: [String] = [],
        excludedAbsolutePrefixes: [String] = []
    ) {
        self.includeHidden = includeHidden
        self.oldFileAgeDays = oldFileAgeDays
        self.largeFileThreshold = largeFileThreshold
        self.duplicateCandidateThreshold = duplicateCandidateThreshold
        self.duplicateVerificationByteLimit = duplicateVerificationByteLimit
        self.maxDuplicateVerificationFiles = maxDuplicateVerificationFiles
        self.maxDuplicateCandidateItems = maxDuplicateCandidateItems
        self.maxRankedResults = maxRankedResults
        self.maxChildrenPerDirectory = maxChildrenPerDirectory
        self.maxRetainedItems = maxRetainedItems
        self.excludeEnabled = excludeEnabled
        self.excludedPathComponents = excludedPathComponents
        self.excludedAbsolutePrefixes = excludedAbsolutePrefixes
    }
}
