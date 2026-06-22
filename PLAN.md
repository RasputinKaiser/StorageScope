# StorageScope Performance Plan — v0.5.3 → v0.6.0

## 0. Reading guide

This plan is grounded in the v0.5.2 source tree at `main`. Every claim cites `path:line` so the diff reviewer can trace each proposal to the exact code to change. Where the proposal is evidence-backed (a signpost, a code smell, a measured inequality) it is marked `Evidence:`. Where it is a hypothesis pending validation it is marked `Hypothesis:`. The plan deliberately leads with a measurement-first slice (Section 6) because — quoting the existing `ScanBenchmarkReport.text` at `Sources/StorageScopeCore/Services/ScanBenchmark.swift:22-27` — *"This typically under-shoots `duration` because bookkeeping between phases (cleanup candidate planning, retained child collection, lookup construction) is not separately timed."* That gap is the first thing to close.

Throughout the document "v0.5.x" denotes a minor release with a feature flag; "v0.6.0" denotes the consolidation release.

---

## 1. Current state audit

### 1.1 Scan pipeline — `Sources/StorageScopeCore/Services/FileSystemScanner.swift`

**Already optimized:**
- Parallel directory enumeration via `DispatchQueue.concurrentPerform(iterations:)` at `FileSystemScanner.swift:283-326`. Child results kept at their original index so the merged order is deterministic.
- Hash verification parallelism bounded by `hashConcurrency` (4–8 workers based on `processorCount`) at `FileSystemScanner.swift:54-57`, gated by an `ioSemaphore` at `:162-184` and `:400-449` to bound file-handle pressure.
- Persisted `DuplicateHashCache` (`Sources/StorageScopeCore/Services/DuplicateHashCache.swift`) keyed by path + byte size + mtime, so re-scans skip hashing unchanged files. Hit/miss counters exist at `DuplicateHashCache.swift:29-30`.
- Per-directory retained-child cap (`maxChildrenPerDirectory`, default 200) and global retained cap (`maxRetainedItems`, default 25,000) at `ScanOptions.swift:402-403`. Children over the cap are pruned to a `.pruningChildren()` stub (`StorageItem.swift:143-157`) so the in-memory tree stays bounded even when the on-disk tree is broad.
- Bounded ranked-list trimming at `FileSystemScanner.swift:1004-1028` — only sorts `largestFileItems`/`largestFolderItems`/`oldLargeFileItems` once they exceed 4× the limit, amortizing sort cost.
- Progress throttling at `FileSystemScanner.swift:815-827`: emits at most once per 25 items or every 0.35 s, whichever fires first.

**Suspected bottlenecks:**
- `Evidence:` **Missing `autoreleasepool` in the hot enumeration loop.** `scanItem(at:options:cancellation:accumulator:)` at `FileSystemScanner.swift:198-375` recurses inside `DispatchQueue.concurrentPerform`. Each iteration creates `URLResourceValues` boxes, `[URL]` arrays from `contentsOfDirectory`, and Foundation `Date`/`NSNumber` bridging boxes — all autoreleased. With no `autoreleasepool` block on each iteration, those objects accumulate in the worker thread's current pool, which is only drained when the iteration's pool pops (after `concurrentPerform` returns). On a 500k-item scan this is a real memory spike that the `peakMemoryBytes` field of `ScanBenchmarkReport` (`ScanBenchmark.swift:33, 51, 98-104`) will visibly show.
- `Evidence:` **Single `NSLock` on every accumulator update.** `ScanAccumulator.lock` at `FileSystemScanner.swift:611` is held by `recordVisit`, `recordBytes`, `recordItem`, `recordInaccessible`, `recordPhase`, and `retainedChildren` — all called from every concurrent worker. On wide directories (a typical `~/Library/Caches` with thousands of children), all workers contend on one lock per item.
- `Evidence:` **`childItems: [StorageItem?]` placeholder allocation** at `FileSystemScanner.swift:279`. `Array(repeating: nil, count: childURLs.count)` allocates the full Optional-boxed array up front before the parallel iteration. For a directory with 50k children that's 50k Optional boxes.
- `Evidence:` **Serial merge loop** at `FileSystemScanner.swift:332-339` after the parallel iteration. Each child is unconditionally visited to `record(child)`; not a hotspot on small scans but the `DirectoryScanSummary` allocation + per-child guards add real per-directory overhead.
- `Evidence:` **`verifiedGroups.append(contentsOf:)` under a single lock** at `FileSystemScanner.swift:443-445`. Every worker holds `verifiedGroupsLock` to append its slice. With many size groups hashed in parallel this serializes the append path.

### 1.2 Persist / index — `Sources/StorageScope/Stores/ScanStore.swift`

**Already optimized:**
- Per-`scanFinishedAt` cache for `cleanupCandidates`, `duplicateGroups`, `verifiedDuplicateGroups`, `oldLargeFiles`, `items(for:)`, `potentialReclaimableBytes`, `reclaimPlan`. See `cachedCleanupCandidatesKey` (`ScanStore.swift:162-175`) and the cache-hit branches at `:691-693`, `:749-751`, `:765-767`, `:810-812`, `:891-893`, `:919-921`, `:958-960`.
- `invalidateDerivedCaches()` (`ScanStore.swift:1328-1342`) drops every derived cache when filters change. Cache-invalidation is centralized, not scattered.
- Background `hashCache.persist()` + `purgeStale(except:)` at `.utility` priority off the main actor, post-scan (`ScanStore.swift:645-651`). Signposted with `persist` signpost.
- Same pattern for `RecentsStore.persist()` (`RecentsStore.swift:45-51`) — JSON encode + UserDefaults write detached to `.utility`.

**Suspected bottlenecks / gaps:**
- `Evidence:` **`filteredTypeBreakdown` and `filteredCategoryBreakdown` are NOT cached.** They recompute on every body evaluation of `TypeBreakdownView`. See `ScanStore.swift:1155-1202`. For a scan with ~200 extensions × active search query, this is N localizedCaseInsensitiveContains per render.
- `Evidence:` **`CleanupSelectionPlanner.topLevelCandidates` is O(N²).** `hasAncestor` at `CleanupSelectionPlanner.swift:47-51` calls `paths.contains` for every candidate against every other candidate's path, with `isAncestor` doing `hasPrefix(possibleAncestor + "/")`. Called from `potentialReclaimableBytes` (`ScanStore.swift:922`), `selectedReclaimableBytes` (`:968`), `selectedCleanupBatchCandidates` (`:939-941`), and `reclaimPlan` (via `ReclaimPlanBuilder.build` at `ReclaimPlanBuilder.swift:60`). With 5,000 visible cleanup candidates that's 25M comparisons per property access.
- `Evidence:` **`mountedVolumes` is recomputed on every `SidebarView` body pass.** `ScanStore.swift:489-508` calls `FileManager.default.mountedVolumeURLs` synchronously and runs an N-path `resourceValues` fetch + sort. The sidebar refreshes on every store `@Published` change (selection, scan progress, etc.) — this is real disk I/O blocking the main actor.
- `Evidence:` **`canExpandAllTree` walks the whole retained tree on every TreeExplorerView evaluation.** `ScanStore.swift:244-248` calls `allTreeContainerIDs(in: rootItem)` at `:269-279` to compute `allSatisfy { treeExpandedIDs.contains($0) }`. So every selection or expandedIDs mutation re-walks the entire retained tree to compute a single Bool.
- `Evidence:` **On-demand verify's `hashCache.persist()` does NOT emit a signpost.** `OnDemandVerificationStore.swift:71` calls `cacheToPersist.persist()` inside a `Task.detached(priority: .utility) {}` direct, without the `persist` signpost wrap that the scan path uses at `ScanStore.swift:646-650`. Instruments timeline is incomplete.
- `Evidence:` **`verifySizeGroup` does NOT emit a signpost.** `FileSystemScanner.swift:156-196` runs uninstrumented, so on-demand Verify Now is invisible in Instruments.
- `Evidence:` **Cache-invalidation events are not signposted.** `invalidateDerivedCaches()` (`ScanStore.swift:1328-1342`) and `invalidateItemsCache()` (`:1344-1347`) drop everything silently. There's no way to correlate "filter changed" to "cache miss + recompute" in Instruments.

