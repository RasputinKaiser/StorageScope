import Foundation
import Testing
@testable import StorageScopeCore

@Suite("StorageItem search query matching")
struct StorageItemSearchQueryTests {
    @Test("Empty query matches everything (backward compat)")
    func emptyQueryMatchesAll() throws {
        let item = makeItem(name: "report.pdf", path: "/tmp/work/Documents/report.pdf")
        #expect(item.matchesSearchQuery(""))
        #expect(item.matchesSearchQuery("   "))
        #expect(item.matchesSearchQuery("\t\n"))
    }

    @Test("Single-term query matches name substring (backward compat)")
    func singleTermMatchOnName() throws {
        let item = makeItem(name: "Quarterly Report.pdf", path: "/tmp/work/Documents/report.pdf")
        #expect(item.matchesSearchQuery("report"))
        #expect(item.matchesSearchQuery("Quarterly"))
        #expect(item.matchesSearchQuery("REPORT"))
    }

    @Test("Single-term query matches full path substring")
    func singleTermMatchOnPath() throws {
        let item = makeItem(name: "data.csv", path: "/tmp/work/Documents/Foo/research/data.csv")
        #expect(item.matchesSearchQuery("research"))
        #expect(item.matchesSearchQuery("Documents"))
    }

    @Test("Multi-word AND matches when all terms present")
    func multiWordAndPositiveName() throws {
        let item = makeItem(name: "Q3 marketing budget.xlsx", path: "/tmp/work/Documents/finance/Q3.xlsx")
        #expect(item.matchesSearchQuery("marketing budget"))
        #expect(item.matchesSearchQuery("budget marketing"))
        // Path-segment + name combo
        #expect(item.matchesSearchQuery("Documents marketing"))
    }

    @Test("Multi-word AND fails when only one term present")
    func multiWordAndNegativeMissingTerm() throws {
        let item = makeItem(name: "Q3 marketing budget.xlsx", path: "/tmp/work/Documents/finance/Q3.xlsx")
        #expect(!item.matchesSearchQuery("marketing synthesis"))
        #expect(!item.matchesSearchQuery("budget website"))
    }

    @Test("Path-segment match: term equals a `/`-split path segment")
    func pathSegmentExactMatch() throws {
        let item = makeItem(name: "file.txt", path: "/tmp/work/Documents/reports/file.txt")
        #expect(item.matchesSearchQuery("Documents"))
        #expect(item.matchesSearchQuery("reports"))
        #expect(item.matchesSearchQuery("work"))
    }

    @Test("Path-segment negative: term must match a full segment, not a substring across segments")
    func pathSegmentNoSubstringAcrossSegments() throws {
        let item = makeItem(name: "file.txt", path: "/tmp/Doc/reports/file.txt")
        // "xDoc" is a substring of the contiguous path string but is NOT a full
        // `/`-split segment. Must not match the name OR any path segment.
        #expect(!item.matchesSearchQuery("xDoc"))
        #expect(!item.matchesSearchQuery("workDoc"))
    }

    @Test("Case-insensitive matching across name and path")
    func caseInsensitiveMatching() throws {
        let item = makeItem(name: "Invoice.PDF", path: "/tmp/work/Sales/Invoice.PDF")
        #expect(item.matchesSearchQuery("invoice"))
        #expect(item.matchesSearchQuery("INVOICE"))
        #expect(item.matchesSearchQuery("sales"))
        #expect(item.matchesSearchQuery("SALES"))
    }

    @Test("searchHighlightRanges returns matched ranges in name")
    func highlightRangesForName() throws {
        let item = makeItem(name: "foobar-baz", path: "/tmp/foobar-baz")
        let ranges = item.searchHighlightRanges(for: "foo")
        #expect(ranges.count == 1)
        let matched = String(item.name[ranges[0]])
        #expect(matched == "foo")
    }

    @Test("searchHighlightRanges supports multi-term queries")
    func highlightRangesMultiTerm() throws {
        let item = makeItem(name: "foo bar foo baz", path: "/tmp")
        let ranges = item.searchHighlightRanges(for: "foo bar")
        // "foo" appears twice, "bar" appears once — expect 3 total ranges.
        #expect(ranges.count == 3)
    }

    @Test("searchHighlightRanges is empty for empty query")
    func highlightRangesEmptyQuery() throws {
        let item = makeItem(name: "anything", path: "/tmp")
        #expect(item.searchHighlightRanges(for: "").isEmpty)
        #expect(item.searchHighlightRanges(for: "   ").isEmpty)
    }

    @Test("searchHighlightRanges is empty when term not present in name")
    func highlightRangesTermNotInName() throws {
        let item = makeItem(name: "foobar", path: "/tmp/Documents")
        // Term not present in name (only in path segment) — no highlight ranges.
        #expect(item.searchHighlightRanges(for: "Documents").isEmpty)
    }

    // MARK: - Helpers

    private func makeItem(name: String, path: String) -> StorageItem {
        StorageItem(
            url: URL(fileURLWithPath: path),
            name: name,
            kind: .file,
            byteSize: 1024,
            allocatedSize: 1024,
            modifiedAt: Date(),
            immediateChildCount: 0,
            descendantCount: 0,
            children: [],
            isReadable: true,
            fileExtension: (name as NSString).pathExtension
        )
    }
}