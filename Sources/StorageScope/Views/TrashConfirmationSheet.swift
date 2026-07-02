import StorageScopeCore
import SwiftUI

/// Bundles the closures + lifecycle state `TrashConfirmationSheet` needs from the store.
/// Keeps the sheet's initializer to two parameters (plan + actions) instead of six.
struct TrashReviewActions {
    let isMoving: Bool
    let reveal: (TrashReviewPlan.Item) -> Void
    let revealAll: ([TrashReviewPlan.Item]) -> Void
    let open: (TrashReviewPlan.Item) -> Void
    let remove: (TrashReviewPlan.Item) -> Void
    let removeAll: ([TrashReviewPlan.Item]) -> Void
    let cancel: () -> Void
    let confirm: () -> Void
}

struct TrashConfirmationSheet: View {
    let plan: TrashReviewPlan
    @ObservedObject var filters: FilterStore
    let actions: TrashReviewActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Label(plan.title, systemImage: "trash")
                    .font(.title3.weight(.semibold))

                Text(summaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if actions.isMoving {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Moving items to Trash…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !plan.verifiedItems.isEmpty {
                        TrashReviewSection(
                            title: L10n.string("Verified Duplicates"),
                            subtitle: "Content-hashed copies. Keep one copy and confirm the listed paths.",
                            systemImage: "checkmark.seal.fill",
                            tint: .green,
                            items: plan.verifiedItems,
                            filters: filters,
                            reveal: actions.reveal,
                            revealAll: actions.revealAll,
                            open: actions.open,
                            remove: actions.remove,
                            removeAll: actions.removeAll,
                            isMoving: actions.isMoving
                        )
                    }

                    if !plan.reviewItems.isEmpty {
                        TrashReviewSection(
                            title: L10n.string("Review Before Moving"),
                            subtitle: "Suggestions are not duplicate proof. Inspect each path before confirming.",
                            systemImage: "exclamationmark.octagon.fill",
                            tint: .orange,
                            items: plan.reviewItems,
                            filters: filters,
                            reveal: actions.reveal,
                            revealAll: actions.revealAll,
                            open: actions.open,
                            remove: actions.remove,
                            removeAll: actions.removeAll,
                            isMoving: actions.isMoving
                        )
                    }
                }
                .padding(20)
            }
            .frame(minHeight: 260)
            .disabled(actions.isMoving)

            Divider()

            HStack {
                Text(L10n.string("Items can usually be restored from Finder Trash."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(L10n.string("Cancel"), role: .cancel) {
                    actions.cancel()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(actions.isMoving)

                Button(L10n.string("Move to Trash"), role: .destructive) {
                    actions.confirm()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(actions.isMoving)
            }
            .padding(20)
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 520)
    }

    private var summaryText: String {
        let reclaim = StorageFormat.bytes(plan.estimatedReclaimBytes)
        if plan.containsReviewRisk {
            return String(format: L10n.string("Estimated reclaim: %@. This batch includes review-suggested items."), reclaim)
        }
        return String(format: L10n.string("Estimated reclaim: %@. This batch contains verified duplicate cleanup items."), reclaim)
    }
}

private struct TrashReviewSection: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let items: [TrashReviewPlan.Item]
    let filters: FilterStore
    let reveal: (TrashReviewPlan.Item) -> Void
    let revealAll: ([TrashReviewPlan.Item]) -> Void
    let open: (TrashReviewPlan.Item) -> Void
    let remove: (TrashReviewPlan.Item) -> Void
    let removeAll: ([TrashReviewPlan.Item]) -> Void
    let isMoving: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .foregroundStyle(tint)

                Spacer()

                Text("\(items.count.formatted()) \(items.count == 1 ? "item" : "items")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if items.count > 1 {
                    Button {
                        revealAll(items)
                    } label: {
                        Label("Reveal All", systemImage: "rectangle.on.rectangle")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(isMoving)
                    .help("Reveal all \(items.count.formatted()) items in Finder")

                    Button(role: .destructive) {
                        removeAll(items)
                    } label: {
                        Label("Remove All", systemImage: "minus.circle.fill")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(isMoving)
                    .help("Remove all \(items.count.formatted()) \(items.count == 1 ? "item" : "items") from this batch")
                }
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                let lastItemID = items.last?.id
                ForEach(items) { item in
                    TrashReviewRow(item: item, filters: filters, reveal: reveal, open: open, remove: remove, isMoving: isMoving)

                    if item.id != lastItemID {
                        Divider()
                    }
                }
            }
            .cardBackground()
        }
    }
}

private struct TrashReviewRow: View {
    let item: TrashReviewPlan.Item
    let filters: FilterStore
    let reveal: (TrashReviewPlan.Item) -> Void
    let open: (TrashReviewPlan.Item) -> Void
    let remove: (TrashReviewPlan.Item) -> Void
    let isMoving: Bool

    private var displayName: String {
        filters.displayName(forURL: item.url, isDirectory: item.isDirectory)
    }

    private var displayParentPath: String {
        filters.displayParentPath(forURL: item.url)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: item.isVerified ? "checkmark.seal.fill" : item.kind.systemImage)
                .foregroundStyle(item.isVerified ? .green : .orange)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    Text(StorageFormat.bytes(item.reclaimableBytes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(displayParentPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(item.reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Button {
                open(item)
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
                    .labelStyle(.iconOnly)
            }
            .help("Open \(displayName) in its default app")

            Button {
                reveal(item)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
                    .labelStyle(.iconOnly)
            }
            .help("Reveal \(displayName) in Finder")

            Button {
                remove(item)
            } label: {
                Label("Remove from batch", systemImage: "minus.circle")
                    .labelStyle(.iconOnly)
            }
            .help("Remove \(displayName) from this Trash batch")
            .disabled(isMoving)
        }
        .padding(12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayName), \(StorageFormat.bytes(item.reclaimableBytes))")
    }
}
