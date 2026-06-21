import StorageScopeCore
import SwiftUI

struct KeeperComparisonSheet: View {
    let group: VerifiedDuplicateGroup
    let keeperItemID: String?
    let onSetKeeper: (StorageItem) -> Void
    let onDismiss: () -> Void

    private var keeper: StorageItem? {
        group.items.first { $0.id == keeperItemID } ?? group.items.first
    }

    private var copies: [StorageItem] {
        group.items.filter { $0.id != keeper?.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    keeperSection
                    copiesSection
                }
                .padding(20)
            }
            .frame(minHeight: 280)

            Divider()

            footer
                .padding(20)
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 480)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Compare Keeper", systemImage: "doc.on.doc.fill")
                .font(.title3.weight(.semibold))
            Text("\(group.count.formatted()) verified copies of \(StorageFormat.bytes(group.byteSize)). Reassign the keeper, or reveal all paths in Finder for closer inspection.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var keeperSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Keeper", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Spacer()
                if let keeper {
                    Button {
                        FileActionService.reveal(keeper.url)
                    } label: {
                        Label("Reveal", systemImage: "folder")
                            .labelStyle(.iconOnly)
                    }
                    .help("Reveal \(keeper.url.lastPathComponent) in Finder")
                }
            }

            if let keeper {
                KeeperComparisonRow(item: keeper, isKeeper: true) {
                    onSetKeeper(keeper)
                }
            }
        }
    }

    private var copiesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Alternative Copies")
                    .font(.headline)
                Spacer()
                Text("\(copies.count.formatted()) \(copies.count == 1 ? "copy" : "copies")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(Array(copies.enumerated()), id: \.element.id) { index, item in
                    KeeperComparisonRow(item: item, isKeeper: false) {
                        onSetKeeper(item)
                    }
                    if index < copies.index(before: copies.endIndex) {
                        Divider()
                    }
                }
            }
            .cardBackground()
        }
    }

    private var footer: some View {
        HStack {
            Button {
                FileActionService.revealAll(group.items.map(\.url))
            } label: {
                Label("Reveal All in Finder", systemImage: "folder.badge.gearshape")
            }

            Spacer()

            Button("Done") {
                onDismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

private struct KeeperComparisonRow: View {
    let item: StorageItem
    let isKeeper: Bool
    let onSetKeeper: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isKeeper ? "checkmark.seal.fill" : "doc.fill")
                .foregroundStyle(isKeeper ? .green : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(item.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 16) {
                    Label(StorageFormat.bytes(item.displaySize), systemImage: "internaldrive")
                    Label(StorageFormat.date(item.modifiedAt), systemImage: "clock")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 12)

            if !isKeeper {
                Button {
                    onSetKeeper()
                } label: {
                    Label("Set as Keeper", systemImage: "checkmark.seal")
                        .labelStyle(.iconOnly)
                }
                .help("Make \(item.url.lastPathComponent) the keeper")
                .buttonStyle(.borderless)
            }
        }
        .padding(12)
    }
}