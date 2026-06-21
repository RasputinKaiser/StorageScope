import AppKit
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
                    if let notice = store.scanNoticeText {
                        ScanNoticeView(
                            text: notice,
                            rescan: { store.rescan() },
                            dismissAction: store.scanNoticeIsDismissible ? { store.dismissScanNotice() } : nil
                        )
                    }
                    if store.activeView == .cleanupReview
                        ? store.hasActiveCleanupFilters
                        : store.hasActiveDisplayFilters {
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
    @AppStorage("StorageScope.didDismissFirstRunCard") private var didDismissFirstRunCard = false

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

            if !didDismissFirstRunCard {
                FirstRunPermissionCard {
                    didDismissFirstRunCard = true
                }
                .frame(maxWidth: 760)
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

            if !store.recents.entries.isEmpty {
                VStack(spacing: 8) {
                    Text("Recent Scans")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(store.recents.entries.prefix(8)) { entry in
                                Button {
                                    store.scanRecentPath(entry.path)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .font(.caption)
                                        Text(URL(fileURLWithPath: entry.path).lastPathComponent)
                                            .lineLimit(1)
                                    }
                                    .font(.callout)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(.quaternary, in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .disabled(store.isScanning)
                                .help(entry.path)
                            }
                        }
                    }
                    .frame(maxWidth: 760)
                }
            }
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
        .cardBackground()
    }
}

private struct FirstRunPermissionCard: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "lock.shield.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 6) {
                Text("How folder access works")
                    .font(.headline)
                Text("StorageScope is sandboxed. It only reads folders you choose with the macOS picker, never uploads file names, paths, or contents. Scans of protected locations (Home, Desktop, Documents, Downloads, external volumes) may require you to grant access, or Full Disk Access for whole-disk scans.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 2)
            }

            Spacer(minLength: 0)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Dismiss this card")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .cardBackground(.thin)
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
        .cardBackground(.thin)
    }
}

private struct ScanNoticeView: View {
    let text: String
    let rescan: () -> Void
    var dismissAction: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(.orange)

            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 12)

            Button {
                rescan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)

            if let dismissAction {
                Button {
                    dismissAction()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .cardBackground()
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
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
        Picker("Size", selection: store.filterBinding(\.sizeFilter)) {
            ForEach(SizeFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var sortPicker: some View {
        Picker("Sort", selection: store.filterBinding(\.sortOption)) {
            ForEach(ItemSortOption.allCases) { option in
                Text(option.title).tag(option)
            }
        }
    }

    private var sortControl: some View {
        HStack(spacing: 6) {
            Text("Sort")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            sortPicker
                .labelsHidden()
                .frame(width: 128)
        }
        .accessibilityElement(children: .combine)
    }

    private var wideControls: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 10) {
                ControlGroupLabel(title: "Display", systemImage: "line.3.horizontal.decrease.circle")

                sizePicker
                    .frame(maxWidth: 430)

                sortControl
            }

            Divider()
                .frame(height: 28)

            HStack(spacing: 10) {
                ControlGroupLabel(title: "Scan Options", systemImage: "slider.horizontal.3")

                Stepper("Old after \(store.oldFileAgeDays) days", value: store.filterBinding(\.oldFileAgeDays), in: 30...1440, step: 30)
                    .frame(width: 190)

                Toggle("Hidden", isOn: store.filterBinding(\.includeHiddenFiles))
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

                sortControl

                Spacer(minLength: 0)
            }

            ControlGroupLabel(title: "Scan Options", systemImage: "slider.horizontal.3")

            HStack(spacing: 12) {
                Stepper("Old after \(store.oldFileAgeDays) days", value: store.filterBinding(\.oldFileAgeDays), in: 30...1440, step: 30)
                    .frame(width: 190)

                Toggle("Hidden", isOn: store.filterBinding(\.includeHiddenFiles))

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

    private var chips: [FilterStore.ActiveFilter] {
        store.activeView == .cleanupReview
            ? store.filters.activeCleanupChips
            : store.filters.activeDisplayChips
    }

    private var resetAction: () -> Void {
        store.activeView == .cleanupReview
            ? { store.resetCleanupFilters() }
            : { store.resetDisplayFilters() }
    }

    var body: some View {
        HStack(spacing: 8) {
            Label("Filtering", systemImage: "line.3.horizontal.decrease.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(chips) { chip in
                Button {
                    store.filters.clearActiveFilter(chip.id)
                } label: {
                    HStack(spacing: 4) {
                        Text(chip.label)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Remove \(chip.label)")
                .accessibilityLabel("Remove \(chip.label) filter")
            }

            Spacer(minLength: 0)

            Button {
                resetAction()
            } label: {
                Label("Clear All", systemImage: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }
}
