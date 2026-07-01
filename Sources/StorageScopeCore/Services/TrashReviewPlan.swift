import Foundation

public struct TrashReviewPlan: Identifiable, Equatable, Sendable {
    public struct Item: Identifiable, Equatable, Sendable {
        public let id: String
        public let url: URL
        public let kind: CleanupCandidate.Kind
        public let confidence: CleanupCandidate.Confidence
        public let reclaimableBytes: Int64
        public let reason: String
        public let isDirectory: Bool

        public init(candidate: CleanupCandidate) {
            id = candidate.id
            url = candidate.item.url
            kind = candidate.kind
            confidence = candidate.confidence
            reclaimableBytes = candidate.reclaimableBytes
            reason = candidate.reason
            isDirectory = candidate.item.isContainer
        }

        public var isVerified: Bool {
            kind == .verifiedDuplicate && confidence == .high
        }
    }

    public let items: [Item]
    public let id: String
    public let missingPaths: [URL]

    public init(candidates: [CleanupCandidate]) {
        let kept = CleanupSelectionPlanner.topLevelCandidates(candidates)
        items = kept.map(Item.init(candidate:))
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
        id = items.map(\.id).joined(separator: "|")
        missingPaths = selection.missingPaths
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