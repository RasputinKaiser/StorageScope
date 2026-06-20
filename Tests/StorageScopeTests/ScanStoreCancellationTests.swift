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
}