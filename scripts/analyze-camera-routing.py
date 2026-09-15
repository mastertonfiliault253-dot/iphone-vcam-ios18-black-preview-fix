"""Validate the current mediaserverd camera-routing session from stdin."""

from __future__ import annotations

import argparse
from collections import Counter
import re
import sys


SESSION_MARKER = "shared-frame reader initialized"
PRODUCTION_IDENTITY_RE = re.compile(
    r"^production identity pid=(?P<pid>\d+)\b.*$", re.MULTILINE
)
PRODUCTION_ROUTE_RE = re.compile(
    r"production replacement-count=(?P<count>\d+) route=(?P<route>\d+)"
)


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
    args = parser.parse_args()

    text = sys.stdin.read()
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
