import json
import pathlib
import unittest


ROOT = pathlib.Path(__file__).parents[1]


class PackagingArchitectureTests(unittest.TestCase):
    def test_process_targets_are_mapped_to_separate_packages(self) -> None:
        manifest = json.loads((ROOT / "packaging" / "targets.json").read_text(encoding="utf-8"))
        targets = {target["name"]: target for target in manifest["targets"]}

        self.assertEqual(targets["VCAMController"]["bundleIds"], ["com.apple.camera"])
        self.assertEqual(
            targets["VCAMAppClient"]["bundleIds"],
            ["com.apple.mobilesafari", "com.google.chrome.ios"],
        )
        self.assertTrue(targets["VCAMWebKitClient"]["separateBinary"])
        self.assertEqual(targets["VCAMMediaServerClient"]["executables"], ["mediaserverd"])
        self.assertTrue(targets["VCAMMediaServerClient"]["separatePackage"])
        self.assertFalse(targets["VCAMMediaServerClient"]["defaultEnabled"])

    def test_daemon_owns_decode_and_clients_forbid_ui_or_ffmpeg(self) -> None:
        manifest = json.loads((ROOT / "packaging" / "targets.json").read_text(encoding="utf-8"))
        targets = {target["name"]: target for target in manifest["targets"]}

        self.assertEqual(targets["vcamd"]["role"], "decode-and-publish-iosurface")
        for name in ("VCAMAppClient", "VCAMWebKitClient", "VCAMMediaServerClient"):
            forbidden = targets[name]["forbiddenDependencies"]
            self.assertIn("PhotosUI", forbidden)
            self.assertIn("FFmpeg", forbidden)
        self.assertIn("UIKit", targets["VCAMMediaServerClient"]["forbiddenDependencies"])


if __name__ == "__main__":
    unittest.main()
