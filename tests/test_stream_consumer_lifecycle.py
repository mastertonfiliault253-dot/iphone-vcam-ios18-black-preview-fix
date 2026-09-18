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

    def test_ios18_rtsp_stops_decoder_after_consumer_lease_and_restarts_on_demand(self) -> None:
        main = (ROOT / "Sources" / "Daemon" / "main.m").read_text(
            encoding="utf-8"
        )
        header = (ROOT / "Sources" / "Daemon" / "VCAMFrameProducer.h").read_text(
            encoding="utf-8"
        )
        producer = (ROOT / "Sources" / "Daemon" / "VCAMFrameProducer.m").read_text(
            encoding="utf-8"
        )

        self.assertIn("VCAMDynamicConsumerLeaseNanoseconds", main)
        self.assertIn('CFSTR("com.codex.vcam.ios18.frame")', main)
        self.assertIn("VCAMMediaConsumerActivity", main)
        self.assertIn("setConsumerDemandActive:", header)
        self.assertIn("setConsumerDemandActive:", producer)
        self.assertIn("VCAMSourceKindRTSP", producer)
        self.assertIn("vcamd RTSP source suspended no consumer", producer)
        self.assertIn("vcamd RTSP source resumed for consumer", producer)
        self.assertIn("operatingSystemVersion.majorVersion >= 18", main)
        self.assertIn("VCAMScheduleTimer", main)
        publish_tick = main.split("static void VCAMPublishTick(void)", 1)[1].split(
            "static void VCAMScheduleTimer(void)", 1
        )[0]
        self.assertIn("transportConsumerActive", publish_tick)
        self.assertIn("VCAMSharedSurfaceWriterHasConsumer(VCAMSurfaceWriter)", publish_tick)
        daemon_start = main.split("int main(int argc, char *argv[])", 1)[1]
        self.assertIn("if (VCAMDaemonRuntimeIsAtLeastIOS18())", daemon_start)

    def test_consumer_demand_setter_does_not_recursively_call_itself(self) -> None:
        producer = (ROOT / "Sources" / "Daemon" / "VCAMFrameProducer.m").read_text(
            encoding="utf-8"
        )
        setter = producer.split(
            "- (void)setConsumerDemandActive:(BOOL)active {", 1
        )[1].split("\n}\n", 1)[0]

        self.assertNotIn("self.consumerDemandActive = active", setter)
        self.assertIn("_consumerDemandActive = active", setter)

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
        display_tick = preview.split("- (void)displayTick:", 1)[1]
        self.assertIn("VCAMPreviewSignalsConsumerDemand(self)", display_tick)


if __name__ == "__main__":
    unittest.main()
