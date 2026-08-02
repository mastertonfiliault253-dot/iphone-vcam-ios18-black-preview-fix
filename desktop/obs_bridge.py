"""Send OBS Virtual Camera or RTSP frames to the iOS VCAM tweak over WebSocket.

OBS must have Virtual Camera started. On Windows the default device is usually
camera index 0 or 1; use --list-devices in a future GUI or try nearby indexes.
"""

from __future__ import annotations

import argparse
import asyncio
import os
from dataclasses import dataclass

from vcam_protocol import KIND_JPEG_VIDEO, pack_packet


@dataclass(frozen=True)
class BridgeSettings:
    device: int | None
    rtsp_url: str | None
    width: int
    height: int
    fps: int
    jpeg_quality: int

    @property
    def is_rtsp(self) -> bool:
        return self.rtsp_url is not None

    @property
    def capture_source(self) -> int | str:
        return self.rtsp_url if self.rtsp_url is not None else int(self.device or 0)


class FrameBroadcaster:
    def __init__(self, settings: BridgeSettings) -> None:
        self.settings = settings
        self.condition = asyncio.Condition()
        self.sequence = 0
        self.latest_packet: bytes | None = None
        self.running = True

    def _open_capture(self, cv2):
        if self.settings.is_rtsp:
            # OpenCV passes these options to its FFmpeg backend. TCP avoids the
            # frame corruption common with UDP on Wi-Fi; nobuffer keeps latency
            # bounded when the receiver briefly falls behind.
            os.environ.setdefault(
                "OPENCV_FFMPEG_CAPTURE_OPTIONS",
                "rtsp_transport;tcp|fflags;nobuffer|flags;low_delay",
            )
            backend = cv2.CAP_FFMPEG if hasattr(cv2, "CAP_FFMPEG") else cv2.CAP_ANY
        else:
            backend = cv2.CAP_DSHOW if hasattr(cv2, "CAP_DSHOW") else cv2.CAP_ANY
        capture = cv2.VideoCapture(self.settings.capture_source, backend)
        if hasattr(cv2, "CAP_PROP_BUFFERSIZE"):
            capture.set(cv2.CAP_PROP_BUFFERSIZE, 1)
        if not self.settings.is_rtsp:
            capture.set(cv2.CAP_PROP_FRAME_WIDTH, self.settings.width)
            capture.set(cv2.CAP_PROP_FRAME_HEIGHT, self.settings.height)
            capture.set(cv2.CAP_PROP_FPS, self.settings.fps)
        return capture

    async def capture(self) -> None:
        try:
            import cv2
        except ImportError as exc:
            raise SystemExit("Install desktop dependencies: pip install opencv-python websockets") from exc

        camera = self._open_capture(cv2)
        if not camera.isOpened():
            source = self.settings.capture_source
            hint = "Check the RTSP URL and server" if self.settings.is_rtsp else "Start OBS Virtual Camera and try another index"
            raise SystemExit(f"Cannot open video source {source!r}. {hint}.")

        encode_options = [cv2.IMWRITE_JPEG_QUALITY, self.settings.jpeg_quality]
        frame_period = 1.0 / self.settings.fps
        try:
            while self.running:
                started = asyncio.get_running_loop().time()
                ok, frame = await asyncio.to_thread(camera.read)
                if not ok:
                    if self.settings.is_rtsp:
                        camera.release()
                        await asyncio.sleep(0.5)
                        camera = await asyncio.to_thread(self._open_capture, cv2)
                    else:
                        await asyncio.sleep(0.1)
                    continue
                encoded, jpeg = await asyncio.to_thread(cv2.imencode, ".jpg", frame, encode_options)
                if encoded:
                    packet = pack_packet(KIND_JPEG_VIDEO, jpeg.tobytes())
                    async with self.condition:
                        self.latest_packet = packet
                        self.sequence += 1
                        self.condition.notify_all()
                elapsed = asyncio.get_running_loop().time() - started
                await asyncio.sleep(max(0.0, frame_period - elapsed))
        finally:
            camera.release()

    async def serve_client(self, websocket) -> None:
        sent_sequence = -1
        while self.running:
            async with self.condition:
                await self.condition.wait_for(lambda: self.sequence != sent_sequence or not self.running)
                packet = self.latest_packet
                sent_sequence = self.sequence
            if packet is not None:
                await websocket.send(packet)


async def run(args: argparse.Namespace) -> None:
    try:
        import websockets
    except ImportError as exc:
        raise SystemExit("Install desktop dependencies: pip install opencv-python websockets") from exc

    settings = BridgeSettings(args.device, args.rtsp_url, args.width, args.height, args.fps, args.jpeg_quality)
    broadcaster = FrameBroadcaster(settings)
    async with websockets.serve(broadcaster.serve_client, args.host, args.port, max_size=None):
        print(f"VCAM OBS bridge listening on ws://{args.host}:{args.port}")
        if settings.is_rtsp:
            print(f"RTSP input: {settings.rtsp_url} (TCP, low-latency, reconnect enabled)")
        else:
            print("Start OBS Virtual Camera.")
        print("Configure the iPhone to connect to this PC's LAN IP.")
        await broadcaster.capture()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--device", type=int, help="OBS Virtual Camera device index (default: 0)")
    source.add_argument("--rtsp-url", help="RTSP input, for example rtsp://host:8554/live")
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=720)
    parser.add_argument("--fps", type=int, default=30)
    parser.add_argument("--jpeg-quality", type=int, default=82)
    args = parser.parse_args()
    if args.rtsp_url is not None and not args.rtsp_url.lower().startswith(("rtsp://", "rtsps://")):
        parser.error("--rtsp-url must start with rtsp:// or rtsps://")
    if args.device is None and args.rtsp_url is None:
        args.device = 0
    if not 1 <= args.fps <= 60:
        parser.error("--fps must be between 1 and 60")
    if not 20 <= args.jpeg_quality <= 100:
        parser.error("--jpeg-quality must be between 20 and 100")
    return args


if __name__ == "__main__":
    asyncio.run(run(parse_args()))
