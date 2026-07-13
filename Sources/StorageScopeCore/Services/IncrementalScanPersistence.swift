import CoreServices
import CryptoKit
import Darwin
import Foundation

struct IncrementalChangeSet: Sendable {
    let paths: [String]
    let requiresFullScan: Bool
    let reason: String?
}

protocol IncrementalChangeSource: Sendable {
    func currentEventID() -> UInt64
    func changes(rootURL: URL, since eventID: UInt64) -> IncrementalChangeSet
}

final class SystemFSEventsChangeSource: IncrementalChangeSource, @unchecked Sendable {
    private final class Collector {
        let lock = NSLock()
        var paths: [String] = []
        var requiresFullScan = false
        var reason: String?

        func append(paths newPaths: [String], flags: UnsafePointer<FSEventStreamEventFlags>, count: Int) {
            lock.lock()
            defer { lock.unlock() }
            for index in 0..<count {
                let flag = flags[index]
                if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) == 0,
                   index < newPaths.count {
                    paths.append(newPaths[index])
                }
                if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                    requiresFullScan = true
                    reason = "event-log-overflow"
                }
                if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped) != 0 ||
                    flag & FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped) != 0 ||
                    flag & FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped) != 0 {
                    requiresFullScan = true
                    reason = "event-log-dropped"
                }
                if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 ||
                    flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMount) != 0 ||
                    flag & FSEventStreamEventFlags(kFSEventStreamEventFlagUnmount) != 0 {
                    requiresFullScan = true
                    reason = "volume-or-root-changed"
                }
            }
        }
    }

    func currentEventID() -> UInt64 {
        FSEventsGetCurrentEventId()
    }

    func changes(rootURL: URL, since eventID: UInt64) -> IncrementalChangeSet {
        let collector = Collector()
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(collector).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let collector = Unmanaged<Collector>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: CFArray.self) as? [String] ?? []
            collector.append(paths: paths, flags: flags, count: count)
        }
        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
                kFSEventStreamCreateFlagWatchRoot |
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [rootURL.path] as CFArray,
            eventID,
            0,
            createFlags
        ) else {
            return IncrementalChangeSet(paths: [], requiresFullScan: true, reason: "event-stream-unavailable")
        }

        let queue = DispatchQueue(label: "com.rasputinkaiser.StorageScope.incremental-fsevents")
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return IncrementalChangeSet(paths: [], requiresFullScan: true, reason: "event-stream-start-failed")
        }
        FSEventStreamFlushSync(stream)
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)

        collector.lock.lock()
        defer { collector.lock.unlock() }
        return IncrementalChangeSet(
            paths: collector.paths,
            requiresFullScan: collector.requiresFullScan,
            reason: collector.reason
        )
    }
}

final class LiveFSEventsMonitor: @unchecked Sendable {
    private final class State {
        let lock = NSLock()
        var paths: [String] = []
        var requiresFullScan = false
        var reason: String?
        // Every monitor in the registry starts from an event ID captured immediately
        // before construction, so there is no older range to replay before it is safe
        // to inspect newly delivered events.
        var historyReady = true

        func append(paths newPaths: [String], flags: UnsafePointer<FSEventStreamEventFlags>, count: Int) {
            lock.lock()
            defer { lock.unlock() }
            for index in 0..<count {
                let flag = flags[index]
                if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 {
                    historyReady = true
                    continue
                }
                if index < newPaths.count {
                    paths.append(newPaths[index])
                }
                if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                    requiresFullScan = true
                    reason = "event-log-overflow"
                }
                if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped) != 0 ||
                    flag & FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped) != 0 ||
                    flag & FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped) != 0 {
                    requiresFullScan = true
                    reason = "event-log-dropped"
                }
                if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 ||
                    flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMount) != 0 ||
                    flag & FSEventStreamEventFlags(kFSEventStreamEventFlagUnmount) != 0 {
                    requiresFullScan = true
                    reason = "volume-or-root-changed"
                }
            }
        }

        func drainIfReady() -> IncrementalChangeSet? {
            lock.lock()
            defer { lock.unlock() }
            guard historyReady else { return nil }
            let result = IncrementalChangeSet(
                paths: paths,
                requiresFullScan: requiresFullScan,
                reason: reason
            )
            paths.removeAll(keepingCapacity: true)
            requiresFullScan = false
            reason = nil
            return result
        }
    }

    private let state: State
    private let stream: FSEventStreamRef

    init?(rootURL: URL, since eventID: UInt64) {
        let state = State()
        self.state = state
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(state).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let state = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: CFArray.self) as? [String] ?? []
            state.append(paths: paths, flags: flags, count: count)
        }
        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
                kFSEventStreamCreateFlagWatchRoot |
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [rootURL.path] as CFArray,
            eventID,
            0.05,
            createFlags
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(
            label: "com.rasputinkaiser.StorageScope.incremental-live-fsevents"
        ))
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    func flushAndDrainIfReady() -> IncrementalChangeSet? {
        Thread.sleep(forTimeInterval: 0.06)
        FSEventStreamFlushSync(stream)
        return state.drainIfReady()
    }
}

