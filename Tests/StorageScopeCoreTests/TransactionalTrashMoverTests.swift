import Foundation
import Testing
@testable import StorageScopeCore

@Suite("TransactionalTrashMover")
struct TransactionalTrashMoverTests {
    @Test("toctou rollback restores earlier-moved items")
    func toctouRollbackRestoresEarlierMovedItems() throws {
        let urlA = URL(fileURLWithPath: "/tmp/fixture-a")
        let urlB = URL(fileURLWithPath: "/tmp/fixture-b")
        let trashedA = URL(fileURLWithPath: "/tmp/.Trash/fixture-a")
        struct ToctouError: LocalizedError {
            var errorDescription: String? { "toctou trash failed" }
        }

        var moved: [URL] = []
        var restored: [(trashed: URL, original: URL)] = []
        let mover = TransactionalTrashMover(
            fileExists: { _ in true },
            trashItem: { url in
                if url == urlA {
                    moved.append(url)
                    return trashedA
                }
                throw ToctouError()
            },
            restoreItem: { trashed, original in
                restored.append((trashed, original))
            }
        )

        var caught: BatchTrashError?
        do {
            try mover.moveToTrash([urlA, urlB])
        } catch let error as BatchTrashError {
            caught = error
        } catch {
            Issue.record("Expected BatchTrashError, got \(error)")
        }

        guard case .rollbackSucceeded(let originalError)? = caught else {
            Issue.record("Expected rollbackSucceeded, got \(String(describing: caught))")
            return
        }
        #expect(moved == [urlA])
        #expect(restored.count == 1)
        #expect(restored.first?.trashed == trashedA)
        #expect(restored.first?.original == urlA)
        #expect(originalError.localizedDescription == "toctou trash failed")
    }

    @Test("rollback failure surfaces rollback failed error")
    func rollbackFailureSurfacesRollbackFailedError() throws {
        let urlA = URL(fileURLWithPath: "/tmp/fixture-a")
        let urlB = URL(fileURLWithPath: "/tmp/fixture-b")
        let trashedA = URL(fileURLWithPath: "/tmp/.Trash/fixture-a")
        struct ToctouError: LocalizedError {
            var errorDescription: String? { "toctou trash failed" }
        }
        struct RestoreError: LocalizedError {
            var errorDescription: String? { "restore failed" }
        }

        var moved: [URL] = []
        var restored: [(trashed: URL, original: URL)] = []
        // fileExists returns true for every probe, so the rollbackMovedItems
        // continue-on-restore-silent-success guard (fileExists(original) &&
        // !fileExists(trashed)) is false and the RestoreError is rethrown.
        let mover = TransactionalTrashMover(
            fileExists: { _ in true },
            trashItem: { url in
                if url == urlA {
                    moved.append(url)
                    return trashedA
                }
                throw ToctouError()
            },
            restoreItem: { trashed, original in
                restored.append((trashed, original))
                throw RestoreError()
            }
        )

        var caught: BatchTrashError?
        do {
            try mover.moveToTrash([urlA, urlB])
        } catch let error as BatchTrashError {
            caught = error
        } catch {
            Issue.record("Expected BatchTrashError, got \(error)")
        }

        guard case .rollbackFailed(let originalError, let rollbackError, let movedCount)? = caught else {
            Issue.record("Expected rollbackFailed, got \(String(describing: caught))")
            return
        }
        #expect(movedCount == 1)
        #expect(originalError.localizedDescription == "toctou trash failed")
        #expect(rollbackError.localizedDescription == "restore failed")
        #expect(moved == [urlA])
        #expect(restored.count == 1)
        #expect(restored.first?.trashed == trashedA)
        #expect(restored.first?.original == urlA)
    }

    @Test("rollback failure with multiple moved items reports accurate movedCount")
    func rollbackFailureReportsAccurateMovedCount() throws {
        let urlA = URL(fileURLWithPath: "/tmp/multi-a")
        let urlB = URL(fileURLWithPath: "/tmp/multi-b")
        let urlC = URL(fileURLWithPath: "/tmp/multi-c")
        let trashedA = URL(fileURLWithPath: "/tmp/.Trash/multi-a")
        let trashedB = URL(fileURLWithPath: "/tmp/.Trash/multi-b")
        struct ToctouError: LocalizedError {
            var errorDescription: String? { "toctou trash failed on c" }
        }
        struct RestoreError: LocalizedError {
            var errorDescription: String? { "restore failed" }
        }

        var moved: [URL] = []
        var restored: [(trashed: URL, original: URL)] = []
        let mover = TransactionalTrashMover(
            fileExists: { _ in true },
            trashItem: { url in
                switch url {
                case urlA:
                    moved.append(url)
                    return trashedA
                case urlB:
                    moved.append(url)
                    return trashedB
                default:
                    throw ToctouError()
                }
            },
            restoreItem: { trashed, original in
                restored.append((trashed, original))
                throw RestoreError()
            }
        )

        var caught: BatchTrashError?
        do {
            try mover.moveToTrash([urlA, urlB, urlC])
        } catch let error as BatchTrashError {
            caught = error
        } catch {
            Issue.record("Expected BatchTrashError, got \(error)")
        }

        guard case .rollbackFailed(_, _, let movedCount)? = caught else {
            Issue.record("Expected rollbackFailed, got \(String(describing: caught))")
            return
        }
        #expect(movedCount == 2)
        #expect(moved == [urlA, urlB])
        // Rollback is reverse-order and fail-fast: the first restore (B) throws,
        // so A is never attempted. movedCount still reports both moved items.
        #expect(restored.count == 1)
        #expect(restored.first?.trashed == trashedB)
        #expect(restored.first?.original == urlB)
    }

    @Test("empty batch throws nothing and runs no closures")
    func emptyBatchThrowsNothingAndRunsNoClosures() throws {
        var calls: [String] = []
        let mover = TransactionalTrashMover(
            fileExists: { _ in
                calls.append("fileExists")
                return true
            },
            trashItem: { _ in
                calls.append("trashItem")
                return URL(fileURLWithPath: "/dev/null")
            },
            restoreItem: { _, _ in
                calls.append("restoreItem")
            }
        )

        try mover.moveToTrash([])
        #expect(calls.isEmpty)
    }
}