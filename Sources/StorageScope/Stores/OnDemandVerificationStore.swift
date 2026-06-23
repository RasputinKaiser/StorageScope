import Foundation
import os.signpost
import StorageScopeCore

/// Bounded state and orchestration for out-of-band SHA-256 verification of same-size
/// duplicate candidate groups that fell outside the scan-time auto-verification budget.
/// Layered on top of the scan-time `scan.verifiedDuplicateGroups` so the user can surface
/// real matches on demand via the "Verify Now" affordance on each same-size group card.
///
/// v0.5.0 Tier 1b extraction from `ScanStore`. The store owns its `@Published` state
/// (verified hashes + in-flight group ids) and the verify task; cross-store coordination
/// back into `ScanStore` happens via the closures passed at init so there's no circular
/// observer dependency.
@MainActor
final class OnDemandVerificationStore: ObservableObject {
    /// os_signpost surface for Instruments. Shares the scan subsystem/category so on-demand
    /// Verify Now + persist work shows up alongside scan-phase signposts (#81-pattern).
    private static let log = OSLog(subsystem: "com.rasputinkaiser.StorageScope", category: "scan")
    private static let signpostID = OSSignpostID(log: log)

    /// Verified duplicate groups revealed by user-triggered Verify Now taps, keyed by the
    /// SHA-256 checksum so re-verifying the same group replaces rather than duplicates.
    @Published private(set) var verifiedGroupsByChecksum: [String: VerifiedDuplicateGroup] = [:]
    /// Group ids currently being hashed on a background task. Used to drive a per-row
    /// spinner + "Verifying…" label in the same-size candidate UI.
    @Published private(set) var verifyingGroupIDs: Set<String> = []

    private let hashCache: DuplicateHashCache
    private let scanLookup: () -> StorageScan?
    private let coordinateInvalidate: () -> Void
    private let reportError: (String) -> Void

    /// In-flight verify tasks keyed by `DuplicateSizeGroup.id` so the user can cancel a
    /// specific group without disturbing other concurrent verifications.
    private var verifyTasksByID: [String: Task<Void, Never>] = [:]
    /// Cooperative cancellation handles mirroring `FileSystemScanner.ScanCancellation`. Kept
    /// alongside the task so hashing I/O bails out at the next chunk boundary instead of
    /// waiting for a whole file to hash before noticing the Swift task was cancelled.
    private var verifyCancellationsByID: [String: ScanCancellation] = [:]
    /// Group IDs that have completed verification at least once. Non-duplicate items (singletons
    /// after hashing) are intentionally absent from `verifiedGroupsByChecksum`, so the
    /// item-coverage check in `isGroupAlreadyVerified` would incorrectly re-verify them.
    /// Tracking completed IDs separately ensures re-verify taps are always a no-op.
    private var completedVerificationGroupIDs: Set<String> = []

    init(
        hashCache: DuplicateHashCache,
        scanLookup: @escaping () -> StorageScan?,
        coordinateInvalidate: @escaping () -> Void,
        reportError: @escaping (String) -> Void
    ) {
        self.hashCache = hashCache
        self.scanLookup = scanLookup
        self.coordinateInvalidate = coordinateInvalidate
        self.reportError = reportError
    }

    /// Hashes every file in `group` on a background task and merges any resulting
    /// `VerifiedDuplicateGroup` entries into `verifiedGroupsByChecksum`. Skips no-ops when
    /// every item is already covered by a verified group at the same byte size.
    func verify(_ group: DuplicateSizeGroup) {
        guard !isGroupAlreadyVerified(group) else { return }
        guard !verifyingGroupIDs.contains(group.id) else { return }
        verifyingGroupIDs.insert(group.id)

        let cancellation = ScanCancellation()
        verifyCancellationsByID[group.id] = cancellation
        let cache = hashCache

        // Pass a `ScanCancellation` (in addition to the Swift Task) so hashing I/O bails
        // at the next read-chunk boundary instead of finishing the whole file before the
        // task cancellation is observed.
        let task: Task<Void, Never> = Task { [weak self] in
            let result: Result<[VerifiedDuplicateGroup], Error>
            do {
                try Task.checkCancellation()
                let groups = try await Task.detached(priority: .userInitiated) { [cache] in
                    let scanner = FileSystemScanner(hashCache: cache)
                    return try scanner.verifySizeGroup(group, cancellation: cancellation)
                }.value

                // FileSystemScanner swallows `cancellation.check()` errors inside a `try?`
                // during `compactMap`, so a mid-stream cancel lands here as `.success`
                // with whatever fragments hashed before the cancel. Promote it to an
                // explicit cancellation so the store discards partial results instead of
                // surfacing phantom verified groups.
                if cancellation.isCancelled {
                    result = .failure(FileSystemScannerError.cancelled)
                } else {
                    result = .success(groups)
                }
            } catch is CancellationError {
                result = .failure(FileSystemScannerError.cancelled)
            } catch {
                result = .failure(error)
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.verifyingGroupIDs.remove(group.id)
                self.verifyCancellationsByID.removeValue(forKey: group.id)
                self.verifyTasksByID.removeValue(forKey: group.id)

                // Re-check cancellation right before merging. A cancel that lands between
                // the detached hash completing and this main-actor closure running (while
                // we were parked waiting for the main actor) must still discard partial
                // results — otherwise the user's abort silently surfaces phantom groups.
                if cancellation.isCancelled || Task.isCancelled {
                    return
                }

                switch result {
                case .success(let groups):
                    self.completedVerificationGroupIDs.insert(group.id)
                    for verifiedGroup in groups {
                        self.verifiedGroupsByChecksum[verifiedGroup.checksum] = verifiedGroup
                    }
                    self.coordinateInvalidate()
                    self.persistAsync(group: group)
                case .failure(let error):
                    if case FileSystemScannerError.cancelled = error {
                        // Cancellation is a user action, not an error to surface.
                        return
                    }
                    self.reportError("Verification failed: \(error.localizedDescription)")
                }
            }
        }
        verifyTasksByID[group.id] = task
    }

