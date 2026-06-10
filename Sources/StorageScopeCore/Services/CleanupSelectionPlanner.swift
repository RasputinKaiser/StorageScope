import Foundation

public enum CleanupSelectionPlanner {
    public static func verifiedDuplicateBatchCandidates(_ candidates: [CleanupCandidate]) -> [CleanupCandidate] {
        topLevelCandidates(candidates.filter(isHighConfidenceVerifiedDuplicate))
    }

    public static func containsReviewRisk(_ candidates: [CleanupCandidate]) -> Bool {
        candidates.contains { !isHighConfidenceVerifiedDuplicate($0) }
    }

    public static func topLevelCandidates(_ candidates: [CleanupCandidate]) -> [CleanupCandidate] {
        let paths = candidates.map { $0.item.url.standardizedFileURL.path }
        let firstIndexes = firstIndexesByPath(paths)

        return candidates.enumerated().compactMap { index, candidate in
            let path = paths[index]
            guard firstIndexes[path] == index else {
                return nil
            }
            return hasAncestor(path, in: paths) ? nil : candidate
        }
    }

    public static func topLevelURLs(_ urls: [URL]) -> [URL] {
        let standardizedURLs = urls.map(\.standardizedFileURL)
        let paths = standardizedURLs.map(\.path)
        let firstIndexes = firstIndexesByPath(paths)

        return standardizedURLs.enumerated().compactMap { index, url in
            let path = paths[index]
            guard firstIndexes[path] == index else {
                return nil
            }
            return hasAncestor(path, in: paths) ? nil : url
        }
    }

    private static func isHighConfidenceVerifiedDuplicate(_ candidate: CleanupCandidate) -> Bool {
        candidate.kind == .verifiedDuplicate && candidate.confidence == .high
    }

    private static func firstIndexesByPath(_ paths: [String]) -> [String: Int] {
        var firstIndexes: [String: Int] = [:]
        for (index, path) in paths.enumerated() where firstIndexes[path] == nil {
            firstIndexes[path] = index
        }
        return firstIndexes
    }

    private static func hasAncestor(_ path: String, in paths: [String]) -> Bool {
        paths.contains { candidate in
            candidate != path && isAncestor(candidate, of: path)
        }
    }

    private static func isAncestor(_ possibleAncestor: String, of path: String) -> Bool {
        if possibleAncestor == "/" {
            return path != "/"
        }
        return path.hasPrefix(possibleAncestor + "/")
    }
}
