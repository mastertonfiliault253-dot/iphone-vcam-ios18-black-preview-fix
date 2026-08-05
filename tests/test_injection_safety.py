import pathlib
import unittest


ROOT = pathlib.Path(__file__).parents[1]


class InjectionSafetyTests(unittest.TestCase):
    def test_controller_filter_stays_limited_to_camera(self) -> None:
        filter_text = (ROOT / "VCAM.plist").read_text(encoding="utf-8")

        self.assertIn('"com.apple.camera"', filter_text)
        self.assertNotIn("mediaserverd", filter_text)
        self.assertNotIn("Classes", filter_text)

    def test_app_client_filter_is_limited_to_ui_host_apps(self) -> None:
        filter_text = (ROOT / "VCAMAppClient.plist").read_text(encoding="utf-8")

        self.assertIn("com.apple.mobilesafari", filter_text)
        self.assertIn("com.google.chrome.ios", filter_text)
        self.assertIn("com.microsoft.edge.ios", filter_text)
        self.assertIn("com.google.GoogleMobile", filter_text)
        self.assertNotIn("mediaserverd", filter_text)
        self.assertNotIn("WebContent", filter_text)

    def test_webkit_client_filter_is_limited_to_web_content(self) -> None:
        filter_text = (ROOT / "VCAMWebKitClient.plist").read_text(encoding="utf-8")

        self.assertIn("com.apple.WebKit.WebContent", filter_text)
        self.assertNotIn("mediaserverd", filter_text)
        self.assertNotIn("com.apple.mobilesafari", filter_text)
        self.assertNotIn("com.apple.camera", filter_text)
        self.assertNotIn("Classes", filter_text)

    def test_mediaserver_client_filter_is_limited_to_mediaserverd(self) -> None:
        filter_text = (ROOT / "VCAMMediaServerClient.plist").read_text(encoding="utf-8")

        self.assertIn("mediaserverd", filter_text)
        self.assertNotIn("WebContent", filter_text)
        self.assertNotIn("com.apple.camera", filter_text)
        self.assertNotIn("Classes", filter_text)

    def test_constructor_uses_shared_process_policy_and_only_starts_ui_in_camera(self) -> None:
        hooks = (
            ROOT / "Sources" / "Hooks" / "VCAMCaptureHooks.xm"
        ).read_text(encoding="utf-8")

        self.assertIn("VCAMInjectionPolicy", hooks)
        self.assertIn("isCurrentProcessMediaReplacementEnabled", hooks)
        self.assertIn("VCAM_WITH_CONTROL_UI", hooks)
        self.assertIn("startControlUI", hooks)

    def test_mediaserver_client_does_not_link_ui_or_ffmpeg(self) -> None:
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")

        self.assertIn("VCAMMediaServerClient_FILES", makefile)
        entry = (ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefEntry.xm").read_text(encoding="utf-8")
        self.assertIn("BWNodeOutput", entry)
        self.assertIn("emitSampleBuffer", entry)
        self.assertIn("loadReplacementMedia", entry)
        self.assertIn("VCAMMediaServerClient_CFLAGS", makefile)
        self.assertIn("-DVCAM_WITH_CONTROL_UI=0", makefile)
        ms_block = makefile.split("VCAMMediaServerClient_FILES", 1)[1].split("VCAMSpringBoardClient_FILES", 1)[0]
        self.assertNotIn("VCAM_COMMON_FILES", ms_block)
        self.assertNotIn("VCAMCaptureHooks", ms_block)
        self.assertNotIn("ffmpeg", ms_block)
        self.assertNotIn("UIKit", ms_block)
        self.assertNotIn("PhotosUI", ms_block)
        self.assertIn("VCAMCameraPreviewHooks.xm", makefile)
        self.assertNotIn("VCAMCameraPreviewHooks.xm", makefile.split("VCAMWebKitClient_FILES", 1)[1].splitlines()[0])
        self.assertNotIn("VCAMCameraPreviewHooks.xm", ms_block)


if __name__ == "__main__":
    unittest.main()