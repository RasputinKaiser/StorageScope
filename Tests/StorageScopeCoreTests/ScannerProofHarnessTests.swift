import Foundation
import Testing
@testable import StorageScopeCore

struct ScannerProofHarnessTests {
    @Test("differential harness covers deep and wide directory shapes")
    func deepAndWideFixtureHasStableParity() throws {
        let fixture = try ScannerProofFixture.make(.deepAndWide)
        defer { fixture.tearDown() }

        let signature = try ScannerProofHarness.compare(
            fixture,
            baseline: ScannerProofHarness.legacyRunner,
            candidate: ScannerProofHarness.fixedWorkerRunner,
            context: "deep and wide fixture"
        )

        #expect(signature.scannedItemCount > 500)
        #expect(signature.root.maxDepth >= 17)
        #expect(signature.root.maxWidth >= 64)
        #expect(signature.inaccessibleItemCount == 0)
    }

    @Test("differential harness compares every mutation-heavy state")
    func mutationHeavyFixtureHasStableParity() throws {
        let fixture = try ScannerProofFixture.make(.mutationHeavy)
        defer { fixture.tearDown() }

        let signatures = try ScannerProofHarness.compareMutationSequence(
            fixture,
            baseline: ScannerProofHarness.legacyRunner,
            candidate: ScannerProofHarness.fixedWorkerRunner
        )

        #expect(signatures.count == fixture.mutations.count + 1)
        #expect(signatures.first?.treePaths.contains("mutation/branch-00/file-00.dat") == true)
        #expect(signatures.last?.treePaths.contains("mutation/renamed-branch-00/roundtrip.dat") == true)
        #expect(signatures.last?.treePaths.contains("mutation/received/new-00.dat") == false)
        #expect(signatures.first?.treePaths != signatures.last?.treePaths)
    }

    @Test("differential harness preserves hard-link fixture semantics")
    func hardLinkFixtureHasStableParity() throws {
        let fixture = try ScannerProofFixture.make(.hardLinks)
        defer { fixture.tearDown() }

        let signature = try ScannerProofHarness.compare(
            fixture,
            baseline: ScannerProofHarness.legacyRunner,
            candidate: ScannerProofHarness.fixedWorkerRunner,
            context: "hard-link fixture"
        )
        let pair = try #require(fixture.hardLinkPair)

        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: pair.source.path)
        let aliasAttributes = try FileManager.default.attributesOfItem(atPath: pair.alias.path)
        let sourceFileNumber = try #require(sourceAttributes[.systemFileNumber] as? NSNumber)
        let aliasFileNumber = try #require(aliasAttributes[.systemFileNumber] as? NSNumber)

