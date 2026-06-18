import Foundation

public struct TrashReviewPlan: Identifiable, Equatable, Sendable {
    public struct Item: Identifiable, Equatable, Sendable {
        public let id: String
        public let url: URL
        public let kind: CleanupCandidate.Kind
        public let confidence: CleanupCandidate.Confidence
        public let reclaimableBytes: Int64
        public let reason: String

        public init(candidate: CleanupCandidate) {
            id = candidate.id
            url = candidate.item.url
            kind = candidate.kind
            confidence = candidate.confidence
            reclaimableBytes = candidate.reclaimableBytes
            reason = candidate.reason
        }

        public var isVerified: Bool {
            kind == .verifiedDuplicate && confidence == .high
        }
    }

    public let items: [Item]
    public let id: String

    public init(candidates: [CleanupCandidate]) {
        items = CleanupSelectionPlanner.topLevelCandidates(candidates).map(Item.init(candidate:))
        id = items.map(\.id).joined(separator: "|")
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
