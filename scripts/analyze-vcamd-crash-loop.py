#!/usr/bin/env python3
"""Detect the vcamd producer-queue self-dispatch crash behind HLS blackouts."""

from __future__ import annotations

import argparse
import collections
import json
import pathlib
import sys
from typing import Any


PROCESS = "vcamd"
PRODUCER_QUEUE = "com.codex.vcamd.producer"
SELF_SYNC_NEEDLE = "dispatch_sync called on queue already owned by current thread"


def _load_report(path: pathlib.Path) -> tuple[dict[str, Any], dict[str, Any]] | None:
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        metadata = json.loads(lines[0])
        report = json.loads("\n".join(lines[1:]))
    except (OSError, IndexError, json.JSONDecodeError):
        return None
    if not isinstance(metadata, dict) or not isinstance(report, dict):
        return None
    return metadata, report


def _matches(metadata: dict[str, Any], report: dict[str, Any]) -> bool:
    process = report.get("procName") or metadata.get("app_name")
    exception = report.get("exception", {})
    if (
        process != PROCESS
        or exception.get("type") != "EXC_BREAKPOINT"
        or exception.get("signal") != "SIGTRAP"
    ):
        return False

    faulting_thread = report.get("faultingThread")
    threads = report.get("threads", [])
    if not isinstance(faulting_thread, int) or not 0 <= faulting_thread < len(threads):
        return False
    if threads[faulting_thread].get("queue") != PRODUCER_QUEUE:
        return False

    asi = report.get("asi", {})
    messages = asi.get("libdispatch.dylib", []) if isinstance(asi, dict) else []
    if isinstance(messages, str):
        messages = [messages]
    return any(SELF_SYNC_NEEDLE in message for message in messages)


def _app_offsets(report: dict[str, Any]) -> list[int]:
    faulting_thread = report.get("faultingThread")
    threads = report.get("threads", [])
    if not isinstance(faulting_thread, int) or not 0 <= faulting_thread < len(threads):
        return []
    offsets: list[int] = []
    for frame in threads[faulting_thread].get("frames", []):
        offset = frame.get("imageOffset")
        if frame.get("imageIndex") == 1 and isinstance(offset, int):
            offsets.append(offset)
    return offsets


def analyze(root: pathlib.Path) -> tuple[list[str], dict[str, Any]]:
    matching_reports = 0
    incidents: set[str] = set()
    timestamps: list[str] = []
    offsets: collections.Counter[int] = collections.Counter()

    for path in sorted(root.glob("vcamd-*.ips")):
        parsed = _load_report(path)
        if parsed is None:
            continue
        metadata, report = parsed
        if not _matches(metadata, report):
            continue
        matching_reports += 1
        incident = metadata.get("incident_id")
        incidents.add(str(incident) if incident else path.name)
        timestamp = metadata.get("timestamp")
        if timestamp:
            timestamps.append(str(timestamp))
        offsets.update(_app_offsets(report))

    evidence: dict[str, Any] = {
        "matching_incidents": len(incidents),
        "matching_reports": matching_reports,
        "first_timestamp": min(timestamps) if timestamps else None,
        "last_timestamp": max(timestamps) if timestamps else None,
        "top_app_offsets": [offset for offset, _ in offsets.most_common(6)],
    }
    failures = ["producer-queue-self-dispatch-sync"] if matching_reports else []
    return failures, evidence


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("diagnostics", type=pathlib.Path)
    args = parser.parse_args(argv)
    if not args.diagnostics.is_dir():
        print(f"ERROR: diagnostics directory not found: {args.diagnostics}", file=sys.stderr)
        return 2

    failures, evidence = analyze(args.diagnostics)
    print(f"matching_reports={evidence['matching_reports']}")
    print(f"matching_incidents={evidence['matching_incidents']}")
    if evidence["first_timestamp"]:
        print(f"window={evidence['first_timestamp']} .. {evidence['last_timestamp']}")
    if evidence["top_app_offsets"]:
        print("app_offsets=" + ",".join(str(item) for item in evidence["top_app_offsets"]))
    if failures:
        print("VCAM_VCAMD_CRASH_LOOP=RED")
        print("failure=" + ",".join(failures))
        return 1
    print("VCAM_VCAMD_CRASH_LOOP=GREEN")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
