import SwiftUI

struct ContentView: View {
    @ObservedObject var store: ScanStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 330)
        } detail: {
            HStack(spacing: 0) {
                DetailView(store: store)

                Divider()

                InspectorView(store: store)
                    .frame(minWidth: 300, idealWidth: 330, maxWidth: 380)
            }
        }
        .searchable(text: $store.query, placement: .toolbar, prompt: "Search files and paths")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.chooseFolderAndScan()
                } label: {
                    Label("Choose Folder", systemImage: "folder.badge.plus")
                }

                Button {
                    store.rescan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(!store.canRescan)

                if store.isScanning {
                    Button {
                        store.cancelScan()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    store.revealSelectedItem()
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
                .disabled(store.selectedItem == nil)
            }
        }
        .navigationTitle("StorageScope")
        .alert("StorageScope", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}
