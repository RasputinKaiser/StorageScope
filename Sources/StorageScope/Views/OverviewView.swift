import StorageScopeCore
import SwiftUI

struct OverviewView: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if store.scan != nil {
                    ReclaimPlanView(
                        plan: store.reclaimPlan,
                        activeFilters: store.activeCleanupFilterDescriptions
                    ) {
                        store.resetCleanupFilters()
                    } perform: { action in
                        perform(action)
                    }

                    SizeDistributionView(store: store)

                    let overviewItems = Array(store.items(for: .overview).prefix(12))
                    HStack(alignment: .top, spacing: 16) {
                        StorageItemTable(
                            title: "Largest Children",
                            subtitle: "Immediate storage pressure under the scanned root",
                            items: overviewItems,
                            store: store,
                            compact: true
                        )

                        VStack(spacing: 16) {
                            InsightCard(
                                title: "Largest File",
                                item: store.items(for: .largestFiles).first,
                                systemImage: "doc.fill"
                            )
                            InsightCard(
                                title: "Largest Folder",
                                item: store.items(for: .largestFolders).first,
                                systemImage: "folder.fill"
                            )
                            InsightCard(
                                title: "Oldest Large File",
                                item: store.oldLargeFiles.first,
                                systemImage: "clock.fill"
                            )
                        }
                        .frame(width: 280)
                    }
                }
            }
            .padding(20)
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
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
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
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SizeDistributionView: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Storage Map")
                    .font(.headline)
                Text("Top folders and packages inside the scanned root")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if store.scan != nil {
                let items = Array(store.items(for: .overview).prefix(10))
                let maxSize = max(items.first?.displaySize ?? 1, 1)

                VStack(spacing: 8) {
                    ForEach(items) { item in
                        Button {
                            store.selectedItemID = item.id
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: StorageFormat.icon(for: item))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(item.name)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(StorageFormat.bytes(item.displaySize))
                                            .foregroundStyle(.secondary)
                                    }

                                    GeometryReader { geometry in
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(.quaternary)
                                            .overlay(alignment: .leading) {
                                                RoundedRectangle(cornerRadius: 4)
                                                    .fill(.tint.opacity(0.85))
                                                    .frame(width: max(8, geometry.size.width * CGFloat(Double(item.displaySize) / Double(maxSize))))
                                            }
                                    }
                                    .frame(height: 8)
                                }
                            }
                            .padding(10)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct InsightCard: View {
    let title: String
    let item: StorageScopeCore.StorageItem?
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                Spacer()
            }

            if let item {
                Text(item.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text(StorageFormat.bytes(item.displaySize))
                    .font(.title3.weight(.semibold))
                Text(item.url.path)
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension ReclaimPlanSection.Kind {
    var systemImage: String {
        switch self {
        case .verifiedDuplicates:
            return "checkmark.seal.fill"
        case .reviewSuggestions:
            return "exclamationmark.triangle.fill"
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
            return "Review"
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
