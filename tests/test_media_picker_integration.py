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
            "restoreRealCamera",
        ):
            self.assertIn(action, picker)
        for title in ("从相册选择", "从文件选择", "在线源下载", "输入直播流", "恢复真实相机"):
            self.assertIn(title, panel)
        self.assertNotIn("选择替换软件和进程", panel)

    def test_obs_bridge_has_latest_frame_and_stale_fail_open(self) -> None:
        obs = (ROOT / "Sources" / "Sources" / "VCAMOBSStreamSource.m").read_text(encoding="utf-8")
        self.assertIn("NSURLSessionWebSocketTask", obs)
        self.assertIn("latestJPEG", obs)
        self.assertIn("latestFrameHostTime", obs)
        self.assertIn("< 3.5", obs)
        self.assertIn("return NULL", obs)

    def test_rtsp_is_low_delay_tcp_videotoolbox_in_worker(self) -> None:
        rtsp = (ROOT / "Sources" / "Sources" / "VCAMRTSPStreamSource.m").read_text(encoding="utf-8")
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        self.assertIn('av_dict_set(&options, "rtsp_transport", "tcp"', rtsp)
        self.assertIn("AV_CODEC_FLAG_LOW_DELAY", rtsp)
        self.assertIn("AV_HWDEVICE_TYPE_VIDEOTOOLBOX", rtsp)
        self.assertIn("AV_PIX_FMT_YUV420P", rtsp)
        self.assertIn("AV_PIX_FMT_NV12", rtsp)
        self.assertIn("switching to FFmpeg software decode", rtsp)
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

    def test_restore_posts_reload_notification(self) -> None:
        picker = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(encoding="utf-8")
        self.assertIn('@"source": @"camera", @"enabled": @NO', picker)
        self.assertIn('CFSTR("com.codex.vcam/preferences.changed")', picker)


if __name__ == "__main__":
    unittest.main()
