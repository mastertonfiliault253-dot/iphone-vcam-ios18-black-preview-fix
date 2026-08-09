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
        self.assertIn("VCAMSharedSurfaceWriterCopyNextPixelBuffer", source)
        self.assertIn("VCAMSharedSurfaceWriterPublish", source)
        self.assertIn("springboard HLS health", source)
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
        self.assertNotIn("removeOutput:self.output", source)
        self.assertIn("springboard HLS stop detached", source)
        self.assertIn("QOS_CLASS_UTILITY", source)
        self.assertNotIn("[self.player pause]", source)
        self.assertIn("VCAMSpringBoardMediaBridge sharedBridge", entry)
        self.assertIn("Sources/SpringBoard/VCAMSpringBoardMediaBridge.m", makefile)
        self.assertIn("CoreImage", makefile)
        self.assertIn("Metal", makefile)
        self.assertIn("IOSurface", makefile)
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

    def test_iosurface_transport_has_bounded_ring_and_mmap_fallback(self) -> None:
        shared = (ROOT / "Sources" / "Shared" / "VCAMSharedFrame.m").read_text(
            encoding="utf-8"
        )
        consumer = (
            ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefImageUtils.m"
        ).read_text(encoding="utf-8")
        self.assertIn("VCAMSharedFrameSlotCount", shared)
        self.assertIn("IOSurfaceCreate", shared)
        self.assertIn("CVPixelBufferCreateWithIOSurface", shared)
        self.assertIn('@"IOSurfaceIsGlobal"', shared)
        self.assertIn("consumerUseCount", shared)
        self.assertIn("consumerReady", shared)
        self.assertIn("atomic_fetch_add_explicit(useCounter", shared)
        self.assertIn("IOSurfaceIncrementUseCount", shared)
        self.assertIn("IOSurfaceDecrementUseCount", shared)
        self.assertIn("VCAMSharedSurfaceReaderCopyLatest", consumer)
        self.assertIn("VCAMSharedFrameReaderCopyLatest", consumer)
        self.assertIn("VCAMSurfaceBrokerCopySurface", shared)

        broker = (ROOT / "Sources" / "Shared" / "VCAMSurfaceBroker.m").read_text(
            encoding="utf-8"
        )
        server = (
            ROOT / "Sources" / "Daemon" / "VCAMSurfaceBrokerServer.m"
        ).read_text(encoding="utf-8")
        launchd = (
            ROOT / "layout" / "Library" / "LaunchDaemons" / "com.codex.vcamd.plist"
        ).read_text(encoding="utf-8")
        self.assertIn("IOSurfaceCreateXPCObject", broker)
        self.assertIn("IOSurfaceLookupFromXPCObject", broker)
        self.assertIn('VCAMSurfaceBrokerPeerIs(peer, "SpringBoard")', server)
        self.assertIn('VCAMSurfaceBrokerPeerIs(peer, "mediaserverd")', server)
        self.assertIn("com.codex.vcam.surface", launchd)

    def test_iosurface_bootstrap_keeps_mmap_live_until_consumer_ready(self) -> None:
        bridge = (
            ROOT / "Sources" / "SpringBoard" / "VCAMSpringBoardMediaBridge.m"
        ).read_text(encoding="utf-8")
        shared = (ROOT / "Sources" / "Shared" / "VCAMSharedFrame.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("VCAMSharedSurfaceWriterHasConsumer", bridge)
        self.assertIn("VCAMSharedFrameWriterPublish(self.writer, destination)", bridge)
        self.assertIn("iosurface+bootstrap-mmap", bridge)
        self.assertIn("VCAMSharedSurfaceReaderSetReady(reader, true)", shared)
        self.assertIn("VCAMSharedSurfaceReaderSetReady(reader, false)", shared)


if __name__ == "__main__":
    unittest.main()
