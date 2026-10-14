"""路线 2（屏幕色跟随/三色调光）契约测试。

链路：SpringBoard 采屏器 → notifyd `screen-tint.state` → cameracaptured 合成链
CIColorMatrix 染色；用户入口=面板"三色调光"开关 → `screenTintEnabled` 偏好。
任一环节被重构掉都应在这里失败（契约测试钉点需随重构同步）。
"""

import pathlib
import unittest

ROOT = pathlib.Path(__file__).parents[1]


class ScreenTintChainTests(unittest.TestCase):
    def test_configuration_allows_screen_tint_switch(self) -> None:
        source = (ROOT / "Sources" / "Core" / "VCAMConfiguration.m").read_text(
            encoding="utf-8"
        )
        # 布尔校验组与写白名单都必须包含该键，且恰好各一处。
        self.assertIn('@"floatingDotGlobal", @"screenTintEnabled"] containsObject:key',
                      source)
        self.assertIn('@"floatingDotGlobal", @"screenTintEnabled",', source)
        self.assertEqual(source.count('@"screenTintEnabled"'), 2)
        # 镜像必须是 XML 文本：相机侧按 <key> 标签裸文本扫描，binary plist 读不到。
        self.assertIn("NSPropertyListXMLFormat_v1_0", source)

    def test_panel_exposes_screen_tint_toggle(self) -> None:
        header = (ROOT / "Sources" / "UI" / "VCAMControlPanelViewController.h").read_text(
            encoding="utf-8"
        )
        self.assertIn("controlPanelDidRequestScreenTintToggle", header)
        panel = (ROOT / "Sources" / "UI" / "VCAMControlPanelViewController.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("三色调光", panel)
        self.assertIn("screenTintTapped", panel)
        self.assertIn("status[@\"screenTint\"]", panel)
        controller = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("controlPanelDidRequestScreenTintToggle", controller)
        self.assertIn('updatePreferences:@{@"screenTintEnabled": @(enabled)}', controller)

    def test_springboard_sampler_publishes_screen_tint_state(self) -> None:
        controller = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(
            encoding="utf-8"
        )
        self.assertIn('"com.codex.vcam.ios18.screen-tint.state"', controller)
        # 抓屏走 dlsym 的私有符号，不允许直接链接期依赖（缺失时降级而不是崩）。
        self.assertIn('dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay")', controller)
        # iOS 18 实测 CARenderServerRenderDisplay 的 layer.contents 为空；
        # SBScreenshotManager 只剩 saveScreenshots*（存相册），真机类扫描证实
        # 取屏入口=其 eligible providers 的 captureScreenshot（_SBMainScreenScreenshotProvider）。
        self.assertIn('objc_getClass("SBScreenshotManager")', controller)
        self.assertIn('_fetchEligibleScreenshotProvidersForSnapshotting', controller)
        self.assertIn('captureScreenshot', controller)
        self.assertIn('path=provider', controller)
        # iOS 18.3.1 真机：SBScreenshotManager 已无 +sharedInstance；工厂探测 +
        # 直接实例化 provider 的兜底必须有计数封顶（防 SpringBoard 崩溃循环）。
        self.assertIn('manager factory missing', controller)
        self.assertIn('objc_getClass("_SBMainScreenScreenshotProvider")', controller)
        self.assertIn('path=provider-direct', controller)
        self.assertIn('screen-tint-provider-probe.count', controller)
        self.assertIn("startScreenTintSampler", controller)
        # 采样只允许挂在 SpringBoard 宿主（保持 filter 收缩结论：零 App 注入）。
        self.assertIn("if ([self isSpringBoardHost]) {\n            "
                      "VCAMSampleSelfCPUWindowForSampler();",
                      controller)
        self.assertIn('[[VCAMConfiguration currentValues][@"screenTintEnabled"] boolValue]',
                      controller)

    def test_mediaserver_reads_channel_and_tints_only_with_gate(self) -> None:
        source = (ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefImageUtils.m").read_text(
            encoding="utf-8"
        )
        self.assertIn('"com.codex.vcam.ios18.screen-tint.state"', source)
        # 屏幕染色与 AE 曝光增益合并为单一对角增益计算入口（全链时也只一条
        # filter；快速路径走等价的逐像素对角乘法）。
        self.assertIn("VCAMComputeCombinedChannelFactors(diagFactor)", source)
        self.assertIn("VCAMComputeScreenTintFactors", source)
        self.assertIn('@"inputRVector"', source)
        # 缺省关闭 + 镜像配置解析
        self.assertIn("VCAMScreenTintEnabled = 0", source)
        self.assertIn('VCAMConfigValueSegment(contents, "screenTintEnabled", &end)', source)
        # 基线模型必须存在（防止普通 UI 肤色自污染误染色）。
        self.assertIn("VCAMScreenTintBaseline", source)

    def test_probe_reports_screen_tint_challenge(self) -> None:
        source = (ROOT / "probe-app" / "ProbeRunner.m").read_text(encoding="utf-8")
        self.assertIn('self.report[@"observedScreenTint"]', source)
        self.assertIn('"com.codex.vcam.ios18.screen-tint.state"', source)
        self.assertIn("runScreenTintChallenge", source)


if __name__ == "__main__":
    unittest.main()
