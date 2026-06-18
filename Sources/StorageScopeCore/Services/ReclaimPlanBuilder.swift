import Foundation

public struct ReclaimPlan: Equatable, Sendable {
    public let sections: [ReclaimPlanSection]
    public let primaryAction: ReclaimPlanAction?

    public init(sections: [ReclaimPlanSection], primaryAction: ReclaimPlanAction?) {
        self.sections = sections
        self.primaryAction = primaryAction
    }
}

public struct ReclaimPlanSection: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case verifiedDuplicates
        case reviewSuggestions
        case inaccessibleItems
    }

    public let kind: Kind
    public let title: String
    public let detail: String
    public let itemCount: Int
    public let reclaimableBytes: Int64
    public let action: ReclaimPlanAction?

    public var id: String {
        kind.rawValue
    }

    public init(
        kind: Kind,
        title: String,
        detail: String,
        itemCount: Int,
        reclaimableBytes: Int64,
        action: ReclaimPlanAction?
    ) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.itemCount = itemCount
        self.reclaimableBytes = reclaimableBytes
        self.action = action
    }
}

public enum ReclaimPlanAction: String, Equatable, Sendable {
    case reviewVerifiedDuplicates
    case reviewCleanupSuggestions
    case inspectInaccessibleItems
}

public enum ReclaimPlanBuilder {
    public static func build(
        scan: StorageScan,
        visibleCleanupCandidates: [CleanupCandidate]
    ) -> ReclaimPlan {
        let verifiedCandidates = CleanupSelectionPlanner.verifiedDuplicateBatchCandidates(visibleCleanupCandidates)
        let reviewCandidates = CleanupSelectionPlanner.topLevelCandidates(
            visibleCleanupCandidates.filter { !$0.isHighConfidenceVerifiedDuplicate }
        )

        var sections: [ReclaimPlanSection] = []

        if !verifiedCandidates.isEmpty {
            sections.append(
                ReclaimPlanSection(
                    kind: .verifiedDuplicates,
                    title: "Verified duplicate reclaim",
                    detail: "Content-matched copies are the safest batch review lane.",
                    itemCount: verifiedCandidates.count,
                    reclaimableBytes: verifiedCandidates.reduce(Int64(0)) { $0 + $1.reclaimableBytes },
                    action: .reviewVerifiedDuplicates
                )
            )
        }

        if !reviewCandidates.isEmpty {
            sections.append(
                ReclaimPlanSection(
                    kind: .reviewSuggestions,
                    title: "Review suggested cleanup",
                    detail: "Installers, archives, caches, build output, and stale large files need a human pass.",
                    itemCount: reviewCandidates.count,
                    reclaimableBytes: reviewCandidates.reduce(Int64(0)) { $0 + $1.reclaimableBytes },
                    action: .reviewCleanupSuggestions
                )
            )
        }

        if scan.inaccessibleItemCount > 0 {
            sections.append(
                ReclaimPlanSection(
                    kind: .inaccessibleItems,
                    title: "Access gaps",
                    detail: "Some locations could not be read. Grant access or rescan a narrower folder for a fuller map.",
                    itemCount: scan.inaccessibleItemCount,
                    reclaimableBytes: 0,
                    action: .inspectInaccessibleItems
                )
            )
        }

        return ReclaimPlan(
            sections: sections,
            primaryAction: sections.compactMap(\.action).first
        )
    }
}
