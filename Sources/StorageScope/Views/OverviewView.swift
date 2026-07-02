import StorageScopeCore
import SwiftUI

struct OverviewView: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if store.scan != nil {
                    ScanLimitsDisclosure(
                        rankedResultsCap: store.scanRankedResultsCap,
                        duplicateThresholdMB: store.duplicateCandidateThresholdMB,
                        retainedItemsCap: store.scanRetainedItemsCap
                    )

                    ReclaimPlanView(
                        plan: store.reclaimPlan,
                        activeFilters: store.activeCleanupFilterDescriptions
                    ) {
                        store.resetCleanupFilters()
                    } perform: { action in
                        perform(action)
                    }

                    let allOverviewItems = store.items(for: .overview)

                    SizeDistributionView(store: store, overviewItems: allOverviewItems)

                    let overviewItems = Array(allOverviewItems.prefix(12))
                    let isFiltered = store.hasActiveDisplayFilters
                    let childrenTable = StorageItemTable(
                        title: isFiltered ? "Matching Children" : "Largest Children",
                        subtitle: isFiltered ? "Immediate children matching the active filters" : "Immediate storage pressure under the scanned root",
                        items: overviewItems,
                        store: store,
                        compact: true,
                        countLabel: previewCountLabel(visible: overviewItems.count, total: allOverviewItems.count)
                    )

                    // Side-by-side when the detail column is wide enough; otherwise the
                    // insight cards drop below the table instead of squeezing it
                    // (UI_PLAN.md P1.4 pulled forward to keep 1280×800 clip-free).
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            childrenTable
                                .frame(minWidth: 560)

                            insightCards(isFiltered: isFiltered)
                                .frame(width: 280)
                        }

                        VStack(alignment: .leading, spacing: 16) {
                            childrenTable

                            insightCards(isFiltered: isFiltered)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func insightCards(isFiltered: Bool) -> some View {
        VStack(spacing: 16) {
            InsightCard(
                title: isFiltered ? "Largest Matching File" : "Largest File",
                item: store.items(for: .largestFiles).first,
                systemImage: "doc.fill",
                filters: store.filters
            ) { item in
                store.selectedItemID = item.id
            }
            InsightCard(
                title: isFiltered ? "Largest Matching Folder" : "Largest Folder",
                item: store.items(for: .largestFolders).first,
                systemImage: "folder.fill",
                filters: store.filters
            ) { item in
                store.selectedItemID = item.id
            }
            InsightCard(
                title: isFiltered ? "Oldest Matching Large File" : "Oldest Large File",
                item: store.oldLargeFiles.first,
                systemImage: "clock.fill",
                filters: store.filters
            ) { item in
                store.selectedItemID = item.id
            }
        }
    }

    private func perform(_ action: ReclaimPlanAction) {
        switch action {
        case .reviewVerifiedDuplicates:
            store.setCleanupLaneFilter(.verified)
            store.selectVerifiedCleanupCandidates()
            store.selectedView = .cleanupReview
        case .reviewCleanupSuggestions:
            store.setCleanupLaneFilter(.suggestions)
            store.selectedView = .cleanupReview
        case .inspectInaccessibleItems:
            store.selectedView = .tree
        }
    }
}

/// Collapsed-by-default disclosure stating the active scan bounds. Without this, a ranked
/// list capped at 800 or a duplicate group missing because a file fell under the configured
/// threshold reads as "broken" rather than "working as designed" — see 6.1-PLAN.md U-3.
private struct ScanLimitsDisclosure: View {
    let rankedResultsCap: Int
    let duplicateThresholdMB: Int
    let retainedItemsCap: Int

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                Text("Largest Files, Largest Folders, and similar ranked lists show the top \(rankedResultsCap.formatted()) matches.")
                Text("Duplicate detection considers files \(duplicateThresholdMB) MB or larger.")
                Text("Folder Tree and Storage Map retain up to \(retainedItemsCap.formatted()) of the largest items.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        } label: {
            Label("Scan limits", systemImage: "info.circle")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Scan limits disclosure")
    }
}

