import StorageScopeCore
import SwiftUI

struct StorageItemTable: View {
    let title: String
    let subtitle: String
    let items: [StorageItem]
    @ObservedObject var store: ScanStore
    var compact = false
    var countLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(countLabel ?? "\(items.count.formatted()) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                StorageItemHeader()

                Divider()

                if items.isEmpty {
                    FilterRecoveryView(
                        title: "No Items",
                        systemImage: "magnifyingglass",
                        description: store.hasActiveDisplayFilters ? "No items match the active display filters." : "No items are available in this view.",
                        filters: store.activeDisplayFilterDescriptions,
                        clearTitle: "Clear Filters"
                    ) {
                        store.resetDisplayFilters()
                    }
                    .frame(minHeight: 220)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { item in
                                StorageItemRow(
                                    item: item,
                                    isSelected: store.selectedItemID == item.id,
                                    store: store
                                )
                                Divider()
                            }
                        }
                    }
                    .frame(minHeight: compact ? 320 : 420)
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct StorageItemHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Name")
                .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
            Text("Size")
                .frame(width: 96, alignment: .trailing)
            Text("Kind")
                .frame(width: 94, alignment: .leading)
            Text("Modified")
                .frame(width: 112, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct StorageItemRow: View {
    let item: StorageItem
    let isSelected: Bool
    @ObservedObject var store: ScanStore

    var body: some View {
        Button {
            store.selectedItemID = item.id
        } label: {
            HStack(spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: StorageFormat.icon(for: item))
                        .foregroundStyle(item.kind == .inaccessible ? .red : .secondary)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .lineLimit(1)

                        Text(item.url.path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)

                Text(StorageFormat.bytes(item.displaySize))
                    .font(.system(.body, design: .rounded).monospacedDigit())
                    .frame(width: 96, alignment: .trailing)

                Text(StorageFormat.label(for: item.kind))
                    .foregroundStyle(.secondary)
                    .frame(width: 94, alignment: .leading)

                Text(StorageFormat.date(item.modifiedAt))
                    .foregroundStyle(.secondary)
                    .frame(width: 112, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
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
            .disabled(!store.canMoveItemToTrash(item))
        }
    }
}
