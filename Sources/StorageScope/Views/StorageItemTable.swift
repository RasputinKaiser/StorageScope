import QuickLook
import StorageScopeCore
import SwiftUI

struct StorageItemTable: View {
    let title: String
    let subtitle: String
    let items: [StorageItem]
    @ObservedObject var store: ScanStore
    var compact = false
    var countLabel: String?
    /// Focus target for keyboard navigation: clicking any row moves focus here so
    /// ↑/↓/Space work immediately after a click (UX round 3).
    @FocusState private var tableFocused: Bool
    /// Space-bar Quick Look for the selected item — preview before deciding to trash.
    @State private var quickLookURL: URL?
    /// Type-to-select buffer (Finder-style): letters accumulate while typed within
    /// 0.8s of each other, then the buffer resets lazily on the next key.
    @State private var typeAheadBuffer = ""
    @State private var typeAheadLastKeyAt = Date.distantPast

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

            if store.activeView == .oldLargeFiles, items.count > 0, items.count <= 5 {
                OldLargeFilesThresholdHint(itemCount: items.count, days: store.oldFileAgeDays) {
                    store.rescan()
                }
            }

            VStack(spacing: 0) {
                StorageItemHeader(sortOption: store.filters.sortOption) { store.filters.sortOption = $0 }

                Divider()

                if items.isEmpty {
                    FilterRecoveryView(
                        title: "No Items",
                        systemImage: "magnifyingglass",
                        filters: store.activeDisplayFilterDescriptions,
                        state: store.displayRecoveryState,
                        clearTitle: "Clear Filters"
                    ) {
                        store.resetDisplayFilters()
                    }
                    .frame(minHeight: 220)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(items) { item in
                                    StorageItemRow(
                                        item: item,
                                        isSelected: store.selectedItemID == item.id,
                                        searchText: store.filters.searchText,
                                        displayName: store.filters.displayName(for: item),
                                        displayPath: store.displayRelativePath(for: item),
                                        fullPath: store.filters.displayPath(for: item),
                                        redactionEnabled: store.filters.redactionEnabled,
                                        canTrash: store.canMoveItemToTrash(item),
                                        // Excluding mid-scan would silently no-op: excludeFolder()
                                        // routes through rescan(), which guards on !isScanning.
                                        canExclude: item.isContainer && item.id != store.scan?.rootItem.id && !store.isScanning,
                                        onSelect: { store.selectedItemID = item.id; tableFocused = true },
                                        onOpen: { store.selectedItemID = item.id; store.openSelectedItem() },
                                        onReveal: { store.selectedItemID = item.id; store.revealSelectedItem() },
                                        onCopyPath: { store.selectedItemID = item.id; store.copySelectedPath() },
                                        onTrash: { store.selectedItemID = item.id; store.moveSelectedItemToTrash() },
                                        onExclude: { store.excludeFolder(item) },
                                        onShowInTree: { store.revealInFolderTree(item) },
                                        onQuickLook: { store.selectedItemID = item.id; quickLookURL = item.url }
                                    )
                                    .equatable()
                                    .id(item.id)
                                    Divider()
                                }
                            }
                        }
                        .frame(minHeight: listMinHeight)
                        .focusable()
                        .focusEffectDisabled()
                        .focused($tableFocused)
                        .onKeyPress(.upArrow) {
                            moveSelection(-1, proxy: proxy)
                            return .handled
                        }
                        .onKeyPress(.downArrow) {
                            moveSelection(1, proxy: proxy)
                            return .handled
                        }
                        .onKeyPress(.space) {
                            guard let selected = items.first(where: { $0.id == store.selectedItemID }) else { return .ignored }
                            quickLookURL = selected.url
                            return .handled
                        }
                        .onKeyPress(.escape) {
                            store.clearSearchIfActive() ? .handled : .ignored
                        }
                        .onKeyPress(characters: .alphanumerics, phases: .down) { press in
                            typeToSelect(press.characters, proxy: proxy)
                            return .handled
                        }
                        .quickLookPreview($quickLookURL)
                    }
                }
            }
            .cardBackground()
        }
    }

    /// Finder-style type-to-select: consecutive keystrokes within 0.8s form a prefix;
    /// a longer pause starts a fresh one. No Timer — the buffer resets lazily on the
    /// next keystroke, so idle cost is zero.
    private func typeToSelect(_ characters: String, proxy: ScrollViewProxy) {
        let now = Date()
        if now.timeIntervalSince(typeAheadLastKeyAt) > 0.8 {
            typeAheadBuffer = ""
        }
        typeAheadLastKeyAt = now
        typeAheadBuffer += characters
        guard let id = store.selectItem(matchingPrefix: typeAheadBuffer) else { return }
        proxy.scrollTo(id, anchor: nil)
    }

    /// Arrow-key navigation: the selection math lives in `ScanStore.selectAdjacentItem`
    /// (unit-tested); the view only scrolls the result into sight. No animation on the
    /// scroll — keyboard repeat (holding ↓) should track instantly, not fight a spring.
    private func moveSelection(_ offset: Int, proxy: ScrollViewProxy) {
        guard let id = store.selectAdjacentItem(offset: offset) else { return }
        proxy.scrollTo(id, anchor: nil)
    }

    /// Scales the scroll area to its content rather than reserving ~420pt for a sparse
    /// result set. Old Large Files frequently surfaces 1-3 files; leaving the old 420pt
    /// reserved produced the "600px of void below one row" complaint. When there are
    /// enough rows to overflow a card anyway, the old compact/full heights stay.
    private var listMinHeight: CGFloat {
        if compact { return items.count <= 5 ? 180 : 320 }
        return items.count <= 5 ? 220 : 420
    }
}

