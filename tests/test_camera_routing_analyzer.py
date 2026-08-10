import pathlib
import subprocess
import sys
import unittest


ROOT = pathlib.Path(__file__).parents[1]
SCRIPT = ROOT / "scripts" / "analyze-camera-routing.py"


def run_analyzer(log: str, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        input=log,
        text=True,
        capture_output=True,
        check=False,
    )


class CameraRoutingAnalyzerTests(unittest.TestCase):
    def test_reports_ios16_mode_switch_failure_as_red(self) -> None:
        result = run_analyzer(
            "shared-frame reader initialized\n"
            "output signature supported=0 allowed=1 route=camera-source-video\n"
            "suppressing real sample after replacement failure\n"
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("VCAM_CAMERA_ROUTING=RED", result.stdout)
        self.assertIn("unsupported-routed-format", result.stdout)

    def test_requires_photo_and_recording_routes_after_acceptance_actions(self) -> None:
        result = run_analyzer(
            "shared-frame reader initialized\nroute=camera-preview\n",
            "--require-recording",
            "--require-photo",
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("recording-route-missing", result.stdout)
        self.assertIn("photo-route-missing", result.stdout)

    def test_accepts_clean_photo_and_recording_session(self) -> None:
        result = run_analyzer(
            "old supported=0 allowed=1 route=camera-source-video\n"
            "shared-frame reader initialized\n"
            "route=camera-source-video\nroute=video-recording\nroute=still-photo\n",
            "--require-recording",
            "--require-photo",
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("VCAM_CAMERA_ROUTING=GREEN", result.stdout)
        self.assertIn("failures=none", result.stdout)


if __name__ == "__main__":
    unittest.main()
