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

    def test_reports_recording_route_churn_during_preview_as_red(self) -> None:
        result = run_analyzer(
            "production identity pid=24062 start=1 ctor=1\n"
            "production replacement-count=2 route=4\n"
            "production replacement-count=13 route=5\n"
            "production replacement-count=16 route=4\n"
            "production replacement-count=19 route=5\n",
            "--preview-only-listener",
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("VCAM_CAMERA_PREVIEW_ROUTING=RED", result.stdout)
        self.assertIn("recording-route-active-during-preview", result.stdout)
        self.assertIn("mixed-preview-recording-presentations", result.stdout)
        self.assertIn("route_counts=4:2,5:2", result.stdout)

    def test_accepts_preview_only_listener_without_recording_route(self) -> None:
        result = run_analyzer(
            "production identity pid=30000 start=2 ctor=1\n"
            "production replacement-count=1 route=4\n"
            "production replacement-count=2 route=4\n",
            "--preview-only-listener",
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("VCAM_CAMERA_PREVIEW_ROUTING=GREEN", result.stdout)
        self.assertIn("failures=none", result.stdout)
        self.assertIn("route_counts=4:2", result.stdout)

    def test_preview_listener_selects_requested_pid_from_multiple_sessions(self) -> None:
        result = run_analyzer(
            "production identity pid=24062 start=1 ctor=1\n"
            "production replacement-count=1 route=4\n"
            "production replacement-count=2 route=5\n"
            "production identity pid=24147 start=2 ctor=1\n"
            "production replacement-count=1 route=0\n",
            "--preview-only-listener",
            "--production-pid",
            "24062",
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("production_pid=24062", result.stdout)
        self.assertIn("route_counts=4:1,5:1", result.stdout)


if __name__ == "__main__":
    unittest.main()
