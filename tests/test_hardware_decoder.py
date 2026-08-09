import pathlib
import unittest


ROOT = pathlib.Path(__file__).parents[1]


class HardwareDecoderTests(unittest.TestCase):
    def test_vcamd_has_hardware_decoder_entitlement(self) -> None:
        entitlements = (ROOT / "vcamd.entitlements").read_text(encoding="utf-8")
        self.assertIn("platform-application", entitlements)
        self.assertIn("com.apple.videotoolbox.hardwarevideodecoder", entitlements)

    def test_video_toolbox_session_uses_ios_default_decoder(self) -> None:
        decoder = (ROOT / "Sources" / "Daemon" / "VCAMHardwareVideoDecoder.m").read_text(
            encoding="utf-8"
        )
        # iPhoneOS 16.5 excludes the macOS-only Enable/Require/UsingHardware
        # keys behind !TARGET_OS_IPHONE. Let iOS select its native decoder.
        create = decoder.split("VTDecompressionSessionCreate(", 1)[1].split(
            "&_session);", 1
        )[0]
        self.assertIn("NULL,", create)
        self.assertNotIn("_decoderSpecification", create)
        self.assertNotIn("UsingHardwareAcceleratedVideoDecoder", decoder)
        self.assertNotIn("kVTDecompressionPropertyKey_RealTime", decoder)

    def test_reference_missing_error_is_recoverable(self) -> None:
        decoder = (ROOT / "Sources" / "Daemon" / "VCAMHardwareVideoDecoder.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("kVTVideoDecoderReferenceMissingErr", decoder)
        self.assertIn("reference frame missing", decoder)
        self.assertIn("status == noErr || status == kVTVideoDecoderReferenceMissingErr", decoder)

    def test_annex_b_samples_are_converted_to_length_prefixed(self) -> None:
        decoder = (ROOT / "Sources" / "Daemon" / "VCAMHardwareVideoDecoder.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("VCAMFilterParameterSetNALs", decoder)
        self.assertIn("VCAMIsAnnexBStartCode", decoder)
        self.assertIn("annexB conversion failed", decoder)
        self.assertIn("VCAMIsParameterSetNAL", decoder)

    def test_annex_b_parser_excludes_trailing_zero_bytes_from_nals(self) -> None:
        decoder = (ROOT / "Sources" / "Daemon" / "VCAMHardwareVideoDecoder.m").read_text(
            encoding="utf-8"
        )
        # Real x264 SPS boundary: ...50 00 | 00 00 00 01 68...
        # The first zero is trailing_zero_8bits, not SPS payload.
        self.assertIn("VCAMTrimAnnexBTrailingZeroBytes", decoder)
        self.assertGreaterEqual(decoder.count("VCAMTrimAnnexBTrailingZeroBytes("), 4)

    def test_annex_b_parameter_sets_are_accepted_for_h264_and_hevc(self) -> None:
        decoder = (ROOT / "Sources" / "Daemon" / "VCAMHardwareVideoDecoder.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("VCAMCollectH264AnnexBParameterSets", decoder)
        self.assertIn("VCAMCollectHEVCAnnexBParameterSets", decoder)
        self.assertIn("H264 annexB psets sps=%d pps=%d status=%d", decoder)
        self.assertIn("HEVC annexB psets vps=%d sps=%d pps=%d status=%d", decoder)

    def test_packet_memory_uses_verified_block_buffer_pattern(self) -> None:
        decoder = (ROOT / "Sources" / "Daemon" / "VCAMHardwareVideoDecoder.m").read_text(
            encoding="utf-8"
        )
        # 0.8.10's block-buffer construction (NULL memory block + explicit
        # ReplaceDataBytes) is the pattern that produced decoded frames on the
        # iOS 16.5 device; keep it byte-for-byte.
        self.assertIn("CMBlockBufferReplaceDataBytes(feedBytes, blockBuffer, 0, feedLength)", decoder)
        create = decoder.split("CMBlockBufferCreateWithMemoryBlock(", 1)[1].split(
            "&blockBuffer);", 1
        )[0]
        self.assertIn("NULL,", create)
        self.assertNotIn("ownedBytes", decoder)

    def test_rtsp_direct_decoder_waits_for_an_idr_and_marks_sync_samples(self) -> None:
        decoder = (ROOT / "Sources" / "Daemon" / "VCAMHardwareVideoDecoder.m").read_text(
            encoding="utf-8"
        )
        header = (ROOT / "Sources" / "Daemon" / "VCAMHardwareVideoDecoder.h").read_text(
            encoding="utf-8"
        )
        rtsp = (ROOT / "Sources" / "Sources" / "VCAMRTSPStreamSource.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("isKeyFrame:(BOOL)isKeyFrame", header)
        self.assertIn("kCMSampleAttachmentKey_NotSync", decoder)
        self.assertIn("kCMSampleAttachmentKey_DependsOnOthers", decoder)
        self.assertIn("isKeyFrame ? kCFBooleanFalse : kCFBooleanTrue", decoder)
        self.assertIn("BOOL receivedKeyPacket = NO", rtsp)
        self.assertIn("packet->flags & AV_PKT_FLAG_KEY", rtsp)
        self.assertIn("if (!receivedKeyPacket && !isKeyFrame)", rtsp)
        self.assertIn("if (isKeyFrame && !receivedKeyPacket)", rtsp)
        self.assertIn("isKeyFrame:isKeyFrame", rtsp)
        loop = rtsp.split("while (self.running && av_read_frame", 1)[1].split(
            "[decoder flush]", 1
        )[0]
        self.assertIn("sessionStart = CFAbsoluteTimeGetCurrent();", rtsp)
        self.assertLess(
            rtsp.index("hardware session codec="),
            rtsp.index("sessionStart = CFAbsoluteTimeGetCurrent();", rtsp.index("hardware session codec=")),
        )
        self.assertIn("receivedKeyPacket &&", loop)
        self.assertLess(
            loop.index("if (!receivedKeyPacket && !isKeyFrame)"),
            loop.index("[decoder decodePacket:"),
        )

    def test_rtsp_direct_decoder_preserves_packet_timing_after_the_first_idr(self) -> None:
        rtsp = (ROOT / "Sources" / "Sources" / "VCAMRTSPStreamSource.m").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("seconds < 0", rtsp)
        self.assertIn("CMTime timelineOrigin = kCMTimeInvalid", rtsp)
        self.assertIn("timelineOrigin = pts", rtsp)
        self.assertIn("pts = CMTimeSubtract(pts, timelineOrigin)", rtsp)
        self.assertIn("duration:VCAMPacketDuration(packet, stream)", rtsp)

    def test_hls_uses_the_ffmpeg_videotoolbox_stream_source(self) -> None:
        stream = (ROOT / "Sources" / "Sources" / "VCAMRTSPStreamSource.m").read_text(
            encoding="utf-8"
        )
        producer = (ROOT / "Sources" / "Daemon" / "VCAMFrameProducer.m").read_text(
            encoding="utf-8"
        )
        pipeline = (ROOT / "Sources" / "Core" / "VCAMFramePipeline.m").read_text(
            encoding="utf-8"
        )
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")

        self.assertIn("configuration.sourceKind == VCAMSourceKindHLS", stream)
        self.assertIn("configuration.hlsURL", stream)
        self.assertIn('@"http"', stream)
        self.assertIn('@"https"', stream)
        self.assertIn('av_dict_set(options, "rw_timeout", "3000000", 0)', stream)
        self.assertIn("if (self.usesRTSPTransport)", stream)
        self.assertIn('@"%@ hardware first-frame size=', stream)
        self.assertNotIn('@"rtsp ', stream)
        self.assertIn("self.softwareFallbackActive = NO;", stream)
        self.assertIn("CACurrentMediaTime() < self.hardwareRetryDeadline", stream)
        self.assertIn("software retry window elapsed; retrying hardware", stream)
        self.assertNotIn("static volatile int consecutiveSendFailures", stream)
        self.assertEqual(producer.count("[[VCAMRTSPStreamSource alloc]"), 2)
        self.assertEqual(pipeline.count("[[VCAMRTSPStreamSource alloc]"), 2)
        self.assertNotIn("VCAMHLSStreamSource", producer)
        self.assertNotIn("VCAMHLSStreamSource", pipeline)
        self.assertNotIn("VCAMHLSStreamSource.m", makefile)
        self.assertFalse((ROOT / "Sources" / "Sources" / "VCAMHLSStreamSource.h").exists())
        self.assertFalse((ROOT / "Sources" / "Sources" / "VCAMHLSStreamSource.m").exists())

    def test_ffmpeg_build_includes_hls_http_and_mpegts(self) -> None:
        build = (ROOT / "scripts" / "build-ffmpeg-ios.sh").read_text(encoding="utf-8")
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")

        self.assertIn("--enable-securetransport", build)
        self.assertIn("--enable-protocol=file,tcp,udp,http,https,tls,crypto", build)
        self.assertIn("--enable-demuxer=mov,rtsp,rtp,sdp,hls,mpegts", build)
        self.assertIn("Security", makefile)

    def test_transient_debug_diagnostics_are_not_shipped(self) -> None:
        decoder = (ROOT / "Sources" / "Daemon" / "VCAMHardwareVideoDecoder.m").read_text(
            encoding="utf-8"
        )
        rtsp = (ROOT / "Sources" / "Sources" / "VCAMRTSPStreamSource.m").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("[DEBUG-a4f2]", decoder)
        self.assertNotIn("vcam-rtsp-pkt", rtsp)
        self.assertNotIn("vcam-diagnostic-software", rtsp)
        self.assertNotIn("rtsp packet dump", rtsp)

    def test_videotoolbox_packet_probe_is_bounded_and_device_visible(self) -> None:
        decoder = (ROOT / "Sources" / "Daemon" / "VCAMHardwareVideoDecoder.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("[DEBUG-vtpack]", decoder)
        self.assertIn("packetDiagnostic <= 4", decoder)
        self.assertIn("VCAMConfiguration appendProcessLog", decoder)

        stream = (ROOT / "Sources" / "Sources" / "VCAMRTSPStreamSource.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("[DEBUG-vtff]", stream)
        self.assertIn("count <= 40", stream)
        self.assertIn("level > AV_LOG_WARNING", stream)
        self.assertIn("VCAMCaptureFFmpegHardwareLogs", stream)


if __name__ == "__main__":
    unittest.main()
