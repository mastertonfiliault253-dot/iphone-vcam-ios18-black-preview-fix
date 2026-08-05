import json
import pathlib
import plistlib
import unittest


ROOT = pathlib.Path(__file__).parents[1]


class PackagingArchitectureTests(unittest.TestCase):
    def test_manifest_describes_two_injections_and_one_worker(self) -> None:
        manifest = json.loads((ROOT / "packaging" / "targets.json").read_text(encoding="utf-8"))
        targets = {target["name"]: target for target in manifest["targets"]}
        self.assertEqual(
            set(targets),
            {"VCAMMediaServerClient", "VCAMSpringBoardClient", "vcamd"},
        )
        self.assertTrue(targets["VCAMMediaServerClient"]["injected"])
        self.assertTrue(targets["VCAMSpringBoardClient"]["injected"])
        self.assertFalse(targets["vcamd"]["injected"])
        self.assertEqual(targets["VCAMMediaServerClient"]["executables"], ["mediaserverd"])

    def test_launchdaemon_runs_package_worker_from_rootless_prefix(self) -> None:
        launchd = (
            ROOT / "layout" / "Library" / "LaunchDaemons" / "com.codex.vcamd.plist"
        ).read_text(encoding="utf-8")
        postinst = (ROOT / "layout" / "DEBIAN" / "postinst").read_text(encoding="utf-8")
        prerm = (ROOT / "layout" / "DEBIAN" / "prerm").read_text(encoding="utf-8")
        self.assertIn("com.codex.vcamd", launchd)
        self.assertIn("<string>/var/jb/usr/libexec/vcamd</string>", launchd)
        self.assertNotIn("tweaksupport", launchd)
        self.assertIn("launchctl bootstrap system", postinst)
        self.assertIn("launchctl kickstart -k user/foreground/com.codex.vcamd", postinst)
        self.assertIn("for attempt in 1 2 3 4 5", postinst)
        self.assertIn("launchctl print user/foreground/com.codex.vcamd", postinst)
        self.assertIn("launchctl bootout user/foreground/com.codex.vcamd", prerm)

    def test_realtime_worker_sets_decoder_jetsam_budget_before_allocating(self) -> None:
        launchd_path = (
            ROOT / "layout" / "Library" / "LaunchDaemons" / "com.codex.vcamd.plist"
        )
        launchd = plistlib.loads(launchd_path.read_bytes())
        self.assertEqual(launchd["ProcessType"], "Interactive")
        self.assertEqual(launchd["UserName"], "mobile")
        self.assertNotIn("JetsamProperties", launchd)

        entitlements = plistlib.loads((ROOT / "vcamd.entitlements").read_bytes())
        self.assertEqual(entitlements, {"com.apple.private.memorystatus": True})
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        self.assertIn(
            "vcamd_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/vcamd.entitlements",
            makefile,
        )

        main = (ROOT / "Sources" / "Daemon" / "main.m").read_text(encoding="utf-8")
        self.assertIn("MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES", main)
        self.assertIn("MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES", main)
        self.assertIn("memlimit_active = VCAMWorkerMemoryLimitMB", main)
        self.assertIn("memlimit_inactive = VCAMWorkerMemoryLimitMB", main)
        self.assertIn("VCAMWorkerMemoryLimitMB = 256", main)
        self.assertLess(
            main.index("VCAMRaiseJetsamMemoryLimit();"),
            main.index("VCAMSharedFrameWriterCreate();"),
        )

    def test_package_scheme_is_rootless_only(self) -> None:
        manifest = json.loads((ROOT / "packaging" / "targets.json").read_text(encoding="utf-8"))
        build = (ROOT / "scripts" / "build-all.sh").read_text(encoding="utf-8")
        self.assertEqual(manifest["scheme"], "rootless")
        self.assertIn("THEOS_PACKAGE_SCHEME=rootless", build)
        self.assertNotIn("THEOS_PACKAGE_SCHEME=roothide", build)
        self.assertFalse((ROOT / "scripts" / "build-roothide-wsl.sh").exists())
        self.assertTrue((ROOT / "scripts" / "build-rootless-wsl.sh").exists())

    def test_shared_transport_is_triple_buffered_atomic_and_stale_aware(self) -> None:
        header = (ROOT / "Sources" / "Shared" / "VCAMSharedFrame.h").read_text(encoding="utf-8")
        implementation = (ROOT / "Sources" / "Shared" / "VCAMSharedFrame.m").read_text(encoding="utf-8")
        self.assertIn("VCAMSharedFrameSlotCount = 3", header)
        self.assertIn("mmap", implementation)
        self.assertIn("_Atomic", implementation)
        self.assertIn("slotSequence[slot], 0", implementation)
        self.assertIn("maximumAgeNanoseconds", implementation)
        self.assertIn("active", implementation)

    def test_worker_hides_source_selection_and_publication(self) -> None:
        producer = (ROOT / "Sources" / "Daemon" / "VCAMFrameProducer.m").read_text(encoding="utf-8")
        main = (ROOT / "Sources" / "Daemon" / "main.m").read_text(encoding="utf-8")
        for source in ("VCAMLocalMediaSource", "VCAMOBSStreamSource", "VCAMRTSPStreamSource"):
            self.assertIn(source, producer)
        self.assertIn("VCAMSharedFrameWriterPublish", main)
        self.assertIn("VCAMSharedFrameWriterClear", main)
        self.assertIn("preferences.changed", main)

    def test_headless_renderer_has_no_core_image_or_gpu_context(self) -> None:
        renderer = (ROOT / "Sources" / "Core" / "VCAMFrameRenderer.m").read_text(encoding="utf-8")
        producer = (ROOT / "Sources" / "Daemon" / "VCAMFrameProducer.m").read_text(encoding="utf-8")
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        self.assertIn("CGBitmapContextCreate", renderer)
        self.assertIn("VTCreateCGImageFromCVPixelBuffer", renderer)
        self.assertIn("kCVPixelBufferCGImageCompatibilityKey", renderer)
        self.assertIn("kCVPixelBufferCGBitmapContextCompatibilityKey", renderer)
        self.assertNotIn("kCVPixelBufferIOSurfacePropertiesKey", renderer)
        self.assertNotIn("kCVPixelBufferIOSurfacePropertiesKey", producer)
        self.assertNotIn("CIContext", renderer)
        self.assertNotIn("CoreImage", makefile.split("vcamd_FRAMEWORKS", 1)[1].splitlines()[0])
        self.assertIn("vcamd_ARCHS = arm64", makefile)

    def test_ffmpeg_is_linked_only_to_worker(self) -> None:
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        self.assertIn("vcamd_LIBRARIES = avformat avcodec avutil", makefile)
        self.assertNotIn("VCAMMediaServerClient_LIBRARIES", makefile)
        self.assertNotIn("VCAMSpringBoardClient_LIBRARIES", makefile)

    def test_configuration_accepts_images_and_worker_direct_read(self) -> None:
        configuration = (ROOT / "Sources" / "Core" / "VCAMConfiguration.m").read_text(encoding="utf-8")
        for extension in ('@"png"', '@"jpg"', '@"jpeg"', '@"heic"', '@"heif"'):
            self.assertIn(extension, configuration)
        self.assertIn("isMediaWorkerHost", configuration)
        self.assertIn("self.isWriteBrokerHost || self.isMediaWorkerHost", configuration)
        self.assertIn("VCAMLocalDecoderModeSinglePlayer", configuration)

    def test_springboard_contains_preview_but_no_source_decoder(self) -> None:
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        preview = (ROOT / "Sources" / "UI" / "VCAMSharedFramePreviewView.m").read_text(encoding="utf-8")
        panel = (ROOT / "Sources" / "UI" / "VCAMControlPanelViewController.m").read_text(encoding="utf-8")
        self.assertIn("VCAMSharedFramePreviewView.m", makefile)
        self.assertIn("VCAMSharedFrameReaderCopyLatest", preview)
        self.assertIn("AVSampleBufferDisplayLayer", preview)
        self.assertIn("VCAMSharedFramePreviewView", panel)
        self.assertNotIn("presentTargetSelector", panel)


if __name__ == "__main__":
    unittest.main()
