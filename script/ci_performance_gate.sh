#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/storagescope-perf-gate.XXXXXX")"
FIXTURE=""
cleanup() {
  [[ -z "$FIXTURE" ]] || rm -rf "$FIXTURE"
  rm -rf "$OUTPUT_DIR"
}
trap cleanup EXIT

swift build -c release --product StorageScopeBenchmark
BIN="$(swift build -c release --show-bin-path)/StorageScopeBenchmark"

"$BIN" --synthetic --items 10000 --depth 5 --duplicates 0.1 --keep-fixture > "$OUTPUT_DIR/fixture.txt"
FIXTURE="$(sed -n 's/^Synthetic fixture: //p' "$OUTPUT_DIR/fixture.txt" | head -1)"
[[ -d "$FIXTURE" ]] || { echo "failed to create benchmark fixture" >&2; exit 1; }

"$BIN" "$FIXTURE" > "$OUTPUT_DIR/run1.txt"
"$BIN" "$FIXTURE" > "$OUTPUT_DIR/run2.txt"

python3 script/check_performance_gate.py "$OUTPUT_DIR/run1.txt" "$OUTPUT_DIR/run2.txt"
