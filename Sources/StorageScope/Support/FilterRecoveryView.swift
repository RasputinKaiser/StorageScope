import SwiftUI

/// Distinguishes why a list came back empty so `FilterRecoveryView` can show
/// state-appropriate copy + iconography instead of a single generic "No Items"
/// message.
///
/// - `.noScan`: list is empty because no scan is loaded or no filters are
///   active (the original v0.4.5 default). Preserves existing call sites that
///   don't pass `state:` by routing through this case.
/// - `.noMatches(query:)`: a search query is currently active and returned
///   zero hits. The query is carried so the empty state can echo it back to
///   the user ("No items matched 'foo'. Try a different search term…").
/// - `.filteredEmpty`: non-query filters are active (size / file-type / lane)
///   and zero items pass them. Distinct from `.noMatches` because the user's
///   mental model is "my filter chip is wrong", not "my search text is wrong".
enum FilterRecoveryState: Equatable {
    case noScan
    case noMatches(query: String)
    case filteredEmpty
}

struct FilterRecoveryView: View {
    let title: String
    let systemImage: String
    let descriptionText: String?
    let filters: [String]
    let clearTitle: String
    let clearAction: () -> Void
    let state: FilterRecoveryState

    init(
        title: String,
        systemImage: String,
        description: String? = nil,
        filters: [String] = [],
        state: FilterRecoveryState = .noScan,
        clearTitle: String,
        clearAction: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.descriptionText = description
        self.filters = filters
        self.state = state
        self.clearTitle = clearTitle
        self.clearAction = clearAction
    }

    var body: some View {
        ContentUnavailableView {
            Label(resolvedTitle, systemImage: resolvedSystemImage)
        } description: {
            VStack(spacing: 8) {
                Text(resolvedDescription)

                if !filters.isEmpty {
                    Text(filters.joined(separator: "  |  "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
        } actions: {
            // Only show Clear when there's actually something to clear — with no active
            // filters this button was previously a visible no-op, which is what made BUG-1's
            // "no items" empty states read as broken rather than as honest "nothing here".
            if !filters.isEmpty {
                Button(clearTitle) {
                    clearAction()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    /// For `.noMatches`, override the caller-supplied title so the empty state
    /// reads "No Matches" instead of the catch-all "No Items" used for the
    /// unfiltered, no-scan case. Caller-provided titles (e.g. "No File Types")
    /// are still honored for `.noScan` and `.filteredEmpty`.
    private var resolvedTitle: String {
        switch state {
        case .noMatches:
            return "No Matches"
        default:
            return title
        }
    }

    /// Magnifying glass is the universal "no search results" icon on macOS;
    /// funnel for filter chips; otherwise delegate to the caller-provided
    /// systemImage (per-view branding).
    private var resolvedSystemImage: String {
        switch state {
        case .noMatches:
            return "magnifyingglass"
        case .filteredEmpty:
            return "line.3.horizontal.decrease.circle"
        case .noScan:
            return systemImage
        }
    }

    private var resolvedDescription: String {
        if let descriptionText {
            return descriptionText
        }
        switch state {
        case .noScan:
            return "No items are available in this view."
        case .noMatches(let query):
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "No items matched your search."
            }
            return "No items matched '\(trimmed)'. Try a different search term or clear filters."
        case .filteredEmpty:
            return "Adjust active filters to see more items."
        }
    }
}