"""Send OBS Virtual Camera frames to the iOS VCAM tweak over WebSocket.

OBS must have Virtual Camera started. On Windows the default device is usually
camera index 0 or 1; use --list-devices in a future GUI or try nearby indexes.
"""

from __future__ import annotations

import argparse
import asyncio
from dataclasses import dataclass

from vcam_protocol import KIND_JPEG_VIDEO, pack_packet


@dataclass(frozen=True)
class BridgeSettings:
    device: int
    width: int
    height: int
    fps: int
    jpeg_quality: int


class FrameBroadcaster:
    def __init__(self, settings: BridgeSettings) -> None:
        self.settings = settings
        self.condition = asyncio.Condition()
        self.sequence = 0
        self.latest_packet: bytes | None = None
        self.running = True

    async def capture(self) -> None:
        try:
            import cv2
        except ImportError as exc:
            raise SystemExit("Install desktop dependencies: pip install opencv-python websockets") from exc

        backend = cv2.CAP_DSHOW if hasattr(cv2, "CAP_DSHOW") else cv2.CAP_ANY
        camera = cv2.VideoCapture(self.settings.device, backend)
        camera.set(cv2.CAP_PROP_FRAME_WIDTH, self.settings.width)
        camera.set(cv2.CAP_PROP_FRAME_HEIGHT, self.settings.height)
        camera.set(cv2.CAP_PROP_FPS, self.settings.fps)
        if not camera.isOpened():
            raise SystemExit(
                f"Cannot open camera index {self.settings.device}. Start OBS Virtual Camera and try another index."
            )

        encode_options = [cv2.IMWRITE_JPEG_QUALITY, self.settings.jpeg_quality]
        frame_period = 1.0 / self.settings.fps
        try:
            while self.running:
                started = asyncio.get_running_loop().time()
                ok, frame = await asyncio.to_thread(camera.read)
                if not ok:
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

    settings = BridgeSettings(args.device, args.width, args.height, args.fps, args.jpeg_quality)
    broadcaster = FrameBroadcaster(settings)
    async with websockets.serve(broadcaster.serve_client, args.host, args.port, max_size=None):
        print(f"VCAM OBS bridge listening on ws://{args.host}:{args.port}")
        print("Start OBS Virtual Camera, then configure the iPhone to connect to this PC's LAN IP.")
        await broadcaster.capture()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--device", type=int, default=0, help="OBS Virtual Camera device index")
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=720)
    parser.add_argument("--fps", type=int, default=30)
    parser.add_argument("--jpeg-quality", type=int, default=82)
    args = parser.parse_args()
    if not 1 <= args.fps <= 60:
        parser.error("--fps must be between 1 and 60")
    if not 20 <= args.jpeg_quality <= 100:
        parser.error("--jpeg-quality must be between 20 and 100")
    return args


if __name__ == "__main__":
    asyncio.run(run(parse_args()))
