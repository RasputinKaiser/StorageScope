import StorageScopeCore
import SwiftUI

struct TreeExplorerView: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Folder Tree")
                                .font(.headline)
                            Text(treeSummaryText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if store.scan?.rootItem != nil {
                            HStack(spacing: 6) {
                                Button {
                                    store.expandEntireTree()
                                } label: {
                                    Label("Expand All", systemImage: "chevron.down.square")
                                        .labelStyle(.iconOnly)
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .disabled(!store.canExpandAllTree)
                                .help("Expand every folder in the tree")

                                Button {
                                    store.collapseEntireTree()
                                } label: {
                                    Label("Collapse All", systemImage: "chevron.right.square")
                                        .labelStyle(.iconOnly)
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .disabled(!store.canCollapseTree)
                                .help("Collapse every folder to the root")
                            }
                        }
                    }
                }

                if let rootItem = store.scan?.rootItem {
                    VStack(spacing: 0) {
                        TreeNodeRow(
                            item: rootItem,
                            rootSize: max(rootItem.displaySize, 1),
                            depth: 0,
                            expandedIDs: $store.treeExpandedIDs,
                            selectedItemID: store.selectedItemID,
                            searchSubtreeMatchIDs: store.searchSubtreeMatchIDs,
                            sizeThreshold: store.filters.sizeFilter.threshold,
                            searchText: store.filters.searchText,
                            selectItem: { store.selectedItemID = $0 },
                            openItem: { store.selectedItemID = $0.id; store.openSelectedItem() },
                            revealItem: { store.selectedItemID = $0.id; store.revealSelectedItem() },
                            copyItemPath: { store.selectedItemID = $0.id; store.copySelectedPath() },
                            trashItem: { store.selectedItemID = $0.id; store.moveSelectedItemToTrash() },
                            canTrashItem: { store.canMoveItemToTrash($0) },
                            excludeItem: { store.excludeFolder($0) },
                            // Excluding mid-scan would silently no-op: excludeFolder() routes
                            // through rescan(), which guards on !isScanning.
                            canExcludeItem: { $0.isContainer && $0.id != store.scan?.rootItem.id && !store.isScanning }
                        )
                    }
                    .cardBackground()
                    .onAppear {
                        store.treeExpandedIDs.insert(rootItem.id)
                    }
                } else {
                    ContentUnavailableView(
                        "No Scan",
                        systemImage: "list.bullet.indent",
                        description: Text("Choose a folder to build a navigable storage tree.")
                    )
                    .frame(minHeight: 360)
                }
            }
            .padding(20)
        }
    }

    private var treeSummaryText: String {
        guard let scan = store.scan else {
            return "Choose a folder to build a navigable storage tree."
        }

        let retainedCount = scan.rootItem.retainedItemCount
        if retainedCount < scan.scannedItemCount {
            return "Showing retained tree: top \(retainedCount.formatted()) of \(scan.scannedItemCount.formatted()) scanned items, summarized by largest retained children."
        }
        return "Browse the scanned hierarchy with storage bars at every level."
    }
}

private struct TreeNodeRow: View {
    let item: StorageItem
    let rootSize: Int64
    let depth: Int
    @Binding var expandedIDs: Set<String>
    let selectedItemID: String?
    let searchSubtreeMatchIDs: Set<String>?
    let sizeThreshold: Int64
    let searchText: String
    let selectItem: (String) -> Void
    let openItem: (StorageItem) -> Void
    let revealItem: (StorageItem) -> Void
    let copyItemPath: (StorageItem) -> Void
    let trashItem: (StorageItem) -> Void
    let canTrashItem: (StorageItem) -> Bool
    let excludeItem: (StorageItem) -> Void
    let canExcludeItem: (StorageItem) -> Bool
    @State private var isHovered = false

    private var isExpanded: Bool {
        expandedIDs.contains(item.id)
    }

    private var isSelected: Bool { selectedItemID == item.id }

    private var visibleChildren: [StorageItem] {
        item.children.filter { child in
            guard child.displaySize >= sizeThreshold else { return false }
            return searchSubtreeMatchIDs?.contains(child.id) ?? true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if item.isContainer && !item.children.isEmpty {
                    Button {
                        toggleExpanded()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Collapse \(item.name)" : "Expand \(item.name)")
                    .help(isExpanded ? "Collapse this folder" : "Expand this folder")
                } else {
                    Color.clear
                        .frame(width: 22, height: 22)
                }

                Button {
                    selectItem(item.id)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: StorageFormat.icon(for: item))
                            .foregroundStyle(item.kind == .inaccessible ? .red : .secondary)
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                HighlightedText(item.name, query: searchText)
                                    .lineLimit(1)
                                Spacer()
                                Text(StorageFormat.bytes(item.displaySize))
                                    .font(.system(.body, design: .rounded).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }

                            GeometryReader { geometry in
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(.quaternary)
                                    .overlay(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(.tint.opacity(depth == 0 ? 0.85 : 0.62))
                                            .frame(width: max(6, geometry.size.width * CGFloat(Double(item.displaySize) / Double(rootSize))))
                                    }
                            }
                            .frame(height: 7)
                            // Purely decorative — the row's own accessibilityLabel/Value already
                            // states the size; without this, VoiceOver can land on an unlabeled bar.
                            .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressableRow)
            }
            .padding(.leading, CGFloat(depth * 18) + 12)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .selectionBackground(isSelected: isSelected)
            .background(isHovered && !isSelected ? Color.primary.opacity(0.04) : Color.clear)
            .onHover { isHovered = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(item.name), \(StorageFormat.label(for: item.kind)), \(StorageFormat.bytes(item.displaySize))")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(item.isContainer && !item.children.isEmpty
                ? "Click the disclosure triangle to expand or collapse"
                : "Selects this item")
            .contextMenu {
                Button("Reveal in Finder") { revealItem(item) }
                Button("Open") { openItem(item) }
                Button("Copy Path") { copyItemPath(item) }
                if canExcludeItem(item) {
                    Divider()
                    Button("Exclude This Folder") { excludeItem(item) }
                }
                Divider()
                Button("Move to Trash", role: .destructive) { trashItem(item) }
                    .disabled(!canTrashItem(item))
            }

            if isExpanded {
                ForEach(visibleChildren) { child in
                    Divider()
                    TreeNodeRow(
                        item: child,
                        rootSize: rootSize,
                        depth: depth + 1,
                        expandedIDs: $expandedIDs,
                        selectedItemID: selectedItemID,
                        searchSubtreeMatchIDs: searchSubtreeMatchIDs,
                        sizeThreshold: sizeThreshold,
                        searchText: searchText,
                        selectItem: selectItem,
                        openItem: openItem,
                        revealItem: revealItem,
                        copyItemPath: copyItemPath,
                        trashItem: trashItem,
                        canTrashItem: canTrashItem,
                        excludeItem: excludeItem,
                        canExcludeItem: canExcludeItem
                    )
                }
            }
        }
    }

    private func toggleExpanded() {
        if isExpanded {
            expandedIDs.remove(item.id)
        } else {
            expandedIDs.insert(item.id)
        }
    }
}
