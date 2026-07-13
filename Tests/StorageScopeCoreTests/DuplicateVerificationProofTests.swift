import Foundation
import Testing
@testable import StorageScopeCore

@Suite("Phase 4 duplicate verification proof", .serialized)
struct DuplicateVerificationProofTests {
    @Test("realistic corpus measures byte, cache, hard-link, mutation, cancellation, and descriptor gates")
    func realisticCorpusEstablishesAcceptanceSurface() throws {
        let fixture = try DuplicateVerificationProofFixture.create(largeCandidateBytes: 1 * 1_024 * 1_024)
        defer { fixture.remove() }

        #expect(fixture.candidateFileCount == 54)
        #expect(fixture.naiveFullHashBytes > 48 * 1_000_000)
        let extensions = try Set(
            FileManager.default.subpathsOfDirectory(atPath: fixture.rootURL.path)
                .map { URL(fileURLWithPath: $0).pathExtension.lowercased() }
        )
        #expect(extensions.isSuperset(of: ["mov", "mp4", "dmg", "vmdk", "qcow2", "img"]))

        let originalAttributes = try FileManager.default.attributesOfItem(atPath: fixture.hardLinkURLs[0].path)
        let aliasAttributes = try FileManager.default.attributesOfItem(atPath: fixture.hardLinkURLs[1].path)
        #expect(originalAttributes[.systemFileNumber] as? NSNumber == aliasAttributes[.systemFileNumber] as? NSNumber)
        #expect((originalAttributes[.referenceCount] as? NSNumber)?.intValue ?? 0 >= 2)

        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StorageScopeDuplicateProofCacheTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cacheURL = cacheDirectory.appendingPathComponent("hashes.json")
        let coldCache = DuplicateHashCache(cacheURL: cacheURL)
        let options = ScanOptions.benchmarkDefaults()
        let coldScan = try FileSystemScanner(hashCache: coldCache).scan(
            root: fixture.rootURL,
            options: options
        )

        let maximumProofBytes = fixture.naiveFullHashBytes / 10
        #expect(coldScan.duplicateVerificationBytesRead <= maximumProofBytes)
        #expect(coldScan.duplicateVerificationPeakOpenFiles > 0)
        #expect(coldScan.duplicateVerificationPeakOpenFiles <= 6)

        let exactDuplicateNames = Set(fixture.exactDuplicateURLs.map(\.lastPathComponent))
        let verifiedNameSets = coldScan.verifiedDuplicateGroups.map { Set($0.items.map(\.name)) }
        #expect(verifiedNameSets.contains(exactDuplicateNames))

        let hardLinkPaths = Set(fixture.hardLinkURLs.map { $0.standardizedFileURL.path })
        let candidatePaths = Set(coldScan.duplicateSizeGroups.flatMap(\.items).map { $0.url.standardizedFileURL.path })
        let verifiedPaths = Set(coldScan.verifiedDuplicateGroups.flatMap(\.items).map { $0.url.standardizedFileURL.path })
        let hardLinksExcludedFromCandidates = candidatePaths.isDisjoint(with: hardLinkPaths)
        let hardLinksExcludedFromVerifiedGroups = verifiedPaths.isDisjoint(with: hardLinkPaths)
        withKnownIssue("Phase 4 must exclude hard-link aliases before duplicate verification") {
            #expect(hardLinksExcludedFromCandidates)
            #expect(hardLinksExcludedFromVerifiedGroups)
        }

        coldCache.persist()
        let warmCache = DuplicateHashCache(cacheURL: cacheURL)
        let warmScan = try FileSystemScanner(hashCache: warmCache).scan(
            root: fixture.rootURL,
            options: options
        )
        #expect(warmScan.duplicateVerificationBytesRead < coldScan.duplicateVerificationBytesRead)
        withKnownIssue("Phase 4 must persist prefix digests so a cold-process warm cache performs zero reads") {
            #expect(warmScan.duplicateVerificationBytesRead == 0)
        }

        let exactGroup = try #require(
            coldScan.duplicateSizeGroups.first { group in
                Set(group.items.map(\.name)) == exactDuplicateNames
            }
        )
        let changedURL = fixture.exactDuplicateURLs[1]
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 120)],
            ofItemAtPath: changedURL.path
        )
        let changedResult = try FileSystemScanner().verifySizeGroup(exactGroup)
        let changedFileWasRejected = changedResult.isEmpty
        withKnownIssue("Phase 4 must reject a file whose metadata changed after enumeration and before hashing") {
            #expect(changedFileWasRejected)
        }

        let largeGroup = try #require(
            coldScan.duplicateSizeGroups.first { $0.byteSize == 1 * 1_024 * 1_024 }
        )
        let cancellation = ScanCancellation()
        cancellation.cancel()
        #expect(throws: FileSystemScannerError.self) {
            _ = try FileSystemScanner().verifySizeGroup(largeGroup, cancellation: cancellation)
        }
    }

    @Test("benchmark CLI exposes the reusable duplicate proof mode")
    func benchmarkCLIExposesDuplicateProofMode() throws {
        let repoRoot = try repositoryRoot()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/StorageScopeBenchmark/main.swift"),
            encoding: .utf8
        )

        #expect(source.contains("--duplicate-proof"))
        #expect(source.contains("Naive full-hash bytes:"))
        #expect(source.contains("Verification byte reduction:"))
    }

    private func repositoryRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
