import Foundation

enum SmartView: String, CaseIterable, Identifiable {
    case overview
    case cleanupReview
    case tree
    case largestFolders
    case largestFiles
    case oldLargeFiles
    case typeBreakdown
    case duplicateCandidates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview:
            return "Overview"
        case .cleanupReview:
            return "Cleanup Review"
        case .tree:
            return "Folder Tree"
        case .largestFolders:
            return "Largest Folders"
        case .largestFiles:
            return "Largest Files"
        case .oldLargeFiles:
            return "Old Large Files"
        case .typeBreakdown:
            return "File Types"
        case .duplicateCandidates:
            return "Duplicate Review"
        }
    }

    var subtitle: String {
        switch self {
        case .overview:
            return "Storage command center"
        case .cleanupReview:
            return "High-signal reclaim targets"
        case .tree:
            return "Browse the scanned hierarchy"
        case .largestFolders:
            return "Folders ranked by footprint"
        case .largestFiles:
            return "Individual files worth inspecting"
        case .oldLargeFiles:
            return "Large files not touched recently"
        case .typeBreakdown:
            return "Where space goes by extension"
        case .duplicateCandidates:
            return "Verified and suspected copies"
        }
    }

    var systemImage: String {
        switch self {
        case .overview:
            return "gauge.with.dots.needle.67percent"
        case .cleanupReview:
            return "checklist"
        case .tree:
            return "list.bullet.indent"
        case .largestFolders:
            return "folder.fill.badge.gearshape"
        case .largestFiles:
            return "doc.text.magnifyingglass"
        case .oldLargeFiles:
            return "clock.badge.exclamationmark"
        case .typeBreakdown:
            return "chart.pie.fill"
        case .duplicateCandidates:
            return "checkmark.seal"
        }
    }

    /// Views whose rows are individual files (rather than folders / categories) and so
    /// can serve as a destination for the `Type: <ext>` filter chip set from
    /// TypeBreakdownView. Used by ScanStore.selectedView's didSet to auto-clear a stale
    /// file-type focus when the user navigates to a view it doesn't apply to.
    var supportsFileTypeFocus: Bool {
        switch self {
        case .largestFiles, .oldLargeFiles, .duplicateCandidates:
            return true
        case .overview, .cleanupReview, .tree, .largestFolders, .typeBreakdown:
            return false
        }
    }
}

enum SizeFilter: Int, CaseIterable, Identifiable {
    case all
    case over100MB
    case over1GB
    case over10GB

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All Sizes"
        case .over100MB:
            return "> 100 MB"
        case .over1GB:
            return "> 1 GB"
        case .over10GB:
            return "> 10 GB"
        }
    }

    var threshold: Int64 {
        switch self {
        case .all:
            return 0
        case .over100MB:
            return 100_000_000
        case .over1GB:
            return 1_000_000_000
        case .over10GB:
            return 10_000_000_000
        }
    }
}

enum ItemSortOption: String, CaseIterable, Identifiable {
    case sizeDescending
    case nameAscending
    case modifiedNewest
    case modifiedOldest
    case kind

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sizeDescending:
            return "Size"
        case .nameAscending:
            return "Name"
        case .modifiedNewest:
            return "Newest"
        case .modifiedOldest:
            return "Oldest"
        case .kind:
            return "Kind"
        }
    }
}

enum CleanupLaneFilter: String, CaseIterable, Identifiable {
    case all
    case verified
    case suggestions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .verified:
            return "Verified"
        case .suggestions:
            return "Suggestions"
        }
    }

    var detail: String {
        switch self {
        case .all:
            return "All reclaim leads"
        case .verified:
            return "Content-matched duplicates"
        case .suggestions:
            return "Needs manual review"
        }
    }
}
