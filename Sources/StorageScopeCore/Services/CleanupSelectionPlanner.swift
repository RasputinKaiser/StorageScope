import Foundation

public enum CleanupSelectionPlanner {
    /// Result of a top-level selection sweep. `missingPaths` is populated when
    /// the caller supplies a `fileExists` probe, so the trash flow can surface
    /// inputs that no longer point at a live disk item.
    public struct Selection: Equatable, Sendable {
        public let candidates: [CleanupCandidate]
        public let missingPaths: [URL]

        public init(candidates: [CleanupCandidate], missingPaths: [URL] = []) {
            self.candidates = candidates
            self.missingPaths = missingPaths
        }
    }

    public static func verifiedDuplicateBatchCandidates(_ candidates: [CleanupCandidate]) -> [CleanupCandidate] {
        topLevelCandidates(candidates.filter(\.isHighConfidenceVerifiedDuplicate))
    }

    public static func containsReviewRisk(_ candidates: [CleanupCandidate]) -> Bool {
        candidates.contains { !$0.isHighConfidenceVerifiedDuplicate }
    }

    public static func topLevelCandidates(_ candidates: [CleanupCandidate]) -> [CleanupCandidate] {
        guard !candidates.isEmpty else {
            return []
        }
        let paths = candidates.map { $0.item.url.standardizedFileURL.path }
        let topPaths = topLevelPaths(paths)
        var deduped = Set<String>()
        var result: [CleanupCandidate] = []
        result.reserveCapacity(min(candidates.count, topPaths.count))
        for (index, candidate) in candidates.enumerated() {
            let path = paths[index]
            guard topPaths.contains(path), deduped.insert(path).inserted else {
                continue
            }
            result.append(candidate)
        }
        return result
    }

    /// Same as `topLevelCandidates(_:)` but reports any candidate whose URL no
    /// longer exists on disk. Missing candidates are excluded from the kept
    /// list so downstream trash flows never present a path that cannot be moved.
    public static func selectTopLevel(
        _ candidates: [CleanupCandidate],
        fileExists: @escaping (URL) -> Bool
    ) -> Selection {
        var kept: [CleanupCandidate] = []
        kept.reserveCapacity(candidates.count)
        var missing: [URL] = []
        for candidate in candidates {
            let url = candidate.item.url.standardizedFileURL
            if fileExists(url) {
                kept.append(candidate)
            } else {
                missing.append(url)
            }
        }
        return Selection(candidates: topLevelCandidates(kept), missingPaths: missing)
    }

    public static func topLevelURLs(_ urls: [URL]) -> [URL] {
        guard !urls.isEmpty else {
            return []
        }
        let standardizedURLs = urls.map(\.standardizedFileURL)
        let paths = standardizedURLs.map(\.path)
        let topPaths = topLevelPaths(paths)
        var deduped = Set<String>()
        var result: [URL] = []
        result.reserveCapacity(min(standardizedURLs.count, topPaths.count))
        for (index, url) in standardizedURLs.enumerated() {
            let path = paths[index]
            guard topPaths.contains(path), deduped.insert(path).inserted else {
                continue
            }
            result.append(url)
        }
        return result
    }

    /// Collapses nested-target selections in a single hash-join pass: one `Set`
    /// is built for the whole input, and each path walks its own parent chain
    /// with O(1) set lookups. Replaces the previous O(n^2) `paths.contains` scan.
    static func topLevelPaths(_ paths: [String]) -> Set<String> {
        guard !paths.isEmpty else {
            return []
        }
        let pathSet = Set(paths)
        var topPaths: Set<String> = []
        topPaths.reserveCapacity(pathSet.count)
        for path in pathSet where !hasAncestor(path, in: pathSet) {
            topPaths.insert(path)
        }
        return topPaths
    }

    private static func hasAncestor(_ path: String, in pathSet: Set<String>) -> Bool {
        // Walk the parent chain by slicing at the last '/' until the path is
        // exhausted. The root "/" is treated as an ancestor of every non-root
        // path, since trashing the root would swallow the nested target.
        var current = path
        while let slash = current.lastIndex(of: "/") {
            current = String(current[..<slash])
            if current.isEmpty {
                return path != "/" && pathSet.contains("/")
            }
            if pathSet.contains(current) {
                return true
            }
        }
        return false
    }
}