import pathlib
import subprocess
import sys
import unittest


ROOT = pathlib.Path(__file__).parents[1]
SCRIPT = ROOT / "scripts" / "analyze-camera-routing.py"


def run_analyzer(log: str, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        input=log,
        text=True,
        capture_output=True,
        check=False,
    )


class CameraRoutingAnalyzerTests(unittest.TestCase):
    def test_reports_ios16_mode_switch_failure_as_red(self) -> None:
        result = run_analyzer(
            "shared-frame reader initialized\n"
            "output signature supported=0 allowed=1 route=camera-source-video\n"
            "suppressing real sample after replacement failure\n"
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("VCAM_CAMERA_ROUTING=RED", result.stdout)
        self.assertIn("unsupported-routed-format", result.stdout)

    def test_requires_photo_and_recording_routes_after_acceptance_actions(self) -> None:
        result = run_analyzer(
            "shared-frame reader initialized\nroute=camera-preview\n",
            "--require-recording",
            "--require-photo",
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("recording-route-missing", result.stdout)
        self.assertIn("photo-route-missing", result.stdout)

    def test_accepts_clean_photo_and_recording_session(self) -> None:
        result = run_analyzer(
            "old supported=0 allowed=1 route=camera-source-video\n"
            "shared-frame reader initialized\n"
            "route=camera-source-video\nroute=video-recording\nroute=still-photo\n",
            "--require-recording",
            "--require-photo",
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("VCAM_CAMERA_ROUTING=GREEN", result.stdout)
        self.assertIn("failures=none", result.stdout)

    def test_reports_recording_route_churn_during_preview_as_red(self) -> None:
        result = run_analyzer(
            "production identity pid=24062 start=1 ctor=1\n"
            "production replacement-count=2 route=4\n"
            "production replacement-count=13 route=5\n"
            "production replacement-count=16 route=4\n"
            "production replacement-count=19 route=5\n",
            "--preview-only-listener",
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("VCAM_CAMERA_PREVIEW_ROUTING=RED", result.stdout)
        self.assertIn("recording-route-active-during-preview", result.stdout)
        self.assertIn("mixed-preview-recording-presentations", result.stdout)
        self.assertIn("route_counts=4:2,5:2", result.stdout)

    def test_accepts_preview_only_listener_without_recording_route(self) -> None:
        result = run_analyzer(
            "production identity pid=30000 start=2 ctor=1\n"
            "production replacement-count=1 route=4\n"
            "production replacement-count=2 route=4\n",
            "--preview-only-listener",
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("VCAM_CAMERA_PREVIEW_ROUTING=GREEN", result.stdout)
        self.assertIn("failures=none", result.stdout)
        self.assertIn("route_counts=4:2", result.stdout)

    def test_preview_listener_selects_requested_pid_from_multiple_sessions(
        self,
    ) -> None:
        result = run_analyzer(
            "production identity pid=24062 start=1 ctor=1\n"
            "production replacement-count=1 route=4\n"
            "production replacement-count=2 route=5\n"
            "production identity pid=24147 start=2 ctor=1\n"
            "production replacement-count=1 route=0\n",
            "--preview-only-listener",
            "--production-pid",
            "24062",
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("production_pid=24062", result.stdout)
        self.assertIn("route_counts=4:1,5:1", result.stdout)

    def test_reports_repeated_static_preview_render_duty_as_red(self) -> None:
        result = run_analyzer(
            "[24327][start=1][15:51:48.000] emitSampleBuffer video count=1 size=1242x2688 format=420f/34323066 route=camera-preview\n"
            "[24327][start=1][15:51:48.050] rendered shared frame sequence=77 format=34323066 elapsedMs=40.00\n"
            "[24327][start=1][15:51:48.100] rendered shared frame sequence=77 format=34323066 elapsedMs=40.00\n"
            "[24327][start=1][15:51:54.000] replacement render window count=120 p50Ms=40.00 p95Ms=42.00 maxMs=45.00\n"
            "[24327][start=1][15:51:58.000] emitSampleBuffer video count=201 size=1242x2688 format=420f/34323066 route=camera-preview\n",
            "--preview-performance",
            "--expect-static-source",
            "--production-pid",
            "24327",
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("VCAM_CAMERA_PREVIEW_PERFORMANCE=RED", result.stdout)
        self.assertIn("excessive-preview-processing-duty", result.stdout)
        self.assertIn("static-preview-cache-missing", result.stdout)
        self.assertIn("estimated_processing_duty=0.800", result.stdout)
        self.assertIn("repeated_static_sequence=1", result.stdout)

    def test_accepts_cached_static_preview_with_low_processing_duty(self) -> None:
        result = run_analyzer(
            "[30000][start=2][10:00:00.000] emitSampleBuffer video count=1 size=1242x2688 format=420f/34323066 route=camera-preview\n"
            "[30000][start=2][10:00:00.050] rendered shared frame sequence=77 format=34323066 elapsedMs=40.00\n"
            "[30000][start=2][10:00:06.000] preview replacement performance window count=120 cacheHits=119 renders=1 p50Ms=2.00 p95Ms=2.50 maxMs=41.00\n"
            "[30000][start=2][10:00:10.000] emitSampleBuffer video count=201 size=1242x2688 format=420f/34323066 route=camera-preview\n",
            "--preview-performance",
            "--expect-static-source",
            "--production-pid",
            "30000",
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("VCAM_CAMERA_PREVIEW_PERFORMANCE=GREEN", result.stdout)
        self.assertIn("failures=none", result.stdout)
        self.assertIn("cache_ratio=0.992", result.stdout)
        self.assertIn("estimated_processing_duty=0.040", result.stdout)
        self.assertIn("repeated_static_sequence=1", result.stdout)

    def test_preview_performance_uses_latest_active_burst(self) -> None:
        result = run_analyzer(
            "[24327][start=1][15:28:20.000] emitSampleBuffer video count=1 size=1242x2688 format=420f/34323066 route=camera-preview\n"
            "[24327][start=1][15:28:30.000] emitSampleBuffer video count=201 size=1242x2688 format=420f/34323066 route=camera-preview\n"
            "[24327][start=1][15:51:48.000] emitSampleBuffer video count=202 size=1242x2688 format=420f/34323066 route=camera-preview\n"
            "[24327][start=1][15:51:58.000] emitSampleBuffer video count=402 size=1242x2688 format=420f/34323066 route=camera-preview\n"
            "[24327][start=1][15:52:00.000] replacement render window count=120 p50Ms=40.00 p95Ms=42.00 maxMs=45.00\n",
            "--preview-performance",
            "--production-pid",
            "24327",
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("preview_fps=20.00", result.stdout)
        self.assertIn("estimated_processing_duty=0.800", result.stdout)
        self.assertIn("excessive-preview-processing-duty", result.stdout)

    def test_reports_duplicate_dynamic_stream_rendering_as_red(self) -> None:
        result = run_analyzer(
            "[24940][start=3][18:22:49.980] output signature output=0x1 outputClass=BWNodeOutput outputName=(none) node=0x2 nodeClass=BWBackgroundBlurNode nodeName=BWBackgroundBlurNode size=1920x1080 pixel=420v/34323076 subtype=420v/34323076 planes=2 data=0 supported=1 allowed=1 route=universal-video\n"
            "[24940][start=3][18:22:50.032] output signature output=0x3 outputClass=BWNodeOutput outputName=(none) node=0x4 nodeClass=BWPixelTransferNode nodeName=Video Data Converter/Zoomer size=1920x1080 pixel=420f/34323066 subtype=420f/34323066 planes=2 data=0 supported=1 allowed=1 route=video-converter\n"
            "[24940][start=3][18:22:54.000] replacement render window count=120 p50Ms=30.00 p95Ms=35.00 maxMs=40.00\n"
            "[24940][start=3][18:22:56.000] replacement render window count=120 p50Ms=30.00 p95Ms=35.00 maxMs=40.00\n",
            "--stream-performance",
            "--production-pid",
            "24940",
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("VCAM_STREAM_PERFORMANCE=RED", result.stdout)
        self.assertIn("excessive-stream-render-rate", result.stdout)
        self.assertIn("excessive-stream-processing-duty", result.stdout)
        self.assertIn("remote-propagation-fast-path-missing", result.stdout)
        self.assertIn("known-preterminal-rendered", result.stdout)
        self.assertIn("max_render_rate_fps=60.00", result.stdout)
        self.assertIn("max_estimated_processing_duty=1.800", result.stdout)

    def test_accepts_one_terminal_dynamic_stream_render(self) -> None:
        result = run_analyzer(
            "[30001][start=4][10:00:00.000] output signature output=0x1 outputClass=BWNodeOutput outputName=(none) node=0x2 nodeClass=BWPixelTransferNode nodeName=Video Data Converter/Zoomer size=1920x1080 pixel=420f/34323066 subtype=420f/34323066 planes=2 data=0 supported=1 allowed=1 route=video-converter\n"
            "[30001][start=4][10:00:04.000] replacement render window count=120 p50Ms=20.00 p95Ms=25.00 maxMs=30.00\n"
            "[30001][start=4][10:00:08.000] replacement render window count=120 p50Ms=20.00 p95Ms=25.00 maxMs=30.00\n"
            "[30001][start=4][10:00:08.010] passing propagated remote queue virtual frame count=120\n",
            "--stream-performance",
            "--production-pid",
            "30001",
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("VCAM_STREAM_PERFORMANCE=GREEN", result.stdout)
        self.assertIn("failures=none", result.stdout)
        self.assertIn("max_render_rate_fps=30.00", result.stdout)
        self.assertIn("max_estimated_processing_duty=0.600", result.stdout)


if __name__ == "__main__":
    unittest.main()
