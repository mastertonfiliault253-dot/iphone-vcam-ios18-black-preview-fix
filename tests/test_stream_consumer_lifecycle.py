import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class StreamConsumerLifecycleTests(unittest.TestCase):
    def test_ios18_hls_pauses_after_consumer_lease_and_wakes_on_frame_demand(self) -> None:
        bridge = (
            ROOT / "Sources" / "SpringBoard" / "VCAMSpringBoardMediaBridge.m"
        ).read_text(encoding="utf-8")

        self.assertIn("VCAMDynamicConsumerLeaseNanoseconds", bridge)
        self.assertIn('CFSTR("com.codex.vcam.ios18.frame")', bridge)
        self.assertIn("VCAMSpringBoardMediaConsumerActivity", bridge)
        self.assertIn("suspendHLSForNoConsumer", bridge)
        self.assertIn("resumeHLSForConsumer", bridge)
        self.assertIn("self.player.rate = 0.0f", bridge)
        self.assertIn("self.displayLink.paused = YES", bridge)
        self.assertIn("self.displayLink.paused = NO", bridge)
        self.assertIn("springboard HLS suspended no consumer", bridge)
        self.assertIn("springboard HLS resumed for consumer", bridge)
        self.assertIn("operatingSystemVersion.majorVersion >= 18", bridge)
        self.assertIn("if (self.localVideo)", bridge)
        suspend_method = bridge.split("- (void)suspendHLSForNoConsumer", 2)[2].split(
            "- (void)resumeHLSForConsumer", 1
        )[0]
        self.assertIn("surfaceConsumerActive", suspend_method)
        self.assertIn("VCAMSharedSurfaceWriterHasConsumer(self.surfaceWriter)", suspend_method)
        bridge_start = bridge.split("- (void)start {", 1)[1].split(
            "- (void)stopPlayback", 1
        )[0]
        self.assertIn("if (VCAMSpringBoardRuntimeIsAtLeastIOS18())", bridge_start)
        self.assertGreaterEqual(
            bridge.count('CFSTR("com.codex.vcam.ios18.frame")'), 2
        )

    def test_ios18_rtsp_source_is_always_on_without_consumer_demand(self) -> None:
        # V 轮需求模型（用户指令）：RTSP 源随配置常开，不再随相机消费者
        # 起停。无流时源停留在廉价 404 退避重试，共享环自然过期（点橙、卡
        # 红），不再有 demand lease、挂起/恢复日志或订阅帧 notify。
        main = (ROOT / "Sources" / "Daemon" / "main.m").read_text(
            encoding="utf-8"
        )
        header = (ROOT / "Sources" / "Daemon" / "VCAMFrameProducer.h").read_text(
            encoding="utf-8"
        )
        producer = (ROOT / "Sources" / "Daemon" / "VCAMFrameProducer.m").read_text(
            encoding="utf-8"
        )

        self.assertNotIn("requiresConsumerDemand", header)
        self.assertNotIn("setConsumerDemandActive", header)
        self.assertNotIn("requiresConsumerDemand", main)
        self.assertNotIn("setConsumerDemandActive", main)
        self.assertNotIn("VCAMDynamicConsumerLeaseNanoseconds", main)
        self.assertNotIn('CFSTR("com.codex.vcam.ios18.frame")', main)
        self.assertNotIn("demandIdle", main)
        self.assertNotIn("consumerDemandActive", producer)
        self.assertNotIn("vcamd RTSP source suspended no consumer", producer)
        self.assertNotIn("vcamd RTSP source started for consumer", producer)
        self.assertNotIn("vcamd RTSP source resumed for consumer", producer)
        self.assertIn("VCAMSourceKindRTSP", producer)
        rtsp_case = producer.split("case VCAMSourceKindRTSP:", 1)[1].split(
            "case VCAMSourceKindHLS:", 1
        )[0]
        self.assertIn("self.source = [self newRTSPSource];", rtsp_case)
        self.assertNotIn("consumerDemand", rtsp_case)

    def test_rtsp_no_stream_goes_stale_without_placeholder_frames(self) -> None:
        # V 轮：黑占位帧机制整体移除（用户裁决"不要用断流黑屏"）。断流时
        # 共享环停止推进并由消费端 TTL 判 stale，不再由 daemon 向环写黑帧。
        source = (ROOT / "Sources" / "Sources" / "VCAMRTSPStreamSource.m").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("StallPlaceholder", source)
        self.assertNotIn("stallPlaceholder", source)
        self.assertNotIn("placeholder frames", source)

    def test_hls_resume_rebuilds_live_player_before_generic_stall_timeout(self) -> None:
        bridge = (
            ROOT / "Sources" / "SpringBoard" / "VCAMSpringBoardMediaBridge.m"
        ).read_text(encoding="utf-8")
        resume = bridge.split("- (void)resumeHLSForConsumer", 2)[2].split(
            "- (BOOL)configurationMatches:", 1
        )[0]

        self.assertIn("VCAMHLSResumeFrameTimeoutNanoseconds", bridge)
        self.assertIn("hlsResumeProbeGeneration", bridge)
        self.assertIn("decodedFramesBeforeResume", resume)
        self.assertIn("self.decodedFrames != decodedFramesBeforeResume", resume)
        self.assertIn("springboard HLS resume frame timeout", resume)
        self.assertIn("[self stopPlayback]", resume)
        self.assertIn("[self reload]", resume)

    def test_rtsp_stop_interrupts_blocking_ffmpeg_io_before_restart(self) -> None:
        source = (
            ROOT / "Sources" / "Sources" / "VCAMRTSPStreamSource.m"
        ).read_text(encoding="utf-8")

        self.assertIn("VCAMRTSPInterruptWhenStopped", source)
        self.assertIn("avformat_alloc_context()", source)
        self.assertIn("formatContext->interrupt_callback.callback", source)
        self.assertIn("formatContext->interrupt_callback.opaque", source)

    def test_visible_control_panel_preview_renews_stream_demand(self) -> None:
        preview = (
            ROOT / "Sources" / "UI" / "VCAMSharedFramePreviewView.m"
        ).read_text(encoding="utf-8")

        self.assertIn("VCAMPreviewSignalsConsumerDemand", preview)
        self.assertIn('CFSTR("com.codex.vcam.ios18.frame")', preview)
        self.assertIn("preview.window == nil", preview)
        self.assertIn("preview.hidden", preview)
        self.assertIn("preview.alpha <= 0.01", preview)
        # U-round P1: CADisplayLink retains its target, so the ticker must be
        # torn down when the panel view leaves the window — dealloc never runs
        # while the run loop holds the link, and the control panel creates a
        # new preview view on every open.
        self.assertIn("- (void)didMoveToWindow", preview)
        self.assertIn("self.displayLink = nil;", preview)
        display_link_setup = preview.split("- (void)didMoveToWindow", 1)[1]
        self.assertIn("addToRunLoop", display_link_setup)
        display_tick = preview.split("- (void)displayTick:", 1)[1]
        self.assertIn("VCAMPreviewSignalsConsumerDemand(self)", display_tick)


if __name__ == "__main__":
    unittest.main()
