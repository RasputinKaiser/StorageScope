import StorageScopeCore
import SwiftUI

struct CleanupReviewView: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Cleanup Review")
                            .font(.headline)
                        Text("Filter reclaim leads by confidence before selecting anything destructive.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    HStack(spacing: 10) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(StorageFormat.bytes(store.selectedCleanupCandidates.isEmpty ? store.potentialReclaimableBytes : store.selectedReclaimableBytes))
                                .font(.title3.weight(.semibold))
                            Text(store.selectedCleanupCandidates.isEmpty ? "potential reclaim" : "selected reclaim")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Button("Verified") {
                            store.selectVerifiedCleanupCandidates()
                        }
                        .help("Select verified duplicate cleanup items")
                        .disabled(store.verifiedCleanupCandidates.isEmpty)

                        Button("Select All") {
                            store.selectAllVisibleCleanupCandidates()
                        }
                        .help("Select all visible cleanup items")
                        .disabled(store.cleanupCandidates.isEmpty || store.allVisibleCleanupCandidatesSelected)

                        Button("Clear") {
                            store.clearCleanupSelection()
                        }
                        .help("Clear cleanup selection")
                        .disabled(store.selectedCleanupCandidates.isEmpty)

                        Button(role: .destructive) {
                            store.moveSelectedCleanupCandidatesToTrash()
                        } label: {
                            Label("Move", systemImage: "trash")
                        }
                        .help("Move selected cleanup items to Trash")
                        .disabled(store.selectedCleanupCandidates.isEmpty)
                    }
                }

                CleanupLaneControl(store: store)

                if !store.cleanupCandidates.isEmpty {
                    CleanupSelectionSummary(store: store)
                }

                if store.selectedCleanupBatchContainsReviewRisk {
                    Label("Selection includes review-suggested items. Confirm each path before moving it to Trash.", systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                if store.cleanupCandidates.isEmpty {
                    FilterRecoveryView(
                        title: "No Review Targets",
                        systemImage: "checklist",
                        description: store.hasActiveCleanupFilters ? "No cleanup targets match the active review filters." : "Try a broader scan or enable hidden files.",
                        filters: store.activeCleanupFilterDescriptions,
                        clearTitle: "Clear Review Filters"
                    ) {
                        store.resetCleanupFilters()
                    }
                    .frame(minHeight: 340)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(store.cleanupCandidates) { candidate in
                            CleanupCandidateRow(candidate: candidate, store: store)
                        }
                    }
                }

                if !store.ignoredCleanupCandidates.isEmpty {
                    IgnoredCleanupSection(store: store)
                }
            }
            .padding(20)
        }
    }
}

private struct CleanupSelectionSummary: View {
    @ObservedObject var store: ScanStore

    private var selectedCandidates: [CleanupCandidate] {
        store.selectedCleanupCandidates
    }

    private var batchCandidates: [CleanupCandidate] {
        store.selectedCleanupBatchCandidates
    }

