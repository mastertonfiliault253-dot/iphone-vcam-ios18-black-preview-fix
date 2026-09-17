#!/usr/bin/env python3
"""Detect the SpringBoard check-in watchdog incident in a diagnostics bundle."""

from __future__ import annotations

import argparse
import json
import pathlib
import sys


WATCHDOG_NEEDLE = "no successful checkins from SpringBoard"


def _springboard_crash_summary(path: pathlib.Path) -> str | None:
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        metadata = json.loads(lines[0])
        report = json.loads("\n".join(lines[1:]))
    except (OSError, IndexError, json.JSONDecodeError):
        return None

    exception = report.get("exception", {})
    termination = report.get("termination", {})
    faulting_thread = report.get("faultingThread")
    top_frame = "unknown"
    threads = report.get("threads", [])
    if isinstance(faulting_thread, int) and 0 <= faulting_thread < len(threads):
        frames = threads[faulting_thread].get("frames", [])
        if frames:
            top_frame = frames[0].get("symbol", "unknown")
    return (
        f"{metadata.get('timestamp', path.name)} "
        f"{exception.get('type', 'unknown')}/{exception.get('signal', 'unknown')} "
        f"termination={termination.get('namespace', 'unknown')}/"
        f"{termination.get('code', 'unknown')} top={top_frame}"
    )


def analyze(root: pathlib.Path) -> tuple[list[str], list[str]]:
    failures: list[str] = []
    evidence: list[str] = []

    panic_files = sorted(root.glob("userspace-panic-*.ips"))
    matching_panics: list[pathlib.Path] = []
    for path in panic_files:
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if WATCHDOG_NEEDLE in text:
            matching_panics.append(path)
            first_line = next(
                (line.strip() for line in text.splitlines() if WATCHDOG_NEEDLE in line),
                WATCHDOG_NEEDLE,
            )
            failures.append(f"{path.name}: {first_line}")

    for path in sorted(root.glob("SpringBoard-*.ips")):
        summary = _springboard_crash_summary(path)
        if summary is not None:
            evidence.append(summary)

    inject_log = root / "vcaminjectd.log"
    if inject_log.exists():
        text = inject_log.read_text(encoding="utf-8", errors="replace")
        if "target=SpringBoard" in text and "proof=1" in text:
            evidence.append("vcaminjectd recorded SpringBoard proof=1")

    if matching_panics and not evidence:
        evidence.append("no parseable SpringBoard crash report in bundle")
    return failures, evidence


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("diagnostics", type=pathlib.Path)
    args = parser.parse_args(argv)
    if not args.diagnostics.is_dir():
        print(f"ERROR: diagnostics directory not found: {args.diagnostics}", file=sys.stderr)
        return 2

    failures, evidence = analyze(args.diagnostics)
    for item in evidence:
        print(f"EVIDENCE: {item}")
    if failures:
        for failure in failures:
            print(f"RED: {failure}")
        return 1
    print("GREEN: no SpringBoard check-in watchdog panic found")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
