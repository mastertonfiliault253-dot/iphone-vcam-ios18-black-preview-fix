import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class SpringBoardMediaBridgeTests(unittest.TestCase):
    def test_hls_uses_avplayer_nv12_metal_and_shared_writer(self) -> None:
        source = (
            ROOT / "Sources" / "SpringBoard" / "VCAMSpringBoardMediaBridge.m"
        ).read_text(encoding="utf-8")
        self.assertIn("AVPlayerItemVideoOutput", source)
        self.assertIn("kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange", source)
        self.assertIn("kCVPixelBufferIOSurfacePropertiesKey", source)
        self.assertIn("contextWithMTLDevice", source)
        self.assertIn("VCAMSharedFrameWriterPublish", source)
        self.assertNotIn("VTDecompressionSession", source)
        self.assertNotIn("avcodec_", source)

    def test_bridge_is_lifecycle_owned_and_keeps_legacy_rollback(self) -> None:
        source = (
            ROOT / "Sources" / "SpringBoard" / "VCAMSpringBoardMediaBridge.m"
        ).read_text(encoding="utf-8")
        producer = (ROOT / "Sources" / "Daemon" / "VCAMFrameProducer.m").read_text(
            encoding="utf-8"
        )
        entry = (ROOT / "Sources" / "Hooks" / "VCAMSpringBoardEntry.xm").read_text(
            encoding="utf-8"
        )
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        self.assertIn("com.codex.vcam/preferences.changed", source)
        self.assertIn("- (void)reload", source)
        self.assertIn("- (void)stop", source)
        self.assertIn("VCAMSpringBoardMediaBridge sharedBridge", entry)
        self.assertIn("Sources/SpringBoard/VCAMSpringBoardMediaBridge.m", makefile)
        self.assertIn("CoreImage", makefile)
        self.assertIn("Metal", makefile)
        self.assertIn("/var/tmp/vcam-hls-legacy-vcamd.enable", source)
        self.assertIn("/var/tmp/vcam-hls-legacy-vcamd.enable", producer)

    def test_gpu_output_is_triple_buffered_and_one_pass(self) -> None:
        source = (
            ROOT / "Sources" / "SpringBoard" / "VCAMSpringBoardMediaBridge.m"
        ).read_text(encoding="utf-8")
        self.assertIn("kCVPixelBufferPoolMinimumBufferCountKey", source)
        self.assertIn("VCAMSharedFrameSlotCount", source)
        self.assertIn("imageByApplyingTransform", source)
        self.assertIn("render:image toCVPixelBuffer:destination", source)
        self.assertNotIn("CGContextDrawImage", source)
        self.assertNotIn("memcpy(", source)


if __name__ == "__main__":
    unittest.main()
