import StorageScopeCore
import SwiftUI

struct CleanupReviewView: View {
    @ObservedObject var store: ScanStore
    /// Keyboard navigation focus: ↑/↓ move through candidates, Space toggles the
    /// check on the selected row — batch review without touching the mouse
    /// (UX round 4).
    @FocusState private var listFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            scrollContent
                .focusable()
                .focusEffectDisabled()
                .focused($listFocused)
                .onKeyPress(.upArrow) {
                    scrollToSelection(store.selectAdjacentCleanupCandidate(offset: -1), proxy: proxy)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    scrollToSelection(store.selectAdjacentCleanupCandidate(offset: 1), proxy: proxy)
                    return .handled
                }
                .onKeyPress(.space) {
                    guard store.cleanupCandidates.contains(where: { $0.item.id == store.selectedItemID }) else {
                        return .ignored
                    }
                    store.toggleSelectedCleanupCandidate()
                    return .handled
                }
                .onKeyPress(.escape) {
                    store.clearSearchIfActive() ? .handled : .ignored
                }
        }
    }

    private func scrollToSelection(_ id: String?, proxy: ScrollViewProxy) {
        guard let id else { return }
        proxy.scrollTo(id, anchor: nil)
    }

    private var scrollContent: some View {
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
                                .font(.title3.weight(.semibold).monospacedDigit())
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
                        .padding(.vertical, 8)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                if store.cleanupCandidates.isEmpty {
                    FilterRecoveryView(
                        title: "No Review Targets",
                        systemImage: "checklist",
                        description: store.hasActiveCleanupFilters ? "No cleanup targets match the active review filters." : "Try a broader scan or enable hidden files.",
                        filters: store.activeCleanupFilterDescriptions,
                        state: store.cleanupRecoveryState,
                        clearTitle: "Clear Review Filters"
                    ) {
                        store.resetCleanupFilters()
                    }
                    .frame(minHeight: 220)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(store.cleanupCandidates) { candidate in
                            CleanupCandidateRow(
                                candidate: candidate,
                                displayName: store.filters.displayName(for: candidate.item),
                                displayPath: store.displayRelativePath(for: candidate.item),
                                isChecked: store.selectedCleanupCandidateIDs.contains(candidate.id),
                                isSelected: store.selectedItemID == candidate.item.id,
                                canTrash: store.canMoveItemToTrash(candidate.item),
                                // Excluding mid-scan would silently no-op: excludeFolder()
                                // routes through rescan(), which guards on !isScanning.
                                canExclude: candidate.item.isContainer && candidate.item.id != store.scan?.rootItem.id && !store.isScanning,
                                // Clicking both toggles and selects, so a follow-up
                                // Space/↑/↓ continues from the clicked row.
                                onToggle: {
                                    store.selectedItemID = candidate.item.id
                                    store.toggleCleanupCandidate(candidate)
                                    listFocused = true
                                },
                                onIgnore: { store.ignoreCleanupCandidate(candidate) },
                                onReveal: { store.selectedItemID = candidate.item.id; store.revealSelectedItem() },
                                onOpen: { store.selectedItemID = candidate.item.id; store.openSelectedItem() },
                                onCopyPath: { store.selectedItemID = candidate.item.id; store.copySelectedPath() },
                                onTrash: { store.moveCleanupCandidateToTrash(candidate) },
                                onExclude: { store.excludeFolder(candidate.item) },
                                onShowInTree: { store.revealInFolderTree(candidate.item) }
                            )
                            .equatable()
                            // Anchor for keyboard-driven scroll-follow (UX round 4).
                            .id(candidate.item.id)
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
        .background(statusTint.opacity(selectedCandidates.isEmpty ? 0.08 : 0.12), in: RoundedRectangle(cornerRadius: 12))
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
                        detail: store.filters.cleanupLaneFilter.detail,
                        tint: .blue
                    )
                }

                VStack(spacing: 10) {
                    CleanupLaneStat(
                        title: "Visible Reclaim",
                        value: StorageFormat.bytes(store.potentialReclaimableBytes),
                        detail: store.filters.cleanupLaneFilter.detail,
                        tint: .blue
                    )
                }
            }
        }
    }

    private var cleanupLaneBinding: Binding<CleanupLaneFilter> {
        Binding(
            get: { store.filters.cleanupLaneFilter },
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
        .cardBackground(.thin)
    }
}

private struct CleanupCandidateRow: View, Equatable {
    let candidate: CleanupCandidate
    let displayName: String
    let displayPath: String
    let isChecked: Bool
    let isSelected: Bool
    let canTrash: Bool
    let canExclude: Bool
    let onToggle: () -> Void
    let onIgnore: () -> Void
    let onReveal: () -> Void
    let onOpen: () -> Void
    let onCopyPath: () -> Void
    let onTrash: () -> Void
    let onExclude: () -> Void
    /// Context-menu drill-down into the Folder Tree (UX round 2).
    let onShowInTree: () -> Void
    @State private var isHovered = false

    static func == (lhs: CleanupCandidateRow, rhs: CleanupCandidateRow) -> Bool {
        lhs.candidate == rhs.candidate
            && lhs.isChecked == rhs.isChecked
            && lhs.isSelected == rhs.isSelected
            && lhs.canTrash == rhs.canTrash
            && lhs.canExclude == rhs.canExclude
            && lhs.displayName == rhs.displayName
            && lhs.displayPath == rhs.displayPath
    }

    var body: some View {
        Button {
            onToggle()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isChecked ? .green : .secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)

                Image(systemName: candidate.kind.systemImage)
                    .font(.title3)
                    .foregroundStyle(candidate.confidence.tint)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(displayName)
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

                    Text(displayPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .selectionBackground(isSelected: isSelected, radius: 8)
            .background(isHovered && !isSelected ? Color.primary.opacity(0.04) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableRow)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(displayName), \(candidate.kind.displayName), \(StorageFormat.bytes(candidate.reclaimableBytes))")
        .accessibilityValue(isChecked ? "Selected" : "Not selected")
        .accessibilityHint("Toggles selection for cleanup")
        .contextMenu {
            Button(isChecked ? "Unselect" : "Select") { onToggle() }
            Button("Ignore Candidate") { onIgnore() }
            Divider()
            Button("Show in Folder Tree") { onShowInTree() }
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
                                Text(store.filters.displayName(for: candidate.item))
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Text(store.displayRelativePath(for: candidate.item))
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
        .cardBackground(.thin)
    }
}
