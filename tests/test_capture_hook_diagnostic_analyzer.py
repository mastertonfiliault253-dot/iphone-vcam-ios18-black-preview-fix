import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class CaptureHookDiagnosticAnalyzerTests(unittest.TestCase):
    def test_reports_exact_on_device_failure_as_red(self):
        result = subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts" / "analyze-capture-hook-diagnostics.py"),
                "--photo-request", "0",
                "--photo-callback", "0",
                "--recording-start", "1",
                "--recording-finish", "1",
                "--photo-output", "real",
                "--recording-output", "real",
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("VCAM_CAPTURE_VERDICT=RED", result.stdout)
        self.assertIn("photo_path=public_hook_not_reached", result.stdout)
        self.assertIn("recording_path=completion_hook_reached_but_output_unreplaced", result.stdout)

    def test_reports_successful_late_copy_with_real_first_frame_as_red(self):
        result = subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts" / "analyze-capture-hook-diagnostics.py"),
                "--photo-request", "0",
                "--photo-callback", "0",
                "--recording-start", "1",
                "--recording-finish", "1",
                "--photo-output", "real",
                "--recording-output", "replacement",
                "--recording-first-frame", "real",
                "--copy-attempt", "1",
                "--copy-success", "1",
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("VCAM_CAPTURE_VERDICT=RED", result.stdout)
        self.assertIn("recording_path=replacement_succeeded_but_first_frame_is_real", result.stdout)


if __name__ == "__main__":
    unittest.main()
