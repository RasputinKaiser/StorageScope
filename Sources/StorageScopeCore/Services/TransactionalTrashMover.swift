import Foundation

public enum BatchTrashError: LocalizedError {
    case duplicateTargets
    case nestedTargets(parent: URL, child: URL)
    case missingTargets([URL])
    case rollbackSucceeded(originalError: Error)
    case rollbackFailed(originalError: Error, rollbackError: Error, movedCount: Int)
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
        case .rollbackFailed(let originalError, let rollbackError, let movedCount):
            return "Trash failed after moving \(movedCount) item(s), and rollback also failed. Original error: \(originalError.localizedDescription). Rollback error: \(rollbackError.localizedDescription)"
        case .missingTrashLocation(let url):
            return "macOS moved \(url.lastPathComponent) to Trash but did not report its Trash location, so StorageScope could not guarantee rollback."
        }
    }
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

            do {
                try rollbackMovedItems(movedItems)
                throw BatchTrashError.rollbackSucceeded(originalError: originalError)
            } catch let rollbackError as BatchTrashError {
                throw rollbackError
            } catch let rollbackError {
                throw BatchTrashError.rollbackFailed(
                    originalError: originalError,
                    rollbackError: rollbackError,
                    movedCount: movedItems.count
                )
            }
        }
    }

    private func preflightBatchTrash(_ urls: [URL]) throws {
        guard urls.count == Set(urls.map(\.path)).count else {
            throw BatchTrashError.duplicateTargets
        }

        let missingURLs = urls.filter { !fileExists($0) }
        if !missingURLs.isEmpty {
            throw BatchTrashError.missingTargets(missingURLs)
        }

        let sortedURLs = urls.sorted { $0.path.count < $1.path.count }
        for parentIndex in sortedURLs.indices {
            let parent = sortedURLs[parentIndex]
            for child in sortedURLs.dropFirst(parentIndex + 1) {
                if child.path.hasPrefix(parent.path + "/") {
                    throw BatchTrashError.nestedTargets(parent: parent, child: child)
                }
            }
        }
    }

    private func rollbackMovedItems(_ movedItems: [(original: URL, trashed: URL)]) throws {
        for movedItem in movedItems.reversed() {
            do {
                try restoreItem(movedItem.trashed, movedItem.original)
            } catch {
                if fileExists(movedItem.original), !fileExists(movedItem.trashed) {
                    continue
                }
                throw error
            }
        }
    }
}
