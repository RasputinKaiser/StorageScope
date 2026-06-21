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

    static func bytes(_ value: Int64) -> String {
        byteFormatter.string(fromByteCount: value)
    }

    static func date(_ date: Date?) -> String {
        guard let date else {
            return "Unknown"
        }
        return date.formatted(formatDateStyle)
    }

    static func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, end.timeIntervalSince(start))
        if seconds < 1 {
            return "< 1 sec"
        }
        if seconds < 60 {
            return "\(Int(seconds.rounded())) sec"
        }
        return "\(Int((seconds / 60).rounded())) min"
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
