import pathlib
import unittest


ROOT = pathlib.Path(__file__).parents[1]


class SpringBoardInjectionRecoveryTests(unittest.TestCase):
    def test_package_defines_only_the_two_vcam_tweaks(self) -> None:
        self.assertEqual(
            sorted(path.name for path in ROOT.glob("*.plist") if "Client" in path.name),
            ["VCAMMediaServerClient.plist", "VCAMSpringBoardClient.plist"],
        )

        springboard_filter = (ROOT / "VCAMSpringBoardClient.plist").read_text(
            encoding="utf-8"
        )
        media_filter = (ROOT / "VCAMMediaServerClient.plist").read_text(
            encoding="utf-8"
        )
        # M 轮收缩：UI 注入只保留 SpringBoard（全局悬浮点），与
        # tests/test_injection_monitor.py 同名契约一致。
        self.assertIn('"com.apple.springboard"', springboard_filter)
        self.assertIn('"SpringBoard"', springboard_filter)
        for forbidden in (
            '"com.apple.camera"',
            '"com.apple.mobilesafari"',
            '"com.google.chrome.ios"',
            '"com.microsoft.msedge"',
            '"org.mozilla.ios.Firefox"',
        ):
            self.assertNotIn(forbidden, springboard_filter)
        self.assertIn("cameracaptured", media_filter)

    def test_postinstall_keeps_springboard_on_ellekit_and_defers_cameracaptured(self) -> None:
        postinst = (ROOT / "layout" / "DEBIAN" / "postinst").read_text(
            encoding="utf-8"
        )
        self.assertEqual(postinst.count('vcam_log_injection "deferred target='), 1)
        self.assertIn(
            'vcam_log_injection "automatic target=SpringBoard reason=ElleKit"',
            postinst,
        )
        self.assertIn(
            'vcam_log_injection "deferred target=cameracaptured reason=vcaminjectd"',
            postinst,
        )
        self.assertNotIn("vcam_best_effort_inject", postinst)
        self.assertNotIn("/var/jb/usr/bin/opainject", postinst)
        self.assertIn("/var/tmp/vcam-postinst-inject.log", postinst)
        self.assertNotIn("TweakLoader.dylib", postinst)
        self.assertNotIn("sbreload", postinst)
        for forbidden in ("Camera", "MobileSafari", "SafariViewService", "WebKit"):
            self.assertNotIn(f"deferred target={forbidden}", postinst)

    def test_white_dot_waits_for_springboard_window_lifecycle(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("VCAMWindowDiscoveryRetryCount = 240", picker)
        self.assertIn("UIWindowDidBecomeKeyNotification", picker)
        self.assertIn("UISceneDidActivateNotification", picker)
        self.assertIn("self.remainingWindowRetries = VCAMWindowDiscoveryRetryCount", picker)


if __name__ == "__main__":
    unittest.main()
