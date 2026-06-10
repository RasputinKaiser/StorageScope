import AppKit
import Foundation
import StorageScopeCore

enum FileActionService {
    @MainActor
    static func chooseFolder(startingAt directoryURL: URL? = nil, message: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder to Scan"
        panel.message = message ?? "StorageScope will inspect file and folder sizes inside the selected location."
        panel.prompt = "Scan"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = directoryURL
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    static func moveToTrash(_ url: URL) throws {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
    }

    static func moveToTrashTransactionally(_ urls: [URL]) throws {
        try TransactionalTrashMover().moveToTrash(urls)
    }

    @MainActor
    static func confirmTrash(url: URL) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move to Trash?"
        alert.informativeText = "\(url.lastPathComponent) will be moved to Trash. You can restore it from Finder if needed."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    static func confirmTrash(urls: [URL], containsReviewRisk: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move \(urls.count) Items to Trash?"
        alert.informativeText = containsReviewRisk
            ? "This batch includes review-suggested cleanup items that are not content-verified duplicates. Confirm each path is safe before moving them to Trash. You can restore items from Finder if needed."
            : "The selected cleanup items will be moved to Trash. You can restore them from Finder if needed."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

}
