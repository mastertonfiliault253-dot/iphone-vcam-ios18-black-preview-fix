from pathlib import Path
import math
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import kyc_ai_content_audit  # noqa: E402


def _require_ffmpeg() -> None:
    if shutil.which("ffmpeg") is None or shutil.which("ffprobe") is None:
        raise unittest.SkipTest("ffmpeg/ffprobe not available")


class PureLogicTests(unittest.TestCase):
    """无 ffmpeg 依赖的纯逻辑判据测试。"""

    def test_autocorr_finds_injected_period(self) -> None:
        fps = 30
        n = int(fps * 10)
        diffs = [1.0 + 0.8 * math.sin(2 * math.pi * i / (fps * 2.0))
                 for i in range(n)]  # 2s 周期的运动能量
        result = kyc_ai_content_audit.autocorr_peak(diffs, fps)
        self.assertGreater(result["max_autocorr"], 0.8)
        self.assertAlmostEqual(result["period_seconds"], 2.0, delta=0.2)

    def test_constant_series_reports_not_meaningful(self) -> None:
        result = kyc_ai_content_audit.autocorr_peak([1.0] * 300, 30)
        self.assertIsNone(result["max_autocorr"])


class SyntheticAssetAuditTests(unittest.TestCase):
    """合成资产判别：静止资产必须触发"微动作不足"RISK，运动资产不得触发。"""

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

    def test_static_asset_flagged_low_motion(self) -> None:
        clip = self._encode("static.mp4", "color=gray:s=640x480:duration=8:rate=30")
        result = kyc_ai_content_audit.audit(clip)
        self.assertGreater(result["motion"]["static_ratio"], 0.9)
        self.assertTrue(any("微动作不足" in v for v in result["verdicts"]))

    def test_moving_asset_not_flagged_low_motion(self) -> None:
        clip = self._encode("moving.mp4", "testsrc2=size=640x480:duration=8:rate=30")
        result = kyc_ai_content_audit.audit(clip)
        self.assertLess(result["motion"]["static_ratio"], 0.1)
        self.assertFalse(any("微动作不足" in v for v in result["verdicts"]))

    def test_encode_profile_reports_bpp_and_gop(self) -> None:
        clip = self._encode("moving.mp4", "testsrc2=size=640x480:duration=8:rate=30")
        result = kyc_ai_content_audit.audit(clip)
        enc = result["encode"]
        self.assertEqual(enc["size"], "640x480")
        self.assertAlmostEqual(enc["fps"], 30.0, delta=0.5)
        self.assertGreater(enc["bpp"], 0.0)
        self.assertGreaterEqual(enc["keyframes"], 1)


if __name__ == "__main__":
    unittest.main()
