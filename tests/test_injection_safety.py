import pathlib
import unittest


ROOT = pathlib.Path(__file__).parents[1]


class InjectionSafetyTests(unittest.TestCase):
    def test_filter_is_limited_to_camera_bundle(self) -> None:
        filter_text = (ROOT / "VCAM.plist").read_text(encoding="utf-8")

        self.assertIn('"com.apple.camera"', filter_text)
        self.assertNotIn(
            "Classes",
            filter_text,
            "Class filters use OR semantics in ElleKit and can inject VCAM into mediaserverd",
        )
        self.assertNotIn("AVCaptureSession", filter_text)

    def test_constructor_has_runtime_camera_process_guard(self) -> None:
        hooks = (
            ROOT / "Sources" / "Hooks" / "VCAMCaptureHooks.xm"
        ).read_text(encoding="utf-8")

        self.assertIn("VCAMIsAllowedProcess", hooks)
        self.assertIn('isEqualToString:@"com.apple.camera"', hooks)
        self.assertIn('isEqualToString:@"Camera"', hooks)
        self.assertRegex(hooks, r"%ctor\s*\{[\s\S]*if \(!VCAMIsAllowedProcess\(\)\) return;")


if __name__ == "__main__":
    unittest.main()
