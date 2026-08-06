import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).parents[1]
ENTRY_PATH = ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefEntry.xm"


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

    def test_only_video_capture_output_of_multistream_source_routes_upstream(self) -> None:
        self.assertIn("VCAMReplacementRouteCameraSourceVideo", self.entry)
        self.assertRegex(
            self.route_function,
            re.compile(
                r'VCAMStringMatches\(nodeClass,\s*@"BWMultiStreamCameraSourceNode"\)'
                r'\s*&&\s*VCAMStringMatches\(outputName,\s*@"VideoCapture"\)'
                r'\s*\)\s*\{\s*return VCAMReplacementRouteCameraSourceVideo;',
                re.DOTALL,
            ),
        )
        self.assertNotIn('@"Preview"', self.route_function)
        self.assertNotIn('@"StillImage"', self.route_function)

    def test_source_route_is_selected_before_buffer_support_is_considered(self) -> None:
        source_match = re.search(
            r'if\s*\(VCAMStringMatches\(nodeClass,\s*@"BWMultiStreamCameraSourceNode"\)'
            r'.*?return VCAMReplacementRouteCameraSourceVideo;\s*\}',
            self.route_function,
            re.DOTALL,
        )
        self.assertIsNotNone(source_match)
        self.assertNotIn("targetSupported", source_match.group(0))

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

    def test_only_three_exact_pixel_transfer_terminals_and_meteor_still_remain(self) -> None:
        for terminal_name, route_name in (
            ("Video Data Converter/Scaler/Zoomer", "VideoConverter"),
            ("Preview Scaler", "CameraPreview"),
            ("Movie File Zoomer", "VideoRecording"),
        ):
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
        self.assertNotIn("VCAMReplacementRouteStillPhoto", route_helper)
        self.assertRegex(
            self.hook,
            re.compile(
                r'replacementRoute\s*==\s*VCAMReplacementRouteCameraSourceVideo'
                r'.*?VCAMWritePropagationMarker',
                re.DOTALL,
            ),
        )

    def test_marked_recording_frame_authorizes_only_its_encoded_frame(self) -> None:
        fast_path = _between(
            self.hook,
            "BOOL propagatedReplacement =",
            "static volatile int videoSamples",
        )
        self.assertRegex(
            fast_path,
            re.compile(
                r'if\s*\(replacementRoute\s*==\s*VCAMReplacementRouteVideoRecording\)'
                r'\s*\{\s*VCAMRecordRecordingFrameOutcome\('
                r'\s*self,\s*sampleBuffer,\s*originalImageBuffer,\s*YES\s*\);',
                re.DOTALL,
            ),
        )
        self.assertLess(
            fast_path.index("VCAMRecordRecordingFrameOutcome"),
            fast_path.index("%orig(sampleBuffer)"),
        )
        self.assertNotIn("static CMTime", fast_path)
        self.assertNotIn("VCAMRecordRecordingFrameOutcome", fast_path.split(
            "if (propagatedReplacement)", 1
        )[0])

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


if __name__ == "__main__":
    unittest.main()
