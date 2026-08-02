import pathlib
import subprocess
import sys
import tempfile
import unittest


class VCAMDiagnosticAnalyzerTests(unittest.TestCase):
    def test_flags_double_orientation_and_format_thrash(self) -> None:
        root = pathlib.Path(__file__).parents[1]
        script = root / "scripts" / "analyze-vcam-diagnostics.py"
        fixture = """
[DEBUG-vcamdiag] asset natural=1920x1080 transform=[0 1 -1 0 1080 0] angle=90 configRotation=0 requestedFps=30
[DEBUG-vcamdiag] perf window=1.000 callbacks=60 newFrames=8 misses=12 reconfigs=38 templateSwitches=37 cacheHits=10 renders=38 renderAvgMs=12.0 renderMaxMs=41.0 itemAdvance=0.48 rate=1.0 source=1080x1920 target=1920x1080 templateFormat=0x34323076
"""
        with tempfile.TemporaryDirectory() as directory:
            log = pathlib.Path(directory) / "diag.log"
            log.write_text(fixture, encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(script),
                    "--log",
                    str(log),
                    "--orientation-observed",
                    "upside-down",
                    "--choppy-observed",
                    "yes",
                ],
                capture_output=True,
                text=True,
            )

        self.assertEqual(result.returncode, 1)
        self.assertIn("VCAM_DIAG_VERDICT=RED", result.stdout)
        self.assertIn("orientation_double_transform_evidence=True", result.stdout)
        self.assertIn("format_thrash=True", result.stdout)


if __name__ == "__main__":
    unittest.main()
