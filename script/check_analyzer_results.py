#!/usr/bin/env python3
import json
import sys

if len(sys.argv) != 2:
    print("usage: check_analyzer_results.py <build-results.json>", file=sys.stderr)
    sys.exit(2)

# Modern xcresulttool (post-deprecation) emits a flat JSON via
# `xcrun xcresulttool get build-results --path <bundle>`. The analyzer
# findings live in `analyzerWarnings`; the legacy `IssueSummary` graph
# shape is gone and the old `get object` subcommand prints a deprecation
# warning that fails CI under set -e.
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    document = json.load(handle)

findings = document.get("analyzerWarnings") or []
if not findings:
    print("No static analyzer findings.")
    sys.exit(0)

print(f"Static analyzer found {len(findings)} issue(s):", file=sys.stderr)
for finding in findings[:10]:
    print(f"  - {finding.get('message') or finding}", file=sys.stderr)
sys.exit(1)