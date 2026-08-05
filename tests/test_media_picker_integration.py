import pathlib
import unittest


ROOT = pathlib.Path(__file__).parents[1]


class MediaPickerIntegrationTests(unittest.TestCase):
    def test_unified_picker_accepts_images_and_videos(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(encoding="utf-8")
        self.assertIn("presentMediaPicker", picker)
        self.assertIn("PHPickerFilter.imagesFilter", picker)
        self.assertIn("PHPickerFilter.videosFilter", picker)
        self.assertIn("@[UTTypeImage, UTTypeMovie]", picker)
        self.assertIn("installMediaFromTemporaryURL", picker)
        self.assertIn("loadFileRepresentationForTypeIdentifier", picker)

    def test_import_is_brokered_and_activates_single_decoder(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(encoding="utf-8")
        configuration = (ROOT / "Sources" / "Core" / "VCAMConfiguration.m").read_text(encoding="utf-8")
        self.assertIn("[VCAMConfiguration importMediaAtURL:temporaryURL", picker)
        self.assertIn('@"localDecoderMode": @"single"', picker)
        self.assertIn('@"replaceAudio": @NO', picker)
        self.assertIn("VCAMConfigurationBrokerImportCommand", configuration)
        self.assertIn("receiveImportedMediaFromClient", configuration)

    def test_image_is_static_and_video_uses_timeline_without_preload(self) -> None:
        source = (ROOT / "Sources" / "Sources" / "VCAMLocalMediaSource.m").read_text(encoding="utf-8")
        producer = (ROOT / "Sources" / "Daemon" / "VCAMFrameProducer.m").read_text(encoding="utf-8")
        self.assertIn("CGImageSourceCreateImageAtIndex", source)
        self.assertIn("_stillImage", source)
        self.assertIn("AVPlayerItemVideoOutput", source)
        self.assertIn("itemTimeForHostTime", source)
        self.assertIn("copyPixelBufferForItemTime", source)
        self.assertNotIn("videoFrames", producer)
        self.assertNotIn("NSMutableArray", producer)

    def test_panel_connects_media_live_and_transform_actions(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(encoding="utf-8")
        panel = (ROOT / "Sources" / "UI" / "VCAMControlPanelViewController.m").read_text(encoding="utf-8")
        for action in (
            "presentMediaPicker",
            "presentDocumentPicker",
            "promptForOnlineVideo",
            "promptForLiveStream",
            "rotateClockwise",
            "rotateCounterClockwise",
            "toggleMirror",
            "cycleContentMode",
            "enableVirtualCamera",
            "restoreRealCamera",
        ):
            self.assertIn(action, picker)
        for title in (
            "从相册选择",
            "从文件选择",
            "在线源下载",
            "输入直播流",
            "启用虚拟相机",
            "恢复真实相机",
        ):
            self.assertIn(title, panel)
        self.assertNotIn("选择替换软件和进程", panel)

    def test_obs_bridge_has_latest_frame_and_stale_fail_open(self) -> None:
        obs = (ROOT / "Sources" / "Sources" / "VCAMOBSStreamSource.m").read_text(encoding="utf-8")
        self.assertIn("NSURLSessionWebSocketTask", obs)
        self.assertIn("latestJPEG", obs)
        self.assertIn("latestFrameHostTime", obs)
        self.assertIn("< 3.5", obs)
        self.assertIn("return NULL", obs)

    def test_rtsp_consumes_tcp_continuously_and_converts_latest_clean_frame(self) -> None:
        rtsp = (ROOT / "Sources" / "Sources" / "VCAMRTSPStreamSource.m").read_text(encoding="utf-8")
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        self.assertIn('av_dict_set(&options, "rtsp_transport", "tcp"', rtsp)
        self.assertNotIn('"nobuffer"', rtsp)
        self.assertNotIn('"low_delay"', rtsp)
        self.assertNotIn('"reorder_queue_size"', rtsp)
        self.assertIn("AV_HWDEVICE_TYPE_VIDEOTOOLBOX", rtsp)
        self.assertIn("AV_PIX_FMT_YUV420P", rtsp)
        self.assertIn("AV_PIX_FMT_NV12", rtsp)
        self.assertIn("switching to FFmpeg software decode", rtsp)
        self.assertIn("av_frame_clone", rtsp)
        self.assertIn("_pendingSoftwareFrame", rtsp)
        self.assertIn("conversionQueue", rtsp)
        self.assertIn("sendResult = avcodec_send_packet(codecContext, packet)", rtsp)
        self.assertIn("sendResult != AVERROR(EAGAIN)", rtsp)
        self.assertIn("retry this exact packet", rtsp)
        self.assertNotIn('"discardcorrupt"', rtsp)
        self.assertIn("AV_FRAME_FLAG_CORRUPT", rtsp)
        self.assertIn("AV_FRAME_FLAG_KEY", rtsp)
        self.assertIn("decode_error_flags", rtsp)
        self.assertIn("AV_PKT_FLAG_KEY", rtsp)
        self.assertIn("recoveryPacketLimit = 120", rtsp)
        self.assertIn("recoveryTimeLimit = 5.0", rtsp)
        self.assertIn("rtsp key-frame recovery timed out", rtsp)
        self.assertIn("clean-key recovery exceeded five seconds", rtsp)
        self.assertIn("receive_frame ended", rtsp)
        self.assertIn("maximumDimension = 1280", rtsp)
        software_conversion = rtsp.split(
            "- (CVPixelBufferRef)copyBGRAFromSoftwareFrame:", 1
        )[1].split("- (BOOL)decodeOneSession", 1)[0]
        self.assertIn("kCVPixelBufferCGImageCompatibilityKey", software_conversion)
        self.assertIn("kCVPixelBufferCGBitmapContextCompatibilityKey", software_conversion)
        self.assertNotIn("kCVPixelBufferIOSurfacePropertiesKey", software_conversion)
        self.assertIn("_latestPixelBuffer", rtsp)
        self.assertIn("< 3.5", rtsp)
        self.assertIn("Sources/Sources/VCAMRTSPStreamSource.m", makefile)

    def test_floating_dot_is_springboard_owned_and_accessible(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(encoding="utf-8")
        panel = (ROOT / "Sources" / "UI" / "VCAMControlPanelViewController.m").read_text(encoding="utf-8")
        self.assertIn('NSClassFromString(@"SBIconController")', picker)
        self.assertIn("UIPanGestureRecognizer", picker)
        self.assertIn("numberOfTouchesRequired = 3", picker)
        self.assertIn("UIAccessibilityIsVoiceOverRunning", picker)
        self.assertIn("accessibilityLabel", panel)

    def test_preview_displays_worker_oriented_pixels_without_a_second_transform(self) -> None:
        preview = (ROOT / "Sources" / "UI" / "VCAMSharedFramePreviewView.m").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("CGAffineTransformMakeScale", preview)
        self.assertNotIn("affineTransform", preview)
        self.assertNotIn("rotationDegrees", preview)

    def test_ui_only_notifications_do_not_reconnect_an_unchanged_rtsp_source(self) -> None:
        producer = (ROOT / "Sources" / "Daemon" / "VCAMFrameProducer.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("VCAMConfigurationsProduceSameFrames", producer)
        self.assertIn("sourceHealthy", producer)
        self.assertIn("reload skipped unchanged media configuration", producer)
        comparison = producer.split("VCAMConfigurationsProduceSameFrames", 1)[1].split(
            "@interface VCAMFrameProducer", 1
        )[0]
        for field in (
            "enabled",
            "loopMedia",
            "mirrorHorizontally",
            "rotationDegrees",
            "sourceKind",
            "contentMode",
            "preferredFramesPerSecond",
            "mediaPath",
            "obsWebSocketURL",
            "rtspURL",
        ):
            self.assertIn(field, comparison)

    def test_enable_and_restore_drive_shared_frame_active_state(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(encoding="utf-8")
        header = (ROOT / "Sources" / "UI" / "VCAMControlPanelViewController.h").read_text(
            encoding="utf-8"
        )
        panel = (ROOT / "Sources" / "UI" / "VCAMControlPanelViewController.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("controlPanelDidRequestEnableVirtualCamera", header)
        self.assertIn("controlPanelDidRequestEnableVirtualCamera", panel)
        self.assertIn("controlPanelDidRequestEnableVirtualCamera", picker)
        self.assertIn('@"enabled": @YES', picker)
        self.assertIn('@"source": source', picker)
        self.assertNotIn('@"injectionMediaServerEnabled": @YES', picker)
        configuration = (ROOT / "Sources" / "Core" / "VCAMConfiguration.m").read_text(
            encoding="utf-8"
        )
        allowed_keys = configuration.split("allowedPreferenceKeys", 1)[1].split(
            "+ (BOOL)validateChanges", 1
        )[0]
        self.assertIn('@"enabled"', allowed_keys)
        self.assertIn('@"source"', allowed_keys)
        for configured_source_check in ("BOOL hasRTSP", "BOOL hasOBS", "BOOL hasLocalMedia"):
            self.assertIn(configured_source_check, picker)
        self.assertIn('updatePreferences:@{@"enabled": @NO}', picker)
        self.assertNotIn('@"source": @"camera", @"enabled": @NO', picker)
        self.assertIn('CFSTR("com.codex.vcam/preferences.changed")', picker)
        self.assertIn("VCAMSharedFrameSetRequestedActive", configuration)
        self.assertIn("if (!sharedStateWritten) written = NO", configuration)


if __name__ == "__main__":
    unittest.main()
