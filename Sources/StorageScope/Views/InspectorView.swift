import StorageScopeCore
import SwiftUI

struct InspectorView: View {
    @ObservedObject var store: ScanStore
    @FocusState private var focusedAction: InspectorAction?

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
                        // Tinted icon header
                        HStack(alignment: .top, spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.accentColor.opacity(0.14))
                                    .frame(width: 48, height: 48)
                                Image(systemName: StorageFormat.icon(for: item))
                                    .font(.title2)
                                    .foregroundStyle(.tint)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(store.filters.displayName(for: item))
                                    .font(.title3.weight(.semibold))
                                    .lineLimit(3)
                                Text(store.filters.displayPath(for: item))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                        }

                        Divider()

                        // 2-column attribute grid
                        LazyVGrid(
                            columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                            alignment: .leading,
                            spacing: 14
                        ) {
                            InspectorMetric(title: "Size", value: StorageFormat.bytes(item.displaySize))
                            InspectorMetric(title: "Kind", value: StorageFormat.label(for: item.kind))
                            InspectorMetric(title: "Modified", value: StorageFormat.date(item.modifiedAt))
                            InspectorMetric(title: "Readable", value: item.isReadable ? "Yes" : "No")
                            InspectorMetric(title: "Children", value: item.immediateChildCount.formatted())
                            InspectorMetric(title: "Nested", value: item.descendantCount.formatted())
                        }

                        if let candidate = store.selectedCleanupCandidate {
                            Divider()
                            CleanupContextSection(candidate: candidate, filters: store.filters)
                        }

                        Divider()

                        // Differentiated action button hierarchy
                        VStack(spacing: 8) {
                            Button {
                                store.revealSelectedItem()
                            } label: {
                                Label("Reveal in Finder", systemImage: "folder")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .focused($focusedAction, equals: .reveal)

                            HStack(spacing: 8) {
                                Button {
                                    store.openSelectedItem()
                                } label: {
                                    Label("Open", systemImage: "arrow.up.right.square")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .disabled(!store.canOpenSelectedItem)
                                .help(item.isReadable ? "Open in default app" : "File is not readable; try Reveal in Finder instead")
                                .focused($focusedAction, equals: .open)

                                Button {
                                    store.copySelectedPath()
                                } label: {
                                    Label("Copy Path", systemImage: "doc.on.clipboard")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .focused($focusedAction, equals: .copyPath)
                            }

                            Button(role: .destructive) {
                                store.moveSelectedItemToTrash()
                            } label: {
                                Label("Move to Trash", systemImage: "trash")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(!store.canMoveItemToTrash(item))
                            .focused($focusedAction, equals: .moveToTrash)
                        }
                    }
                    .padding(16)
                }
                .onAppear {
                    focusedAction = .reveal
                }
                .onChange(of: item.id) { _, _ in
                    focusedAction = .reveal
                }
            } else {
                ContentUnavailableView(
                    "Nothing Selected",
                    systemImage: "cursorarrow.rays",
                    description: Text("Select an item in the scan results to inspect its metadata and actions.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.bar)
    }
}

private enum InspectorAction: Hashable {
    case reveal
    case open
    case copyPath
    case moveToTrash
}

private struct CleanupContextSection: View {
    let candidate: CleanupCandidate
    @ObservedObject var filters: FilterStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Cleanup Context", systemImage: candidate.kind.systemImage)
                .font(.headline)
                .foregroundStyle(candidate.confidence.tint)

            HStack(spacing: 8) {
                CleanupBadge(candidate.kind.displayName, tint: candidate.confidence.tint)
                CleanupBadge(candidate.trustDetails.confidenceLabel, tint: candidate.confidence.tint)
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                alignment: .leading,
                spacing: 14
            ) {
                InspectorMetric(title: "Reclaimable", value: StorageFormat.bytes(candidate.reclaimableBytes))
                InspectorMetric(title: "Last Modified", value: StorageFormat.date(candidate.item.modifiedAt))
                InspectorMetric(title: "Kind", value: candidate.kind.displayName)
            }

            InspectorMetric(title: "Path", value: filters.displayPath(for: candidate.item))
            InspectorMetric(title: "Why flagged", value: candidate.trustDetails.flaggedReason)
            InspectorMetric(title: "Could break", value: candidate.trustDetails.couldBreak)
            InspectorMetric(title: "Safety note", value: candidate.trustDetails.safetyNote)
            InspectorMetric(title: "Suggested action", value: candidate.trustDetails.suggestedAction)

            Text(candidate.isHighConfidenceVerifiedDuplicate
                ? "Verified duplicates are content-matched. StorageScope still sends cleanup through Trash so you can recover from a bad choice."
                : "This is review guidance, not proof. Reveal the item and inspect the owning app or project before moving it to Trash.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CleanupBadge: View {
    let title: String
    let tint: Color

    init(_ title: String, tint: Color) {
        self.title = title
        self.tint = tint
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
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
