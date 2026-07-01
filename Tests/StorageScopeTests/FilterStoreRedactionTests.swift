import Foundation
import Testing
@testable import StorageScope
@testable import StorageScopeCore

@MainActor
@Suite("FilterStore redaction")
struct FilterStoreRedactionTests {
    private func makeFilterStore() -> FilterStore {
        FilterStore(scanLookup: { nil }, coordinateInvalidate: {})
    }

    private func makeFile(_ path: String, ext: String = "mp4") -> StorageItem {
        StorageItem(
            url: URL(fileURLWithPath: path),
            kind: .file,
            byteSize: 1024,
            allocatedSize: 1024,
            modifiedAt: nil,
            immediateChildCount: 0,
            descendantCount: 0,
            isReadable: true,
            fileExtension: ext
        )
    }

    private func makeFolder(_ path: String) -> StorageItem {
        StorageItem(
            url: URL(fileURLWithPath: path, isDirectory: true),
            kind: .folder,
            byteSize: 2048,
            allocatedSize: 2048,
            modifiedAt: nil,
            immediateChildCount: 1,
            descendantCount: 1,
            isReadable: true,
            fileExtension: nil
        )
    }

    @Test("returns real values when redaction is off")
    func realValuesWhenOff() {
        let store = makeFilterStore()
        let file = makeFile("/Users/test/Movies/vacation.mp4")

        #expect(store.displayName(for: file) == "vacation.mp4")
        #expect(store.displayPath(for: file) == file.url.path)
    }

    @Test("same item id maps to same placeholder across repeated calls")
    func stablePlaceholderForSameItem() {
        let store = makeFilterStore()
        store.redactionEnabled = true
        let file = makeFile("/Users/test/Movies/vacation.mp4")

        let first = store.displayName(for: file)
        let second = store.displayName(for: file)
        #expect(first == second)
        #expect(first.hasPrefix("File "))
        #expect(first.hasSuffix(".mp4"))
    }

    @Test("different items get different placeholders")
    func differentItemsDifferentPlaceholders() {
        let store = makeFilterStore()
        store.redactionEnabled = true
        let fileA = makeFile("/Users/test/Movies/vacation.mp4")
        let fileB = makeFile("/Users/test/Movies/wedding.mp4")

        let nameA = store.displayName(for: fileA)
        let nameB = store.displayName(for: fileB)
        #expect(nameA != nameB)
    }

    @Test("folders get a Folder N placeholder, distinct from files")
    func folderPlaceholder() {
        let store = makeFilterStore()
        store.redactionEnabled = true
        let folder = makeFolder("/Users/test/Movies")

        let name = store.displayName(for: folder)
        #expect(name.hasPrefix("Folder "))
    }

    @Test("toggling redaction off after being on immediately restores real names")
    func togglingOffRestoresRealNames() {
        let store = makeFilterStore()
        let file = makeFile("/Users/test/Movies/vacation.mp4")

        store.redactionEnabled = true
        let masked = store.displayName(for: file)
        #expect(masked != file.name)

        store.redactionEnabled = false
        #expect(store.displayName(for: file) == file.name)
        #expect(store.displayPath(for: file) == file.url.path)
    }

    @Test("displayPath masks parent folder and file name when enabled")
    func displayPathMasksBothLevels() {
        let store = makeFilterStore()
        store.redactionEnabled = true
        let file = makeFile("/Users/test/Movies/vacation.mp4")

        let path = store.displayPath(for: file)
        #expect(!path.contains("vacation"))
        #expect(!path.contains("Movies"))
        #expect(path.contains("Folder "))
        #expect(path.contains("File "))
    }
}
