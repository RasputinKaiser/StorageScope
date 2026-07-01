import Foundation
import Testing
@testable import StorageScope

@Suite("ScanSession pause/resume guards")
struct ScanSessionPauseResumeTests {
    @Test("canPauseScan is false when not scanning")
    func canPauseFalseWhenIdle() {
        var session = ScanSession()
        session.isScanning = false
        session.isScanPaused = false
        #expect(session.canPauseScan == false)
        #expect(session.canResumeScan == false)
    }

    @Test("canPauseScan is true while scanning and not paused")
    func canPauseTrueWhileScanning() {
        var session = ScanSession()
        session.isScanning = true
        session.isScanPaused = false
        #expect(session.canPauseScan == true)
        #expect(session.canResumeScan == false)
    }

    @Test("canResumeScan is true while scanning and paused")
    func canResumeTrueWhilePaused() {
        var session = ScanSession()
        session.isScanning = true
        session.isScanPaused = true
        #expect(session.canPauseScan == false)
        #expect(session.canResumeScan == true)
    }

    @Test("neither pause nor resume is available once scanning stops, even if isScanPaused lingers")
    func neitherAvailableAfterScanStops() {
        var session = ScanSession()
        session.isScanning = false
        session.isScanPaused = true
        #expect(session.canPauseScan == false)
        #expect(session.canResumeScan == false)
    }
}