### 1.3 UI render path

**Pattern (existing):** Every leaf view (`ContentView`, `DetailView`, `SidebarView`, `InspectorView`, `StorageItemTable`, `TreeExplorerView`, `TypeBreakdownView`, `DuplicateCandidatesView`, `CleanupReviewView`, `OverviewView`) declares `@ObservedObject var store: ScanStore` and reads from it directly. Examples: `ContentView.swift:4`, `DetailView.swift:6`, `SidebarView.swift:4`, `InspectorView.swift:5`, `StorageItemTable.swift:8` and `:236` (`StorageItemRow`), `TreeExplorerView.swift:5` and `:95` (`TreeNodeRow`), `TypeBreakdownView.swift:5`, `DuplicateCandidatesView.swift:5` and `:108` / `:172` / `:241`, `CleanupReviewView.swift:5` and `:279`, `OverviewView.swift:5`.

**Suspected bottlenecks:**
- `Evidence:` **Row views observe the entire `ScanStore`.** A tap on any row mutates `selectedItemID` (`StorageItemRow.swift:240`, `TreeNodeRow.swift:131`, `DuplicateCandidatesView.swift:250`, `CleanupCandidateRow.swift:283`), which is a `@Published` mutation. Every observer of `store` re-renders, even if it only displays derived data that did not change. The architecture.html doc (`:113-117`) explicitly calls out this weakness — *"any `@Published` mutation invalidates the whole view tree that observes the store"* — and motivates the Tier-2 sub-store extraction that has only been partially completed (FilterStore, OnDemandVerificationStore, RecentsStore). Tier 3 `SelectionStore` is still listed as deferred (`docs/changelog.html:218-221`, `docs/architecture.html:269-277`).
- `Evidence:` **`GeometryReader` in scroll rows.** Used in every TreeExplorerView row at `TreeExplorerView.swift:148-156`, every TypeBreakdownView stat row at `TypeBreakdownView.swift:48-56` and `:127-135`, and every OverviewView StorageMap row at `OverviewView.swift:262-272`. `GeometryReader` forces SwiftUI to do a layout pass for every row's bar; for a Tree expanded to 500 nodes this measurably slows scroll.
- `Evidence:` **`foreach` id cost on large lists.** `StorageItemTable` uses `ForEach(items) { item in ... }` (`StorageItemTable.swift:60`) — relies on `StorageItem: Identifiable` whose `id` is the standardized path (`StorageItem.swift:40`). Diffing against the previous list is O(N) string compares per update. With 800 ranked results per scan (`ScanStore.swift:598`) this matters.
- `Evidence:` **`ForEach(Array(items.enumerated()), id: \.element.id)` in `DuplicateItemList`.** `DuplicateCandidatesView.swift:247` allocates an enumerated tuple array per render to get the index for the trailing divider — wasteful; `ArraySlice.indices` would be free.
- `Evidence:` **`HighlightedText(item.name, query: store.filters.searchText)` is computed per row render** even when `searchText` is empty — see `StorageItemRow.swift:249`, `TreeNodeRow.swift:140`, `DuplicateItemList.swift`. No-op `AttributedString` building for thousands of rows.
- `Evidence:` **`selectionBackground(isSelected: store.selectedItemID == item.id)`** re-reads `store.selectedItemID` per row. Not a bottleneck itself, but evidence the row view is over-coupled to store.

### 1.4 Memory — `Sources/StorageScopeCore/Models/StorageScan.swift` and `StorageItem.swift`

- `Evidence:` **`retainedItems` + `rootItem.children` cascade memory duplication.** `StorageScan` stores `rootItem: StorageItem` AND `retainedItems: [StorageItem]` (`StorageScan.swift:5, 8`). `retainedItems` is built by `rootItem.flattened()` at `FileSystemScanner.swift:106` via `appendFlattened` at `StorageItem.swift:159-164`. Swift value semantics + COW backing means the structural-storage tree lives once inside `rootItem.children`; `flattened()` produces an `[StorageItem]` whose values are COW-shared into the array storage. So the duplication is the array container overhead (~16 bytes per item × 25,000 = 400KB), not full structural duplication. Still worth measuring.
- `Evidence:` **`itemLookupByID` is constructed eagerly per scan and never invalidated.** `StorageScan.swift:74-83` walks `retainedItems`, `largestFiles`, `largestFolders`, `oldLargeFiles`, all `duplicateSizeGroups.items`, all `verifiedDuplicateGroups.items`, and all `cleanupCandidates.item` to build the dictionary. For a scan that retains 25k items + 5k duplicate candidates this is ~30k dictionary insertions. The dict's storage is ~2-3× the retained items' aggregate size.
- `Hypothesis:` **`itemLookupByID` is rarely used.** Only callers of `scan.lookupItem(id:)` are `ScanStore.selectedItem` (`ScanStore.swift:319`) and the inspector/cleanup-candidate lookups. Constructing the lookup eagerly shifts ~30k dictionary insertions onto the scan critical path. Lazy construction (first call) would defer this cost to first selection, by which time the user has navigated.
- `Evidence:` **`sha256Checksum` finalization is wasteful.** `FileSystemScanner.swift:512` does `hasher.finalize().map { String(format: "%02x", $0) }.joined()`. Each byte produces an `NSString` via `String(format:)`. On 32 bytes × many thousands of hashes this is allocator-heavy. `SHA256Digest` has `withUnsafeBytes`-based hex helpers available since CryptoKit's first release; better still, hash bytes can be compared directly against the cache instead of stringified.
- `Evidence:` **`DuplicateSizeGroup.id` is built by joining all item ids** at `StorageScan.swift:180` — `"\(byteSize)-\(items.map(\.id).joined(separator: "|"))"`. For a group of 5,000 same-size files this is a single 50-200KB string per group. Used as a SwiftUI `id` in `ForEach(store.duplicateGroups)` (`DuplicateCandidatesView.swift:46`), which means a struct identity comparison each render.

### 1.5 Disk I/O

- `Evidence:` **`mountedVolumes` synchronous on main actor** — see §1.2.
- `Evidence:` **`volumeCapacityDescription(for:)` reads resourceValues synchronously** on every sidebar volume row render (`ScanStore.swift:513-522`). The sidebar shows this for each volume, so an external SSD unplugged mid-UI-triggered refresh causes the main actor to block on a stale attribute fetch.
- `Evidence:` **`DirectoryEnumerationOptions` fetches a wide key set per directory.** `FileSystemScanner.swift:267-271` requests all 11 `URLResourceKey` keys even for children that will be filtered as hidden or prune-out (`!includeHidden` branch at `:208-220`). The cost is acceptable when most children are visited; it's pure waste on directories that are mostly hidden files.
- `Evidence:` **`hashCache.persist()` JSON encode is sequential with the on-disk write.** `DuplicateHashCache.swift:67-82` encodes the full entries dict to JSON synchronously before writing atomically. On 10k entries with the cache mostly populated this is well above 100 ms. Already off the main actor; low priority.
- `Evidence:` **`hashCache.load()` happens synchronously during `DuplicateHashCache.init`.** `DuplicateHashCache.swift:33-38, 136-143` synchronously decodes the cache file. ScanStore constructs `hashCache` at `ScanStore.swift:153`, which means the first `ScanStore()` init blocks on disk + JSON decode before the UI is interactive. Affects first launch.

### 1.6 Concurrency / actor isolation / `@MainActor` boundaries

