# StorageScope Performance Plan v2.1 — measured, not guessed

**Scope:** StorageScope v0.7.1 (`main` @ 9cb1f36, 2026-07-02)
**Relationship to `PLAN.md`:** Supersedes and extends P-1..P-28. This revision replaces v2's code-reading hypotheses with **profile evidence captured on this machine** (Apple silicon, Swift 6.3.2, release build, 10 k synthetic fixture, `sample(1)` at 1 ms for 3 s mid-scan). Two of v2's claims were wrong and are corrected below.

**Headline goal:** 100 k-item scan enumerates in **< 10 s** (release, SSD), re-scans of an unchanged tree in **< 1 s**, duplicate verification reads **≥ 90 % fewer bytes**, peak RSS **< 150 MB** @ 100 k items, 60 fps UI during a live scan.

---

## 0. What the profiler actually says

Measured runs, same machine, same 10 k / depth-5 / 10 %-duplicates fixture:

| Configuration | Enumerate | Rate |
|---|---:|---:|
| Debug (`-Onone`) | 5.25 s | ~1,970 items/s |
| Release (`-O`) | 4.91 s | ~2,110 items/s |

**Correction 1:** debug vs release is only ~7 %. The committed baselines being debug builds (`script/benchmark_scan.sh:7` lacks `-c release`; `100k.txt` starts with "Building for debugging...") is a hygiene bug worth fixing, but it is **not** why scans are slow. A workload this insensitive to optimizer level is not CPU-bound in Swift code — it is blocked.

`sample(1)` during the release scan, top-of-stack across ~18,000 thread-samples on 12 threads:

| Frame | Samples | Meaning |
|---|---:|---|
| `__psynch_mutexwait` | 14,697 (~80 %) | Threads parked waiting on a mutex |
| `CFStringCompareWithOptionsAndLocale` | 814 | `localizedStandardCompare` (ICU collation) |
| `__workq_kernreturn` / `__ulock_wait` | 1,140 | GCD pool idle/starved under nested `concurrentPerform` |
| `CanonicalFileURLStringToFileSystemRepresentation` | 345 | URL path canonicalization (`standardizedFileURL`, `.path`) |
| `stat` | 28 | Actual filesystem I/O |

Per-thread call trees attribute the mutex waits: each of ~11 worker threads spent ~1.2 s of the 3 s window blocked in **`ScanAccumulator.recordItem` → `-[NSLock lock]` → `__psynch_mutexwait`**.

**The measured story:** the parallel directory walk is effectively serialized through `ScanAccumulator`'s single `NSLock`, and the thread *holding* the lock spends its time doing ICU string comparisons in the duplicate-candidate eviction path. Filesystem I/O (`stat`, 28 samples) is nearly free — the hardware is idle while the code argues over a mutex. This is why 105 k items took 185 s: eviction runs once per candidate insert after the 5,000 cap (100,000 considered ⇒ ~95,000 evictions, each a linear ICU-compare scan under the global lock), so cost grows superlinearly with item count.

