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
                        Text("High-signal reclaim targets. StorageScope never deletes automatically.")
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

                        Button("Select All") {
                            store.selectAllCleanupCandidates()
                        }
                        .disabled(store.cleanupCandidates.isEmpty)

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

                if store.cleanupCandidates.isEmpty {
                    ContentUnavailableView(
                        "No Review Targets",
                        systemImage: "checklist",
                        description: Text("Try a broader scan, lower the size filter, or enable hidden files.")
                    )
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

private extension CleanupCandidate.Kind {
    var displayName: String {
        switch self {
        case .verifiedDuplicate:
            return "Verified Duplicate"
        case .oldLargeFile:
            return "Old Large File"
        case .archive:
            return "Archive"
        case .installer:
            return "Installer"
        case .diskImage:
            return "Disk Image"
        case .cacheFolder:
            return "Cache Folder"
        case .buildArtifact:
            return "Build Artifact"
        case .temporary:
            return "Temporary"
        }
    }

    var systemImage: String {
        switch self {
        case .verifiedDuplicate:
            return "checkmark.seal.fill"
        case .oldLargeFile:
            return "clock.badge.exclamationmark"
        case .archive:
            return "archivebox.fill"
        case .installer:
            return "shippingbox.fill"
        case .diskImage:
            return "externaldrive.fill"
        case .cacheFolder:
            return "folder.badge.gearshape"
        case .buildArtifact:
            return "hammer.fill"
        case .temporary:
            return "timer"
        }
    }
}

private extension CleanupCandidate.Confidence {
    var tint: Color {
        switch self {
        case .high:
            return .green
        case .medium:
            return .orange
        case .review:
            return .blue
        }
    }
}
