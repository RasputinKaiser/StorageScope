import Foundation
import Testing
@testable import StorageScope

@Suite("SecurityScopedBookmarkStore")
struct SecurityScopedBookmarkStoreTests {
    @Test("prune removes bookmarks that cannot resolve")
    func pruneRemovesUnresolvableBookmarks() throws {
        let suiteName = "StorageScopeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let deadPath = "/tmp/storagescope-dead-bookmark-\(UUID().uuidString)"
        let store = SecurityScopedBookmarkStore(defaults: defaults)
        store.storeBookmarkData(Data("not-a-bookmark".utf8), for: deadPath)

        store.prune()

        #expect(store.storedBookmarkPaths.isEmpty)
    }

    @Test("fresh store exposes no bookmark paths")
    func freshStoreExposesNoPaths() throws {
        let suiteName = "StorageScopeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SecurityScopedBookmarkStore(defaults: defaults)

        #expect(store.storedBookmarkPaths.isEmpty)
    }

    @Test("resolve returns nil for unknown path without throwing")
    func resolveReturnsNilForUnknownPath() throws {
        let suiteName = "StorageScopeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SecurityScopedBookmarkStore(defaults: defaults)
        let unknownPath = "/tmp/storagescope-unknown-\(UUID().uuidString)"

        let resolved = try store.resolve(path: unknownPath)

        #expect(resolved == nil)
        #expect(store.storedBookmarkPaths.isEmpty)
    }

    @Test("remember round-trips and resolves a non-stale bookmark")
    func rememberRoundTripsNonStaleBookmark() throws {
        let suiteName = "StorageScopeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempDir = try makeTempDir()
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let expectedPath = tempDir.standardizedFileURL.path
        let store = SecurityScopedBookmarkStore(defaults: defaults)

        try store.remember(tempDir)

        #expect(store.storedBookmarkPaths == [expectedPath])

        let resolved = try #require(try store.resolve(path: expectedPath))

        #expect(resolved.url.standardizedFileURL.path == expectedPath)
        #expect(resolved.bookmarkWasStale == false)
    }

    @Test("storeBookmarkData round-trips real security-scoped bookmark data")
    func storeBookmarkDataRoundTripsRealBookmark() throws {
        let suiteName = "StorageScopeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempDir = try makeTempDir()
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let expectedPath = tempDir.standardizedFileURL.path
        let bookmarkData = try tempDir.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let store = SecurityScopedBookmarkStore(defaults: defaults)
        store.storeBookmarkData(bookmarkData, for: expectedPath)

        #expect(store.storedBookmarkPaths == [expectedPath])

        let resolved = try #require(try store.resolve(path: expectedPath))

        #expect(resolved.url.standardizedFileURL.path == expectedPath)
        #expect(resolved.bookmarkWasStale == false)
    }

    @Test("resolve throws bookmarkDataInvalid and prunes when stored bytes are corrupt")
    func resolveThrowsBookmarkDataInvalidForCorruptBytes() throws {
        let suiteName = "StorageScopeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let deadPath = "/tmp/storagescope-corrupt-\(UUID().uuidString)"
        let store = SecurityScopedBookmarkStore(defaults: defaults)
        store.storeBookmarkData(Data("definitely-not-a-bookmark".utf8), for: deadPath)

        var caught: BookmarkError?
        do {
            _ = try store.resolve(path: deadPath)
            Issue.record("Expected resolve to throw for corrupt bookmark bytes")
        } catch let error as BookmarkError {
            caught = error
        } catch {
            Issue.record("Expected BookmarkError, got \(error)")
        }

        guard case .bookmarkDataInvalid(let path, _) = caught else {
            Issue.record("Expected .bookmarkDataInvalid, got \(String(describing: caught))")
            return
        }
        #expect(path == deadPath)

        // resolve() prunes corrupt bytes so the next resolve is a clean nil.
        let again = try store.resolve(path: deadPath)
        #expect(again == nil)
    }

    @Test("resolve throws fileMissing and prunes when the folder no longer exists")
    func resolveThrowsFileMissingAndPrunesWhenFolderDeleted() throws {
        let suiteName = "StorageScopeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempDir = try makeTempDir()
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let expectedPath = tempDir.standardizedFileURL.path
        let bookmarkData = try tempDir.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        // Delete the folder before resolve so fileExists returns false but the
        // bookmark bytes themselves are valid data. The default volume check
        // treats the root volume (/private/var, /tmp) as always-mounted.
        try FileManager.default.removeItem(at: tempDir)

        let store = SecurityScopedBookmarkStore(defaults: defaults)
        store.storeBookmarkData(bookmarkData, for: expectedPath)

        var caught: BookmarkError?
        do {
            _ = try store.resolve(path: expectedPath)
            Issue.record("Expected resolve to throw when the folder is missing")
        } catch let error as BookmarkError {
            caught = error
        } catch {
            Issue.record("Expected BookmarkError, got \(error)")
        }

        guard case .fileMissing(let url) = caught else {
            Issue.record("Expected .fileMissing, got \(String(describing: caught))")
            return
        }
        #expect(url.standardizedFileURL.path == expectedPath)

        // resolve() prunes the entry after reporting the failure.
        let again = try store.resolve(path: expectedPath)
        #expect(again == nil)
    }

