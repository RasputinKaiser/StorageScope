import SwiftUI

struct InspectorView: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Inspector", systemImage: "sidebar.right")
                    .font(.headline)
                Spacer()
            }
            .padding(16)

            Divider()

            if let item = store.selectedItem {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: StorageFormat.icon(for: item))
                                .font(.system(size: 42))
                                .foregroundStyle(.tint)

                            Text(item.name)
                                .font(.title3.weight(.semibold))
                                .lineLimit(3)

                            Text(item.url.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                                .truncationMode(.middle)
                        }

                        Divider()

                        InspectorMetric(title: "Size", value: StorageFormat.bytes(item.displaySize))
                        InspectorMetric(title: "Kind", value: StorageFormat.label(for: item.kind))
                        InspectorMetric(title: "Modified", value: StorageFormat.date(item.modifiedAt))
                        InspectorMetric(title: "Children", value: "\(item.immediateChildCount.formatted()) direct, \(item.descendantCount.formatted()) nested")
                        InspectorMetric(title: "Readable", value: item.isReadable ? "Yes" : "No")

                        Divider()

                        VStack(spacing: 8) {
                            Button {
                                store.revealSelectedItem()
                            } label: {
                                Label("Reveal in Finder", systemImage: "folder")
                                    .frame(maxWidth: .infinity)
                            }

                            Button {
                                store.openSelectedItem()
                            } label: {
                                Label("Open", systemImage: "arrow.up.right.square")
                                    .frame(maxWidth: .infinity)
                            }

                            Button {
                                store.copySelectedPath()
                            } label: {
                                Label("Copy Path", systemImage: "doc.on.clipboard")
                                    .frame(maxWidth: .infinity)
                            }

                            Button(role: .destructive) {
                                store.moveSelectedItemToTrash()
                            } label: {
                                Label("Move to Trash", systemImage: "trash")
                                    .frame(maxWidth: .infinity)
                            }
                            .disabled(item.id == store.scan?.rootItem.id)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "sidebar.right",
                    description: Text("Select an item to inspect actions and metadata.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.bar)
    }
}

private struct InspectorMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .textSelection(.enabled)
        }
    }
}
