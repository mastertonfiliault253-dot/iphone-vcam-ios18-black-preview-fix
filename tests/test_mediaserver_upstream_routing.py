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

    def test_raw_camera_video_stays_internal_until_observed_terminal_routes(self) -> None:
        # Shared pixels are already in the source's presentation orientation.
        # Injecting them into the raw sensor branch makes Camera and WebKit apply
        # their different physical-camera transforms a second time.
        self.assertIn(
            "return VCAMReplacementRouteCameraSourceVideo;", self.route_function
        )
        self.assertNotIn('@"Preview"', self.route_function)
        self.assertRegex(
            self.route_function,
            re.compile(
                r'VCAMStringMatches\(nodeClass,\s*@"BWMultiStreamCameraSourceNode"\)'
                r'\s*&&\s*VCAMStringMatches\(outputName,\s*@"StillImage"\)'
                r'\s*&&\s*VCAMTargetBufferIsSupported\(pixelBuffer\)'
                r'\s*\)\s*\{\s*return VCAMReplacementRouteCameraSourceVideo;',
                re.DOTALL,
            ),
        )

    def test_private_still_source_reaches_supported_downstream_photo_route(self) -> None:
        self.assertIn(
            'VCAMStringMatches(outputName, @"StillImage") &&\n'
            '        VCAMTargetBufferIsSupported(pixelBuffer)',
            self.route_function,
        )
        self.assertIn('VCAMStringMatches(nodeClass, @"BWMeteorHeadroomNode")', self.route_function)
        self.assertIn('VCAMStringMatches(nodeName, @"Meteor Headroom")', self.route_function)

    def test_terminal_routes_remain_fail_closed_for_missing_buffers(self) -> None:
        null_buffer_path = _between(
            self.hook,
            "if (originalImageBuffer == NULL) {",
            "if (!replacementAllowed) {",
        )
        self.assertRegex(
            null_buffer_path,
            re.compile(
                r'if\s*\(replacementAllowed\s*&&\s*VCAMVirtualModeIsEnabled\(\)\)'
                r'\s*\{.*?return;\s*\}.*?%orig\(sampleBuffer\);',
                re.DOTALL,
            ),
        )

    def test_only_device_observed_exact_pixel_transfer_terminals_and_meteor_still_remain(self) -> None:
        for terminal_name, route_name in (
            ("Video Data Converter/Scaler/Zoomer", "VideoConverter"),
            ("Video Data Converter/Rotator/Zoomer", "VideoConverter"),
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

    def test_ios16_movie_file_governor_is_a_fail_closed_recording_route(self) -> None:
        self.assertRegex(
            self.route_function,
            re.compile(
                r'VCAMStringMatches\(nodeClass,\s*@"BWFrameRateGovernorNode"\)'
                r'\s*&&\s*VCAMStringMatches\(nodeName,\s*@"Movie File Frame Rate Governor"\)'
                r'\s*\)\s*\{\s*return VCAMReplacementRouteVideoRecording;',
                re.DOTALL,
            ),
        )

    def test_fanout_and_inference_nodes_are_never_direct_replacement_routes(self) -> None:
        self.assertNotIn('@"BWFanOutNode"', self.route_function)
        self.assertNotIn('@"BWInferenceNode"', self.route_function)

    def test_successful_source_replacement_writes_versioned_full_time_marker(self) -> None:
        self.assertIn(
            'CFSTR("com.codex.vcam.virtual-frame.v1")',
            self.entry,
        )
        for field in ("version", "value", "timescale", "flags", "epoch"):
            self.assertIn(f'@"{field}"', self.entry)
        self.assertIn("kCMAttachmentMode_ShouldPropagate", self.entry)
        self.assertIn("kCVAttachmentMode_ShouldPropagate", self.entry)
        self.assertRegex(
            self.hook,
            re.compile(
                r'if\s*\(replacementSucceeded\s*&&\s*'
                r'replacementRoute\s*==\s*VCAMReplacementRouteCameraSourceVideo'
                r'.*?markerSampleBuffer\s*=\s*replacementSampleBuffer\s*!=\s*NULL'
                r'\s*\?\s*replacementSampleBuffer\s*:\s*sampleBuffer;'
                r'.*?markerImageBuffer\s*=\s*replacementImageBuffer\s*!=\s*NULL'
                r'\s*\?\s*replacementImageBuffer\s*:\s*originalImageBuffer;'
                r'.*?VCAMWritePropagationMarker\('
                r'\s*markerSampleBuffer,\s*markerImageBuffer\s*\)',
                re.DOTALL,
            ),
        )

    def test_uncompressed_source_marker_does_not_require_a_clone(self) -> None:
        source_marker_path = _between(
            self.hook,
            "replacementRoute == VCAMReplacementRouteCameraSourceVideo",
            "} @catch (NSException *exception)",
        )
        self.assertIn(": sampleBuffer", source_marker_path)
        self.assertIn(": originalImageBuffer", source_marker_path)
        self.assertIn("replacementSampleBuffer != NULL", source_marker_path)
        self.assertIn("replacementImageBuffer != NULL", source_marker_path)
        self.assertNotIn(
            "VCAMWritePropagationMarker(\n                    replacementSampleBuffer, replacementImageBuffer)",
            source_marker_path,
        )

    def test_invalid_private_format_retries_with_buffer_derived_description(self) -> None:
        sample_builder = _between(
            self.entry,
            "static CMSampleBufferRef VCAMCreateSampleBufferWithReplacementImage",
            "static CFStringRef const VCAMPropagationMarkerKey",
        )
        original_create = "CMSampleBufferCreateReadyWithImageBuffer("
        retry_guard = "createStatus == kCMSampleBufferError_InvalidMediaFormat"
        derived_create = "CMVideoFormatDescriptionCreateForImageBuffer("
        retry_region = _between(
            sample_builder,
            "if (createStatus == kCMSampleBufferError_InvalidMediaFormat) {",
            "if (createStatus != noErr || replacementSampleBuffer == NULL)",
        )

        self.assertEqual(sample_builder.count(original_create), 2)
        self.assertEqual(sample_builder.count(derived_create), 1)
        self.assertEqual(retry_region.count(original_create), 1)
        self.assertEqual(retry_region.count(derived_create), 1)
        self.assertIn(retry_guard, sample_builder)
        self.assertIn("sourceSubtype == (OSType)0x5b387630", sample_builder)
        self.assertIn("sourceSubtype == (OSType)0x7d387630", sample_builder)
        self.assertIn("sourceSubtype == (OSType)0x26786630", sample_builder)
        self.assertRegex(
            self.hook,
            re.compile(
                r'VCAMCreateSampleBufferWithReplacementImage\('
                r'\s*sampleBuffer,\s*replacementImageBuffer,\s*'
                r'replacementRoute\s*==\s*VCAMReplacementRouteCameraSourceVideo\s*\|\|\s*'
                r'replacementRoute\s*==\s*VCAMReplacementRouteStillPhoto\)',
                re.DOTALL,
            ),
        )
        self.assertIn("replacementImageBuffer, &derivedFormat", sample_builder)
        self.assertIn("replacementImageBuffer, derivedFormat", sample_builder)
        self.assertIn("derivedFormatMatchesSource", sample_builder)
        self.assertIn("derivedDimensions.width == dimensions.width", sample_builder)
        self.assertIn("derivedDimensions.height == dimensions.height", sample_builder)
        # The derived description is accepted on matching dimensions only: it is
        # created from the replacement buffer itself, so its subtype always
        # matches the pixels even when the source description (e.g. 10-bit
        # p420 vs 8-bit 420f) disagrees with the clone.
        self.assertNotIn(
            "CMFormatDescriptionGetMediaSubType(derivedFormat) ==",
            sample_builder,
        )
        self.assertIn("sourceSubtype", sample_builder)
        self.assertLess(
            retry_region.index("if (derivedFormatMatchesSource)"),
            retry_region.index("replacementImageBuffer, derivedFormat"),
        )
        self.assertIn("if (derivedFormat != NULL)", sample_builder)
        self.assertIn("CFRelease(derivedFormat);", sample_builder)
        derived_declaration = sample_builder.index(
            "CMVideoFormatDescriptionRef derivedFormat = NULL"
        )
        derived_release = sample_builder.index("CFRelease(derivedFormat);")
        self.assertNotIn("return", sample_builder[derived_declaration:derived_release])
        self.assertGreater(
            derived_release,
            sample_builder.index("replacementImageBuffer, derivedFormat"),
        )
        self.assertIn("if (createStatus != noErr || replacementSampleBuffer == NULL)", sample_builder)
        failure_path = _between(
            sample_builder,
            "if (createStatus != noErr || replacementSampleBuffer == NULL)",
            "if (attemptedDerivedFormat)",
        )
        self.assertIn(
            "if (replacementSampleBuffer != NULL)",
            failure_path,
        )
        self.assertIn("CFRelease(replacementSampleBuffer);", failure_path)
        self.assertLess(
            failure_path.index("CFRelease(replacementSampleBuffer);"),
            failure_path.index("return NULL;"),
        )
        self.assertLess(sample_builder.index(original_create), sample_builder.index(retry_guard))
        self.assertLess(sample_builder.index(retry_guard), sample_builder.index(derived_create))
        self.assertIn("compressed replacement sample used derived format", sample_builder)

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
        self.assertNotIn("VCAMReplacementRouteCameraSourceVideo", route_helper)
        self.assertRegex(
            self.hook,
            re.compile(
                r'replacementRoute\s*==\s*VCAMReplacementRouteCameraSourceVideo'
                r'.*?VCAMWritePropagationMarker',
                re.DOTALL,
            ),
        )

    def test_webkit_terminal_rerenders_from_uncompressed_shared_frame(self) -> None:
        route_helper = _between(
            self.entry,
            "static BOOL VCAMRouteUsesPropagationMarker",
            "static BOOL VCAMWritePropagationMarker",
        )
        self.assertNotIn("VCAMReplacementRouteVideoConverter", route_helper)
        self.assertIn("VCAMReplacementRouteCameraPreview", route_helper)
        self.assertIn("VCAMReplacementRouteVideoRecording", route_helper)
        redraw_path = _between(
            self.hook,
            "replacementSucceeded = drawReplacementOntoBuffer(",
            "} @catch (NSException *exception)",
        )
        self.assertIn("VCAMPresentationForReplacementRoute(replacementRoute)", redraw_path)
        self.assertIn("VCAMClearPropagationMarker", redraw_path)

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
        self.assertIn("drawReplacementOntoBuffer", after_fast_path)
        self.assertIn("if (!replacementSucceeded && virtualModeEnabled)", after_fast_path)
        failure_path = _between(
            after_fast_path,
            "if (!replacementSucceeded && virtualModeEnabled)",
            "if (replacementSucceeded && replacementSampleBuffer != NULL)",
        )
        self.assertLess(failure_path.index("return;"), len(failure_path))
        self.assertNotIn("%orig(", failure_path)

    def test_remote_queue_sink_probe_is_diagnostic_only(self) -> None:
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
        self.assertNotIn("drawReplacementOntoBuffer", remote_sink)
        self.assertNotIn("VCAMCreateSampleBufferWithReplacementImage", remote_sink)
        self.assertNotIn("VCAMVirtualModeIsEnabled", remote_sink)
        self.assertNotIn("return;", remote_sink)


if __name__ == "__main__":
    unittest.main()
