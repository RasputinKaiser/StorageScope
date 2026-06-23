import AppKit
import Foundation
import Testing
@testable import StorageScope

@MainActor
@Suite("FileActionService")
struct FileActionServiceTests {
    @Test("reveal returns an error string when the URL points to a missing file")
    func revealSurfacesErrorForMissingFile() {
        let url = URL(fileURLWithPath: "/tmp/storagescope-reveal-missing-\(UUID().uuidString)")
        #expect(FileManager.default.fileExists(atPath: url.path) == false)

        let message = FileActionService.reveal(url)

        guard let message else {
            Issue.record("Expected reveal to return an error for a missing URL")
            return
        }
        #expect(message.contains(url.lastPathComponent))
        #expect(message.contains(url.path))
        #expect(message.localizedCaseInsensitiveContains("couldn") || message.localizedCaseInsensitiveContains("no longer"))
    }

    @Test("open returns an error string when no app is registered for the URL")
    func openSurfacesErrorForMissingHandler() async {
        let url = URL(fileURLWithPath: "/tmp/storagescope-open-missing-\(UUID().uuidString)")
        #expect(FileManager.default.fileExists(atPath: url.path) == false)

        let message = await FileActionService.open(url)

        guard let message else {
            Issue.record("Expected open to return an error for a missing URL")
            return
        }
        #expect(message.contains(url.lastPathComponent))
        #expect(message.localizedCaseInsensitiveContains("couldn"))
    }

    @Test("copyPath writes the URL path to the pasteboard and returns nil")
    func copyPathWritesPathToPasteboardAndReturnsNil() {
        let url = URL(fileURLWithPath: "/tmp/storagescope-copy-test-\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("storagescope-copy-\(UUID().uuidString)"))

        let message = FileActionService.copyPath(url, pasteboard: pasteboard)

        #expect(message == nil)
        #expect(pasteboard.string(forType: .string) == url.path)
        #expect(pasteboard.types?.contains(.string) == true)
    }
}