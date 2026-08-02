"""Turn tagged on-device VCAM diagnostics into a red/green bug verdict."""

from __future__ import annotations

import argparse
import re
import statistics
from pathlib import Path


ASSET_RE = re.compile(
    r"\[DEBUG-vcamdiag\] asset natural=(?P<width>[\d.]+)x(?P<height>[\d.]+).*?"
    r"angle=(?P<angle>-?[\d.]+).*?configRotation=(?P<rotation>-?\d+).*?"
    r"requestedFps=(?P<fps>\d+)"
)
PERF_RE = re.compile(r"\[DEBUG-vcamdiag\] perf (?P<fields>.*)$")
FIELD_RE = re.compile(r"(?P<key>[A-Za-z]+)=(?P<value>[^\s]+)")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--orientation-observed", choices=("correct", "upside-down"), required=True)
    parser.add_argument("--choppy-observed", choices=("yes", "no"), required=True)
    return parser.parse_args()


def numeric(rows: list[dict[str, str]], key: str) -> list[float]:
    values: list[float] = []
    for row in rows:
        try:
            values.append(float(row[key]))
        except (KeyError, ValueError):
            pass
    return values


def median(values: list[float]) -> float:
    return statistics.median(values) if values else 0.0


def main() -> int:
    args = parse_args()
    text = args.log.read_text(encoding="utf-8", errors="replace")
    asset_match = ASSET_RE.search(text)
    rows: list[dict[str, str]] = []
    for line in text.splitlines():
        match = PERF_RE.search(line)
        if match:
            rows.append({item.group("key"): item.group("value") for item in FIELD_RE.finditer(match.group("fields"))})
    if asset_match is None or not rows:
        print("VCAM_DIAG_VERDICT=ERROR")
        print(f"asset_record={asset_match is not None} perf_windows={len(rows)}")
        return 2

    asset = asset_match.groupdict()
    natural_width = float(asset["width"])
    natural_height = float(asset["height"])
    angle = float(asset["angle"])
    requested_fps = float(asset["fps"])
    source_match = re.match(r"(?P<w>\d+)x(?P<h>\d+)", rows[-1].get("source", ""))
    source_width = float(source_match.group("w")) if source_match else 0.0
    source_height = float(source_match.group("h")) if source_match else 0.0
    quarter_turn_metadata = abs(abs(angle) - 90.0) < 2.0
    player_output_is_already_swapped = (
        source_width > 0
        and abs(source_width - natural_height) <= 2
        and abs(source_height - natural_width) <= 2
    )

    windows = numeric(rows, "window")
    new_frames = numeric(rows, "newFrames")
    misses = numeric(rows, "misses")
    reconfigs = numeric(rows, "reconfigs")
    switches = numeric(rows, "templateSwitches")
    render_avg = numeric(rows, "renderAvgMs")
    render_max = numeric(rows, "renderMaxMs")
    item_advance = numeric(rows, "itemAdvance")
    cadence = median([frames / window for frames, window in zip(new_frames, windows) if window > 0])
    speed_ratio = median([advance / window for advance, window in zip(item_advance, windows) if window > 0])
    callback_misses = sum(misses)
    format_thrash = median(reconfigs) >= 2 or median(switches) >= 2
    cadence_low = cadence < requested_fps * 0.75
    media_clock_slow = speed_ratio < 0.82
    frame_budget_ms = 1000.0 / max(1.0, requested_fps)
    renderer_over_budget = max(render_max, default=0.0) > frame_budget_ms

    exact_symptom_red = args.orientation_observed == "upside-down" or args.choppy_observed == "yes"
    print(f"VCAM_DIAG_VERDICT={'RED' if exact_symptom_red else 'GREEN'}")
    print(f"perf_windows={len(rows)} requested_fps={requested_fps:.0f} decoded_fps_median={cadence:.2f}")
    print(f"media_clock_ratio_median={speed_ratio:.3f} callback_misses={callback_misses:.0f}")
    print(f"output_reconfigs_median={median(reconfigs):.1f} template_switches_median={median(switches):.1f}")
    print(f"render_avg_ms_median={median(render_avg):.3f} render_max_ms={max(render_max, default=0.0):.3f}")
    print(f"asset_angle={angle:.1f} natural={natural_width:.0f}x{natural_height:.0f} player_output={source_width:.0f}x{source_height:.0f}")
    print(f"orientation_double_transform_evidence={quarter_turn_metadata and player_output_is_already_swapped}")
    print(f"format_thrash={format_thrash} cadence_low={cadence_low} media_clock_slow={media_clock_slow} renderer_over_budget={renderer_over_budget}")
    print(f"observed_orientation={args.orientation_observed} observed_choppy={args.choppy_observed}")
    return 1 if exact_symptom_red else 0


if __name__ == "__main__":
    raise SystemExit(main())
