import AppKit
import Foundation
import StorageScopeCore

/// Adapter for macOS file-UI primitives — Reveal in Finder / Open / Copy Path / Move to Trash.
/// Marked `@MainActor` because every method here touches AppKit (NSWorkspace / NSOpenPanel /
/// NSPasteboard); the call sites (ScanStore, AppDelegate target-action) are already on the main
/// actor. `moveToTrashTransactionally` stays `nonisolated` so it can run on a detached task
/// inside ScanStore's transactional Trash batch without hopping to the main actor mid-batch.
@MainActor
enum FileActionService {
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

    /// Reveals `url` in Finder. Returns nil on success, an error string when the file is
    /// missing — `NSWorkspace.activateFileViewerSelecting(_:)` neither throws nor reports a
    /// failure for a path Finder can't resolve, so a moved-or-deleted item would silently
    /// no-op without the preflight check.
    static func reveal(_ url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "StorageScope couldn't reveal \"\(url.lastPathComponent)\" in Finder because it no longer exists at \(url.path)."
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return nil
    }

    /// Reveals multiple URLs in a single Finder window. Preflights each URL; reveals the
    /// existing subset and returns a partial-failure message if some are missing, a fail-all
    /// message if none exist, or nil if every URL is on disk.
    static func revealAll(_ urls: [URL]) -> String? {
        guard !urls.isEmpty else { return nil }
        var existing: [URL] = []
        var missing: [URL] = []
        for url in urls {
            if FileManager.default.fileExists(atPath: url.path) {
                existing.append(url)
            } else {
                missing.append(url)
            }
        }
        if existing.isEmpty {
            let names = urls.map(\.lastPathComponent).joined(separator: ", ")
            return "StorageScope couldn't reveal \(names) in Finder because none of the items exist at their scanned paths anymore."
        }
        NSWorkspace.shared.activateFileViewerSelecting(existing)
        if missing.isEmpty {
            return nil
        }
        let missingNames = missing.map(\.lastPathComponent).joined(separator: ", ")
        return "Revealed \(existing.count) of \(urls.count) items. Missing: \(missingNames)."
    }

    /// Opens `url` with its default application via the throwing Swift API so failures
    /// (missing file, no registered handler, permission denied) surface through
    /// `errorMessage` instead of being swallowed by NSWorkspace. `promptsUserIfNeeded = false`
    /// keeps the OS from presenting a "Choose Application" inspector — failures should be
    /// returned to the caller as a string, not chained into an unprompted system sheet.
    static func open(_ url: URL) async -> String? {
        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.promptsUserIfNeeded = false
            _ = try await NSWorkspace.shared.open(url, configuration: configuration)
            return nil
        } catch {
            return "StorageScope couldn't open \"\(url.lastPathComponent)\": \(error.localizedDescription)"
        }
    }

    /// Copies `url.path` to the pasteboard. Returns nil on success; an error string when
    /// `setString(_:forType:)` refuses the write, which `NSPasteboard.general` essentially
    /// never does but lets us discriminate against a stubbed NSPasteboard in tests by
    /// having the subclass return false from setString.
    static func copyPath(_ url: URL, pasteboard: NSPasteboard = .general) -> String? {
        pasteboard.clearContents()
        guard pasteboard.setString(url.path, forType: .string) else {
            return "StorageScope couldn't copy the path for \"\(url.lastPathComponent)\" to the clipboard."
        }
        return nil
    }

    nonisolated static func moveToTrashTransactionally(_ urls: [URL]) throws {
        try TransactionalTrashMover().moveToTrash(urls)
    }
}
