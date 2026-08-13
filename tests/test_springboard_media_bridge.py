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
        self.assertIn("localVideoReachedEnd", source)
        self.assertIn("springboard local video reached end; holding last frame", source)
        no_frame = source.split("if (!hasNewFrame)", 1)[1].split("CMTime displayTime", 1)[0]
        self.assertIn("if (self.localVideoReachedEnd) return", no_frame)

    def test_hls_prefers_live_edge_over_large_forward_buffer(self) -> None:
        source = (
            ROOT / "Sources" / "SpringBoard" / "VCAMSpringBoardMediaBridge.m"
        ).read_text(encoding="utf-8")
        self.assertIn("preferredForwardBufferDuration = 1.0", source)
        self.assertIn("automaticallyPreservesTimeOffsetFromLive = NO", source)
        self.assertIn("automaticallyWaitsToMinimizeStalling = YES", source)
        self.assertIn("VCAMLiveEdgeLagSeconds", source)
        self.assertIn("liveLag=%.3f", source)
        self.assertIn("8ULL * 1000000000ULL", source)
        self.assertIn("localVideo ? sourceFramesPerSecond : 60", source)

    def test_local_video_reuses_native_player_pipeline_and_keeps_daemon_rollback(self) -> None:
        source = (
            ROOT / "Sources" / "SpringBoard" / "VCAMSpringBoardMediaBridge.m"
        ).read_text(encoding="utf-8")
        producer = (ROOT / "Sources" / "Daemon" / "VCAMFrameProducer.m").read_text(
            encoding="utf-8"
        )

        self.assertIn("VCAMSourceKindLocalMedia", source)
        self.assertIn("fileURLWithPath:next.mediaPath", source)
        self.assertIn("AVPlayerItemDidPlayToEndTimeNotification", source)
        self.assertIn("seekToTime:kCMTimeZero", source)
        self.assertIn("/var/tmp/vcam-local-video-legacy-vcamd.enable", source)
        self.assertIn("/var/tmp/vcam-local-video-legacy-vcamd.enable", producer)
        self.assertIn("VCAMLocalMediaPathIsVideo", producer)
        self.assertIn("videoTrack.preferredTransform", source)
        self.assertIn("VCAMCoreImageLinearTransformForTrack", source)
        self.assertIn("preferredTransform.a, -preferredTransform.b", source)
        self.assertIn("-preferredTransform.c, preferredTransform.d", source)
        self.assertIn("top-left basis", source)
        self.assertIn("bottom-left basis", source)
        self.assertNotIn("sourceBufferNeedsTrackTransform", source)

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
        self.assertIn("render:renderImage toCVPixelBuffer:destination", source)
        self.assertIn("VCAMSharedSurfaceWriterCreateConfigured", source)
        self.assertIn("outputWidth, outputHeight", source)
        self.assertNotIn("CGContextDrawImage", source)
        self.assertNotIn("memcpy(", source)

    def test_iosurface_transport_has_bounded_ring_and_mmap_fallback(self) -> None:
        shared = (ROOT / "Sources" / "Shared" / "VCAMSharedFrame.m").read_text(
            encoding="utf-8"
        )
        consumer = (
            ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefImageUtils.m"
        ).read_text(encoding="utf-8")
        create_pixel_buffer = shared.split(
            "static CVPixelBufferRef VCAMSharedSurfaceCreatePixelBuffer", 1
        )[1].split("VCAMSharedSurfaceWriter *VCAMSharedSurfaceWriterCreate", 1)[0]
        self.assertIn("VCAMSharedFrameSlotCount", shared)
        self.assertIn("CVPixelBufferCreate(", create_pixel_buffer)
        self.assertIn("kCVPixelBufferIOSurfacePropertiesKey", create_pixel_buffer)
        self.assertIn("IOSurfaceCreate(", create_pixel_buffer)
        self.assertIn('@"IOSurfaceIsGlobal": @YES', create_pixel_buffer)
        self.assertIn("CVPixelBufferCreateWithIOSurface", create_pixel_buffer)
        self.assertIn("kIOSurfacePixelFormat: @(pixelFormat)", create_pixel_buffer)
        self.assertIn("pixelFormat == kCVPixelFormatType_32BGRA", create_pixel_buffer)
        self.assertNotIn("kCVPixelBufferMetalCompatibilityKey", create_pixel_buffer)
        self.assertIn("consumerUseState", shared)
        self.assertIn("VCAMSharedSurfaceAcquireUse", shared)
        self.assertIn("VCAMSharedSurfaceReleaseUse", shared)
        self.assertIn("consumerReady", shared)
        self.assertIn("atomic_compare_exchange_weak_explicit", shared)
        self.assertGreaterEqual(shared.count("VCAMSharedSurfaceReleaseUse(useCounter, surfaceID)"), 2)
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
        self.assertIn("VCAMSurfaceBrokerPeerIdentitySpringBoard", server)
        self.assertIn("VCAMSurfaceBrokerPeerIdentityMediaServer", server)
        self.assertIn("com.codex.vcam.surface", launchd)

    def test_static_surface_renders_in_springboard_single_shared_buffer(self) -> None:
        bridge = (
            ROOT / "Sources" / "SpringBoard" / "VCAMSpringBoardMediaBridge.m"
        ).read_text(encoding="utf-8")
        bootstrap = bridge.split("- (BOOL)publishStaticBootstrap", 1)[1].split(
            "- (BOOL)startStaticImage", 1
        )[0]
        self.assertIn("VCAMSetRGBColorAttachments(bootstrap)", bootstrap)
        producer = (ROOT / "Sources" / "Daemon" / "VCAMFrameProducer.m").read_text(
            encoding="utf-8"
        )

        static_path = bridge.split("- (BOOL)startStaticImage:", 1)[1].split(
            "- (void)refreshStaticImage:", 1
        )[0]
        self.assertIn("CGImageSourceCreateThumbnailWithTransform", static_path)
        self.assertIn("kCVPixelFormatType_32BGRA, 1", static_path)
        self.assertIn("VCAMSharedSurfaceWriterCopyNextPixelBuffer", static_path)
        self.assertIn("render:image toCVPixelBuffer:destination", static_path)
        self.assertIn("VCAMSharedSurfaceWriterPublish", static_path)
        self.assertIn("VCAMSharedSurfaceWriterRefreshLatest", bridge)
        self.assertIn("VCAMStaticImageMaximumStartRetries = 20", bridge)
        self.assertIn("scheduleStaticImageStartRetryForConfiguration", bridge)
        self.assertIn("self.staticImageStartRetryable = YES;", static_path)
        self.assertIn("static bootstrap deferred until refresh", static_path)
        self.assertNotIn("!surfacePublished || !bootstrapPublished", static_path)
        self.assertIn("BOOL transportCurrent = !self.staticImage", bridge)
        self.assertIn("if (!VCAMSharedSurfaceWriterIsCurrent(self.surfaceWriter))", bridge)
        self.assertIn("/var/tmp/vcam-local-image-legacy-vcamd.enable", bridge)
        self.assertIn("/var/tmp/vcam-local-image-legacy-vcamd.enable", producer)
        local_case = producer.split("case VCAMSourceKindLocalMedia:", 1)[1].split(
            "case VCAMSourceKindOBSWebSocket:", 1
        )[0]
        self.assertIn("if (daemonRollback)", local_case)

    def test_cgimage_renderer_keeps_image_row_order(self) -> None:
        renderer = (ROOT / "Sources" / "Core" / "VCAMFrameRenderer.m").read_text(
            encoding="utf-8"
        )
        direct_render = renderer.split("renderCGImage:", 1)[1].split(
            "copySampleFromPixelBuffer:", 1
        )[0]

        self.assertNotIn("CGContextScaleCTM(context, 1, -1)", direct_render)

    def test_mediaserver_transport_accepts_only_uncompressed_pixel_buffers(self) -> None:
        shared = (ROOT / "Sources" / "Shared" / "VCAMSharedFrame.m").read_text(
            encoding="utf-8"
        )
        mmap_publish = shared.split("bool VCAMSharedFrameWriterPublish", 1)[1].split(
            "bool VCAMSharedFrameSetRequestedActive", 1
        )[0]
        surface_create = shared.split(
            "VCAMSharedSurfaceWriter *VCAMSharedSurfaceWriterCreateWithPixelFormat", 1
        )[1].split("void VCAMSharedSurfaceWriterDestroy", 1)[0]

        self.assertIn("kCVPixelFormatType_32BGRA", mmap_publish)
        self.assertIn("CVPixelBufferLockBaseAddress", mmap_publish)
        for raw_format in (
            "kCVPixelFormatType_32BGRA",
            "kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange",
            "kCVPixelFormatType_420YpCbCr8BiPlanarFullRange",
        ):
            self.assertIn(raw_format, surface_create)
        for encoded_format in ("JPEG", "H264", "HEVC"):
            self.assertNotIn(encoded_format, surface_create)

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