private func previewCountLabel(visible: Int, total: Int) -> String {
    guard total > visible else {
        return "\(visible.formatted()) items"
    }
    return "Showing \(visible.formatted()) of \(total.formatted())"
}

private struct ReclaimPlanView: View {
    let plan: ReclaimPlan
    let activeFilters: [String]
    let clearFilters: () -> Void
    let perform: (ReclaimPlanAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reclaim Plan")
                        .font(.headline)
                    Text("Separate verified duplicate reclaim from review-only suggestions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let primaryAction = plan.primaryAction {
                    Button {
                        perform(primaryAction)
                    } label: {
                        Label(primaryAction.title, systemImage: primaryAction.systemImage)
                    }
                }
            }

            if plan.sections.isEmpty {
                if activeFilters.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("No reclaim actions found for this scan.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .cardBackground()
                } else {
                    FilterRecoveryView(
                        title: "No Reclaim Actions",
                        systemImage: "checkmark.circle",
                        description: "No reclaim actions match the active filters.",
                        filters: activeFilters,
                        clearTitle: "Clear Reclaim Filters",
                        clearAction: clearFilters
                    )
                    .frame(minHeight: 130)
                    .cardBackground()
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        ForEach(plan.sections) { section in
                            ReclaimPlanSectionCard(section: section, perform: perform)
                        }
                    }

                    VStack(spacing: 12) {
                        ForEach(plan.sections) { section in
                            ReclaimPlanSectionCard(section: section, perform: perform)
                        }
                    }
                }
            }
        }
    }
}

private struct ReclaimPlanSectionCard: View {
    let section: ReclaimPlanSection
    let perform: (ReclaimPlanAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: section.kind.systemImage)
                    .font(.title3)
                    .foregroundStyle(section.kind.tint)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(section.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.kind == .inaccessibleItems ? "\(section.itemCount.formatted())" : StorageFormat.bytes(section.reclaimableBytes))
                        .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
                    Text(section.kind == .inaccessibleItems ? "access gaps" : "\(section.itemCount.formatted()) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let action = section.action {
                    Button {
                        perform(action)
                    } label: {
                        Label(action.shortTitle, systemImage: action.systemImage)
                            .labelStyle(.iconOnly)
                    }
                    .help(action.title)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
        .cardBackground()
    }
}