**Correction 2:** v2 blamed the every-25-items snapshot build (`emitProgressLocked`'s `isMultiple(of: 25)` branch) for the baseline. The benchmark installs **no** progress/onSnapshot callbacks (`ScanBenchmark.swift:127`), so snapshots contribute *zero* to the committed baselines. The snapshot problem is still real **in the app** — `ScanStore` installs both callbacks, so real users pay it on top of everything the benchmark measures — but it is an app-only cost and is re-scoped accordingly (§2.3).

---

## 1. Phase 1 — kill the lock convoy (the measured 80 %)

### 1.1 Fix the eviction path — highest priority in the plan

`ScanAccumulator.removeSmallestDuplicateCandidateLocked` (`FileSystemScanner.swift:1187`):

```swift
let removalIndex = items.indices.max { lhs, rhs in
    items[lhs].url.path.localizedStandardCompare(items[rhs].url.path) == .orderedAscending
}
```

Once `maxDuplicateCandidateItems` (5,000) is reached, **every further candidate insert** triggers: a linear scan of the smallest-size bucket with full ICU collation per pair (`CFStringCompareWithOptionsAndLocale` — the #1 working frame in the profile), plus `duplicateCandidatesBySize.keys.min()` when a bucket drains — all while holding the global lock every other worker needs to record anything.

Changes:

1. **Reject-before-lock:** keep an atomic `smallestRetainedSize`; workers whose `item.byteSize < smallestRetainedSize` (the common case post-cap) skip the insert without touching the lock.
2. Replace `[Int64: [StorageItem]]` + linear-min-scan with a **min-heap keyed by `byteSize`** — O(log n) insert/evict, zero string comparisons on the hot path.
3. Determinism moves to one final sort of the retained set at scan end (existing determinism tests are the safety net).
4. Audit-and-ban `localizedStandardCompare` from all hot paths: it also runs in `DirectoryScanSummary.sortedRetainedCandidates` (`:762`, re-sorts up to 800 items *per directory*) and in ranked-list tie-breaks. Use `displaySize` + byte-wise UTF-8 compare during the scan; apply localized ordering only at display time.

### 1.2 Decompose the accumulator lock

Even with cheap critical sections, one `NSLock` across 11 workers for every `recordVisit` + `recordBytes` + `recordItem` (that's **2–3 separate lock acquisitions per file**, `:844-882`) leaves a convoy. In order of preference:

1. **Per-worker sharded accumulators:** each walker thread owns a private accumulator (counters, ranked heaps, type stats, candidate heap); merge shards on emission ticks and at scan end. Lock contention drops to ~zero; merging 8 heaps of ≤ 500 items is microseconds.
2. Failing that, minimum viable: collapse the per-item triple acquisition into a single `record(visit:bytes:item:)` call, and swap `NSLock` for `os_unfair_lock`/`OSAllocatedUnfairLock` (no syscall on uncontended acquire, better convoy behavior).
3. Replace append-then-resort ranked lists (`trimRankedItems` sorts at 4× limit) with **bounded min-heaps** of `maxRankedResults` — O(log 500) insert, no comparator closures over Strings.

**Exit criterion (Phase 1):** on the re-captured release 100 k baseline, `__psynch_mutexwait` < 5 % of samples and enumerate improves ≥ 5× (the profile says ≥ 80 % of thread-time is recoverable, and the superlinear eviction term disappears entirely). Effort: S–M. Risk: low — internal to `ScanAccumulator`; determinism + cancellation tests must pass.

---

## 2. Phase 2 — structural fixes the profile also implicates

### 2.1 Flatten the nested `concurrentPerform` walk

`scanItem` fans out via `DispatchQueue.concurrentPerform` **per directory, recursively** (`:355`). Every non-leaf directory blocks a GCD worker while its children run; the 1,140 `__workq_kernreturn`/`__ulock_wait` samples are that machinery idling. The code's own `waitIfPaused` comment (`:78-84`) admits the pool-starvation risk on pause.

Replace with a **fixed worker pool** (≈ `activeProcessorCount`, capped ~8 on SSD, 2–4 on network/spinning volumes) pulling directories from a shared frontier deque: pop directory → enumerate children → record files → push subdirectories. Directory sizes finalize via a pending-children counter bubbling up (no call-stack dependency). One cancellation check per pop; pause parks workers on one condition variable without occupying the GCD pool. This also deletes the `[StorageItem?]` placeholder array and the per-child `OSSignpostID(log:object: index as NSNumber)` allocation — an NSNumber + signpost begin/end **per file** even with no profiler attached; re-scope signposts to per-directory.

Keep the old walker behind `STORAGESCOPE_LEGACY_WALKER` for one release; gate on tree-equality differential tests plus pause/cancel fuzzing. Effort: L. Risk: medium — the one big refactor here, but it also fixes the documented pause-starvation bug, so it pays for itself even if Phase 1 alone hits the wall-time target.

### 2.2 Cut per-item Foundation costs (345 samples of URL canonicalization)

1. Don't re-fetch `url.resourceValues(forKeys:)` in `scanItem` (`:274`) — `contentsOfDirectory(includingPropertiesForKeys:)` already prefetched those keys; fall back to a stat only on cache miss.
2. Build `StorageItem.id` as parent-path + `/` + name instead of `url.standardizedFileURL.path` per item (`StorageItem.swift:41`) — that call is the `CanonicalFileURLStringToFileSystemRepresentation` hot frame. Intern lowercase extensions (they repeat massively).
3. **Stretch, behind a flag:** a `getattrlistbulk(2)` enumeration backend — one syscall returns name/type/sizes/mtime for hundreds of entries, zero NSURL objects. Runtime capability probe per volume; FileManager fallback per subtree; differential tree-equality tests. This is the difference between "fast" and "instant" once §1's lock work stops hiding the syscall layer. Only meaningful *after* Phase 1 — today it would speed up the 20 % the process isn't blocked.

### 2.3 Fix the app-only snapshot cost

In the app (not the benchmark), `emitProgressLocked` (`:1059`) builds a full `StorageScan` snapshot **every 25 items regardless of elapsed time** — three ranked sorts + both breakdown rebuilds + `StorageScan.init` — under the accumulator lock, with workers blocked behind it.

1. Make the throttle time-only (~0.35 s progress, ~1 s snapshots); delete the `isMultiple(of: 25)` branch.
2. Copy raw state under the lock (cheap COW), build the derived `StorageScan` **outside** it.
3. Add an in-app instrumented measurement (signpost around snapshot build) to the re-baselined numbers so "benchmark-fast but app-slow" can't recur — that divergence is exactly what let this hide until now.

---

## 3. Phase 3 — do less work, not just faster work

Two tracks v2 under-weighted; both matter more to perceived speed than raw enumeration:

### 3.1 Incremental re-scan (biggest user-facing win in this document)

Users re-scan the same folders repeatedly; today every re-scan pays full price. Design:

1. Persist the completed scan tree (compact walk records, §4) keyed by root + volume ID.
2. On re-scan, start an **FSEvents** listener rooted at the scan root from the moment a scan completes; record dirtied subtree paths (coalesced by FSEvents for free) between scans.
3. Re-scan = re-walk dirty subtrees only, splice into the persisted tree, re-derive accumulator stats from merged records. Unchanged-tree re-scan touches ~nothing: **< 1 s target.**
4. Fall back to a full walk when the event log overflowed (`kFSEventStreamEventFlagMustScanSubDirs`), the volume ID changed, or persistence is missing/corrupt. Hash cache already persists (`DuplicateHashCache`), so verification is incremental for free.
5. Ship read-only-trust-but-verify first: incremental result + background full walk comparing item counts, log divergence, before making incremental the default.

Effort: L (the one new-feature-sized item). Risk: medium — correctness depends on FSEvents semantics; the trust-but-verify rollout and the fallback rules bound it.

### 3.2 Perceived performance during first scan

- **Converge big numbers first:** walk the frontier largest-known-first (size from parent enumeration) so top-level folder sizes and the Overview stabilize in the first seconds even if leaves take longer.
- Stream a real (partial) retained tree in snapshots instead of the current placeholder root (`snapshotLocked` sends an empty tree, `:1083`), so Folder Tree/Storage Map populate during the scan rather than at the end.

### 3.3 Duplicate verification: tiered hashing

1. **Tier 0 — metadata:** detect hard links (`st_nlink`/`st_ino`) and exclude them — they reclaim nothing and are reported as duplicates today. Investigate APFS clone detection (clones also reclaim ~nothing on delete); no clean public API, so at minimum caveat clone-suspect results in UI.
2. **Tier 1 — 64 KB prefix hash** per candidate; most same-size non-duplicates diverge in the first block and drop out for the cost of one small read.
3. **Tier 2 — full hash** only for still-colliding groups. Cache both tiers in `DuplicateHashCache` under separate key namespaces.
4. Mechanics: reuse a read buffer instead of a fresh 1 MB `Data` per chunk (`:663`), raise chunks to 4–8 MB, keep digests as 32 raw bytes end-to-end (hex only at display; subsumes PLAN P-7/P-23), batch cache writes per group instead of per file (`cacheLock` per record, `:697`).

Expected: ≥ 90 % fewer verification bytes on media/VM-heavy sets; the 20 GB budget then verifies far more real duplicates per scan. Add a "verification bytes read" counter to `ScanBenchmarkReport` so this is measured, not asserted.

---

### 3.4 Proof harness (implemented 2026-07-11)

Before changing the walker, `Tests/StorageScopeCoreTests/ScannerProofHarness.swift` now
provides a reusable differential surface. It canonicalizes relative paths, sibling order,
tree metadata, derived rankings, duplicate groups, cleanup candidates, and scan counters
while intentionally ignoring UUID roots, timestamps, and durations.

The fixture set covers:

1. deep and wide directory shapes;
2. a mutation sequence of creates, deletes, renames, and resizes;
3. a hard-link pair with an inode identity check;
4. deterministic permission-loss injection; and
5. deterministic volume-loss injection.

`ScannerProofHarness.compare` accepts separate baseline and candidate runners, so the
fixed-worker walker can be introduced behind a flag and compared state-for-state before
it becomes the default. The current tests run both sides through the existing scanner to
prove the harness itself, and deliberately preserve the current hard-link semantics until
the compact-record phase changes that policy.

Focused proof:

```sh
swift test --scratch-path /tmp/storagescope-worker-focused-serial --disable-index-store --jobs 1 --filter ScannerProofHarnessTests
```

Latest result: 7 differential/stability tests in 1 suite passed; the compact-record
contract extends the latest focused run to 8 tests across 2 suites.

### 3.5 Fixed-worker walker (implemented opt-in 2026-07-11)

`FileSystemScanner` now has an experimental fixed-worker backend behind
`STORAGESCOPE_EXPERIMENTAL_WORKER_WALKER=1`. It uses a bounded directory frontier,
bounded record channel, fixed worker count, deterministic post-walk reconstruction, and
the same public `StorageScan` accumulation rules as the legacy walker. The legacy path
remains the default; `STORAGESCOPE_LEGACY_WALKER=1` is an explicit override. If the
experimental backend encounters an unexpected worker-only failure, it retries the root
through the legacy path before publishing a scan.

The differential harness now compares legacy and fixed-worker output across deep/wide,
mutation-heavy, hard-link, permission-loss, and volume-loss fixtures. It also covers
pause/resume completion and cancellation while paused. The focused suite passed 7 tests.

Release measurements on the same synthetic depth-5 fixture show why promotion is not
yet justified:

| Fixture | Legacy median / RSS | Fixed-worker median / RSS | Result |
|---|---:|---:|---|
| 10 k items, 3 runs | 0.57 s / 36 MB | 0.99 s / 49.6 MB | worker slower and higher RSS |
| 100 k items, 1 run | 17.82 s / 84.8 MB | 14.66 s / 249 MB | wall time improves, memory gate fails |

The fixed-worker path therefore stays opt-in. The next implementation step is the compact
metadata-record phase: remove URL-rich transient retention, carry parent and volume/file-
resource identity explicitly, and re-run the same differential and release gates before
changing the default.

### 3.6 Compact walk records (implemented opt-in 2026-07-11)

The fixed-worker backend now uses `FixedWorkerWalkRecord` for the retained walk state:
name, parent ID, scalar sizes/timestamps/readability, compact kind metadata, and fixed-width
opaque volume/file-resource identifiers from `URLResourceValues`. URLs remain only on
directory jobs and are materialized when the final public tree is rebuilt. Per-directory
autorelease pools bound Foundation-object retention during enumeration. The hard-link
reclaimability policy is intentionally unchanged in this slice; `hardLinkCount` is reserved
for the follow-up identity policy rather than being inferred from an opaque resource identifier.

The proof surface now includes a source contract that rejects URL storage inside the compact
record and requires parent/resource identity fields. The differential hard-link fixture still
passes with the existing public semantics.

Kept-fixture release measurements isolate scan cost from fixture-generation memory:

| Fixture | Legacy control | Compact fixed-worker | Result |
|---|---:|---:|---|
| 10 k items, 3-run median | 0.58 s / 29.7 MB | 0.44 s / 37.3 MB | wall time improves, RSS +26% |
| 100 k items, 1 run | 8.67 s / 31.3 MB | 7.48 s / 54.5 MB | wall time improves, RSS +74% |

The compact representation removes the earlier URL-rich worker spike, but it still fails the
memory promotion gate. The 100 k profile is no longer mutex-dominated; `__workq_kernreturn`
leads, followed by `StorageItem` copy/destroy activity in `makeFixedWorkerItem`. The next
step is lazy rich-item materialization for retained/ranked/duplicate candidates, plus a
separate hard-link reclaimability policy, before considering default promotion.

### 3.7 Lazy rich-item materialization (implemented opt-in 2026-07-12)

The fixed-worker reconstruction pass now returns compact `FixedWorkerItemSummary` values and
retains rich summary payloads only for the bounded retained tree and bounded ranked, duplicate,
and cleanup references. `FixedWorkerSummaryStore` is a stateless materializer rather than a
global ID-to-summary map, so non-retained entries are released after aggregation. Ranked,
duplicate, and cleanup references carry their source URL explicitly; this preserves parity for
results that are not present in the retained tree.

The hard-link reclaimability policy remains deliberately deferred. `hardLinkCount` stays a
reserved zero field and opaque resource identifiers are not interpreted as link counts.

Latest proof and release measurements for the post-materialization implementation:

| Fixture | Fixed-worker release result | Gate |
|---|---:|---|
| 10 k items, 3 runs | 1.14 s median / 40.5 MB RSS (1.04, 1.14, 1.37 s; 39.8, 40.5, 41.7 MB) | memory healthy; worker remains slower than the historical legacy control |
| 100 k items, 1 run | 12.83 s / 58.2 MB RSS | RSS clears `<150 MB`; wall time misses `<10 s` |

The worker therefore remains opt-in behind `STORAGESCOPE_EXPERIMENTAL_WORKER_WALKER=1` and
the legacy walker remains the default. The 100 k three-run recheck was not promoted to evidence
because SwiftPM hit its known “input file was modified during the build” race before the scan
started. That handoff led to the ranked-reference heap pass below rather than reintroducing a
global summary map.

### 3.8 Bounded ranked-reference heap (implemented opt-in 2026-07-12)

A fresh release sample localized the remaining reconstruction cost to
`buildFixedWorkerSummary` → `insertFixedWorkerRankedReference`: every scanned candidate could
scan the bounded ranked array, recompute its minimum, and repeatedly materialize `URL.path` for
tie-breaking. The ranked collections now use a worst-first bounded heap. Path keys are captured
only for references that enter the bounded set, and final display ordering remains deterministic
through one read-time sort.

The change is covered by a source contract for the heap operations and by the existing
differential, hard-link, cleanup, fault, pause, and cancellation tests.

Latest kept-fixture release measurements:

| Fixture | Fixed-worker result | Gate |
|---|---:|---|
| 10 k items, 3 runs | 0.40 s median / 39.3 MB RSS (0.42, 0.39, 0.40 s; 39.3, 37.9, 39.9 MB) | clears the small-fixture wall gate |
| 100 k items, 3 runs | 6.34 s median / 56.6 MB RSS (6.25, 6.40, 6.34 s; 53.2, 59.5, 56.6 MB) | clears `<10 s` and `<150 MB` |

The benchmark wall-time gate is green. The worker remains opt-in for the planned one-release
fallback window; hard-link reclaimability is a Phase 3 policy, not a Phase 2 promotion gate.
The next profiled cost is copy-on-write eviction in
`FixedWorkerDuplicateCandidateRetention.evictSmallestRetained()`; it is not changed in this
slice.

### 3.9 Phase 2 app-path gate — complete (2026-07-12)

The first release comparison failed at 1.278× app/callback-free overhead: 2.938 s app median
versus 2.299 s callback-free. Two app-only costs were then removed without changing scan
semantics: snapshot builds were separated from the 0.35 s progress cadence and throttled to
approximately 1 s, and retained-path canonicalization for hash-cache persistence moved off the
main actor into the existing detached persistence task.

The same-process, same-fixture, alternating three-run release proof then passed:

| Path | 100 k median | Relative |
|---|---:|---:|
| Callback-free `FileSystemScanner` | 2.541 s | 1.000× |
| Interactive `ScanStore` | 2.561 s | 1.008× |
| Scanner duration reported through app path | 2.348 s | 0.924× |

App overhead is 0.8%, clearing the ≤15% exit gate. Snapshot counts were 3, 2, and 2 across the
three app runs. The opt-in proof is `ScanStoreAppPerformanceProofTests` and requires a release
build plus `STORAGESCOPE_TESTING`, so ordinary release builds retain no debug counters or test
drain hooks. Focused differential/fault/pause/cancel coverage passed 10 tests across 3 suites;
the full rebased default suite passed 221 tests across 22 suites with the expensive proof skipped by
default. All Phase 2 exit criteria are now satisfied. Phase 3 starts with tiered verification,
hard-link reclaimability, and perceived-progress streaming.

---

## 4. Phase 4 — memory

271.8 MB peak @ 100 k ≈ 2.7 KB/item even though only 25 k items are retained: every visited item transiently materializes URL + id String + name String + extension + NSURL bridging garbage.

1. Split the model: a fixed-size **walk record** (sizes, mtime, flags, interned-extension index, parent index) for enumeration/stats, with rich `StorageItem`s built only for the ≤ 25 k retained items at finalization. This same compact record is the persistence format for §3.1.
2. `ContiguousArray` + capacity reservation for children buffers; per-worker scratch reuse in the §2.1 pool.
3. Target < 150 MB @ 100 k, sublinear to 500 k; verify with mid-scan `mach_task_basic_info` sampling (PLAN P-25).

---

## 5. Phase 5 — UI and main actor

1. **`@Observable` migration** (target is already macOS 14+): `ScanStore` (2,170 lines) currently invalidates every observing view on any change. Observation-framework per-property tracking largely obsoletes PLAN's invasive P-13 `SelectionStore` extraction and P-15 `Equatable` rows in one move. Sequence store-by-store (`FilterStore` → small stores → `ScanStore` last), comparing SwiftUI update counts in Instruments at each step.
2. **Search:** `matchesTerm` (`StorageItem.swift:102`) runs `localizedCaseInsensitiveContains` on name *and* path plus a `pathComponents` split, per item per keystroke, over up to 25 k items. Precompute lowercase name/path keys once per scan, use plain `contains`, debounce the query ~150 ms.
3. Keep the still-valid cheap PLAN items and fold them in here: P-8/P-9 (memoization), P-11 (async `mountedVolumes`), P-14 (GeometryReader fills), P-16/P-17.

---

## 6. Measurement hygiene (demoted from v2's #1, still required)

1. `script/benchmark_scan.sh` → `swift run -c release ...` (with `--debug` escape hatch); benchmark report header prints build configuration; CI rejects debug-mode baseline files.
2. Re-capture 10 k / 100 k baselines in release into `docs/perf-baselines/v0.7.1/`, 3 runs, median + spread — **plus a `sample(1)`/xctrace capture committed alongside**, since top-of-stack profiles (not wall-time alone) are what caught the real bottleneck.
3. **Cold-cache variant:** the synthetic benchmark scans files it just wrote — everything is warm in the unified buffer cache, which understates I/O and overstates CPU/lock effects relative to real first scans. Add a purge step (`purge`, or re-mount fixture on a disk image) and record both warm and cold numbers.
4. New counters in `ScanBenchmarkReport`: mutex-wait share (from an instrumented build), evictions performed, snapshot builds (app-instrumented), verification bytes read, cache hit/miss, worker utilization.
5. CI perf gate on the 10 k fixture: items/second vs. committed reference with ±35 % band (GitHub runners are noisy) plus noise-immune ratio gates ("evictions ≤ considered − retained", "snapshot builds per 1,000 items ≤ 2"); fail only on two consecutive regressions.

---

## 7. Sequenced rollout

| Phase | Release | Contents | Exit criterion (release build, 100 k fixture) |
|---|---|---|---|
| 0 | v0.7.2 | §6.1–2 hygiene + counters + re-baseline | Trustworthy baseline incl. profile committed |
| 1 | v0.7.3 | §1 eviction fix + lock decomposition + heaps | `__psynch_mutexwait` < 5 % of samples; enumerate ≥ 5× vs Phase-0 baseline |
| 2 | v0.8.0 | §2.1 worker-pool walker (flagged), §2.2.1–2 per-item costs, §2.3 app snapshot fix | Enumerate < 10 s; pause/cancel green on both walkers; in-app scan within 15 % of benchmark scan |
| 3 | v0.8.1 | §3.3 tiered hashing; §3.2 perceived-perf streaming | Verification bytes −90 % on duplicates fixture; hard links excluded; Overview stable < 3 s into a 100 k scan |
| 4 | v0.9.0 | §4 walk records; §2.2.3 `getattrlistbulk` (flagged); §3.1 incremental re-scan (trust-but-verify) | RSS < 150 MB @ 100 k; unchanged-tree re-scan < 1 s; bulk backend ≥ 2× with identical trees |
| 5 | v0.9.x | §5 `@Observable` + search keys | SwiftUI update count during live scan −80 %; no dropped frames typing in filter @ 25 k items |

**Decision rule** (replacing PLAN §6.3's debug-based thresholds): each phase re-runs fixtures in release, 3 runs, medians, warm *and* cold. A change ships if its target counter improves ≥ 10 % without regressing any other counter > 5 %; otherwise it stays flagged and the hypothesis table is updated with the measured result. Any claim of "X is the bottleneck" must cite a profile, not code reading — this document needed two corrections for exactly that reason.

---

## 8. Risk register

- **§2.1 walker refactor:** concurrency contract change (pause/cancel/determinism). Mitigation: legacy flag one release, differential tree-equality tests, pause/resume/cancel fuzz (randomized timing, 1,000 CI iterations).
- **§3.1 incremental re-scan:** correctness rests on FSEvents delivery. Mitigation: trust-but-verify rollout, conservative fallback triggers, full-walk always available.
- **`getattrlistbulk`:** per-filesystem quirks (SMB/NFS/FUSE). Mitigation: per-volume probe, per-subtree fallback, non-default until v1.0.
- **`@Observable`:** silent update-timing changes. Mitigation: store-by-store migration with render-count snapshots.
- **Determinism:** current stable orderings lean on ICU compares in hot paths; the plan moves all determinism to final read-time sorts. `parallelEnumerationIsDeterministicAcrossRuns` and friends are the safety net and must not be weakened.
- **CI noise:** wide bands, ratio gates, two-strike policy (§6.5).

---

## 9. Expected end state

The profile shows the hardware is nearly idle during today's scans (28 `stat` samples vs 14,697 mutex-wait samples). The syscall floor for 100 k stat-equivalents via bulk enumeration is well under 2 s on Apple silicon + SSD; tiered hashing keeps verification to a few hundred MB of reads against a 2.5 GB/s device. Phases 0–2 remove the self-inflicted serialization between that hardware and the user; Phases 3–4 stop repeating work across scans. A first scan in single-digit seconds and a re-scan in under one second are engineering outcomes of this sequence, not aspirations.
