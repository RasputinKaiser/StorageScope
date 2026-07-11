#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CONFIGURATION="release"
ARGS=()

while (($#)); do
  case "$1" in
    --debug)
      CONFIGURATION="debug"
      ;;
    *)
      ARGS+=("$1")
      ;;
  esac
  shift
done

STORAGESCOPE_BENCHMARK_CONFIGURATION="$CONFIGURATION" swift run -c "$CONFIGURATION" StorageScopeBenchmark "${ARGS[@]}"