    private var selectedCountText: String {
        if selectedCandidates.count == batchCandidates.count {
            return "\(batchCandidates.count.formatted()) selected"
        }
        return "\(batchCandidates.count.formatted()) top-level of \(selectedCandidates.count.formatted()) selected"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: selectedCandidates.isEmpty ? "circle.dashed" : statusIcon)
                .font(.title3)
                .foregroundStyle(statusTint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if !selectedCandidates.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(StorageFormat.bytes(store.selectedReclaimableBytes))
                        .font(.system(.subheadline, design: .rounded).weight(.semibold).monospacedDigit())
                    Text("selected reclaim")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(statusTint.opacity(selectedCandidates.isEmpty ? 0.08 : 0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var title: String {
        guard !selectedCandidates.isEmpty else {
            return "No cleanup items selected"
        }
        return "\(selectedCountText) for Trash review"
    }

    private var detail: String {
        guard !selectedCandidates.isEmpty else {
            return "Use Verified for content-matched duplicates, or choose individual rows after checking their paths."
        }
        if store.selectedCleanupBatchContainsReviewRisk {
            return "This batch includes review-suggested items. Confirm every path before moving it to Trash."
        }
        return "Verified duplicate batch only. StorageScope will still ask for confirmation before moving anything to Trash."
    }

    private var statusIcon: String {
        store.selectedCleanupBatchContainsReviewRisk ? "exclamationmark.circle.fill" : "checkmark.seal.fill"
    }

    private var statusTint: Color {
        if selectedCandidates.isEmpty {
            return .secondary
        }
        return store.selectedCleanupBatchContainsReviewRisk ? .orange : .green
    }
}

private struct CleanupLaneControl: View {
    @ObservedObject var store: ScanStore

    private var verifiedCount: Int {
        store.cleanupCandidates.filter(\.isHighConfidenceVerifiedDuplicate).count
    }

    private var suggestionCount: Int {
        store.cleanupCandidates.count - verifiedCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Cleanup lane", selection: cleanupLaneBinding) {
                ForEach(CleanupLaneFilter.allCases) { lane in
                    Text(lane.title).tag(lane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    CleanupLaneStat(
                        title: "Visible Verified",
                        value: verifiedCount.formatted(),
                        detail: "safe batch review",
                        tint: .green
                    )
                    CleanupLaneStat(
                        title: "Visible Suggestions",
                        value: suggestionCount.formatted(),
                        detail: "manual decisions",
                        tint: .orange
                    )
                    CleanupLaneStat(
                        title: "Visible Reclaim",
                        value: StorageFormat.bytes(store.potentialReclaimableBytes),
                        detail: store.cleanupLaneFilter.detail,
                        tint: .blue
                    )
                }

                VStack(spacing: 10) {
                    CleanupLaneStat(
                        title: "Visible Reclaim",
                        value: StorageFormat.bytes(store.potentialReclaimableBytes),
                        detail: store.cleanupLaneFilter.detail,
                        tint: .blue
                    )
                }
            }
        }
    }

    private var cleanupLaneBinding: Binding<CleanupLaneFilter> {
        Binding(
            get: { store.cleanupLaneFilter },
            set: { store.setCleanupLaneFilter($0) }
        )
    }
}

private struct CleanupLaneStat: View {
    let title: String
    let value: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline.monospacedDigit())
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CleanupCandidateRow: View {
    let candidate: CleanupCandidate
    @ObservedObject var store: ScanStore

    var body: some View {
        Button {
            store.toggleCleanupCandidate(candidate)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: store.selectedCleanupCandidateIDs.contains(candidate.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(store.selectedCleanupCandidateIDs.contains(candidate.id) ? .green : .secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)

                Image(systemName: candidate.kind.systemImage)
                    .font(.title3)
                    .foregroundStyle(candidate.confidence.tint)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(candidate.item.name)
                            .font(.headline)
                            .lineLimit(1)

                        Text(candidate.kind.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(candidate.confidence.tint)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(candidate.confidence.tint.opacity(0.14), in: Capsule())

                        Spacer()

                        Text(StorageFormat.bytes(candidate.reclaimableBytes))
                            .font(.system(.headline, design: .rounded).monospacedDigit())
                    }

                    Text(candidate.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    Text(candidate.item.url.path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(store.selectedItemID == candidate.item.id ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(candidate.item.name), \(candidate.kind.displayName), \(StorageFormat.bytes(candidate.reclaimableBytes))")
        .accessibilityValue(store.selectedCleanupCandidateIDs.contains(candidate.id) ? "Selected" : "Not selected")
        .accessibilityHint("Toggles selection for cleanup")
        .contextMenu {
            Button(store.selectedCleanupCandidateIDs.contains(candidate.id) ? "Unselect" : "Select") {
                store.toggleCleanupCandidate(candidate)
            }
            Button("Ignore Candidate") {
                store.ignoreCleanupCandidate(candidate)
            }
            Divider()
            Button("Reveal in Finder") {
                store.selectedItemID = candidate.item.id
                store.revealSelectedItem()
            }
            Button("Open") {
                store.selectedItemID = candidate.item.id
                store.openSelectedItem()
            }
            Button("Copy Path") {
                store.selectedItemID = candidate.item.id
                store.copySelectedPath()
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                store.moveCleanupCandidateToTrash(candidate)
            }
            .disabled(!store.canMoveItemToTrash(candidate.item))
        }
    }
}

private struct IgnoredCleanupSection: View {
    @ObservedObject var store: ScanStore
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                HStack {
                    Label("Ignored (\(store.ignoredCleanupCandidates.count.formatted()))", systemImage: "eye.slash")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.ignoredCleanupCandidates) { candidate in
                        HStack(spacing: 10) {
                            Image(systemName: candidate.kind.systemImage)
                                .foregroundStyle(candidate.confidence.tint)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.item.name)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Text(candidate.item.url.path)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 8)
                            Button {
                                store.unignoreCleanupCandidate(candidate)
                            } label: {
                                Label("Restore", systemImage: "arrow.uturn.backward")
                                    .labelStyle(.iconOnly)
                            }
                            .help("Restore this candidate to the review list")
                        }
                        .padding(.vertical, 4)
                    }

                    Button("Restore All Ignored", role: .cancel) {
                        store.clearIgnoredCleanupCandidates()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
