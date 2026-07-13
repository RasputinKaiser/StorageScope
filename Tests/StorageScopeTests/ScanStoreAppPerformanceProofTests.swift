import Foundation
import Testing
@testable import StorageScope
@testable import StorageScopeCore

private let appPerformanceProofEnabled =
    ProcessInfo.processInfo.environment["STORAGESCOPE_RUN_APP_PERF_PROOF"] == "1"

@MainActor
@Suite("ScanStore app performance proof")
struct ScanStoreAppPerformanceProofTests {
    @Test(
        "release app path stays within 15 percent of callback-free scanner",
        .enabled(if: appPerformanceProofEnabled)
    )
    func appPathStaysWithinBenchmarkGate() async throws {
        let environment = ProcessInfo.processInfo.environment
        let itemCount = environment["STORAGESCOPE_APP_PERF_ITEMS"].flatMap(Int.init) ?? 100_000
        let runCount = max(1, environment["STORAGESCOPE_APP_PERF_RUNS"].flatMap(Int.init) ?? 3)
        let root = try SyntheticBenchmarkFixture.create(
            items: itemCount,
            depth: 5,
            duplicateRatio: 0.1
        )
        defer { SyntheticBenchmarkFixture.remove(root) }

        let store = ScanStore()
        let options = store.makeScannerOptions()
        var callbackFreeDurations: [TimeInterval] = []
        var appDurations: [TimeInterval] = []
        var scannerDurations: [TimeInterval] = []
        var snapshotCounts: [Int] = []

        for runIndex in 0..<runCount {
            if runIndex.isMultiple(of: 2) {
                callbackFreeDurations.append(try measureCallbackFreeScan(root: root, options: options))
                let appRun = try await measureAppScan(store: store, root: root)
                appDurations.append(appRun.wallDuration)
                scannerDurations.append(appRun.scannerDuration)
                snapshotCounts.append(appRun.snapshotCount)
            } else {
                let appRun = try await measureAppScan(store: store, root: root)
                appDurations.append(appRun.wallDuration)
                scannerDurations.append(appRun.scannerDuration)
                snapshotCounts.append(appRun.snapshotCount)
                callbackFreeDurations.append(try measureCallbackFreeScan(root: root, options: options))
            }
        }

        let callbackFreeMedian = median(callbackFreeDurations)
        let appMedian = median(appDurations)
        let scannerMedian = median(scannerDurations)
        let ratio = appMedian / callbackFreeMedian
        let snapshotSummary = snapshotCounts.map(String.init).joined(separator: ",")
        print(String(
            format: "APP_SCAN_PERF items=%d runs=%d callback_free_median=%.3f app_median=%.3f scanner_median=%.3f ratio=%.3f snapshots=%@",
            itemCount,
            runCount,
            callbackFreeMedian,
            appMedian,
            scannerMedian,
            ratio,
            snapshotSummary
        ))

        #expect(snapshotCounts.allSatisfy { $0 > 0 })
        #expect(
            ratio <= 1.15,
            "App median \(appMedian)s exceeded callback-free median \(callbackFreeMedian)s by more than 15%"
        )
    }

    private func measureCallbackFreeScan(root: URL, options: ScanOptions) throws -> TimeInterval {
        let startedAt = Date()
        _ = try FileSystemScanner().scan(root: root, options: options)
        return Date().timeIntervalSince(startedAt)
    }

    private func measureAppScan(
        store: ScanStore,
        root: URL
    ) async throws -> (wallDuration: TimeInterval, scannerDuration: TimeInterval, snapshotCount: Int) {
        let startedAt = Date()
        store.scanDeveloperFixturePath(root.path)
        let deadline = ContinuousClock.now + .seconds(60)
        while store.isScanning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        guard !store.isScanning else {
            throw AppPerformanceProofError.timedOut
        }
        guard let scan = store.scan else {
            throw AppPerformanceProofError.missingScan
        }
        if let errorMessage = store.errorMessage {
            throw AppPerformanceProofError.scanFailed(errorMessage)
        }
        return (
            Date().timeIntervalSince(startedAt),
            scan.enumerateDuration,
            scan.snapshotBuildCount
        )
    }

    private func median(_ values: [TimeInterval]) -> TimeInterval {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

private enum AppPerformanceProofError: Error {
    case timedOut
    case missingScan
    case scanFailed(String)
}
