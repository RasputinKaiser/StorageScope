import Foundation
import Testing
@testable import StorageScope

@MainActor
@Suite("ScanStore find-next navigation (Cmd+G)")
struct ScanStoreFindNextNavigationTests {
    @Test("advanceSearchResult is no-op when no search active")
    func advanceNoSearchNoOp() {
        let store = ScanStore()
        store.advanceSearchResult()
        #expect(store.currentSearchResultIndex == nil)
        #expect(store.selectedItemID == nil)
    }

    @Test("reverseSearchResult is no-op when no search active")
    func reverseNoSearchNoOp() {
        let store = ScanStore()
        store.reverseSearchResult()
        #expect(store.currentSearchResultIndex == nil)
    }

    @Test("advance cycles through matches and wraps around")
    func advanceCyclesAndWraps() async throws {
        let store = ScanStore()
        // Fixture: small tree with three matching items at top level so
        // searchResultIDs ends up with at least 3 entries.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmdg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["foo-report.txt", "foo-data.csv", "foo-summary.md"] {
            try Data().write(to: root.appendingPathComponent(name))
        }

        store.scanDeveloperFixturePath(root.path)
        // Give the async scan + debounce a moment to populate searchResultIDs.
        try await Task.sleep(for: .milliseconds(400))

        store.filters.searchText = "foo"
        try await Task.sleep(for: .milliseconds(400))

        guard let ids = store.filters.searchResultIDs, ids.count >= 3 else {
            Issue.record("expected >=3 searchResultIDs, got \(store.filters.searchResultIDs?.count ?? 0)")
            return
        }

        store.advanceSearchResult()
        #expect(store.currentSearchResultIndex == 0)
        #expect(store.selectedItemID == ids[0])

        store.advanceSearchResult()
        #expect(store.currentSearchResultIndex == 1)
        #expect(store.selectedItemID == ids[1])

        store.advanceSearchResult()
        #expect(store.currentSearchResultIndex == 2)

        // Wrap around back to 0
        store.advanceSearchResult()
        #expect(store.currentSearchResultIndex == 0)
        #expect(store.selectedItemID == ids[0])
    }

    @Test("reverse starts from the last match and wraps backward")
    func reverseStartsFromLast() async throws {
        let store = ScanStore()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmdg-rev-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["foo-report.txt", "foo-data.csv", "foo-summary.md"] {
            try Data().write(to: root.appendingPathComponent(name))
        }

        store.scanDeveloperFixturePath(root.path)
        try await Task.sleep(for: .milliseconds(400))
        store.filters.searchText = "foo"
        try await Task.sleep(for: .milliseconds(400))

        guard let ids = store.filters.searchResultIDs, ids.count >= 3 else {
            Issue.record("expected >=3 searchResultIDs, got \(store.filters.searchResultIDs?.count ?? 0)")
            return
        }

        store.reverseSearchResult()
        #expect(store.currentSearchResultIndex == ids.count - 1)
        #expect(store.selectedItemID == ids[ids.count - 1])

        store.reverseSearchResult()
        #expect(store.currentSearchResultIndex == ids.count - 2)
    }

    @Test("advanceSearchResult auto-expands collapsed ancestors in the tree so the matched row is visible")
    func advanceExpandsAncestors() async throws {
        let store = ScanStore()
        // Fixture: nested tree with a matching file two levels deep.
        //   root/
        //     Projects/        <- collapsed by default
        //       Sub/           <- collapsed by default
        //         foo-report.txt
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmdg-expand-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Projects/Sub", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("Projects/Sub/foo-report.txt"))

        store.scanDeveloperFixturePath(root.path)
        try await Task.sleep(for: .milliseconds(400))
        store.filters.searchText = "foo"
        try await Task.sleep(for: .milliseconds(400))

        guard let ids = store.filters.searchResultIDs, !ids.isEmpty else {
            Issue.record("expected searchResultIDs to contain the nested file")
            return
        }

        // TreeExpandedIDs should be empty (or just root via .onAppear in real UI) before Cmd+G:
        store.treeExpandedIDs = []

        store.advanceSearchResult()
        // After advance, the intermediate "Projects" folder must be expanded so the
        // (nested) matched row is reachable in the tree navigation UI.
        guard let scan = store.scan else {
            Issue.record("scan should be loaded")
            return
        }
        let projectsID = scan.rootItem.children.first(where: { $0.name == "Projects" })?.id
        let subID = scan.rootItem.children.first(where: { $0.name == "Projects" })?
            .children.first(where: { $0.name == "Sub" })?.id
        #expect(projectsID.map { store.treeExpandedIDs.contains($0) } == true)
        #expect(subID.map { store.treeExpandedIDs.contains($0) } == true)
    }
}