    @Test("resolve throws volumeNotMounted when file is missing on an unmounted external volume")
    func resolveThrowsVolumeNotMountedForMissingVolumed() throws {
        let suiteName = "StorageScopeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Bookmark a real directory then delete it, so the bookmark bytes are
        // valid but the resolve path is missing. Override the mount check to
        // return false, simulating a disconnected external volume.
        let tempDir = try makeTempDir()
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let realBookmarkData = try tempDir.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try FileManager.default.removeItem(at: tempDir)
        let tempPath = tempDir.standardizedFileURL.path

        let store = SecurityScopedBookmarkStore(
            defaults: defaults,
            isVolumeMounted: { _ in false }
        )
        store.storeBookmarkData(realBookmarkData, for: tempPath)

        var caught: BookmarkError?
        do {
            _ = try store.resolve(path: tempPath)
            Issue.record("Expected resolve to throw for missing file on unmounted volume")
        } catch let error as BookmarkError {
            caught = error
        } catch {
            Issue.record("Expected BookmarkError, got \(error)")
        }

        guard case .volumeNotMounted(let url) = caught else {
            Issue.record("Expected .volumeNotMounted, got \(String(describing: caught))")
            return
        }
        #expect(url.standardizedFileURL.path == tempPath)

        // Volume-not-mounted still prunes: the entry is gone after the throw.
        let again = try store.resolve(path: tempPath)
        #expect(again == nil)
    }

    @Test("resolve surfaces accessDenied when startAccessingSecurityScopedResource returns false")
    func resolveSurfacesAccessDeniedWhenSandboxRevoked() throws {
        let suiteName = "StorageScopeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempDir = try makeTempDir()
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let expectedPath = tempDir.standardizedFileURL.path
        let bookmarkData = try tempDir.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        // Inject an access factory that always throws accessDenied — simulates
        // the sandbox revoking a previously granted scope at resolve time. The
        // bookmark itself and the file are both still valid; only the sandbox
        // grant fails.
        let store = SecurityScopedBookmarkStore(
            defaults: defaults,
            makeAccess: { url in
                throw BookmarkError.accessDenied(url)
            }
        )
        store.storeBookmarkData(bookmarkData, for: expectedPath)

        var caught: BookmarkError?
        do {
            _ = try store.resolve(path: expectedPath)
            Issue.record("Expected resolve to throw accessDenied")
        } catch let error as BookmarkError {
            caught = error
        } catch {
            Issue.record("Expected BookmarkError, got \(error)")
        }

        guard case .accessDenied(let url) = caught else {
            Issue.record("Expected .accessDenied, got \(String(describing: caught))")
            return
        }
        #expect(url.standardizedFileURL.path == expectedPath)

        // Access-denied is NOT a corrupted bookmark — the stored entry is
        // retained so a future re-grant can still resolve it without forcing
        // the user to re-pick from disk.
        #expect(store.storedBookmarkPaths == [expectedPath])
    }

    @Test("remember propagates bookmarkCreationFailed when bookmarkData throws")
    func rememberPropagatesCreationFailure() throws {
        let suiteName = "StorageScopeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SecurityScopedBookmarkStore(defaults: defaults)

        // A path that does not exist and is not under any security-scoped grant
        // will fail at URL.bookmarkData: it cannot be bookmarked.
        let bogusURL = URL(fileURLWithPath: "/dev/null/storagescope-impossible-\(UUID().uuidString)")

        var caught: BookmarkError?
        do {
            try store.remember(bogusURL)
            Issue.record("Expected remember to throw for a non-bookmarkable URL")
        } catch let error as BookmarkError {
            caught = error
        } catch {
            Issue.record("Expected BookmarkError, got \(error)")
        }

        guard case .bookmarkCreationFailed(let url, _) = caught else {
            Issue.record("Expected .bookmarkCreationFailed, got \(String(describing: caught))")
            return
        }
        #expect(url == bogusURL)
        #expect(store.storedBookmarkPaths.isEmpty)
    }

    @Test("prune swallows resolve errors without surfacing")
    func pruneSwallowsResolveErrors() throws {
        // prune must never throw — it runs on app launch before the user can
        // react. The corrupt-byte case is the variant that always removes the
        // entry; the access-denied variant leaves the entry in place (verified
        // in its dedicated test above).
        let suiteName = "StorageScopeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SecurityScopedBookmarkStore(defaults: defaults)
        let corruptPath = "/tmp/storagescope-prune-\(UUID().uuidString)"
        store.storeBookmarkData(Data("corrupt".utf8), for: corruptPath)

        store.prune()

        #expect(store.storedBookmarkPaths.isEmpty)
    }

    private func makeTempDir() throws -> URL {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        return baseURL.appendingPathComponent("storagescope-tests-\(UUID().uuidString)")
    }
}