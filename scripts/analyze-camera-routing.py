"""Validate the current mediaserverd camera-routing session from stdin."""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime
import re
import statistics
import sys


SESSION_MARKER = "shared-frame reader initialized"
PRODUCTION_IDENTITY_RE = re.compile(
    r"^production identity pid=(?P<pid>\d+)\b.*$", re.MULTILINE
)
PRODUCTION_ROUTE_RE = re.compile(
    r"production replacement-count=(?P<count>\d+) route=(?P<route>\d+)"
)
REF_PREFIX_RE = re.compile(r"^\[(?P<pid>\d+)\]\[start=[^]]+\]\[(?P<time>\d\d:\d\d:\d\d\.\d{3})\] (?P<message>.*)$")
PREVIEW_EMIT_RE = re.compile(
    r"emitSampleBuffer video count=(?P<count>\d+).*route=camera-preview"
)
RENDER_WINDOW_RE = re.compile(
    r"replacement render window count=120 p50Ms=(?P<p50>[0-9.]+)"
)
PREVIEW_PERFORMANCE_RE = re.compile(
    r"preview replacement performance window count=(?P<count>\d+) "
    r"cacheHits=(?P<hits>\d+) renders=(?P<renders>\d+) "
    r"p50Ms=(?P<p50>[0-9.]+)"
)
SOURCE_SEQUENCE_RE = re.compile(r"rendered shared frame sequence=(?P<sequence>\d+)")


def _seconds(timestamp: str) -> float:
    parsed = datetime.strptime(timestamp, "%H:%M:%S.%f")
    return (
        parsed.hour * 3600
        + parsed.minute * 60
        + parsed.second
        + parsed.microsecond / 1_000_000
    )


def _latest_emit_burst(
    emits: list[tuple[float, int]], maximum_gap_seconds: float = 60.0
) -> list[tuple[float, int]]:
    bursts: list[list[tuple[float, int]]] = []
    for timestamp, count in emits:
        if not bursts:
            bursts.append([(timestamp, count)])
            continue
        previous_time, previous_count = bursts[-1][-1]
        gap = timestamp - previous_time
        if gap < 0:
            gap += 24 * 60 * 60
        if gap > maximum_gap_seconds or count <= previous_count:
            bursts.append([])
        bursts[-1].append((timestamp, count))
    return bursts[-1] if bursts else []


def analyze_preview_performance(
    text: str, production_pid: int | None, expect_static_source: bool
) -> int:
    rows: list[tuple[float, str]] = []
    available_pids: set[int] = set()
    for line in text.splitlines():
        match = REF_PREFIX_RE.match(line)
        if match is None:
            continue
        pid = int(match.group("pid"))
        available_pids.add(pid)
        if production_pid is None or pid == production_pid:
            rows.append((_seconds(match.group("time")), match.group("message")))

    failures: list[str] = []
    if production_pid is not None and production_pid not in available_pids:
        failures.append("requested-production-camera-session-missing")
    if not rows:
        failures.append("preview-reference-telemetry-missing")

    emits = []
    render_p50s = []
    performance_p50s = []
    cache_hits = 0
    performance_calls = 0
    performance_renders = 0
    source_sequences = []
    for timestamp, message in rows:
        if match := PREVIEW_EMIT_RE.search(message):
            emits.append((timestamp, int(match.group("count"))))
        if match := RENDER_WINDOW_RE.search(message):
            render_p50s.append(float(match.group("p50")))
        if match := PREVIEW_PERFORMANCE_RE.search(message):
            performance_calls += int(match.group("count"))
            cache_hits += int(match.group("hits"))
            performance_renders += int(match.group("renders"))
            performance_p50s.append(float(match.group("p50")))
        if match := SOURCE_SEQUENCE_RE.search(message):
            source_sequences.append(int(match.group("sequence")))

    preview_fps = 0.0
    emit_burst = _latest_emit_burst(emits)
    if len(emit_burst) >= 2:
        first_time, first_count = emit_burst[0]
        last_time, last_count = emit_burst[-1]
        elapsed = last_time - first_time
        if elapsed < 0:
            elapsed += 24 * 60 * 60
        if elapsed > 0 and last_count > first_count:
            preview_fps = (last_count - first_count) / elapsed
    if preview_fps <= 0:
        failures.append("preview-rate-telemetry-missing")

    if performance_p50s:
        processing_p50_ms = statistics.median(performance_p50s)
    elif render_p50s:
        processing_p50_ms = statistics.median(render_p50s)
    else:
        processing_p50_ms = 0.0
        failures.append("preview-processing-timing-missing")

    estimated_duty = preview_fps * processing_p50_ms / 1000.0
    if estimated_duty >= 0.50:
        failures.append("excessive-preview-processing-duty")

    cache_ratio = cache_hits / performance_calls if performance_calls else 0.0
    repeated_static_sequence = (
        (len(source_sequences) >= 2 and len(set(source_sequences)) == 1)
        or cache_hits > 0
    )
    if expect_static_source:
        if source_sequences and not repeated_static_sequence:
            failures.append("source-sequence-not-static")
        if cache_ratio < 0.90:
            failures.append("static-preview-cache-missing")

    selected_pid = production_pid
    if selected_pid is None and rows:
        matching_pids = [
            int(match.group("pid"))
            for line in text.splitlines()
            if (match := REF_PREFIX_RE.match(line)) is not None
        ]
        selected_pid = Counter(matching_pids).most_common(1)[0][0]

    print(f"VCAM_CAMERA_PREVIEW_PERFORMANCE={'RED' if failures else 'GREEN'}")
    print("failures=" + (",".join(failures) if failures else "none"))
    print(f"production_pid={selected_pid if selected_pid is not None else 'none'}")
    print(f"preview_fps={preview_fps:.2f}")
    print(f"processing_p50_ms={processing_p50_ms:.2f}")
    print(f"estimated_processing_duty={estimated_duty:.3f}")
    print(f"cache_hits={cache_hits}")
    print(f"performance_calls={performance_calls}")
    print(f"performance_renders={performance_renders}")
    print(f"cache_ratio={cache_ratio:.3f}")
    print(f"repeated_static_sequence={int(repeated_static_sequence)}")
    return 1 if failures else 0


