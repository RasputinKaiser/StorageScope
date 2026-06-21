import Foundation
import StorageScopeCore

enum StorageFormat {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    // Date.FormatStyle is a thread-safe value type, unlike the shared
    // mutable DateFormatter instance used previously. Swift Testing and
    // background formatting paths can hit this concurrently.
    private static let formatDateStyle = Date.FormatStyle.dateTime.year().month().day()

    /// Cutoff for switching from "2 hours ago" to "Jun 18, 2026". Anything inside
    /// a week is recent enough that the relative time is more informative than the
    /// date, which keeps same-day files distinguishable.
    private static let relativeCutoff: TimeInterval = 7 * 24 * 60 * 60

    static func bytes(_ value: Int64) -> String {
        byteFormatter.string(fromByteCount: value)
    }

    static func date(_ date: Date?) -> String {
        guard let date else {
            return "Unknown"
        }
        return date.formatted(formatDateStyle)
    }

    /// Renders `date` as a relative phrase ("2 hours ago") when within the last week,
    /// otherwise falls back to the absolute date. Nil falls back to "Unknown", matching
    /// `date(_:)` for callers that need a stable fallback in the same column.
    static func relativeOrAbsoluteDate(_ date: Date?, relativeTo now: Date = .now) -> String {
        guard let date else {
            return "Unknown"
        }
        let age = now.timeIntervalSince(date)
        if age < 0 {
            // Future-dated (clock skew / time zone). Show the date — relative phrasing
            // for "in 5 hours" is technically correct but reads weird in a storage tool.
            return date.formatted(formatDateStyle)
        }
        if age < relativeCutoff {
            return date.formatted(.relative(presentation: .named))
        }
        return date.formatted(formatDateStyle)
    }

    static func duration(from start: Date, to end: Date) -> String {
        let totalSeconds = max(0, Int(end.timeIntervalSince(start).rounded()))
        if totalSeconds < 1 {
            return "< 1 sec"
        }
        if totalSeconds < 60 {
            return "\(totalSeconds) sec"
        }
        // Sub-10-min scans are usually the comparison case ("did this rescan run faster?")
        // — rounding to a whole minute hides meaningful differences. Show "X min Y sec"
        // until the seconds stop mattering relative to the minutes.
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes < 10 {
            return "\(minutes) min \(seconds) sec"
        }
        // Round-to-minute fine for long scans — precision stops being useful and "min"
        // truncates nicely. Don't lose precision below 1 min though.
        let rounded = minutes + (seconds >= 30 ? 1 : 0)
        return "\(rounded) min"
    }

    static func icon(for item: StorageItem) -> String {
        switch item.kind {
        case .folder:
            return "folder.fill"
        case .file:
            return "doc.fill"
        case .package:
            return "shippingbox.fill"
        case .alias:
            return "arrowshape.turn.up.right.fill"
        case .inaccessible:
            return "lock.fill"
        case .other:
            return "questionmark.square.fill"
        }
    }

    static func label(for kind: StorageItem.Kind) -> String {
        switch kind {
        case .folder:
            return "Folder"
        case .file:
            return "File"
        case .package:
            return "Package"
        case .alias:
            return "Alias"
        case .inaccessible:
            return "Inaccessible"
        case .other:
            return "Other"
        }
    }
}

extension String {
    /// Returns `self` when non-empty, otherwise `nil`. Shared so view files do not
    /// each declare their own private duplicate.
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
