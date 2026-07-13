# Phase 3 incremental re-scan proof

Captured 2026-07-13 on an Apple M1 with Swift 6.3.2. The release binary scanned a
kept local fixture containing 100,000 empty files and 101 directories. The fixture
was already persisted before this process started, so run 1 measures cold-process
tree reconstruction and runs 2-3 measure unchanged re-scans in the same process.

```sh
swift build -c release --disable-index-store --jobs 1
/usr/bin/time -l env STORAGESCOPE_INCREMENTAL_RESCAN=1 \
  .build/release/StorageScopeBenchmark \
  /tmp/storagescope-incremental-100k-20260713 --repeat 3
```

| Run | Mode | Duration | Dirty subtrees | Fallback |
|---|---|---:|---:|---|
| 1 | `incrementalUnchanged` | 4.03 s | 0 | none |
| 2 | `incrementalUnchanged` | 0.10 s | 0 | none |
| 3 | `incrementalUnchanged` | 0.07 s | 0 | none |

The process reported 126.9 MB peak memory (`133087232` maximum resident bytes from
`time -l`). Runs 2-3 clear the `<1 s` unchanged re-scan target and the process stays
below the `<150 MB` 100k RSS gate. This does not prove a sub-second cold-process
reload; the persisted reconstruction in run 1 took 4.03 s.

The app enables incremental scans explicitly. A live FSEvents monitor starts from
the pre-walk checkpoint, changed directory subtrees are coalesced and spliced into
a compact parent-indexed binary property-list tree, and the previous scan is reused
in memory when no event arrived. The scanner falls back to a full walk for missing,
corrupt, incompatible, or inconsistent persistence; changed root, volume, or scan
options; unavailable/dropped/overflowed event history; and excessive dirty subtrees.
The legacy-walker environment override disables the incremental backend.

Trust-but-verify remains enabled in the app: an incremental result is followed by a
deduplicated background full walk. A metadata/tree divergence invalidates persistence
so the next scan takes the conservative full-walk fallback.

Correctness proof:

- 11 focused incremental tests cover real one-shot and live FSEvents delivery,
  immediate-mutation races, unchanged reuse, cancellation, subtree splicing,
  1,000 generated create/delete/rename/resize mutations, event overflow, option,
  schema and volume changes, corrupt persistence, and inconsistent parent IDs.
- The final post-tightening full package run passed 232 tests across 23 suites.

Results are local only. The fixture contains generated empty files, not user data.
