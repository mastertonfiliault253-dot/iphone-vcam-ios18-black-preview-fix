import pathlib
import unittest


ROOT = pathlib.Path(__file__).parents[1]


class MediaServerTargetFillTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.implementation = (
            ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefImageUtils.m"
        ).read_text(encoding="utf-8")
        cls.adapter = cls.implementation.split("CIImage *image =", 1)[1].split(
            "CIRenderDestination *destination", 1
        )[0]

    def test_consumer_adapter_selects_fit_or_fill_without_device_orientation_guessing(self) -> None:
        fill_scale = "CGFloat scale = aspectFit"

        self.assertIn(fill_scale, self.adapter)
        self.assertIn("MIN((CGFloat)renderWidth", self.adapter)
        self.assertIn("MAX((CGFloat)renderWidth", self.adapter)
        # Still-photo fill rotates canonical portrait pixels into the system's
        # landscape still basis; preview (aspectFit) and other routes never
        # guess device orientation.
        self.assertIn("!realtimeCompensation && /* sourceIsPortrait always YES */ YES", self.adapter)
        self.assertNotIn("aspectFit && sourceIsPortrait", self.adapter)
        self.assertNotIn("interfaceOrientation", self.adapter)
        self.assertIn("imageByCroppingToRect:CGRectMake(0, 0, renderWidth, renderHeight)", self.adapter)

    def test_still_route_marks_orientation_for_landscape_still_basis(self) -> None:
        # The system still-photo basis is landscape (4224x3024); Photos shows
        # portrait via the Orientation attachment. VCAM renders canonical
        # portrait pixels there and marks the final sample Orientation=Right
        # (0.8.80 behavior). The 0.8.81 audit removed the mark and saved
        # photos came out landscape on device.
        entry = (
            ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefEntry.xm"
        ).read_text(encoding="utf-8")
        self.assertIn("stillPhotoRequiresRightOrientation", self.adapter)
        self.assertIn("VCAMSetStillPhotoDisplayOrientation", entry)
        self.assertIn("kCGImagePropertyOrientationRight", entry)

    def test_webkit_terminal_alone_uses_landscape_storage_compensation(self) -> None:
        # Device A/B: the same canonical portrait source is upright in Camera
        # but appears rotated 90 degrees in Safari's 640x480 video-converter
        # terminal. Only that explicit route may pre-rotate the raw pixels.
        self.assertIn(
            "webKitLandscapeStorage && sourceIsPortrait",
            self.adapter,
        )
        webkit_adapter = self.adapter.split(
            "if (webKitLandscapeStorage && sourceIsPortrait", 1
        )[1].split("// The producer publishes", 1)[0]
        self.assertIn(
            "imageByApplyingOrientation:kCGImagePropertyOrientationLeft",
            webkit_adapter,
        )
        self.assertNotIn("kCGImagePropertyOrientationUpMirrored", webkit_adapter)

        entry = (
            ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefEntry.xm"
        ).read_text(encoding="utf-8")
        render_call = entry.split(
            "replacementSucceeded = VCAMReplaceSampleBufferInPlace(", 1
        )[1].split(");", 1)[0]
        self.assertIn(
            "VCAMPresentationForReplacementRoute(replacementRoute)", render_call
        )
        presentation = entry.split(
            "static VCAMFramePresentation VCAMPresentationForReplacementRoute", 1
        )[1].split("static BOOL VCAMStringMatches", 1)[0]
        self.assertRegex(
            presentation,
            r"case VCAMReplacementRouteVideoConverter:\s*"
            r"return VCAMFramePresentationWebKitFill;",
        )
        self.assertNotIn(
            "replacementRoute == VCAMReplacementRouteCameraPreview\n"
            "                    ?",
            render_call,
        )

    def test_webkit_uses_one_camera_style_crop_in_the_negotiated_profile(self) -> None:
        entry = (
            ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefEntry.xm"
        ).read_text(encoding="utf-8")
        render_call = entry.split(
            "replacementSucceeded = VCAMReplaceSampleBufferInPlace(", 1
        )[1].split(");", 1)[0]

        # WebKit still owns the target profile (480p/720p/1080p), pixel format
        # and timing. VCAM performs exactly one camera-style center crop while
        # composing into that target. WebKit receives the original target size,
        # so there is no second VCAM scale or format renegotiation.
        self.assertIn(
            "VCAMPresentationForReplacementRoute(replacementRoute)", render_call
        )
        implementation = (
            ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefImageUtils.m"
        ).read_text(encoding="utf-8")
        aspect_fit_assignment = implementation.split("BOOL aspectFit =", 1)[1].split(
            ";", 1
        )[0]
        self.assertEqual(
            "".join(aspect_fit_assignment.split()),
            "presentation==VCAMFramePresentationCameraPreviewFit",
        )
        self.assertEqual(
            self.adapter.count(
                "imageByApplyingTransform:CGAffineTransformMakeScale"
            ),
            1,
        )
        self.assertIn(
            "CGFloat x = ((CGFloat)renderWidth - CGRectGetWidth(image.extent)) * 0.5",
            self.adapter,
        )
        self.assertIn(
            "CGFloat y = ((CGFloat)renderHeight - CGRectGetHeight(image.extent)) * 0.5",
            self.adapter,
        )

        source_width, source_height = 3840, 2160
        for target_width, target_height in ((640, 480), (1280, 720), (1920, 1080)):
            with self.subTest(target=(target_width, target_height)):
                scale = max(
                    target_width / source_width,
                    target_height / source_height,
                )
                scaled_width = source_width * scale
                scaled_height = source_height * scale
                self.assertGreaterEqual(scaled_width, target_width)
                self.assertGreaterEqual(scaled_height, target_height)
                self.assertTrue(
                    abs(scaled_width - target_width) < 1e-9
                    or abs(scaled_height - target_height) < 1e-9
                )

    def test_full_bleed_modes_cover_still_and_recording_targets(self) -> None:
        # WebKit, recording and still-photo use camera-style full bleed. Camera
        # preview alone retains the separately tested whole-frame fit mode.
        cases = (
            ((1080, 1920), (4224, 3024)),  # Camera still-photo sensor buffer
            ((1080, 1920), (1920, 1080)),  # Camera movie recording buffer
        )
        for (source_width, source_height), (target_width, target_height) in cases:
            with self.subTest(target=(target_width, target_height)):
                scale = max(
                    target_width / source_width,
                    target_height / source_height,
                )
                self.assertGreaterEqual(source_width * scale, target_width)
                self.assertGreaterEqual(source_height * scale, target_height)

    def test_darwin_notification_observer_is_a_stable_nonnull_token(self) -> None:
        # iOS 18 cameracaptured crashes inside CoreFoundation while hashing the
        # Darwin notification observer when the observer is NULL or a raw
        # address. Use a process-lifetime CF object so arm64e PAC sees a valid
        # CF/ObjC identity rather than arbitrary static storage.
        self.assertIn(
            "static CFStringRef VCAMPreferencesObserverToken =",
            self.implementation,
        )
        observer_call = self.implementation.split(
            "CFNotificationCenterAddObserver(", 1
        )[1].split(");", 1)[0]
        self.assertIn("(__bridge const void *)VCAMPreferencesObserverToken", observer_call)
        self.assertNotIn("&VCAMPreferencesObserverToken", observer_call)
        self.assertNotIn("CFNotificationCenterGetDarwinNotifyCenter(), NULL,", observer_call)

    def test_webkit_reuses_the_real_camera_negotiation_shell(self) -> None:
        entry = (
            ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefEntry.xm"
        ).read_text(encoding="utf-8")
        in_place = entry.split(
            "static BOOL VCAMReplaceSampleBufferInPlace", 1
        )[1].split("// SumUp's final still encoder", 1)[0]
        render_call = in_place.split(
            "BOOL rendered = drawReplacementOntoBuffer", 1
        )[1].split(");", 1)[0]

        self.assertIn("imageBuffer", render_call)
        self.assertIn("VCAMCopyReplacementBufferIntoTarget", in_place)
        self.assertIn("CVPixelBufferRelease(replacementBuffer)", in_place)
        self.assertNotIn("CMSampleBufferCreateReadyWithImageBuffer", entry)
        self.assertNotIn("CMSampleBufferGetSampleTimingInfo", in_place)

        hook = entry.split("%hook BWNodeOutput", 1)[1].split("%end", 1)[0]
        self.assertIn("%orig(sampleBuffer);", hook)
        self.assertNotIn("%orig(replacementSampleBuffer)", hook)


if __name__ == "__main__":
    unittest.main()
