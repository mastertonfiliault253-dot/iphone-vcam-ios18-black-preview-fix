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
