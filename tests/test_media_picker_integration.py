import pathlib
import unittest


ROOT = pathlib.Path(__file__).parents[1]


class MediaPickerIntegrationTests(unittest.TestCase):
    def test_picker_module_is_linked_into_the_tweak(self) -> None:
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")

        self.assertIn("VCAMMediaPickerController.m", makefile)
        self.assertIn("PhotosUI", makefile)

    def test_picker_uses_video_only_copy_then_configuration_reload(self) -> None:
        source = (
            ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m"
        ).read_text(encoding="utf-8")

        self.assertIn("PHPickerFilter.videosFilter", source)
        self.assertIn("loadFileRepresentationForTypeIdentifier", source)
        self.assertIn("[VCAMConfiguration importMediaAtURL:temporaryURL", source)
        self.assertIn("[VCAMConfiguration updateValues:changes]", source)
        self.assertNotIn('@"/var/mobile/Media/VCAM"', source)
        self.assertIn('@"source": @"local"', source)
        self.assertIn('@"enabled": @YES', source)
        self.assertIn('CFSTR("com.codex.vcam/preferences.changed")', source)

    def test_picker_storage_uses_shared_paths_with_legacy_process_fallback(self) -> None:
        configuration = (
            ROOT / "Sources" / "Core" / "VCAMConfiguration.m"
        ).read_text(encoding="utf-8")

        self.assertIn("NSApplicationSupportDirectory", configuration)
        self.assertIn("NSCachesDirectory", configuration)
        self.assertIn("NSTemporaryDirectory()", configuration)
        self.assertIn('@".write-probe"', configuration)
        self.assertIn("+ (NSString *)mediaDirectoryPath", configuration)
        self.assertIn(
            'return @"/var/mobile/Media/VCAM/com.codex.vcam.plist"',
            configuration,
        )
        self.assertIn('return @"/var/mobile/Media/VCAM"', configuration)
        self.assertIn("+ (NSDictionary<NSString *, id> *)currentValues", configuration)
        self.assertIn("legacyPath", configuration)

    def test_shared_preference_updates_use_springboard_write_broker(self) -> None:
        configuration_h = (ROOT / "Sources" / "Core" / "VCAMConfiguration.h").read_text(encoding="utf-8")
        configuration_m = (ROOT / "Sources" / "Core" / "VCAMConfiguration.m").read_text(encoding="utf-8")
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(encoding="utf-8")

        self.assertIn("updateValues", configuration_h)
        self.assertIn("startWriteBroker", configuration_h)
        self.assertIn("INADDR_LOOPBACK", configuration_m)
        self.assertIn("VCAMConfigurationBrokerPort", configuration_m)
        self.assertIn("VCAMConfigurationBrokerReadCommand", configuration_m)
        self.assertIn("copyValuesFromBroker", configuration_m)
        self.assertIn("allowedPreferenceKeys", configuration_m)
        self.assertIn("writeValuesDirectly", configuration_m)
        self.assertIn('@"/var/mobile/Media/VCAM/com.codex.vcam.plist"', configuration_m)
        self.assertIn("[VCAMConfiguration updateValues:changes]", picker)
        update_method = picker.split("- (BOOL)updatePreferences:", 1)[1]
        update_method = update_method.split("\n}", 1)[0]
        self.assertNotIn("writeToFile", update_method)

    def test_floating_dot_is_per_process_and_toggled_by_three_finger_double_tap(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(encoding="utf-8")

        self.assertIn("floatingButtonVisibility", picker)
        self.assertIn("numberOfTouchesRequired = 3", picker)
        self.assertIn("numberOfTapsRequired = 2", picker)
        self.assertIn("UIAccessibilityIsVoiceOverRunning", picker)
        self.assertIn("cancelsTouchesInView = NO", picker)
        self.assertIn("52.0", picker)
        self.assertIn("44.0", picker)

    def test_springboard_uses_the_home_icon_window_instead_of_app_scenes_only(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(encoding="utf-8")

        self.assertIn('NSClassFromString(@"SBIconController")', picker)
        self.assertIn("springBoardHomeWindow", picker)
        self.assertIn("UIApplication.sharedApplication.windows", picker)

    def test_sandboxed_media_import_is_delegated_to_the_springboard_broker(self) -> None:
        configuration_h = (ROOT / "Sources" / "Core" / "VCAMConfiguration.h").read_text(encoding="utf-8")
        configuration_m = (ROOT / "Sources" / "Core" / "VCAMConfiguration.m").read_text(encoding="utf-8")
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(encoding="utf-8")

        self.assertIn("importMediaAtURL", configuration_h)
        self.assertIn("VCAMConfigurationBrokerImportCommand", configuration_m)
        self.assertIn("receiveImportedMediaFromClient", configuration_m)
        self.assertIn("[VCAMConfiguration importMediaAtURL:temporaryURL", picker)

    def test_menu_can_restore_the_real_camera(self) -> None:
        source = (
            ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m"
        ).read_text(encoding="utf-8")

        self.assertIn('@"source": @"camera"', source)
        self.assertIn('@"enabled": @NO', source)

    def test_local_video_supports_upstream_triple_reader_and_single_player_fallback(self) -> None:
        source = (
            ROOT / "Sources" / "Sources" / "VCAMLocalMediaSource.m"
        ).read_text(encoding="utf-8")

        self.assertIn("videoTrack.preferredTransform", source)
        self.assertIn("CACurrentMediaTime()", source)
        self.assertIn("VCAMLocalDecoderModeUpstreamTriple", source)
        self.assertIn("tripleBGRAOutput", source)
        self.assertIn("tripleVideoRangeOutput", source)
        self.assertIn("tripleFullRangeOutput", source)
        self.assertIn("copyNextSampleBuffer", source)
        self.assertIn("AVPlayerItemVideoOutput", source)
        self.assertIn("itemTimeForHostTime", source)
        self.assertIn("copyPixelBufferForItemTime", source)
        self.assertIn("VCAMLocalPlaybackPerformanceSnapshot", source)

        picker = (
            ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m"
        ).read_text(encoding="utf-8")
        self.assertIn("VCAMLocalPlaybackPerformanceSnapshot()", picker)
        self.assertIn('performance[@"sourceFPS"]', picker)

    def test_preview_samples_are_displayed_immediately(self) -> None:
        source = (
            ROOT / "Sources" / "Hooks" / "VCAMPreviewDriver.m"
        ).read_text(encoding="utf-8")

        self.assertIn("kCMSampleAttachmentKey_DisplayImmediately", source)

    def test_floating_entry_opens_a_native_control_panel(self) -> None:
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        picker = (
            ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m"
        ).read_text(encoding="utf-8")
        panel = (
            ROOT / "Sources" / "UI" / "VCAMControlPanelViewController.m"
        ).read_text(encoding="utf-8")

        self.assertIn("VCAMControlPanelViewController.m", makefile)
        self.assertIn("UIPanGestureRecognizer", picker)
        self.assertIn("cornerRadius = 22.0", picker)
        self.assertIn("VCAMControlPanelViewController", picker)
        self.assertIn("UIScrollView", panel)
        self.assertIn("accessibilityLabel", panel)
        self.assertIn("minimumScaleFactor", panel)

    def test_control_panel_connects_every_source_action(self) -> None:
        picker = (
            ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m"
        ).read_text(encoding="utf-8")
        panel = (
            ROOT / "Sources" / "UI" / "VCAMControlPanelViewController.m"
        ).read_text(encoding="utf-8")

        for action in (
            "presentVideoPicker",
            "presentDocumentPicker",
            "promptForOnlineVideo",
            "promptForLiveStream",
            "rotateClockwise",
            "rotateCounterClockwise",
            "toggleMirror",
            "toggleAudioReplacement",
            "cycleContentMode",
            "restoreRealCamera",
            "presentTargetSelector",
        ):
            self.assertIn(action, picker)
        for title in (
            "从相册选择",
            "从文件选择",
            "在线源下载",
            "输入直播流",
            "顺时针旋转",
            "逆时针旋转",
            "选择替换软件和进程",
        ):
            self.assertIn(title, panel)

    def test_direct_rtsp_source_is_wired_to_ffmpeg_videotoolbox(self) -> None:
        configuration_h = (ROOT / "Sources" / "Core" / "VCAMConfiguration.h").read_text(encoding="utf-8")
        configuration_m = (ROOT / "Sources" / "Core" / "VCAMConfiguration.m").read_text(encoding="utf-8")
        pipeline = (ROOT / "Sources" / "Core" / "VCAMFramePipeline.m").read_text(encoding="utf-8")
        source = (ROOT / "Sources" / "Sources" / "VCAMRTSPStreamSource.m").read_text(encoding="utf-8")
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(encoding="utf-8")
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")

        self.assertIn("VCAMSourceKindRTSP", configuration_h)
        self.assertIn("rtspURL", configuration_h)
        self.assertIn('isEqualToString:@"rtsp"', configuration_m)
        self.assertIn("VCAMRTSPStreamSource", pipeline)
        self.assertIn("AV_HWDEVICE_TYPE_VIDEOTOOLBOX", source)
        self.assertIn("AV_PIX_FMT_VIDEOTOOLBOX", source)
        self.assertIn("frame->data[3]", source)
        self.assertIn("VCAMRTSPPerformanceSnapshot", source)
        self.assertIn("copyDirectPreviewSample", source)
        self.assertIn("_latestFrameSequence", source)
        self.assertIn("copyDirectPreviewVideoSample", pipeline)
        self.assertIn("identityPreview", pipeline)
        self.assertIn("VCAMContentModeAspectFill", pipeline)
        preview = (ROOT / "Sources" / "Hooks" / "VCAMPreviewDriver.m").read_text(encoding="utf-8")
        self.assertIn("copyDirectPreviewVideoSample", preview)
        self.assertIn('@"rtspURL"', picker)
        self.assertIn("VCAMRTSPStreamSource.m", makefile)

    def test_rtsp_zero_copy_path_preserves_matching_nv12_frames(self) -> None:
        renderer_h = (ROOT / "Sources" / "Core" / "VCAMFrameRenderer.h").read_text(encoding="utf-8")
        renderer_m = (ROOT / "Sources" / "Core" / "VCAMFrameRenderer.m").read_text(encoding="utf-8")
        rtsp = (ROOT / "Sources" / "Sources" / "VCAMRTSPStreamSource.m").read_text(encoding="utf-8")

        self.assertIn("copySampleFromPixelBuffer", renderer_h)
        self.assertIn("copySampleFromPixelBuffer", renderer_m)
        self.assertIn("sourceWidth == targetWidth", renderer_m)
        self.assertIn("sourcePixelFormat == targetPixelFormat", renderer_m)
        self.assertIn("_lastRenderedFrameSequence", rtsp)

    def test_preview_hot_path_reuses_buffers_and_template(self) -> None:
        renderer = (
            ROOT / "Sources" / "Core" / "VCAMFrameRenderer.m"
        ).read_text(encoding="utf-8")
        pipeline = (
            ROOT / "Sources" / "Core" / "VCAMFramePipeline.m"
        ).read_text(encoding="utf-8")

        self.assertIn("CVPixelBufferPoolCreate", renderer)
        self.assertIn("CVPixelBufferPoolCreatePixelBuffer", renderer)
        self.assertIn("CGColorSpaceCreateDeviceRGB", renderer)
        self.assertIn("_previewTemplateSample", pipeline)
        self.assertIn("CMSampleBufferCreateCopyWithNewTiming", pipeline)

    def test_import_preserves_source_cadence_and_reuses_rendered_frame(self) -> None:
        picker = (
            ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m"
        ).read_text(encoding="utf-8")
        source = (
            ROOT / "Sources" / "Sources" / "VCAMLocalMediaSource.m"
        ).read_text(encoding="utf-8")
        preview = (
            ROOT / "Sources" / "Hooks" / "VCAMPreviewDriver.m"
        ).read_text(encoding="utf-8")

        self.assertIn("nominalFrameRate", picker)
        self.assertIn('@"preferredFramesPerSecond"', picker)
        self.assertIn("_lastRenderedVideoSample", source)
        self.assertIn("CMTimeCompare", source)
        self.assertIn("preferredFramesPerSecond", preview)

    def test_local_video_requests_native_camera_yuv_from_hardware_player(self) -> None:
        source = (
            ROOT / "Sources" / "Sources" / "VCAMLocalMediaSource.m"
        ).read_text(encoding="utf-8")

        self.assertIn("kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange", source)
        self.assertIn("configurePlayerVideoOutputForPixelFormat:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange", source)
        self.assertIn("kCVPixelBufferIOSurfacePropertiesKey", source)
        self.assertIn("automaticallyWaitsToMinimizeStalling", source)

    def test_rotation_action_is_quarter_turn_and_immediately_reloads(self) -> None:
        picker = (
            ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m"
        ).read_text(encoding="utf-8")

        self.assertIn("rotationDegrees", picker)
        self.assertIn("changeRotationBy:90", picker)
        self.assertIn("changeRotationBy:270", picker)
        self.assertIn("[self postConfigurationChanged]", picker)

    def test_preview_template_uses_screen_pixels_instead_of_layer_points(self) -> None:
        preview = (
            ROOT / "Sources" / "Hooks" / "VCAMPreviewDriver.m"
        ).read_text(encoding="utf-8")

        self.assertIn("UIScreen.mainScreen.nativeScale", preview)
        self.assertIn("preview.bounds.size.width * pixelScale", preview)
        self.assertIn("preview.bounds.size.height * pixelScale", preview)

    def test_recommended_single_decoder_stays_on_one_nv12_output(self) -> None:
        source = (
            ROOT / "Sources" / "Sources" / "VCAMLocalMediaSource.m"
        ).read_text(encoding="utf-8")
        method = source.split("- (CVPixelBufferRef)copyCurrentPlayerPixelBufferForTemplate:", 1)[1]
        method = method.split("- (void)emitDiagnosticsForTemplate:", 1)[0]

        self.assertNotIn("configurePlayerVideoOutputForPixelFormat", method)
        self.assertIn("kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange", source)

    def test_gpu_renderer_uses_lanczos_when_downscaling(self) -> None:
        renderer = (
            ROOT / "Sources" / "Core" / "VCAMFrameRenderer.m"
        ).read_text(encoding="utf-8")

        self.assertIn('filterWithName:@"CILanczosScaleTransform"', renderer)

    def test_local_camera_preview_uses_avplayerlayer_hardware_compositor(self) -> None:
        preview = (
            ROOT / "Sources" / "Hooks" / "VCAMPreviewDriver.m"
        ).read_text(encoding="utf-8")
        pipeline_h = (
            ROOT / "Sources" / "Core" / "VCAMFramePipeline.h"
        ).read_text(encoding="utf-8")
        pipeline_m = (
            ROOT / "Sources" / "Core" / "VCAMFramePipeline.m"
        ).read_text(encoding="utf-8")

        self.assertIn("AVPlayerLayer", preview)
        self.assertIn("localPreviewPlayer", pipeline_h)
        self.assertIn("localPreviewPlayer", pipeline_m)
        self.assertIn("tickLocalPreviewDiagnostics", pipeline_h)
        self.assertIn("tickLocalPreviewDiagnostics", pipeline_m)
        self.assertIn("self.localPlayerLayer.player = localPlayer", preview)
        self.assertIn("[pipeline tickLocalPreviewDiagnostics]", preview)
        self.assertIn("self.replacementLayer.hidden = YES", preview)

    def test_new_local_imports_default_to_smooth_single_decoder(self) -> None:
        picker = (
            ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m"
        ).read_text(encoding="utf-8")

        self.assertIn('@"localDecoderMode": @"single"', picker)


if __name__ == "__main__":
    unittest.main()
