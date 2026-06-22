import AppKit
import SwiftUI

struct WelcomeView: View {
    @ObservedObject var store: ScanStore
    @AppStorage("StorageScope.didDismissFirstRunCard") private var didDismissFirstRunCard = false
    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                WelcomeHeroView()
                    .appear(appeared, delay: 0)

                WelcomeHeadline()
                    .appear(appeared, delay: 0.07)

                if !didDismissFirstRunCard {
                    FirstRunPermissionCard {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                            didDismissFirstRunCard = true
                        }
                    }
                    .frame(maxWidth: 680)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .appear(appeared, delay: 0.12)
                }

                WelcomeCTAButtons(
                    chooseFolderAction: { store.chooseFolderAndScan() },
                    scanHomeAction: store.scanHome
                )
                .appear(appeared, delay: 0.17)

                WelcomeCapabilitySection()
                    .appear(appeared, delay: 0.23)

                if !store.recents.entries.isEmpty {
                    WelcomeRecentScans(
                        entries: Array(store.recents.entries.prefix(8)),
                        isScanning: store.isScanning,
                        onSelect: store.scanRecentPath
                    )
                    .appear(appeared, delay: 0.29)
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .onAppear { appeared = true }
    }
}

// MARK: - Appear animation

private extension View {
    func appear(_ appeared: Bool, delay: Double) -> some View {
        opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)
            .animation(.spring(response: 0.5, dampingFraction: 0.82).delay(delay), value: appeared)
    }
}

// MARK: - Subviews

private struct WelcomeHeroView: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.accentColor.opacity(0.18), Color.accentColor.opacity(0.04)],
                        center: .center,
                        startRadius: 12,
                        endRadius: 56
                    )
                )
                .frame(width: 112, height: 112)

            Image(systemName: "internaldrive.fill")
                .font(.system(size: 52, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
        }
    }
}

private struct WelcomeHeadline: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("Map your storage. Reclaim space.")
                .font(.largeTitle.weight(.semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)

            Text("Choose a folder, home directory, or volume to grant access, rank the biggest storage consumers, and inspect them safely.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
        }
    }
}

private struct WelcomeCTAButtons: View {
    let chooseFolderAction: () -> Void
    let scanHomeAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: chooseFolderAction) {
                Label("Choose Folder", systemImage: "folder.badge.plus")
                    .frame(minWidth: 130)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button(action: scanHomeAction) {
                Label("Choose Home", systemImage: "house")
                    .frame(minWidth: 130)
            }
            .controlSize(.large)
        }
    }
}

private struct WelcomeCapabilitySection: View {
    var body: some View {
        HStack(spacing: 14) {
            WelcomeCapabilityCard(
                title: "Big Folders",
                detail: "Rank folders and packages by real disk footprint.",
                systemImage: "folder.fill"
            )
            WelcomeCapabilityCard(
                title: "Old Bulk",
                detail: "Surface large files that have gone stale.",
                systemImage: "clock.fill"
            )
            WelcomeCapabilityCard(
                title: "Type Mix",
                detail: "See which extensions dominate the scan.",
                systemImage: "chart.pie.fill"
            )
        }
        .frame(maxWidth: 680)
    }
}

private struct WelcomeCapabilityCard: View {
    let title: String
    let detail: String
    let systemImage: String
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: systemImage)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.tint)
            }
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
        .shadow(color: .black.opacity(isHovered ? 0.09 : 0), radius: isHovered ? 10 : 0, y: isHovered ? 3 : 0)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(isHovered ? 0.06 : 0), lineWidth: 1)
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isHovered)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
    }
}

private struct WelcomeRecentScans: View {
    let entries: [RecentScanEntry]
    let isScanning: Bool
    let onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("Recent Scans")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(entries) { entry in
                        Button {
                            onSelect(entry.path)
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
                        .disabled(isScanning)
                        .help(entry.path)
                    }
                }
            }
            .frame(maxWidth: 680)
        }
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
