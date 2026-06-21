import Foundation
import Testing
@testable import StorageScope
@testable import StorageScopeCore

@MainActor
@Suite("ScanStore keeper and ignore")
struct ScanStoreKeeperAndIgnoreTests {
    @Test("keeper override and isKeeper reflect assignment")
    func keeperOverrideReflectsAssignment() async throws {
        let (store, group) = try await makeStoreWithVerifiedGroup()
        guard let firstID = group.items.first?.id,
              let secondID = group.items.dropFirst().first?.id else {
            Issue.record("Expected at least two items in verified group")
            return
        }

        #expect(store.keeperItemID(for: group) == firstID)
        #expect(store.isKeeper(firstID, in: group) == true)
        #expect(store.isKeeper(secondID, in: group) == false)

        store.setKeeper(itemID: secondID, for: group)
        #expect(store.keeperItemID(for: group) == secondID)
        #expect(store.isKeeper(secondID, in: group) == true)
        #expect(store.isKeeper(firstID, in: group) == false)
    }

    @Test("ignore then unignore restores a candidate to the review list")
    func ignoreThenUnignoreRestoresCandidate() async throws {
        let store = try await makeStoreWithCleanupCandidates()
        guard let candidate = store.cleanupCandidates.first else {
            Issue.record("Expected at least one cleanup candidate")
            return
        }
        let id = candidate.id

        store.ignoreCleanupCandidate(candidate)
        #expect(store.cleanupCandidates.allSatisfy { $0.id != id })
        #expect(store.ignoredCleanupCandidates.contains { $0.id == id })

        store.unignoreCleanupCandidate(candidate)
        #expect(store.cleanupCandidates.contains { $0.id == id })
        #expect(store.ignoredCleanupCandidates.allSatisfy { $0.id != id })

        store.ignoreCleanupCandidate(candidate)
        store.clearIgnoredCleanupCandidates()
        #expect(store.ignoredCleanupCandidates.isEmpty)
        #expect(store.cleanupCandidates.contains { $0.id == id })
    }

    @Test("scan stage and recent-scan metadata update after a fixture scan")
    func scanStageAndRecentScanMetadataUpdateAfterScan() async throws {
        let store = ScanStore()
        #expect(store.scanStage == .idle)

        let root = try makeFixtureRoot()
        store.scanDeveloperFixturePath(root.path)
        try await waitForScan(store: store)

        guard let scan = store.scan else {
            Issue.record("Scan did not complete")
            return
        }
        #expect(store.scanStage == .complete)
        #expect(store.recents.entries.first?.path == root.standardizedFileURL.path)
        #expect(store.recents.entries.first?.totalBytes == scan.totalBytes)
        #expect(store.recents.entries.first?.path == root.standardizedFileURL.path)
    }

    private func makeStoreWithVerifiedGroup() async throws -> (ScanStore, VerifiedDuplicateGroup) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageScopeKeeper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // ScanStore.scan uses ScanOptionPolicy.interactiveScanThresholds(), which sets
        // duplicateCandidateThreshold to 100 MB. Use sparse files just over that threshold so
        // duplicate candidate capture and SHA-256 verification both run, without writing 200 MB.
        try writeSparseDuplicate(at: root.appendingPathComponent("copy-a.bin"), bytes: 101_000_000, seed: 0x41)
        try writeSparseDuplicate(at: root.appendingPathComponent("copy-b.bin"), bytes: 101_000_000, seed: 0x41)

        let store = ScanStore()
        store.scanDeveloperFixturePath(root.path)
        try await waitForScan(store: store)

        guard let scan = store.scan, !scan.verifiedDuplicateGroups.isEmpty,
              let group = scan.verifiedDuplicateGroups.first(where: { $0.items.count > 1 }) else {
            Issue.record("Expected at least one verified duplicate group with multiple items")
            return (store, VerifiedDuplicateGroup(checksum: "none", byteSize: 0, items: []))
        }
        return (store, group)
    }

    private func writeSparseDuplicate(at url: URL, bytes: Int64, seed: UInt8) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(repeating: seed, count: 16))
        try handle.truncate(atOffset: UInt64(bytes))
    }

    private func makeStoreWithCleanupCandidates() async throws -> ScanStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageScopeIgnore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(5))
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(repeating: 9, count: 1_000_000).write(to: root.appendingPathComponent("installer.pkg"))

        let store = ScanStore()
        store.scanDeveloperFixturePath(root.path)
        try await waitForScan(store: store)
        return store
    }

    private func makeFixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageScopeFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 9, count: 1_000_000).write(to: root.appendingPathComponent("installer.pkg"))
        return root
    }

    private func waitForScan(store: ScanStore) async throws {
        for _ in 0..<50 {
            if !store.isScanning { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}