import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).parents[1]
ENTRY_PATH = ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefEntry.xm"
UTILS_PATH = ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefImageUtils.m"


def _entry_source() -> str:
    return ENTRY_PATH.read_text(encoding="utf-8")


def _between(source: str, start: str, end: str) -> str:
    return source.split(start, 1)[1].split(end, 1)[0]


class MediaServerUpstreamRoutingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.entry = _entry_source()
        self.route_function = _between(
            self.entry,
            "static VCAMReplacementRoute VCAMReplacementRouteForOutput",
            "static void VCAMLogOutputSignature",
        )
        self.hook = _between(self.entry, "%hook BWNodeOutput", "%end")

    def test_unknown_camera_outputs_use_the_common_universal_route(self) -> None:
        # Shared pixels are already in the source's presentation orientation.
        # Known terminals retain their route-specific composition, while an
        # unrecognized video output must still be replaced at BWNodeOutput so
        # a new app cannot silently receive the physical camera.
        self.assertIn(
            "return VCAMReplacementRouteUniversalVideo;", self.route_function
        )
        self.assertNotIn('@"Preview"', self.route_function)
        self.assertRegex(
            self.route_function,
            re.compile(
                r'VCAMStringMatches\(nodeClass,\s*@"BWMultiStreamCameraSourceNode"\)'
                r'\s*&&\s*\(\s*VCAMStringMatches\(outputName,\s*@"StillImage"\)'
                r'.*?pixelFormat\s*==\s*\(OSType\)0x26786630'
                r'.*?return VCAMReplacementRouteStillPhoto;',
                re.DOTALL,
            ),
        )

    def test_private_still_source_reaches_supported_downstream_photo_route(self) -> None:
        self.assertIn(
            'VCAMStringMatches(outputName, @"StillImage")',
            self.route_function,
        )
        self.assertIn("(OSType)0x26786630", self.route_function)
        self.assertIn("return VCAMReplacementRouteStillPhoto;", self.route_function)
        self.assertIn('VCAMStringMatches(nodeClass, @"BWMeteorHeadroomNode")', self.route_function)
        self.assertIn('VCAMStringMatches(nodeName, @"Meteor Headroom")', self.route_function)

    def test_photo_encoder_is_a_narrow_still_photo_route(self) -> None:
        self.assertRegex(
            self.route_function,
            re.compile(
                r'VCAMStringMatches\(nodeClass,\s*@"BWPhotoEncoderNode"\)'
                r'.*?VCAMStringMatches\(nodeName,\s*@"Encoder"\)'
                r'.*?return VCAMReplacementRoutePhotoEncoder;',
                re.DOTALL,
            ),
        )

    def test_photo_encoder_rewrites_supported_encoded_surface_attachment(self) -> None:
        helper = _between(
            self.entry,
            "static BOOL VCAMReplacePhotoEncodedSurface",
            "static const CFStringRef VCAMPropagationMarkerKey",
        )
        self.assertIn('CFSTR("DeferredPhotoProxyEncodedImageSurface")', helper)
        self.assertIn('CFSTR("EncodedImageSurface")', helper)
        self.assertIn("CVPixelBufferCreateWithIOSurface", helper)
        self.assertIn("VCAMReplaceEncodedPhotoBytes", self.entry)
        self.assertIn("DeferredPhotoProxyEncodedImageSurfaceSize", self.entry)
        self.assertIn("photo encoded-bytes replacement", self.entry)
        self.assertIn("VCAMTargetBufferIsSupported", helper)
        self.assertIn("VCAMFramePresentationStillPhotoFill", helper)
        self.assertIn("VCAMSetStillPhotoDisplayOrientationIfMissing", helper)
        self.assertIn("photoEncodedSurfaceReplaced", self.hook)

    def test_terminal_routes_remain_fail_closed_for_missing_buffers(self) -> None:
        null_buffer_path = _between(
            self.hook,
            "if (originalImageBuffer == NULL) {",
            "if (!replacementAllowed) {",
        )
        self.assertRegex(
            null_buffer_path,
            re.compile(
                r'if\s*\(replacementAllowed\s*&&\s*VCAMVirtualModeIsEnabled\(\)'
                r'\s*&&\s*!photoEncodedSurfaceReplaced'
                r'\s*\)\s*\{.*?return;\s*\}.*?%orig\(sampleBuffer\);',
                re.DOTALL,
            ),
        )

    def test_only_device_observed_exact_pixel_transfer_terminals_and_meteor_still_remain(self) -> None:
        for terminal_name, route_name in (
            ("Video Data Converter/Scaler/Zoomer", "VideoConverter"),
            ("Video Data Converter/Rotator/Zoomer", "VideoConverter"),
            ("Video Data Converter/Rotator/Scaler/Zoomer", "VideoConverter"),
            ("Video Data Converter/Zoomer", "StillPhoto"),
            ("Preview Scaler", "CameraPreview"),
            ("Movie File Zoomer", "VideoRecording"),
        ):
            if terminal_name == "Video Data Converter/Zoomer":
                self.assertIn("VCAMReplacementRouteCameraSourceVideo", self.route_function)
            else:
                self.assertRegex(
                    self.route_function,
                    re.compile(
                        rf'VCAMStringMatches\(nodeName,\s*@"{re.escape(terminal_name)}"\)'
                        rf'\s*\)\s*\{{\s*return VCAMReplacementRoute{route_name};',
                        re.DOTALL,
                    ),
                )
        self.assertIn('@"BWMeteorHeadroomNode"', self.route_function)
        self.assertIn('@"Meteor Headroom"', self.route_function)

        self.assertNotIn("VCAMReplacementRouteGenericPixelTransfer", self.entry)
        self.assertNotIn("VCAMReplacementRouteLegacyPreview", self.entry)
        self.assertNotIn("width == 750", self.route_function)
        self.assertNotIn("height == 1334", self.route_function)

    def test_ios18_pf20_still_source_uses_supported_photo_route(self) -> None:
        utils = UTILS_PATH.read_text(encoding="utf-8")
        compressed_formats = _between(
            utils,
            "static BOOL VCAMFormatIsCompressedVideoRange",
            "static CVReturn VCAMCreateStagingPool",
        )
        support = _between(
            utils,
            "BOOL VCAMTargetBufferIsSupported",
            "static BOOL VCAMFillBlackSharedFrame",
        )

        # iOS 18.3.1 on iPhone12,5 exposed stock Camera's full-resolution
        # still as StillImage(StillImage), 4224x3168, private compressed pf20.
        self.assertIn('@"StillImage(StillImage)"', self.route_function)
        self.assertIn("(OSType)0x70663230", self.route_function)
        self.assertIn("(OSType)0x70663230", compressed_formats)
        self.assertIn("(OSType)0x70663230", support)
        self.assertRegex(
            self.route_function,
            re.compile(
                r'pixelFormat\s*==\s*\(OSType\)0x70663230.*?'
                r'return VCAMReplacementRouteStillPhoto;',
                re.DOTALL,
            ),
        )

    def test_movie_file_governor_is_version_scoped_between_prewarm_and_recording(self) -> None:
        version_helper = _between(
            self.entry,
            "static BOOL VCAMOperatingSystemIsAtLeast18",
            "static VCAMReplacementRoute VCAMReplacementRouteForOutput",
        )
        self.assertIn("operatingSystemVersion", version_helper)
        self.assertIn("majorVersion >= 18", version_helper)

        body = _between(
            self.route_function,
            'if (VCAMStringMatches(nodeClass, @"BWFrameRateGovernorNode") &&\n'
            '        VCAMStringMatches(nodeName, @"Movie File Frame Rate Governor")) {',
            "// Stock Camera still capture reaches this last standard 8-bit pixel stage",
        )
        self.assertIn("VCAMOperatingSystemIsAtLeast18()", body)
        self.assertIn("return VCAMReplacementRouteNone;", body)
        self.assertIn("return VCAMReplacementRouteVideoRecording;", body)
        self.assertLess(
            body.index("return VCAMReplacementRouteNone;"),
            body.index("return VCAMReplacementRouteVideoRecording;"),
        )

    def test_only_metadata_input_fanout_is_a_direct_analysis_route(self) -> None:
        # Camera QR recognition consumes Preview Splitter/MetadataObject before
        # Preview Scaler. Keep every other fan-out and inference output on the
        # internal-stage bypass to avoid restoring the old render explosion.
        self.assertIn('@"BWFanOutNode"', self.route_function)
        self.assertIn('@"Preview Splitter"', self.route_function)
        self.assertIn('@"MetadataObject"', self.route_function)
        self.assertIn(
            "return VCAMReplacementRouteQRAnalysis;", self.route_function
        )
        self.assertNotIn('@"BWInferenceNode"', self.route_function)

    def test_qr_analysis_reuses_preview_fit_without_propagation(self) -> None:
        presentation = _between(
            self.entry,
            "static VCAMFramePresentation VCAMPresentationForReplacementRoute",
            "static BOOL VCAMStringMatches",
        )
        marker_routes = _between(
            self.entry,
            "static BOOL VCAMRouteUsesPropagationMarker",
            "static BOOL VCAMWritePropagationMarker",
        )
        self.assertRegex(
            presentation,
            re.compile(
                r"case VCAMReplacementRouteQRAnalysis:\s*"
                r"return VCAMFramePresentationCameraPreviewFit;"
            ),
        )
        self.assertNotIn("VCAMReplacementRouteQRAnalysis", marker_routes)

    def test_ios18_observed_internal_graph_stages_bypass_direct_rendering(self) -> None:
        helper = _between(
            self.entry,
            "static BOOL VCAMOutputIsKnownInternalGraphStage",
            "static VCAMReplacementRoute VCAMReplacementRouteForOutput",
        )
        for node_class in (
            "BWSlaveFrameSynchronizerNode",
            "BWSynchronizerNode",
            "BWFanOutNode",
            "BWPreviewStitcherNode",
            "BWStreamingFilterNode",
            "BWInferenceNode",
            "BWCrossoverNode",
            "BWMetadataDetectorGatingNode",
        ):
            self.assertIn(f'@"{node_class}"', helper)
        self.assertIn('@"VideoCapture(PrimaryScaler)"', helper)
        self.assertIn('@"Preview Governor"', helper)

        internal_guard = self.route_function.index(
            "VCAMOutputIsKnownInternalGraphStage(nodeClass, nodeName, outputName)"
        )
        fallback = self.route_function.rindex(
            "return VCAMReplacementRouteUniversalVideo;"
        )
        self.assertLess(internal_guard, fallback)
        self.assertIn(
            "return VCAMReplacementRouteNone;",
            self.route_function[internal_guard:fallback],
        )

    def test_successful_source_replacement_writes_versioned_full_time_marker(self) -> None:
        self.assertIn(
            'CFSTR("com.codex.vcam.virtual-frame.v1")',
            self.entry,
        )
        for field in ("version", "value", "timescale", "flags", "epoch"):
            self.assertIn(f'@"{field}"', self.entry)
        self.assertIn("kCMAttachmentMode_ShouldPropagate", self.entry)
        self.assertIn("kCVAttachmentMode_ShouldPropagate", self.entry)
        in_place = _between(
            self.entry,
            "static BOOL VCAMReplaceSampleBufferInPlace",
            "// SumUp's final still encoder",
        )
        self.assertIn("VCAMCopyReplacementBufferIntoTarget", in_place)
        self.assertIn("VCAMRouteUsesPropagationMarker(route)", in_place)
        self.assertIn(
            "VCAMWritePropagationMarker(sampleBuffer, imageBuffer)",
            in_place,
        )

    def test_source_marker_uses_the_original_sample_without_a_clone(self) -> None:
        in_place = _between(
            self.entry,
            "static BOOL VCAMReplaceSampleBufferInPlace",
            "// SumUp's final still encoder",
        )
        self.assertIn("CVPixelBufferRef replacementBuffer = NULL", in_place)
        self.assertIn("if (rendered && replacementBuffer != NULL)", in_place)
        self.assertIn("VCAMCopyReplacementBufferIntoTarget", in_place)
        self.assertIn("VCAMWritePropagationMarker(sampleBuffer, imageBuffer)", in_place)
        self.assertNotIn("replacementSampleBuffer", in_place)

    def test_ios18_forwards_original_sample_after_in_place_copy(self) -> None:
        in_place = _between(
            self.entry,
            "static BOOL VCAMReplaceSampleBufferInPlace",
            "// SumUp's final still encoder",
        )
        self.assertIn("BOOL rendered = drawReplacementOntoBuffer", in_place)
        self.assertIn("VCAMCopyReplacementBufferIntoTarget(", in_place)
        self.assertIn("CVPixelBufferRelease(replacementBuffer)", in_place)
        self.assertNotIn("VCAMCreateSampleBufferWithReplacementImage", self.entry)
        self.assertNotIn("CMSampleBufferCreateReadyWithImageBuffer", self.entry)

        self.assertIn("%orig(sampleBuffer);", self.hook)
        self.assertNotIn("%orig(replacementSampleBuffer)", self.hook)
        self.assertIn("cameracaptured accepts the original graph-owned sample", self.entry)

    def test_ios16_observed_p420_preview_does_not_depend_on_capability_probe(self) -> None:
        utils = UTILS_PATH.read_text(encoding="utf-8")
        compressed_formats = _between(
            utils,
            "static BOOL VCAMFormatIsCompressedVideoRange",
            "static CVReturn VCAMCreateStagingPool",
        )
        support = _between(
            utils,
            "BOOL VCAMTargetBufferIsSupported",
            "static BOOL VCAMFillBlackSharedFrame",
        )
        compressed_branch = _between(
            support,
            "if (compressedVideoRange)",
            "return CVPixelBufferGetWidthOfPlane",
        )
        self.assertIn("format == (OSType)0x70343230", compressed_formats)
        self.assertIn("format == (OSType)0x70343230", compressed_branch)

    def test_ios16_observed_deferred_photo_format_uses_compressed_transfer(self) -> None:
        utils = UTILS_PATH.read_text(encoding="utf-8")
        compressed_formats = _between(
            utils,
            "static BOOL VCAMFormatIsCompressedVideoRange",
            "static CVReturn VCAMCreateStagingPool",
        )
        support = _between(
            utils,
            "BOOL VCAMTargetBufferIsSupported",
            "static BOOL VCAMFillBlackSharedFrame",
        )
        compressed_branch = _between(
            support,
            "if (compressedVideoRange)",
            "return CVPixelBufferGetWidthOfPlane",
        )
        self.assertIn("format == (OSType)0x26786630", compressed_formats)
        self.assertIn("format == (OSType)0x26786630", compressed_branch)

    def test_downstream_fast_path_requires_its_own_matching_numeric_marker(self) -> None:
        matcher = _between(
            self.entry,
            "static BOOL VCAMSampleHasMatchingPropagationMarker",
            "static VCAMReplacementRoute VCAMReplacementRouteForOutput",
        )
        self.assertIn("CMGetAttachment(sampleBuffer", matcher)
        self.assertIn("CVBufferGetAttachment(imageBuffer", matcher)
        self.assertGreaterEqual(matcher.count("kCMAttachmentMode_ShouldPropagate"), 1)
        self.assertGreaterEqual(matcher.count("kCVAttachmentMode_ShouldPropagate"), 1)
        self.assertGreaterEqual(matcher.count("CMTIME_IS_NUMERIC"), 1)
        self.assertIn("CMTimeCompare(markerTime, presentationTime) == 0", matcher)

        self.assertRegex(
            self.hook,
            re.compile(
                r'VCAMRouteUsesPropagationMarker\(replacementRoute\)\s*&&'
                r'\s*VCAMSampleHasMatchingPropagationMarker\('
                r'\s*sampleBuffer,\s*originalImageBuffer\s*\)',
                re.DOTALL,
            ),
        )

    def test_still_route_neither_writes_nor_consumes_propagation_marker(self) -> None:
        route_helper = _between(
            self.entry,
            "static BOOL VCAMRouteUsesPropagationMarker",
            "static BOOL VCAMWritePropagationMarker",
        )
        self.assertIn("VCAMReplacementRouteCameraSourceVideo", route_helper)
        self.assertNotIn("VCAMReplacementRouteStillPhoto", route_helper)
        self.assertNotIn("VCAMReplacementRoutePhotoEncoder", route_helper)
        in_place = _between(
            self.entry,
            "static BOOL VCAMReplaceSampleBufferInPlace",
            "// SumUp's final still encoder",
        )
        self.assertIn("VCAMWritePropagationMarker(sampleBuffer, imageBuffer)", in_place)

    def test_webkit_terminal_propagates_only_on_ios18(self) -> None:
        route_helper = _between(
            self.entry,
            "static BOOL VCAMRouteUsesPropagationMarker",
            "static BOOL VCAMWritePropagationMarker",
        )
        self.assertRegex(
            route_helper,
            re.compile(
                r"route == VCAMReplacementRouteVideoConverter\s*&&\s*"
                r"VCAMOperatingSystemIsAtLeast18\(\)",
                re.DOTALL,
            ),
        )
        self.assertIn("VCAMReplacementRouteCameraPreview", route_helper)
        self.assertIn("VCAMReplacementRouteVideoRecording", route_helper)
        in_place = _between(
            self.entry,
            "static BOOL VCAMReplaceSampleBufferInPlace",
            "// SumUp's final still encoder",
        )
        self.assertIn("VCAMPresentationForReplacementRoute(replacementRoute)", self.entry)
        self.assertIn("VCAMRouteUsesPropagationMarker(route)", in_place)
        self.assertIn("VCAMClearPropagationMarker", in_place)

    def test_ios18_background_blur_is_a_known_preterminal_stage(self) -> None:
        routing = _between(
            self.entry,
            "static VCAMReplacementRoute VCAMReplacementRouteForOutput",
            "static void VCAMLogOutputSignature",
        )
        self.assertIn("BWBackgroundBlurNode", routing)
        background_gate = routing.split("BWBackgroundBlurNode", 1)[0].rsplit("if (", 1)[1]
        self.assertIn("VCAMOperatingSystemIsAtLeast18()", background_gate)

    def test_marked_recording_frame_reaches_system_encoder_without_second_guard(self) -> None:
        fast_path = _between(
            self.hook,
            "BOOL propagatedReplacement =",
            "static volatile int videoSamples",
        )
        self.assertIn("%orig(sampleBuffer)", fast_path)
        self.assertNotIn("static CMTime", fast_path)
        self.assertNotIn("VCAMRecordRecordingFrameOutcome", fast_path)
        self.assertNotIn("VCAMEncodedRecordingSampleCanPass", self.hook)
        self.assertNotIn("guarding encoded recording sample", self.hook)

    def test_unmarked_same_pts_frame_must_render_or_be_suppressed(self) -> None:
        propagated_assignment = _between(
            self.hook,
            "BOOL propagatedReplacement =",
            "if (propagatedReplacement)",
        )
        self.assertIn(
            "VCAMSampleHasMatchingPropagationMarker(sampleBuffer, originalImageBuffer)",
            propagated_assignment,
        )
        self.assertNotIn("presentationTime", propagated_assignment)
        self.assertNotIn("VCAMRecordingFrameOutcomes", propagated_assignment)

        after_fast_path = self.hook.split("if (propagatedReplacement)", 1)[1]
        self.assertIn("VCAMReplaceSampleBufferInPlace", after_fast_path)
        self.assertIn("if (!replacementSucceeded && virtualModeEnabled &&", after_fast_path)
        failure_path = _between(
            after_fast_path,
            "if (!replacementSucceeded && virtualModeEnabled &&",
            "// cameracaptured accepts the original graph-owned sample",
        )
        self.assertLess(failure_path.index("return;"), len(failure_path))
        self.assertNotIn("%orig(", failure_path)

    def test_remote_queue_sink_replaces_video_data_boundary(self) -> None:
        remote_sink = _between(
            self.entry,
            "%hook BWRemoteQueueSinkNode",
            "%end",
        )
        self.assertIn(
            "- (void)renderSampleBuffer:(CMSampleBufferRef)sampleBuffer forInput:(id)input",
            remote_sink,
        )
        self.assertIn("CMFormatDescriptionGetMediaType", remote_sink)
        self.assertIn("kCMMediaType_Video", remote_sink)
        self.assertIn("remote queue sink diagnostic", remote_sink)
        self.assertIn("%orig(sampleBuffer, input);", remote_sink)
        self.assertIn("VCAMReplaceSampleBufferInPlace", remote_sink)
        self.assertIn("VCAMFramePresentationCameraPreviewFit", remote_sink)
        self.assertIn("VCAMVirtualModeIsEnabled", remote_sink)
        self.assertIn("VCAMSampleHasMatchingPropagationMarker", remote_sink)
        self.assertIn("VCAMOperatingSystemIsAtLeast18()", remote_sink)
        self.assertIn("passing propagated remote queue virtual frame", remote_sink)
        self.assertIn("suppressing remote queue real sample", remote_sink)
        self.assertIn("return;", remote_sink)


if __name__ == "__main__":
    unittest.main()
