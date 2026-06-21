import SwiftUI

struct ContentView: View {
    @ObservedObject var store: ScanStore
    var onOpenSettings: () -> Void = {}
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Search-field prompt that reflects what the active view actually filters —
    /// "files and paths" misleads on Tree (where rows are folders) and on File Types
    /// (where rows are extension stats). Kept here instead of computed in ScanStore so
    /// the prompt stays a UI concern, not a store concern.
    private var searchPrompt: String {
        switch store.activeView {
        case .tree:
            return "Search folders and paths"
        case .typeBreakdown:
            return "Search extensions"
        case .duplicateCandidates:
            return "Search duplicate paths"
        case .cleanupReview:
            return "Search cleanup candidates"
        case .largestFolders:
            return "Search largest folders"
        case .largestFiles, .oldLargeFiles:
            return "Search files and paths"
        case .overview:
            return "Search files and paths"
        }
    }

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
        .searchable(text: store.filterBinding(\.searchText), placement: .toolbar, prompt: searchPrompt)
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
                    revealAll: { store.revealAllTrashReviewItems($0) },
                    open: { store.openTrashReviewItem($0) },
                    remove: { store.removePendingTrashReviewItem($0) },
                    cancel: { store.cancelPendingTrashReview() },
                    confirm: { store.confirmPendingTrashReview() }
                )
            )
        }
    }
}
