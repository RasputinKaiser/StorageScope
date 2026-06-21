import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SidebarSectionTitle("Storage Views")

                    VStack(spacing: 2) {
                        ForEach(SmartView.allCases) { view in
                            SidebarSmartButton(
                                view: view,
                                isSelected: store.selectedView == view
                            ) {
                                store.selectedView = view
                            }
                        }
                    }

                    SidebarSectionTitle("Grant Access")

                    VStack(spacing: 6) {
                        SidebarActionButton(title: "Choose Home...", systemImage: "house.fill") {
                            store.scanHome()
                        }
                        SidebarActionButton(title: "Choose Documents...", systemImage: "doc.richtext.fill") {
                            store.scanDocuments()
                        }
                        SidebarActionButton(title: "Choose Downloads...", systemImage: "arrow.down.circle.fill") {
                            store.scanDownloads()
                        }
                        SidebarActionButton(title: "Choose Folder...", systemImage: "folder.fill.badge.plus") {
                            store.chooseFolderAndScan()
                        }
                    }

                    if !store.recentScanEntries.isEmpty {
                        SidebarSectionTitle("Recent Scans")

                        VStack(spacing: 2) {
                            ForEach(store.recentScanEntries) { entry in
                                RecentScanRow(entry: entry) {
                                    store.scanRecentPath(entry.path)
                                } forgetAction: {
                                    store.forgetRecentScanPath(entry.path)
                                }
                            }
                        }
                    }

                    let volumes = store.mountedVolumes
                    if !volumes.isEmpty {
                        SidebarSectionTitle("Volumes")

                        VStack(spacing: 2) {
                            ForEach(volumes, id: \.path) { url in
                                SidebarPathButton(path: url.path, title: url.lastPathComponent.nonEmpty ?? url.path, systemImage: "externaldrive.fill") {
                                    store.scanVolume(url)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 16)
                .padding(.bottom, 18)
            }

            ScanStatusFooter(store: store)
        }
        .background(.bar)
    }
}

private struct SidebarSectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 2)
    }
}

private struct SidebarSmartButton: View {
    let view: SmartView
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: view.systemImage)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(view.title)
                        .lineLimit(1)

                    Text(view.subtitle)
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.primary.opacity(0.75) : Color.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .selectionBackground(isSelected: isSelected, tint: 0.24, radius: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(view.title)
        .accessibilityHint(view.subtitle)
    }
}

private struct SidebarActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

private struct SidebarPathButton: View {
    let path: String
    let title: String?
    let systemImage: String
    let subtitle: String?
    let action: () -> Void

    init(path: String, title: String? = nil, systemImage: String, subtitle: String? = nil, action: @escaping () -> Void) {
        self.path = path
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title ?? URL(fileURLWithPath: path).lastPathComponent.nonEmpty ?? path)
                        .lineLimit(1)

                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct RecentScanRow: View {
    let entry: RecentScanEntry
    let scanAction: () -> Void
    let forgetAction: () -> Void

    @State private var relativeText: String = ""

    var body: some View {
        SidebarPathButton(
            path: entry.path,
            systemImage: "clock.arrow.circlepath",
            subtitle: subtitleText
        ) {
            scanAction()
        }
        .contextMenu {
            Button("Forget Recent Scan") {
                forgetAction()
            }
        }
        .onAppear {
            relativeText = entry.scannedAt.formatted(.relative(presentation: .named))
        }
    }

    private var subtitleText: String {
        let relative = relativeText.isEmpty
            ? entry.scannedAt.formatted(.relative(presentation: .named))
            : relativeText
        guard entry.totalBytes > 0 else { return relative }
        return "\(relative) · \(StorageFormat.bytes(entry.totalBytes))"
    }
}

private struct ScanStatusFooter: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.isScanning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(store.scanStage.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    Text("\(store.progress.scannedItemCount.formatted()) items")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(store.progress.currentPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .accessibilityLabel("Current scan path")
            } else if let scan = store.scan {
                Label(StorageFormat.bytes(scan.totalBytes), systemImage: "internaldrive.fill")
                    .font(.headline)
                Text("\(scan.scannedItemCount.formatted()) items scanned")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(scan.rootURL.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            } else {
                Label("No scan yet", systemImage: "internaldrive")
                    .font(.headline)
                Text("Choose a folder to grant access and map storage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}
