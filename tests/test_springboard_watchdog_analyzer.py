import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).parents[1]
SCRIPT = ROOT / "scripts" / "analyze-springboard-watchdog.py"
SPEC = importlib.util.spec_from_file_location("springboard_watchdog", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class SpringBoardWatchdogAnalyzerTests(unittest.TestCase):
    def test_detects_exact_checkin_watchdog_and_crash(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "userspace-panic-1.ips").write_text(
                "no successful checkins from SpringBoard (0 induced crashes) in 180 seconds\n",
                encoding="utf-8",
            )
            metadata = {"timestamp": "2026-09-17 11:01:15.00 +0100"}
            report = {
                "exception": {"type": "EXC_BAD_ACCESS", "signal": "SIGBUS"},
                "termination": {"namespace": "SIGNAL", "code": 10},
                "faultingThread": 0,
                "threads": [{"frames": [{"symbol": "dyld4::Loader::hasExportedSymbol"}]}],
            }
            (root / "SpringBoard-1.ips").write_text(
                json.dumps(metadata) + "\n" + json.dumps(report), encoding="utf-8"
            )

            failures, evidence = MODULE.analyze(root)

            self.assertEqual(len(failures), 1)
            self.assertIn("180 seconds", failures[0])
            self.assertEqual(len(evidence), 1)
            self.assertIn("EXC_BAD_ACCESS/SIGBUS", evidence[0])
            self.assertIn("dyld4::Loader::hasExportedSymbol", evidence[0])

    def test_accepts_bundle_without_matching_panic(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            failures, evidence = MODULE.analyze(pathlib.Path(directory))
            self.assertEqual(failures, [])
            self.assertEqual(evidence, [])


if __name__ == "__main__":
    unittest.main()
