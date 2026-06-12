import AppKit
import SwiftUI

@main
@MainActor
enum StorageScopeApp {
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate, NSMenuItemValidation, NSToolbarItemValidation {
    private let store = ScanStore()
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        showMainWindow()
        scanDeveloperFixtureIfRequested()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc private func showMainWindow() {
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "StorageScope"
        window.minSize = NSSize(width: 1180, height: 760)
        window.center()
        window.setFrameAutosaveName("StorageScopeMainWindow")
        window.contentView = NSHostingView(rootView: ContentView(store: store))
        window.toolbar = makeToolbar()
        window.toolbarStyle = .unified
        window.makeKeyAndOrderFront(nil)
        mainWindow = window
    }

    @objc private func chooseFolder() {
        store.chooseFolderAndScan()
    }

    @objc private func scanHome() {
        store.scanHome()
    }

    @objc private func scanDocuments() {
        store.scanDocuments()
    }

    @objc private func scanDownloads() {
        store.scanDownloads()
    }

    @objc private func rescan() {
        store.rescan()
    }

    @objc private func cancelScan() {
        store.cancelScan()
    }

    @objc private func revealSelectedItem() {
        store.revealSelectedItem()
    }

    @objc private func openSelectedItem() {
        store.openSelectedItem()
    }

    @objc private func copySelectedPath() {
        store.copySelectedPath()
    }

    @objc private func moveSelectedItemToTrash() {
        store.moveSelectedItemToTrash()
    }

    @objc private func showSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "StorageScope Settings"
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView(store: store))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "StorageScope",
            .applicationVersion: "0.1.0",
            .credits: NSAttributedString(string: "A local-first Mac storage map for reviewing large folders, verified duplicates, cleanup suggestions, and safer reclaim decisions.")
        ])
    }

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "StorageScopeToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = true
        toolbar.displayMode = .iconAndLabel
        return toolbar
    }

    private func scanDeveloperFixtureIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["STORAGESCOPE_ENABLE_DEVELOPER_SCAN"] == "1",
              let path = environment["STORAGESCOPE_DEVELOPER_SCAN_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return
        }

        applyDeveloperFixtureFilters(environment)

        store.scanDeveloperFixturePath(
            path,
            markResultsNeedRefreshWhenComplete: environment["STORAGESCOPE_DEVELOPER_MARK_RESULTS_STALE"] == "1",
            selectedViewWhenComplete: environment["STORAGESCOPE_DEVELOPER_SELECTED_VIEW"].flatMap(SmartView.init(rawValue:)),
            selectVerifiedCleanupWhenComplete: environment["STORAGESCOPE_DEVELOPER_SELECT_VERIFIED_CLEANUP"] == "1"
        )
    }

    private func applyDeveloperFixtureFilters(_ environment: [String: String]) {
        if let query = environment["STORAGESCOPE_DEVELOPER_QUERY"]?.trimmingCharacters(in: .whitespacesAndNewlines) {
            store.query = query
        }
        if let value = environment["STORAGESCOPE_DEVELOPER_SIZE_FILTER"],
           let sizeFilter = SizeFilter(developerFixtureValue: value) {
            store.sizeFilter = sizeFilter
        }
        if let value = environment["STORAGESCOPE_DEVELOPER_SORT"],
           let sortOption = ItemSortOption(developerFixtureValue: value) {
            store.sortOption = sortOption
        }
        if let value = environment["STORAGESCOPE_DEVELOPER_CLEANUP_LANE"],
           let cleanupLane = CleanupLaneFilter(developerFixtureValue: value) {
            store.cleanupLaneFilter = cleanupLane
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.chooseFolder, .rescan, .cancelScan, .revealItem, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.chooseFolder, .rescan, .cancelScan, .flexibleSpace, .revealItem]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)

        switch itemIdentifier {
        case .chooseFolder:
            item.label = "Choose"
            item.paletteLabel = "Choose Folder"
            item.toolTip = "Choose a folder to scan"
            item.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "Choose Folder")
            item.target = self
            item.action = #selector(chooseFolder)
        case .rescan:
            item.label = "Rescan"
            item.toolTip = "Scan the last selected location again"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Rescan")
            item.target = self
            item.action = #selector(rescan)
        case .cancelScan:
            item.label = "Cancel"
            item.toolTip = "Cancel the current scan"
            item.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Cancel")
            item.target = self
            item.action = #selector(cancelScan)
        case .revealItem:
            item.label = "Reveal"
            item.toolTip = "Reveal the selected item in Finder"
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Reveal")
            item.target = self
            item.action = #selector(revealSelectedItem)
        default:
            return nil
        }

        return item
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .chooseFolder:
            return !store.isScanning
        case .rescan:
            return store.canRescan
        case .cancelScan:
            return store.canCancelScan
        case .revealItem:
            return store.canUseSelectedItemActions
        default:
            return true
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(showMainWindow), #selector(showSettings), #selector(showAbout):
            return true
        case #selector(chooseFolder), #selector(scanHome), #selector(scanDocuments), #selector(scanDownloads):
            return !store.isScanning
        case #selector(rescan):
            return store.canRescan
        case #selector(cancelScan):
            return store.canCancelScan
        case #selector(revealSelectedItem), #selector(openSelectedItem), #selector(copySelectedPath):
            return store.canUseSelectedItemActions
        case #selector(moveSelectedItemToTrash):
            return store.canMoveSelectedItemToTrash
        default:
            return true
        }
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "StorageScope")
        appMenu.addItem(menuItem("About StorageScope", action: #selector(showAbout), key: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(menuItem("Settings...", action: #selector(showSettings), key: ","))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit StorageScope", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(menuItem("Show Window", action: #selector(showMainWindow), key: "n"))
        fileMenu.addItem(menuItem("Choose Folder...", action: #selector(chooseFolder), key: "o"))
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let scanMenuItem = NSMenuItem()
        let scanMenu = NSMenu(title: "Scan")
        scanMenu.addItem(menuItem("Choose Home...", action: #selector(scanHome), key: "H", modifiers: [.command, .shift]))
        scanMenu.addItem(menuItem("Choose Documents...", action: #selector(scanDocuments), key: "D", modifiers: [.command, .shift]))
        scanMenu.addItem(menuItem("Choose Downloads...", action: #selector(scanDownloads), key: "L", modifiers: [.command, .shift]))
        scanMenu.addItem(NSMenuItem.separator())
        scanMenu.addItem(menuItem("Rescan", action: #selector(rescan), key: "r"))
        scanMenu.addItem(menuItem("Cancel Scan", action: #selector(cancelScan), key: "."))
        scanMenuItem.submenu = scanMenu
        mainMenu.addItem(scanMenuItem)

        let itemMenuItem = NSMenuItem()
        let itemMenu = NSMenu(title: "Item")
        itemMenu.addItem(menuItem("Reveal in Finder", action: #selector(revealSelectedItem), key: "F", modifiers: [.command, .shift]))
        itemMenu.addItem(menuItem("Open", action: #selector(openSelectedItem), key: "\r"))
        itemMenu.addItem(menuItem("Copy Path", action: #selector(copySelectedPath), key: "C", modifiers: [.command, .option]))
        itemMenu.addItem(NSMenuItem.separator())
        itemMenu.addItem(menuItem("Move to Trash", action: #selector(moveSelectedItemToTrash), key: "\u{8}", modifiers: .command))
        itemMenuItem.submenu = itemMenu
        mainMenu.addItem(itemMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(menuItem("Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), key: ""))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func menuItem(
        _ title: String,
        action: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }
}

private extension NSToolbarItem.Identifier {
    static let chooseFolder = NSToolbarItem.Identifier("StorageScopeChooseFolder")
    static let rescan = NSToolbarItem.Identifier("StorageScopeRescan")
    static let cancelScan = NSToolbarItem.Identifier("StorageScopeCancelScan")
    static let revealItem = NSToolbarItem.Identifier("StorageScopeRevealItem")
}

private extension SizeFilter {
    init?(developerFixtureValue value: String) {
        switch value.normalizedDeveloperFixtureValue {
        case "all", "0":
            self = .all
        case "100mb", "over100mb", "over100m", "1e8":
            self = .over100MB
        case "1gb", "over1gb", "over1g", "1e9":
            self = .over1GB
        case "10gb", "over10gb", "over10g", "1e10":
            self = .over10GB
        default:
            return nil
        }
    }
}

private extension ItemSortOption {
    init?(developerFixtureValue value: String) {
        switch value.normalizedDeveloperFixtureValue {
        case "size", "sizedescending", "largest":
            self = .sizeDescending
        case "name", "nameascending", "az":
            self = .nameAscending
        case "newest", "modifiednewest":
            self = .modifiedNewest
        case "oldest", "modifiedoldest":
            self = .modifiedOldest
        case "kind", "type":
            self = .kind
        default:
            return nil
        }
    }
}

private extension CleanupLaneFilter {
    init?(developerFixtureValue value: String) {
        switch value.normalizedDeveloperFixtureValue {
        case "all":
            self = .all
        case "verified", "duplicates", "highconfidence":
            self = .verified
        case "suggestions", "review", "manual":
            self = .suggestions
        default:
            return nil
        }
    }
}

private extension String {
    var normalizedDeveloperFixtureValue: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
    }
}