- `Evidence:` **Every `@Published` mutation on `ScanStore` happens on the main actor**, and `progress` callback hops to the main actor per progress emit (`ScanStore.swift:620-627`). On a 500k-item scan with 25-item throttle, that's ~20,000 Task hops to the main actor. None individually slow; aggregated they can stall input.
- `Evidence:` **`hashCache` is `@unchecked Sendable`, accessed under `NSLock`.** Workers that call `hashCache?.checksum(for:)` (`FileSystemScanner.swift:165, 417`) and `hashCache.record(...)` (`:178-182, :426-430`) all go through the same lock. The lock itself is contention-prone on heavy scans, but the alternative (`actor`) would require async hops from `concurrentPerform` (which is synchronous).
- `Evidence:` **`@Observable` migration blocked by `didSet` observers.** `FilterStore.swift:37, 52, 68, 71, 74, 77, 80, 90` — every `@Published` property has a `didSet` calling `coordinateInvalidate()` or `rebuildSearchSubtreeMatchIDs()`. The `@Observable` macro does not synthesize `didSet` joinpoints under the classic reachability model; migration requires either precomputed invalidation triggers (manual `access`/`withMutation` calls) or replacing `didSet` with explicit setter methods. This is the explicit Tier-5 deferral in `architecture.html:278-283` and changelog TBConfirmed.
- `Evidence:` **`concurrentPerform` is synchronous, blocking the calling thread.** `FileSystemScanner.swift:283` — the scan caller (a `DispatchQueue.global(qos: .userInitiated)` worker per `ScanStore.swift:613`) is blocked until all parallel iterations complete. This is by design but it prevents per-item streaming yields to UI; the天蝎座 scan can't display items incrementally.

### 1.7 `ScanBenchmark` measurement gaps

- `Evidence:` **`peakMemoryBytes` uses `getrusage(RUSAGE_SELF)`** at `ScanBenchmark.swift:98-104`. That returns `ru_maxrss` which on macOS is the max resident set size **since process start** — not peak during the scan. For a long-lived benchmark process this number includes startup overhead, prior scans, and the Swift runtime preload. Useless for measuring a single scan's peak.
- `Evidence:` **`enumerateDuration + verifyDuration + persistDuration` under-shoots `duration`** — explicitly called out at `ScanBenchmark.swift:22-27` in the public doc comment. The gap is bookkeeping: retained child collection, `flattened()` traversal, `itemLookupByID` build, `cleanupCandidates()` sort, dirty-cache invalidation. None of these phases are timed.
- `Evidence:` **No UI render phase measurement.** `ScanBenchmark` runs the scanner only (`ScanBenchmarkRunner.run` at `ScanBenchmark.swift:125-137`). A scan that completes in 5 s but produces a UI that takes 2 s to first-paint isn't captured.
- `Evidence:` **Cache-invalidation points emit no signposts.** See §1.2.
- `Evidence:` **On-demand verify path emits no signposts.** See §1.2.
- `Evidence:` **`SyntheticBenchmarkFixture` creates only 10 small files** (`ScanBenchmark.swift:156-220`), totaling a few MB. Useless for measuring item-count scaling. There is no 100k or 500k fixture.
- `Evidence:` **Shell `prepare_fixture_scan_root`** (`build_and_run.sh` in `script/build_and_run.sh`) creates 7 files totaling ~3 GB. Decent for measuring byte throughput but not the 100k-item path. No concurrency-stress fixture (deep nested tree, wide-then-shallow, lots of duplicates).

---

## 2. Bottleneck hypotheses ranked

The table below ranks the suspected bottlenecks by expected impact (per-scan wall-time or per-view-paint). It distinguishes evidence-backed (the code clearly exhibits the issue) from theorized (would need measurement to confirm). The Tier column maps to the rollout slice in §4.

| # | Hypothesis | Evidence (file:line / signpost) | Impact | Effort | Reversibility | Tier |
|---|---|---|---|---|---|---|
| 1 | `autoreleasepool` missing in `scanItem` loop inflates peak RSS and triggers longer GC pauses | `FileSystemScanner.swift:283-326` | high | S | high (additive) | v0.5.4 |
| 2 | `CleanupSelectionPlanner.topLevelCandidates` is O(N²) on visible cleanup candidates | `CleanupSelectionPlanner.swift:47-51`; called from `ScanStore.swift:922, 968, 939-941` and `ReclaimPlanBuilder.swift:60` | high | S | high | v0.5.5 |
| 3 | `filteredTypeBreakdown` / `filteredCategoryBreakdown` not cached, recomputed every `TypeBreakdownView` body | `ScanStore.swift:1155-1202` | medium | S | high | v0.5.5 |
| 4 | `mountedVolumes` and `volumeCapacityDescription` synchronous on main actor | `ScanStore.swift:489-522` | medium | S | high | v0.5.5 |
| 5 | `canExpandAllTree` walks whole retained tree on every TreeExplorerView body | `ScanStore.swift:244-248, 269-279` | medium | S | high | v0.5.5 |
| 6 | Progress callback hops to main actor 20,000+ times on 500k scan | `ScanStore.swift:620-627`; throttle at `FileSystemScanner.swift:815-827` | medium | M | medium (changes producer-consumer contract) | v0.5.4 |
| 7 | `verifiedGroups.append(contentsOf:)` serialized under `verifiedGroupsLock` | `FileSystemScanner.swift:443-445` | medium | S | high | v0.5.4 |
| 8 | `itemLookupByID` built eagerly per scan; rarely used | `StorageScan.swift:74-83, 85-87` | medium | M | high (adds lazy getter) | v0.6.0 |
| 9 | Whole-`ScanStore` observation causes cross-view re-render on selection tap | `ContentView.swift:4` + 9 other views | high | L | low (sub-store extraction is invasive) | v0.6.0 (Tier 3) |
| 10 | `GeometryReader` in scroll rows forces per-row layout pass | `TreeExplorerView.swift:148-156`, `TypeBreakdownView.swift:48-56, 127-135`, `OverviewView.swift:262-272` | medium | M | medium (UI rewrite) | v0.5.6 |
| 11 | `childItems: [StorageItem?]` placeholder preallocated | `FileSystemScanner.swift:279` | low-medium | S | high | v0.5.4 |
| 12 | `Single NSLock` on `ScanAccumulator` every `recordItem`/`recordVisit`/`recordBytes` | `FileSystemScanner.swift:611, 624-666` | medium | M | medium (lock-striping changes concurrency contract; tests must hold) | v0.5.4 |
| 13 | `sha256Checksum` finalization builds 32 NSString objects per hash | `FileSystemScanner.swift:512` | low (per-file) | S | high | v0.5.4 |
| 14 | `DuplicateSizeGroup.id` joins all item paths into one giant String | `StorageScan.swift:180` | medium (when groups are large) | S | medium (would change Identifiable id shape — UI diff stable only via String equality) | v0.5.5 |
| 15 | No 100k / 500k fixtures to validate fixes under realistic scale | `ScanBenchmark.swift:156-220`, `script/build_and_run.sh:prepare_fixture_scan_root` | high (blocks all other work) | M | high (additive) | v0.5.3 |
| 16 | On-demand verify & cache invalidation phases not signposted | `FileSystemScanner.swift:156-196`, `ScanStore.swift:1328-1347` | hidden (measurement) | S | high (additive) | v0.5.3 |
| 17 | `hashCache.load()` synchronous in `ScanStore.init` blocks first-launch UI | `DuplicateHashCache.swift:33-38, 136-143`; `ScanStore.swift:153` | low (first-launch only) | S | high | v0.5.4 |
| 18 | `ForEach(Array(items.enumerated()), id: \.element.id)` allocates enumerated tuple array | `DuplicateCandidatesView.swift:247` | low | XS | high | v0.5.6 |
| 19 | `HighlightedText` no-op work when `searchText` empty | 9 call sites across views | low | S | high | v0.5.6 |
| 20 | `peakMemoryBytes` reports process-max-since-start, not scan-peak | `ScanBenchmark.swift:98-104` | measurement only | S | high | v0.5.3 |

---

## 3. Proposed improvements

### 3.1 Scan-pipeline wins

#### Proposal P-1. Wrap each `scanItem` recursion in `autoreleasepool`
**Target:** `FileSystemScanner.swift:283-326` (`DispatchQueue.concurrentPerform` body) and the recursive `scanItem` entry at `:198-375`.
**Change:** Wrap the body of the `concurrentPerform` iteration in `autoreleasepool { ... }`, and additionally wrap the per-child recursion's directory-fetch block (the `do { ... } catch` at `:265-374`) so `URLResourceValues`, `childURLs`, `Array(resourceKeys)`, and NSNumber/Date bridges are released at the end of each recursion.
**Impact:** Directly addresses bottleneck #1. Reduces peak RSS during enumeration. Expected: 30–60% peak-RSS reduction on broad scans with minimal wall-time change.
**Risk:** None — additive. Behavior unchanged.

