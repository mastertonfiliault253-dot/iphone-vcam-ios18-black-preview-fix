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
        for name in ("VCAMAppClient", "VCAMWebKitClient", "VCAMMediaServerClient"):
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


if __name__ == "__main__":
    unittest.main()
