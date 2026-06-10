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
    static func confirmTrash(
        urls: [URL],
        containsReviewRisk: Bool = false,
        estimatedReclaimBytes: Int64? = nil
    ) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move \(trashItemCountLabel(urls.count)) to Trash?"
        alert.informativeText = trashBatchMessage(
            urls: urls,
            containsReviewRisk: containsReviewRisk,
            estimatedReclaimBytes: estimatedReclaimBytes
        )
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func trashBatchMessage(
        urls: [URL],
        containsReviewRisk: Bool,
        estimatedReclaimBytes: Int64?
    ) -> String {
        var sections: [String] = [
            containsReviewRisk
                ? "This batch includes review-suggested cleanup items that are not content-verified duplicates. Confirm each path is safe before moving them to Trash."
                : "This batch contains content-verified duplicate copies. Keep one copy of each duplicate group and confirm the paths before moving them to Trash."
        ]

        if let estimatedReclaimBytes {
            sections.append("Estimated reclaim: \(StorageFormat.bytes(estimatedReclaimBytes)).")
        }

        let previewPaths = urls.prefix(5).map(\.path)
        if !previewPaths.isEmpty {
            var preview = "Paths:\n" + previewPaths.joined(separator: "\n")
            let remainingCount = urls.count - previewPaths.count
            if remainingCount > 0 {
                preview += "\n+\(remainingCount.formatted()) more"
            }
            sections.append(preview)
        }

        sections.append("You can restore items from Finder if needed.")
        return sections.joined(separator: "\n\n")
    }

    private static func trashItemCountLabel(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "Item" : "Items")"
    }
}
