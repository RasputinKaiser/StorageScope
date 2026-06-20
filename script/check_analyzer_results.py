#!/usr/bin/env python3
import json
import sys

if len(sys.argv) != 2:
    print("usage: check_analyzer_results.py <analysis.json>", file=sys.stderr)
    sys.exit(2)

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    document = json.load(handle)

findings = []
stack = [document]
while stack:
    node = stack.pop()
    if isinstance(node, dict):
        if node.get("_name") == "IssueSummary" and node.get("issueType") == "Static Analyzer":
            findings.append(node.get("message", "<no message>"))
        stack.extend(node.values())
    elif isinstance(node, list):
        stack.extend(node)

if not findings:
    print("No static analyzer findings.")
    sys.exit(0)

print(f"Static analyzer found {len(findings)} issue(s):", file=sys.stderr)
for message in findings[:10]:
    print(f"  - {message}", file=sys.stderr)
sys.exit(1)