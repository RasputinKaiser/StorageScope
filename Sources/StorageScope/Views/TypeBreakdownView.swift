import StorageScopeCore
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
                        state: store.displayRecoveryState,
                        clearTitle: "Clear Filters"
                    ) {
                        store.resetDisplayFilters()
                    }
                    .frame(minHeight: 320)
                    .cardBackground()
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Category Mix")
                            .font(.subheadline.weight(.semibold))

                        LazyVStack(spacing: 0) {
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
                                                    .fill(stat.category.barTint.opacity(0.72))
                                                    .frame(width: max(8, geometry.size.width * CGFloat(Double(stat.totalBytes) / Double(maxCategoryBytes))))
                                            }
                                    }
                                    .frame(height: 10)
                                    .accessibilityHidden(true)

                                    Text(StorageFormat.bytes(stat.totalBytes))
                                        .font(.system(.body, design: .rounded).monospacedDigit())
                                        .frame(width: 100, alignment: .trailing)

                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(stat.extensionCountLabel)
                                            .monospacedDigit()
                                        Text(stat.fileCountLabel)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    }
                                    .foregroundStyle(.secondary)
                                    .frame(width: 86, alignment: .trailing)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 11)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("\(stat.category.rawValue) category, \(StorageFormat.bytes(stat.totalBytes))")
                                .accessibilityValue("\(stat.extensionCountLabel), \(stat.fileCountLabel)")

                                Divider()
                            }
                        }
                        .cardBackground()
                    }

                    LazyVStack(spacing: 0) {
                        ForEach(stats) { stat in
                            Button {
                                store.focusFileType(stat)
                            } label: {
                                FileTypeRowLabel(
                                    stat: stat,
                                    maxBytes: maxBytes,
                                    isFocused: isFocused(fileTypeFocus: store.filters.fileTypeFocus, stat: stat)
                                )
                                .equatable()
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(stat.label), \(StorageFormat.bytes(stat.totalBytes)), \(stat.fileCount.formatted()) files")
                            .accessibilityHint("Shows matching files in the large files view")

                            Divider()
                        }
                    }
                    .cardBackground()
                }
            }
            .padding(20)
        }
    }
}

private struct FileTypeRowLabel: View, Equatable {
    let stat: FileTypeStat
    let maxBytes: Int64
    let isFocused: Bool

    var body: some View {
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
                            .fill(stat.category.barTint.opacity(0.72))
                            .frame(width: max(8, geometry.size.width * CGFloat(Double(stat.totalBytes) / Double(maxBytes))))
                    }
            }
            .frame(height: 10)
            .accessibilityHidden(true)

            Text(StorageFormat.bytes(stat.totalBytes))
                .font(.system(.body, design: .rounded).monospacedDigit())
                .frame(width: 100, alignment: .trailing)

            Text(stat.fileCountLabel)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 86, alignment: .trailing)

            Image(systemName: isFocused ? "checkmark.circle.fill" : "chevron.right")
                .foregroundStyle(isFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.5)))
                .frame(width: 18)
                .help(isFocused ? "Filtered by this type" : "")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .selectionBackground(isSelected: isFocused)
    }
}

private func isFocused(fileTypeFocus: String?, stat: FileTypeStat) -> Bool {
    let expected = stat.label == "No Extension" ? "" : stat.label
    return fileTypeFocus == expected
}

/// Per-category bar tint so bar length is visually comparable even when the
/// numeric ratio is small (Archives at 16 GB vs Installers at 572 MB looked
/// near-identical when both bars were the same teal/blue — the eye registered
/// color, not length). Hue assignment is deterministic per category and uses
/// Apple system semantic colors so it adapts to light/dark mode automatically.
private extension FileTypeStat.Category {
    var barTint: Color {
        switch self {
        case .archive:        return .orange
        case .audio:           return .pink
        case .developer:      return .purple
        case .document:       return .blue
        case .database:       return .red
        case .font:           return .indigo
        case .image:          return .green
        case .installer:      return .teal
        case .video:          return .yellow
        case .virtualMachine: return .brown
        case .other:          return .gray
        }
    }
}