final class LiveFSEventsMonitorRegistry: @unchecked Sendable {
    static let shared = LiveFSEventsMonitorRegistry()
    private let lock = NSLock()
    private var monitors: [String: LiveFSEventsMonitor] = [:]
    private var recency: [String] = []

    func ensure(rootURL: URL, since eventID: UInt64) {
        let key = IncrementalPathIdentity.canonicalPath(rootURL.path)
        lock.lock()
        if monitors[key] != nil {
            lock.unlock()
            return
        }
        lock.unlock()
        restart(rootURL: rootURL, since: eventID)
    }

    func restart(rootURL: URL, since eventID: UInt64) {
        let key = IncrementalPathIdentity.canonicalPath(rootURL.path)
        guard let monitor = LiveFSEventsMonitor(rootURL: rootURL, since: eventID) else { return }
        lock.lock()
        monitors[key] = monitor
        recency.removeAll { $0 == key }
        recency.append(key)
        while recency.count > 4 {
            monitors.removeValue(forKey: recency.removeFirst())
        }
        lock.unlock()
    }

    func flushAndDrainIfReady(rootURL: URL) -> IncrementalChangeSet? {
        let key = IncrementalPathIdentity.canonicalPath(rootURL.path)
        lock.lock()
        let monitor = monitors[key]
        lock.unlock()
        return monitor?.flushAndDrainIfReady()
    }
}

struct IncrementalScanOptionsFingerprint: Codable, Equatable, Hashable, Sendable {
    let includeHidden: Bool
    let oldFileAgeDays: Int
    let largeFileThreshold: Int64
    let duplicateCandidateThreshold: Int64
    let duplicateVerificationByteLimit: Int64
    let maxDuplicateVerificationFiles: Int
    let maxDuplicateCandidateItems: Int
    let maxRankedResults: Int
    let maxChildrenPerDirectory: Int
    let maxRetainedItems: Int
    let excludeEnabled: Bool
    let excludedPathComponents: [String]
    let excludedAbsolutePrefixes: [String]

    init(_ options: ScanOptions) {
        includeHidden = options.includeHidden
        oldFileAgeDays = options.oldFileAgeDays
        largeFileThreshold = options.largeFileThreshold
        duplicateCandidateThreshold = options.duplicateCandidateThreshold
        duplicateVerificationByteLimit = options.duplicateVerificationByteLimit
        maxDuplicateVerificationFiles = options.maxDuplicateVerificationFiles
        maxDuplicateCandidateItems = options.maxDuplicateCandidateItems
        maxRankedResults = options.maxRankedResults
        maxChildrenPerDirectory = options.maxChildrenPerDirectory
        maxRetainedItems = options.maxRetainedItems
        excludeEnabled = options.excludeEnabled
        excludedPathComponents = options.excludedPathComponents.sorted()
        excludedAbsolutePrefixes = options.excludedAbsolutePrefixes.sorted()
    }
}

struct PersistedWalkNode: Codable, Sendable {
    let id: Int
    let parentID: Int
    let name: String
    let kind: String
    let byteSize: Int64
    let allocatedSize: Int64
    let modifiedAt: Date?
    let isReadable: Bool
    let volumeIdentifierLow: UInt64
    let volumeIdentifierHigh: UInt64
    let fileResourceIdentifierLow: UInt64
    let fileResourceIdentifierHigh: UInt64
    let hardLinkCount: UInt16
    let isInaccessible: Bool
}

struct PersistedWalkTree: Codable, Sendable {
    static let schemaVersion = 2

    let schemaVersion: Int
    let standardizedRootPath: String
    let volumeIdentity: String
    let options: IncrementalScanOptionsFingerprint
    var checkpoint: UInt64
    var nodes: [PersistedWalkNode]

