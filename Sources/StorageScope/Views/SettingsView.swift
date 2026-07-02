import SwiftUI

/// Native grouped settings form (UI_PLAN.md P2). Replaces the previous hand-rolled
/// fixed-width VStack: `Form` + `.formStyle(.grouped)` provides macOS-standard section
/// chrome, label/control alignment, and sensible resizing for free. The hosting
/// window (AppDelegate.showSettings) is resizable with the form as its content.
struct SettingsView: View {
    @ObservedObject var store: ScanStore
    @State private var showingClearCacheAlert = false
    @State private var cacheSnapshot: CacheSnapshot = .init(entryCount: 0, lastPersistedAt: nil)
    @State private var newExcludedPath: String = ""

    var body: some View {
        Form {
            Section {
                Toggle("Include hidden files", isOn: store.filterBinding(\.includeHiddenFiles))

                LabeledContent("Treat files as old after") {
                    Stepper(
                        "\(store.oldFileAgeDays) days",
                        value: store.filterBinding(\.oldFileAgeDays),
                        in: 30...1440,
                        step: 30
                    )
                    .monospacedDigit()
                }

                LabeledContent("Detect duplicates at or above") {
                    Stepper(
                        "\(store.duplicateCandidateThresholdMB) MB",
                        value: store.filterBinding(\.duplicateCandidateThresholdMB),
                        in: 1...500,
                        step: 1
                    )
                    .monospacedDigit()
                }

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
            } header: {
                Text("Scan Options")
            } footer: {
                SettingsFootnote("Hidden files, old-file age, and the duplicate threshold affect scan results. Existing results keep their previous scan options until you rescan.")
            }

            Section {
                Toggle("Exclude folders", isOn: store.filterBinding(\.excludeFoldersEnabled))

                ForEach(store.filters.excludedPaths, id: \.self) { path in
                    HStack {
                        Text(path)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            store.filters.excludedPaths.removeAll { $0 == path }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this exclusion")
                    }
                }

                HStack {
                    TextField("Folder name or path (e.g. node_modules, ~/Library/Caches)", text: $newExcludedPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        let trimmed = newExcludedPath.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty, !store.filters.excludedPaths.contains(trimmed) else { return }
                        store.filters.excludedPaths.append(trimmed)
                        newExcludedPath = ""
                    }
                    .disabled(newExcludedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("Excluded Folders")
            } footer: {
                SettingsFootnote("Folder names (e.g. node_modules) match anywhere in the tree. Paths starting with ~ or / match only that exact folder and its contents. Excluded folders are skipped entirely during the next scan.")
            }

            Section {
                Picker("Visible size", selection: store.filterBinding(\.sizeFilter)) {
                    ForEach(SizeFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
            } header: {
                Text("Display Filters")
            } footer: {
                SettingsFootnote("Size changes only filter the current view. They do not rescan the folder.")
            }

            Section {
                Toggle("Redact file & folder names", isOn: store.filterBinding(\.redactionEnabled))
            } header: {
                Text("Privacy")
            } footer: {
                SettingsFootnote("Replaces file and folder names and paths shown in the app with generic placeholders. Sizes, dates, and counts stay real. Trash, move, and reveal-in-Finder still act on the real files.")
            }

            Section {
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
            } header: {
                Text("Duplicate Hash Cache")
            } footer: {
                SettingsFootnote("Cached SHA-256 hashes make rescans faster by skipping unchanged files. Clearing forces a full re-hash on the next scan. Cache lives in your user Caches directory and never leaves the Mac.")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 680)
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
