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

    def test_failed_hls_item_reconnects_with_bounded_backoff(self) -> None:
        source = (
            ROOT / "Sources" / "SpringBoard" / "VCAMSpringBoardMediaBridge.m"
        ).read_text(encoding="utf-8")
        self.assertIn("AVPlayerItemStatusFailed", source)
        self.assertIn("dispatch_after", source)
        self.assertIn("MIN((NSUInteger)30", source)
        self.assertIn("self.reconnectAttempt = 0", source)
        self.assertIn("springboard HLS reconnect", source)

    def test_ready_hls_item_reconnects_after_decoded_frame_stall(self) -> None:
        source = (
            ROOT / "Sources" / "SpringBoard" / "VCAMSpringBoardMediaBridge.m"
        ).read_text(encoding="utf-8")
        self.assertIn("VCAMHLSStallTimeoutNanoseconds", source)
        self.assertIn("lastDecodedFrameTimestampNanoseconds", source)
        self.assertIn("AVPlayerItemStatusReadyToPlay", source)
        self.assertIn("springboard HLS stalled", source)
        self.assertIn("scheduleReconnectForItem:item reason:", source)

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

    def test_xpc_bridge_uses_sdk_types_and_runtime_private_entrypoint(self) -> None:
        broker = (ROOT / "Sources" / "Shared" / "VCAMSurfaceBroker.m").read_text(
            encoding="utf-8"
        )
        server = (
            ROOT / "Sources" / "Daemon" / "VCAMSurfaceBrokerServer.m"
        ).read_text(encoding="utf-8")
        for source in (broker, server):
            self.assertIn("__has_include(<xpc/xpc.h>)", source)
            self.assertIn('#import <xpc/xpc.h>', source)
            self.assertIn('dlsym(RTLD_DEFAULT,', source)
            self.assertIn('"xpc_connection_create_mach_service"', source)
            self.assertIn("VCAMXPCMachServiceCreate(", source)
            self.assertIn("VCAMXPCRelease(", source)
            self.assertNotIn("extern xpc_connection_t xpc_connection_create_mach_service", source)
        self.assertIn('"xpc_connection_get_pid"', server)
        self.assertIn("VCAMXPCConnectionGetPID(", server)
        self.assertNotIn("pid_t pid = xpc_connection_get_pid(peer)", server)

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
