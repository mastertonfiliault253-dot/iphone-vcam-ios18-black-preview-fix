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
        self.assertIn("!realtimeCompensation && targetWidth > targetHeight", self.adapter)
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

    def test_webkit_adapts_portrait_source_to_negotiated_landscape_storage(self) -> None:
        # The iOS 18 trace negotiates a portrait WebKit target on the rear lens
        # and a landscape target on the front lens. Rotate only when the
        # explicit WebKit target basis differs from the canonical portrait
        # source; OS version and hard-coded resolutions must not decide it.
        self.assertIn(
            "BOOL webKitRotatedForStorage = webKitLandscapeStorage &&",
            self.adapter,
        )
        webkit_adapter = self.adapter.split(
            "BOOL webKitRotatedForStorage =", 1
        )[1].split("// The producer publishes", 1)[0]
        self.assertIn("sourceIsPortrait && targetWidth > targetHeight", webkit_adapter)
        self.assertNotIn("VCAMRuntimeIsAtLeastIOS18", webkit_adapter)
        self.assertIn("VCAMLastCameraIsFront", self.adapter)
        self.assertIn("currentCameraIsFront", webkit_adapter)
        self.assertIn("kCGImagePropertyOrientationRight", webkit_adapter)
        self.assertIn("kCGImagePropertyOrientationLeft", webkit_adapter)
        self.assertIn(
            "imageByApplyingOrientation:storageOrientation",
            webkit_adapter,
        )
        self.assertNotIn("kCGImagePropertyOrientationUpMirrored", webkit_adapter)

    def test_front_webkit_mirror_compensation_is_consumer_scoped(self) -> None:
        # The shared frame is canonical and unmirrored. The front WebKit graph
        # mirrors its preview after the converter, so pre-compensate exactly
        # that consumer. Camera preview, still photo, recording and rear WebKit
        # must not receive this transform.
        self.assertIn(
            "webKitLandscapeStorage && currentCameraIsFront",
            self.adapter,
        )
        self.assertIn("VCAMLastCameraIsFront()", self.adapter)
        mirror_block = self.adapter.split(
            "if (webKitFrontPresentation)", 1
        )[1].split("// The producer publishes", 1)[0]
        self.assertIn("CGAffineTransformMakeScale(-1.0, 1.0)", mirror_block)
        self.assertEqual(
            self.adapter.count("CGAffineTransformMakeScale(-1.0, 1.0)"),
            1,
        )

    def test_composition_logs_negotiated_coverage_without_pixels(self) -> None:
        self.assertIn("composition diagnostic presentation=%s", self.adapter)
        for field in (
            "source=%.0fx%.0f",
            "oriented=%.0fx%.0f",
            "target=%zux%zu",
            "front=%d",
            "rotate=%d",
            "mirror=%d",
            "scale=%.6f",
            "coverage=%.1fx%.1f",
        ):
            self.assertIn(field, self.adapter)

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
        # 2026-10-16: camera preview no longer letterboxes either — every
        # terminal shares the full-bleed center crop. Whole-frame fit padded
        # mismatched-aspect RTSP sources into the app's preview buffer and KYC
        # document capture showed those pads as black side bars.
        aspect_fit_assignment = implementation.split("BOOL aspectFit =", 1)[1].split(
            ";", 1
        )[0]
        self.assertEqual("".join(aspect_fit_assignment.split()), "NO")
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
        self.assertIn("VCAMPreferencesObserverToken", observer_call)
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
        self.assertIn("VCAMCreatePlanarRenderBuffer", self.implementation)
        self.assertIn("VCAMTransferBGRAIntoPlanarTarget", self.implementation)
        self.assertIn("BOOL planarTarget", self.implementation)
        self.assertIn("CVPixelBufferRelease(replacementBuffer)", in_place)
        self.assertNotIn("CMSampleBufferCreateReadyWithImageBuffer", entry)
        self.assertNotIn("CMSampleBufferGetSampleTimingInfo", in_place)

        hook = entry.split("%hook BWNodeOutput", 1)[1].split("%end", 1)[0]
        self.assertIn("%orig(sampleBuffer);", hook)
        self.assertNotIn("%orig(replacementSampleBuffer)", hook)

    def test_planar_target_has_cpu_fallback_and_reports_after_final_write(self) -> None:
        # iOS 18 can return success from Core Image/VideoToolbox while the
        # graph-owned 420f/420v target remains black. Keep a deterministic CPU
        # writer at this seam, and only publish rendered after the final target
        # write has completed.
        self.assertIn("VCAMCopyBGRAToPlanarTarget", self.implementation)
        planar_transfer = self.implementation.split(
            "static BOOL VCAMTransferBGRAIntoPlanarTarget", 1
        )[1].split("BOOL VCAMCopyReplacementBufferIntoTarget", 1)[0]
        self.assertIn("VCAMCopyBGRAToPlanarTarget(stagingBuffer, targetBuffer)", planar_transfer)
        self.assertLess(
            planar_transfer.index("VCAMCopyBGRAToPlanarTarget"),
            planar_transfer.index("VTPixelTransferSessionTransferImage"),
        )

        draw = self.implementation.split("BOOL drawReplacementOntoBuffer", 1)[1]
        self.assertNotIn('notify_post(coreImageRendered', draw)
        self.assertIn("notify_post(rendered", draw)

    def test_planar_target_writer_uses_the_backing_iosurface(self) -> None:
        # The iOS 18 graph-owned 420f target read back as video-range black
        # even though the BGRA staging buffer was non-black. Use the actual
        # IOSurface planes under an explicit synchronized surface lock so the
        # bytes handed to the graph are the bytes that were written.
        self.assertIn("#import <CoreVideo/CVPixelBufferIOSurface.h>", self.implementation)
        self.assertIn("CVPixelBufferGetIOSurface(targetBuffer)", self.implementation)
        self.assertIn("IOSurfaceLock(targetSurface, 0, NULL)", self.implementation)
        self.assertIn("IOSurfaceGetBaseAddressOfPlane(targetSurface, 0)", self.implementation)
        self.assertIn("IOSurfaceGetBaseAddressOfPlane(targetSurface, 1)", self.implementation)
        self.assertIn("IOSurfaceUnlock(targetSurface, 0, NULL)", self.implementation)

    def test_planar_writer_reports_before_after_and_relock_samples(self) -> None:
        # A post-unlock read through Core Video alone cannot distinguish an
        # ineffective write from a surface/cache hand-off that discards it.
        # Keep the three observations in the production probe contract.
        for state_name in (
            "direct-write-before.state",
            "direct-write-after.state",
            "direct-write-relock.state",
        ):
            self.assertIn(state_name, self.implementation)
        self.assertIn("IOSurfaceGetID(targetSurface)", self.implementation)
        self.assertIn("IOSurfaceLock(targetSurface, 0, NULL) == 0", self.implementation)

    def test_external_bgra_source_is_localized_before_core_image(self) -> None:
        # cameracaptured's software Core Image context can complete a render
        # while reading an externally-created IOSurface as black. Localize the
        # BGRA source bytes before constructing the CIImage so the renderer
        # consumes a process-owned pixel buffer.
        self.assertIn("VCAMCreateLocalBGRASourceBuffer", self.implementation)
        self.assertIn("VCAMCopyBGRASourceToLocal", self.implementation)
        draw = self.implementation.split("BOOL drawReplacementOntoBuffer", 1)[1]
        image_section = draw.split("CIImage *image =", 1)[1].split(
            "BOOL sourceIsPortrait", 1
        )[0]
        self.assertIn("ciSourceBuffer", image_section)
        self.assertIn("imageWithCVPixelBuffer:ciSourceBuffer", image_section)
        self.assertNotIn("imageWithCVPixelBuffer:scratch", image_section)

    def test_camera_preview_reuses_only_an_exact_unchanged_render(self) -> None:
        # The stock Camera preview can request the same source at ~20 fps.
        # iOS 18 may expose that source through either a one-slot IOSurface or
        # the mmap compatibility transport (surfaceSlotCount == 0). Reuse is
        # safe only for the exact source generation/sequence and negotiated
        # output; WebKit, photo, recording and compressed paths must continue
        # through their existing render code.
        self.assertIn("VCAMPreviewCacheLock", self.implementation)
        self.assertIn("VCAMPreviewCacheCanReuse", self.implementation)
        cache_gate = self.implementation.split(
            "static BOOL VCAMPreviewCacheCanReuse", 1
        )[1].split("static BOOL VCAMCopyPreviewCacheIntoTarget", 1)[0]
        for key_part in (
            "metadata.sequence",
            "metadata.surfaceGeneration",
            "metadata.surfaceSlotCount <= 1",
            "targetWidth",
            "targetHeight",
            "targetFormat",
        ):
            self.assertIn(key_part, cache_gate)
        self.assertIn("VCAMFramePresentationCameraPreviewFit", cache_gate)
        self.assertIn("planarTarget", cache_gate)
        self.assertIn("VCAMRuntimeIsAtLeastIOS18()", cache_gate)
        self.assertNotIn("VCAMFramePresentationWebKitFill", cache_gate)
        self.assertNotIn("VCAMFramePresentationStillPhotoFill", cache_gate)

        cache_copy = self.implementation.split(
            "static BOOL VCAMCopyPreviewCacheIntoTarget", 1
        )[1].split("static void VCAMRememberPreviewTarget", 1)[0]
        self.assertIn("VCAMCopyPlanarPixels", cache_copy)
        self.assertNotIn("VTPixelTransferSessionTransferImage", cache_copy)

        shared = (ROOT / "Sources" / "Shared" / "VCAMSharedFrame.m").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            "metadata->surfaceSlotCount = reader->header->slotCount", shared
        )
        self.assertIn("metadata->surfaceSlotCount = 0", shared)

        draw = self.implementation.split("BOOL drawReplacementOntoBuffer", 1)[1]
        cache_lookup = draw.index("VCAMCopyPreviewCacheIntoTarget")
        core_image = draw.index("CIImage *image =")
        self.assertLess(cache_lookup, core_image)
        self.assertIn("VCAMInvalidatePreviewCache();", draw)
        self.assertIn("preview replacement performance window", self.implementation)

    def test_black_surface_fallback_uses_cpu_readable_mmap_bootstrap(self) -> None:
        # The mmap bootstrap is already local data; putting it through another
        # IOSurface-backed pool can reproduce iOS 18's black CPU mapping.
        self.assertIn("VCAMCreateCPUReadableBGRABuffer", self.implementation)
        self.assertIn("usingMmapBootstrap", self.implementation)
        fallback = self.implementation.split(
            "if (surfaceIsBGRA &&", 1
        )[1].split("if (copied)", 1)[0]
        self.assertIn("VCAMSharedFrameReaderCopyLatest", fallback)
        self.assertIn("mmapMetadata.surfaceGeneration == metadata.surfaceGeneration", fallback)
        self.assertIn("VCAMPixelBufferHasRGBContent(mmapScratch)", fallback)

    def test_black_surface_fallback_publishes_bounded_rgb_gate_telemetry(self) -> None:
        self.assertIn("[DEBUG-6f2c]", self.implementation)
        self.assertIn("VCAMDebug6F2CRGBCoverageSummary", self.implementation)
        self.assertIn("debug-6f2c.fallback-state", self.implementation)
        self.assertIn("debug-6f2c.surface-rgb", self.implementation)
        self.assertIn("debug-6f2c.mmap-rgb", self.implementation)
        self.assertIn("debug-6f2c.source-state", self.implementation)
        self.assertIn("!surfaceHasRGB || publishPixelDiagnostics", self.implementation)

    def test_direct_mmap_path_publishes_source_selection_state(self) -> None:
        self.assertIn("directMmapAttempted", self.implementation)
        self.assertIn("directMmapCopied", self.implementation)
        self.assertIn("debug6F2CSourceState", self.implementation)
        self.assertIn("VCAMDebug6F2CRGBCoverageSummary", self.implementation)
        self.assertIn("debug6F2CSourceState |= 1ULL << 19", self.implementation)

    def test_external_bgra_source_reads_the_imported_iosurface_under_lock(self) -> None:
        # An XPC-imported IOSurface can expose a stale CoreVideo CPU mapping on
        # iOS 18. The localization copy must use the synchronized surface
        # address first and retain CoreVideo as a non-surface fallback.
        self.assertIn("IOSurfaceLock(sourceSurface, 1, NULL) == 0", self.implementation)
        self.assertIn("IOSurfaceGetBaseAddress(sourceSurface)", self.implementation)
        self.assertIn("IOSurfaceGetBytesPerRow(sourceSurface)", self.implementation)
        self.assertIn("IOSurfaceUnlock(sourceSurface, 1, NULL)", self.implementation)
        self.assertIn("CVPixelBufferGetBaseAddress(sourceBuffer)", self.implementation)

    def test_common_camera_output_defaults_to_universal_replacement(self) -> None:
        entry = (
            ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefEntry.xm"
        ).read_text(encoding="utf-8")
        self.assertIn("VCAMReplacementRouteUniversalVideo", entry)
        route = entry.split(
            "static VCAMReplacementRoute VCAMReplacementRouteForOutput", 1
        )[1].split("static void VCAMLogOutputSignature", 1)[0]
        self.assertIn("return VCAMReplacementRouteUniversalVideo;", route)

        presentation = entry.split(
            "static VCAMFramePresentation VCAMPresentationForReplacementRoute", 1
        )[1].split("static BOOL VCAMStringMatches", 1)[0]
        self.assertRegex(
            presentation,
            r"case VCAMReplacementRouteUniversalVideo:\s*"
            r"return VCAMFramePresentationRealtimeFill;",
        )


if __name__ == "__main__":
    unittest.main()
