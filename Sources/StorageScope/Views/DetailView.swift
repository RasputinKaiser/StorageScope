import StorageScopeCore
import SwiftUI

struct DetailView: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        Group {
            if store.scan == nil && !store.isScanning {
                WelcomeView(store: store)
            } else {
                VStack(spacing: 0) {
                    ScanHeaderView(store: store)
                    FilterBarView(store: store)
                    if store.hasActiveDisplayFilters {
                        ActiveDisplayFiltersView(store: store)
                    }
                    Divider()
                    viewContent
                }
                .padding(.leading, 28)
            }
        }
    }

    @ViewBuilder
    private var viewContent: some View {
        switch store.activeView {
        case .overview:
            OverviewView(store: store)
        case .cleanupReview:
            CleanupReviewView(store: store)
        case .tree:
            TreeExplorerView(store: store)
        case .largestFolders, .largestFiles, .oldLargeFiles:
            StorageItemTable(
                title: store.activeView.title,
                subtitle: store.activeView.subtitle,
                items: store.items(for: store.activeView),
                store: store
            )
        case .typeBreakdown:
            TypeBreakdownView(store: store)
        case .duplicateCandidates:
            DuplicateCandidatesView(store: store)
        }
    }
}

private struct WelcomeView: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 78, weight: .regular))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("StorageScope")
                    .font(.largeTitle.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text("Map. Review. Reclaim.")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text("A local Mac storage map for finding large folders, separating verified duplicates from suggestions, and reclaiming space through macOS Trash when you are ready.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 680)
            }

            HStack(spacing: 12) {
                Button {
                    store.chooseFolderAndScan()
                } label: {
                    Label("Choose Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    store.scanHome()
                } label: {
                    Label("Choose Home", systemImage: "house")
                }
                .controlSize(.large)
            }

            HStack(spacing: 14) {
                WelcomeCapabilityCard(
                    title: "Map",
                    detail: "Rank folders, packages, files, and type-heavy storage locally.",
                    systemImage: "folder.fill.badge.gearshape"
                )
                WelcomeCapabilityCard(
                    title: "Review",
                    detail: "Separate verified duplicates from suggestions that need judgment.",
                    systemImage: "checkmark.seal.fill"
                )
                WelcomeCapabilityCard(
                    title: "Reclaim",
                    detail: "Preview paths, confirm risk, and move selected items to Trash.",
                    systemImage: "trash"
                )
            }
            .frame(maxWidth: 760)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WelcomeCapabilityCard: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ScanHeaderView: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.scan?.rootURL.lastPathComponent.nonEmpty ?? "Scanning...")
                        .font(.title2.weight(.semibold))
                    Text(store.scan?.rootURL.path ?? store.progress.currentPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if store.isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: 12) {
                MetricCard(
                    title: "Footprint",
                    value: StorageFormat.bytes(store.scan?.totalBytes ?? store.progress.totalBytes),
                    systemImage: "internaldrive.fill",
                    tint: .blue
                )
                MetricCard(
                    title: "Items",
                    value: (store.scan?.scannedItemCount ?? store.progress.scannedItemCount).formatted(),
                    systemImage: "square.stack.3d.up.fill",
                    tint: .green
                )
                MetricCard(
                    title: "Large Files",
                    value: (store.scan?.largestFiles.count ?? 0).formatted(),
                    systemImage: "doc.text.magnifyingglass",
                    tint: .orange
                )
                MetricCard(
                    title: "Reviewable",
                    value: StorageFormat.bytes(store.potentialReclaimableBytes),
                    systemImage: "checklist",
                    tint: .purple
                )
            }
        }
        .padding(20)
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct FilterBarView: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wideControls
            compactControls
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private var scanDurationLabel: some View {
        Group {
            if let status = store.scanOptionsStatusText {
                Button {
                    store.rescan()
                } label: {
                    Label(status, systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if let scan = store.scan {
                Text("Scanned in \(StorageFormat.duration(from: scan.startedAt, to: scan.finishedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sizePicker: some View {
        Picker("Size", selection: $store.sizeFilter) {
            ForEach(SizeFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var sortPicker: some View {
        Picker("Sort", selection: $store.sortOption) {
            ForEach(ItemSortOption.allCases) { option in
                Text(option.title).tag(option)
            }
        }
    }

    private var wideControls: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 10) {
                ControlGroupLabel(title: "Display", systemImage: "line.3.horizontal.decrease.circle")

                sizePicker
                    .frame(maxWidth: 430)

                sortPicker
                    .frame(width: 128)
            }

            Divider()
                .frame(height: 28)

            HStack(spacing: 10) {
                ControlGroupLabel(title: "Scan Options", systemImage: "slider.horizontal.3")

                Stepper("Old after \(store.oldFileAgeDays) days", value: $store.oldFileAgeDays, in: 30...1440, step: 30)
                    .frame(width: 190)

                Toggle("Hidden", isOn: $store.includeHiddenFiles)
            }

            Spacer()

            scanDurationLabel
        }
    }

    private var compactControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ControlGroupLabel(title: "Display", systemImage: "line.3.horizontal.decrease.circle")

            HStack(spacing: 12) {
                sizePicker
                    .frame(maxWidth: 430)

                sortPicker
                    .frame(width: 128)

                Spacer(minLength: 0)
            }

            ControlGroupLabel(title: "Scan Options", systemImage: "slider.horizontal.3")

            HStack(spacing: 12) {
                Stepper("Old after \(store.oldFileAgeDays) days", value: $store.oldFileAgeDays, in: 30...1440, step: 30)
                    .frame(width: 190)

                Toggle("Hidden", isOn: $store.includeHiddenFiles)

                Spacer(minLength: 0)

                scanDurationLabel
            }
        }
    }
}

private struct ControlGroupLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
    }
}

private struct ActiveDisplayFiltersView: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        HStack(spacing: 8) {
            Label("Filtering", systemImage: "line.3.horizontal.decrease.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(store.activeDisplayFilterDescriptions, id: \.self) { filter in
                Text(filter)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }

            Spacer(minLength: 0)

            Button {
                store.resetDisplayFilters()
            } label: {
                Label("Clear", systemImage: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
