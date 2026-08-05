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
            [
                "com.apple.mobilesafari",
                "com.google.chrome.ios",
                "com.microsoft.edge.ios",
                "com.google.GoogleMobile",
            ],
        )
        self.assertEqual(targets["VCAMAppClient"]["package"], "com.codex.vcam")
        self.assertEqual(manifest["delivery"], "single-package-multiple-binaries")

    def test_webkit_client_is_headless(self) -> None:
        manifest = json.loads((ROOT / "packaging" / "targets.json").read_text(encoding="utf-8"))
        targets = {target["name"]: target for target in manifest["targets"]}

        self.assertEqual(targets["VCAMWebKitClient"]["bundleIds"], ["com.apple.WebKit.WebContent"])
        self.assertIn("UIKit", targets["VCAMWebKitClient"]["forbiddenDependencies"])
        self.assertIn("PhotosUI", targets["VCAMWebKitClient"]["forbiddenDependencies"])
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        self.assertIn("VCAMWebKitClient", makefile)
        self.assertTrue((ROOT / "VCAMWebKitClient.plist").exists())

    def test_mediaserver_client_is_minimal_headless_and_default_on(self) -> None:
        manifest = json.loads((ROOT / "packaging" / "targets.json").read_text(encoding="utf-8"))
        targets = {target["name"]: target for target in manifest["targets"]}

        ms = targets["VCAMMediaServerClient"]
        self.assertEqual(ms["executables"], ["mediaserverd"])
        self.assertTrue(ms["defaultEnabled"])
        self.assertIn("FFmpeg", ms["forbiddenDependencies"])
        self.assertIn("UIKit", ms["forbiddenDependencies"])
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        self.assertIn("VCAMMediaServerClient", makefile)
        self.assertIn("VCAMMediaServerRefEntry.xm", makefile)
        self.assertIn("VCAMMediaServerRefImageUtils.m", makefile)
        self.assertTrue((ROOT / "VCAMMediaServerClient.plist").exists())
        self.assertFalse((ROOT / "VCAMProcessClient.plist").exists())

    def test_control_panel_exposes_individual_and_global_injection_selection(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(encoding="utf-8")

        for key in (
            "injectionGlobalEnabled",
            "injectionCameraEnabled",
            "injectionSafariEnabled",
            "injectionChromeEnabled",
            "injectionEdgeEnabled",
            "injectionGoogleEnabled",
            "injectionWebKitEnabled",
            "injectionMediaServerEnabled",
        ):
            self.assertIn(key, picker)
        self.assertIn("全局注入", picker)
        self.assertIn("Safari", picker)
        self.assertIn("Chrome", picker)
        self.assertIn("Edge", picker)
        self.assertIn("Google", picker)
        self.assertIn("WebKit", picker)
        self.assertIn("mediaserverd", picker)

    def test_ui_hosts_share_panel_and_all_targets_use_common_policy(self) -> None:
        policy_h = (ROOT / "Sources" / "Core" / "VCAMInjectionPolicy.h").read_text(encoding="utf-8")
        policy_m = (ROOT / "Sources" / "Core" / "VCAMInjectionPolicy.m").read_text(encoding="utf-8")
        hooks = (ROOT / "Sources" / "Hooks" / "VCAMCaptureHooks.xm").read_text(encoding="utf-8")

        self.assertIn("shouldShowControlUI", policy_h)
        self.assertIn("isCurrentProcessMediaReplacementEnabled", policy_h)
        self.assertIn("VCAMInjectionTargetMediaServer", policy_m)
        self.assertIn("VCAMInjectionTargetWebKit", policy_m)
        self.assertIn("supportsControlUIInCurrentProcess", hooks)
        self.assertIn("isCurrentProcessMediaReplacementEnabled", hooks)
        self.assertIn("dispatch_async", hooks)

    def test_configuration_allowlist_includes_webkit_and_mediaserver(self) -> None:
        configuration = (
            ROOT / "Sources" / "Core" / "VCAMConfiguration.m"
        ).read_text(encoding="utf-8")
        policy = (
            ROOT / "Sources" / "Core" / "VCAMInjectionPolicy.m"
        ).read_text(encoding="utf-8")

        self.assertIn("injectionWebKitEnabled", configuration)
        self.assertIn("injectionMediaServerEnabled", configuration)
        self.assertIn("VCAMInjectionTargetWebKit", policy)
        self.assertIn("VCAMInjectionTargetMediaServer", policy)
        self.assertIn("com.microsoft.edge.ios", policy)
        self.assertIn("com.google.GoogleMobile", policy)

    def test_broker_persistence_is_verified_and_diagnosed(self) -> None:
        configuration = (
            ROOT / "Sources" / "Core" / "VCAMConfiguration.m"
        ).read_text(encoding="utf-8")

        self.assertIn("VCAMAppendDiagnostics", configuration)
        self.assertIn("broker-probe.log", configuration)
        self.assertIn("copyValuesFromBroker", configuration)
        self.assertIn("VCAMBuildTag", configuration)

    def test_shared_media_is_mirrored_into_each_process(self) -> None:
        configuration = (
            ROOT / "Sources" / "Core" / "VCAMConfiguration.m"
        ).read_text(encoding="utf-8")
        header = (
            ROOT / "Sources" / "Core" / "VCAMConfiguration.h"
        ).read_text(encoding="utf-8")

        self.assertIn("resolvedMediaPathForSharedPath", header)
        self.assertIn("VCAMConfigurationBrokerFetchMediaCommand", configuration)
        self.assertIn("VCAM-media", configuration)
        self.assertIn("resolvedMediaPathForSharedPath:", configuration)
        self.assertIn("isWriteBrokerHost", configuration)

    def test_global_toggle_excludes_mediaserver(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(encoding="utf-8")

        self.assertIn("globalPreferenceKeys", picker)
        global_method = picker.split("- (NSArray<NSString *> *)globalPreferenceKeys", 1)[1]
        global_method = global_method.split("\n}", 1)[0]
        for key in ("injectionCameraEnabled", "injectionSafariEnabled", "injectionChromeEnabled",
                    "injectionEdgeEnabled", "injectionGoogleEnabled", "injectionWebKitEnabled"):
            self.assertIn(key, global_method)
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
        self.assertIn("com.apple.springboard", filter_text)
        springboard_files = makefile.split("VCAMSpringBoardClient_FILES", 1)[1].splitlines()[0]
        self.assertNotIn("VCAM_COMMON_FILES", springboard_files)
        self.assertNotIn("VCAMCaptureHooks", springboard_files)
        self.assertNotIn("VCAMRTSPStreamSource", springboard_files)
        self.assertIn("VCAMSpringBoardDiagnosticsStubs.m", springboard_files)
        self.assertIn("startWriteBroker", entry)
        self.assertIn("startControlUI", entry)

    def test_default_injection_enables_all_targets(self) -> None:
        policy = (ROOT / "Sources" / "Core" / "VCAMInjectionPolicy.m").read_text(encoding="utf-8")

        self.assertIn("defaultEnabledForTarget", policy)
        self.assertIn("VCAMInjectionTargetSpringBoard", policy)
        for target in ("Camera", "Safari", "Chrome", "Edge", "Google", "WebKit", "MediaServer"):
            self.assertIn(f"VCAMInjectionTarget{target}: return YES", policy)

    def test_browser_media_pipeline_is_deferred_until_a_source_is_enabled(self) -> None:
        policy = (ROOT / "Sources" / "Core" / "VCAMInjectionPolicy.m").read_text(encoding="utf-8")

        method = policy.split("isCurrentProcessMediaReplacementEnabledForValues", 1)[1]
        method = method.split("\n}", 1)[0]
        self.assertIn('values[@"enabled"]', method)
        self.assertIn("VCAMInjectionTargetCamera", method)


if __name__ == "__main__":
    unittest.main()