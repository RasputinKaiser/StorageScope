# Phase 4 duplicate-verification proof fixture

Date: 2026-07-13
Commit base: `4fa1213` (post-Phase-3 `main`)
Machine: Apple silicon Mac
Build: Swift release
Regime: freshly generated local temporary fixture; run 1 cold hash cache, run 2
persisted warm hash cache

Command:

```sh
./script/benchmark_scan.sh --duplicate-proof --repeat 2
```

The reusable corpus contains 48 same-size early-diverging media, DMG, and VM
files, one exact-copy pair, one same-prefix/different-tail collision pair, and one
hard-link pair. It is 202.2 MB across 54 duplicate candidates. The naive baseline
is the sum of every candidate byte that a full-hash-only verifier would read.

| Measurement | Cold run | Warm persisted-cache run |
|---|---:|---:|
| Duration | 0.02 s | 0.01 s |
| Naive full-hash bytes | 202.2 MB | 202.2 MB |
| Verification bytes read | 4.4 MB | 3.1 MB |
| Byte reduction | 97.83% | 98.44% |
| Peak open verification files | 3 | 1 |
| Verified groups | 2 | 2 |
| Peak RSS | 18.5 MB | 22.3 MB |

The cold byte-reduction target and six-reader descriptor ceiling pass on this
fixture. The warm run is near-instant, but it still reads 3,145,728 bytes because
prefix digests are not persisted yet.

The focused acceptance suite is:

```sh
swift test --scratch-path /tmp/storagescope-phase4-proof-focused \
  --disable-index-store --jobs 1 --filter DuplicateVerificationProofTests
```

It passes with four recorded known-issue assertions covering three open Phase 4
gaps:

- hard-link aliases remain in candidate and verified groups;
- a cold-process warm cache still reads the 48 large-file prefixes;
- a file whose modification time changes after enumeration and before hashing is
  still accepted.

Cancellation propagates as `FileSystemScannerError.cancelled` without returning a
partial group. The mutation proof currently covers the enumeration-to-hash
boundary; deterministic mutation during an active read remains part of the Phase 4
implementation tranche. Corrupt-cache quarantine, versioned/batched persistence,
raw digests, reusable buffers, and volume-aware read sizing are not claimed by this
fixture-only tranche.
