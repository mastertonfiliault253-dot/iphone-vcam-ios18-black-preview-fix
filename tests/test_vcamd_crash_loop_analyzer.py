import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).parents[1]
SCRIPT = ROOT / "scripts" / "analyze-vcamd-crash-loop.py"
SPEC = importlib.util.spec_from_file_location("vcamd_crash_loop", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def write_report(
    root: pathlib.Path,
    name: str,
    *,
    incident_id: str,
    process: str = "vcamd",
    queue: str = "com.codex.vcamd.producer",
    assertion: str = (
        "BUG IN CLIENT OF LIBDISPATCH: dispatch_sync called on queue already "
        "owned by current thread"
    ),
) -> None:
    metadata = {
        "app_name": process,
        "timestamp": "2026-09-18 10:25:04.00 -0300",
        "incident_id": incident_id,
    }
    report = {
        "procName": process,
        "exception": {"type": "EXC_BREAKPOINT", "signal": "SIGTRAP"},
        "faultingThread": 0,
        "asi": {"libdispatch.dylib": [assertion]},
        "threads": [
            {
                "triggered": True,
                "queue": queue,
                "frames": [
                    {"symbol": "__DISPATCH_WAIT_FOR_QUEUE__"},
                    {"symbol": "_dispatch_sync_f_slow"},
                    {"imageOffset": 2734044, "imageIndex": 1},
                ],
            }
        ],
    }
    (root / name).write_text(
        json.dumps(metadata) + "\n" + json.dumps(report), encoding="utf-8"
    )


class VCAMDCrashLoopAnalyzerTests(unittest.TestCase):
    def test_detects_repeated_producer_queue_self_sync(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            write_report(root, "vcamd-1.ips", incident_id="incident-1")
            write_report(root, "vcamd-2.ips", incident_id="incident-2")

            failures, evidence = MODULE.analyze(root)

            self.assertEqual(failures, ["producer-queue-self-dispatch-sync"])
            self.assertEqual(evidence["matching_incidents"], 2)
            self.assertEqual(evidence["matching_reports"], 2)
            self.assertEqual(evidence["top_app_offsets"], [2734044])

    def test_deduplicates_same_incident_and_ignores_other_crashes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            write_report(root, "vcamd-1.ips", incident_id="same-incident")
            write_report(root, "vcamd-1.000.ips", incident_id="same-incident")
            write_report(
                root,
                "vcamd-unrelated.ips",
                incident_id="other-incident",
                queue="com.apple.main-thread",
            )

            failures, evidence = MODULE.analyze(root)

            self.assertEqual(failures, ["producer-queue-self-dispatch-sync"])
            self.assertEqual(evidence["matching_incidents"], 1)
            self.assertEqual(evidence["matching_reports"], 2)

    def test_accepts_bundle_without_matching_crash(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            write_report(
                root,
                "vcamd-unrelated.ips",
                incident_id="other-incident",
                assertion="unrelated failure",
            )

            failures, evidence = MODULE.analyze(root)

            self.assertEqual(failures, [])
            self.assertEqual(evidence["matching_incidents"], 0)


if __name__ == "__main__":
    unittest.main()
