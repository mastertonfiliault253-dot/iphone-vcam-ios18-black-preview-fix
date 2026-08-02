"""Classify the on-device VCAM capture replacement failure."""

from __future__ import annotations

import argparse


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--photo-request", type=int, required=True)
    parser.add_argument("--photo-callback", type=int, required=True)
    parser.add_argument("--recording-start", type=int, required=True)
    parser.add_argument("--recording-finish", type=int, required=True)
    parser.add_argument("--photo-output", choices=("replacement", "real"), required=True)
    parser.add_argument("--recording-output", choices=("replacement", "real"), required=True)
    args = parser.parse_args()

    red = args.photo_output == "real" or args.recording_output == "real"
    photo_path = "public_hook_not_reached" if args.photo_request == 0 and args.photo_callback == 0 else "public_hook_reached"
    recording_path = (
        "completion_hook_reached_but_output_unreplaced"
        if args.recording_start > 0 and args.recording_finish > 0 and args.recording_output == "real"
        else "completion_hook_not_fully_reached"
    )
    print(f"VCAM_CAPTURE_VERDICT={'RED' if red else 'GREEN'}")
    print(f"photo_path={photo_path}")
    print(f"recording_path={recording_path}")
    print(
        "counts="
        f"photo_request:{args.photo_request},photo_callback:{args.photo_callback},"
        f"recording_start:{args.recording_start},recording_finish:{args.recording_finish}"
    )
    return 1 if red else 0


if __name__ == "__main__":
    raise SystemExit(main())
