import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: ScanStore
    var onOpenSettings: () -> Void = {}
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    // The inspector is secondary UI and must never be the reason the window
    // doesn't fit the display — start it closed on narrow screens (UI_PLAN.md P0.3).
    @State private var inspectorVisible = (NSScreen.main?.visibleFrame.width ?? 1440) >= 1350
    @FocusState private var searchFieldFocused: Bool

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
                // Ideal stays close to min: NavigationSplitView satisfies every
                // column's *ideal* before it compresses toward min — inflated ideals
                // made it slide the sidebar off-screen at 1280pt (UI_PLAN.md P0.2).
                // 240 fits the smart-view titles plus reclaim badges; total ideals
                // (240 + 700 + 260) still clear a 1280pt window comfortably.
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 330)
        } detail: {
            DetailView(store: store)
                // Cap the *reported* ideal width. NavigationSplitView sizes the
                // detail column to its content's ideal (ViewThatFits and ScrollView
                // report the widest branch at an unspecified proposal) and slides
                // the sidebar off-screen instead of compressing — the
                // navigationSplitViewColumnWidth spec alone did not override that.
                // The views adapt down to ~600pt via ViewThatFits fallbacks.
                .frame(minWidth: 500, idealWidth: 560, maxWidth: .infinity)
                .navigationSplitViewColumnWidth(min: 500, ideal: 560)
        }
        // Attached to the split view (not nested in the detail column): nesting made
        // the inspector participate in the detail column's width negotiation, which
        // slid the sidebar off-screen and clipped the inspector at ≤1308pt windows.
        .inspector(isPresented: $inspectorVisible) {
            InspectorView(store: store)
                .inspectorColumnWidth(min: 260, ideal: 260, max: 380)
        }
        .searchable(text: store.filterBinding(\.searchText), placement: .toolbar, prompt: searchPrompt)
        .searchSuggestions {
            // Only surface when field is empty/blank — once the user is typing,
            // the search field's own auto-complete is more useful than a stale
            // recent, and the suggestions list shouldn't crowd their input.
            if store.filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ForEach(store.searchRecents.entries, id: \.self) { recent in
                    Button {
                        store.filters.searchText = recent
                    } label: {
                        Label(recent, systemImage: "clock.arrow.circlepath")
                    }
                }
                if !store.searchRecents.entries.isEmpty {
                    Button(role: .destructive) {
                        store.searchRecents.clear()
                    } label: {
                        Label("Clear Recents", systemImage: "trash")
                    }
                }
            }
        }
        .modifier(SearchFocusModifier(focused: $searchFieldFocused))
        .onChange(of: store.searchFieldFocusRequest) { _, _ in
            // AppDelegate's Find command (Cmd+F) bumps the request counter; the
            // counter is a counter rather than a Bool so Cmd+F re-fires even after
            // the field is already focused (a la Mail / Finder).
            searchFieldFocused = true
        }
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
                        store.canPauseScan ? store.pauseScan() : store.resumeScan()
                    } label: {
                        Label(
                            store.canResumeScan ? "Resume" : "Pause",
                            systemImage: store.canResumeScan ? "play.circle" : "pause.circle"
                        )
                    }

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
                    inspectorVisible.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help(inspectorVisible ? "Hide Inspector" : "Show Inspector")

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
                filters: store.filters,
                actions: TrashReviewActions(
                    isMoving: store.isMovingToTrash,
                    reveal: { store.revealTrashReviewItem($0) },
                    revealAll: { store.revealAllTrashReviewItems($0) },
                    open: { store.openTrashReviewItem($0) },
                    remove: { store.removePendingTrashReviewItem($0) },
                    removeAll: { store.removeAllPendingTrashReviewItems($0) },
                    cancel: { store.cancelPendingTrashReview() },
                    confirm: { store.confirmPendingTrashReview() }
                )
            )
        }
    }
}

/// Bridges `.searchFocused(_:)` (macOS 15+) to a macOS 14 deployment target via
/// `if #available`. The Find command (Cmd+F) writes `true` to the focus state via
/// `-onChange(of: store.searchFieldFocusRequest)`; this modifier applies the actual
/// `.searchFocused` modifier when the running OS supports it. On macOS 14 the focus
/// state is tracked but doesn't drive `.searchable`'s internal field — acceptable
/// fallback since macOS 14 is now an older release and the Finder-style keyboard
/// cheat-sheet still surfaces "Find... F" as a menu hint.
private struct SearchFocusModifier: ViewModifier {
    @FocusState.Binding var focused: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.searchFocused($focused)
        } else {
            content
        }
    }
}
