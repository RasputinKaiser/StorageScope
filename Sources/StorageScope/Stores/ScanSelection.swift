import Foundation
import StorageScopeCore

struct ScanSelection {
    var selectedItemID: String?
    var selectedCleanupCandidateIDs = Set<String>()
    var ignoredCleanupCandidateIDs = Set<String>()
    var treeExpandedIDs = Set<String>()

    mutating func resetForNewScan() {
        selectedItemID = nil
        selectedCleanupCandidateIDs.removeAll()
        ignoredCleanupCandidateIDs.removeAll()
        treeExpandedIDs.removeAll()
    }

    mutating func toggleCleanupCandidate(_ candidate: CleanupCandidate) {
        if selectedCleanupCandidateIDs.contains(candidate.id) {
            selectedCleanupCandidateIDs.remove(candidate.id)
        } else {
            selectedCleanupCandidateIDs.insert(candidate.id)
        }
        selectedItemID = candidate.item.id
    }

    mutating func clearCleanupSelection() {
        selectedCleanupCandidateIDs.removeAll()
    }

    mutating func ignoreCleanupCandidate(_ candidate: CleanupCandidate) {
        ignoredCleanupCandidateIDs.insert(candidate.id)
        selectedCleanupCandidateIDs.remove(candidate.id)
    }

    mutating func unignoreCleanupCandidate(_ candidate: CleanupCandidate) {
        ignoredCleanupCandidateIDs.remove(candidate.id)
    }

    mutating func clearIgnoredCleanupCandidates() {
        ignoredCleanupCandidateIDs.removeAll()
    }
}