/// Inline hint shown above the table when Old Large Files surfaces only a handful of
/// items. The threshold is scan-time (baked into `StorageScan.oldLargeFiles`), so the
/// call-to-action is a Rescan after the user adjusts either the size filter or the
/// `oldFileAgeDays` stepper above.
private struct OldLargeFilesThresholdHint: View {
    let itemCount: Int
    let days: Int
    let onRescan: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(itemCount == 1
                    ? "Only 1 file qualifies as old."
                    : "Only \(itemCount.formatted()) files qualify as old.")
                    .font(.callout.weight(.medium))
                Text("Lower the size filter or \"Old after \(days) days\" above, then rescan to surface more.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button {
                onRescan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Rescan with the current threshold settings")
        }
        .padding(12)
        .cardBackground(.thin)
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
            // No "Kind" column: it read "File" for nearly every row (UI_PLAN.md P1.3).
            // Kind still exists as a sort option and in the row's accessibility label.
            SortableColumnHeader(label: "Modified", width: 112, alignment: .leading, isActive: isModifiedActive, indicator: sortOption == .modifiedNewest ? .down : .up) {
                onSortChange(toggleModified)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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

private struct StorageItemRow: View, Equatable {
    let item: StorageItem
    let isSelected: Bool
    let searchText: String
    let displayName: String
    /// Shown under the name — relative to the scan root (UI_PLAN.md P1.2).
    let displayPath: String
    /// Absolute (or redacted) path, surfaced via hover help only.
    let fullPath: String
    let redactionEnabled: Bool
    let canTrash: Bool
    let canExclude: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onCopyPath: () -> Void
    let onTrash: () -> Void
    let onExclude: () -> Void
    /// Context-menu drill-down into the Folder Tree (UX round 2).
    let onShowInTree: () -> Void
    /// Quick Look preview — also bound to Space at the table level (UX round 3).
    let onQuickLook: () -> Void
    @State private var isHovered = false

    // Closures are excluded: they're stable references back to the store and
    // are never the source of meaningful visual change. `@State isHovered`
    // uses the SwiftUI @State channel and must not participate here either.
    static func == (lhs: StorageItemRow, rhs: StorageItemRow) -> Bool {
        lhs.item == rhs.item && lhs.isSelected == rhs.isSelected
            && lhs.searchText == rhs.searchText && lhs.canTrash == rhs.canTrash
            && lhs.canExclude == rhs.canExclude
            && lhs.displayName == rhs.displayName && lhs.displayPath == rhs.displayPath
            && lhs.fullPath == rhs.fullPath
            && lhs.redactionEnabled == rhs.redactionEnabled
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: StorageFormat.icon(for: item))
                        .foregroundStyle(item.kind == .inaccessible ? .red : .secondary)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 2) {
                        if redactionEnabled {
                            Text(displayName)
                                .lineLimit(1)
                        } else {
                            HighlightedText(item.name, query: searchText)
                                .lineLimit(1)
                        }

                        Text(displayPath)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(fullPath)
                    }
                }
                .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)

                Text(StorageFormat.bytes(item.displaySize))
                    .font(.system(.body, design: .rounded).monospacedDigit())
                    .frame(width: 96, alignment: .trailing)

                Text(StorageFormat.relativeOrAbsoluteDate(item.modifiedAt))
                    .foregroundStyle(.secondary)
                    .frame(width: 112, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .selectionBackground(isSelected: isSelected)
            .background(isHovered && !isSelected ? Color.primary.opacity(0.04) : Color.clear)
        }
        .buttonStyle(.pressableRow)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(displayName), \(StorageFormat.label(for: item.kind)), \(StorageFormat.bytes(item.displaySize))")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint("Selects this storage item")
        .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen() })
        .contextMenu {
            Button("Quick Look") { onQuickLook() }
            Button("Show in Folder Tree") { onShowInTree() }
            Divider()
            Button("Reveal in Finder") { onReveal() }
            Button("Open") { onOpen() }
            Button("Copy Path") { onCopyPath() }
            if canExclude {
                Divider()
                Button("Exclude This Folder") { onExclude() }
            }
            Divider()
            Button("Move to Trash", role: .destructive) { onTrash() }
                .disabled(!canTrash)
        }
    }
}
