import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest


class WriteConfigTests(unittest.TestCase):
    def test_hls_configuration_is_valid_plist(self) -> None:
        script = pathlib.Path(__file__).parents[1] / "scripts" / "write-config.py"
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "vcam.plist"
            subprocess.run(
                [
                    sys.executable,
                    str(script),
                    "--output",
                    str(output),
                    "--source",
                    "hls",
                    "--hls-url",
                    "http://192.168.2.10:8888/live/index.m3u8",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            values = plistlib.loads(output.read_bytes())
            self.assertTrue(values["enabled"])
            self.assertEqual(values["source"], "hls")
            self.assertEqual(
                values["hlsURL"], "http://192.168.2.10:8888/live/index.m3u8"
            )

    def test_direct_rtsp_configuration_is_valid_plist(self) -> None:
        script = pathlib.Path(__file__).parents[1] / "scripts" / "write-config.py"
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "vcam.plist"
            subprocess.run(
                [
                    sys.executable,
                    str(script),
                    "--output",
                    str(output),
                    "--source",
                    "rtsp",
                    "--rtsp-url",
                    "rtsp://192.168.2.10:8554/live",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            values = plistlib.loads(output.read_bytes())
            self.assertEqual(values["source"], "rtsp")
            self.assertEqual(values["rtspURL"], "rtsp://192.168.2.10:8554/live")

    def test_obs_configuration_is_valid_plist(self) -> None:
        script = pathlib.Path(__file__).parents[1] / "scripts" / "write-config.py"
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "vcam.plist"
            subprocess.run(
                [
                    sys.executable,
                    str(script),
                    "--output",
                    str(output),
                    "--source",
                    "obs",
                    "--obs-url",
                    "ws://192.168.1.20:8765",
                    "--mirror",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            values = plistlib.loads(output.read_bytes())
            self.assertTrue(values["enabled"])
            self.assertEqual(values["source"], "obs")
            self.assertTrue(values["mirrorHorizontally"])

    def test_metadata_json_is_merged_into_configuration(self) -> None:
        script = pathlib.Path(__file__).parents[1] / "scripts" / "write-config.py"
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "vcam.plist"
            metadata = pathlib.Path(directory) / "metadata.json"
            metadata.write_text('{"{TIFF}": {"Make": "VCAM"}}', encoding="utf-8")
            subprocess.run(
                [
                    sys.executable,
                    str(script),
                    "--output",
                    str(output),
                    "--source",
                    "local",
                    "--media-path",
                    "/var/mobile/Media/test.mov",
                    "--metadata-json",
                    str(metadata),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            values = plistlib.loads(output.read_bytes())
            self.assertEqual(values["photoMetadata"]["{TIFF}"]["Make"], "VCAM")
            self.assertEqual(values["localDecoderMode"], "single")

    def test_local_decoder_can_use_single_player_fallback(self) -> None:
        script = pathlib.Path(__file__).parents[1] / "scripts" / "write-config.py"
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "vcam.plist"
            subprocess.run(
                [
                    sys.executable,
                    str(script),
                    "--output",
                    str(output),
                    "--source",
                    "local",
                    "--media-path",
                    "/var/mobile/Media/test.mov",
                    "--local-decoder",
                    "single",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            values = plistlib.loads(output.read_bytes())
            self.assertEqual(values["localDecoderMode"], "single")


if __name__ == "__main__":
    unittest.main()
