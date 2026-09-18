"""Validate that dynamic stream decoders stop when camera consumers disappear."""

from __future__ import annotations

import argparse
from datetime import datetime
import re
import sys


APP_LOG_RE = re.compile(
    r"^\[(?P<time>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\]"
    r"\[[^]]+\] (?P<message>.*)$"
)


def _parse_time(value: str) -> datetime:
    return datetime.strptime(value, "%Y-%m-%d %H:%M:%S.%f")


def analyze(text: str, source: str) -> int:
    if source == "hls":
        start_marker = "springboard HLS start "
        suspend_marker = "springboard HLS suspended no consumer"
        resume_marker = "springboard HLS resumed for consumer"
        activity_markers = ("springboard HLS health ", "springboard HLS frame ")
    else:
        start_marker = "vcamd RTSP source started for consumer"
        suspend_marker = "vcamd RTSP source suspended no consumer"
        resume_marker = "vcamd RTSP source resumed for consumer"
        # Product logs use the lower-case source name for decode, network,
        # reconnect, and performance activity. Any such line after the final
        # suspension proves the FFmpeg session did not actually become idle.
        activity_markers = ("rtsp ",)

    rows: list[tuple[datetime, str]] = []
    for line in text.splitlines():
        match = APP_LOG_RE.match(line)
        if match is not None:
            rows.append((_parse_time(match.group("time")), match.group("message")))

    resume_stalls = 0
    if source == "hls":
        waiting_for_resumed_playback = False
        for _, message in rows:
            if start_marker in message or suspend_marker in message:
                waiting_for_resumed_playback = False
            elif resume_marker in message:
                waiting_for_resumed_playback = True
            elif waiting_for_resumed_playback and (
                "springboard HLS frame decoded=" in message
                or (
                    "springboard HLS health " in message
                    and "timeControl=2" in message
                )
            ):
                waiting_for_resumed_playback = False
            elif (
                waiting_for_resumed_playback
                and "springboard HLS reconnect " in message
                and "springboard HLS stalled" in message
            ):
                resume_stalls += 1
                waiting_for_resumed_playback = False

    start_indexes = [index for index, (_, message) in enumerate(rows) if start_marker in message]
    failures: list[str] = []
    if resume_stalls:
        failures.append("hls-resume-stall")
    if not start_indexes:
        failures.append(f"{source}-start-missing")
        session: list[tuple[datetime, str]] = []
    else:
        session = rows[start_indexes[-1] :]

    suspensions = [(timestamp, message) for timestamp, message in session if suspend_marker in message]
    resumes = [(timestamp, message) for timestamp, message in session if resume_marker in message]
    transitions = [
        (timestamp, "suspend" if suspend_marker in message else "resume")
        for timestamp, message in session
        if suspend_marker in message or resume_marker in message
    ]
    activity = [
        (timestamp, message)
        for timestamp, message in session
        if any(marker in message for marker in activity_markers)
    ]

    if session and not suspensions:
        failures.append(f"{source}-consumer-suspension-missing")
    if transitions and transitions[-1][1] != "suspend":
        failures.append(f"{source}-left-active")

    activity_after_suspend = 0
    latest_suspend = suspensions[-1][0] if suspensions else None
    if latest_suspend is not None:
        activity_after_suspend = sum(timestamp > latest_suspend for timestamp, _ in activity)
        if activity_after_suspend:
            failures.append(f"{source}-activity-after-suspension")

    active_seconds_before_suspend = 0.0
    if session and latest_suspend is not None:
        active_seconds_before_suspend = max(
            0.0, (latest_suspend - session[0][0]).total_seconds()
        )

    label = source.upper()
    print(f"VCAM_{label}_LIFECYCLE={'RED' if failures else 'GREEN'}")
    print("failures=" + (",".join(failures) if failures else "none"))
    print(f"starts={len(start_indexes)}")
    print(f"suspensions={len(suspensions)}")
    print(f"resumes={len(resumes)}")
    print(f"resume_stalls={resume_stalls}")
    print(f"activity_after_suspend={activity_after_suspend}")
    print(f"active_seconds_before_suspend={active_seconds_before_suspend:.3f}")
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", choices=("hls", "rtsp"), required=True)
    args = parser.parse_args()
    return analyze(sys.stdin.read(), args.source)


if __name__ == "__main__":
    raise SystemExit(main())
