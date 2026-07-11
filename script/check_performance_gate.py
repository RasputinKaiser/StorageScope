#!/usr/bin/env python3
"""Validate two StorageScope release benchmark reports without overfitting CI noise."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def field(text: str, label: str) -> str:
    match = re.search(rf"^{re.escape(label)}:\s*(.+)$", text, re.MULTILINE)
    if not match:
        raise ValueError(f"missing benchmark field: {label}")
    return match.group(1).strip()


def integer(value: str) -> int:
    return int(value.replace(",", ""))


def memory_megabytes(value: str) -> float:
    match = re.fullmatch(r"([0-9.]+)\s*([KMGT])B", value)
    if not match:
        raise ValueError(f"unsupported memory value: {value}")
    amount = float(match.group(1))
    scale = {"K": 1 / 1024, "M": 1, "G": 1024, "T": 1024 * 1024}
    return amount * scale[match.group(2)]


def parse_report(path: Path) -> dict[str, float | int | str]:
    text = path.read_text(encoding="utf-8")
    retained, considered = re.fullmatch(
        r"([0-9,]+) retained / ([0-9,]+) considered",
        field(text, "Duplicate candidates"),
    ).groups()
    return {
        "configuration": field(text, "Build configuration"),
        "duration": float(field(text, "Duration").removesuffix("s")),
        "items": integer(field(text, "Items scanned")),
        "peak_memory_mb": memory_megabytes(field(text, "Peak memory")),
        "snapshots": integer(field(text, "Snapshots built")),
        "retained": integer(retained),
        "considered": integer(considered),
        "evictions": integer(field(text, "Duplicate evictions")),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("reports", nargs=2, type=Path)
    parser.add_argument("--minimum-items", type=int, default=10_000)
    parser.add_argument("--maximum-duration", type=float, default=5.0)
    parser.add_argument("--maximum-memory-mb", type=float, default=150.0)
    args = parser.parse_args()

    reports = [parse_report(path) for path in args.reports]
    failures: list[str] = []

    for index, report in enumerate(reports, start=1):
        if report["configuration"] != "release":
            failures.append(f"run {index}: configuration was {report['configuration']}, not release")
        if report["items"] < args.minimum_items:
            failures.append(f"run {index}: scanned only {report['items']} items")
        if report["peak_memory_mb"] > args.maximum_memory_mb:
            failures.append(
                f"run {index}: peak memory {report['peak_memory_mb']:.1f} MB exceeds "
                f"{args.maximum_memory_mb:.1f} MB"
            )
        if report["snapshots"] != 0:
            failures.append(f"run {index}: benchmark unexpectedly built snapshots")
        if report["retained"] > report["considered"]:
            failures.append(f"run {index}: retained candidates exceed considered candidates")
        maximum_possible_evictions = report["considered"] - report["retained"]
        if report["evictions"] > maximum_possible_evictions:
            failures.append(f"run {index}: duplicate eviction counter is internally inconsistent")

    durations = [float(report["duration"]) for report in reports]
    if all(duration > args.maximum_duration for duration in durations):
        failures.append(
            "both release runs exceeded the duration ceiling: "
            + ", ".join(f"{duration:.2f}s" for duration in durations)
        )

    print(
        "StorageScope performance gate: "
        + ", ".join(
            f"run {index}={report['duration']:.2f}s/{report['peak_memory_mb']:.1f}MB"
            for index, report in enumerate(reports, start=1)
        )
    )
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print("performance gate passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
