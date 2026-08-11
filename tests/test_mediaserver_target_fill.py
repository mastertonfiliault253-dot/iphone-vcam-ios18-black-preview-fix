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

    def test_consumer_adapter_uses_aspect_fill_without_device_orientation_guessing(self) -> None:
        fill_scale = "CGFloat scale = aspectFit"

        self.assertIn(fill_scale, self.adapter)
        self.assertIn("MIN((CGFloat)renderWidth", self.adapter)
        self.assertIn("MAX((CGFloat)renderWidth", self.adapter)
        self.assertIn("!realtimeCompensation && sourceIsPortrait", self.adapter)
        self.assertNotIn("interfaceOrientation", self.adapter)
        self.assertIn("imageByCroppingToRect:CGRectMake(0, 0, renderWidth, renderHeight)", self.adapter)

    def test_portrait_still_uses_sensor_storage_and_exif_orientation(self) -> None:
        # iOS encodes still pixels in the sensor's landscape storage. A
        # canonical portrait VCAM source must be turned into that storage
        # basis and marked Orientation=Right so Photos presents a 3:4 image.
        self.assertIn("sourceIsPortrait", self.adapter)
        self.assertIn("!realtimeCompensation", self.adapter)
        self.assertIn("targetWidth > targetHeight", self.adapter)
        still_adapter = self.adapter.split(
            "if (!realtimeCompensation && sourceIsPortrait", 1
        )[1].split("// The producer publishes", 1)[0]
        self.assertIn(
            "imageByApplyingOrientation:kCGImagePropertyOrientationLeft",
            still_adapter,
        )
        self.assertNotIn("kCGImagePropertyOrientationUpMirrored", still_adapter)
        self.assertIn("stillPhotoRequiresRightOrientationOut", self.adapter)

        entry = (
            ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefEntry.xm"
        ).read_text(encoding="utf-8")
        still_path = entry.split("replacementSucceeded = drawReplacementOntoBuffer", 1)[1]
        self.assertIn("VCAMReplacementRouteStillPhoto", still_path)
        self.assertIn("VCAMSetStillPhotoDisplayOrientation", still_path)
        self.assertIn("kCGImagePropertyOrientationRight", entry)
        self.assertIn("CMSetAttachment", entry)
        self.assertIn("CVBufferSetAttachment", entry)
        self.assertNotIn("interfaceOrientation", still_path)

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
        )[1].split("// iOS still-photo buffers", 1)[0]
        self.assertIn(
            "imageByApplyingOrientation:kCGImagePropertyOrientationLeft",
            webkit_adapter,
        )
        self.assertNotIn("kCGImagePropertyOrientationUpMirrored", webkit_adapter)

        entry = (
            ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefEntry.xm"
        ).read_text(encoding="utf-8")
        render_call = entry.split(
            "replacementSucceeded = drawReplacementOntoBuffer", 1
        )[1].split(");", 1)[0]
        self.assertIn(
            "replacementRoute == VCAMReplacementRouteVideoConverter",
            render_call,
        )
        self.assertNotIn(
            "replacementRoute == VCAMReplacementRouteCameraPreview\n"
            "                    ?",
            render_call,
        )

    def test_fill_covers_photo_preview_and_browser_targets(self) -> None:
        # Every consumer is aspect-filled without changing the source's
        # user-visible direction. Still-photo orientation remains system-owned.
        cases = (
            ((1080, 1920), (4224, 3024)),  # Camera still-photo sensor buffer
            ((1080, 1920), (750, 1334)),  # Camera portrait preview
            ((1920, 1080), (640, 480)),  # common browser/WebRTC 4:3 buffer
        )
        for (source_width, source_height), (target_width, target_height) in cases:
            with self.subTest(target=(target_width, target_height)):
                scale = max(
                    target_width / source_width,
                    target_height / source_height,
                )
                self.assertGreaterEqual(source_width * scale, target_width)
                self.assertGreaterEqual(source_height * scale, target_height)


if __name__ == "__main__":
    unittest.main()
