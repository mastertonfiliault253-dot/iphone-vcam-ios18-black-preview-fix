"""Create a VCAM preference plist without depending on macOS plutil."""

from __future__ import annotations

import argparse
import json
import plistlib
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path("com.codex.vcam.plist"))
    parser.add_argument("--source", choices=("camera", "local", "obs", "rtsp"), required=True)
    parser.add_argument("--media-path")
    parser.add_argument("--depth-image-path")
    parser.add_argument("--live-photo-still-path")
    parser.add_argument("--live-photo-movie-path")
    parser.add_argument("--metadata-json", type=Path, help="JSON object merged into AVCapturePhoto metadata")
    parser.add_argument("--obs-url")
    parser.add_argument("--rtsp-url")
    parser.add_argument("--audio", action="store_true")
    parser.add_argument("--no-loop", action="store_true")
    parser.add_argument("--mirror", action="store_true")
    parser.add_argument("--rotation", type=int, choices=(0, 90, 180, 270), default=0)
    parser.add_argument("--content-mode", choices=("fit", "fill", "stretch"), default="fill")
    parser.add_argument("--fps", type=int, choices=range(1, 61), default=30, metavar="1..60")
    parser.add_argument("--local-decoder", choices=("triple", "single"), default="single")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.source == "local" and not args.media_path:
        raise SystemExit("--media-path is required for --source local")
    if args.source == "obs" and not args.obs_url:
        raise SystemExit("--obs-url is required for --source obs")
    if args.source == "rtsp" and not args.rtsp_url:
        raise SystemExit("--rtsp-url is required for --source rtsp")
    values = {
        "enabled": args.source != "camera",
        "source": args.source,
        "replaceAudio": args.audio,
        "loopMedia": not args.no_loop,
        "mirrorHorizontally": args.mirror,
        "rotationDegrees": args.rotation,
        "contentMode": args.content_mode,
        "preferredFramesPerSecond": args.fps,
        "localDecoderMode": args.local_decoder,
    }
    if args.media_path:
        values["mediaPath"] = args.media_path
    if args.depth_image_path:
        values["depthImagePath"] = args.depth_image_path
    if bool(args.live_photo_still_path) != bool(args.live_photo_movie_path):
        raise SystemExit("Live Photo replacement requires both paired paths")
    if args.live_photo_still_path:
        values["livePhotoStillPath"] = args.live_photo_still_path
        values["livePhotoMoviePath"] = args.live_photo_movie_path
    if args.obs_url:
        values["obsWebSocketURL"] = args.obs_url
    if args.rtsp_url:
        values["rtspURL"] = args.rtsp_url
    if args.metadata_json:
        metadata = json.loads(args.metadata_json.read_text(encoding="utf-8"))
        if not isinstance(metadata, dict):
            raise SystemExit("--metadata-json must contain a JSON object")
        values["photoMetadata"] = metadata
    args.output.write_bytes(plistlib.dumps(values, fmt=plistlib.FMT_XML, sort_keys=True))
    print(args.output.resolve())


if __name__ == "__main__":
    main()
