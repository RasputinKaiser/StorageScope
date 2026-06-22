# v0.5.2 Performance Baselines

Captured on the v0.5.3 measurement slice (HEAD-of-main after the signpost/scaling
work). Signposts are no-ops when no profiler is attached, so the timing aligns with
the v0.5.2 release behavior for the phases already instrumented in v0.5.0 (#81).

## Fixture sizes captured

| File | Items | Total size | Duration (wall) | Phase total | Peak memory |
|---|---:|---:|---:|---:|---:|
| `curated.txt` | 24 | 1.11 GB | 0.01s | 0.01s | 16.5 MB |
| `10k.txt` | 10,353 | 687.3 MB | 6.90s | 6.90s | 52.8 MB |
| `100k.txt` | 105,277 | 7.16 GB | 185.51s | 185.51s | 271.8 MB |

500k fixture skipped on this dev machine: at the 100k rate it would need ~36 GB
disk and ~15 min runtime, and the system volume has ~33 GB free (2026-06-22). Run
500k from a machine with ≥50 GB free disk so the timing isn't skewed by APFS
read-timeouts under pressure (see committed memory note
`project_disk_full_fs_timeouts.md`).

## How to regenerate

```bash
swift run StorageScopeBenchmark --synthetic --show-full-path > docs/perf-baselines/v0.5.2/curated.txt

# Scaled fixtures need explicit item count:
swift run StorageScopeBenchmark --synthetic --items 10000 --depth 5 --duplicates 0.1 --show-full-path \
    > docs/perf-baselines/v0.5.2/10k.txt
swift run StorageScopeBenchmark --synthetic --items 100000 --depth 8 --duplicates 0.05 --show-full-path \
    > docs/perf-baselines/v0.5.2/100k.txt
```

## Validation thresholds (per PLAN.md §6.3)

Each subsequent optimization slice validates against these baselines. If the
target signpost's contribution to `totalDuration` falls below 5% after a code
change, the change is reverted as not the bottleneck. If it crosses 20%,
promote the corresponding P-1..P-23 proposal to the next v0.5.x slice.

Decision rules — verify against the **largest fixture your machine can run**
before promoting a proposal. The 100k baseline is the floor for evidence;
an optimization that "looks 5% faster" on the 10k fixture is not real signal.

## Results are local only

Per `ScanBenchmarkReport.text`, "Results are local only." Baseline files contain
fixture-instance paths (under `$TMPDIR`), not real user data. Safe to commit.