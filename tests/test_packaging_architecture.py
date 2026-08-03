import json
import pathlib
import unittest


ROOT = pathlib.Path(__file__).parents[1]


class PackagingArchitectureTests(unittest.TestCase):
    def test_process_targets_share_one_package_but_keep_separate_binaries(self) -> None:
        manifest = json.loads((ROOT / "packaging" / "targets.json").read_text(encoding="utf-8"))
        targets = {target["name"]: target for target in manifest["targets"]}

        self.assertEqual(targets["VCAMController"]["bundleIds"], ["com.apple.camera"])
        self.assertEqual(
            targets["VCAMAppClient"]["bundleIds"],
            ["com.apple.mobilesafari", "com.google.chrome.ios"],
        )
        self.assertTrue(targets["VCAMWebKitClient"]["separateBinary"])
        self.assertEqual(targets["VCAMMediaServerClient"]["executables"], ["mediaserverd"])
        self.assertEqual(targets["VCAMAppClient"]["package"], "com.codex.vcam")
        self.assertEqual(targets["VCAMMediaServerClient"]["package"], "com.codex.vcam")
        self.assertFalse(targets["VCAMMediaServerClient"]["separatePackage"])
        self.assertFalse(targets["VCAMMediaServerClient"]["defaultEnabled"])

    def test_process_clients_exclude_control_ui_dependencies(self) -> None:
        manifest = json.loads((ROOT / "packaging" / "targets.json").read_text(encoding="utf-8"))
        targets = {target["name"]: target for target in manifest["targets"]}

        self.assertEqual(manifest["delivery"], "single-package-multiple-binaries")
        self.assertEqual(targets["VCAMAppClient"]["binary"], "VCAMAppClient.dylib")
        for name in ("VCAMWebKitClient", "VCAMMediaServerClient"):
            forbidden = targets[name]["forbiddenDependencies"]
            self.assertIn("PhotosUI", forbidden)
            self.assertIn("UIKit", forbidden)
            self.assertEqual(targets[name]["binary"], "VCAMProcessClient.dylib")

    def test_control_panel_exposes_individual_and_global_injection_selection(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(encoding="utf-8")

        for key in (
            "injectionGlobalEnabled",
            "injectionCameraEnabled",
            "injectionSafariEnabled",
            "injectionChromeEnabled",
            "injectionWebKitEnabled",
            "injectionMediaServerEnabled",
        ):
            self.assertIn(key, picker)
        self.assertIn("全局注入", picker)
        self.assertIn("Safari", picker)
        self.assertIn("Chrome", picker)
        self.assertIn("mediaserverd", picker)

    def test_ui_hosts_share_panel_but_process_clients_never_start_ui(self) -> None:
        policy_h = (ROOT / "Sources" / "Core" / "VCAMInjectionPolicy.h").read_text(encoding="utf-8")
        policy_m = (ROOT / "Sources" / "Core" / "VCAMInjectionPolicy.m").read_text(encoding="utf-8")
        hooks = (ROOT / "Sources" / "Hooks" / "VCAMCaptureHooks.xm").read_text(encoding="utf-8")

        self.assertIn("shouldShowControlUI", policy_h)
        self.assertIn("isCurrentProcessMediaReplacementEnabled", policy_h)
        self.assertIn("VCAMInjectionTargetMediaServer", policy_m)
        self.assertIn("target != VCAMInjectionTargetMediaServer", policy_m)
        self.assertIn("!mediaServerEnabled", policy_m)
        self.assertIn("supportsControlUIInCurrentProcess", hooks)
        self.assertIn("isCurrentProcessMediaReplacementEnabled", hooks)

    def test_global_excludes_mediaserver_and_browser_targets_link_webkit(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(encoding="utf-8")

        self.assertIn("globalPreferenceKeys", picker)
        self.assertIn("linkedWebKitEnabled", picker)
        self.assertIn("confirmMediaServerToggle", picker)
        global_method = picker.split("- (NSArray<NSString *> *)globalPreferenceKeys", 1)[1]
        global_method = global_method.split("\n}", 1)[0]
        self.assertNotIn("injectionMediaServerEnabled", global_method)

    def test_floating_button_position_is_saved_per_host_app(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(encoding="utf-8")

        self.assertIn("floatingButtonPositions", picker)
        self.assertIn("floatingPositionIdentifier", picker)
        self.assertIn("UIGestureRecognizerStateEnded", picker)

    def test_springboard_ui_is_a_separate_ui_only_binary_in_the_same_package(self) -> None:
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        filter_text = (ROOT / "VCAMSpringBoardClient.plist").read_text(encoding="utf-8")
        entry = (ROOT / "Sources" / "Hooks" / "VCAMSpringBoardEntry.xm").read_text(encoding="utf-8")

        self.assertIn("VCAMSpringBoardClient", makefile)
        self.assertIn("SpringBoard", filter_text)
        springboard_files = makefile.split("VCAMSpringBoardClient_FILES", 1)[1].splitlines()[0]
        self.assertNotIn("VCAM_COMMON_FILES", springboard_files)
        self.assertNotIn("VCAMCaptureHooks", springboard_files)
        self.assertNotIn("VCAMRTSPStreamSource", springboard_files)
        self.assertIn("VCAMSpringBoardDiagnosticsStubs.m", springboard_files)
        self.assertIn("startWriteBroker", entry)
        self.assertIn("startControlUI", entry)

    def test_default_injection_enables_camera_and_browsers_but_not_mediaserver(self) -> None:
        policy = (ROOT / "Sources" / "Core" / "VCAMInjectionPolicy.m").read_text(encoding="utf-8")

        self.assertIn("defaultEnabledForTarget", policy)
        self.assertIn("VCAMInjectionTargetSpringBoard", policy)
        self.assertIn("VCAMInjectionTargetMediaServer: return NO", policy)
        for target in ("Camera", "Safari", "Chrome", "WebKit"):
            self.assertIn(f"VCAMInjectionTarget{target}: return YES", policy)


if __name__ == "__main__":
    unittest.main()
