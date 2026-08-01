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

    def test_picker_storage_uses_the_camera_application_support_directory(self) -> None:
        configuration = (
            ROOT / "Sources" / "Core" / "VCAMConfiguration.m"
        ).read_text(encoding="utf-8")

        self.assertIn("NSApplicationSupportDirectory", configuration)
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


if __name__ == "__main__":
    unittest.main()
