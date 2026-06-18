import Foundation
import StorageScopeCore

struct ScanSession {
    var scan: StorageScan?
    var isScanning = false
    var progress = ScanProgress(scannedItemCount: 0, totalBytes: 0, currentPath: "")
    var appliedOptions: ScanStore.ScanOptionsSnapshot?
    var resultsNeedRefresh = false
    var lastScannedURL: URL?

    var canRescan: Bool {
        lastScannedURL != nil && !isScanning
    }

    var canCancelScan: Bool {
        isScanning
    }
}
