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
        fill_scale = "CGFloat scale = MAX("

        self.assertIn(orientation, self.adapter)
        self.assertIn(fill_scale, self.adapter)
        self.assertNotIn("CGFloat scale = MIN(", self.adapter)
        self.assertLess(self.adapter.index(orientation), self.adapter.index(fill_scale))
        self.assertIn("imageByCroppingToRect:CGRectMake(0, 0, renderWidth, renderHeight)", self.adapter)

    def test_fill_covers_photo_preview_and_browser_targets(self) -> None:
        # Landscape targets receive the canonical portrait frame rotated to
        # 1280x720 before scaling. Every scaled axis must cover its consumer;
        # otherwise the black safety background becomes visible as bars.
        cases = (
            ((1280, 720), (4224, 3024)),  # Camera still-photo sensor buffer
            ((720, 1280), (750, 1334)),  # Camera portrait preview
            ((1280, 720), (640, 480)),  # common browser/WebRTC 4:3 buffer
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