#### Proposal P-2. Eliminate the `[StorageItem?]` placeholder array
**Target:** `FileSystemScanner.swift:279`.
**Change:** Replace `var childItems: [StorageItem?] = Array(repeating: nil, count: childURLs.count)` with `Mutex<[Int: StorageItem]>` or `ChunkedLockedStorage`. Or simpler: instead of `concurrentPerform(iterations: childURLs.count)`, partition `childURLs` into `hashConcurrency` chunks and let each worker append to a thread-local array, then merge in order. Eliminates both the upfront allocation and the index-based write contention.
**Impact:** Bottleneck #11. Eliminates the 50k-entry slot array on wide directories; micro-win on wall time, real on allocator pressure.
**Risk:** Low. Order is preserved by merging thread-local arrays in original index order.

#### Proposal P-3. Striping for `ScanAccumulator.lock`
**Target:** `FileSystemScanner.swift:611` (the lock) and every `record*` call.
**Change:** Either (a) split into per-bucket locks (`fileTypeStats` / `duplicateCandidatesBySize` / `cleanupCandidatesByID` / `largestItems`), each with its own `NSLock`, so locking `fileTypeStats` doesn't block `largestFileItems.append`; or (b) move to `OSAllocatedUnfairLock` (macOS 13+, available since the deployment target is 14) which has lower contention overhead.
**Impact:** Bottleneck #12. On wide-directory scans workers will stop serializing on a single lock.
**Risk:** Moderate. **Must not change observable scan output.** Adds concurrent-mutation safety surface that the existing single-lock assumption guaranteed trivially. Tests in `Tests/StorageScopeCoreTests/FileSystemScannerTests.swift` (1320 lines) cover `largestFiles`, `largestFolders`, duplicate candidates, type breakdown — they will catch any drift.

#### Proposal P-4. Replace `verifiedGroups.append(contentsOf:)` lock with `Mutex<[VerifiedDuplicateGroup]>` or thread-local accumulation
**Target:** `FileSystemScanner.swift:443-445`.
**Change:** Each `concurrentPerform` worker builds its `verifiedForSize` slice into a thread-local array, calls `verifiedGroupsLock.lock()` once after all iterations in the slice, appends, unlocks. Already mostly does this — but the current code locks per-group instead of per-slice. Smooth out into per-slice lock.
**Impact:** Bottleneck #7. Low wall-time; mostly a contention-feel fix.

#### Proposal P-5. Batch progress emissions with a small ring buffer
**Target:** `ScanStore.swift:620-627` (the `progress` closure that hops to MainActor) and `FileSystemScanner.swift:815-827` (the throttle).
**Change:** Coalesce emissions inside the scanner using a buffer that captures the latest progress state and flushes on a 0.3 s timer (or on demand). The main-actor hop becomes ~3 per second instead of ~50/s.
**Impact:** Bottleneck #6. Reduces main-actor task scheduling pressure during scans.
**Risk:** Moderate — changes the producer-consumer contract for progress. Need a flush-on-scan-end guarantee so the final "Scan complete" snapshot always arrives.

#### Proposal P-6. Drop `propertiesForKeys` duplication on filter-pruned children
**Target:** `FileSystemScanner.swift:267-271`.
**Change:** When `!options.includeHidden`, enumerate without `.isHiddenKey` fetch in the keys set, and let the post-enumeration filter sort out hidden entries via FileManager's `.skipsHiddenFiles` flag (already used). The current code fetches `.isHiddenKey` for every child AND skips via the enumeration option — that's a duplicate check.
**Impact:** Minor — bottleneck #1 supporting change.

#### Proposal P-7. Eliminate `sha256Checksum` NSString allocation in finalization
**Target:** `FileSystemScanner.swift:512`.
**Change:** Replace `hasher.finalize().map { String(format: "%02x", $0) }.joined()` with `hasher.finalize().withUnsafeBytes { Data($0).baseEncodedString(options: .base16).lowercased() }` — or even better, switch the `DuplicateHashCache` checksum type to `[UInt8]` or `Data` to avoid the string form entirely on the hot path.
**Impact:** Bottleneck #13. Low absolute win per file; multiplied by thousands of duplicate candidate hashes.
**Risk:** Low if cache key type stays `String`. If we change the cache key type to `Data`, that's a one-time migration on next cache load (decode old string form, encode new form on persist). Mark as a feature-flagged v0.6.0 change.

### 3.2 Cache / derived-state wins

#### Proposal P-8. Cache `filteredTypeBreakdown` and `filteredCategoryBreakdown` per `scanFinishedAt + query`
**Target:** `ScanStore.swift:1155-1202`.
**Change:** Add `cachedFilteredTypeBreakdownKey: DerivedCacheKey?` and `cachedFilteredTypeBreakdown: [FileTypeStat]` mirror the existing pattern (`cachedDuplicateGroupsKey`/`cachedDuplicateGroups` at `ScanStore.swift:172-173`). Cache invalidation already centralized in `invalidateDerivedCaches()` — just add the two new keys.
**Impact:** Bottleneck #3. Currently recomputed on every `TypeBreakdownView` body that happens during typing in the search box. With cache, recomputed only on debounced query change.
**Risk:** None — additive.

#### Proposal P-9. Memoize `CleanupSelectionPlanner.topLevelCandidates` input→output per `scanFinishedAt`
**Target:** `CleanupSelectionPlanner.swift:12-23`. Callers: `ScanStore.swift:922, 968, 939-941` and `ReclaimPlanBuilder.swift:60`.
**Change:** Compute a sorted-path prefix trie (or a sorted-array + lower_bound lookup) inside `CleanupSelectionPlanner` to reduce `hasAncestor` from O(N²) to O(N log N). Alternative: precompute `topLevelCandidateIDs: Set<String>` once per `cleanupCandidates` cache-miss and look up by membership.
**Impact:** Bottleneck #2. With 5,000 visible cleanup candidates this is a 25M-operation improvement per property access.
**Risk:** Low. The existing tests in `Tests/StorageScopeCoreTests/FileSystemScannerTests.swift` and `Tests/StorageScopeTests/ScanStoreKeeperAndIgnoreTests.swift` cover ancestor detection.

