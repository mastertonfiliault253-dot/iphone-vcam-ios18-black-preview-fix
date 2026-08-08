import pathlib
import unittest


ROOT = pathlib.Path(__file__).parents[1]


class HardwareDecoderTests(unittest.TestCase):
    def test_video_toolbox_session_uses_hardware_decoder_specification(self) -> None:
        decoder = (ROOT / "Sources" / "Daemon" / "VCAMHardwareVideoDecoder.m").read_text(
            encoding="utf-8"
        )
        # The direct VideoToolbox session explicitly requests the hardware
        # decoder (Require for H.264, Enable for HEVC). The realtime property
        # is deliberately not forced because it regressed decode on device.
        create = decoder.split("VTDecompressionSessionCreate(", 1)[1].split(
            "&_session);", 1
        )[0]
        self.assertIn("_decoderSpecification", create)
        self.assertIn("RequireHardwareAcceleratedVideoDecoder", decoder)
        self.assertIn("EnableHardwareAcceleratedVideoDecoder", decoder)
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
            rtsp.index("rtsp hardware session codec="),
            rtsp.index("sessionStart = CFAbsoluteTimeGetCurrent();", rtsp.index("rtsp hardware session codec=")),
        )
        self.assertIn("receivedKeyPacket &&", loop)
        self.assertLess(
            loop.index("if (!receivedKeyPacket && !isKeyFrame)"),
            loop.index("[decoder decodePacket:"),
        )

    def test_hls_falls_back_to_player_item_time_for_headless_playback(self) -> None:
        hls = (ROOT / "Sources" / "Sources" / "VCAMHLSStreamSource.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("itemTimeForHostTime:CACurrentMediaTime()", hls)
        self.assertIn("![self.videoOutput hasNewPixelBufferForItemTime:itemTime]", hls)
        self.assertIn("itemTime = self.playerItem.currentTime", hls)
        self.assertIn("automaticallyWaitsToMinimizeStalling = NO", hls)
        self.assertIn("playImmediatelyAtRate:1.0", hls)
        self.assertIn("dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)", hls)
        self.assertIn("dispatch_get_main_queue()", hls)
        self.assertIn("copyLatestPixelBuffer", hls)

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


if __name__ == "__main__":
    unittest.main()
