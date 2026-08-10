import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class InjectionPolicyTests(unittest.TestCase):
    def test_supported_browser_bundles_have_control_ui_targets(self):
        header = (ROOT / "Sources/Core/VCAMInjectionPolicy.h").read_text(encoding="utf-8")
        implementation = (ROOT / "Sources/Core/VCAMInjectionPolicy.m").read_text(encoding="utf-8")

        self.assertIn("VCAMInjectionTargetFirefox", header)
        self.assertIn('@"org.mozilla.ios.firefox"', implementation)
        self.assertIn('@"com.microsoft.msedge"', implementation)
        self.assertIn('@"injectionFirefoxEnabled"', implementation)
        self.assertIn('return @"Firefox";', implementation)
        self.assertRegex(
            implementation,
            r"supportsControlUIInCurrentProcess[\s\S]*VCAMInjectionTargetFirefox",
        )


if __name__ == "__main__":
    unittest.main()
