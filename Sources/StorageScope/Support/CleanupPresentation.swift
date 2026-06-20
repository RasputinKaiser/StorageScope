import StorageScopeCore
import SwiftUI

extension CleanupCandidate.Kind {
    var displayName: String {
        switch self {
        case .verifiedDuplicate:
            return "Verified Duplicate"
        case .oldLargeFile:
            return "Old Large File"
        case .archive:
            return "Archive"
        case .installer:
            return "Installer"
        case .diskImage:
            return "Disk Image"
        case .cacheFolder:
            return "Cache Folder"
        case .buildArtifact:
            return "Build Artifact"
        case .temporary:
            return "Temporary"
        case .general:
            return "Selected Item"
        }
    }

    var systemImage: String {
        switch self {
        case .verifiedDuplicate:
            return "checkmark.seal.fill"
        case .oldLargeFile:
            return "clock.badge.exclamationmark"
        case .archive:
            return "archivebox.fill"
        case .installer:
            return "shippingbox.fill"
        case .diskImage:
            return "externaldrive.fill"
        case .cacheFolder:
            return "folder.badge.gearshape"
        case .buildArtifact:
            return "hammer.fill"
        case .temporary:
            return "timer"
        case .general:
            return "trash"
        }
    }
}

extension CleanupCandidate.Confidence {
    var displayName: String {
        switch self {
        case .high:
            return "Verified"
        case .medium:
            return "Medium Confidence"
        case .review:
            return "Review"
        }
    }

    var tint: Color {
        switch self {
        case .high:
            return .green
        case .medium:
            return .orange
        case .review:
            return .blue
        }
    }
}