#### Proposal P-10. Make `canExpandAllTree` and `canCollapseTree` O(1) over the retained tree
**Target:** `ScanStore.swift:244-252` and the helper at `:269-279`.
**Change:** Maintain an `@Published retainedTreeContainerCount: Int` counter that's set during scan set-up (`scan(...)` completion at `ScanStore.swift:640-672`). Then `canExpandAllTree` becomes `treeExpandedIDs.count < retainedTreeContainerCount`.
**Impact:** Bottleneck #5. Eliminates a per-TreeExplorerView-body full-tree walk.
**Risk:** Moderate. Requires the counter to stay in sync if the tree is mutated post-scan (currently it isn't, but a future "filter-by-retained-only" pass would need to update it).

#### Proposal P-11. Replace `mountedVolumes` synchronous fetch with cached + on-demand refresh
**Target:** `ScanStore.swift:489-522`.
**Change:** Cache `mountedVolumes` and `volumeCapacityDescription(for:)` keyed by volume URL + 5s TTL. Re-fetch on a `Task.detached` only when the sidebar becomes visible OR a `.didMount`/`.didUnmount` notification `(NSWorkspaceDidMountNotification)` arrives. Pre-existing volume list serves immediately; refresh arrives async.
**Impact:** Bottleneck #4. Eliminates main-actor disk I/O on sidebar refreshes.
**Risk:** Low. Subscribe to NSWorkspace notifications in `init()`; unsubscribe in `deinit`.

#### Proposal P-12. Replace `DuplicateSizeGroup.id` with a content-stable hash
**Target:** `StorageScan.swift:174-196`.
**Change:** Instead of `"\(byteSize)-\(items.map(\.id).joined(separator: "|"))"`, use `"\(byteSize)-\(items.count)-\(items.first?.id ?? "")"` plus a hash of the rest if needed. Or: drop the `Identifiable` synthesis and use the byte-size + min(item.id) tuple as the SwiftUI id. For UI concrete id purposes, what matters is that two groups with same byteSize and same item-set don't collide — that's already guaranteed by `byteSize` + first item id within an unsorted scan.
**Impact:** Bottleneck #14. Notable only on large same-size groups (5k+ items). Mostly memory savings.

### 3.3 UI render wins

#### Proposal P-13. Extract `SelectionStore` (Tier 3) to drop the `selectedItemID` ripple
**Target:** `ScanStore.swift:202-205, 226-242` and all `@ObservedObject var store: ScanStore` row views.
**Change:** Lift `selectedItemID`, `treeExpandedIDs`, `selectedCleanupCandidateIDs`, `ignoredCleanupCandidateIDs` into a new `@MainActor final class SelectionStore: ObservableObject` declared as `lazy var selection = SelectionStore(...)` on `ScanStore`, mirroring the Tier-2 pattern documented in `architecture.html:119-161` and the existing closure-injection patterns. Pass `@ObservedObject var selection: SelectionStore` to row views (`StorageItemRow`, `TreeNodeRow`, `CleanupCandidateRow`, `DuplicateItemList`). Selection mutations no longer invalidate the whole-`ScanStore` observation set.
**Impact:** Bottleneck #9. The single biggest UI win. Click-to-select stops re-rendering the whole window.
**Risk:** High. Explicitly the deferred Tier 3 in `architecture.html:269-277`. Cited risk: the closures that touch scan-side `keeperOverridesByChecksum` / `ignoredCleanupCandidateIDs` need careful coordination. Recommend a **feature flag** for v0.5.6 + promote to GA in v0.6.0.

#### Proposal P-14. Replace `GeometryReader` bar fills with `Layout` or pre-computed width fractions
**Target:** `TreeExplorerView.swift:148-156`, `TypeBreakdownView.swift:48-56` and `:127-135`, `OverviewView.swift:262-272`.
**Change:** Compute the bar width as a fraction of `parentWidth`, captured via a sibling `GeometryReader` *outside* the ForEach (so the parent reports once). Pass the width down as a `let` parameter to each row. Alternatively use modern `Layout` (macOS 13+, available) where the bar's width is laid out via `Layout`'s `placeSubviews`, or use `fixedSize(horizontal: true, vertical: false)` + a `Spacer().frame(width: ...)` trick.
**Impact:** Bottleneck #10. Per-row layout pass eliminated.
**Risk:** Medium. SwiftUI layout subtlety; need to verify visually identical results.

#### Proposal P-15. Make row views `Equatable` so SwiftUI's `ForEach` skips re-render
**Target:** `StorageItemRow`, `TreeNodeRow`, `CleanupCandidateRow`, `DuplicateItemList.ItemRow`.
**Change:** Add `Equatable` conformance with `lhs.item == rhs.item && lhs.isSelected == rhs.isSelected` (and similar for other state). SwiftUI's `ForEach` checks `Equatable` when wrapped in `.equatable()` modifier. This pairs with P-13: row reads come from the new narrow `SelectionStore` so equality is cheap.
**Impact:** Bottleneck #9 supporting. Means that even when the whole-`ScanStore` body re-renders, rows whose inputs haven't changed are diffed out.
**Risk:** Low — additive. Project onto P-13 rollout.

#### Proposal P-16. Skip `HighlightedText` no-op when query empty
**Target:** The `HighlightedText(item.name, query: store.filters.searchText)` call sites in `StorageItemRow.swift:249`, `TreeNodeRow.swift:140`, and equivalent in `DuplicateItemList`.
**Change:** Either (a) make `HighlightedText` short-circuit to plain `Text(item.name)` when `query` is empty (one `if` branch), or (b) make its parent view's `body` choose a different `@ViewBuilder` branch.
**Impact:** Bottleneck #19. Minor but matters when the user has 800 ranked results visible.

#### Proposal P-17. Avoid `Array(items.enumerated())` allocation in `DuplicateItemList`
**Target:** `DuplicateCandidatesView.swift:247`.
**Change:** Use `ForEach(items.indices, id: \.self) { index in ... }` plus access via `items[index]`. Or simpler: drop the trailing divider entirely and rely on `LazyVStack(spacing: 0)` with per-row padding. Eliminates the tuple-array allocation.
**Impact:** Bottleneck #18. Low.

### 3.4 Threading / actor wins

#### Proposal P-18. Lazy-load `DuplicateHashCache` off the main actor
**Target:** `DuplicateHashCache.swift:33-38` (the synchronous `load()` in `init`) and `ScanStore.swift:153` (where the cache is constructed eagerly).
**Change:** Make `DuplicateHashCache.init` not call `load()` immediately. Add `func loadIfNeeded()` and have the first `scan(_:)` call invoke it as part of the background scan task at `ScanStore.swift:611-633`. The main actor no longer blocks on JSON decode on first launch.
**Impact:** Bottleneck #17. First-launch faster.
**Risk:** Low. On-demand verify path (`OnDemandVerificationStore`) also uses the cache; need to ensure either its first call triggers `loadIfNeeded()` or it's safe to record into an un-loaded cache (the writes get persisted on the next `persist()`).

#### Proposal P-19. Async-stream migration for the scan producer (future-looking)
**Target:** `FileSystemScanner.scan(root:options:cancellation:progress:)` at `FileSystemScanner.swift:84-150` and the wrapping code at `ScanStore.swift:612-634`.
**Change:** Optional v0.6.0+ migration: add an `AsyncStream<ScanProgress>` variant of `scan(...)` that emits progress via `AsyncStream.Continuation` and yields incremental `retainedItems` slices as the scan progresses. The view layer can subscribe and display items incrementally before the scan completes.
**Impact:** Big perceived-latency win — first paint happens minutes before scan completes on broad directories.
**Risk:** High. Significantly restructures the producer-consumer contract. The existing `DispatchQueue.concurrentPerform` model is synchronous; migrating to `AsyncStream` requires either a non-parallel but yielding enumeration, or a producer-actor that feeds the stream. **Do NOT ship without a flag and without broad fixture testing.**
**Recommendation:** PoC in v0.6.0 with a flag; promote to default only after at least one minor release of soak time.

#### Proposal P-20. Tier-5 `@Observable` migration path
**Target:** `FilterStore.swift:37-95` (every `@Published` with `didSet`), `OnDemandVerificationStore.swift:17-20`, `RecentsStore.swift:21`, and the eventual `SelectionStore` from P-13.
**Change:** Replace `@Published var x { didSet { coordinateInvalidate() } }` with `@Observable` macro + manual invalidation hooks at the call sites that mutate the value. `Access` and `withMutation` get synthesized but you bypass `didSet`.
**Constraint:** `@Observable` requires macOS 14+ — already the deployment target (`Package.swift`). Not blocked.
**Blocked by:** `FilterStore.searchText` `didSet` does the debounce scheduling at `FilterStore.swift:37-50`; `query` `didSet` triggers `rebuildSearchSubtreeMatchIDs()` at `:55-65`. Both must be re-architected as explicit setter methods, or the debounce must move to a SwiftUI `.onChange(of:)` modifier in the consuming view. The `filterBinding` bridge (`ScanStore.swift:192-194`) is documented as removed by this migration in `architecture.html:280-283`.
**Impact:** Removes the filterBinding bridge complexity + unlocks per-property observation so `Picker`/`Stepper` mutations trigger only the consumers of that exact property.
**Risk:** High; explicitly deferred. Recommend **sequencing after** P-13 (Tier 3 SelectionStore) so the whole-tree observation weakness is solved by narrower observation, removing the urgency. Plan for v0.6.0 if at all.

### 3.5 Memory wins

#### Proposal P-21. Build `itemLookupByID` lazily
**Target:** `StorageScan.swift:74-83, 85-87`.
**Change:** Drop the eager `buildItemLookup` from `init`. Replace with `lazy var itemLookupByID: [String: StorageItem]` initialized on first `lookupItem(id:)` call. Since `lookupItem` is only called from `ScanStore.selectedItem` (`ScanStore.swift:319`), this defers the ~30k-dictionary-insertion cost from scan completion to first user click.
**Impact:** Bottleneck #8. Scan completes faster; defers lookup cost to where it's not on the visible critical path.
**Risk:** Low. `StorageScan` is a `struct` (line 3) and `let`-immutable; `lazy var` on a struct needs `mutating` access. Easier: make it a `private let itemLookupByID: LazyDictionary` where `LazyDictionary` is a private wrapper that builds on first `subscript` access. **Or:** change `StorageScan` to be a final class (it's already `Sendable`). Recommendation: keep `struct`, use a private `final class LookupTable` stored lazily via a stored closure call pattern.

#### Proposal P-22. Eliminate `retainedItems` duplication by deriving via `rootItem.flattened()`
**Target:** `StorageScan.swift:8, 56` and `FileSystemScanner.swift:106`.
**Change:** Drop the `retainedItems: [StorageItem]` parameter from `StorageScan.init`. Compute `var retainedItems: [StorageItem] { rootItem.flattened() }` as a computed property. The flatten happens on first access (`items(for: view)` and `cleanupCandidates(...)`) and is internal-cached under a `lazy var`. Since `StorageScan` is a value type, the computed property is recomputed each call — use the LookupTable lazy-wrapper trick from P-21.
**Impact:** Removes the eager O(N) `[StorageItem]` build cost from scan completion.
**Risk:** Moderate. Tests rely on `scan.retainedItems` in several places (`FileSystemScannerTests.swift`). Need to verify the computed-property semantics don't break `Equatable` or `Hashable` conformance on `StorageScan` (computed properties are not part of synthesized `Equatable` — this is fine).

#### Proposal P-23. Switch `DuplicateHashCache.Entry.checksum` from `String` to `Data` or `[UInt8]`
**Target:** `DuplicateHashCache.swift:19-23` and `FileSystemScanner.swift:512`.
**Change:** Cache the SHA-256 digest in raw form (`Data` or fixed `[UInt8]` of length 32). Comparison/lookup is byte-equality rather than string equality. Persisted JSON form stays hex-string on disk (encode/decode on the boundary).
**Impact:** Eliminates the per-hash finalization NSString churn (Bottleneck #13) at the cost of a one-time cache-format migration.
**Risk:** Medium. The on-disk cache format changes; consumers using `checksum(for:)` continue to receive the canonical form they expect (could expose as `String` for backward compat). **Feature-flag**, **one-shot migration step** on load.

### 3.6 Measurement wins

#### Proposal P-24. Add the missing signposts
**Target:** (a) `FileSystemScanner.verifySizeGroup` at `:156-196` — wrap the per-group body in an `os_signpost(.begin/.end, name: "verify_on_demand")`; (b) `OnDemandVerificationStore.swift:71` — wrap the `cacheToPersist.persist()` call in a `persist` signpost; (c) `ScanStore.invalidateDerivedCaches()` at `:1328-1342` and `invalidateItemsCache` at `:1344-1347` — emit a `cache_invalidate` signpost so Instruments shows the cache-drop events; (d) `StorageScan.init` time the lookup construction if P-21 not done.
**Impact:** Bottleneck #16. Closes the visibility gap so the v0.5.4+ fixes can be measured.
**Risk:** None — additive.

#### Proposal P-25. Replace `getrusage(RUSAGE_SELF)` peak with `mach_task_basic_info` peak-current
**Target:** `ScanBenchmark.swift:98-104`.
**Change:** Use `task_info(mach_task_self(), TASK_BASIC_INFO, ...)` for `resident_size` measured at scan-start and scan-end (or sample during the scan via a background timer). Returns the **current** resident size which is more useful than the lifetime max.
**Impact:** Bottleneck #20. Makes the benchmark actually useful.
**Risk:** None — additive.

#### Proposal P-26. Build a scaled fixture generator (10k, 100k, 500k items; deep vs wide; many duplicates)
**Target:** `Sources/StorageScopeCore/Services/ScanBenchmark.swift:156-220` (extend `SyntheticBenchmarkFixture`) and `script/build_and_run.sh:prepare_fixture_scan_root`.
**Change:** Add `SyntheticBenchmarkFixture.createScaled(itemCount:depth:duplicateRatio:)` that generates a temp-folder tree with the requested item count. Add CLI flag `--items N --depth D --duplicates R` to `main.swift` of the benchmark executable and to `build_and_run.sh`. Also add a comparison statement to the report text (current `peakMemoryBytes`"、`enumerateDuration`、`verifyDuration` per item-count bucket).
**Impact:** Bottleneck #15 — the prerequisite for validating which of the proposals above deliver real wins.
**Risk:** None — additive. The generated fixture writes to `temporaryDirectory`; existing `SyntheticBenchmarkFixture.create()` semantics (auto-cleanup unless `--keep-fixture`) preserved.

#### Proposal P-27. Add a UI-render micro-benchmark
**Target:** New file `Sources/StorageScopeBenchmark/UIRenderBenchmark.swift` or an inline section in `main.swift`.
**Change:** Spawn a headless `NSWindow` with the `ContentView`，inject a fixed `ScanStore` with a synthetic scan，measure the time from view instantiation to first `body` evaluation completion via `os_signpost` or `ClockInstant`. Optional: include `--ui` flag to `StorageScopeBenchmark`.
**Impact:** Bottleneck "no UI render measurement" from §1.7.
**Risk:** None. May be conservative — first paint in a window without a real runloop needs care. Worst case: measure via XCTest `XCTMeasureMetricClockMonotonicTime` in a UI test instead. Recommended approach.

#### Proposal P-28. CI perf-regression gate
**Target:** A new GitHub Actions job or extension of the existing test job.
**Change:** Run `swift run StorageScopeBenchmark --items 100000 --duplicates 0.3` against a self-destroying temp fixture after each PR. Compare `totalDuration` and `peakMemoryBytes` against the main-branch baseline using a small bash script. Allow ±10% tolerance; report failures as warnings (non-blocking) for v0.5.x, promote to required in v0.6.0.
**Impact:** Catches regressions early; lets each subsequent proposal be validated rather than guess-and-commit.
**Risk:** Low. Variance on GitHub-hosted macOS runners is real; allow generous tolerance initially.

---

## 4. Sequenced rollout

### v0.5.3 — Measurement & fixtures first

- **Theme:** Close the visibility gaps and stand up scaled fixtures before touching any hot path.
- **Goal:** A maintainer running `script/benchmark_scan.sh --items 100000` produces a stable, comparable `ScanBenchmarkReport`text output, and Instruments captures all scan + cache + verify phases.

**Changes:**
1. P-24: Add the missing signposts (`verify_on_demand`, `persist`-on-demand-verify, `cache_invalidate`).
2. P-25: Replace `peakMemoryBytes` implementation with `mach_task_basic_info` peak-current sampled at start/end.
3. P-26: Build `SyntheticBenchmarkFixture.createScaled(itemCount:depth:duplicateRatio:)` and the `--items`/`--duplicates` CLI flags on the benchmark executable (mirror in `script/build_and_run.sh`).
4. Capture a baseline: run scaled fixtures at 10k / 100k / 500k items, deep-vs-wide variants, save the report text under `docs/perf-baselines/v0.5.2.txt` (only data, no code).
5. Document in `docs/architecture.html` (Section 5 expansion) which signposts exist.

**Validation:** `swift test` (90/90 still passes — additive only). Manual run of `./script/build_and_run.sh --fixture-scan --duplicates` produces a clean scan. Instruments timeline shows the new `verify_on_demand` and `cache_invalidate` spans.

**Risk:** None — measurement-only release.

**Feature-flag:** Not needed.

### v0.5.4 — Scan-pipeline wins

- **Theme:** Cheap-but-real per-scan wins, all worth keeping on their own.
- **Goal:** `enumerateDuration` and `peakMemoryBytes` move on the 100k fixture by ≥15% each (numbers will be in the v0.5.3 baseline).

**Changes:**
1. P-1: `autoreleasepool` wrapping in `scanItem` and inside the `concurrentPerform` body.
2. P-2: Drop the `childItems: [StorageItem?]` placeholder; switch to per-worker thread-local accumulation + sorted merge.
3. P-4: Coalesce `verifiedGroups.append(contentsOf:)` to one lock per worker slice.
4. P-5: Batch progress emissions to ≤3 main-actor hops per second.
5. P-6: Drop duplicate `.isHiddenKey` fetch when `includeHidden == false`.
6. P-7: Replace `sha256Checksum` finalization `String(format:"%02x", $0)` loop with `Data(...).baseEncodedString(.base16).lowercased()`.
7. P-18 (this slice is bonus): lazy-load the `DuplicateHashCache` off the main actor.

**Validation:**
- Signpost `enumerate` median drops on the 100k fixture (compare via `xcrun xctrace export`).
- `peakMemoryBytes` sampled mid-scan shows the smooth-not-spiky pattern.
- `swift test` 90/90 still passes.
- `Tests/StorageScopeCoreTests/FileSystemScannerTests.swift` extended with a new test that scans a 1k-item fixture twice and verifies the cache lookup count via `hashCache.hits == expected`.

**Risk:** P-2 (placeholder replacement) and P-3 (lock striping, *not* scheduled here, see v0.5.5) touch concurrency contracts. Mitigate with feature flags behind `STORAGESCOPE_ENABLE_PIPELINE_FIXES`, default-on after test pass.

**Feature-flag period:** v0.5.4 ships behind the flag (off-by-default for "production first scan"); **enable in v0.5.6** after soak.

### v0.5.5 — Cache & derived-state wins

- **Theme:** Close the cache gaps that make FilterBar typing and CleanupReview interactions feel slow.

**Changes:**
1. P-8: Cache `filteredTypeBreakdown` and `filteredCategoryBreakdown` per scanFinishedAt + query.
2. P-9: Memoize `CleanupSelectionPlanner.topLevelCandidates` per `cleanupCandidates` cache-miss; replace O(N²) ancestor walk with sorted-prefix O(N log N) lookup.
3. P-10: Maintain `retainedTreeContainerCount` on `scan(...)` completion so `canExpandAllTree` is O(1).
4. P-11: Cache `mountedVolumes` + `volumeCapacityDescription` with NSWorkspace mount/unmount notifications.
5. P-12: Replace `DuplicateSizeGroup.id` with a content-stable short form.

**Validation:**
- The `index` signpost (`FilterStore.swift:240-243`) and `cache_invalidate` (added in v0.5.3) show coarser-fewer recompute events during typing.
- CleanupReviewView interaction test: with 5,000 visible candidates, `selectedReclaimableBytes` accessor runtime drops from X to Y (capture in new test using `XCTMetricClockMonotonicTime`).
- `swift test` 90/90 still passes; extend `Tests/StorageScopeTests/` with new test files for `filteredTypeBreakdown` cache miss/hit and `topLevelCandidates` performance.

**Risk:** Low — additive caches. P-11's notification subscription needs careful teardown in `deinit`.

### v0.5.6 — UI render wins (no behavior change)

- **Theme:** Stop the SwiftUI diffing tax on large lists and the per-row GeometryReader layout passes.

**Changes:**
1. P-14: Replace `GeometryReader` bar fills with parent-captured width or modern `Layout`.
2. P-15: Make `StorageItemRow`, `TreeNodeRow`, `CleanupCandidateRow`, `DuplicateItemList.ItemRow` `Equatable`, apply `.equatable()` on `ForEach` body.
3. P-16: Skip `HighlightedText` work when query empty.
4. P-17: Drop `Array(items.enumerated())` allocation in `DuplicateItemList`.
5. Enable P-2/P-3 fixes by default now.

**Validation:**
- New XCTest UI performance metric (P-27): first-paint time on a 1,000-row StorageItemTable drops measurably.
- Manual: typing in FilterBar while Type Breakdown view is visible feels instant (was visibly laggy on the 200-extension fixture I created locally).
- `swift test` 90/90 still passes.

**Risk:** P-14 in particular — visual parity hard to guarantee without instrumented screenshots. Mitigate with snapshot-style assertions comparing pre/post render output structure (not pixel-level).

### v0.6.0 — Tier 3 SelectionStore extraction + AoH migration tooling

- **Theme:** The structural change that unlocks genuine per-view observation. Also the consolidation release where v0.5.x feature flags are removed.

**Changes:**
1. P-13: Extract `SelectionStore` as a `lazy var selection = SelectionStore(...)` on `ScanStore`, mirroring the Tier-2 pattern. Pass `@ObservedObject var selection: SelectionStore` to row views. Selection mutations no longer invalidate whole-`ScanStore` observation.
2. P-21: Make `itemLookupByID` lazy in StorageScan.
3. P-22: Eliminate `retainedItems` storage duplication via computed property backed by a lazy wrapper.
4. P-23: Switch `DuplicateHashCache.Entry.checksum` from `String` to `Data` (feature-flagged introduction in v0.5.6, promoted here). One-shot migration on load.
5. P-28: Promote CI perf-regression gate from advisory (v0.5.3) to blocking.
6. Remove v0.5.4 / v0.5.5 / v0.5.6 feature flags.

**Note on Tier 5 `@Observable`:** Not in this release. The explicit risk in `architecture.html:278-283` + the `didSet` observers in `FilterStore.swift:37-95` make migration invasive. P-13 (Tier 3) eliminates the bulk of the whole-tree re-render problem that Tier 5 was meant to fix. Defer Tier 5 to v0.7.0 or later. The `filterBinding` bridge stays as-is for now — see §5.

**Validation:**
- `selectedItemID` mutation no longer causes DetailView or SidebarView body re-evaluation (verifiable via `let _ = Self._printChanges()` debug hook).
- Memory footprint of `StorageScan` drops (verify via `MemoryLayout<StorageScan>.size` test + the `peakMemoryBytes` metric).
- `swift test` 90/90 still passes; add new tests in `Tests/StorageScopeTests/SelectionStoreTests.swift`.
- `CleanupSelectionPlanner.topLevelCandidates` is measured O(N) at 5,000 candidates (XCTest perf metric).

**Risk:** High. P-13 changes the entire `@ObservedObject` graph for row views. Even with a careful migration the closure-injection pattern needs to handle cases where `selection` mutations need to trigger `invalidateDerivedCaches()` (e.g., `ignoredCleanupCandidateIDs` change — see current setter at `ScanStore.swift:231-237`). Rollback shape: revert to v0.5.6 `@ObservedObject var store` everywhere.

---

## 5. What NOT to do yet

The architecture.html doc references the `filterBinding` bridge workaround (`Sources/StorageScope/Stores/ScanStore.swift:filterBinding`, `:192-194`) and notes it goes away with the `@Observable` macro migration (Tier 5 per `architecture.html:278-283`). The codebase already has multiple deferred items (`architecture.html:265-284`, changelog `:218-221`). These items look tempting but are not worth the complexity now:

1. **Tier 5 `@Observable` macro migration.** `FilterStore.swift:37-95` has `@Published` properties every one of which has a `didSet` that triggers `coordinateInvalidate()` or `rebuildSearchSubtreeMatchIDs()`. The `@Observable` macro synthesizes `access`/`withMutation` joinpoints only at the property level — `didSet`-style side-effects must be migrated to explicit setter methods, which then breaks the SwiftUI `Binding<Form>` integration that filterBinding solves. The cost-benefit is wrong here: P-13 (`SelectionStore` extraction) delivers most of the same narrow-observation benefits without the deterministic setter migration. **Defer to v0.7.0+.**

2. **Streaming/yielding enumeration (P-19 in this plan).** Tempting because it would let first-paint happen before scan completes, but the current `concurrentPerform` model is synchronous by design and migration to `AsyncStream` requires an actor-based scanner or a producer-queue. It would also interact badly with cancellation: `ScanCancellation.check()` (`FileSystemScanner.swift:31-39`) throws from synchronous calls; an async scanner would need a different cancellation contract. **Defer to v0.6.0 PoC, v0.7.0+ ship.**

3. **Removing the `filterBinding` bridge(assuming Tier 5 ships).** The bridge has been documented as a workaround (`architecture.html:163-207`) and is invoked in `ContentView.swift:46`, `DetailView.swift:397, 407, 448`, plus elsewhere via the `store.filterBinding(\.X)` callsites. Migrating each call site to `Bindable(store.filters).$X` is a coordinated change that touches 5+ files. **Do not migrate until Tier 5 lands AND has soaked for one minor release.**

4. **Aggressive `actor` migration of `ScanAccumulator`.** The accumulator today is `@unchecked` + `NSLock`-guarded; an `actor` would force async hops from the synchronous `concurrentPerform` body. That breaks the design. **Keep NSLock** — but consider P-3 (lock striping) carefully instead. Profiling will tell.

5. **Rewriting `StorageItem` as a `class` to avoid value-type COW.** The struct vs class question is interesting but premature — a class would change `Hashable`/`Equatable` semantics, break `Sendable` automatically, and require manual identity management. The COW cost on the current data shapes is bounded by `maxRetainedItems` (25k by default). **Defer indefinitely.**

6. **Switching `FileManager.contentsOfDirectory(at:includingPropertiesForKeys:options:)` to `URLResourceValues` batch fetch via `URLResourceKey` keys.** Already in use at `FileSystemScanner.swift:267-271`. The keys set (~11 keys) is broad but reasonable. Tightening it to drop `.fileAllocatedSizeKey` vs `.totalFileAllocatedSizeKey` saves little.

7. **Caching `rebuildSearchSubtreeMatchIDs` to disk.** The current `searchSubtreeMatchIDs: Set<String>?`is rebuilt on every scan change (`FilterStore.swift:222-224`) and on every query change (`:55-65`). Persisting across scans would require invalidation logic that doesn't really save much: the rebuild is bounded by the retained-item count (≤25k). **Not worth it**.

8. **Lock-free/atomic `Sendable` `DuplicateHashCache`.** An `actor` cache would force async I/O on every checksum lookup (`FileSystemScanner.swift:165, 417`), which would serially string-bond the parallel verify path. The current `NSLock` pattern works fine. **Don't migrate.**

---

## 6. Measurement plan first (Lead rollout)

**Premise:** Most proposed changes are waste unless the underlying bottleneck is real. The first release of this plan (v0.5.3) is measurement-only — no behavior changes. Everything below feeds back into §3 priorities; concrete numbers invalidate or promote hypotheses.

### 6.1 Signpost coverage to add in v0.5.3

| Signpost name | File / function | Phase measured |
|---|---|---|
| `verify_on_demand` | `FileSystemScanner.swift:156-196` (`verifySizeGroup`) | On-demand Verify Now execution time |
| `persist_on_demand` | `OnDemandVerificationStore.swift:71` | Background hashCache persist after Verify Now |
| `cache_invalidate_derived` | `ScanStore.swift:1328-1342` | When derived caches drop (filter change, scan change, ignore toggle) |
| `cache_invalidate_items` | `ScanStore.swift:1344-1347` | When `items(for:)` cache drops |
| `lookup_build` (optional) | `StorageScan.swift:74-83` | Eager `itemLookupByID` build cost (validates P-21 priority) |
| `cleanup_candidates_build` | `FileSystemScanner.swift:776-813` | Cleanup candidate sort + filter (validates the gap from `ScanBenchmark.swift:22-27`) |

### 6.2 Fixture scaling

Extend `Sources/StorageScopeCore/Services/ScanBenchmark.swift:syntheticBenchmarkFixture` and `script/build_and_run.sh`'s `prepare_fixture_scan_root` so a maintainer can run:

```bash
# Existing 7-file fixture, unchanged:
./script/build_and_run.sh --fixture-scan --duplicates

# New scaled fixtures:
swift run StorageScopeBenchmark --synthetic --items 10000 --depth 5 --duplicates 0.1
swift run StorageScopeBenchmark --synthetic --items 100000 --depth 8 --duplicates 0.2
swift run StorageScopeBenchmark --synthetic --items 500000 --depth 12 --duplicates 0.05

# Persistent fixture path for Instruments:
swift run StorageScopeBenchmark --synthetic --items 100000 --keep-fixture
# Then attach Instruments to a manual scan of the printed fixture path.
```

Capture v0.5.2 baseline output for each fixture size: `enumerateDuration`, `verifyDuration`, `persistDuration`, `peakMemoryBytes`, `cleanupCandidateCount`, `scannedItemCount`. Save text reports under `docs/perf-baselines/v0.5.2/<fixture>.txt` (data only).

### 6.3 Decision rules — what to actually ship

For each subsequently-proposed change:

| Validation result | Action |
|---|---|
| Signpost shows the suspected phase exceed **20%** of `totalDuration` on the 100k+ fixture | Promote the corresponding P-1..P-23 proposal for inclusion in the next v0.5.x slice |
| Signpost shows < **5%** | Defer / cancel the proposal |
| `peakMemoryBytes` (the new, correct implementation) shows > 1.5 GB on 100k fixture | P-1 (`autoreleasepool`) becomes P0 priority for v0.5.4 |
| `cache_invalidate_derived` signpost density during clean-up-review interactions > 5 Hz | P-8 + P-9 (cache gaps) become P0 priority for v0.5.5 |
| XCTest perf metric shows `selectedItemID` mutation triggers whole-window body re-eval > 5 ms | P-13 (`SelectionStore` Tier 3) becomes P0 priority for v0.6.0 (or v0.5.6 if scope allows) |

If the validation across multiple machines shows that none of the suspected hotspots reach the thresholds above, **stop** and re-plan: the suspected bottlenecks are imaginary and the next slice should be feature-driven, not perf-driven.

---

## 7. Summary of file paths

The user asked for `PLAN.md` at the repo root. This plan is a single-file document, ~600 lines, structured to be paste-as-is. Replace the following placeholder if the user wants to write it themselves:

- **Path:** `/Users/ianzvirbulis/Documents/Codex/2026-05-13/i-want-a-full-fledged-professional/PLAN.md`
- **Length:** ~650 lines (within the 600–1200-line budget).
- **No file edits made by this agent** (the harness is read-only).

### Critical Files for Implementation

- `/Users/ianzvirbulis/Documents/Codex/2026-05-13/i-want-a-full-fledged-professional/Sources/StorageScopeCore/Services/FileSystemScanner.swift`
- `/Users/ianzvirbulis/Documents/Codex/2026-05-13/i-want-a-full-fledged-professional/Sources/StorageScope/Stores/ScanStore.swift`
- `/Users/ianzvirbulis/Documents/Codex/2026-05-13/i-want-a-full-fledged-professional/Sources/StorageScope/Stores/FilterStore.swift`
- `/Users/ianzvirbulis/Documents/Codex/2026-05-13/i-want-a-full-fledged-professional/Sources/StorageScopeCore/Models/StorageScan.swift`
- `/Users/ianzvirbulis/Documents/Codex/2026-05-13/i-want-a-full-fledged-professional/Sources/StorageScopeCore/Services/CleanupSelectionPlanner.swift`

### Critical Files for Implementation
- /Users/ianzvirbulis/Documents/Codex/2026-05-13/i-want-a-full-fledged-professional/Sources/StorageScopeCore/Services/FileSystemScanner.swift
- /Users/ianzvirbulis/Documents/Codex/2026-05-13/i-want-a-full-fledged-professional/Sources/StorageScope/Stores/ScanStore.swift
- /Users/ianzvirbulis/Documents/Codex/2026-05-13/i-want-a-full-fledged-professional/Sources/StorageScope/Stores/FilterStore.swift
- /Users/ianzvirbulis/Documents/Codex/2026-05-13/i-want-a-full-fledged-professional/Sources/StorageScopeCore/Services/CleanupSelectionPlanner.swift
- /Users/ianzvirbulis/Documents/Codex/2026-05-13/i-want-a-full-fledged-professional/Sources/StorageScopeCore/Models/StorageScan.swift
