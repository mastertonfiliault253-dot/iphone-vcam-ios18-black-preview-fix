import pathlib
import unittest


ROOT = pathlib.Path(__file__).parents[1]


class InjectionSafetyTests(unittest.TestCase):
    def test_only_mediaserverd_and_springboard_filters_exist(self) -> None:
        filters = {path.name for path in ROOT.glob("VCAM*.plist")}
        self.assertEqual(
            filters,
            {"VCAMMediaServerClient.plist", "VCAMSpringBoardClient.plist"},
        )

        media = (ROOT / "VCAMMediaServerClient.plist").read_text(encoding="utf-8")
        springboard = (ROOT / "VCAMSpringBoardClient.plist").read_text(encoding="utf-8")
        self.assertIn("cameracaptured", media)
        self.assertNotIn("Bundles", media)
        self.assertIn("com.apple.springboard", springboard)
        self.assertIn("SpringBoard", springboard)

    def test_makefile_builds_exactly_two_injected_targets(self) -> None:
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        target_line = next(
            line for line in makefile.splitlines() if line.startswith("TWEAK_NAME =")
        )
        self.assertEqual(
            target_line,
            "TWEAK_NAME = VCAMMediaServerClient VCAMSpringBoardClient",
        )
        self.assertIn("TOOL_NAME = vcamd vcaminjectd", makefile)
        for removed in ("VCAMAppClient", "VCAMWebKitClient", "VCAMDaemonProbe"):
            self.assertNotIn(removed, target_line)

    def test_mediaserver_consumer_has_no_decoder_or_network_code(self) -> None:
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        implementation = (
            ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefImageUtils.m"
        ).read_text(encoding="utf-8")
        self.assertIn("VCAMSharedFrameReaderCopyLatest", implementation)
        self.assertNotIn("libav", implementation)
        self.assertNotIn("AVAssetReader", implementation)
        self.assertNotIn("NSURLSession", implementation)

        frameworks_line = next(
            line
            for line in makefile.splitlines()
            if line.startswith("VCAMMediaServerClient_FRAMEWORKS")
        )
        self.assertNotIn("UIKit", frameworks_line)
        self.assertNotIn("AVFoundation", frameworks_line)
        self.assertIn("VideoToolbox", frameworks_line)
        self.assertNotIn("VTDecompressionSession", implementation)
        self.assertNotIn("VTCompressionSession", implementation)
        self.assertIn("if (@available(iOS 16.0, *))", implementation)
        self.assertIn("static CFTypeRef VCAMPixelTransferSession", implementation)
        self.assertNotIn(
            "static VTPixelTransferSessionRef VCAMPixelTransferSession",
            implementation,
        )

    def test_mediaserver_replaces_only_validated_consumer_outputs(self) -> None:
        implementation = (
            ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefImageUtils.m"
        ).read_text(encoding="utf-8")
        entry = (
            ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefEntry.xm"
        ).read_text(encoding="utf-8")
        for pixel_format in (
            "kCVPixelFormatType_32BGRA",
            "kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange",
            "kCVPixelFormatType_420YpCbCr8BiPlanarFullRange",
        ):
            self.assertIn(pixel_format, implementation)
        self.assertIn("longEdge > 4608", implementation)
        self.assertIn("width * height > (size_t)4608 * 3456", implementation)
        self.assertIn("CVPixelBufferGetIOSurface", implementation)
        self.assertIn("CVPixelBufferGetPlaneCount(targetBuffer) != 2", implementation)
        self.assertIn("CVPixelBufferGetBytesPerRowOfPlane", implementation)
        self.assertIn("CVIsCompressedPixelFormatAvailable", implementation)
        self.assertIn("0x5b387630", implementation)
        self.assertIn("0x7d387630", implementation)
        self.assertIn("VTPixelTransferSessionTransferImage", implementation)
        self.assertIn("kVTScalingMode_Normal", implementation)
        self.assertIn("kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange", implementation)
        self.assertIn("VCAMCreateCompressedStagingBuffer", implementation)
        self.assertIn("CVPixelBufferCopyCreationAttributes", implementation)
        self.assertIn("VCAMCreateCompressedTargetBuffer", implementation)
        # iOS 18 cameracaptured rejects a VCAM-created CMSampleBuffer. The
        # hook preserves the graph-owned sample and only replaces its pixels.
        self.assertNotIn("CMSampleBufferCreateReadyWithImageBuffer", entry)
        self.assertNotIn("VCAMCreateSampleBufferWithReplacementImage", entry)
        self.assertIn("VCAMCopyReplacementBufferIntoTarget", entry)
        self.assertIn("VCAMCopyReplacementBufferIntoTarget", implementation)
        self.assertIn("CMCopyDictionaryOfAttachments", entry)
        self.assertIn("CVBufferRemoveAllAttachments", implementation)
        self.assertIn("VCAMMergeGraphAttachments", implementation)
        self.assertNotIn(
            "CVBufferRemoveAllAttachments(replacementTargetBuffer)",
            implementation,
        )
        self.assertIn(
            "CFEqual(VCAMCompressedTargetCreationAttributes, creationAttributes)",
            implementation,
        )
        self.assertIn("VCAMCopyLastCompressedVirtualFrame", implementation)
        self.assertIn(
            "VCAMLastCompressedVirtualFrameCreationAttributes",
            implementation,
        )
        self.assertIn(
            "CFEqual(VCAMLastCompressedVirtualFrameCreationAttributes,",
            implementation,
        )
        self.assertIn("using last virtual compressed frame", implementation)
        self.assertIn("compressed pixel transfer failed", implementation)
        self.assertIn("CIRenderDestination", implementation)
        self.assertIn("waitUntilCompletedAndReturnError", implementation)
        self.assertIn("@finally", implementation)
        self.assertIn("kCVPixelBufferMetalCompatibilityKey", implementation)
        self.assertNotIn("VCAMRenderingDisabled", implementation)
        self.assertNotIn("VCAMDisableRendering", implementation)
        self.assertIn("replacement render slow count", implementation)
        self.assertNotIn("three-consecutive-renders-over-50ms", implementation)
        self.assertIn("high-resolution replacement render", implementation)
        self.assertIn("VCAMLastVirtualFrame", implementation)
        self.assertIn("virtual frame stale; rendering black instead of frozen frame", implementation)
        self.assertIn("VCAMVirtualModeIsEnabled", implementation)
        self.assertIn("VCAMConfiguredMode = 0", implementation)
        # mediaserverd must not ask Foundation to parse the plist. Its iOS 18
        # hook runs in a fragile camera daemon; read only the bounded enabled
        # XML scalar and retain the last valid mode on any read/parse failure.
        self.assertIn("VCAMReadConfiguredModeFromFile", implementation)
        self.assertIn('open("/var/mobile/Media/VCAM/com.codex.vcam.plist", O_RDONLY)', implementation)
        self.assertIn("metadata.st_size > 1024 * 1024", implementation)
        self.assertIn("errno == EINTR", implementation)
        self.assertIn("<key>enabled</key>", implementation)
        self.assertIn("<true/>", implementation)
        self.assertIn("<false/>", implementation)
        self.assertNotIn("dictionaryWithContentsOfFile", implementation)
        self.assertIn("VCAMConfiguredMode != 0", implementation)
        self.assertIn("VCAMSharedFrameReaderGetActiveState", implementation)
        self.assertNotIn("VCAMRequestedModeOverride", implementation)
        self.assertNotIn("[values[@\"enabled\"] boolValue]", implementation)
        self.assertIn("/var/mobile/Media/VCAM/com.codex.vcam.plist", implementation)
        self.assertIn("com.codex.vcam/preferences.changed", implementation)
        self.assertIn("replacement render window count=120", implementation)
        self.assertIn("1000000000ULL", implementation)
        self.assertNotIn("VCAMReader, scratch, 0, &metadata", implementation)
        self.assertIn("allowMmapBootstrap", implementation)
        self.assertIn("VCAMAdoptedSurfaceGeneration", implementation)
        self.assertIn("BWNodeOutput", entry)
        self.assertIn("%orig(sampleBuffer)", entry)
        self.assertNotIn("%orig(replacementSampleBuffer)", entry)
        self.assertIn("output signature", entry)
        self.assertIn("VCAMReplacementRouteForOutput", entry)
        self.assertIn("[value isKindOfClass:NSString.class]", entry)
        self.assertIn('VCAMStringMatches(nodeClass, @"BWPixelTransferNode")', entry)
        self.assertIn('@"Video Data Converter/Scaler/Zoomer"', entry)
        self.assertIn('@"Preview Scaler"', entry)
        self.assertIn('@"Movie File Zoomer"', entry)
        self.assertIn("VCAMReplacementRouteVideoRecording", entry)
        self.assertNotIn('VCAMStringMatches(nodeClass, @"BWVideoCompressorNode")', entry)
        self.assertNotIn("VCAMRecordRecordingFrameOutcome", entry)
        self.assertNotIn("VCAMEncodedRecordingSampleCanPass", entry)
        self.assertNotIn("VCAMRecordingFrameOutcomeCapacity", entry)
        self.assertNotIn("guarding encoded recording sample", entry)
        self.assertIn("no-safe-compressed-virtual-fallback", entry)
        self.assertIn("CMTIME_IS_NUMERIC", entry)
        self.assertIn('VCAMSafeObjectResult(output, sel_registerName("node"))', entry)
        self.assertNotIn("VCAMResetRecordingFrameOutcomes", entry)
        self.assertIn("VCAMReplacementRouteCameraSourceVideo", entry)
        self.assertIn('@"BWMultiStreamCameraSourceNode"', entry)
        route_function = entry.split(
            "static VCAMReplacementRoute VCAMReplacementRouteForOutput", 1
        )[1].split("static void VCAMLogOutputSignature", 1)[0]
        self.assertNotIn('@"VideoCapture"', route_function)
        self.assertIn(
            "return VCAMReplacementRouteCameraSourceVideo;", route_function
        )
        self.assertNotIn("VCAMReplacementRouteGenericPixelTransfer", entry)
        self.assertNotIn("VCAMReplacementRouteLegacyPreview", entry)
        self.assertNotIn("width == 750 && height == 1334", entry)
        self.assertIn('VCAMStringMatches(nodeClass, @"BWMeteorHeadroomNode")', entry)
        self.assertIn('VCAMStringMatches(nodeName, @"Meteor Headroom")', entry)
        self.assertIn("VCAMReplacementRouteStillPhoto", entry)
        self.assertIn("suppressing real sample after replacement failure", entry)
        self.assertIn(
            "kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange",
            implementation,
        )
        self.assertIn(
            "kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarVideoRange",
            implementation,
        )
        self.assertIn('@"BWFanOutNode"', route_function)
        self.assertIn('@"Preview Splitter"', route_function)
        self.assertIn('@"MetadataObject"', route_function)
        self.assertNotIn("VCAMReplacementRouteQRAnalysis", route_function)
        self.assertNotIn('@"BWInferenceNode"', route_function)
        self.assertIn('@"BWPhotoEncoderNode"', entry)
        self.assertIn('@"Encoder"', entry)
        self.assertIn("VCAMReplacementRoutePhotoEncoder", entry)
        self.assertIn("%hook BWPhotoEncoderNode", entry)
        self.assertIn("%hook BWRemoteQueueSinkNode", entry)
        # Lens position is observed only at the physical source boundary. It
        # may select WebKit presentation compensation, but must never select a
        # replacement route or alter Camera/photo/recording consumers.
        self.assertIn('@"Front Camera"', entry)
        self.assertIn('@"Back Camera"', entry)
        self.assertIn("VCAMSetLastCameraIsFront", entry)
        self.assertIn("NSPointerFunctionsObjectPointerPersonality", entry)
        self.assertIn("method_getReturnType", entry)
        self.assertNotIn("[node description]", entry)
        self.assertNotIn("VCAMOutputLooksAuxiliary", entry)

    def test_real_microphone_is_forced(self) -> None:
        configuration = (
            ROOT / "Sources" / "Core" / "VCAMConfiguration.m"
        ).read_text(encoding="utf-8")
        panel = (
            ROOT / "Sources" / "UI" / "VCAMControlPanelViewController.m"
        ).read_text(encoding="utf-8")
        self.assertIn("configuration.replaceAudio = NO", configuration)
        self.assertNotIn("audioTapped", panel)
        self.assertNotIn("替换声音", panel)

    def test_consumer_orientation_preserves_system_still_metadata(self) -> None:
        # The system still-photo basis is landscape (4224x3024 on the test
        # device) and Photos shows portrait via the Orientation attachment.
        # VCAM must render canonical portrait pixels into that landscape basis
        # and mark the final sample Orientation=Right (0.8.80 behavior); the
        # 0.8.81 audit removed the mark and saved photos came out landscape.
        # Camera preview (aspectFit) and browsers are never rotated here.
        implementation = (
            ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefImageUtils.m"
        ).read_text(encoding="utf-8")
        entry = (
            ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefEntry.xm"
        ).read_text(encoding="utf-8")
        render = implementation.split("CIImage *image =", 1)[1].split(
            "CIRenderDestination *destination", 1
        )[0]

        self.assertIn("!realtimeCompensation && /* sourceIsPortrait always YES */ YES", render)
        self.assertIn("stillPhotoRequiresRightOrientationOut", implementation)
        self.assertIn("VCAMSetStillPhotoDisplayOrientation", entry)
        self.assertIn("kCGImagePropertyOrientationRight", entry)
        # preview path is never rotated; only still-photo fill triggers it
        self.assertIn("BOOL webKitRotatedForStorage = webKitLandscapeStorage &&", render)
        self.assertNotIn("aspectFit && sourceIsPortrait", render)
        self.assertIn("VCAMSetStandardColorAttachments", implementation)


if __name__ == "__main__":
    unittest.main()
