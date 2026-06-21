import Foundation
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

        let cache = hashCache
        Task { [weak self] in
            let result: Result<[VerifiedDuplicateGroup], Error>
            do {
                let groups = try await Task.detached(priority: .userInitiated) {
                    let scanner = FileSystemScanner(hashCache: cache)
                    return try scanner.verifySizeGroup(group, cancellation: nil)
                }.value
                result = .success(groups)
            } catch {
                result = .failure(error)
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.verifyingGroupIDs.remove(group.id)

                switch result {
                case .success(let groups):
                    for verifiedGroup in groups {
                        self.verifiedGroupsByChecksum[verifiedGroup.checksum] = verifiedGroup
                    }
                    self.coordinateInvalidate()
                    let cacheToPersist = self.hashCache
                    Task.detached(priority: .utility) { cacheToPersist.persist() }
                case .failure(let error):
                    self.reportError("Verification failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// `true` when every item in `group` is already covered by a verified duplicate group
    /// (scan-time or on-demand) at the same byte size — i.e. calling `verify(_:)` would be
    /// a no-op. Used to skip superfluous Verify Now taps cheaply.
    private func isGroupAlreadyVerified(_ group: DuplicateSizeGroup) -> Bool {
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
        verifiedGroupsByChecksum.removeAll()
        verifyingGroupIDs.removeAll()
    }
}