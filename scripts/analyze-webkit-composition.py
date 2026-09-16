#!/usr/bin/env python3
"""Validate bounded VCAM composition telemetry without exporting pixels."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys
from dataclasses import dataclass


LINE_RE = re.compile(
    r"composition diagnostic presentation=(?P<presentation>webkit|still) "
    r"count=(?P<count>\d+) source=(?P<source_w>[0-9.]+)x(?P<source_h>[0-9.]+) "
    r"oriented=(?P<oriented_w>[0-9.]+)x(?P<oriented_h>[0-9.]+) "
    r"target=(?P<target_w>\d+)x(?P<target_h>\d+) front=(?P<front>[01]) "
    r"rotate=(?P<rotate>[01]) mirror=(?P<mirror>[01]) fit=(?P<fit>[01]) "
    r"scale=(?P<scale>[0-9.]+) coverage=(?P<coverage_w>[0-9.]+)x"
    r"(?P<coverage_h>[0-9.]+)"
)


@dataclass(frozen=True)
class Composition:
    presentation: str
    count: int
    source_w: float
    source_h: float
    target_w: int
    target_h: int
    front: bool
    rotate: bool
    mirror: bool
    fit: bool
    scale: float
    coverage_w: float
    coverage_h: float


def parse_compositions(text: str) -> list[Composition]:
    records: list[Composition] = []
    for match in LINE_RE.finditer(text):
        values = match.groupdict()
        records.append(
            Composition(
                presentation=values["presentation"],
                count=int(values["count"]),
                source_w=float(values["source_w"]),
                source_h=float(values["source_h"]),
                target_w=int(values["target_w"]),
                target_h=int(values["target_h"]),
                front=values["front"] == "1",
                rotate=values["rotate"] == "1",
                mirror=values["mirror"] == "1",
                fit=values["fit"] == "1",
                scale=float(values["scale"]),
                coverage_w=float(values["coverage_w"]),
                coverage_h=float(values["coverage_h"]),
            )
        )
    return records


def validate(records: list[Composition]) -> list[str]:
    failures: list[str] = []
    webkit = [record for record in records if record.presentation == "webkit"]
    if not webkit:
        failures.append("missing WebKit composition telemetry")
    for record in records:
        label = f"{record.presentation}#{record.count}"
        if record.fit:
            failures.append(f"{label} unexpectedly used aspect-fit")
        if record.coverage_w + 0.11 < record.target_w:
            failures.append(
                f"{label} horizontal coverage {record.coverage_w} < {record.target_w}"
            )
        if record.coverage_h + 0.11 < record.target_h:
            failures.append(
                f"{label} vertical coverage {record.coverage_h} < {record.target_h}"
            )
        if record.presentation == "webkit":
            if record.front != record.mirror:
                failures.append(
                    f"{label} front={int(record.front)} mirror={int(record.mirror)}"
                )
            orientation_differs = (
                record.source_h > record.source_w
                and record.target_w > record.target_h
            )
            if record.rotate != orientation_differs:
                failures.append(
                    f"{label} rotate={int(record.rotate)} expected={int(orientation_differs)}"
                )
        elif record.mirror:
            failures.append(f"{label} still-photo path was mirrored")
    return failures


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("log", type=pathlib.Path)
    args = parser.parse_args(argv)
    try:
        text = args.log.read_text(encoding="utf-8", errors="replace")
    except OSError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2

    records = parse_compositions(text)
    failures = validate(records)
    webkit_count = sum(record.presentation == "webkit" for record in records)
    still_count = sum(record.presentation == "still" for record in records)
    print(f"records={len(records)} webkit={webkit_count} still={still_count}")
    if failures:
        for failure in failures:
            print(f"RED: {failure}")
        return 1
    print("GREEN: negotiated fill covers every target and mirror/rotation are scoped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
