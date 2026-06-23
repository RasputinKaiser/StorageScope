import Foundation
import Testing
@testable import StorageScope
import StorageScopeCore

@MainActor
@Suite("ScanStore error handling")
struct ScanStoreErrorHandlingTests {
    @Test("cancellation returns nil so the caller suppresses the alert")
    func cancellationReturnsNil() {
        let category = ScanStore.categorize(FileSystemScannerError.cancelled)
        #expect(category == nil)
    }

    @Test("missing root surfaces with the affected folder path")
    func missingFolderIncludesPath() throws {
        let url = URL(fileURLWithPath: "/tmp/storagescope-tester/does-not-exist", isDirectory: true)
        let category = try #require(ScanStore.categorize(FileSystemScannerError.rootDoesNotExist(url)))
        #expect(category == .missingFolder(path: url.path))
        #expect(category.userMessage.contains(url.path))
    }

    @Test("permission-denied bookmark errors include the affected URL")
    func permissionDeniedIncludesURL() throws {
        let url = URL(fileURLWithPath: "/tmp/storagescope-tester/restricted", isDirectory: true)
        let category = try #require(ScanStore.categorize(BookmarkError.accessDenied(url)))
        #expect(category == .permissionDenied(path: url.path))
        #expect(category.userMessage.contains(url.path))
    }

    @Test("NSCocoa bookmark decode error maps to stale category when path is known")
    func staleBookmarkCategoryForDecodeError() throws {
        let corruptData = Data("not-a-bookmark".utf8)
        do {
            var stale = false
            _ = try URL(
                resolvingBookmarkData: corruptData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            Issue.record("URL.init(resolvingBookmarkData:) should throw on corrupt data")
        } catch {
            let path = "/tmp/storagescope-tester/folder-bookmark"
            let category = try #require(ScanStore.categorize(error, fallbackPath: path))
            #expect(category == .staleBookmark(path: path))
            #expect(category.userMessage.contains(path))
        }
    }

    @Test("unknown error falls back to scanInternal and attaches the path when provided")
    func unknownErrorAttachesFallbackPath() throws {
        struct MysteryError: Error {}
        let category = try #require(ScanStore.categorize(MysteryError(), fallbackPath: "/tmp/storagescope-tester/scans/inbox"))
        if case .scanInternal(let message) = category {
            #expect(message.contains("/tmp/storagescope-tester/scans/inbox"))
        } else {
            Issue.record("expected .scanInternal, got \(category)")
        }
    }

    @Test("scanning a non-existent path surfaces missingFolder and clears on next scan")
    func missingFolderRescanSurfaceAndClear() async throws {
        let store = ScanStore()
        let deadPath = "/tmp/storagescope-missing-\(UUID().uuidString)"
        #expect(!FileManager.default.fileExists(atPath: deadPath))

        store.scanDeveloperFixturePath(deadPath)
        try await Self.waitFor { store.errorMessage != nil || store.session.lastErrorCategory != nil }
        #expect(store.errorMessage != nil)
        #expect(store.isScanning == false)
        let category = try #require(store.session.lastErrorCategory)
        if case .missingFolder(let path) = category {
            #expect(path == deadPath)
        } else {
            Issue.record("expected .missingFolder, got \(category)")
        }
        #expect(store.errorMessage?.contains(deadPath) == true)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("storagescope-err-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("placeholder.txt"))

        store.scanDeveloperFixturePath(root.path)
        #expect(store.errorMessage == nil)
        #expect(store.session.lastErrorCategory == nil)
    }

    @Test("persisted stale bookmark data rescan throws through the catch and surfaces")
    func persistedStaleBookmarkRescan() throws {
        // Inject corrupt bookmark bytes that SecurityScopedBookmarkStore.resolve cannot
        // decode. Then exercise the same `bookmarkStore.resolve` → `Self.categorize` chain
        // `scanRecentPath` would run on a real rescan attempt, without opening NSOpenPanel:
        // NSOpenPanel only opens inside `chooseFolderAndScan` (the recovery UI path). We
        // can't drive the recovery UI in a sandboxed unit test, so we stop at the catch —
        // which is the load-bearing part: the error is classified as staleBookmark with the
        // affected path so the user-facing alert names the folder StorageScope can't reopen.
        let path = "/tmp/storagescope-stale-\(UUID().uuidString)"
        #expect(!FileManager.default.fileExists(atPath: path))
        let corruptData = Data("corrupt-bookmark".utf8)
        let bookmarkStore = SecurityScopedBookmarkStore()
        bookmarkStore.storeBookmarkData(corruptData, for: path)

        do {
            _ = try bookmarkStore.resolve(path: path)
            Issue.record("expected resolve to throw on corrupt bookmark data")
        } catch {
            let category = try #require(ScanStore.categorize(error, fallbackPath: path))
            #expect(category == .staleBookmark(path: path))
            #expect(category.userMessage.contains(path))
            // Stale-category message tells the user how to recover.
            #expect(category.userMessage.contains("Choose it again"))
        }

        // After resolve throws, SecurityScopedBookmarkStore prunes the bad entry so the
        // next call returns nil (not throws). This is what lets the next scanRecentPath
        // attempt skip the corrupt bookmark and prompt for re-grant rather than rethrow.
        let resolved = try bookmarkStore.resolve(path: path)
        #expect(resolved == nil)
    }

    @Test("cancellation is silent — no errorMessage, no lastErrorCategory")
    func cancellationSilent() async throws {
        let store = ScanStore()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("storagescope-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<400 {
            try Data(repeating: UInt8(i % 255), count: 32_768).write(to: root.appendingPathComponent("f-\(i).bin"))
        }

        store.scanDeveloperFixturePath(root.path)
        try await Task.sleep(for: .milliseconds(50))

        guard store.isScanning else {
            #expect(store.errorMessage == nil)
            return
        }

        store.cancelScan()
        try await Task.sleep(for: .milliseconds(200))

        #expect(store.isScanning == false)
        #expect(store.errorMessage == nil)
        #expect(store.session.lastErrorCategory == nil)
        #expect(store.progress.currentPath == "Scan cancelled")
    }

    private static func waitFor(
        _ predicate: @MainActor @Sendable () -> Bool,
        timeout: Duration = .seconds(5)
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await MainActor.run(body: predicate) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("predicate never became true within \(timeout)")
    }
}