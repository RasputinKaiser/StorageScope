import StorageScopeCore
import SwiftUI

struct OverviewView: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if store.scan != nil {
                    SizeDistributionView(store: store)

                    let overviewItems = Array(store.items(for: .overview).prefix(12))
                    HStack(alignment: .top, spacing: 16) {
                        StorageItemTable(
                            title: "Largest Children",
                            subtitle: "Immediate storage pressure under the scanned root",
                            items: overviewItems,
                            store: store,
                            compact: true
                        )

                        VStack(spacing: 16) {
                            InsightCard(
                                title: "Largest File",
                                item: store.items(for: .largestFiles).first,
                                systemImage: "doc.fill"
                            )
                            InsightCard(
                                title: "Largest Folder",
                                item: store.items(for: .largestFolders).first,
                                systemImage: "folder.fill"
                            )
                            InsightCard(
                                title: "Oldest Large File",
                                item: store.oldLargeFiles.first,
                                systemImage: "clock.fill"
                            )
                        }
                        .frame(width: 280)
                    }
                }
            }
            .padding(20)
        }
    }
}

private struct SizeDistributionView: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Storage Map")
                    .font(.headline)
                Text("Top folders and packages inside the scanned root")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if store.scan != nil {
                let items = Array(store.items(for: .overview).prefix(10))
                let maxSize = max(items.first?.displaySize ?? 1, 1)

                VStack(spacing: 8) {
                    ForEach(items) { item in
                        Button {
                            store.selectedItemID = item.id
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: StorageFormat.icon(for: item))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(item.name)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(StorageFormat.bytes(item.displaySize))
                                            .foregroundStyle(.secondary)
                                    }

                                    GeometryReader { geometry in
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(.quaternary)
                                            .overlay(alignment: .leading) {
                                                RoundedRectangle(cornerRadius: 4)
                                                    .fill(.tint.opacity(0.85))
                                                    .frame(width: max(8, geometry.size.width * CGFloat(Double(item.displaySize) / Double(maxSize))))
                                            }
                                    }
                                    .frame(height: 8)
                                }
                            }
                            .padding(10)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct InsightCard: View {
    let title: String
    let item: StorageScopeCore.StorageItem?
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                Spacer()
            }

            if let item {
                Text(item.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text(StorageFormat.bytes(item.displaySize))
                    .font(.title3.weight(.semibold))
                Text(item.url.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            } else {
                Text("No matching item")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
