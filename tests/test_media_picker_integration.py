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


if __name__ == "__main__":
    unittest.main()
