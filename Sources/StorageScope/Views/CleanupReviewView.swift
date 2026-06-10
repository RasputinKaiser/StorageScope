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

                        Button("Select Verified") {
                            store.selectVerifiedCleanupCandidates()
                        }
                        .disabled(store.verifiedCleanupCandidates.isEmpty)

                        Button("Clear") {
                            store.clearCleanupSelection()
                        }
                        .disabled(store.selectedCleanupCandidates.isEmpty)

                        Button(role: .destructive) {
                            store.moveSelectedCleanupCandidatesToTrash()
                        } label: {
                            Label("Move Selected", systemImage: "trash")
                        }
                        .disabled(store.selectedCleanupCandidates.isEmpty)
                    }
                }

                CleanupLaneControl(store: store)

                if store.selectedCleanupBatchContainsReviewRisk {
                    Label("Selection includes review-suggested items. Confirm each path before moving it to Trash.", systemImage: "exclamationmark.triangle.fill")
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
            }
            .padding(20)
        }
    }
}

private struct CleanupLaneControl: View {
    @ObservedObject var store: ScanStore

    private var verifiedCount: Int {
        store.cleanupCandidates.filter { $0.kind == .verifiedDuplicate && $0.confidence == .high }.count
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
                store.selectedItemID = candidate.item.id
                store.moveSelectedItemToTrash()
            }
        }
    }
}
