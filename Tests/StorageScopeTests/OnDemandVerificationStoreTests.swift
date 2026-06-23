import Foundation
import Testing
import StorageScopeCore
@testable import StorageScope

@MainActor
@Suite("OnDemandVerificationStore")
struct OnDemandVerificationStoreTests {
    // MARK: - Concurrent same-group dedupe

    @Test("concurrent same-group taps are deduped by verifyingGroupIDs")
    func concurrentSameGroupTapsDedupe() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        let store = OnDemandVerificationStore(
            hashCache: DuplicateHashCache(),
            scanLookup: { nil },
            coordinateInvalidate: { },
            reportError: { _ in }
        )

        let group = fixture.unverifiedGroup
        // Fire multiple taps in immediate succession before the first one can clear
        // verifyingGroupIDs. The guard at line 58 must reject every subsequent tap.
        for _ in 0..<25 {
            store.verify(group)
        }

        #expect(store.verifyingGroupIDs == [group.id])
        #expect(verifiedItemNames(store: store) == [])

        // Let the in-flight task finish and assert it produced exactly one verified group.
        try await waitForVerifyToSettle(store: store, groupID: group.id)

        #expect(store.verifyingGroupIDs == [])
        let verifiedNames = Set(verifiedItemNames(store: store))
        #expect(verifiedNames == Set(["a-match.bin", "b-match.bin"]))
    }

    // MARK: - Cancellation mid-verify

    @Test("cancel mid-verify discards partial results and surfaces no error")
    func cancelMidVerifyDiscardsPartialResults() async throws {
        // Same-size fixture; size doesn't matter here because the cancel below fires
        // before the verify Task ever begins executing (see rationale below).
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        var reportedErrors: [String] = []
        let store = OnDemandVerificationStore(
            hashCache: DuplicateHashCache(),
            scanLookup: { nil },
            coordinateInvalidate: { },
            reportError: { reportedErrors.append($0) }
        )

        let group = fixture.unverifiedGroup
        store.verify(group)

        // Cancel synchronously, before any `await` yields the main actor. `verify(_:)`
        // populates `verifyTasksByID`/`verifyCancellationsByID` on the main actor without
        // awaiting, so by the time we reach this line the outer verify Task is enqueued
        // but has not started. Marking the task cancelled here means its first instruction
        // (`try Task.checkCancellation()`) throws CancellationError, which the store maps
        // to FileSystemScannerError.cancelled — partial results are discarded and no error
        // is surfaced. Avoiding `Task.sleep` here keeps the assertion deterministic:
        // relying on a 5 ms window assumed the detached hash was still mid-flight, which
        // fails on runners that complete hashing before the sleep ends.
        let wasActive = store.cancelVerification(forGroupID: group.id)
        #expect(wasActive)

        try await waitForVerifyToSettle(store: store, groupID: group.id)

        // No verified groups after cancellation, and no error surfaced (cancellation is
        // a user action, not a failure).
        #expect(verifiedItemNames(store: store) == [])
        #expect(store.verifyingGroupIDs == [])
        #expect(reportedErrors == [])
    }

    @Test("cancelVerification returns false when group is not in flight")
    func cancelVerificationReturnsFalseForUnknownGroup() async throws {
        let store = OnDemandVerificationStore(
            hashCache: DuplicateHashCache(),
            scanLookup: { nil },
            coordinateInvalidate: { },
            reportError: { _ in }
        )

        #expect(store.cancelVerification(forGroupID: "nope") == false)
    }

    @Test("clear cancels in-flight verify and drops verified state")
    func clearCancelsInFlightVerify() async throws {
        let fixture = try makeFixture(fileSize: 4 * 1_048_576)
        defer { fixture.tearDown() }

        var reportedErrors: [String] = []
        let store = OnDemandVerificationStore(
            hashCache: DuplicateHashCache(),
            scanLookup: { nil },
            coordinateInvalidate: { },
            reportError: { reportedErrors.append($0) }
        )

        let group = fixture.unverifiedGroup
        store.verify(group)
        try await Task.sleep(for: .milliseconds(5))

        store.clear()

        try await waitForVerifyToSettle(store: store, groupID: group.id)

        #expect(store.verifiedGroupsByChecksum.isEmpty)
        #expect(store.verifyingGroupIDs.isEmpty)
        // clear() runs before the verify task finishes its MainActor.run, so the cancellation
        // path runs instead of the success path — no error should be reported for cancel.
        #expect(reportedErrors == [])
    }

    // MARK: - Persist failure reporting

    @Test("persist failure surfaces through reportError")
    func persistFailureSurfacesThroughReportError() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        // cacheURL points at a path whose parent is a regular file, so atomic write throws.
        let poisonedCacheURL = fixture.rootDiskFile.appendingPathComponent("cannot-be-a-directory.json")
        let hashCache = DuplicateHashCache(cacheURL: poisonedCacheURL)
        // Pre-seed one entry so persist has something it tries to encode + write.
        let key = DuplicateHashCache.LookupKey(
            path: "/tmp/seed.bin",
            byteSize: 1,
            modificationDate: Date(timeIntervalSince1970: 0)
        )
        hashCache.record(key, checksum: "deadbeef")

        var reportedErrors: [String] = []
        let store = OnDemandVerificationStore(
            hashCache: hashCache,
            scanLookup: { nil },
            coordinateInvalidate: { },
            reportError: { reportedErrors.append($0) }
        )

        let group = fixture.unverifiedGroup
        store.verify(group)

        // wait for the verify task; persist runs in its own Task after that.
        try await waitForVerifyToSettle(store: store, groupID: group.id)

        // Persist may still be in flight even after the main verify task settled. Poll until
        // either the error is reported or a generous timeout elapses.
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while reportedErrors.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }

        #expect(!reportedErrors.isEmpty)
        #expect(reportedErrors.first?.contains("verification cache") == true || reportedErrors.first?.contains("save") == true)
    }

    // MARK: - Successful verify path sanity

    @Test("verify merges verified groups and hits the cache on re-verify")
    func verifyMergesVerifiedGroups() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        let hashCache = DuplicateHashCache()
        let store = OnDemandVerificationStore(
            hashCache: hashCache,
            scanLookup: { nil },
            coordinateInvalidate: { },
            reportError: { _ in }
        )

        let group = fixture.unverifiedGroup
        store.verify(group)

        try await waitForVerifyToSettle(store: store, groupID: group.id)

        let verified = Array(store.verifiedGroupsByChecksum.values)
        #expect(verified.count == 1)
        let first = try #require(verified.first)
        #expect(Set(first.items.map(\.name)) == Set(["a-match.bin", "b-match.bin"]))
        #expect(!first.items.contains { $0.name == "c-nomatch.bin" })

        // Re-verifying the same group is a no-op because isGroupAlreadyVerified returns true.
        store.verify(group)
        try await Task.sleep(for: .milliseconds(20))
        // Still exactly one verified group; the no-op path didn't spawn a task.
        #expect(store.verifiedGroupsByChecksum.count == 1)
        #expect(store.verifyingGroupIDs.isEmpty)
    }

    // MARK: - Helpers

    private struct Fixture {
        let root: URL
        let unverifiedGroup: DuplicateSizeGroup
        let rootDiskFile: URL

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Builds three same-byte-size files in a temp dir, two sharing content and one diverging,
    /// then produces an unverified `DuplicateSizeGroup` (verifiedDuplicateGroups left empty
    /// via budget=0) so the on-demand store has real work to do.
    private func makeFixture(fileSize: Int = 4_096) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnDemandVerificationStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let sameData = Data(repeating: 0x99, count: fileSize)
        try sameData.write(to: root.appendingPathComponent("a-match.bin"))
        try sameData.write(to: root.appendingPathComponent("b-match.bin"))
        try Data(repeating: 0x01, count: fileSize).write(to: root.appendingPathComponent("c-nomatch.bin"))

        let scan = try FileSystemScanner().scan(
            root: root,
            options: ScanOptions(
                duplicateCandidateThreshold: 1,
                duplicateVerificationByteLimit: 0,
                maxDuplicateVerificationFiles: 0
            )
        )

        let group = try #require(scan.duplicateSizeGroups.first)
        #expect(scan.verifiedDuplicateGroups.isEmpty)

        // Write a regular file in the fixture root so the persist-failure test can point
        // the cache URL at a path whose parent is a file, which forces an atomic-write error.
        let rootDiskFile = root.appendingPathComponent("root-disk-file-marker.txt")
        try Data("marker".utf8).write(to: rootDiskFile)

        return Fixture(
            root: root,
            unverifiedGroup: group,
            rootDiskFile: rootDiskFile
        )
    }

    /// Spins the runloop until the verify task for `groupID` has settled out of
    /// `verifyingGroupIDs` (i.e. either finished successfully or cancelled).
    private func waitForVerifyToSettle(store: OnDemandVerificationStore, groupID: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while store.verifyingGroupIDs.contains(groupID) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!store.verifyingGroupIDs.contains(groupID), "verify task for \(groupID) did not settle in time")
    }

    private func verifiedItemNames(store: OnDemandVerificationStore) -> [String] {
        store.verifiedGroupsByChecksum.values.flatMap { $0.items.map(\.name) }
    }
}