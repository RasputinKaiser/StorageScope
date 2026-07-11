# StorageScope performance baseline — 2026-07-11

Machine: Apple M1, 16 GB RAM
Configuration: SwiftPM release (`-c release`)
Fixture regime: synthetic files written immediately before scanning, warm filesystem cache
Branch base: `origin/main` at `690227d`

All medians below use three scans of the same kept fixture. Fixture creation is excluded from scan duration.

| Stage | 10k median | 100k median | 100k peak RSS |
| --- | ---: | ---: | ---: |
| Merged `main` baseline | 4.70s | not rerun; the 10k profile already reproduced the eviction convoy | 29.9 MB at 10k |
| Duplicate-retention, snapshot, and verification tranche | 0.57s | 8.53s | 32.4 MB |
| Bounded ranked-item heaps | **0.49s** | **7.42s** | **30.5 MB** |

The complete tranche makes the freshly measured 10k case approximately 9.6x faster than merged `main`. Replacing append/resort/truncate ranked lists with deterministic bounded heaps improves the already-optimized 10k median by approximately 14% and the 100k median by approximately 13%.

## Release profiles

The merged-main 10k capture (`/tmp/storagescope-perf/20260711-170503`) recorded:

- `__psynch_mutexwait`: 15,251 top-of-stack samples
- `CFStringCompareWithOptionsAndLocale`: 742 samples
- `CanonicalFileURLStringToFileSystemRepresentation`: 365 samples

The final 100k capture (`/tmp/storagescope-perf/20260711-171724`) recorded:

- `__psynch_mutexwait`: 11,896 top-of-stack samples
- `stat`: 217 samples
- `initializeWithCopy for StorageItem`: 168 samples
- `CanonicalFileURLStringToFileSystemRepresentation`: 43 samples

The remaining dominant cost is still the single `ScanAccumulator` lock. A fixed-worker/batched-accumulator redesign remains the next structural phase; this tranche deliberately does not claim that exit criterion is complete.

## Duplicate-verification guard

`./script/benchmark_scan.sh /tmp/storagescope-prefix-mismatch-bench` read 262 KB while rejecting 4.2 MB of same-size, prefix-mismatched candidates. It produced no false verified groups.

## App-like streaming regime

The benchmark now supports `--streaming`, which installs progress and partial-snapshot callbacks without involving UI automation. On the same kept 10k fixture:

- streaming callbacks: 0.50s median, 4 snapshots built
- callbacks disabled: 0.52s median, 0 snapshots built

Streaming is already within the plan's 15% app-versus-benchmark target. Moving snapshot construction outside the accumulator lock is therefore not justified by this fixture today.

## Rejected experiments

- Accumulator batches of 64 regressed the 10k median to 0.58s by suppressing filesystem parallelism.
- Accumulator batches of 8 improved 10k to 0.42s but produced a 9.88s 100k median with runs spanning 7.41–10.77s. The scheduling variance is unacceptable, so batching was fully reverted.
- Replacing `NSLock` with `os_unfair_lock` left the 10k median unchanged at 0.57s and was reverted.
- Moving per-item classification outside the lock improved only about 5%, below the 10% acceptance gate, and was reverted.
- Verification-time hard-link probing passed correctness tests but regressed the 10k median and raised peak RSS to roughly 34 MB. It was reverted; hard-link identity belongs in a future metadata-prefetch design.

## CI regression guard

`script/ci_performance_gate.sh` builds the release benchmark, creates one kept 10k fixture, runs it twice, and validates both reports with `script/check_performance_gate.py`. Duration fails only when both runs exceed the broad hosted-runner ceiling; release mode, item count, memory, snapshot, and duplicate-counter invariants are checked on every run.

## Validation

- 214 tests across 20 suites passed.
- `./script/build_and_run.sh --verify` built, signed, and launched the app bundle.
- `./script/public_upload_audit.sh` passed.
- `bash -n script/benchmark_scan.sh` passed.
- `git diff --check` passed.
- `script/ci_performance_gate.sh` passed locally at 0.49s/29.2 MB and 0.53s/28.5 MB.
