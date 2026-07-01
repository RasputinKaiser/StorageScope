import Foundation
import StorageScopeCore

struct ScanSession {
    var scan: StorageScan?
    var isScanning = false
    var progress = ScanProgress(scannedItemCount: 0, totalBytes: 0, currentPath: "")
    var appliedOptions: ScanStore.ScanOptionsSnapshot?
    var resultsNeedRefresh = false
    var lastScannedURL: URL?
    /// Wall-clock start of the current/most-recent scan, for the elapsed-time display.
    /// Set when `ScanStore.scan(_:)` starts; not reset on cancel so the footer can still
    /// show "ran for Ns" alongside the cancellation notice.
    var scanStartedAt: Date?
    /// Set when a scan is canceled mid-flight so the UI can acknowledge the cancel.
    /// Cleared the next time `scan(_:)` starts. Previously `cancelScan` wrote a "Scan cancelled"
    /// string into `progress.currentPath` that the footer never displayed (it only shows
    /// currentPath during `isScanning`), so users got no visible feedback.
    var lastCancellationMessage: String?

    /// Last scan/bookmark/trash error category surfaced through `errorMessage`. Mirrors
    /// `lastCancellationMessage`'s lifecycle (cleared on the next `scan(_:)` start) so the
    /// alert UI and tests can assert on what kind of failure just happened — permission
    /// denial, missing folder, stale bookmark, internal — without parsing the alert string.
    /// Nil after a cancellation, since cancellation is intentionally silent.
    var lastErrorCategory: ScanStore.ScanStoreErrorCategory?

    /// True while an in-flight scan is paused (in-memory only — not persisted). Reset to
    /// false whenever a new scan starts.
    var isScanPaused = false

    var canRescan: Bool {
        lastScannedURL != nil && !isScanning
    }

    var canCancelScan: Bool {
        isScanning
    }

    var canPauseScan: Bool {
        isScanning && !isScanPaused
    }

    var canResumeScan: Bool {
        isScanning && isScanPaused
    }
}
