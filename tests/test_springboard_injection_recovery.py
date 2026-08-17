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
        self.assertIn('"com.apple.springboard"', springboard_filter)
        self.assertIn('"SpringBoard"', springboard_filter)
        self.assertIn('"com.apple.camera"', springboard_filter)
        self.assertIn('"com.apple.mobilesafari"', springboard_filter)
        self.assertIn('"com.google.chrome.ios"', springboard_filter)
        self.assertIn('"com.microsoft.msedge"', springboard_filter)
        self.assertIn('"org.mozilla.ios.Firefox"', springboard_filter)
        self.assertIn("cameracaptured", media_filter)

    def test_postinstall_recovers_exact_targets_with_exact_dylibs_only(self) -> None:
        postinst = (ROOT / "layout" / "DEBIAN" / "postinst").read_text(
            encoding="utf-8"
        )
        springboard_call = (
            "vcam_best_effort_inject SpringBoard "
            "/var/jb/Library/MobileSubstrate/DynamicLibraries/"
            "VCAMSpringBoardClient.dylib"
        )
        cameracaptured_call = (
            "vcam_best_effort_inject cameracaptured "
            "/var/jb/Library/MobileSubstrate/DynamicLibraries/"
            "VCAMMediaServerClient.dylib"
        )
        self.assertEqual(postinst.count("vcam_best_effort_inject "), 2)
        self.assertIn(springboard_call, postinst)
        self.assertIn(cameracaptured_call, postinst)
        self.assertIn("/var/jb/usr/bin/opainject", postinst)
        self.assertIn("/var/tmp/vcam-postinst-inject.log", postinst)
        self.assertNotIn("TweakLoader.dylib", postinst)
        self.assertNotIn("sbreload", postinst)
        self.assertIn("for inject_attempt in 1 2 3 4 5", postinst)
        self.assertIn('if [ "$observed_pid" = "$target_pid" ]', postinst)
        self.assertIn(
            'retry target=$target_name old_pid=$target_pid new_pid=$observed_pid',
            postinst,
        )
        self.assertIn(
            'completed target=$target_name pid=$target_pid attempt=$inject_attempt',
            postinst,
        )
        for forbidden in ("Camera", "MobileSafari", "SafariViewService", "WebKit"):
            self.assertNotIn(f"vcam_best_effort_inject {forbidden}", postinst)

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
