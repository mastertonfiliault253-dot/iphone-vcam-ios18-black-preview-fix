import importlib.util
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).parents[1]
SCRIPT = ROOT / "scripts" / "analyze-webkit-composition.py"
SPEC = importlib.util.spec_from_file_location("webkit_composition", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class WebKitCompositionAnalyzerTests(unittest.TestCase):
    def test_requires_webkit_telemetry(self) -> None:
        self.assertEqual(
            MODULE.validate(MODULE.parse_compositions("old log without marker")),
            ["missing WebKit composition telemetry"],
        )

    def test_accepts_adaptive_front_and_rear_fill(self) -> None:
        text = "\n".join(
            (
                "composition diagnostic presentation=webkit count=1 "
                "source=1080x1920 oriented=1080x1920 target=1440x1920 "
                "front=0 rotate=0 mirror=0 fit=0 scale=1.333333 "
                "coverage=1440.0x2560.0",
                "composition diagnostic presentation=webkit count=2 "
                "source=1080x1920 oriented=1920x1080 target=1920x1080 "
                "front=1 rotate=1 mirror=1 fit=0 scale=1.000000 "
                "coverage=1920.0x1080.0",
                "composition diagnostic presentation=still count=1 "
                "source=1080x1920 oriented=1920x1080 target=1920x1440 "
                "front=0 rotate=0 mirror=0 fit=0 scale=1.333333 "
                "coverage=2560.0x1440.0",
            )
        )
        records = MODULE.parse_compositions(text)
        self.assertEqual(len(records), 3)
        self.assertEqual(MODULE.validate(records), [])

    def test_rejects_letterbox_geometry_or_unscoped_mirror(self) -> None:
        text = (
            "composition diagnostic presentation=webkit count=1 "
            "source=1080x1920 oriented=1080x1920 target=1920x1080 "
            "front=1 rotate=0 mirror=0 fit=1 scale=0.562500 "
            "coverage=607.5x1080.0"
        )
        failures = MODULE.validate(MODULE.parse_compositions(text))
        self.assertTrue(any("horizontal coverage" in failure for failure in failures))
        self.assertTrue(any("unexpectedly used aspect-fit" in failure for failure in failures))
        self.assertTrue(any("front=1 mirror=0" in failure for failure in failures))
        self.assertTrue(any("rotate=0 expected=1" in failure for failure in failures))


if __name__ == "__main__":
    unittest.main()
