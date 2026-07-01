import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ScanStore
    @State private var showingClearCacheAlert = false
    @State private var cacheSnapshot: CacheSnapshot = .init(entryCount: 0, lastPersistedAt: nil)

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Scan Options") {
                Toggle("Include hidden files", isOn: store.filterBinding(\.includeHiddenFiles))
                Stepper("Treat files older than \(store.oldFileAgeDays) days as old", value: store.filterBinding(\.oldFileAgeDays), in: 30...1440, step: 30)
                Stepper("Detect duplicates \(store.duplicateCandidateThresholdMB) MB or larger", value: store.filterBinding(\.duplicateCandidateThresholdMB), in: 1...500, step: 1)

                if let status = store.scanOptionsStatusText {
                    HStack {
                        Label(status, systemImage: "arrow.clockwise.circle")
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("Rescan") {
                            store.rescan()
                        }
                        .disabled(!store.canRescan)
                    }
                }

                SettingsFootnote("Hidden files, old-file age, and the duplicate threshold affect scan results. Existing results keep their previous scan options until you rescan.")
            }

            Divider()

            SettingsSection(title: "Display Filters") {
                Picker("Visible size", selection: store.filterBinding(\.sizeFilter)) {
                    ForEach(SizeFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }

                SettingsFootnote("Size changes only filter the current view. They do not rescan the folder.")
            }

            Divider()

            SettingsSection(title: "Duplicate Hash Cache") {
                LabeledContent("Stored entries", value: cacheSnapshot.entryCount.formatted())

                if let lastPersistedAt = cacheSnapshot.lastPersistedAt {
                    LabeledContent("Last updated", value: lastPersistedAt.formatted(date: .abbreviated, time: .shortened))
                } else {
                    LabeledContent("Last updated", value: "Never")
                }

                Button(role: .destructive) {
                    showingClearCacheAlert = true
                } label: {
                    Label("Clear Cache", systemImage: "trash")
                }
                .disabled(cacheSnapshot.entryCount == 0)

                SettingsFootnote("Cached SHA-256 hashes make rescans faster by skipping unchanged files. Clearing forces a full re-hash on the next scan. Cache lives in your user Caches directory and never leaves the Mac.")
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 520, alignment: .topLeading)
        } // ScrollView
        .frame(width: 520)
        .task { refreshCacheSnapshot() }
        .alert("Clear Duplicate Hash Cache?", isPresented: $showingClearCacheAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                store.clearDuplicateHashCache()
                refreshCacheSnapshot()
            }
        } message: {
            Text("Every cached SHA-256 hash will be discarded. The next scan will re-hash duplicate candidates from scratch. This cannot be undone.")
        }
    }

    private func refreshCacheSnapshot() {
        cacheSnapshot = CacheSnapshot(
            entryCount: store.duplicateHashCacheEntryCount,
            lastPersistedAt: store.duplicateHashCacheLastPersistedAt
        )
    }
}

private struct CacheSnapshot: Equatable {
    let entryCount: Int
    let lastPersistedAt: Date?
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
