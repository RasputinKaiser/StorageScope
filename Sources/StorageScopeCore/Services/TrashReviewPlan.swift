import Foundation
import Darwin

public struct TrashReviewPlan: Identifiable, Equatable, Sendable {
    public struct Item: Identifiable, Equatable, Sendable {
        public let id: String
        public let storageItemID: String
        public let url: URL
        public let kind: CleanupCandidate.Kind
        public let confidence: CleanupCandidate.Confidence
        public let reclaimableBytes: Int64
        public let reason: String
        public let isDirectory: Bool
        private let reviewedIdentity: ReviewIdentity?
        private let matchedScan: Bool

        public init(candidate: CleanupCandidate) {
            id = candidate.id
            storageItemID = candidate.item.id
            url = candidate.item.url
            kind = candidate.kind
            confidence = candidate.confidence
            reclaimableBytes = candidate.reclaimableBytes
            reason = candidate.reason
            isDirectory = candidate.item.isContainer
            reviewedIdentity = ReviewIdentity.read(candidate.item.url)
            if candidate.item.kind == .file {
                matchedScan = reviewedIdentity?.matches(candidate.item) == true
            } else {
                matchedScan = reviewedIdentity != nil
            }
        }

        fileprivate func validateUnchanged() throws {
            guard matchedScan, let reviewedIdentity,
                  ReviewIdentity.read(url) == reviewedIdentity else {
                throw BatchTrashError.changedTargets([url])
            }
        }

        public var isVerified: Bool {
            kind == .verifiedDuplicate && confidence == .high
        }
    }

    public let items: [Item]
    public let id: String
    public let missingPaths: [URL]
    private let itemIndexByPath: [String: Int]

    public init(candidates: [CleanupCandidate]) {
        let kept = CleanupSelectionPlanner.topLevelCandidates(candidates)
        items = kept.map(Item.init(candidate:))
        itemIndexByPath = Dictionary(items.enumerated().map { ($0.element.url.standardizedFileURL.path, $0.offset) }, uniquingKeysWith: { first, _ in first })
        id = items.map(\.id).joined(separator: "|")
        missingPaths = []
    }

    /// Constructs a trash review plan and reports any candidate whose URL no
    /// longer exists on disk. Missing candidates are excluded from `items` —
    /// they cannot be moved to Trash — and surfaced through `missingPaths` so
    /// the caller can ask the user to rescan before retrying.
    public init(
        candidates: [CleanupCandidate],
        fileExists: @escaping (URL) -> Bool
    ) {
        let selection = CleanupSelectionPlanner.selectTopLevel(candidates, fileExists: fileExists)
        items = selection.candidates.map(Item.init(candidate:))
        itemIndexByPath = Dictionary(items.enumerated().map { ($0.element.url.standardizedFileURL.path, $0.offset) }, uniquingKeysWith: { first, _ in first })
        id = items.map(\.id).joined(separator: "|")
        missingPaths = selection.missingPaths
    }

    private init(items: [Item], missingPaths: [URL]) {
        self.items = items
        self.itemIndexByPath = Dictionary(items.enumerated().map { ($0.element.url.standardizedFileURL.path, $0.offset) }, uniquingKeysWith: { first, _ in first })
        self.id = items.map(\.id).joined(separator: "|")
        self.missingPaths = missingPaths
    }

    /// Remove only from the reviewed batch, independently of current filters or selection.
    public func removingItems(withIDs ids: Set<String>) -> TrashReviewPlan {
        TrashReviewPlan(items: items.filter { !ids.contains($0.id) }, missingPaths: missingPaths)
    }

    public func protectingKeepers(withIDs keeperIDs: Set<String>) -> TrashReviewPlan {
        let kept = items.filter { item in
            if keeperIDs.contains(item.storageItemID) { return false }
            guard item.isDirectory else { return true }
            let path = item.url.standardizedFileURL.path
            let prefix = path == "/" ? path : path + "/"
            return !keeperIDs.contains(where: { $0.hasPrefix(prefix) })
        }
        return TrashReviewPlan(items: kept, missingPaths: missingPaths)
    }