    init(
        standardizedRootPath: String,
        volumeIdentity: String,
        options: IncrementalScanOptionsFingerprint,
        checkpoint: UInt64,
        nodes: [PersistedWalkNode]
    ) {
        schemaVersion = Self.schemaVersion
        self.standardizedRootPath = standardizedRootPath
        self.volumeIdentity = volumeIdentity
        self.options = options
        self.checkpoint = checkpoint
        self.nodes = nodes
    }

    init(
        result: FixedWorkerWalkResult,
        rootURL: URL,
        volumeIdentity: String,
        options: IncrementalScanOptionsFingerprint,
        checkpoint: UInt64
    ) throws {
        guard let rootMetadata = result.rootMetadata else {
            throw IncrementalScanFallback.stateInconsistent
        }
        var inaccessibleIDs: Set<Int> = []
        var metadataByID: [Int: FixedWorkerWalkRecord] = [rootMetadata.id: rootMetadata]
        for record in result.directoryRecords {
            if record.isInaccessible {
                inaccessibleIDs.insert(record.metadata.id)
            }
            for child in record.children {
                guard metadataByID.updateValue(child, forKey: child.id) == nil else {
                    throw IncrementalScanFallback.stateInconsistent
                }
            }
        }
        let sortedMetadata = metadataByID.values.sorted { $0.id < $1.id }
        guard sortedMetadata.first?.id == 0,
              sortedMetadata.indices.allSatisfy({ sortedMetadata[$0].id == $0 }) else {
            throw IncrementalScanFallback.stateInconsistent
        }
        var persisted: [PersistedWalkNode] = []
        persisted.reserveCapacity(sortedMetadata.count)
        for metadata in sortedMetadata {
            guard metadata.id == 0 || metadata.parentID < metadata.id else {
                throw IncrementalScanFallback.stateInconsistent
            }
            persisted.append(PersistedWalkNode(
                id: metadata.id,
                parentID: metadata.parentID,
                name: metadata.name,
                kind: metadata.kind.rawValue,
                byteSize: metadata.byteSize,
                allocatedSize: metadata.allocatedSize,
                modifiedAt: metadata.modifiedAt,
                isReadable: metadata.isReadable,
                volumeIdentifierLow: metadata.volumeIdentifier.low,
                volumeIdentifierHigh: metadata.volumeIdentifier.high,
                fileResourceIdentifierLow: metadata.fileResourceIdentifier.low,
                fileResourceIdentifierHigh: metadata.fileResourceIdentifier.high,
                hardLinkCount: metadata.hardLinkCount,
                isInaccessible: inaccessibleIDs.contains(metadata.id)
            ))
        }
        let expectedNodeCount = result.directoryRecords.reduce(1) { count, record in
            count + record.children.count
        }
        guard persisted.count == expectedNodeCount else {
            throw IncrementalScanFallback.stateInconsistent
        }

        self.init(
            standardizedRootPath: rootURL.standardizedFileURL.path,
            volumeIdentity: volumeIdentity,
            options: options,
            checkpoint: checkpoint,
            nodes: persisted
        )
    }

    func makeWalkResult() throws -> FixedWorkerWalkResult {
        guard let rootNode = nodes.first,
              rootNode.id == 0,
              rootNode.parentID == 0,
              nodes.indices.allSatisfy({ nodes[$0].id == $0 }) else {
            throw IncrementalScanFallback.stateInconsistent
        }
        func metadata(for node: PersistedWalkNode) throws -> FixedWorkerWalkRecord {
            guard let kind = StorageItem.Kind(rawValue: node.kind),
                  node.id == 0 || (node.parentID >= 0 && node.parentID < node.id) else {
                throw IncrementalScanFallback.stateInconsistent
            }
            return FixedWorkerWalkRecord(
                id: node.id,
                parentID: node.parentID,
                name: node.name,
                kind: kind,
                byteSize: node.byteSize,
                allocatedSize: node.allocatedSize,
                modifiedAt: node.modifiedAt,
                isReadable: node.isReadable,
                volumeIdentifier: FixedWorkerResourceIdentifier(
                    low: node.volumeIdentifierLow,
                    high: node.volumeIdentifierHigh
                ),
                fileResourceIdentifier: FixedWorkerResourceIdentifier(
                    low: node.fileResourceIdentifierLow,
                    high: node.fileResourceIdentifierHigh
                ),
                hardLinkCount: node.hardLinkCount
            )
        }

        var childrenByParent: [[FixedWorkerWalkRecord]] = Array(repeating: [], count: nodes.count)
        for node in nodes.dropFirst() {
            guard node.parentID >= 0, node.parentID < nodes.count else {
                throw IncrementalScanFallback.stateInconsistent
            }
            childrenByParent[node.parentID].append(try metadata(for: node))
        }
        var directoryRecords: [FixedWorkerDirectoryRecord] = []
        directoryRecords.reserveCapacity(nodes.count / 4)
        for node in nodes {
            guard let kind = StorageItem.Kind(rawValue: node.kind) else {
                throw IncrementalScanFallback.stateInconsistent
            }
            let isDirectory = kind == .folder || kind == .package
            if !isDirectory {
                guard childrenByParent[node.id].isEmpty else {
                    throw IncrementalScanFallback.stateInconsistent
                }
                continue
            }
            directoryRecords.append(FixedWorkerDirectoryRecord(
                metadata: try metadata(for: node),
                children: childrenByParent[node.id].sorted { $0.name < $1.name },
                isInaccessible: node.isInaccessible
            ))
        }
        return FixedWorkerWalkResult(
            rootMetadata: try metadata(for: rootNode),
            directoryRecords: directoryRecords
        )
    }

