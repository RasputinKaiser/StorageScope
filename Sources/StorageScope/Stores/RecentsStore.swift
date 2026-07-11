import Foundation
import os

/// Shared `os_log` surface for the JSON-persisted recents stores. Hoisted out
/// of `RecentStoreWriter` because Swift reserves static stored properties for
/// non-generic types — the actor is generic over `T: Encodable`. Internal so
/// both `RecentsStore` and `SearchRecentsStore` can share one log instance.
let recentStorePersistenceLog = OSLog(subsystem: "com.rasputinkaiser.StorageScope", category: "persistence")

struct RecentScanEntry: Codable, Identifiable, Hashable {
    let path: String
    let scannedAt: Date
    let totalBytes: Int64

    var id: String { path }
}

/// The UI state for recovering a recent scan whose security-scoped bookmark no
/// longer resolves. This state deliberately contains no AppKit behavior: the
/// owner of the store can present the recovery controls and perform folder
/// selection asynchronously without an alert opening an `NSOpenPanel` inline.
enum RecentScanRecoveryState: Equatable, Identifiable {
    case idle
    case needsAction(path: String)
    case choosingFolder(path: String)

    var id: String {
        switch self {
        case .idle:
            return "idle"
        case .needsAction(let path), .choosingFolder(let path):
            return path
        }
    }

    var path: String? {
        switch self {
        case .idle:
            return nil
        case .needsAction(let path), .choosingFolder(let path):
            return path
        }
    }
}

enum RecentScanRecoveryAction: Equatable {
    case chooseFolder
    case forgetScan
    case cancel
}

/// Serializes JSON encode + UserDefaults writes for `RecentsStore` and
/// `SearchRecentsStore`. A monotonic generation counter drops writes whose
/// generation is older than the latest committed one — this is the fix for the
/// race where two `Task.detached` persist invocations reach the actor mailbox
/// out of arrival order and the older snapshot would otherwise overwrite the
/// user's most recent state. Held as a `static let` per store so writes for a
/// given storage key serialize without blocking other store's persist calls.
actor RecentStoreWriter<T: Encodable> {
    private let key: String
    private var lastWrittenGeneration: UInt64 = 0

    init(key: String) { self.key = key }

    func write(_ value: T, generation: UInt64) {
        guard generation >= lastWrittenGeneration else { return }
        lastWrittenGeneration = generation
        do {
            let data = try JSONEncoder().encode(value)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            os_log("RecentStoreWriter encode failed key=%{public}@ error=%{public}@", log: recentStorePersistenceLog, type: .error, key, String(describing: error))
        }
    }
}

/// Bounded ring of recently-scanned folder paths with their last-known scan metadata.
/// Backed by JSON in UserDefaults and migrated once from the legacy string-array format
/// that predated v0.2.0. Self-contained: there are no derived caches or cross-store
/// dependencies. v0.5.0 Tier 1 extraction from `ScanStore` — see stored research plan.
@MainActor
final class RecentsStore: ObservableObject {
    private static let legacyRecentScanPathsKey = "StorageScope.recentScanPaths"
    private static let recentScanEntriesKey = "StorageScope.recentScanEntries"
    private static let maxEntries = 8
    private static let writer = RecentStoreWriter<[RecentScanEntry]>(key: recentScanEntriesKey)

    @Published private(set) var entries: [RecentScanEntry] = []
    @Published private(set) var recoveryState: RecentScanRecoveryState = .idle
    private var writeGeneration: UInt64 = 0

    init() {
        load()
    }

    func remember(_ url: URL, scannedAt: Date, totalBytes: Int64) {
        let path = url.standardizedFileURL.path
        let entry = RecentScanEntry(path: path, scannedAt: scannedAt, totalBytes: totalBytes)
        entries.removeAll { $0.path == path }
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(Self.maxEntries))
        persist()
    }

    func forget(path: String) {
        entries.removeAll { $0.path == path }
        if recoveryState.path == path {
            recoveryState = .idle
        }
        persist()
    }

    /// Starts the explicit recovery flow for a recent scan whose bookmark could
    /// not be resolved. Calling this only changes state; it never presents a
    /// panel or an alert synchronously.
    func requestRecovery(for path: String) {
        guard !path.isEmpty else { return }
        recoveryState = .needsAction(path: path)
    }

    /// Applies one of the recovery controls while the flow is awaiting a user
    /// decision. `chooseFolder` moves to a separate state so its owner can start
    /// an asynchronous folder picker and later call `completeRecovery()`.
    @discardableResult
    func applyRecoveryAction(_ action: RecentScanRecoveryAction) -> String? {
        guard case .needsAction(let path) = recoveryState else { return nil }

        switch action {
        case .chooseFolder:
            recoveryState = .choosingFolder(path: path)
            return path
        case .forgetScan:
            forget(path: path)
            return nil
        case .cancel:
            recoveryState = .idle
            return nil
        }
    }

    /// Returns the stale path to the caller that owns folder selection and
    /// advances the state to `.choosingFolder`.
    @discardableResult
    func chooseFolderForRecovery() -> String? {
        applyRecoveryAction(.chooseFolder)
    }

    /// Removes the stale recent entry and dismisses the recovery flow.
    func forgetScanFromRecovery() {
        _ = applyRecoveryAction(.forgetScan)
    }

    /// Dismisses the recovery flow without changing the recent entry.
    func cancelRecovery() {
        guard recoveryState != .idle else { return }
        recoveryState = .idle
    }

    /// Called after the asynchronous folder picker or replacement scan finishes
    /// (including when the picker is dismissed) to return to the idle state.
    func completeRecovery() {
        recoveryState = .idle
    }

    /// Rendered @Published mutations already updated `entries` synchronously on the main
    /// actor so SwiftUI sees the change immediately; the heavy JSON encode + UserDefaults
    /// write is dispatched to `RecentStoreWriter` (a serializing actor) so the main actor
    /// doesn't block on serialization and concurrent `add(_:)` calls can't race the
    /// UserDefaults write order.
    private func persist() {
        writeGeneration += 1
        let generation = writeGeneration
        let snapshot = entries
        Task.detached(priority: .utility) { [writer = Self.writer] in
            await writer.write(snapshot, generation: generation)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.recentScanEntriesKey) {
            do {
                entries = try JSONDecoder().decode([RecentScanEntry].self, from: data)
                return
            } catch {
                // Migration-safe: drop corrupt JSON so subsequent loads see a clean
                // state instead of being stuck on undecodable bytes forever. Also
                // surfaces the failure so a future build can correlate via Console.app
                // rather than chasing a phantom plist.
                os_log("RecentsStore decode failed, resetting to empty: %{public}@", log: recentStorePersistenceLog, type: .error, String(describing: error))
                entries = []
                UserDefaults.standard.removeObject(forKey: Self.recentScanEntriesKey)
            }
        }

        // One-time migration from the v0.1.x string-array recent-scans list. Drops the
        // legacy key after migration completes so future loads skip this branch.
        let legacyPaths = UserDefaults.standard.stringArray(forKey: Self.legacyRecentScanPathsKey) ?? []
        guard !legacyPaths.isEmpty else { return }
        let now = Date()
        entries = legacyPaths.map { RecentScanEntry(path: $0, scannedAt: now, totalBytes: 0) }
        UserDefaults.standard.removeObject(forKey: Self.legacyRecentScanPathsKey)
    }
}
