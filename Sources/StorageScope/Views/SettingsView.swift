import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Scan Options") {
                Toggle("Include hidden files", isOn: $store.includeHiddenFiles)
                Stepper("Treat files older than \(store.oldFileAgeDays) days as old", value: $store.oldFileAgeDays, in: 30...1440, step: 30)

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

                SettingsFootnote("Hidden files and old-file age affect scan results. Existing results keep their previous scan options until you rescan.")
            }

            Divider()

            SettingsSection(title: "Display Filters") {
                Picker("Visible size", selection: $store.sizeFilter) {
                    ForEach(SizeFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }

                SettingsFootnote("Size changes only filter the current view. They do not rescan the folder.")
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 520, alignment: .topLeading)
        .frame(minHeight: 280, alignment: .topLeading)
    }
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
