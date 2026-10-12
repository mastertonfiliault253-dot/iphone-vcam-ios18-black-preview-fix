from pathlib import Path
import json
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import kyc_native_probe_scan  # noqa: E402


def _sample_report():
    return {
        "meta": {"flow": "native_probe", "machine": "iPhone12,5",
                 "systemRelease": "24.x", "appVersion": "0.1.0"},
        "environment": {
            "dyldCount": 300,
            "dyldSuspicious": ["/var/jb/usr/lib/TweakInject/Shadow.dylib"],
            "jbPaths": {"/var/jb": True, "/bin/bash": False},
            "canOpenURL": {"sileo://": True},
            "network": [{"name": "en0", "ipv4": "192.168.2.39"}],
        },
        "camera": {
            "frontCamera": {"hasTorch": False, "position": "front"},
            "sessions": [
                {"label": "low", "capturedW": 640, "capturedH": 480,
                 "frames": 1000, "faceFrames": 900,
                 "attachmentStats": {
                     "ExposureTime": {"n": 1000, "min": 0.004, "max": 0.009, "mean": 0.006, "sd": 0.001},
                     "SensorISO": {"n": 1000, "min": 100, "max": 400, "mean": 200, "sd": 30},
                 }},
            ],
            "torch": {"supported": False},
            "photo": {"saved": True, "width": 4032, "height": 3024, "exifKeyCount": 14, "exif": {}},
        },
        "motion": {"sampleCount": 2000, "gyroStdev": [0.2, 0.1, 0.15], "activity": "moving"},
        "items": [
            {"name": "jb_visible_to_app", "status": "RISK", "detail": "x"},
            {"name": "per_frame_exposure_640x480", "status": "PASS", "detail": "x"},
        ],
    }


class AnalyzerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def _write(self, obj, name):
        p = self.dir / name
        p.write_text(json.dumps(obj), encoding="utf-8")
        return p

    def test_exposure_present_is_pass(self):
        rep = _sample_report()
        verdicts = kyc_native_probe_scan.analyze_sessions(rep["camera"]["sessions"])
        self.assertTrue(any(lvl == "PASS" and "逐帧曝光" in m for lvl, m in verdicts))

    def test_exposure_absent_is_risk(self):
        rep = _sample_report()
        rep["camera"]["sessions"][0]["attachmentStats"] = {}
        verdicts = kyc_native_probe_scan.analyze_sessions(rep["camera"]["sessions"])
        self.assertTrue(any(lvl == "RISK" and "无逐帧曝光" in m for lvl, m in verdicts))

    def test_zero_variance_exposure_is_warn(self):
        rep = _sample_report()
        rep["camera"]["sessions"][0]["attachmentStats"] = {
            "ExposureTime": {"n": 500, "min": 0.006, "max": 0.006, "mean": 0.006, "sd": 0}}
        verdicts = kyc_native_probe_scan.analyze_sessions(rep["camera"]["sessions"])
        self.assertTrue(any(lvl == "WARN" and "恒定" in m for lvl, m in verdicts))

    def test_face_low_coverage_is_risk(self):
        rep = _sample_report()
        rep["camera"]["sessions"][0]["faceFrames"] = 0
        verdicts = kyc_native_probe_scan.analyze_sessions(rep["camera"]["sessions"])
        self.assertTrue(any(lvl == "RISK" and "人脸 metadata" in m for lvl, m in verdicts))

    def test_jb_visible_risk(self):
        rep = _sample_report()
        verdicts = kyc_native_probe_scan.analyze_environment(rep["environment"])
        self.assertTrue(any(lvl == "RISK" and "/var/jb" in m for lvl, m in verdicts))

    def test_motion_static_risk(self):
        rep = _sample_report()
        rep["motion"]["activity"] = "static"
        verdicts = kyc_native_probe_scan.analyze_motion(rep["motion"])
        self.assertEqual(verdicts[0][0], "RISK")

    def test_cross_compare_fills_browser_status(self):
        rep = _sample_report()
        browser = {"items": [{"name": "jb_visible_to_app", "status": "PASS"}]}
        native = [("jb_visible_to_app", "RISK", ""), ("per_frame_exposure_640x480", "PASS", "")]
        rows = kyc_native_probe_scan.cross_compare(native, browser)
        self.assertEqual(rows[0], ("jb_visible_to_app", "RISK", "PASS"))
        self.assertEqual(rows[1][2], "-")

    def test_full_analyze_end_to_end(self):
        report = self._write(_sample_report(), "probe.json")
        browser = self._write({"items": [{"name": "jb_visible_to_app", "status": "PASS"}]}, "browser.json")
        verdicts = kyc_native_probe_scan.analyze(report, browser, videos=[])
        self.assertTrue(any("RISK" == lvl for lvl, _ in verdicts))


class AppContractTests(unittest.TestCase):
    """探针 App 的关键结构契约：缺件即失败（防止源码/打包被误删）。"""

    def _read(self, rel):
        return (ROOT / "probe-app" / rel).read_text(encoding="utf-8")

    def test_makefile_application_target(self):
        mk = self._read("Makefile")
        self.assertIn("APPLICATION_NAME = VCAMDetectProbe", mk)
        self.assertIn("CoreMotion", mk)
        self.assertIn("AVFoundation", mk)

    def test_control_and_infoplist_keys(self):
        self.assertIn("com.codex.vcamdetectprobe", self._read("control"))
        info = self._read("Info.plist")
        self.assertIn("NSCameraUsageDescription", info)
        self.assertIn("NSMotionUsageDescription", info)
        self.assertIn("vcam-probe", info)

    def test_probe_runner_phases(self):
        src = self._read("ProbeRunner.m")
        self.assertIn("kLowPhaseSeconds = 35", src)
        self.assertIn("kHighPhaseSeconds = 8", src)
        self.assertIn("CVBufferGetAttachments", src)
        self.assertIn("AVMetadataFaceObject", src)
        self.assertIn("startDeviceMotionUpdates", src)

    def test_wkwebview_host_page_with_media_permission_delegate(self):
        src = self._read("main.m")
        self.assertIn("requestMediaCapturePermissionForOrigin", src)
        self.assertIn("WKPermissionDecisionGrant", src)
        self.assertIn("kyc-flow.html?auto=1", src)
        mk = self._read("Makefile")
        self.assertIn("WebKit", mk)


if __name__ == "__main__":
    unittest.main()
