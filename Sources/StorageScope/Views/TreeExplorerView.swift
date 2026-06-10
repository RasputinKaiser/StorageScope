import StorageScopeCore
import SwiftUI

struct TreeExplorerView: View {
    @ObservedObject var store: ScanStore
    @State private var expandedIDs = Set<String>()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Folder Tree")
                        .font(.headline)
                    Text(treeSummaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let rootItem = store.scan?.rootItem {
                    VStack(spacing: 0) {
                        TreeNodeRow(
                            item: rootItem,
                            rootSize: max(rootItem.displaySize, 1),
                            depth: 0,
                            expandedIDs: $expandedIDs,
                            store: store
                        )
                    }
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .onAppear {
                        expandedIDs.insert(rootItem.id)
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
    @ObservedObject var store: ScanStore

    private var isExpanded: Bool {
        expandedIDs.contains(item.id)
    }

    private var visibleChildren: [StorageItem] {
        item.children.filter { child in
            child.displaySize >= store.sizeFilter.threshold &&
                (store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    child.name.localizedCaseInsensitiveContains(store.query) ||
                    child.url.path.localizedCaseInsensitiveContains(store.query))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                store.selectedItemID = item.id
                if item.isContainer {
                    toggleExpanded()
                }
            } label: {
                HStack(spacing: 10) {
                    if item.isContainer && !visibleChildren.isEmpty {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                    } else {
                        Color.clear
                            .frame(width: 14, height: 14)
                    }

                    Image(systemName: StorageFormat.icon(for: item))
                        .foregroundStyle(item.kind == .inaccessible ? .red : .secondary)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(item.name)
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
                    }
                }
                .padding(.leading, CGFloat(depth * 18) + 12)
                .padding(.trailing, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .background(store.selectedItemID == item.id ? Color.accentColor.opacity(0.18) : Color.clear)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Reveal in Finder") {
                    store.selectedItemID = item.id
                    store.revealSelectedItem()
                }
                Button("Open") {
                    store.selectedItemID = item.id
                    store.openSelectedItem()
                }
                Button("Copy Path") {
                    store.selectedItemID = item.id
                    store.copySelectedPath()
                }
                Divider()
                Button("Move to Trash", role: .destructive) {
                    store.selectedItemID = item.id
                    store.moveSelectedItemToTrash()
                }
            }

            if isExpanded {
                ForEach(visibleChildren) { child in
                    Divider()
                    TreeNodeRow(
                        item: child,
                        rootSize: rootSize,
                        depth: depth + 1,
                        expandedIDs: $expandedIDs,
                        store: store
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
