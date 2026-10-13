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
            "identifierForVendor": "D1-UUID", "screenBrightness": 0.5,
            "barometerAvailable": True,
            "audio": {"inputs": [{"type": "mic"}], "outputs": [], "inputChannels": 1,
                      "outputVolume": 0.5},
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
            "faceSamples": [{"t": 1.0, "id": 1, "w": 0.2, "h": 0.3, "yaw": 3.0, "roll": 1.0}],
            "visionSamples": [{"t": 1.0, "n": 1, "qual": [0.82, 0.77]}],
            "exposureSamples": [{"t": 1.0, "exposureUs": 8000, "iso": 120},
                                {"t": 2.0, "exposureUs": 9000, "iso": 130}],
            "maxPhotoDims": {"supported": ["4032x3024"], "applied": "4032x3024"},
            "sensorRanges": {"maxExposureMs": 30.0, "minISO": 75, "maxISO": 3072,
                             "videoFieldOfView": 60.0, "activeMaxFPS": 30},
            "trueDepth": {"frontTrueDepthPresent": False},
            "depth": {"frames": 0},
        },
        "altimeter": {"available": True, "samples": [{"t": 1.0, "altitudeM": 0, "pressureKPa": 101.0}]},
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

    def test_extended_sections_present(self):
        rep = _sample_report()
        out = kyc_native_probe_scan.analyze_extended(rep)
        joined = " | ".join(m for _, m in out)
        self.assertIn("IDFV 可得", joined)
        self.assertIn("faceID 跨帧跟踪", joined)
        self.assertIn("mean=", joined)          # Vision 质量统计
        self.assertIn("有变化(AE 活跃", joined)  # 实时曝光有 spread
        self.assertIn("最大拍照档位", joined)
        self.assertIn("TrueDepth 前置不可得", joined)
        # 全量报告端到端必须把扩展判级并入 verdicts。
        report = self._write(rep, "probe.json")
        full = kyc_native_probe_scan.analyze(report, None, videos=[])
        self.assertTrue(any("Vision 人脸质量" in m for _, m in full))

    def test_extended_idfv_missing_is_risk(self):
        rep = _sample_report()
        rep["environment"]["identifierForVendor"] = "none"
        out = kyc_native_probe_scan.analyze_extended(rep)
        self.assertTrue(any(lvl == "RISK" and "identifierForVendor" in m for lvl, m in out))

    def test_extended_exposure_flat_warns(self):
        rep = _sample_report()
        rep["camera"]["exposureSamples"] = [{"t": 1, "exposureUs": 8000, "iso": 120},
                                            {"t": 2, "exposureUs": 8000, "iso": 120}]
        out = kyc_native_probe_scan.analyze_extended(rep)
        self.assertTrue(any("恒定(AE 锁死?)" in m for _, m in out))


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
        info = self._read("Resources/Info.plist")
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

    def test_probe_runner_follows_apple_capture_standard(self):
        # Apple 文档标准的会话配置路径（AVCaptureSession 类文档），防止回退到非标准写法。
        src = self._read("ProbeRunner.m")
        self.assertIn("AVCaptureDeviceDiscoverySession", src)
        self.assertIn("beginConfiguration", src)
        self.assertIn("commitConfiguration", src)
        self.assertIn("videoSupportedFrameRateRanges", src)
        self.assertIn("activeFormat", src)
        self.assertIn("lockForConfiguration", src)

    def test_probe_runner_collects_all_extended_signals(self):
        # "可扩展收集的信息全部入探针"的契约：每项都必须在源码中有对应 API 调用点。
        src = self._read("ProbeRunner.m")
        for api in [
            "CMVideoFormatDescriptionGetDimensions",   # 且必须是没有的旧名修复后的版本
            "faceID", "hasYawAngle", "yawAngle", "hasRollAngle",   # AVMetadataFaceObject 细节
            "VNDetectFaceCaptureQualityRequest", "VNDetectFaceLandmarksRequest",
            "faceCaptureQuality",
            "supportedMaxPhotoDimensions", "maxPhotoDimensions",     # iOS16 高分辨率档位
            "resolvedSettings", "photoProcessingTimeRange",
            "AVCaptureDepthDataOutput", "didOutputDepthData",
            "CMAltimeter", "startRelativeAltitudeUpdatesToQueue",
            "identifierForVendor", "screenBrightness",
            "currentRoute", "minExposureDuration", "maxISO",
            "videoFieldOfView", "videoHDRSupported",
            "AVCaptureDeviceTypeBuiltInTrueDepthCamera",
            # 零帧定位三件套：丢弃计数 / 会话事件 / simple 模式开关
            "didDropSampleBuffer", "AVCaptureSessionRuntimeErrorNotification",
            "AVCaptureSessionInterruptionReasonKey", "onSessionNote",
        ]:
            self.assertIn(api, src)
        main = self._read("main.m")
        self.assertIn("probeSimple", main)   # simple=1 参数贯通（不锁格式的对照组）
        # 回归护栏：theos 16.5 SDK 没有这个名字（两轮 CI 编译错实证），不得回退。
        self.assertNotIn("CMFormatDescriptionGetDimensions(", src)
        mk = self._read("Makefile")
        self.assertIn("Vision", mk)

    def test_mini_runner_textbook_reference_exists(self):
        # 零帧根因隔离用：与 ProbeRunner 完全隔离的最小 AVCapture 参考实现，
        # 入口经 mini=1 参数贯通，结果写设备本地 mini.log（不依赖测试台）。
        main = self._read("main.m")
        self.assertIn("MiniRunner startWithDurationSeconds", main)
        self.assertIn('isEqualToString:@"mini"', main)
        src = self._read("MiniRunner.m")
        for api in [
            "AVCaptureSessionPresetHigh",                    # 不锁格式，用会话默认 preset
            "setSampleBufferDelegate:self queue:dispatch_get_main_queue()",  # 教科书写法：主队列
            "defaultDeviceWithDeviceType",
            "didDropSampleBuffer",
            "/var/mobile/Media/VCAM/mini.log",
        ]:
            self.assertIn(api, src)

    def test_wkwebview_host_page_with_media_permission_delegate(self):
        src = self._read("main.m")
        self.assertIn("requestMediaCapturePermissionForOrigin", src)
        self.assertIn("WKPermissionDecisionGrant", src)
        self.assertIn("kyc-flow.html?auto=1", src)
        mk = self._read("Makefile")
        self.assertIn("WebKit", mk)

    def test_cli_probe_target_exists(self):
        # 非 App 身份的原生采集载体（隔离零帧根因用）：Makefile 必须有 tool 目标，
        # CLI 复用 MiniRunner 同一实现，保证两种载体的观测可对比。
        mk = self._read("Makefile")
        self.assertIn("TOOL_NAME = vcamprobcli", mk)
        self.assertIn("include $(THEOS_MAKE_PATH)/tool.mk", mk)
        src = self._read("cli_main.m")
        self.assertIn("MiniRunner startWithDurationSeconds", src)

    def test_wk_navigation_diagnostics_and_home_short_circuit(self):
        # 真机 WK 页空白必须可归因：导航失败原因写 /var/mobile/Media/VCAM/wk.log；
        # home host 只开主界面（否则每次 uiopen 都触发一次自动采集，干扰 UI 验证）。
        src = self._read("main.m")
        self.assertIn("didFailProvisionalNavigation", src)
        self.assertIn("didFinishNavigation", src)
        self.assertIn("nav fail-provisional", src)
        self.assertIn("/var/mobile/Media/VCAM/wk.log", src)
        self.assertIn('isEqualToString:@"home"', src)


if __name__ == "__main__":
    unittest.main()
