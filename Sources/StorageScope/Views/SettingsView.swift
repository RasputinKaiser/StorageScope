import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        Form {
            Section("Scanning") {
                Toggle("Include hidden files", isOn: $store.includeHiddenFiles)
                Stepper("Treat files older than \(store.oldFileAgeDays) days as old", value: $store.oldFileAgeDays, in: 30...1440, step: 30)
            }

            Section("Filtering") {
                Picker("Default size filter", selection: $store.sizeFilter) {
                    ForEach(SizeFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
