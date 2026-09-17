import importlib.util
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).parents[1]
SCRIPT = ROOT / "scripts" / "analyze-camera-qr-routing.py"
SPEC = importlib.util.spec_from_file_location("camera_qr_routing", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def signature(output: str, node_class: str, node: str, route: str) -> str:
    return (
        "output signature output=0x1 outputClass=BWNodeOutput "
        f"outputName={output} node=0x2 nodeClass={node_class} "
        f"nodeName={node} size=1242x2688 pixel=420f route={route}"
    )


class CameraQrRoutingAnalyzerTests(unittest.TestCase):
    def test_rejects_preview_only_replacement(self) -> None:
        text = "\n".join(
            (
                signature("(none)", "BWPixelTransferNode", "Preview Scaler", "camera-preview"),
                signature("MetadataObject", "BWFanOutNode", "Preview Splitter", "none"),
                signature("(none)", "BWMetadataDetectorGatingNode", "BWMetadataDetectorGatingNode", "none"),
            )
        )
        failures = MODULE.analyze(text)
        self.assertEqual(len(failures), 1)
        self.assertIn("does not receive VCAM pixels", failures[0])

    def test_accepts_scoped_metadata_input_replacement(self) -> None:
        text = "\n".join(
            (
                signature("(none)", "BWPixelTransferNode", "Preview Scaler", "camera-preview"),
                signature("MetadataObject", "BWFanOutNode", "Preview Splitter", "qr-analysis"),
                signature("(none)", "BWMetadataDetectorGatingNode", "BWMetadataDetectorGatingNode", "none"),
            )
        )
        self.assertEqual(MODULE.analyze(text), [])

    def test_rejects_replacing_post_detection_output(self) -> None:
        text = "\n".join(
            (
                signature("(none)", "BWPixelTransferNode", "Preview Scaler", "camera-preview"),
                signature("MetadataObject", "BWFanOutNode", "Preview Splitter", "qr-analysis"),
                signature("(none)", "BWMetadataDetectorGatingNode", "BWMetadataDetectorGatingNode", "universal-video"),
            )
        )
        failures = MODULE.analyze(text)
        self.assertEqual(failures, ["post-detection gating output must remain untouched"])


if __name__ == "__main__":
    unittest.main()
