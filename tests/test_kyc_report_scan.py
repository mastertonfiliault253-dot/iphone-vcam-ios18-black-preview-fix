from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import kyc_report_scan  # noqa: E402


def _require_ffmpeg() -> None:
    if shutil.which("ffmpeg") is None or shutil.which("ffprobe") is None:
        raise unittest.SkipTest("ffmpeg/ffprobe not available")


class FrameStreamContinuityRegressionTests(unittest.TestCase):
    """1080p 内容冻结的判据回归：检测电池必须能把"正常运动流"与
    "时间戳正常但内容重复"的流区分开（真机 2026-10-12 的缺陷形态就是后者）。

    设备端修复验收：kyc-flow 1080p 录像经同一判据 content_frozen 必须为 False。
    """

    def setUp(self) -> None:
        _require_ffmpeg()
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def _encode(self, name: str, source_filter: str) -> Path:
        path = self.dir / name
        subprocess.run(
            ["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", source_filter,
             "-frames:v", "240", "-r", "30", "-pix_fmt", "yuv420p", str(path)],
            check=True)
        return path

    def test_moving_stream_is_not_frozen(self) -> None:
        clip = self._encode("moving.mp4", "testsrc2=size=640x480:rate=30:duration=8")
        result = kyc_report_scan.scan(clip)
        self.assertFalse(result["frame_diff"]["content_frozen"])
        self.assertGreater(result["frame_diff"]["content_refresh_hz"], 20.0)

    def test_repeated_stream_is_flagged_frozen(self) -> None:
        # 单帧循环 8s：时间戳 30fps 正常、内容完全重复，等价于 1080p 缺陷形态。
        clip = self._encode("frozen.mp4", "color=gray:s=640x480:duration=8:rate=30")
        result = kyc_report_scan.scan(clip)
        self.assertTrue(result["frame_diff"]["content_frozen"])
        self.assertLess(result["frame_diff"]["content_refresh_hz"], 10.0)

    def test_timestamp_structure_reported_for_both(self) -> None:
        moving = self._encode("moving.mp4", "testsrc2=size=640x480:rate=30:duration=8")
        result = kyc_report_scan.scan(moving)
        self.assertAlmostEqual(result["pts"]["ts_fps"], 30.0, delta=1.0)


if __name__ == "__main__":
    unittest.main()
