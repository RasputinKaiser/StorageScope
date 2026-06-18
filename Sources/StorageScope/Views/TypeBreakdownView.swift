import SwiftUI

struct TypeBreakdownView: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("File Type Breakdown")
                        .font(.headline)
                    Text("Extensions ranked by total storage footprint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                let stats = store.filteredTypeBreakdown
                let categoryStats = store.filteredCategoryBreakdown
                let maxBytes = max(stats.first?.totalBytes ?? 1, 1)
                let maxCategoryBytes = max(categoryStats.first?.totalBytes ?? 1, 1)

                if stats.isEmpty {
                    FilterRecoveryView(
                        title: "No File Types",
                        systemImage: "chart.pie",
                        description: store.hasActiveDisplayFilters ? "No file types match the active display filters." : "No file type summary is available for this scan.",
                        filters: store.activeDisplayFilterDescriptions,
                        clearTitle: "Clear Filters"
                    ) {
                        store.resetDisplayFilters()
                    }
                    .frame(minHeight: 320)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Category Mix")
                            .font(.subheadline.weight(.semibold))

                        VStack(spacing: 0) {
                            ForEach(categoryStats) { stat in
                                HStack(spacing: 14) {
                                    Text(stat.category.rawValue)
                                        .font(.system(.body, design: .rounded).weight(.semibold))
                                        .frame(width: 110, alignment: .leading)

                                    GeometryReader { geometry in
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(.quaternary)
                                            .overlay(alignment: .leading) {
                                                RoundedRectangle(cornerRadius: 4)
                                                    .fill(.teal.opacity(0.72))
                                                    .frame(width: max(8, geometry.size.width * CGFloat(Double(stat.totalBytes) / Double(maxCategoryBytes))))
                                            }
                                    }
                                    .frame(height: 10)

                                    Text(StorageFormat.bytes(stat.totalBytes))
                                        .font(.system(.body, design: .rounded).monospacedDigit())
                                        .frame(width: 100, alignment: .trailing)

                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(stat.extensionCountLabel)
                                        Text(stat.fileCountLabel)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .foregroundStyle(.secondary)
                                    .frame(width: 86, alignment: .trailing)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 11)

                                Divider()
                            }
                        }
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }

                    VStack(spacing: 0) {
                        ForEach(stats) { stat in
                            Button {
                                store.focusFileType(stat)
                            } label: {
                                HStack(spacing: 14) {
                                    Text(stat.label)
                                        .font(.system(.body, design: .rounded).weight(.semibold))
                                        .frame(width: 110, alignment: .leading)

                                    Text(stat.category.rawValue)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 86, alignment: .leading)

                                    GeometryReader { geometry in
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(.quaternary)
                                            .overlay(alignment: .leading) {
                                                RoundedRectangle(cornerRadius: 4)
                                                    .fill(.blue.opacity(0.72))
                                                    .frame(width: max(8, geometry.size.width * CGFloat(Double(stat.totalBytes) / Double(maxBytes))))
                                            }
                                    }
                                    .frame(height: 10)

                                    Text(StorageFormat.bytes(stat.totalBytes))
                                        .font(.system(.body, design: .rounded).monospacedDigit())
                                        .frame(width: 100, alignment: .trailing)

                                    Text(stat.fileCountLabel)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 86, alignment: .trailing)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 11)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(stat.label), \(StorageFormat.bytes(stat.totalBytes)), \(stat.fileCount.formatted()) files")
                            .accessibilityHint("Shows matching files in the large files view")

                            Divider()
                        }
                    }
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(20)
        }
    }
}