def analyze_preview_only_listener(text: str, production_pid: int | None) -> int:
    identities = list(PRODUCTION_IDENTITY_RE.finditer(text))
    if not identities:
        print("VCAM_CAMERA_PREVIEW_ROUTING=RED")
        print("failures=no-production-camera-session")
        return 1

    sessions = []
    for index, identity in enumerate(identities):
        end = identities[index + 1].start() if index + 1 < len(identities) else len(text)
        session = text[identity.end():end]
        pid = int(identity.group("pid"))
        routes = [
            int(match.group("route"))
            for match in PRODUCTION_ROUTE_RE.finditer(session)
        ]
        if production_pid is None or pid == production_pid:
            sessions.append((len(routes), pid, routes))

    if not sessions:
        print("VCAM_CAMERA_PREVIEW_ROUTING=RED")
        print("failures=requested-production-camera-session-missing")
        return 1

    _, selected_pid, routes = max(sessions, key=lambda item: item[0])
    failures = []
    if not routes:
        failures.append("replacement-route-telemetry-missing")
    if 4 not in routes:
        failures.append("preview-route-missing")
    if 5 in routes:
        failures.append("recording-route-active-during-preview")

    mixed_presentation_transitions = sum(
        1
        for previous, current in zip(routes, routes[1:])
        if previous != current and {previous, current} == {4, 5}
    )
    if mixed_presentation_transitions:
        failures.append("mixed-preview-recording-presentations")

    counts = Counter(routes)
    total_transitions = sum(
        previous != current for previous, current in zip(routes, routes[1:])
    )
    transition_rate = total_transitions / max(len(routes) - 1, 1)
    route_counts = ",".join(
        f"{route}:{counts[route]}" for route in sorted(counts)
    ) or "none"

    print(f"VCAM_CAMERA_PREVIEW_ROUTING={'RED' if failures else 'GREEN'}")
    print("failures=" + (",".join(failures) if failures else "none"))
    print(f"production_pid={selected_pid}")
    print(f"samples={len(routes)}")
    print(f"route_counts={route_counts}")
    print(f"transitions={total_transitions}")
    print(f"transition_rate={transition_rate:.3f}")
    print(f"mixed_presentation_transitions={mixed_presentation_transitions}")
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--require-recording", action="store_true")
    parser.add_argument("--require-photo", action="store_true")
    parser.add_argument(
        "--preview-only-listener",
        action="store_true",
        help="validate production listener telemetry from a preview-only Camera session",
    )
    parser.add_argument(
        "--production-pid",
        type=int,
        help="select one cameracaptured PID from a multi-session listener log",
    )
    parser.add_argument(
        "--preview-performance",
        action="store_true",
        help="validate preview processing duty from the cameracaptured reference log",
    )
    parser.add_argument(
        "--expect-static-source",
        action="store_true",
        help="require repeated source frames to use the preview output cache",
    )
    args = parser.parse_args()

    text = sys.stdin.read()
    if args.preview_performance:
        return analyze_preview_performance(
            text, args.production_pid, args.expect_static_source
        )
    if args.preview_only_listener:
        return analyze_preview_only_listener(text, args.production_pid)

    if SESSION_MARKER not in text:
        print("VCAM_CAMERA_ROUTING=RED")
        print("reason=no-current-mediaserver-session")
        return 1

    session = text.rsplit(SESSION_MARKER, 1)[1]
    failures = []
    if "supported=0 allowed=1 route=" in session:
        failures.append("unsupported-routed-format")
    if "suppressing real sample after replacement failure" in session:
        failures.append("replacement-suppressed")
    if "compressed pixel transfer failed" in session:
        failures.append("compressed-transfer-failed")
    if "compressed replacement sample creation failed" in session:
        failures.append("replacement-sample-failed")
    if args.require_recording and "route=video-recording" not in session:
        failures.append("recording-route-missing")
    if args.require_photo and "route=still-photo" not in session:
        failures.append("photo-route-missing")

    print(f"VCAM_CAMERA_ROUTING={'RED' if failures else 'GREEN'}")
    print("failures=" + (",".join(failures) if failures else "none"))
    print(f"recording_route={int('route=video-recording' in session)}")
    print(f"photo_route={int('route=still-photo' in session)}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
