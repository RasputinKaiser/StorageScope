import StorageScopeCore
import SwiftUI

struct DetailView: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        Group {
            if store.scan == nil && !store.isScanning {
                if store.activeView == .overview {
                    WelcomeView(store: store)
                } else {
                    NoScanPlaceholder(activeView: store.activeView, store: store)
                }
            } else {
                VStack(spacing: 0) {
                    ScanHeaderView(store: store)
                    if store.activeView.showsFilterBar {
                        FilterBarView(store: store)
                    }
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
                        .id(store.activeView)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.18), value: store.activeView)
                }
                // Leading inset between the split divider and content. Was 28pt —
                // an offset baked into every view's minimum width (UI_PLAN.md P0.4).
                .padding(.leading, 8)
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

private struct NoScanPlaceholder: View {
    let activeView: SmartView
    @ObservedObject var store: ScanStore

    var body: some View {
        ContentUnavailableView {
            Label(activeView.title, systemImage: activeView.systemImage)
        } description: {
            Text(activeView.subtitle + ".\nScan a folder to get started.")
        } actions: {
            Button {
                store.chooseFolderAndScan()
            } label: {
                Label("Choose Folder", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

private struct ScanHeaderView: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        // Full header (title + metric cards) only on Overview. Every other view
        // repeats those numbers at the cost of ~130pt of working space, so they
        // get a single-line strip instead (UI_PLAN.md P1.1).
        if store.activeView == .overview {
            fullHeader
        } else {
            compactHeader
        }
    }

    private var compactHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(titleText)
                .font(.headline)
                .lineLimit(1)
                .layoutPriority(1)

            Text(pathText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 12)

            if store.isScanning {
                ProgressView()
                    .controlSize(.small)
            }

            Text(compactMetricsText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var compactMetricsText: String {
        let footprint = StorageFormat.bytes(store.scan?.totalBytes ?? store.progress.totalBytes)
        let items = (store.scan?.scannedItemCount ?? store.progress.scannedItemCount).formatted()
        let reviewable = StorageFormat.bytes(store.potentialReclaimableBytes)
        return "\(footprint) · \(items) items · \(reviewable) reviewable"
    }

    private var fullHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(titleText)
                        .font(.title2.weight(.semibold))
                    Text(pathText)
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

            // Four cards in a row when they fit; a 2×2 grid on narrow windows so the
            // header never dictates a >900pt minimum width (UI_PLAN.md P0.2).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    metricCards.0
                    metricCards.1
                    metricCards.2
                    metricCards.3
                }

                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        metricCards.0
                        metricCards.1
                    }
                    GridRow {
                        metricCards.2
                        metricCards.3
                    }
                }
            }
        }
        .padding(20)
    }

    private var metricCards: (MetricCard, MetricCard, MetricCard, MetricCard) {
        (
            MetricCard(
                title: "Footprint",
                value: StorageFormat.bytes(store.scan?.totalBytes ?? store.progress.totalBytes),
                systemImage: "internaldrive.fill",
                tint: .blue
            ),
            MetricCard(
                title: "Items",
                value: (store.scan?.scannedItemCount ?? store.progress.scannedItemCount).formatted(),
                systemImage: "square.stack.3d.up.fill",
                tint: .green
            ),
            MetricCard(
                title: "Large Files",
                value: (store.scan?.largestFiles.count ?? 0).formatted(),
                systemImage: "doc.text.magnifyingglass",
                tint: .orange
            ),
            MetricCard(
                title: "Reviewable",
                value: StorageFormat.bytes(store.potentialReclaimableBytes),
                systemImage: "checklist",
                tint: .purple
            )
        )
    }

    private var titleText: String {
        guard let rootURL = store.scan?.rootURL else { return "Scanning..." }
        guard store.filters.redactionEnabled else { return rootURL.lastPathComponent.nonEmpty ?? rootURL.path }
        return store.filters.displayName(forURL: rootURL, isDirectory: true)
    }

    private var pathText: String {
        guard let rootURL = store.scan?.rootURL else {
            guard store.filters.redactionEnabled else { return store.progress.currentPath }
            let url = URL(fileURLWithPath: store.progress.currentPath)
            return "\(store.filters.displayParentPath(forURL: url))/\(store.filters.displayName(forURL: url, isDirectory: false))"
        }
        guard store.filters.redactionEnabled else { return rootURL.path }
        return "…/\(store.filters.displayName(forURL: rootURL, isDirectory: true))"
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
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .cardBackground(.regular)
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
        .padding(.vertical, 8)
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

    private var displayGroup: some View {
        HStack(spacing: 10) {
            ControlGroupLabel(title: "Display", systemImage: "line.3.horizontal.decrease.circle")

            if store.activeView.appliesSizeFilter {
                sizePicker
                    .frame(maxWidth: 430)
            }

            if store.activeView.appliesSortOption {
                sortControl
            }

            if store.activeView == .oldLargeFiles {
                Divider()
                    .frame(height: 28)

                HStack(spacing: 6) {
                    Text("Old after")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Stepper("\(store.oldFileAgeDays) days", value: store.filterBinding(\.oldFileAgeDays), in: 30...1440, step: 30)
                        .labelsHidden()
                }
                .help("Files older than this become 'old'. Rescan to apply the new threshold.")
            }
        }
    }

    private var wideControls: some View {
        HStack(alignment: .center, spacing: 16) {
            displayGroup

            Spacer()

            scanDurationLabel
        }
    }

    private var compactControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            displayGroup

            HStack(spacing: 12) {
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
