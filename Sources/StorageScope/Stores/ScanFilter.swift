import Foundation

struct ScanFilter {
    var query = ""
    var sizeFilter: SizeFilter = .all
    var sortOption: ItemSortOption = .sizeDescending
    var cleanupLaneFilter: CleanupLaneFilter = .all
    var includeHiddenFiles = false
    var oldFileAgeDays = 180

    var activeDisplayFilterDescriptions: [String] {
        var descriptions: [String] = []
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            descriptions.append("Search: \(trimmedQuery)")
        }
        if sizeFilter != .all {
            descriptions.append("Size: \(sizeFilter.title)")
        }
        return descriptions
    }

    var activeCleanupFilterDescriptions: [String] {
        var descriptions = activeDisplayFilterDescriptions
        if cleanupLaneFilter != .all {
            descriptions.append("Lane: \(cleanupLaneFilter.title)")
        }
        return descriptions
    }

    mutating func resetDisplayFilters() {
        query = ""
        sizeFilter = .all
    }

    mutating func resetCleanupFilters() {
        resetDisplayFilters()
        cleanupLaneFilter = .all
    }
}
