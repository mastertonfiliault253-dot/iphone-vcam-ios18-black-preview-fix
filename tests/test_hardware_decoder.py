import pathlib
import unittest


ROOT = pathlib.Path(__file__).parents[1]


class HardwareDecoderTests(unittest.TestCase):
    def test_rtsp_native_nv12_uses_iosurface_without_the_bgra_round_trip(self) -> None:
        converter = (ROOT / "Sources" / "Daemon" / "VCAMPixelConverter.m").read_text(
            encoding="utf-8"
        )
        stream = (ROOT / "Sources" / "Sources" / "VCAMRTSPStreamSource.m").read_text(
            encoding="utf-8"
        )
        producer = (ROOT / "Sources" / "Daemon" / "VCAMFrameProducer.m").read_text(
            encoding="utf-8"
        )
        daemon = (ROOT / "Sources" / "Daemon" / "main.m").read_text(encoding="utf-8")
        shared = (ROOT / "Sources" / "Shared" / "VCAMSharedFrame.m").read_text(
            encoding="utf-8"
        )

        self.assertIn("VCAMCopyNV12FromAVFrame", converter)
        self.assertIn("copyNativePixelBufferForSharedCanvas", stream)
        self.assertIn("copyNativePixelBufferForSharedCanvas", producer)
        self.assertIn("VCAMSharedSurfaceWriterCreateWithPixelFormat", daemon)
        self.assertIn("VCAMCopyPixelBufferPlanes", daemon)
        self.assertIn("VCAMSharedSurfaceWriterHasConsumer", daemon)
        self.assertIn("vcamd native IOSurface published", daemon)
        self.assertIn("vcamd native IOSurface consumer accepted", daemon)
        self.assertIn("BGRA fallback active", daemon)
        self.assertIn("kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange", shared)
        self.assertIn("header->pixelFormat", shared)
        self.assertIn("consumerHeartbeatNanoseconds", shared)
        self.assertIn("kill((pid_t)processID, 0)", shared)
        self.assertIn("VCAMProcessIsAlive(consumerPID)", shared)
        self.assertIn("now - heartbeat <= 2000000000ULL", shared)
        self.assertIn("VCAMSharedSurfaceReaderSetReady(reader, false)", shared)
        self.assertIn("producerPID", shared)
        self.assertIn("VCAMSharedSurfaceWriterIsCurrent", shared)
        self.assertIn("VCAMProcessIsAlive(activeProducer)", shared)
        self.assertIn("!VCAMSharedSurfaceWriterIsCurrent(VCAMSurfaceWriter)", daemon)

    def test_hd_yuv_fallback_uses_bt709_instead_of_bt601(self) -> None:
        converter = (ROOT / "Sources" / "Daemon" / "VCAMPixelConverter.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("VCAMITU709Matrix", converter)
        self.assertIn("VCAMYpCbCrMatrixForDimensions", converter)
        self.assertIn("MAX(width, height) >= 1280", converter)
    def test_vcamd_has_hardware_decoder_entitlement(self) -> None:
        entitlements = (ROOT / "vcamd.entitlements").read_text(encoding="utf-8")
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
        self.assertIn("destinationAttributes", create)
        self.assertIn("kCVPixelBufferIOSurfacePropertiesKey", decoder)
        self.assertNotIn("UsingHardwareAcceleratedVideoDecoder", decoder)
        self.assertNotIn("kVTDecompressionPropertyKey_RealTime", decoder)

    def test_reference_missing_error_is_recoverable(self) -> None:
        decoder = (ROOT / "Sources" / "Daemon" / "VCAMHardwareVideoDecoder.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("kVTVideoDecoderReferenceMissingErr", decoder)
        self.assertNotIn("#define kVTVideoDecoderReferenceMissingErr", decoder)
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

    def test_length_prefixed_slice_without_parameter_sets_keeps_original_length(self) -> None:
        decoder = (ROOT / "Sources" / "Daemon" / "VCAMHardwareVideoDecoder.m").read_text(
            encoding="utf-8"
        )

        passthrough = decoder.split("if (!sawParameterSet && !annexB)", 1)[1].split(
            "if (nalCount == 0", 1
        )[0]
        self.assertIn("*outLength = length;", passthrough)
        self.assertIn("return NULL;", passthrough)

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

    def test_rtsp_uses_ffmpeg_upstream_videotoolbox_contract(self) -> None:
        rtsp = (ROOT / "Sources" / "Sources" / "VCAMRTSPStreamSource.m").read_text(
            encoding="utf-8"
        )
        session = rtsp.split("- (BOOL)decodeOneSession", 1)[1].split(
            "- (BOOL)decodeOneFFmpegSessionUsingHardware", 1
        )[0]
        self.assertNotIn("decodeOneHardwareSession", session)
        self.assertIn("decodeOneFFmpegSessionUsingHardware:YES", session)
        self.assertIn("decodeOneFFmpegSessionUsingHardware:NO", session)
        self.assertIn("avcodec_get_hw_config(decoder, index)", rtsp)
        self.assertIn("AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX", rtsp)
        self.assertIn("config->device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX", rtsp)
        self.assertIn("hardwareState.pixelFormat = config->pix_fmt", rtsp)
        self.assertIn("codecContext->opaque = &hardwareState", rtsp)
        self.assertIn("decodedFrame->data[3]", rtsp)

    def test_ffmpeg_upstream_path_passes_demuxed_packets_without_manual_au_filtering(self) -> None:
        stream = (ROOT / "Sources" / "Sources" / "VCAMRTSPStreamSource.m").read_text(
            encoding="utf-8"
        )
        loop = stream.split("- (BOOL)decodeOneFFmpegSessionUsingHardware", 1)[1].split(
            "cleanup:", 1
        )[0]
        self.assertIn("avcodec_parameters_to_context(codecContext, stream->codecpar)", loop)
        self.assertIn("avcodec_send_packet(codecContext, packet)", loop)
        self.assertIn("avcodec_receive_frame(codecContext, frame)", loop)
        self.assertNotIn("AV_PKT_FLAG_KEY", loop)
        self.assertNotIn("VCAMCopyCodecParametersWithPacketExtradata", loop)

    def test_rtsp_reconnects_when_either_decoder_stops_producing_frames(self) -> None:
        stream = (ROOT / "Sources" / "Sources" / "VCAMRTSPStreamSource.m").read_text(
            encoding="utf-8"
        )
        session = stream.split("- (BOOL)decodeOneFFmpegSessionUsingHardware", 1)[1].split(
            "cleanup:", 1
        )[0]

        self.assertIn("if (videoPacketsWithoutFrame >= 300)", session)
        self.assertNotIn(
            "if (useHardware && !producedFrame && videoPacketsWithoutFrame >= 300)",
            session,
        )
        self.assertIn("decoder stalled hardware=%d packets=300; reconnecting", session)

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

    def test_hls_direct_vt_bootstraps_in_band_parameter_sets(self) -> None:
        stream = (ROOT / "Sources" / "Sources" / "VCAMRTSPStreamSource.m").read_text(
            encoding="utf-8"
        )

        self.assertIn("VCAMCopyCodecParametersWithPacketExtradata", stream)
        self.assertIn("stream->codecpar->extradata_size > 0", stream)
        self.assertIn("AV_INPUT_BUFFER_PADDING_SIZE", stream)
        self.assertIn("direct-VT using in-band parameter sets", stream)

    def test_ffmpeg_build_includes_hls_http_and_mpegts(self) -> None:
        build = (ROOT / "scripts" / "build-ffmpeg-ios.sh").read_text(encoding="utf-8")
        linux_build = (ROOT / "scripts" / "build-ffmpeg-ios-linux.sh").read_text(
            encoding="utf-8"
        )
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")

        self.assertIn("--enable-securetransport", build)
        self.assertIn("--enable-protocol=file,tcp,udp,http,https,tls,crypto", build)
        for script in (build, linux_build):
            self.assertIn("--enable-protocol=file,tcp,udp,http", script)
            self.assertIn("--enable-demuxer=mov,rtsp,rtp,sdp,hls,mpegts", script)
        self.assertIn("Security", makefile)

    def test_ffmpeg_linux_build_uses_self_contained_llvm_archive_tools(self) -> None:
        build = (ROOT / "scripts" / "build-ffmpeg-ios-linux.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn("llvm-ar llvm-ranlib", build)
        self.assertIn('--ar="$TOOLCHAIN_BIN/llvm-ar"', build)
        self.assertIn('--ranlib="$TOOLCHAIN_BIN/llvm-ranlib"', build)

    def test_ffmpeg_linux_build_allows_isolated_version_probes(self) -> None:
        build = (ROOT / "scripts" / "build-ffmpeg-ios-linux.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn('FFMPEG_VERSION="${VCAM_FFMPEG_VERSION:-7.1.1}"', build)
        self.assertIn(
            'OUTPUT_ROOT="${VCAM_FFMPEG_OUTPUT_ROOT:-$PROJECT_ROOT/vendor/ffmpeg}"',
            build,
        )

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