        #expect(sourceFileNumber == aliasFileNumber)
        #expect(signature.duplicateSizeGroups.contains { group in
            group.paths.contains(ScannerProofHarness.relativePath(pair.source, from: fixture.root)) &&
                group.paths.contains(ScannerProofHarness.relativePath(pair.alias, from: fixture.root))
        })
    }

    @Test("compact worker keeps cleanup candidate parity")
    func cleanupCandidateFixtureHasStableParity() throws {
        let fixture = try ScannerProofFixture.make(.cleanupCandidates)
        defer { fixture.tearDown() }

        let signature = try ScannerProofHarness.compare(
            fixture,
            baseline: ScannerProofHarness.legacyRunner,
            candidate: ScannerProofHarness.fixedWorkerRunner,
            context: "cleanup-candidate fixture"
        )

        let candidateKeys = Set(signature.cleanupCandidates.map { "\($0.kind):\($0.path)" })
        #expect(candidateKeys.contains("cacheFolder:Caches"))
        #expect(candidateKeys.contains("buildArtifact:DerivedData"))
        #expect(candidateKeys.contains("archive:archives/archive.zip"))
        #expect(candidateKeys.contains("diskImage:installers/installer.dmg"))
        #expect(candidateKeys.contains("temporary:temporary.tmp"))
    }

    @Test("permission-loss fixture becomes an inaccessible leaf without crashing")
    func permissionLossFixtureHasStableParity() throws {
        let fixture = try ScannerProofFixture.make(.permissionLoss)
        defer { fixture.tearDown() }

        let signature = try ScannerProofHarness.compare(
            fixture,
            baseline: ScannerProofHarness.legacyRunner,
            candidate: ScannerProofHarness.fixedWorkerRunner,
            context: "permission-loss fixture"
        )
        let fault = try #require(fixture.fault)
        let faultPath = fixture.root.appendingPathComponent(fault.relativePath)
        let scan = try ScannerProofHarness.scan(
            fixture,
            runner: ScannerProofHarness.fixedWorkerRunner
        )
        let item = try #require(scan.rootItem.flattened().first {
            ScannerProofHarness.relativePath($0.url, from: fixture.root) == fault.relativePath
        })

        #expect(fault.kind == .permissionLoss)
        #expect(signature.inaccessibleItemCount > 0)
        #expect(item.kind == .inaccessible)
        #expect(item.children.isEmpty)
        #expect(FileManager.default.fileExists(atPath: faultPath.path))
    }

    @Test("volume-loss fixture becomes an inaccessible leaf without crashing")
    func volumeLossFixtureHasStableParity() throws {
        let fixture = try ScannerProofFixture.make(.volumeLoss)
        defer { fixture.tearDown() }

        let signature = try ScannerProofHarness.compare(
            fixture,
            baseline: ScannerProofHarness.legacyRunner,
            candidate: ScannerProofHarness.fixedWorkerRunner,
            context: "volume-loss fixture"
        )
        let fault = try #require(fixture.fault)
        let scan = try ScannerProofHarness.scan(
            fixture,
            runner: ScannerProofHarness.fixedWorkerRunner
        )
        let item = try #require(scan.rootItem.flattened().first {
            ScannerProofHarness.relativePath($0.url, from: fixture.root) == fault.relativePath
        })

        #expect(fault.kind == .volumeLoss)
        #expect(signature.inaccessibleItemCount > 0)
        #expect(item.kind == .inaccessible)
        #expect(item.children.isEmpty)
    }

    @Test("fixed-worker walker pauses before work and resumes to completion")
    func fixedWorkerPauseResumeCompletes() throws {
        let fixture = try ScannerProofFixture.make(.deepAndWide)
        defer { fixture.tearDown() }

        let cancellation = ScanCancellation()
        let outcome = ProofScanOutcome()
        let scanner = FileSystemScanner(
            fileManager: FileManager(),
            walkerMode: .fixedWorker
        )
        let options = ScanOptions(
            duplicateVerificationByteLimit: 0,
            maxDuplicateVerificationFiles: 0
        )

        cancellation.pause()
        let thread = Thread {
            do {
                _ = try scanner.scan(
                    root: fixture.root,
                    options: options,
                    cancellation: cancellation
                )
                outcome.set(.completed)
            } catch {
                outcome.set(.failed(error))
            }
        }
        thread.start()

        Thread.sleep(forTimeInterval: 0.05)
        #expect(outcome.value == nil)
        cancellation.resume()
        waitForOutcome(outcome)

        switch outcome.value {
        case .completed:
            break
        case .failed(let error):
            Issue.record("Expected fixed-worker scan to resume, got \(error).")
        case nil:
            Issue.record("Fixed-worker scan did not complete after resume.")
        }
    }

    @Test("fixed-worker walker cancels while paused without deadlocking")
    func fixedWorkerCancelWhilePausedTerminates() throws {
        let fixture = try ScannerProofFixture.make(.deepAndWide)
        defer { fixture.tearDown() }

        let cancellation = ScanCancellation()
        let outcome = ProofScanOutcome()
        let scanner = FileSystemScanner(
            fileManager: FileManager(),
            walkerMode: .fixedWorker
        )
        let options = ScanOptions(
            duplicateVerificationByteLimit: 0,
            maxDuplicateVerificationFiles: 0
        )

        cancellation.pause()
        let thread = Thread {
            do {
                _ = try scanner.scan(
                    root: fixture.root,
                    options: options,
                    cancellation: cancellation
                )
                outcome.set(.completed)
            } catch {
                outcome.set(.failed(error))
            }
        }
        thread.start()

        Thread.sleep(forTimeInterval: 0.05)
        #expect(outcome.value == nil)
        cancellation.cancel()
        waitForOutcome(outcome)

        switch outcome.value {
        case .failed(let error):
            if case FileSystemScannerError.cancelled = error {
                break
            }
            Issue.record("Expected FileSystemScannerError.cancelled, got \(error).")
        case .completed:
            Issue.record("Expected fixed-worker scan to cancel while paused.")
        case nil:
            Issue.record("Fixed-worker scan did not terminate after cancellation.")
        }
    }

    private func waitForOutcome(_ outcome: ProofScanOutcome) {
        let deadline = Date().addingTimeInterval(5)
        while outcome.value == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}

private enum ProofScanResult {
    case completed
    case failed(Error)
}

private final class ProofScanOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var result: ProofScanResult?

    var value: ProofScanResult? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    func set(_ result: ProofScanResult) {
        lock.lock()
        self.result = result
        lock.unlock()
    }
}
