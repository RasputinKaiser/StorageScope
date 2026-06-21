import Foundation
import StorageScopeCore

struct ScanSession {
    var scan: StorageScan?
    var isScanning = false
    var progress = ScanProgress(scannedItemCount: 0, totalBytes: 0, currentPath: "")
    var appliedOptions: ScanStore.ScanOptionsSnapshot?
    var resultsNeedRefresh = false
    var lastScannedURL: URL?
    /// Set when a scan is canceled mid-flight so the UI can acknowledge the cancel.
    /// Cleared the next time `scan(_:)` starts. Previously `cancelScan` wrote a "Scan cancelled"
    /// string into `progress.currentPath` that the footer never displayed (it only shows
    /// currentPath during `isScanning`), so users got no visible feedback.
    var lastCancellationMessage: String?

    var canRescan: Bool {
        lastScannedURL != nil && !isScanning
    }

    var canCancelScan: Bool {
        isScanning
    }
}
