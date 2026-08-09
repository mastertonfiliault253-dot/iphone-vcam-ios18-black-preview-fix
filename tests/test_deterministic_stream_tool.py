from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "start-deterministic-stream.ps1"
CONFIG = ROOT / "scripts" / "deterministic-mediamtx.yml"


class DeterministicStreamToolTests(unittest.TestCase):
    def test_publisher_has_one_fixed_closed_gop_h264_source(self):
        script = SCRIPT.read_text(encoding="utf-8")

        self.assertIn("testsrc2=size=1280x720:rate=30", script)
        self.assertIn('"-profile:v", "baseline"', script)
        self.assertIn('"-pix_fmt", "yuv420p"', script)
        self.assertIn('"-g", "30"', script)
        self.assertIn('"-keyint_min", "30"', script)
        self.assertIn('"-sc_threshold", "0"', script)
        self.assertIn('"-bf", "0"', script)
        self.assertIn("repeat-headers=1:aud=1:force-cfr=1", script)
        self.assertIn("threads=1:sliced-threads=0:slices=1", script)
        self.assertNotIn("screen", script.lower())
        self.assertNotIn("pyav", script.lower())

    def test_server_is_isolated_and_prepares_rtsp_and_hls(self):
        script = SCRIPT.read_text(encoding="utf-8")
        config = CONFIG.read_text(encoding="utf-8")

        self.assertIn(r"rtsp-vnc-tool\mediamtx\mediamtx.exe", script)
        self.assertIn("18554", script)
        self.assertIn("18888", script)
        self.assertIn("vcam-test", script)
        self.assertIn("rtspAddress: :18554", config)
        self.assertIn("hlsAddress: :18888", config)
        self.assertIn("hlsAlwaysRemux: true", config)
        self.assertIn("hlsVariant: mpegts", config)
        self.assertIn("moq: false", config)


if __name__ == "__main__":
    unittest.main()
