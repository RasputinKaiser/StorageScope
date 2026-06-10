import StorageScopeCore
import SwiftUI

struct DuplicateCandidatesView: View {
    @ObservedObject var store: ScanStore

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
                    ContentUnavailableView(
                        "No Duplicate Leads",
                        systemImage: "checkmark.seal",
                        description: Text("Try lowering the size filter or scanning a broader folder.")
                    )
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
                                DuplicateGroupCard(group: group, store: store)
                            }
                        }
                    }
                }
            }
            .padding(20)
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
    @ObservedObject var store: ScanStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("\(group.count) files at \(StorageFormat.bytes(group.byteSize)) each", systemImage: "doc.on.doc")
                    .font(.headline)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(StorageFormat.bytes(group.reclaimableBytes))
                        .font(.system(.headline, design: .rounded).monospacedDigit())
                    Text("if duplicate")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            DuplicateItemList(items: Array(group.items.prefix(8)), store: store)
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
