import pathlib
import unittest


ROOT = pathlib.Path(__file__).parents[1]


class InjectionSafetyTests(unittest.TestCase):
    def test_controller_filter_stays_limited_to_camera(self) -> None:
        filter_text = (ROOT / "VCAM.plist").read_text(encoding="utf-8")

        self.assertIn('"com.apple.camera"', filter_text)
        self.assertNotIn("mediaserverd", filter_text)
        self.assertNotIn("Classes", filter_text)

    def test_process_client_filter_is_an_explicit_allowlist(self) -> None:
        filter_text = (ROOT / "VCAMProcessClient.plist").read_text(encoding="utf-8")

        for target in (
            "com.apple.mobilesafari",
            "com.google.chrome.ios",
            "com.apple.WebKit.WebContent",
            "mediaserverd",
        ):
            self.assertIn(target, filter_text)
        self.assertNotIn("Classes", filter_text)
        self.assertNotIn("AVCaptureSession", filter_text)

    def test_constructor_uses_shared_process_policy_and_only_starts_ui_in_camera(self) -> None:
        hooks = (
            ROOT / "Sources" / "Hooks" / "VCAMCaptureHooks.xm"
        ).read_text(encoding="utf-8")

        self.assertIn("VCAMInjectionPolicy", hooks)
        self.assertIn("isCurrentProcessEnabled", hooks)
        self.assertIn("VCAM_WITH_CONTROL_UI", hooks)
        self.assertIn("startControlUI", hooks)

    def test_process_client_does_not_link_ui_frameworks(self) -> None:
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")

        self.assertIn("TWEAK_NAME = VCAM VCAMProcessClient", makefile)
        self.assertIn("VCAMProcessClient_FILES", makefile)
        self.assertIn("VCAMProcessClient_CFLAGS", makefile)
        self.assertIn("-DVCAM_WITH_CONTROL_UI=0", makefile)
        self.assertNotIn("UIKit", makefile.split("VCAMProcessClient_FRAMEWORKS", 1)[1].splitlines()[0])
        self.assertNotIn("PhotosUI", makefile.split("VCAMProcessClient_FRAMEWORKS", 1)[1].splitlines()[0])


if __name__ == "__main__":
    unittest.main()
