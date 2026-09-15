import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "analyze-stream-lifecycle.py"


def run_analyzer(source: str, text: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), "--source", source],
        input=text,
        text=True,
        capture_output=True,
        check=False,
    )


class StreamLifecycleAnalyzerTests(unittest.TestCase):
    def test_hls_without_consumer_suspension_is_red(self) -> None:
        result = run_analyzer(
            "hls",
            "\n".join(
                [
                    "[2026-09-15 21:24:50.000][DEBUG-vcamapp] springboard HLS start url=<REDACTED>",
                    "[2026-09-15 21:48:40.000][DEBUG-vcamapp] springboard HLS health ticks=1",
                    "[2026-09-15 21:54:09.000][DEBUG-vcamapp] springboard HLS health ticks=2",
                ]
            ),
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("VCAM_HLS_LIFECYCLE=RED", result.stdout)
        self.assertIn("hls-consumer-suspension-missing", result.stdout)

    def test_hls_suspends_without_later_decode_activity(self) -> None:
        result = run_analyzer(
            "hls",
            "\n".join(
                [
                    "[2026-09-15 22:00:00.000][DEBUG-vcamapp] springboard HLS start url=<REDACTED>",
                    "[2026-09-15 22:00:01.000][DEBUG-vcamapp] springboard HLS health ticks=1",
                    "[2026-09-15 22:00:04.000][DEBUG-vcamapp] springboard HLS suspended no consumer idle=3.0s",
                ]
            ),
        )

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("VCAM_HLS_LIFECYCLE=GREEN", result.stdout)
        self.assertIn("activity_after_suspend=0", result.stdout)

    def test_activity_after_hls_suspension_is_red(self) -> None:
        result = run_analyzer(
            "hls",
            "\n".join(
                [
                    "[2026-09-15 22:00:00.000][DEBUG-vcamapp] springboard HLS start url=<REDACTED>",
                    "[2026-09-15 22:00:04.000][DEBUG-vcamapp] springboard HLS suspended no consumer idle=3.0s",
                    "[2026-09-15 22:00:09.000][DEBUG-vcamapp] springboard HLS health ticks=2",
                ]
            ),
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("hls-activity-after-suspension", result.stdout)

    def test_rtsp_resume_then_final_suspend_is_green(self) -> None:
        result = run_analyzer(
            "rtsp",
            "\n".join(
                [
                    "[2026-09-15 22:00:00.000][DEBUG-vcamapp] vcamd RTSP source started for consumer",
                    "[2026-09-15 22:00:03.000][DEBUG-vcamapp] vcamd RTSP source suspended no consumer idle=3.0s",
                    "[2026-09-15 22:01:00.000][DEBUG-vcamapp] vcamd RTSP source resumed for consumer",
                    "[2026-09-15 22:01:01.000][DEBUG-vcamapp] rtsp first software pixel buffer format=34323076 size=1080x1920",
                    "[2026-09-15 22:01:04.000][DEBUG-vcamapp] vcamd RTSP source suspended no consumer idle=3.0s",
                ]
            ),
        )

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("VCAM_RTSP_LIFECYCLE=GREEN", result.stdout)
        self.assertIn("resumes=1", result.stdout)

    def test_rtsp_reconnect_after_final_suspension_is_red(self) -> None:
        result = run_analyzer(
            "rtsp",
            "\n".join(
                [
                    "[2026-09-15 22:00:00.000][DEBUG-vcamapp] vcamd RTSP source started for consumer",
                    "[2026-09-15 22:00:03.000][DEBUG-vcamapp] vcamd RTSP source suspended no consumer idle=3.0s",
                    "[2026-09-15 22:00:04.000][DEBUG-vcamapp] rtsp reconnect backing off 1 s",
                ]
            ),
        )

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("rtsp-activity-after-suspension", result.stdout)


if __name__ == "__main__":
    unittest.main()
