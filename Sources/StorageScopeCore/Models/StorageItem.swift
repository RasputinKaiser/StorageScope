import Foundation

public struct StorageItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case folder
        case file
        case package
        case alias
        case inaccessible
        case other
    }

    public let id: String
    public let url: URL
    public let name: String
    public let kind: Kind
    public let byteSize: Int64
    public let allocatedSize: Int64
    public let modifiedAt: Date?
    public let immediateChildCount: Int
    public let descendantCount: Int
    public let children: [StorageItem]
    public let isReadable: Bool
    public let fileExtension: String?

    public init(
        url: URL,
        name: String? = nil,
        kind: Kind,
        byteSize: Int64,
        allocatedSize: Int64,
        modifiedAt: Date?,
        immediateChildCount: Int,
        descendantCount: Int,
        children: [StorageItem] = [],
        isReadable: Bool,
        fileExtension: String? = nil
    ) {
        self.url = url
        self.id = url.standardizedFileURL.path
        self.name = name ?? url.lastPathComponent
        self.kind = kind
        self.byteSize = byteSize
        self.allocatedSize = allocatedSize
        self.modifiedAt = modifiedAt
        self.immediateChildCount = immediateChildCount
        self.descendantCount = descendantCount
        self.children = children
        self.isReadable = isReadable
        self.fileExtension = fileExtension
    }

    public var displaySize: Int64 {
        max(byteSize, allocatedSize)
    }

    public var isContainer: Bool {
        kind == .folder || kind == .package
    }

    public func flattened() -> [StorageItem] {
        var items: [StorageItem] = []
        items.reserveCapacity(retainedItemCount)
        appendFlattened(to: &items)
        return items
    }

    public var retainedItemCount: Int {
        1 + children.reduce(0) { $0 + $1.retainedItemCount }
    }

    public func matchesSearchQuery(_ query: String) -> Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return matchesNormalizedSearchQuery(trimmedQuery)
    }

    public func retainedTreeContainsSearchMatch(_ query: String) -> Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return retainedTreeContainsNormalizedSearchMatch(trimmedQuery)
    }

    public func matchesNormalizedSearchQuery(_ query: String) -> Bool {
        guard !query.isEmpty else {
            return true
        }

        // Multi-word AND: every whitespace-delimited term must match either the
        // name, the contiguous URL path string, OR a `/`-split path segment
        // (so "Documents foo" matches a path like `/tmp/work/Documents/foo.txt`
        // via "Documents" segment + "foo" contiguous name substring). Single-term
        // queries degenerate to the v0.4.5 single-contains behavior on each of
        // name / path / path-segments.
        let terms = query.split(separator: " ", omittingEmptySubsequences: true)
        return terms.allSatisfy { term in
            matchesTerm(String(term))
        }
    }

    private func matchesTerm(_ term: String) -> Bool {
        if name.localizedCaseInsensitiveContains(term) {
            return true
        }
        if url.path.localizedCaseInsensitiveContains(term) {
            return true
        }
        // Path-segment awareness: term matches if it equals (case-insensitively) any
        // segment of the `/`-split path. Segment-aware, NOT substring-across-segments —
        // "xDoc" must NOT match `/tmp/Doc/file.txt` even though it's a substring of
        // the contiguous string "/tmpDocfile".
        return url.pathComponents.contains { $0.localizedCaseInsensitiveCompare(term) == .orderedSame }
    }

    /// Matched ranges of `name` for the given query, suitable for `Text(...)` highlight
    /// rendering. Returns ranges across every whitespace term in `query` whose
    /// case-insensitive substring is found in `name`. Empty when no term matches.
    public func searchHighlightRanges(for query: String) -> [Range<String.Index>] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let terms = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        var ranges: [Range<String.Index>] = []
        for term in terms {
            let termStr = String(term)
            var searchStart = name.startIndex
            while searchStart < name.endIndex,
                  let range = name.range(of: termStr, options: .caseInsensitive, range: searchStart..<name.endIndex) {
                ranges.append(range)
                if range.upperBound < name.endIndex {
                    searchStart = range.upperBound
                } else {
                    break
                }
            }
        }
        return ranges
    }

    public func retainedTreeContainsNormalizedSearchMatch(_ query: String) -> Bool {
        matchesNormalizedSearchQuery(query) ||
            children.contains { $0.retainedTreeContainsNormalizedSearchMatch(query) }
    }

    public func pruningChildren() -> StorageItem {
        StorageItem(
            url: url,
            name: name,
            kind: kind,
            byteSize: byteSize,
            allocatedSize: allocatedSize,
            modifiedAt: modifiedAt,
            immediateChildCount: immediateChildCount,
            descendantCount: descendantCount,
            children: [],
            isReadable: isReadable,
            fileExtension: fileExtension
        )
    }

    private func appendFlattened(to items: inout [StorageItem]) {
        items.append(self)
        for child in children {
            child.appendFlattened(to: &items)
        }
    }
}