    public func validateUnchanged(_ url: URL) throws {
        guard let index = itemIndexByPath[url.standardizedFileURL.path] else {
            throw BatchTrashError.changedTargets([url])
        }
        try items[index].validateUnchanged()
    }

    @discardableResult
    public func validateVerifiedCopies(
        in groups: [VerifiedDuplicateGroup], keeping keeperIDs: Set<String>, scanner: FileSystemScanner
    ) throws -> KeeperValidation {
        let selected = Set(verifiedItems.map(\.storageItemID))
        guard !selected.isEmpty else { return KeeperValidation(keepersByCopyPath: [:]) }
        var validated: Set<String> = []
        var keepersByCopyPath: [String: (url: URL, identity: ReviewIdentity)] = [:]
        for group in groups {
            let copies = group.items.filter { selected.contains($0.id) }
            guard !copies.isEmpty else { continue }
            guard let keeper = group.items.first(where: { keeperIDs.contains($0.id) && !selected.contains($0.id) }) else {
                throw BatchTrashError.changedTargets(copies.map(\.url))
            }
            guard let keeperIdentity = ReviewIdentity.read(keeper.url) else { throw BatchTrashError.changedTargets([keeper.url]) }
            let required = Set(copies.map(\.id)).union([keeper.id])
            let result = try scanner.verifySizeGroup(DuplicateSizeGroup(byteSize: group.byteSize, items: [keeper] + copies))
            guard ReviewIdentity.read(keeper.url) == keeperIdentity,
                  result.contains(where: { $0.checksum == group.checksum && required.isSubset(of: Set($0.items.map(\.id))) }) else {
                throw BatchTrashError.changedTargets([keeper.url] + copies.map(\.url))
            }
            validated.formUnion(copies.map(\.id))
            for copy in copies { keepersByCopyPath[copy.url.standardizedFileURL.path] = (keeper.url, keeperIdentity) }
        }
        guard selected.isSubset(of: validated) else {
            throw BatchTrashError.changedTargets(verifiedItems.filter { !validated.contains($0.storageItemID) }.map(\.url))
        }
        return KeeperValidation(keepersByCopyPath: keepersByCopyPath)
    }

    public struct KeeperValidation: Sendable {
        fileprivate let keepersByCopyPath: [String: (url: URL, identity: ReviewIdentity)]

        public func validateBeforeMoving(_ url: URL) throws {
            guard let keeper = keepersByCopyPath[url.standardizedFileURL.path] else { return }
            guard ReviewIdentity.read(keeper.url) == keeper.identity else {
                throw BatchTrashError.changedTargets([keeper.url])
            }
        }
    }

    public var title: String {
        "Move \(items.count.formatted()) \(items.count == 1 ? "Item" : "Items") to Trash?"
    }

    public var estimatedReclaimBytes: Int64 {
        items.reduce(Int64(0)) { $0 + $1.reclaimableBytes }
    }

    public var containsReviewRisk: Bool {
        !reviewItems.isEmpty
    }

    public var verifiedItems: [Item] {
        items.filter(\.isVerified)
    }

    public var reviewItems: [Item] {
        items.filter { !$0.isVerified }
    }
}
fileprivate struct ReviewIdentity: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let mode: UInt16
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    func matches(_ item: StorageItem) -> Bool {
        guard mode & S_IFMT == S_IFREG, size == item.byteSize, let date = item.modifiedAt else { return false }
        let modified = Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanoseconds) / 1_000_000_000)
        return abs(modified.timeIntervalSince(date)) < 0.000_001
    }

    static func read(_ url: URL) -> Self? {
        var value = stat()
        guard url.withUnsafeFileSystemRepresentation({ path in
            path.map { lstat($0, &value) } ?? -1
        }) == 0 else { return nil }
        return Self(device: value.st_dev, inode: value.st_ino, mode: value.st_mode,
                    size: value.st_size, modifiedSeconds: value.st_mtimespec.tv_sec,
                    modifiedNanoseconds: value.st_mtimespec.tv_nsec,
                    changedSeconds: value.st_ctimespec.tv_sec, changedNanoseconds: value.st_ctimespec.tv_nsec)
    }
}