private struct SizeDistributionView: View {
    @ObservedObject var store: ScanStore
    let overviewItems: [StorageScopeCore.StorageItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let items = Array(overviewItems.prefix(10))

            VStack(alignment: .leading, spacing: 3) {
                Text("Storage Map")
                    .font(.headline)
                Text(storageMapSubtitle(visible: items.count, total: overviewItems.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if store.scan != nil {
                let maxSize = max(items.map(\.displaySize).max() ?? 1, 1)

                if items.isEmpty {
                    FilterRecoveryView(
                        title: "No Storage Map Matches",
                        systemImage: "magnifyingglass",
                        description: store.hasActiveDisplayFilters ? "No root-level items match the active display filters." : "No root-level items are available for this scan.",
                        filters: store.activeDisplayFilterDescriptions,
                        state: store.displayRecoveryState,
                        clearTitle: "Clear Filters"
                    ) {
                        store.resetDisplayFilters()
                    }
                    .frame(minHeight: 180)
                    .cardBackground()
                } else {
                    VStack(spacing: 0) {
                        let lastItemID = items.last?.id
                        ForEach(items) { item in
                            StorageMapRow(
                                item: item,
                                maxSize: maxSize,
                                isSelected: store.selectedItemID == item.id,
                                displayName: store.filters.displayName(for: item),
                                onTap: {
                                    store.selectedItemID = item.id
                                },
                                onShowInTree: {
                                    store.revealInFolderTree(item)
                                }
                            )
                            .equatable()
                            if item.id != lastItemID {
                                Divider()
                            }
                        }
                    }
                    .cardBackground()
                }
            }
        }
    }

    private func storageMapSubtitle(visible: Int, total: Int) -> String {
        let scope = store.hasActiveDisplayFilters ? "Filtered folders and packages" : "Top folders and packages"
        guard total > visible else {
            return "\(scope) inside the scanned root"
        }
        return "\(scope) inside the scanned root, showing \(visible.formatted()) of \(total.formatted())"
    }
}

private struct StorageMapRow: View, Equatable {
    let item: StorageScopeCore.StorageItem
    let maxSize: Int64
    let isSelected: Bool
    let displayName: String
    let onTap: () -> Void
    /// Drill-down: opens this folder in the Folder Tree with ancestors expanded.
    let onShowInTree: () -> Void
    @State private var isHovered = false

    // Excludes `onTap`: closures aren't Equatable and every row's closure is
    // freshly allocated per render anyway, same pattern as StorageItemRow.
    static func == (lhs: StorageMapRow, rhs: StorageMapRow) -> Bool {
        lhs.item == rhs.item && lhs.maxSize == rhs.maxSize && lhs.isSelected == rhs.isSelected
            && lhs.displayName == rhs.displayName
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: StorageFormat.icon(for: item))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(displayName)
                            .lineLimit(1)
                        Spacer()
                        if isHovered {
                            Button(action: onShowInTree) {
                                Image(systemName: "arrow.right.circle")
                                    .foregroundStyle(.tint)
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .help("Show in Folder Tree")
                            .accessibilityLabel("Show \(displayName) in Folder Tree")
                        }
                        Text(StorageFormat.bytes(item.displaySize))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    SizeBar(
                        fraction: Double(item.displaySize) / Double(maxSize),
                        fill: .tint.opacity(0.85)
                    )
                    .frame(height: 8)
                    .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .selectionBackground(isSelected: isSelected)
            .background(isHovered && !isSelected ? Color.primary.opacity(0.04) : Color.clear)
        }
        .buttonStyle(.pressableRow)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(displayName), \(StorageFormat.bytes(item.displaySize))")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint("Selects this storage item")
        .simultaneousGesture(TapGesture(count: 2).onEnded { onShowInTree() })
        .contextMenu {
            Button("Show in Folder Tree") { onShowInTree() }
        }
    }
}

private struct InsightCard: View {
    let title: String
    let item: StorageScopeCore.StorageItem?
    let systemImage: String
    let filters: FilterStore
    var onTap: ((StorageScopeCore.StorageItem) -> Void)? = nil

    var body: some View {
        if let item, let onTap {
            Button { onTap(item) } label: { cardLabel }
                .buttonStyle(.plain)
        } else {
            cardLabel
        }
    }

    private var cardLabel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                Spacer()
                if item != nil && onTap != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }

            if let item {
                Text(filters.displayName(for: item))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text(StorageFormat.bytes(item.displaySize))
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text(filters.displayParentPath(for: item))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            } else {
                Text("No matching item")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
        .cardBackground()
        .contentShape(Rectangle())
    }
}

private extension ReclaimPlanSection.Kind {
    var systemImage: String {
        switch self {
        case .verifiedDuplicates:
            return "checkmark.seal.fill"
        case .reviewSuggestions:
            return "exclamationmark.circle.fill"
        case .inaccessibleItems:
            return "lock.fill"
        }
    }

    var tint: Color {
        switch self {
        case .verifiedDuplicates:
            return .green
        case .reviewSuggestions:
            return .orange
        case .inaccessibleItems:
            return .red
        }
    }
}

private extension ReclaimPlanAction {
    var title: String {
        switch self {
        case .reviewVerifiedDuplicates:
            return "Review Verified Duplicates"
        case .reviewCleanupSuggestions:
            return "Review Suggestions"
        case .inspectInaccessibleItems:
            return "Inspect Access Gaps"
        }
    }

    var shortTitle: String {
        switch self {
        case .reviewVerifiedDuplicates:
            return "Review"
        case .reviewCleanupSuggestions:
            return "Suggestions"
        case .inspectInaccessibleItems:
            return "Inspect"
        }
    }

    var systemImage: String {
        switch self {
        case .reviewVerifiedDuplicates:
            return "arrow.right.circle"
        case .reviewCleanupSuggestions:
            return "list.bullet.clipboard"
        case .inspectInaccessibleItems:
            return "list.bullet.indent"
        }
    }
}
