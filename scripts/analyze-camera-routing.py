"""Validate the current mediaserverd camera-routing session from stdin."""

from __future__ import annotations

import argparse
import sys


SESSION_MARKER = "shared-frame reader initialized"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--require-recording", action="store_true")
    parser.add_argument("--require-photo", action="store_true")
    args = parser.parse_args()

    text = sys.stdin.read()
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
