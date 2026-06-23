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

    @Test("rollback failure surfaces rollbackFailed with restored and unrestored lists")
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

        guard case .rollbackFailed(let originalError, let rollbackError, let restoredURLs, let unrestoredURLs)? = caught else {
            Issue.record("Expected rollbackFailed, got \(String(describing: caught))")
            return
        }
        #expect(originalError.localizedDescription == "toctou trash failed")
        #expect(rollbackError.localizedDescription == "restore failed")
        #expect(moved == [urlA])
        #expect(restored.count == 1)
        #expect(restored.first?.trashed == trashedA)
        #expect(restored.first?.original == urlA)
        #expect(restoredURLs.isEmpty)
        #expect(unrestoredURLs == [urlA])
    }

    @Test("rollback failure with multiple moved items reports restored and unrestored indices")
    func rollbackFailureReportsAccurateIndices() throws {
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

        guard case .rollbackFailed(_, _, let restoredURLs, let unrestoredURLs)? = caught else {
            Issue.record("Expected rollbackFailed, got \(String(describing: caught))")
            return
        }
        #expect(moved == [urlA, urlB])
        // Rollback is reverse-order and fail-fast: the first restore attempt (B)
        // throws, so A is never tried and is recorded as unrestored.
        #expect(restored.count == 1)
        #expect(restored.first?.trashed == trashedB)
        #expect(restored.first?.original == urlB)
        #expect(restoredURLs.isEmpty)
        // Reversed iteration: B fails first, then A is skipped. Order: [B, A].
        #expect(unrestoredURLs == [urlB, urlA])
    }

    @Test("partial rollback with later items successfully restored reports mix")
    func partialRollbackUnusedIndicesReportsMix() throws {
        // Four moved-candidates: trashItem moves A, B, C then throws on D.
        // Rollback runs in reverse (C, B, A): C restores, B throws, and A is
        // skipped because rollback stops at the first captured error.
        let urlA = URL(fileURLWithPath: "/tmp/rollback-a")
        let urlB = URL(fileURLWithPath: "/tmp/rollback-b")
        let urlC = URL(fileURLWithPath: "/tmp/rollback-c")
        let urlD = URL(fileURLWithPath: "/tmp/rollback-d")
        let trashedA = URL(fileURLWithPath: "/tmp/.Trash/rollback-a")
        let trashedB = URL(fileURLWithPath: "/tmp/.Trash/rollback-b")
        let trashedC = URL(fileURLWithPath: "/tmp/.Trash/rollback-c")
        struct ToctouError: LocalizedError {
            var errorDescription: String? { "trash failed on d" }
        }
        struct RestoreError: LocalizedError {
            var errorDescription: String? { "restore b failed" }
        }

        var restored: [(trashed: URL, original: URL)] = []
        let mover = TransactionalTrashMover(
            fileExists: { _ in true },
            trashItem: { url in
                switch url {
                case urlA: return trashedA
                case urlB: return trashedB
                case urlC: return trashedC
                default: throw ToctouError()  // urlD triggers rollback
                }
            },
            restoreItem: { trashed, original in
                // B throws; A and C restore cleanly.
                if original == urlB {
                    throw RestoreError()
                }
                restored.append((trashed, original))
            }
        )

        var caught: BatchTrashError?
        do {
            try mover.moveToTrash([urlA, urlB, urlC, urlD])
            Issue.record("Expected moveToTrash to throw")
        } catch let error as BatchTrashError {
            caught = error
        } catch {
            Issue.record("Expected BatchTrashError, got \(error)")
        }

        guard case .rollbackFailed(_, _, let restoredURLs, let unrestoredURLs)? = caught else {
            Issue.record("Expected rollbackFailed, got \(String(describing: caught))")
            return
        }
        // Reverse iteration order: C, B, A. C restores. B throws. A is skipped
        // because rollback stops at the first capture.
        #expect(restored.count == 1)
        #expect(restored.first?.original == urlC)
        #expect(restoredURLs == [urlC])
        #expect(unrestoredURLs == [urlB, urlA])
    }

    @Test("rollback with missing trash location reports unrestored")
    func rollbackWithMissingTrashLocation() throws {
        // Restore fails because the trashed URL is gone (e.g. user emptied Trash
        // concurrently). We treat it as a restore failure: the original is not at
        // its original path, so it is reported as unrestored.
        let urlA = URL(fileURLWithPath: "/tmp/missing-trash-a")
        let urlB = URL(fileURLWithPath: "/tmp/missing-trash-b")
        let trashedA = URL(fileURLWithPath: "/tmp/.Trash/missing-trash-a")
        struct ToctouError: LocalizedError {
            var errorDescription: String? { "trash failed on b" }
        }
        struct RestoreError: LocalizedError {
            var errorDescription: String? { "trashed item is gone" }
        }

        let mover = TransactionalTrashMover(
            fileExists: { _ in true },
            trashItem: { url in
                if url == urlA { return trashedA }
                throw ToctouError()
            },
            restoreItem: { _, _ in
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

        guard case .rollbackFailed(_, _, let restoredURLs, let unrestoredURLs)? = caught else {
            Issue.record("Expected rollbackFailed, got \(String(describing: caught))")
            return
        }
        #expect(restoredURLs.isEmpty)
        #expect(unrestoredURLs == [urlA])
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

    // MARK: - Preflight

    @Test("preflight returns all error classes in one pass")
    func preflightReturnsAllErrorClassesInOnePass() throws {
        // Mix of: duplicate (/tmp/dup, /tmp/dup), missing (/tmp/does-not-exist),
        // nested (/tmp/parent, /tmp/parent/child).
        let parent = URL(fileURLWithPath: "/tmp/preflight-parent")
        let child = URL(fileURLWithPath: "/tmp/preflight-parent/child")
        let duplicate = URL(fileURLWithPath: "/tmp/preflight-dup")
        let missing = URL(fileURLWithPath: "/tmp/preflight-does-not-exist")

        let existing = Set([parent.path, child.path, duplicate.path])
        let mover = TransactionalTrashMover(
            fileExists: { existing.contains($0.path) },
            trashItem: { _ in fatalError("trashItem should not run in preflight") },
            restoreItem: { _, _ in fatalError("restoreItem should not run in preflight") }
        )

        let result = mover.preflight([parent, child, duplicate, duplicate, missing])

        #expect(result.duplicateCount == 1)
        #expect(result.missing == [missing])
        #expect(result.nested.count == 1)
        #expect(result.nested.first?.parent == parent)
        #expect(result.nested.first?.child == child)
        #expect(result.hasDuplicates)
        #expect(result.hasMissing)
        #expect(result.hasNested)
    }

    @Test("preflight reports only closest ancestor for deeply nested child")
    func preflightReportsClosestAncestorOnly() throws {
        // Three levels: /a, /a/b, /a/b/c. Walk from /a/b/c should find /a/b
        // (closest) and stop, not also report /a.
        let root = URL(fileURLWithPath: "/a")
        let mid = URL(fileURLWithPath: "/a/b")
        let leaf = URL(fileURLWithPath: "/a/b/c")

        let mover = TransactionalTrashMover(
            fileExists: { _ in true },
            trashItem: { _ in fatalError() },
            restoreItem: { _, _ in fatalError() }
        )

        let result = mover.preflight([root, mid, leaf])

        // We expect nested pairs for both /a/b (parent of /a/b/c) and /a (parent
        // of /a/b). Each URL reports only its closest ancestor.
        #expect(result.nested.count == 2)
        let leafPair = result.nested.first(where: { $0.child == leaf })
        let midPair = result.nested.first(where: { $0.child == mid })
        #expect(leafPair?.parent == mid)
        #expect(midPair?.parent == root)
    }

    @Test("preflight throws duplicates first, then missing, then nested")
    func preflightThrowsInStableOrder() throws {
        let parent = URL(fileURLWithPath: "/tmp/throw-parent")
        let child = URL(fileURLWithPath: "/tmp/throw-parent/child")
        let missing = URL(fileURLWithPath: "/tmp/throw-does-not-exist")

        let mover = TransactionalTrashMover(
            fileExists: { $0.path != missing.path },
            trashItem: { _ in fatalError() },
            restoreItem: { _, _ in fatalError() }
        )

        // Duplicates take precedence.
        do {
            try mover.moveToTrash([parent, child, missing, parent])
            Issue.record("Expected duplicateTargets")
        } catch BatchTrashError.duplicateTargets {
            // expected
        } catch {
            Issue.record("Expected duplicateTargets, got \(error)")
        }

        // Missing takes precedence over nested when there are no duplicates.
        do {
            try mover.moveToTrash([parent, child, missing])
            Issue.record("Expected missingTargets")
        } catch BatchTrashError.missingTargets {
            // expected
        } catch {
            Issue.record("Expected missingTargets, got \(error)")
        }

        // Nested is reported when duplicates and missing are clean.
        let allExisting = TransactionalTrashMover(
            fileExists: { _ in true },
            trashItem: { _ in fatalError() },
            restoreItem: { _, _ in fatalError() }
        )
        do {
            try allExisting.moveToTrash([parent, child])
            Issue.record("Expected nestedTargets")
        } catch BatchTrashError.nestedTargets(let reportedParent, let reportedChild) {
            #expect(reportedParent == parent)
            #expect(reportedChild == child)
        } catch {
            Issue.record("Expected nestedTargets, got \(error)")
        }
    }

    @Test("preflight handles root-level and sibling URLs without false nested matches")
    func preflightRejectsSiblingFalsePositives() throws {
        // /tmp/foo and /tmp/foobar share the /tmp/foo prefix but are siblings,
        // not parent/child. The sort-and-prefix approach without the trailing
        // "/" would false-positive here; walkAncestors must not.
        let sibling1 = URL(fileURLWithPath: "/tmp/prefix")
        let sibling2 = URL(fileURLWithPath: "/tmp/prefix-suffix")

        let mover = TransactionalTrashMover(
            fileExists: { _ in true },
            trashItem: { _ in fatalError() },
            restoreItem: { _, _ in fatalError() }
        )

        let result = mover.preflight([sibling1, sibling2])
        #expect(result.nested.isEmpty)
        #expect(result.duplicateCount == 0)
        #expect(result.missing.isEmpty)
    }

    @Test("preflight result for clean batch reports no errors")
    func preflightCleanBatch() throws {
        let urlA = URL(fileURLWithPath: "/tmp/clean-a")
        let urlB = URL(fileURLWithPath: "/tmp/clean-b")

        let mover = TransactionalTrashMover(
            fileExists: { _ in true },
            trashItem: { _ in fatalError() },
            restoreItem: { _, _ in fatalError() }
        )

        let result = mover.preflight([urlA, urlB])
        #expect(result.duplicateCount == 0)
        #expect(result.missing.isEmpty)
        #expect(result.nested.isEmpty)
        #expect(!result.hasDuplicates)
        #expect(!result.hasMissing)
        #expect(!result.hasNested)
    }
}