    mutating func replaceSubtree(
        at relativePath: String,
        with replacement: PersistedWalkTree?
    ) throws {
        _ = try makeWalkResult()
        if relativePath.isEmpty {
            guard let replacement else {
                throw IncrementalScanFallback.stateInconsistent
            }
            nodes = replacement.nodes
            return
        }

        var childIDs: [[Int]] = Array(repeating: [], count: nodes.count)
        for node in nodes.dropFirst() {
            childIDs[node.parentID].append(node.id)
        }
        let components = relativePath.split(separator: "/").map(String.init)
        guard let targetName = components.last else {
            throw IncrementalScanFallback.stateInconsistent
        }
        var parentID = 0
        for component in components.dropLast() {
            guard let childID = childIDs[parentID].first(where: { nodes[$0].name == component }) else {
                throw IncrementalScanFallback.stateInconsistent
            }
            parentID = childID
        }
        let targetID = childIDs[parentID].first(where: { nodes[$0].name == targetName })
        var removed: Set<Int> = []
        if let targetID {
            var pending = [targetID]
            while let id = pending.popLast() {
                guard removed.insert(id).inserted else { continue }
                pending.append(contentsOf: childIDs[id])
            }
        }

        let survivors = nodes.filter { !removed.contains($0.id) }
        var compacted: [PersistedWalkNode] = []
        compacted.reserveCapacity(survivors.count + (replacement?.nodes.count ?? 0))
        var newIDByOldID: [Int: Int] = [:]
        for node in survivors {
            let newID = compacted.count
            let newParentID = node.id == 0 ? 0 : try Self.requiredID(newIDByOldID[node.parentID])
            newIDByOldID[node.id] = newID
            compacted.append(node.reidentified(id: newID, parentID: newParentID))
        }
        guard let compactedParentID = newIDByOldID[parentID] else {
            throw IncrementalScanFallback.stateInconsistent
        }
        if let replacement {
            var replacementIDMap: [Int: Int] = [:]
            for node in replacement.nodes {
                let newID = compacted.count
                let newParentID = node.id == 0
                    ? compactedParentID
                    : try Self.requiredID(replacementIDMap[node.parentID])
                replacementIDMap[node.id] = newID
                compacted.append(node.reidentified(id: newID, parentID: newParentID))
            }
        }
        nodes = compacted
        _ = try makeWalkResult()
    }

    var comparisonSignature: [String] {
        guard !nodes.isEmpty else { return [] }
        var childIDs: [[Int]] = Array(repeating: [], count: nodes.count)
        for node in nodes.dropFirst() where node.parentID < nodes.count {
            childIDs[node.parentID].append(node.id)
        }
        var signatures: [String] = []
        var pending: [(Int, String)] = [(0, "")]
        while let (id, path) = pending.popLast() {
            let node = nodes[id]
            let children = childIDs[id].sorted { nodes[$0].name < nodes[$1].name }
            signatures.append([
                path, node.kind, String(node.byteSize), String(node.allocatedSize),
                String(node.isReadable), String(node.isInaccessible),
                node.modifiedAt.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "nil",
                String(node.volumeIdentifierLow), String(node.volumeIdentifierHigh),
                String(node.fileResourceIdentifierLow), String(node.fileResourceIdentifierHigh),
                String(node.hardLinkCount),
                children.map { nodes[$0].name }.joined(separator: ",")
            ].joined(separator: "|"))
            for childID in children.reversed() {
                let childPath = path.isEmpty ? nodes[childID].name : path + "/" + nodes[childID].name
                pending.append((childID, childPath))
            }
        }
        return signatures.sorted()
    }

