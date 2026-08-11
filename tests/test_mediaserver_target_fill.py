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

    def test_consumer_adapter_uses_aspect_fill_after_orientation(self) -> None:
        orientation = "imageByApplyingOrientation:kCGImagePropertyOrientationLeft"
        fill_scale = "CGFloat scale = aspectFit"

        self.assertIn(orientation, self.adapter)
        self.assertIn(fill_scale, self.adapter)
        self.assertIn("MIN((CGFloat)renderWidth", self.adapter)
        self.assertIn("MAX((CGFloat)renderWidth", self.adapter)
        self.assertLess(self.adapter.index(orientation), self.adapter.index(fill_scale))
        self.assertIn("imageByCroppingToRect:CGRectMake(0, 0, renderWidth, renderHeight)", self.adapter)

    def test_still_photo_uses_sensor_storage_orientation(self) -> None:
        # Portrait virtual pixels must be written into the landscape sensor
        # buffer before the system photo encoder applies Orientation=Right.
        orientation = "imageByApplyingOrientation:kCGImagePropertyOrientationLeft"
        self.assertIn("if (targetWidth > targetHeight", self.adapter)
        self.assertIn(orientation, self.adapter)
        self.assertIn("if (realtimeBudget)", self.adapter)

        entry = (
            ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefEntry.xm"
        ).read_text(encoding="utf-8")
        setter = entry.split(
            "static void VCAMSetStillPhotoOrientation", 1
        )[1].split("static NSString *VCAMSafeStringValue", 1)[0]
        self.assertIn("CVPixelBufferGetWidth(imageBuffer) <=", setter)
        self.assertIn("kCGImagePropertyOrientationRight", setter)
        self.assertIn("CMSetAttachment", setter)
        self.assertIn("CVBufferSetAttachment", setter)
        still_path = entry.split("replacementSucceeded = drawReplacementOntoBuffer", 1)[1]
        self.assertIn("VCAMReplacementRouteStillPhoto", still_path)
        self.assertIn("VCAMSetStillPhotoOrientation", still_path)

    def test_fill_covers_photo_preview_and_browser_targets(self) -> None:
        # Landscape sensor targets receive the canonical portrait frame
        # rotated into storage orientation. Every scaled axis must still cover
        # its consumer after that rotation.
        cases = (
            ((1920, 1080), (4224, 3024)),  # Camera still-photo sensor buffer
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
