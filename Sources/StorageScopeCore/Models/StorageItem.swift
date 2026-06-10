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
        [self] + children.flatMap { $0.flattened() }
    }

    public var retainedItemCount: Int {
        1 + children.reduce(0) { $0 + $1.retainedItemCount }
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
}