    private static func requiredID(_ value: Int?) throws -> Int {
        guard let value else { throw IncrementalScanFallback.stateInconsistent }
        return value
    }
}

private extension PersistedWalkNode {
    func reidentified(id: Int, parentID: Int) -> PersistedWalkNode {
        PersistedWalkNode(
            id: id,
            parentID: parentID,
            name: name,
            kind: kind,
            byteSize: byteSize,
            allocatedSize: allocatedSize,
            modifiedAt: modifiedAt,
            isReadable: isReadable,
            volumeIdentifierLow: volumeIdentifierLow,
            volumeIdentifierHigh: volumeIdentifierHigh,
            fileResourceIdentifierLow: fileResourceIdentifierLow,
            fileResourceIdentifierHigh: fileResourceIdentifierHigh,
            hardLinkCount: hardLinkCount,
            isInaccessible: isInaccessible
        )
    }
}

enum IncrementalScanFallback: String, Error, Sendable {
    case persistenceMissing = "persistence-missing"
    case persistenceCorrupt = "persistence-corrupt"
    case schemaIncompatible = "schema-incompatible"
    case rootChanged = "root-changed"
    case volumeChanged = "volume-changed"
    case optionsChanged = "traversal-options-changed"
    case eventHistoryUnavailable = "event-history-unavailable"
    case stateInconsistent = "parent-child-state-inconsistent"
    case tooManyDirtySubtrees = "too-many-dirty-subtrees"
}

final class IncrementalScanPersistence: @unchecked Sendable {
    struct CacheIdentity: Equatable, Sendable {
        let size: UInt64
        let modifiedAt: Date
    }

    private let baseURL: URL
    private let fileManager: FileManager
    private let encoder: PropertyListEncoder
    private let decoder: PropertyListDecoder

    init(baseURL: URL, fileManager: FileManager = .default) {
        self.baseURL = baseURL
        self.fileManager = fileManager
        encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        decoder = PropertyListDecoder()
    }

    static func defaultBaseURL(fileManager: FileManager = .default) -> URL {
        let cache = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return cache.appendingPathComponent("StorageScope/IncrementalScans", isDirectory: true)
    }

    func load(rootURL: URL) throws -> PersistedWalkTree {
        let url = cacheURL(rootURL: rootURL)
        guard fileManager.fileExists(atPath: url.path) else {
            throw IncrementalScanFallback.persistenceMissing
        }
        do {
            var tree = try decoder.decode(PersistedWalkTree.self, from: Data(contentsOf: url))
            guard tree.schemaVersion == PersistedWalkTree.schemaVersion else {
                throw IncrementalScanFallback.schemaIncompatible
            }
            let checkpointURL = checkpointURL(rootURL: rootURL)
            if fileManager.fileExists(atPath: checkpointURL.path) {
                guard let rawCheckpoint = String(data: try Data(contentsOf: checkpointURL), encoding: .utf8),
                      let checkpoint = UInt64(rawCheckpoint) else {
                    throw IncrementalScanFallback.persistenceCorrupt
                }
                tree.checkpoint = checkpoint
            }
            return tree
        } catch let fallback as IncrementalScanFallback {
            throw fallback
        } catch {
            throw IncrementalScanFallback.persistenceCorrupt
        }
    }

    func save(_ tree: PersistedWalkTree, rootURL: URL) throws {
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        try encoder.encode(tree).write(to: cacheURL(rootURL: rootURL), options: .atomic)
        try saveCheckpoint(tree.checkpoint, rootURL: rootURL)
    }

    func saveCheckpoint(_ checkpoint: UInt64, rootURL: URL) throws {
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        try Data(String(checkpoint).utf8).write(to: checkpointURL(rootURL: rootURL), options: .atomic)
    }

    func loadCheckpoint(rootURL: URL) -> UInt64? {
        guard let data = try? Data(contentsOf: checkpointURL(rootURL: rootURL)),
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }
        return UInt64(raw)
    }

    func cacheIdentity(rootURL: URL) -> CacheIdentity? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: cacheURL(rootURL: rootURL).path),
              let size = attributes[.size] as? NSNumber,
              let modifiedAt = attributes[.modificationDate] as? Date else {
            return nil
        }
        return CacheIdentity(size: size.uint64Value, modifiedAt: modifiedAt)
    }

    func cacheURL(rootURL: URL) -> URL {
        let path = rootURL.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return baseURL.appendingPathComponent("\(digest).plist")
    }

    func invalidate(rootURL: URL) {
        try? fileManager.removeItem(at: cacheURL(rootURL: rootURL))
        try? fileManager.removeItem(at: checkpointURL(rootURL: rootURL))
    }

    private func checkpointURL(rootURL: URL) -> URL {
        cacheURL(rootURL: rootURL).appendingPathExtension("checkpoint")
    }
}

