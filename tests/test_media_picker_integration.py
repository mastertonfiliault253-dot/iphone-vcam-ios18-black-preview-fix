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
        self.assertIn("[VCAMConfiguration mediaDirectoryPath]", source)
        self.assertIn("[VCAMConfiguration configurationPath]", source)
        self.assertNotIn('@"/var/mobile/Media/VCAM"', source)
        self.assertIn('@"source": @"local"', source)
        self.assertIn('@"enabled": @YES', source)
        self.assertIn('CFSTR("com.codex.vcam/preferences.changed")', source)

    def test_picker_storage_probes_camera_writable_directories(self) -> None:
        configuration = (
            ROOT / "Sources" / "Core" / "VCAMConfiguration.m"
        ).read_text(encoding="utf-8")

        self.assertIn("NSApplicationSupportDirectory", configuration)
        self.assertIn("NSCachesDirectory", configuration)
        self.assertIn("NSTemporaryDirectory()", configuration)
        self.assertIn('@".write-probe"', configuration)
        self.assertIn("+ (NSString *)mediaDirectoryPath", configuration)
        self.assertNotIn(
            'return @"/var/mobile/Library/Preferences/com.codex.vcam.plist"',
            configuration,
        )

    def test_menu_can_restore_the_real_camera(self) -> None:
        source = (
            ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m"
        ).read_text(encoding="utf-8")

        self.assertIn('@"source": @"camera"', source)
        self.assertIn('@"enabled": @NO', source)

    def test_local_video_honors_track_orientation_and_media_clock(self) -> None:
        source = (
            ROOT / "Sources" / "Sources" / "VCAMLocalMediaSource.m"
        ).read_text(encoding="utf-8")

        self.assertIn("videoTrack.preferredTransform", source)
        self.assertIn("CACurrentMediaTime()", source)
        self.assertIn("CMSampleBufferGetPresentationTimeStamp", source)
        self.assertIn("_nextVideoSample", source)

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
        self.assertIn("cornerRadius = 24.0", picker)
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

    def test_rotation_action_is_quarter_turn_and_immediately_reloads(self) -> None:
        picker = (
            ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m"
        ).read_text(encoding="utf-8")

        self.assertIn("rotationDegrees", picker)
        self.assertIn("changeRotationBy:90", picker)
        self.assertIn("changeRotationBy:270", picker)
        self.assertIn("[self postConfigurationChanged]", picker)


if __name__ == "__main__":
    unittest.main()
