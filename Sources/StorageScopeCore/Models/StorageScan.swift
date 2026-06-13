import Foundation

public struct StorageScan: Sendable {
    public let rootURL: URL
    public let startedAt: Date
    public let finishedAt: Date
    public let rootItem: StorageItem
    public let allItems: [StorageItem]
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
    public let duplicateCandidateLimitReached: Bool
    public let cleanupCandidates: [CleanupCandidate]

    public init(
        rootURL: URL,
        startedAt: Date,
        finishedAt: Date,
        rootItem: StorageItem,
        allItems: [StorageItem],
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
        duplicateCandidateLimitReached: Bool = false,
        cleanupCandidates: [CleanupCandidate]
    ) {
        self.rootURL = rootURL
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.rootItem = rootItem
        self.allItems = allItems
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
        self.duplicateCandidateLimitReached = duplicateCandidateLimitReached
        self.cleanupCandidates = cleanupCandidates
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

    public init(kind: Kind, item: StorageItem, reason: String, reclaimableBytes: Int64, confidence: Confidence) {
        self.kind = kind
        self.item = item
        self.reason = reason
        self.reclaimableBytes = reclaimableBytes
        self.confidence = confidence
        self.id = "\(kind.rawValue)-\(item.id)"
    }
}

public struct ScanProgress: Sendable {
    public let scannedItemCount: Int
    public let totalBytes: Int64
    public let currentPath: String

    public init(scannedItemCount: Int, totalBytes: Int64, currentPath: String) {
        self.scannedItemCount = scannedItemCount
        self.totalBytes = totalBytes
        self.currentPath = currentPath
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
        maxRetainedItems: Int = 25_000
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
    }
}
