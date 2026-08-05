import pathlib
import unittest


ROOT = pathlib.Path(__file__).parents[1]


class InjectionSafetyTests(unittest.TestCase):
    def test_only_mediaserverd_and_springboard_filters_exist(self) -> None:
        filters = {path.name for path in ROOT.glob("VCAM*.plist")}
        self.assertEqual(
            filters,
            {"VCAMMediaServerClient.plist", "VCAMSpringBoardClient.plist"},
        )

        media = (ROOT / "VCAMMediaServerClient.plist").read_text(encoding="utf-8")
        springboard = (ROOT / "VCAMSpringBoardClient.plist").read_text(encoding="utf-8")
        self.assertIn("mediaserverd", media)
        self.assertNotIn("Bundles", media)
        self.assertIn("com.apple.springboard", springboard)
        self.assertIn("SpringBoard", springboard)

    def test_makefile_builds_exactly_two_injected_targets(self) -> None:
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        target_line = next(
            line for line in makefile.splitlines() if line.startswith("TWEAK_NAME =")
        )
        self.assertEqual(
            target_line,
            "TWEAK_NAME = VCAMMediaServerClient VCAMSpringBoardClient",
        )
        self.assertIn("TOOL_NAME = vcamd", makefile)
        for removed in ("VCAMAppClient", "VCAMWebKitClient", "VCAMDaemonProbe"):
            self.assertNotIn(removed, target_line)

    def test_mediaserver_consumer_has_no_decoder_or_network_code(self) -> None:
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        implementation = (
            ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefImageUtils.m"
        ).read_text(encoding="utf-8")
        self.assertIn("VCAMSharedFrameReaderCopyLatest", implementation)
        self.assertNotIn("libav", implementation)
        self.assertNotIn("AVAssetReader", implementation)
        self.assertNotIn("NSURLSession", implementation)

        frameworks_line = next(
            line
            for line in makefile.splitlines()
            if line.startswith("VCAMMediaServerClient_FRAMEWORKS")
        )
        self.assertNotIn("UIKit", frameworks_line)
        self.assertNotIn("AVFoundation", frameworks_line)
        self.assertNotIn("VideoToolbox", frameworks_line)

    def test_mediaserver_keeps_validated_node_gate_and_fails_open(self) -> None:
        implementation = (
            ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefImageUtils.m"
        ).read_text(encoding="utf-8")
        entry = (
            ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefEntry.xm"
        ).read_text(encoding="utf-8")
        self.assertIn("targetWidth != 750 || targetHeight != 1334", implementation)
        self.assertIn("1000000000ULL", implementation)
        self.assertIn("BWNodeOutput", entry)
        self.assertIn("%orig(sampleBuffer)", entry)

    def test_real_microphone_is_forced(self) -> None:
        configuration = (
            ROOT / "Sources" / "Core" / "VCAMConfiguration.m"
        ).read_text(encoding="utf-8")
        panel = (
            ROOT / "Sources" / "UI" / "VCAMControlPanelViewController.m"
        ).read_text(encoding="utf-8")
        self.assertIn("configuration.replaceAudio = NO", configuration)
        self.assertNotIn("audioTapped", panel)
        self.assertNotIn("替换声音", panel)


if __name__ == "__main__":
    unittest.main()
