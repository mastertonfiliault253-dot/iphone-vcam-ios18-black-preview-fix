import asyncio
import pathlib
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).parents[1] / "desktop"))

from obs_bridge import BridgeSettings, FrameBroadcaster, parse_args  # noqa: E402
from vcam_protocol import KIND_JPEG_VIDEO, pack_packet  # noqa: E402


class _OneShotWebSocket:
    def __init__(self, broadcaster: FrameBroadcaster) -> None:
        self.broadcaster = broadcaster
        self.packet: bytes | None = None

    async def send(self, packet: bytes) -> None:
        self.packet = packet
        self.broadcaster.running = False


class OBSBridgeTests(unittest.IsolatedAsyncioTestCase):
    async def test_latest_frame_is_sent_to_client(self) -> None:
        settings = BridgeSettings(device=0, rtsp_url=None, width=640, height=480, fps=30, jpeg_quality=82)
        broadcaster = FrameBroadcaster(settings)
        packet = pack_packet(KIND_JPEG_VIDEO, b"jpeg", timestamp_us=7)
        broadcaster.latest_packet = packet
        websocket = _OneShotWebSocket(broadcaster)

        await asyncio.wait_for(broadcaster.serve_client(websocket), timeout=1)

        self.assertEqual(websocket.packet, packet)

    def test_rtsp_url_selects_network_source(self) -> None:
        settings = BridgeSettings(
            device=None,
            rtsp_url="rtsp://192.168.2.10:8554/live",
            width=1280,
            height=720,
            fps=30,
            jpeg_quality=82,
        )

        self.assertTrue(settings.is_rtsp)
        self.assertEqual(settings.capture_source, "rtsp://192.168.2.10:8554/live")

    def test_cli_accepts_rtsp_and_rejects_wrong_scheme(self) -> None:
        with mock.patch.object(sys, "argv", ["obs_bridge.py", "--rtsp-url", "rtsp://host/live"]):
            args = parse_args()
        self.assertEqual(args.rtsp_url, "rtsp://host/live")
        self.assertIsNone(args.device)

        with mock.patch.object(sys, "argv", ["obs_bridge.py", "--rtsp-url", "http://host/live"]):
            with self.assertRaises(SystemExit):
                parse_args()


if __name__ == "__main__":
    unittest.main()
