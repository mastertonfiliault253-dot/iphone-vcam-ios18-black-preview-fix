#!/usr/bin/env python3
"""Check that Camera keeps physical QR analysis beside a virtual preview."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys


SIGNATURE_RE = re.compile(
    r"output signature .*?outputName=(?P<output>.*?) "
    r"node=.*? nodeClass=(?P<class>.*?) nodeName=(?P<node>.*?) "
    r"size=.*? route=(?P<route>[^ ]+)"
)


def analyze(text: str) -> list[str]:
    preview_seen = False
    metadata_routes: list[str] = []
    detector_routes: list[str] = []
    for line in text.splitlines():
        match = SIGNATURE_RE.search(line)
        if match is None:
            continue
        output = match.group("output")
        node_class = match.group("class")
        node = match.group("node")
        route = match.group("route")
        if node_class == "BWPixelTransferNode" and node == "Preview Scaler":
            preview_seen = preview_seen or route == "camera-preview"
        if (
            node_class == "BWFanOutNode"
            and node == "Preview Splitter"
            and output == "MetadataObject"
        ):
            metadata_routes.append(route)
        if node_class == "BWMetadataDetectorGatingNode":
            detector_routes.append(route)

    failures: list[str] = []
    if not preview_seen:
        failures.append("Camera preview replacement route was not observed")
    if not metadata_routes:
        failures.append("Camera MetadataObject analysis input was not observed")
    elif any(route != "none" for route in metadata_routes):
        failures.append(
            "Camera MetadataObject analysis input must remain physical "
            f"(routes={','.join(sorted(set(metadata_routes)))})"
        )
    if detector_routes and any(route != "none" for route in detector_routes):
        failures.append("post-detection gating output must remain untouched")
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
    failures = analyze(text)
    if failures:
        for failure in failures:
            print(f"RED: {failure}")
        return 1
    print("GREEN: Camera preview receives VCAM pixels and QR analysis remains physical")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
