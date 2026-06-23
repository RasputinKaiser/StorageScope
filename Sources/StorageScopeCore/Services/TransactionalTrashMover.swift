import Foundation

public enum BatchTrashError: LocalizedError {
    case duplicateTargets
    case nestedTargets(parent: URL, child: URL)
    case missingTargets([URL])
    case rollbackSucceeded(originalError: Error)
    case rollbackFailed(
        originalError: Error,
        rollbackError: Error,
        restored: [URL],
        unrestored: [URL]
    )
    case missingTrashLocation(URL)

    public var errorDescription: String? {
        switch self {
        case .duplicateTargets:
            return "The cleanup selection contains the same item more than once. Clear the selection and try again."
        case .nestedTargets(let parent, let child):
            return "The cleanup selection contains both \(parent.lastPathComponent) and one of its children, \(child.lastPathComponent). Select only one level before moving items to Trash."
        case .missingTargets(let urls):
            let names = urls.map(\.lastPathComponent).joined(separator: ", ")
            return "Some selected items no longer exist: \(names). Rescan before moving items to Trash."
        case .rollbackSucceeded(let originalError):
            return "Trash failed and StorageScope restored the items it had already moved. Original error: \(originalError.localizedDescription)"
        case .rollbackFailed(let originalError, let rollbackError, let restored, let unrestored):
            let movedCount = restored.count + unrestored.count
            let restoredNames = restored.map(\.lastPathComponent).joined(separator: ", ")
            let trashedNames = unrestored.map(\.lastPathComponent).joined(separator: ", ")
            return "Trash failed after moving \(movedCount) item(s); StorageScope restored \(restored.count) (\(restoredNames)) but \(unrestored.count) remain in Trash (\(trashedNames)). Original error: \(originalError.localizedDescription). Rollback error: \(rollbackError.localizedDescription)"
        case .missingTrashLocation(let url):
            return "macOS moved \(url.lastPathComponent) to Trash but did not report its Trash location, so StorageScope could not guarantee rollback."
        }
    }
}

public struct NestedTargetPair: Equatable {
    public let parent: URL
    public let child: URL

    public init(parent: URL, child: URL) {
        self.parent = parent
        self.child = child
    }
}

public struct BatchTrashPreflightResult: Equatable {
    public let duplicateCount: Int
    public let missing: [URL]
    public let nested: [NestedTargetPair]

    public var hasDuplicates: Bool { duplicateCount > 0 }
    public var hasMissing: Bool { !missing.isEmpty }
    public var hasNested: Bool { !nested.isEmpty }
}

public struct TransactionalTrashMover {
    private let fileExists: (URL) -> Bool
    private let trashItem: (URL) throws -> URL
    private let restoreItem: (URL, URL) throws -> Void

    public init(fileManager: FileManager = .default) {
        self.init(
            fileExists: { fileManager.fileExists(atPath: $0.path) },
            trashItem: { url in
                var resultingURL: NSURL?
                try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
                guard let trashedURL = resultingURL as URL? else {
                    throw BatchTrashError.missingTrashLocation(url)
                }
                return trashedURL
            },
            restoreItem: { trashedURL, originalURL in
                try fileManager.moveItem(at: trashedURL, to: originalURL)
            }
        )
    }

    init(
        fileExists: @escaping (URL) -> Bool,
        trashItem: @escaping (URL) throws -> URL,
        restoreItem: @escaping (URL, URL) throws -> Void
    ) {
        self.fileExists = fileExists
        self.trashItem = trashItem
        self.restoreItem = restoreItem
    }

    public func preflight(_ urls: [URL]) -> BatchTrashPreflightResult {
        preflightResult(urls.map(\.standardizedFileURL))
    }

    public func moveToTrash(_ urls: [URL]) throws {
        let standardizedURLs = urls.map(\.standardizedFileURL)
        try preflightBatchTrash(standardizedURLs)
        guard !standardizedURLs.isEmpty else {
            return
        }

        var movedItems: [(original: URL, trashed: URL)] = []

        do {
            for original in standardizedURLs {
                let trashedURL = try trashItem(original)
                movedItems.append((original: original, trashed: trashedURL))
            }
        } catch let originalError {
            guard !movedItems.isEmpty else {
                throw originalError
            }

            let outcome = rollbackMovedItems(movedItems)
            if let rollbackError = outcome.error {
                throw BatchTrashError.rollbackFailed(
                    originalError: originalError,
                    rollbackError: rollbackError,
                    restored: outcome.restored,
                    unrestored: outcome.unrestored
                )
            }
            throw BatchTrashError.rollbackSucceeded(originalError: originalError)
        }
    }

    private func preflightBatchTrash(_ urls: [URL]) throws {
        let result = preflightResult(urls)
        if result.hasDuplicates {
            throw BatchTrashError.duplicateTargets
        }
        if !result.missing.isEmpty {
            throw BatchTrashError.missingTargets(result.missing)
        }
        if let nested = result.nested.first {
            throw BatchTrashError.nestedTargets(parent: nested.parent, child: nested.child)
        }
    }

    private func preflightResult(_ urls: [URL]) -> BatchTrashPreflightResult {
        // Path-keyed lookup so the original URL identity is preserved when an
        // ancestor is found, avoiding the trailing-slash divergence that
        // URL.deletingLastPathComponent() introduces.
        let paths = urls.map(\.path)
        let pathSet = Set(paths)
        // On duplicate paths (duplicates are reported via duplicateCount),
        // keep the first occurrence's URL object for any ancestor lookups.
        let urlByPath = Dictionary(zip(paths, urls), uniquingKeysWith: { first, _ in first })
        let duplicateCount = paths.count - pathSet.count

        var missing: [URL] = []
        var nested: [NestedTargetPair] = []

        for url in urls {
            if !fileExists(url) {
                missing.append(url)
            }
            var currentPath = (url.path as NSString).deletingLastPathComponent
            while currentPath != "/" && !currentPath.isEmpty {
                if let matchingParent = urlByPath[currentPath] {
                    nested.append(NestedTargetPair(parent: matchingParent, child: url))
                    break
                }
                let nextPath = (currentPath as NSString).deletingLastPathComponent
                if nextPath == currentPath {
                    break
                }
                currentPath = nextPath
            }
        }

        return BatchTrashPreflightResult(
            duplicateCount: duplicateCount,
            missing: missing,
            nested: nested
        )
    }

    private func rollbackMovedItems(
        _ movedItems: [(original: URL, trashed: URL)]
    ) -> (restored: [URL], unrestored: [URL], error: Error?) {
        var restored: [URL] = []
        var unrestored: [URL] = []
        var capturedError: Error?

        for movedItem in movedItems.reversed() {
            if capturedError != nil {
                unrestored.append(movedItem.original)
                continue
            }
            do {
                try restoreItem(movedItem.trashed, movedItem.original)
                restored.append(movedItem.original)
            } catch {
                capturedError = error
                unrestored.append(movedItem.original)
            }
        }

        return (restored: restored, unrestored: unrestored, error: capturedError)
    }
}