final class IncrementalScanMemoryCache: @unchecked Sendable {
    private struct Key: Hashable {
        let rootPath: String
        let volumeIdentity: String
        let options: IncrementalScanOptionsFingerprint
    }

    struct Entry: Sendable {
        let scan: StorageScan
        let checkpoint: UInt64
        let cacheIdentity: IncrementalScanPersistence.CacheIdentity
    }

    static let shared = IncrementalScanMemoryCache()
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var recency: [Key] = []

    func entry(
        rootURL: URL,
        volumeIdentity: String,
        options: IncrementalScanOptionsFingerprint,
        cacheIdentity: IncrementalScanPersistence.CacheIdentity?
    ) -> Entry? {
        guard let cacheIdentity else { return nil }
        let key = Self.key(rootURL: rootURL, volumeIdentity: volumeIdentity, options: options)
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key], entry.cacheIdentity == cacheIdentity else {
            entries.removeValue(forKey: key)
            recency.removeAll { $0 == key }
            return nil
        }
        recency.removeAll { $0 == key }
        recency.append(key)
        return entry
    }

    func store(
        scan: StorageScan,
        checkpoint: UInt64,
        volumeIdentity: String,
        options: IncrementalScanOptionsFingerprint,
        cacheIdentity: IncrementalScanPersistence.CacheIdentity
    ) {
        let key = Self.key(rootURL: scan.rootURL, volumeIdentity: volumeIdentity, options: options)
        lock.lock()
        entries[key] = Entry(scan: scan, checkpoint: checkpoint, cacheIdentity: cacheIdentity)
        recency.removeAll { $0 == key }
        recency.append(key)
        while recency.count > 4 {
            entries.removeValue(forKey: recency.removeFirst())
        }
        lock.unlock()
    }

    private static func key(
        rootURL: URL,
        volumeIdentity: String,
        options: IncrementalScanOptionsFingerprint
    ) -> Key {
        Key(
            rootPath: rootURL.standardizedFileURL.path,
            volumeIdentity: volumeIdentity,
            options: options
        )
    }
}

final class IncrementalTrustVerificationRegistry: @unchecked Sendable {
    static let shared = IncrementalTrustVerificationRegistry()
    private let lock = NSLock()
    private var rootsInFlight: Set<String> = []

    func begin(rootURL: URL) -> Bool {
        let key = IncrementalPathIdentity.canonicalPath(rootURL.path)
        lock.lock()
        defer { lock.unlock() }
        return rootsInFlight.insert(key).inserted
    }

    func finish(rootURL: URL) {
        let key = IncrementalPathIdentity.canonicalPath(rootURL.path)
        lock.lock()
        rootsInFlight.remove(key)
        lock.unlock()
    }
}

enum IncrementalVolumeIdentity {
    static func read(from rootURL: URL) -> String? {
        let keys: Set<URLResourceKey> = [.volumeUUIDStringKey, .volumeURLKey]
        guard let values = try? rootURL.resourceValues(forKeys: keys) else { return nil }
        if let uuid = values.volumeUUIDString, !uuid.isEmpty {
            return uuid
        }
        return values.volume?.standardizedFileURL.path
    }
}

enum IncrementalPathIdentity {
    static func canonicalPath(_ path: String, fileManager: FileManager = .default) -> String {
        var existingPath = URL(fileURLWithPath: path).standardizedFileURL.path
        var missingComponents: [String] = []
        while !fileManager.fileExists(atPath: existingPath), existingPath != "/" {
            let url = URL(fileURLWithPath: existingPath)
            missingComponents.insert(url.lastPathComponent, at: 0)
            existingPath = url.deletingLastPathComponent().path
        }

        let resolvedBase: String
        if let pointer = realpath(existingPath, nil) {
            resolvedBase = String(cString: pointer)
            free(pointer)
        } else {
            resolvedBase = existingPath
        }
        return missingComponents.reduce(resolvedBase) { partial, component in
            URL(fileURLWithPath: partial).appendingPathComponent(component).path
        }
    }
}
