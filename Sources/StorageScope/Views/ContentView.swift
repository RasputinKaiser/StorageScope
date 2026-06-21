import SwiftUI

struct ContentView: View {
    @ObservedObject var store: ScanStore
    var onOpenSettings: () -> Void = {}
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
        .searchable(text: store.filterBinding(\.searchText), placement: .toolbar, prompt: "Search files and paths")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.chooseFolderAndScan()
                } label: {
                    Label(L10n.string("Choose Folder"), systemImage: "folder.badge.plus")
                }
                .disabled(store.isScanning)

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

                Button {
                    onOpenSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Open scan and display settings")
            }
        }
        .navigationTitle(L10n.string("StorageScope"))
        .alert(L10n.string("StorageScope"), isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        .sheet(item: $store.pendingTrashReviewPlan) { plan in
            TrashConfirmationSheet(
                plan: plan,
                actions: TrashReviewActions(
                    isMoving: store.isMovingToTrash,
                    reveal: { store.revealTrashReviewItem($0) },
                    remove: { store.removePendingTrashReviewItem($0) },
                    cancel: { store.cancelPendingTrashReview() },
                    confirm: { store.confirmPendingTrashReview() }
                )
            )
        }
    }
}
