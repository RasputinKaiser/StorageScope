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

                if let scan = store.scan, scan.duplicateCandidateLimitReached {
                    DuplicateCandidateLimitNotice(scan: scan)
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

private struct DuplicateCandidateLimitNotice: View {
    let scan: StorageScan

    var body: some View {
        Label {
            Text("Showing largest retained same-size leads: \(scan.duplicateCandidateItemsRetained.formatted()) of \(scan.duplicateCandidateItemsConsidered.formatted()) candidate files kept for review.")
        } icon: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(.thin)
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
    @State private var showingComparison = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("\(group.count) verified copies at \(StorageFormat.bytes(group.byteSize)) each", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.green)

                Spacer()

                Button {
                    showingComparison = true
                } label: {
                    Label("Compare", systemImage: "rectangle.split.2x1")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Compare keeper and copies side-by-side")

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

            Text("One copy is the keeper and is never moved to Trash. Use a row's menu to reassign the keeper.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            DuplicateItemList(
                items: group.items,
                store: store,
                keeperItemID: store.keeperItemID(for: group),
                onSetKeeper: { item in store.setKeeper(itemID: item.id, for: group) }
            )
        }
        .padding(14)
        .cardBackground()
        .sheet(isPresented: $showingComparison) {
            KeeperComparisonSheet(
                group: group,
                keeperItemID: store.keeperItemID(for: group),
                onSetKeeper: { item in store.setKeeper(itemID: item.id, for: group) },
                onDismiss: { showingComparison = false }
            )
        }
    }
}

private struct DuplicateGroupCard: View {
    let group: DuplicateSizeGroup
    let isExpanded: Bool
    @ObservedObject var store: ScanStore
    let toggleExpanded: () -> Void

    private var isVerifying: Bool {
        store.onDemandVerification.verifyingGroupIDs.contains(group.id)
    }

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

                Button {
                    store.onDemandVerification.verify(group)
                } label: {
                    if isVerifying {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Verifying…")
                        }
                    } else {
                        Label("Verify Now", systemImage: "checkmark.seal")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isVerifying || store.isScanning)
                .help("Hash every file in this group and surface verified duplicate matches")

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(StorageFormat.bytes(group.reclaimableBytes))
                        .font(.system(.headline, design: .rounded).monospacedDigit())
                    Text("if duplicate")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            DuplicateItemList(items: visibleItems, store: store, keeperItemID: nil, onSetKeeper: nil)
        }
        .padding(14)
        .cardBackground()
    }
}

private struct DuplicateItemList: View {
    let items: [StorageItem]
    @ObservedObject var store: ScanStore
    var keeperItemID: String? = nil
    var onSetKeeper: ((StorageItem) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let isKeeper = keeperItemID == item.id
                Button {
                    store.selectedItemID = item.id
                } label: {
                    HStack {
                        Image(systemName: "doc.fill")
                            .foregroundStyle(.secondary)
                        Text(item.name)
                            .lineLimit(1)
                        if isKeeper {
                            Text("Keeper")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.green.opacity(0.14), in: Capsule())
                        }
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
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.name), file, \(StorageFormat.bytes(item.displaySize))")
                .accessibilityValue(store.selectedItemID == item.id ? "Selected" : "Not selected")
                .accessibilityHint("Selects this duplicate candidate")
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    store.selectedItemID = item.id
                    store.openSelectedItem()
                })
                .contextMenu {
                    if let onSetKeeper, !isKeeper {
                        Button {
                            onSetKeeper(item)
                        } label: {
                            Label("Set as Keeper", systemImage: "checkmark.seal")
                        }
                        Divider()
                    }
                    Button("Reveal in Finder") {
                        store.selectedItemID = item.id
                        store.revealSelectedItem()
                    }
                    Button("Copy Path") {
                        store.selectedItemID = item.id
                        store.copySelectedPath()
                    }
                }

                if index < items.index(before: items.endIndex) {
                    Divider()
                }
            }
        }
    }
}
