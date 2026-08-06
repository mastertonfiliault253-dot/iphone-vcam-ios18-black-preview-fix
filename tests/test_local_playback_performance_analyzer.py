import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).parents[1]
SCRIPT = ROOT / "scripts" / "analyze-local-playback-performance.py"


class LocalPlaybackPerformanceAnalyzerTests(unittest.TestCase):
    def run_fixture(self, fixture: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            log = pathlib.Path(directory) / "vcam.log"
            log.write_text(fixture, encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(SCRIPT), "--log", str(log)],
                capture_output=True,
                text=True,
                check=False,
            )

    def test_rejects_slow_five_fps_playback(self) -> None:
        lines = [
            "[DEBUG-vcamdiag] perf window=1.000 decoderMode=singleNV12 "
            "sourceFrames=5 sourceFrameP95Ms=205.0 itemAdvance=0.200 droppedSourceFrames=0"
            for _ in range(6)
        ]
        result = self.run_fixture("\n".join(lines))
        self.assertEqual(result.returncode, 1)
        self.assertIn("VCAM_LOCAL_PERF_VERDICT=RED", result.stdout)
        self.assertIn("source_fps=5.00", result.stdout)

    def test_accepts_stable_thirty_fps_playback(self) -> None:
        lines = [
            "[DEBUG-vcamdiag] perf window=1.000 decoderMode=singleReader "
            "sourceFrames=30 sourceFrameP95Ms=34.2 itemAdvance=1.000 droppedSourceFrames=0"
            for _ in range(6)
        ]
        result = self.run_fixture("\n".join(lines))
        self.assertEqual(result.returncode, 0)
        self.assertIn("VCAM_LOCAL_PERF_VERDICT=GREEN", result.stdout)
        self.assertIn("source_fps=30.00", result.stdout)

    def test_requires_p95_instrumentation(self) -> None:
        fixture = "\n".join(
            "[DEBUG-vcamdiag] perf window=1.000 sourceFrames=30 itemAdvance=1.000"
            for _ in range(6)
        )
        result = self.run_fixture(fixture)
        self.assertEqual(result.returncode, 2)
        self.assertIn("VCAM_LOCAL_PERF_VERDICT=ERROR", result.stdout)


if __name__ == "__main__":
    unittest.main()
