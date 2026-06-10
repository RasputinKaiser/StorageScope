import Foundation

public enum DuplicateReviewPlanner {
    public static func unverifiedSizeGroups(
        sizeGroups: [DuplicateSizeGroup],
        verifiedGroups: [VerifiedDuplicateGroup]
    ) -> [DuplicateSizeGroup] {
        let verifiedItemIDs = Set(verifiedGroups.flatMap { $0.items.map(\.id) })

        return sizeGroups
            .map { group in
                DuplicateSizeGroup(
                    byteSize: group.byteSize,
                    items: group.items.filter { !verifiedItemIDs.contains($0.id) }
                )
            }
            .filter { $0.items.count > 1 }
    }
}
