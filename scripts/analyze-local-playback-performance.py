"""Score on-device VCAM local-video playback against a fixed frame budget."""

from __future__ import annotations

import argparse
import re
import statistics
from pathlib import Path


PERF_RE = re.compile(r"\[DEBUG-vcamdiag\] perf (?P<fields>.*)$")
FIELD_RE = re.compile(r"(?P<key>[A-Za-z][A-Za-z0-9]*)=(?P<value>[^\s]+)")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--minimum-windows", type=int, default=5)
    parser.add_argument("--minimum-fps", type=float, default=27.0)
    parser.add_argument("--maximum-p95-ms", type=float, default=50.0)
    parser.add_argument("--minimum-clock-ratio", type=float, default=0.95)
    return parser.parse_args()


def as_float(row: dict[str, str], key: str) -> float | None:
    try:
        return float(row[key])
    except (KeyError, ValueError):
        return None


def main() -> int:
    args = parse_args()
    rows: list[dict[str, str]] = []
    for line in args.log.read_text(encoding="utf-8", errors="replace").splitlines():
        match = PERF_RE.search(line)
        if match:
            rows.append({m.group("key"): m.group("value") for m in FIELD_RE.finditer(match.group("fields"))})

    usable = []
    for row in rows:
        window = as_float(row, "window")
        frames = as_float(row, "sourceFrames")
        p95 = as_float(row, "sourceFrameP95Ms")
        advance = as_float(row, "itemAdvance")
        if window and window > 0 and frames is not None and p95 is not None and advance is not None:
            usable.append((row, window, frames, p95, advance))

    if len(usable) < args.minimum_windows:
        print("VCAM_LOCAL_PERF_VERDICT=ERROR")
        print(f"perf_windows={len(rows)} usable_windows={len(usable)} required={args.minimum_windows}")
        return 2

    total_window = sum(item[1] for item in usable)
    total_frames = sum(item[2] for item in usable)
    measured_fps = total_frames / total_window
    p95_ms = max(item[3] for item in usable)
    clock_ratios = [item[4] / item[1] for item in usable]
    clock_ratio = statistics.median(clock_ratios)
    modes = sorted({item[0].get("decoderMode", "unknown") for item in usable})
    dropped = sum(as_float(item[0], "droppedSourceFrames") or 0 for item in usable)

    green = (
        measured_fps >= args.minimum_fps
        and p95_ms <= args.maximum_p95_ms
        and clock_ratio >= args.minimum_clock_ratio
    )
    print(f"VCAM_LOCAL_PERF_VERDICT={'GREEN' if green else 'RED'}")
    print(f"decoder_modes={','.join(modes)} windows={len(usable)}")
    print(f"source_fps={measured_fps:.2f} source_frame_p95_ms={p95_ms:.2f}")
    print(f"media_clock_ratio_median={clock_ratio:.3f} dropped_source_frames={dropped:.0f}")
    print(
        f"thresholds=min_fps:{args.minimum_fps:.2f},"
        f"max_p95_ms:{args.maximum_p95_ms:.2f},min_clock_ratio:{args.minimum_clock_ratio:.3f}"
    )
    return 0 if green else 1


if __name__ == "__main__":
    raise SystemExit(main())
