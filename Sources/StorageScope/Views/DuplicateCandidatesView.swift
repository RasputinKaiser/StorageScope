import StorageScopeCore
import SwiftUI

struct DuplicateCandidatesView: View {
    @ObservedObject var store: ScanStore
    @State private var expandedCandidateGroupIDs = Set<String>()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Duplicate Review")
                        .font(.headline)
                    Text("Verified duplicates are content-hashed. Same-size candidates remain separated as review leads.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if store.verifiedDuplicateGroups.isEmpty && store.duplicateGroups.isEmpty {
                    FilterRecoveryView(
                        title: "No Duplicate Leads",
                        systemImage: "checkmark.seal",
                        description: store.hasActiveDisplayFilters ? "No duplicate leads match the active display filters." : "Try scanning a broader folder.",
                        filters: store.activeDisplayFilterDescriptions,
                        clearTitle: "Clear Filters"
                    ) {
                        store.resetDisplayFilters()
                    }
                    .frame(minHeight: 320)
                } else {
                    LazyVStack(spacing: 12) {
                        if !store.verifiedDuplicateGroups.isEmpty {
                            SectionHeader(title: "Verified Duplicates", subtitle: "\(StorageFormat.bytes(store.verifiedDuplicateGroups.reduce(Int64(0)) { $0 + $1.reclaimableBytes })) safely reviewable")
                            ForEach(store.verifiedDuplicateGroups) { group in
                                VerifiedDuplicateGroupCard(group: group, store: store)
                            }
                        }

                        if !store.duplicateGroups.isEmpty {
                            SectionHeader(title: "Same-Size Candidates", subtitle: "Same byte size, not content verified")
                            ForEach(store.duplicateGroups) { group in
                                DuplicateGroupCard(
                                    group: group,
                                    isExpanded: expandedCandidateGroupIDs.contains(group.id),
                                    store: store
                                ) {
                                    toggleCandidateGroup(group)
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func toggleCandidateGroup(_ group: DuplicateSizeGroup) {
        if expandedCandidateGroupIDs.contains(group.id) {
            expandedCandidateGroupIDs.remove(group.id)
        } else {
            expandedCandidateGroupIDs.insert(group.id)
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
            Spacer()
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }
}

private struct VerifiedDuplicateGroupCard: View {
    let group: VerifiedDuplicateGroup
    @ObservedObject var store: ScanStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("\(group.count) verified copies at \(StorageFormat.bytes(group.byteSize)) each", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.green)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(StorageFormat.bytes(group.reclaimableBytes))
                        .font(.system(.headline, design: .rounded).monospacedDigit())
                    Text("reclaimable")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text("SHA-256 \(group.checksum.prefix(16))...")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)

            DuplicateItemList(items: group.items, store: store)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DuplicateGroupCard: View {
    let group: DuplicateSizeGroup
    let isExpanded: Bool
    @ObservedObject var store: ScanStore
    let toggleExpanded: () -> Void

    private var visibleItems: [StorageItem] {
        isExpanded ? group.items : Array(group.items.prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("\(group.count) files at \(StorageFormat.bytes(group.byteSize)) each", systemImage: "doc.on.doc")
                    .font(.headline)

                if group.items.count > 8 {
                    Button {
                        toggleExpanded()
                    } label: {
                        Label(
                            isExpanded ? "Show first 8" : "Show all \(group.count.formatted())",
                            systemImage: isExpanded ? "chevron.up.circle" : "ellipsis.circle"
                        )
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                    .help(isExpanded ? "Collapse this same-size group" : "Show every file in this same-size group")
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(StorageFormat.bytes(group.reclaimableBytes))
                        .font(.system(.headline, design: .rounded).monospacedDigit())
                    Text("if duplicate")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            DuplicateItemList(items: visibleItems, store: store)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DuplicateItemList: View {
    let items: [StorageItem]
    @ObservedObject var store: ScanStore

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                Button {
                    store.selectedItemID = item.id
                } label: {
                    HStack {
                        Image(systemName: "doc.fill")
                            .foregroundStyle(.secondary)
                        Text(item.name)
                            .lineLimit(1)
                        Spacer()
                        Text(item.url.deletingLastPathComponent().path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if item.id != items.last?.id {
                    Divider()
                }
            }
        }
    }
}
