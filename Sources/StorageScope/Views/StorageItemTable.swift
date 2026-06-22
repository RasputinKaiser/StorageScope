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

                HStack(spacing: 8) {
                    if let searchResultCount = store.filters.searchResultCount {
                        SearchResultCountBadge(count: searchResultCount)
                    }
                    Text(countLabel ?? "\(items.count.formatted()) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                StorageItemHeader(sortOption: store.filters.sortOption) { store.filters.sortOption = $0 }

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
            .cardBackground()
        }
    }
}

/// Pill-shaped badge displayed alongside `StorageItemTable`'s item-count label
/// whenever a search query is active. Backed by `FilterStore.searchResultCount`
/// (derived from `searchSubtreeMatchIDs.count`). Extracted as its own `View` struct
/// because the `.tint`-tinted Capsule background + caption weight combined with
/// the surrounding HStack ternary was tripping the Swift type-checker inside the
/// table header body — same pitfall already worked around via `HighlightedText`/
/// `FileTypeRowLabel` extraction patterns documented in the v0.5.0 S1 learning.
///
/// Singular/plural wording mirrors macOS Find: `1 match` vs `N matches`.
private struct SearchResultCountBadge: View {
    let count: Int

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .foregroundStyle(.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(.tint.opacity(0.12), in: Capsule())
            .accessibilityLabel("\(count.formatted()) search \(count == 1 ? "match" : "matches")")
            .help("Items in the current scan whose name or path match the search query")
    }

    private var label: String {
        count == 1 ? "1 match" : "\(count.formatted()) matches"
    }
}

private struct StorageItemHeader: View {
    let sortOption: ItemSortOption
    let onSortChange: (ItemSortOption) -> Void

    var body: some View {
        HStack(spacing: 12) {
            SortableColumnHeader(label: "Name", width: nil, alignment: .leading, minWidth: 220, isActive: sortOption == .nameAscending, indicator: .down) {
                onSortChange(.nameAscending)
            }
            SortableColumnHeader(label: "Size", width: 96, alignment: .trailing, isActive: sortOption == .sizeDescending, indicator: .down) {
                onSortChange(.sizeDescending)
            }
            SortableColumnHeader(label: "Kind", width: 94, alignment: .leading, isActive: sortOption == .kind, indicator: .up) {
                onSortChange(.kind)
            }
            SortableColumnHeader(label: "Modified", width: 112, alignment: .leading, isActive: isModifiedActive, indicator: sortOption == .modifiedNewest ? .down : .up) {
                onSortChange(toggleModified)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var isModifiedActive: Bool {
        sortOption == .modifiedNewest || sortOption == .modifiedOldest
    }

    private var toggleModified: ItemSortOption {
        // Clicking Modified cycles Newest → Oldest → Newest. Gives the user both
        // directions from a single column header without needing a separate menu.
        return sortOption == .modifiedNewest ? .modifiedOldest : .modifiedNewest
    }
}

private struct SortableColumnHeader: View {
    enum Direction { case up, down }

    let label: String
    let width: CGFloat?
    let alignment: Alignment
    var minWidth: CGFloat? = nil
    let isActive: Bool
    let indicator: Direction
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 3) {
                if alignment == .trailing {
                    if isActive {
                        Image(systemName: indicator == .down ? "chevron.down" : "chevron.up")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tint)
                    }
                    Text(label)
                    Spacer(minLength: 0)
                } else {
                    Text(label)
                    Spacer(minLength: 0)
                    if isActive {
                        Image(systemName: indicator == .down ? "chevron.down" : "chevron.up")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tint)
                    }
                }
            }
            .frame(minWidth: minWidth, maxWidth: width == nil ? .infinity : nil, alignment: alignment)
            .frame(width: width, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sort by \(label)")
        .accessibilityLabel("\(label) column")
        .accessibilityValue(isActive ? "Active sort, \(indicator == .down ? "descending" : "ascending")" : "Tap to sort")
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
                        HighlightedText(item.name, query: store.filters.searchText)
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

                Text(StorageFormat.relativeOrAbsoluteDate(item.modifiedAt))
                    .foregroundStyle(.secondary)
                    .frame(width: 112, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .selectionBackground(isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name), \(StorageFormat.label(for: item.kind)), \(StorageFormat.bytes(item.displaySize))")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint("Selects this storage item")
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            store.selectedItemID = item.id
            store.openSelectedItem()
        })
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
