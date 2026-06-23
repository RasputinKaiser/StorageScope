import Foundation
import Testing
@testable import StorageScope

@MainActor
@Suite("ScanStore cancellation")
struct ScanStoreCancellationTests {
    @Test("cancels an in-flight scan without surfacing an error")
    func cancelMidScan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<300 {
            let url = root.appendingPathComponent("file-\(index).bin", isDirectory: false)
            try Data(repeating: UInt8(index % 255), count: 32_768).write(to: url)
        }

        let store = ScanStore()
        store.scanDeveloperFixturePath(root.path)

        try await Task.sleep(for: .milliseconds(50))

        // Scan completed before cancellation window; nothing to assert.
        guard store.isScanning else {
            return
        }

        store.cancelScan()
        try await Task.sleep(for: .milliseconds(200))

        #expect(store.isScanning == false)
        #expect(store.errorMessage == nil)
        #expect(store.scan == nil)
        #expect(store.progress.currentPath == "Scan cancelled")
    }

    @Test("rapid rescans during an in-flight scan are no-ops")
    func rescanDuringRescanIsNoOp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<300 {
            let url = root.appendingPathComponent("file-\(index).bin", isDirectory: false)
            try Data(repeating: UInt8(index % 255), count: 32_768).write(to: url)
        }

        let store = ScanStore()
        store.scanDeveloperFixturePath(root.path)

        try await Task.sleep(for: .milliseconds(50))

        guard store.isScanning else {
            return // Scan completed too quickly to exercise the in-flight guard.
        }

        // Multiple rapid rescans while the first scan is still running. With the
        // re-entry guard each call is a no-op; without the guard they would either
        // race a second scan against the first or fall through to NSOpenPanel (no
        // security-scoped bookmark exists for a fixture path), blocking the test.
        store.rescan()
        store.rescan()
        store.rescan()

        // The guard short-circuited: no error message set, no replacement launched.
        #expect(store.errorMessage == nil)
        #expect(store.isScanning == true)

        for _ in 0..<50 {
            if !store.isScanning { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(store.isScanning == false)
        #expect(store.errorMessage == nil)
        #expect(store.scan != nil)
        #expect(store.scan?.rootURL.standardizedFileURL == root.standardizedFileURL)
        #expect(store.progress.currentPath == "Scan complete")
    }

    @Test("scanRecentPath during an in-flight scan is a no-op (stale-bookmark path is skipped)")
    func scanRecentPathWhileScanningIsNoOp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<300 {
            let url = root.appendingPathComponent("file-\(index).bin", isDirectory: false)
            try Data(repeating: UInt8(index % 255), count: 32_768).write(to: url)
        }

        let store = ScanStore()
        store.scanDeveloperFixturePath(root.path)

        try await Task.sleep(for: .milliseconds(50))

        guard store.isScanning else {
            return // Scan completed too quickly to exercise the in-flight guard.
        }

        // Without the guard, scanRecentPath on an unknown path would fall through to
        // bookmarkStore.resolve(), find no bookmark, set errorMessage and open
        // NSOpenPanel modal (blocking the test). The re-entry guard short-circuits
        // before any of that, so the in-flight scan runs to completion undisturbed.
        let neverRememberedPath = "/some/path/with/no/bookmark-\(UUID().uuidString)"
        store.scanRecentPath(neverRememberedPath)

        #expect(store.errorMessage == nil)
        #expect(store.isScanning == true)

        for _ in 0..<50 {
            if !store.isScanning { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(store.isScanning == false)
        #expect(store.errorMessage == nil)
        #expect(store.scan != nil)
        #expect(store.scan?.rootURL.standardizedFileURL == root.standardizedFileURL)
        #expect(store.progress.currentPath == "Scan complete")
    }

    @Test("cancelling a rescan mid-flight does not surface an error")
    func cancelledRescanSurfacesNoError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<300 {
            let url = root.appendingPathComponent("file-\(index).bin", isDirectory: false)
            try Data(repeating: UInt8(index % 255), count: 32_768).write(to: url)
        }

        let store = ScanStore()
        store.scanDeveloperFixturePath(root.path)

        // Wait for the initial scan to complete so the subsequent call is a true
        // "rescan" rather than the first scan. Both routes go through scan(_:URL),
        // but this pattern matches the spec wording.
        for _ in 0..<50 {
            if !store.isScanning { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(store.scan != nil)
        let priorFinishedAt = store.scan?.finishedAt

        store.scanDeveloperFixturePath(root.path) // Re-scan.
        try await Task.sleep(for: .milliseconds(50))

        guard store.isScanning else {
            return // Completed too fast to test cancellation.
        }

        store.cancelScan()
        try await Task.sleep(for: .milliseconds(200))

        #expect(store.isScanning == false)
        #expect(store.errorMessage == nil)
        // Previous results are preserved after cancelling the rescan.
        #expect(store.scan?.finishedAt == priorFinishedAt)
        #expect(store.progress.currentPath == "Scan cancelled")
        // The dismissible cancellation notice replaces the prior scan-complete notice.
        #expect(store.scanNoticeIsDismissible == true)
    }

    @Test("scanner error surfaces and the progress-consumer never blocks the task group")
    func scannerErrorSurfacesWithoutDeadlock() async throws {
        // Point `scan(_:)` at a path that does not exist on disk. The scanner
        // throws `FileSystemScannerError.rootDoesNotExist` synchronously, not
        // `cancelled`. With the TaskGroup refactor the producer's `defer
        // { progressContinuation.finish() }` is the only thing that unblocks the
        // progress consumer — without it the group would wait forever and this
        // test would hang until the suite times out.
        let store = ScanStore()
        store.scanDeveloperFixturePath("/this/path/definitely/does/not/exist-\(UUID().uuidString)")

        for _ in 0..<50 {
            if !store.isScanning { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(store.isScanning == false)
        #expect(store.scan == nil)
        // The error message is surfaced to the alert (this is a user-actionable
        // failure, not a cancel — cancel would have left errorMessage as nil).
        #expect(store.errorMessage?.isEmpty == false)
    }
}