    /// Cancel an in-flight on-demand verify for `groupID`. Partial hashed fragments are
    /// discarded. Returns `true` when a verify was active for the id.
    @discardableResult
    func cancelVerification(forGroupID groupID: String) -> Bool {
        let cancellation = verifyCancellationsByID.removeValue(forKey: groupID)
        let task = verifyTasksByID.removeValue(forKey: groupID)
        cancellation?.cancel()
        task?.cancel()
        verifyingGroupIDs.remove(groupID)
        return cancellation != nil || task != nil
    }

    /// Cancel every in-flight on-demand verify and clear the `verifyingGroupIDs` set.
    /// Called from `clear()` so a fresh scan doesn't resurrect stale verified groups or
    /// leave orphaned verify tasks running.
    func cancelAllVerifications() {
        for cancellation in verifyCancellationsByID.values {
            cancellation.cancel()
        }
        for task in verifyTasksByID.values {
            task.cancel()
        }
        verifyCancellationsByID.removeAll()
        verifyTasksByID.removeAll()
        verifyingGroupIDs.removeAll()
    }

    /// `true` when `group` has already been verified — either by this store or by the scan-time
    /// budget. Non-duplicate items (singletons after hashing) are intentionally absent from
    /// `verifiedGroupsByChecksum`, so checking item coverage alone would incorrectly re-verify
    /// a group whose singletons got filtered out. The `completedVerificationGroupIDs` set
    /// short-circuits that case.
    private func isGroupAlreadyVerified(_ group: DuplicateSizeGroup) -> Bool {
        if completedVerificationGroupIDs.contains(group.id) { return true }
        let targetIDs = Set(group.items.map(\.id))
        let candidates = (scanLookup()?.verifiedDuplicateGroups ?? []) + Array(verifiedGroupsByChecksum.values)
        return candidates.contains { verified in
            verified.byteSize == group.byteSize &&
                targetIDs.isSubset(of: Set(verified.items.map(\.id)))
        }
    }

    /// Reset state called from `ScanStore.scan(_:)`'s new-scan path. Drops verified
    /// duplicates discovered by user-triggered Verify Now actions so they don't bleed
    /// into the next scan's UI until the user re-verifies.
    func clear() {
        cancelAllVerifications()
        verifiedGroupsByChecksum.removeAll()
        completedVerificationGroupIDs.removeAll()
    }

    /// Persists the in-memory hash cache off the main actor. Failures surface through
    /// `reportError` and close the `persist_on_demand` signpost as an error interval so
    /// they show up in Instruments alongside scan-phase spans.
    private func persistAsync(group: DuplicateSizeGroup) {
        let cacheToPersist = hashCache
        let persistSignpostID = OSSignpostID(log: OnDemandVerificationStore.log,
                                             object: group.id as NSString)
        Task { [weak self] in
            os_signpost(.begin, log: OnDemandVerificationStore.log,
                        name: "persist_on_demand", signpostID: persistSignpostID,
                        "group=%@", group.id)
            do {
                try await Task.detached(priority: .utility) {
                    try cacheToPersist.persistThrowing()
                }.value
                os_signpost(.end, log: OnDemandVerificationStore.log,
                            name: "persist_on_demand", signpostID: persistSignpostID)
            } catch {
                let errorMessage = error.localizedDescription
                os_signpost(.end, log: OnDemandVerificationStore.log,
                            name: "persist_on_demand", signpostID: persistSignpostID,
                            "error=%{public}@", errorMessage)
                await MainActor.run { [weak self] in
                    self?.reportError("Could not save verification cache: \(errorMessage)")
                }
            }
        }
    }
}