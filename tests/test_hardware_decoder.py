import pathlib
import unittest


ROOT = pathlib.Path(__file__).parents[1]


class HardwareDecoderTests(unittest.TestCase):
    def test_rtsp_software_frames_use_the_continuous_mmap_transport(self) -> None:
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
        self.assertNotIn("copyNativePixelBufferForSurface", stream)
        self.assertIn("copyNativePixelBufferForSurface", producer)
        native_transport = producer.split("- (BOOL)usesNativeSurfaceTransport", 1)[1].split(
            "- (uint32_t)nativeSurfaceSlotCount", 1
        )[0]
        self.assertNotIn("VCAMSourceKindRTSP", native_transport)
        native_copy = producer.split("- (CVPixelBufferRef)copyNativePixelBufferForSurface", 1)[1].split(
            "- (NSInteger)preferredFramesPerSecond", 1
        )[0]
        self.assertNotIn("VCAMSourceKindRTSP", native_copy)
        self.assertIn("copyVideoSampleForTemplate:template", producer)
        self.assertIn("BOOL nativeTransport = [VCAMProducer usesNativeSurfaceTransport]", daemon)
        self.assertIn("VCAMSharedFrameWriterPublish(VCAMWriter, pixelBuffer)", daemon)
        self.assertIn("vcamd native IOSurface create failed", daemon)
        self.assertIn("VCAMCopyPixelBufferPlanes", daemon)
        self.assertIn("VCAMSharedSurfaceWriterHasConsumer", daemon)
        self.assertIn("vcamd native IOSurface published", daemon)
        self.assertIn("vcamd native IOSurface consumer accepted", daemon)
        self.assertIn("BGRA fallback active", daemon)
        self.assertIn("kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange", shared)
        self.assertIn("shared IOSurface pixel buffer create failed status=", shared)
        self.assertNotIn("shared BGRA IOSurfaceCreate failed", shared)
        self.assertIn("header->pixelFormat", shared)
        self.assertIn("consumerHeartbeatNanoseconds", shared)
        self.assertIn("kill((pid_t)processID, 0)", shared)
        self.assertIn("VCAMProcessMatches(consumerPID, consumerStartToken)", shared)
        self.assertIn("now - heartbeat <= 2000000000ULL", shared)
        self.assertIn("VCAMSharedSurfaceReaderSetReady(reader, false)", shared)
        self.assertIn("producerPID", shared)
        self.assertIn("VCAMSharedSurfaceWriterIsCurrent", shared)
        self.assertIn("VCAMProcessMatches(activeProducer, activeProducerStartToken)", shared)
        self.assertIn("!VCAMSharedSurfaceWriterIsCurrent(VCAMSurfaceWriter)", daemon)

    def test_software_nv12_intermediate_does_not_require_iosurface(self) -> None:
        converter = (ROOT / "Sources" / "Daemon" / "VCAMPixelConverter.m").read_text(
            encoding="utf-8"
        )
        nv12 = converter.split("CVPixelBufferRef VCAMCopyNV12FromAVFrame", 1)[1].split(
            "CVPixelBufferRef VCAMCopyBGRAFromAVFrame", 1
        )[0]

        # This is a short-lived software-decode intermediate. RTSP intentionally
        # renders it into the fixed BGRA mmap transport; requiring IOSurface
        # backing here fails in the root daemon context and is not part of the
        # formal RTSP path.
        self.assertNotIn("kCVPixelBufferIOSurfacePropertiesKey", nv12)
        self.assertNotIn("kCVPixelBufferMetalCompatibilityKey", nv12)
        self.assertIn("pixelFormat, NULL, &pixelBuffer", nv12)
        self.assertIn("NV12 intermediate create failed status=", nv12)

    def test_rtsp_receiver_matches_the_mediamtx_tcp_client_contract(self) -> None:
        stream = (ROOT / "Sources" / "Sources" / "VCAMRTSPStreamSource.m").read_text(
            encoding="utf-8"
        )
        options = stream.split("- (void)configureOpenOptions", 1)[1].split(
            "- (void)stop", 1
        )[0]
        self.assertIn('av_dict_set(options, "rtsp_transport", "tcp", 0)', options)
        self.assertIn('av_dict_set(options, "allowed_media_types", "video", 0)', options)
        self.assertIn('av_dict_set(options, "timeout", "10000000", 0)', options)
        self.assertNotIn('"prefer_tcp"', options)
        self.assertNotIn('"nobuffer"', options)
        self.assertNotIn('"low_delay"', options)

    def test_surface_broker_authorizes_only_expected_publishers_and_consumers(self) -> None:
        broker = (ROOT / "Sources" / "Daemon" / "VCAMSurfaceBrokerServer.m").read_text(
            encoding="utf-8"
        )
        client = (ROOT / "Sources" / "Shared" / "VCAMSurfaceBroker.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("VCAMSurfaceBrokerIdentityForPeer", broker)
        self.assertIn("proc_pidpath(pid, pathBuffer", broker)
        self.assertIn("xpc_connection_get_name", broker)
        self.assertIn("VCAMXPCNameIsCameraCaptured", broker)
        camera_name_gate = broker.split(
            "static BOOL VCAMXPCNameIsCameraCaptured", 1
        )[1].split("typedef NS_ENUM", 1)[0]
        for camera_peer_name in (
            '"cameracaptured"',
            '"/usr/libexec/cameracaptured"',
            '"com.apple.cameracaptured"',
        ):
            self.assertIn(f"strcmp(name, {camera_peer_name})", camera_name_gate)
        # csops is not part of the auth decision under a jailbreak; the exact
        # path/name/bundle allow-list is the boundary.
        self.assertIn("VCAMPeerIsPlatformBinary", broker)
        self.assertIn("intentionally permissive", broker)
        self.assertIn("bundle.executablePath isEqualToString:path", broker)
        self.assertIn("VCAMRootOwnedDaemonPathIsSafe", broker)
        # KERN_PROC_PID (startToken) is also unreliable under a jailbreak and
        # must not gate identity; config-auth issues 10s tokens to any loopback
        # peer so Camera/Safari can reach the SpringBoard broker (0.8.80 parity).
        self.assertNotIn("VCAMProcessStartToken", broker)
        self.assertIn('@"/usr/libexec/cameracaptured"', broker)
        self.assertIn('@"/usr/libexec/vcamd"', broker)
        self.assertIn('@"/System/Library/CoreServices/SpringBoard.app/SpringBoard"', broker)
        self.assertIn("Signing-identity gates (csops) are intentionally not used", broker)
        self.assertIn("VCAMSurfaceBrokerPeerCanSubscribe", broker)
        subscriber = broker.split("static bool VCAMSurfaceBrokerPeerCanSubscribe", 1)[1].split(
            "static xpc_object_t VCAMBrokerRegistry", 1
        )[0]
        for bundle_identifier in (
            "com.apple.camera",
            "com.apple.mobilesafari",
            "com.google.chrome.ios",
            "com.microsoft.msedge",
            "org.mozilla.ios.Firefox",
        ):
            self.assertIn(f'@"{bundle_identifier}"', broker)
        for team_id in ("EQHXZ8M8AV", "UBF8T346G9", "43AQ936H96"):
            self.assertIn(f'@"{team_id}"', broker)
        self.assertIn('xpc_dictionary_set_uint64(message, "slotCount", count)', client)
        self.assertIn('xpc_dictionary_get_uint64(reply, "slotCount")', client)
        self.assertNotIn("SlotCountIsValid((uint32_t)slotCount)", broker)
        self.assertNotIn("SlotCountIsValid((uint32_t)slotCount)", client)
        self.assertIn("VCAMSurfaceBrokerSubscriberStatus", client)
        self.assertIn("surface-import-failed", client)
        self.assertIn("IOSurface registry request pid=", broker)

    def test_cameracaptured_uses_brokered_shared_file_descriptors(self) -> None:
        server = (ROOT / "Sources" / "Daemon" / "VCAMSurfaceBrokerServer.m").read_text(
            encoding="utf-8"
        )
        client = (ROOT / "Sources" / "Shared" / "VCAMSurfaceBroker.m").read_text(
            encoding="utf-8"
        )
        header = (ROOT / "Sources" / "Shared" / "VCAMSurfaceBroker.h").read_text(
            encoding="utf-8"
        )
        shared = (ROOT / "Sources" / "Shared" / "VCAMSharedFrame.m").read_text(
            encoding="utf-8"
        )

        # cameracaptured can connect to the authenticated Mach service but its
        # sandbox rejects path-based reads of /var/tmp. Pass already-open FDs
        # only to the exact MediaServer identity; keep UI subscribers on the
        # existing IOSurface-only registry response.
        self.assertIn("xpc_dictionary_set_fd(reply, key, descriptor)", server)
        self.assertIn(
            'reply, "frameFD", VCAMSharedFrameFileSystemPath(), O_RDONLY', server
        )
        self.assertIn(
            'reply, "surfaceFD", VCAMSharedSurfaceFileSystemPath(), O_RDWR', server
        )
        self.assertIn(
            "peerIdentity == VCAMSurfaceBrokerPeerIdentityMediaServer", server
        )
        self.assertIn('xpc_dictionary_dup_fd(reply, "frameFD")', client)
        self.assertIn('xpc_dictionary_dup_fd(reply, "surfaceFD")', client)
        self.assertIn("VCAMSurfaceBrokerCopySharedFrameFileDescriptor", header)
        self.assertIn("VCAMSurfaceBrokerCopySharedSurfaceFileDescriptor", header)
        self.assertIn("VCAMSurfaceBrokerCopySharedFrameFileDescriptor()", shared)
        self.assertIn("VCAMSurfaceBrokerCopySharedSurfaceFileDescriptor()", shared)
        self.assertNotIn("fchmod(writer->descriptor, 0666)", shared)

    def test_hd_yuv_fallback_uses_bt709_instead_of_bt601(self) -> None:
        converter = (ROOT / "Sources" / "Daemon" / "VCAMPixelConverter.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("VCAMITU709Matrix", converter)
        self.assertIn("VCAMYpCbCrMatrix", converter)
        self.assertIn("MAX(width, height) >= 1280", converter)
        self.assertIn("VCAMITU2020Matrix", converter)
        self.assertIn("frame->colorspace", converter)
        self.assertIn("p010 ? 8 : 0", converter)
        self.assertIn("VCAMDownsample10BitTo8Bit", converter)
        self.assertIn("width, height, p010 ? 8 : 2", converter)
        self.assertIn("width, uvHeight, 8", converter)
        self.assertIn("AVCOL_SPC_BT2020_CL) return NULL", converter)
        matrix_selector = converter.split("static const vImage_YpCbCrToARGBMatrix", 1)[1].split(
            "static void VCAMSetAVFrameColorAttachments", 1
        )[0]
        self.assertNotIn("AVCOL_SPC_BT2020_CL", matrix_selector)
        rtsp = (ROOT / "Sources" / "Sources" / "VCAMRTSPStreamSource.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("BT.2020 constant-luminance frame rejected", rtsp)
    def test_vcamd_has_hardware_decoder_entitlement(self) -> None:
        entitlements = (ROOT / "vcamd.entitlements").read_text(encoding="utf-8")
        self.assertIn("com.apple.videotoolbox.hardwarevideodecoder", entitlements)

    def test_rtsp_color_metadata_tracks_the_decoded_avframe(self) -> None:
        converter = (ROOT / "Sources" / "Daemon" / "VCAMPixelConverter.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("VCAMSetAVFrameColorAttachments", converter)
        self.assertIn("AVCOL_PRI_BT2020", converter)
        self.assertIn("AVCOL_TRC_SMPTE2084", converter)
        self.assertIn("AVCOL_TRC_ARIB_STD_B67", converter)
        self.assertIn("AVCOL_SPC_BT470BG", converter)
        self.assertIn("kCVImageBufferYCbCrMatrix_ITU_R_601_4", converter)

    def test_avcc_record_description_is_preferred_over_parameter_sets_api(self) -> None:
        decoder = (ROOT / "Sources" / "Daemon" / "VCAMHardwareVideoDecoder.m").read_text(
            encoding="utf-8"
        )
        # 0.8.28 contract: canonical parameter-sets construction first, the
        # avcC/hvcC record route remains as fallback.
        desc = decoder.split("static OSStatus VCAMCreateVideoFormatDescription", 1)[1].split(
            "static BOOL VCAMCollectH264AnnexBParameterSets", 1
        )[0]
        self.assertLess(
            desc.index("CMVideoFormatDescriptionCreateFromH264ParameterSets"),
            desc.index("VCAMBuildAVCCRecord"),
        )
        self.assertIn("VCAMDecoderSpecificationCreate", desc)
        self.assertIn("VCAMHardwareOnlyDecoderSpecificationCreate", desc)

    def test_video_toolbox_session_uses_ios_default_decoder(self) -> None:
        decoder = (ROOT / "Sources" / "Daemon" / "VCAMHardwareVideoDecoder.m").read_text(
            encoding="utf-8"
        )
        # The 0.8.10/0.8.28 destination contract that produced frames on the
        # iOS 16.5 device: explicit dimensions, Metal compatibility and an
        # IOSurface backing for the 420v output. Decoder selection is left
        # to VideoToolbox (no Require/EnableHardware keys) and RealTime is
        # not set.
        create = decoder.split("VTDecompressionSessionCreate(", 1)[1].split(
            "&_session);", 1
        )[0]
        self.assertIn("NULL,", create)
        self.assertNotIn("_decoderSpecification", create)
        self.assertIn("destinationAttributes", create)
        self.assertIn("kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder", decoder)
        self.assertIn("kCVPixelBufferIOSurfacePropertiesKey", decoder)
        self.assertIn("kCVPixelBufferMetalCompatibilityKey", decoder)
        self.assertIn("kCVPixelBufferWidthKey", decoder)
        self.assertIn("kCVPixelBufferHeightKey", decoder)
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
        self.assertIn("VCAMConvertAnnexBToLengthPrefixed", decoder)
        self.assertIn("VCAMIsAnnexBStartCode", decoder)
        self.assertIn("annexB conversion failed", decoder)
        # 0.8.28 contract: strip only parameter sets, keep SEI.
        self.assertIn("VCAMIsOmittableNAL", decoder)
        self.assertIn("return type == 7 || type == 8;", decoder)
        self.assertNotIn("type == 6 || type == 7 || type == 8", decoder)

    def test_length_prefixed_slice_without_parameter_sets_keeps_original_length(self) -> None:
        decoder = (ROOT / "Sources" / "Daemon" / "VCAMHardwareVideoDecoder.m").read_text(
            encoding="utf-8"
        )

        passthrough = decoder.split("if (!sawOmittable && !annexB)", 1)[1].split(
            "if (nalCount == 0", 1
        )[0]
        self.assertIn("*outLength = length;", passthrough)
        self.assertIn("return NULL;", passthrough)
        self.assertIn("keep original bytes", passthrough)

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

    def test_hvcc_fallback_allocates_every_array_header_and_rejects_oversize_nals(self) -> None:
        decoder = (ROOT / "Sources" / "Daemon" / "VCAMHardwareVideoDecoder.m").read_text(
            encoding="utf-8"
        )
        hvcc = decoder.split("static CFDataRef VCAMBuildHVCCRecord", 1)[1].split(
            "static CFDictionaryRef VCAMDecoderSpecificationCreate", 1
        )[0]
        self.assertIn("total += 5 + setSizes[arrayIndex];", hvcc)
        self.assertIn("setSizes[arrayIndex] > UINT16_MAX", hvcc)
        self.assertIn("total > SIZE_MAX - 5 - setSizes[arrayIndex]", hvcc)
        self.assertNotIn("size_t total = 22 + 3;", hvcc)

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

    def test_rtsp_prefers_direct_vt_with_software_fallback(self) -> None:
        rtsp = (ROOT / "Sources" / "Sources" / "VCAMRTSPStreamSource.m").read_text(
            encoding="utf-8"
        )
        # Direct-VT is the preferred decode path (same proven decoder class as
        # local media playback) with a zero-frame self-healing fallback to the
        # FFmpeg software decoder. The FFmpeg VideoToolbox hwaccel wrapper
        # remains banned: it historically produced zero frames on RTSP.
        self.assertIn("VCAMHardwareVideoDecoder", rtsp)
        self.assertIn("[[VCAMHardwareVideoDecoder alloc] initWithCodecParameters:stream->codecpar]", rtsp)
        self.assertIn("decodePacketsWithHardwareSession", rtsp)
        self.assertIn("hardware decode disabled; using FFmpeg software decoder", rtsp)
        self.assertIn("gVCAMRTSPHardwareSessionsDisabled", rtsp)
        self.assertIn("acceptDecodedPixelBuffer:output hardware:YES", rtsp)
        self.assertIn("avcodec_find_decoder", rtsp)
        self.assertIn("avcodec_send_packet(codecContext, packet)", rtsp)
        self.assertIn("avcodec_receive_frame(codecContext, frame)", rtsp)
        self.assertIn("codecContext->thread_count = 0", rtsp)
        self.assertIn("enqueueLatestSoftwareFrame", rtsp)
        self.assertIn("acceptDecodedPixelBuffer:pixelBuffer hardware:NO", rtsp)
        self.assertNotIn("VCAMRequestVideoToolboxFormat", rtsp)
        self.assertNotIn("AV_PIX_FMT_VIDEOTOOLBOX", rtsp)
        self.assertNotIn("AV_HWDEVICE_TYPE_VIDEOTOOLBOX", rtsp)
        self.assertNotIn("hw_device_ctx", rtsp)
        self.assertNotIn("hwaccel_flags", rtsp)
        self.assertNotIn("gVideoToolboxDisabled", rtsp)
        self.assertNotIn("gFramelessSessionCount", rtsp)
        self.assertNotIn("avcodec_get_hw_config", rtsp)
        self.assertNotIn("AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX", rtsp)

        workflow = (ROOT / ".github" / "workflows" / "build.yml").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("Verify captured RTSP stream decodes with macOS VideoToolbox", workflow)
        self.assertNotIn("vt-test.swift", workflow)

    def test_ffmpeg_upstream_path_passes_demuxed_packets_without_manual_au_filtering(self) -> None:
        stream = (ROOT / "Sources" / "Sources" / "VCAMRTSPStreamSource.m").read_text(
            encoding="utf-8"
        )
        loop = stream.rsplit("- (BOOL)decodeOneFFmpegSession", 1)[1].split(
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
        session = stream.rsplit("- (BOOL)decodeOneFFmpegSession", 1)[1].split(
            "cleanup:", 1
        )[0]
        self.assertIn("if (videoPacketsWithoutFrame >= 300)", session)
        self.assertIn("decoder stalled packets=300; reconnecting", session)
        self.assertNotIn("stalledOut", session)
        self.assertNotIn("useHardware", session)

    def test_rtsp_reconnect_loop_stays_decoder_agnostic(self) -> None:
        stream = (ROOT / "Sources" / "Sources" / "VCAMRTSPStreamSource.m").read_text(
            encoding="utf-8"
        )
        reconnect = stream.split("- (void)decodeReconnectLoop", 1)[1].split(
            "- (void)acceptDecodedPixelBuffer", 1
        )[0]
        # The reconnect loop only drives sessions; decode-path selection lives
        # inside decodeOneFFmpegSession. The earlier per-session hardware
        # retry state machines must not come back.
        self.assertIn("decodeOneFFmpegSession", reconnect)
        self.assertNotIn("decodeOneSession", reconnect)
        self.assertNotIn("hardwareRejected", stream)
        self.assertNotIn("softwareFallbackActive", stream)
        self.assertNotIn("decodeOneFFmpegSessionUsingHardware", stream)

    def test_legacy_hls_rollback_reuses_the_software_ffmpeg_stream_source(self) -> None:
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
        self.assertNotIn('@"%@ hardware first-frame size=', stream)
        self.assertNotIn('@"rtsp ', stream)
        self.assertNotIn("self.softwareFallbackActive", stream)
        self.assertNotIn("hardwareRetryDeadline", stream)
        self.assertNotIn("decodeOneFFmpegSessionUsingHardware", stream)
        self.assertNotIn("static volatile int consecutiveSendFailures", stream)
        self.assertEqual(producer.count("[[VCAMRTSPStreamSource alloc]"), 2)
        self.assertEqual(pipeline.count("[[VCAMRTSPStreamSource alloc]"), 2)
        self.assertNotIn("VCAMHLSStreamSource", producer)
        self.assertNotIn("VCAMHLSStreamSource", pipeline)
        self.assertNotIn("VCAMHLSStreamSource.m", makefile)
        self.assertFalse((ROOT / "Sources" / "Sources" / "VCAMHLSStreamSource.h").exists())
        self.assertFalse((ROOT / "Sources" / "Sources" / "VCAMHLSStreamSource.m").exists())


    def test_daemon_is_the_only_rtsp_host(self) -> None:
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        bridge = (ROOT / "Sources" / "SpringBoard" / "VCAMSpringBoardMediaBridge.m").read_text(
            encoding="utf-8"
        )
        producer = (ROOT / "Sources" / "Daemon" / "VCAMFrameProducer.m").read_text(
            encoding="utf-8"
        )
        pipeline = (ROOT / "Sources" / "Core" / "VCAMFramePipeline.m").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("Sources/SpringBoard/VCAMSpringBoardRTSPSource.m", makefile)
        springboard_files = makefile.split("VCAMSpringBoardClient_FILES =", 1)[1].split(
            "VCAMSpringBoardClient_CFLAGS", 1
        )[0]
        self.assertNotIn("VCAMHardwareVideoDecoder.m", springboard_files)
        self.assertNotIn("VCAMSpringBoardRTSP", bridge)
        self.assertNotIn("VCAMSpringBoardRTSPMarker", producer)
        self.assertNotIn("VCAMSpringBoardRTSPMarker", pipeline)
        self.assertIn("case VCAMSourceKindRTSP:", producer)
        self.assertIn("[[VCAMRTSPStreamSource alloc]", producer)
        self.assertFalse((ROOT / "Sources" / "SpringBoard" / "VCAMSpringBoardRTSPSource.h").exists())
        self.assertFalse((ROOT / "Sources" / "SpringBoard" / "VCAMSpringBoardRTSPSource.m").exists())

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

    def test_decoder_diagnostics_are_bounded_and_device_visible(self) -> None:
        decoder = (ROOT / "Sources" / "Daemon" / "VCAMHardwareVideoDecoder.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("[DEBUG-vtpack]", decoder)
        self.assertIn("packetDiagnostic <= 4", decoder)
        self.assertIn("VCAMConfiguration appendProcessLog", decoder)

        stream = (ROOT / "Sources" / "Sources" / "VCAMRTSPStreamSource.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("[ffmpeg]", stream)
        self.assertIn("count <= 3000", stream)
        self.assertIn("level > AV_LOG_VERBOSE", stream)
        self.assertNotIn("VCAMCaptureFFmpegHardwareLogs", stream)  # diagnostics always on


    def test_mmap_compatibility_path_propagates_decode_hardware(self) -> None:
        shared = (ROOT / "Sources" / "Shared" / "VCAMSharedFrame.m").read_text(
            encoding="utf-8"
        )
        # The mmap header mirrors the surface header's color slots so the
        # compatibility path reports the same decode class.
        self.assertIn("VCAMSharedFrameWriteSlotMetadata", shared)
        frame_header = shared.split("} VCAMSharedFrameHeader;", 1)[0]
        self.assertIn("slotColorPrimaries", frame_header)
        self.assertIn("slotTransferFunction", frame_header)
        self.assertIn("slotYCbCrMatrix", frame_header)
        # Both transports write through the shared metadata writer.
        self.assertEqual(
            shared.count(
                "VCAMSharedFrameWriteSlotMetadata(\n"
                "        writer->header->slotColorPrimaries,"
            ),
            2,
        )
        # The mmap reader fills the same fields as the surface reader.
        mmap_read = shared.split(
            "static bool VCAMSharedFrameReaderGetSnapshot", 1
        )[1].split("bool VCAMSharedFrameReaderGetLatestMetadata", 1)[0]
        self.assertIn("metadata->colorPrimaries", mmap_read)
        self.assertIn("metadata->transferFunction", mmap_read)
        self.assertIn("metadata->yCbCrMatrix", mmap_read)

    def test_vcamd_native_transport_propagates_decode_hardware_attachments(self) -> None:
        daemon = (ROOT / "Sources" / "Daemon" / "main.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("CVBufferPropagateAttachments(source, destination)", daemon)
        self.assertIn("nativeHardwareDecode", daemon)
        fallback = daemon.split("nativeHardwareDecode = NO;", 1)[1].split(
            "VCAMSharedFrameWriterPublishForSurfaceGeneration(", 1
        )[0]
        self.assertIn("com.codex.vcam.decodeHardware", fallback)
        self.assertIn("nativeHardwareDecode", fallback)

    def test_renderer_preserves_decode_hardware_tag_across_bgra_conversion(self) -> None:
        renderer = (ROOT / "Sources" / "Core" / "VCAMFrameRenderer.m").read_text(
            encoding="utf-8"
        )
        converted = renderer.split("if (converted) {", 1)[1].split(
            "copySampleWrappingPixelBuffer:output", 1
        )[0]
        self.assertIn("com.codex.vcam.decodeHardware", converted)
        self.assertIn("CVBufferCopyAttachment", converted)
        self.assertIn("CVBufferSetAttachment", converted)

    def test_broker_preview_snapshot_carries_decode_hardware(self) -> None:
        config = (ROOT / "Sources" / "Core" / "VCAMConfiguration.m").read_text(
            encoding="utf-8"
        )
        preview = (ROOT / "Sources" / "UI" / "VCAMSharedFramePreviewView.m").read_text(
            encoding="utf-8"
        )
        self.assertIn('@"decodeHardware": @(', config)
        self.assertIn("VCAMSharedFrameDecodeHardwareMask", config)
        broker_read = preview.split("VCAMPreviewGetBrokerMetadata", 1)[1].split(
            "@implementation", 1
        )[0]
        self.assertIn("decodeHardware", broker_read)
        self.assertIn("VCAMSharedFrameDecodeHardwareShift", broker_read)

if __name__ == "__main__":
    unittest.main()
