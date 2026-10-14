"""AE↔亮度全耦合 + metalRenderer 实验开关 + CPU 自测窗契约测试。

链路：BW 设备节点 AE 控制 hook + sample buffer attachment 数据路径
→ RefImageUtils 观测状态（相对基线乘性增益，单一 CIColorMatrix 节点）
→ 输出。物理设备切换（前↔后）必须作废观测/基线。metalRenderer 缺省 0=
保持软件渲染；探针验证 + watchdog 是正确性边界。设备无 top/ps CPU，
getrusage 自测窗是前后对比的唯一数据来源。
"""

import pathlib
import unittest

ROOT = pathlib.Path(__file__).parents[1]


class PhotorealAEMetalChainTests(unittest.TestCase):
    def test_entry_hooks_control_and_data_paths(self) -> None:
        source = (ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefEntry.xm").read_text(
            encoding="utf-8"
        )
        # 控制路径：手动曝光终值 + EV 偏置（与 torch 同款编码自适应安装）。
        self.assertIn(
            "setExposureModeCustomWithExposureDuration:minFrameRate:maxFrameRate:ISO:requestID:",
            source,
        )
        self.assertIn("setExposureTargetBias:requestID:", source)
        self.assertIn("VCAMInstallAEObservationIfNeeded", source)
        # 数据路径：attachment 键诊断转储 + 候选键防御解析（auto-AE 唯一通道）。
        # 注意：构建 SDK（16.5）未导出 kCGImageAuxiliaryDataInfo 常量，必须用
        # 文档钉值的 CFSTR 字符串键（"AuxiliaryData"）。
        self.assertIn('CFSTR("AuxiliaryData")', source)
        self.assertIn("ae_attach.log", source)
        self.assertIn("VCAMObserveSampleBufferExposure", source)
        # 物理设备实例切换=作废观测（前/后置实例不同）。
        self.assertIn("VCAMNoteObservedDevice", source)
        self.assertIn("VCAMResetObservedPhysicalState", source)

    def test_gain_is_relative_and_single_node(self) -> None:
        source = (ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefImageUtils.m").read_text(
            encoding="utf-8"
        )
        # 观测状态 + 文件级基线（前后面切换复位用）。
        self.assertIn("void VCAMSetObservedExposure(double durationSeconds, double iso)", source)
        self.assertIn("VCAMExposureBaselineIndex", source)
        # 增益是相对调制（替换内容自身亮度保留），且与屏幕染色共用一条 filter。
        self.assertIn("exposureIndex / VCAMExposureBaselineIndex", source)
        self.assertIn("ae_gain=%.3f exposure_index=%.6f baseline=%.6f", source)
        self.assertIn("VCAMComputeCombinedChannelFactors", source)
        # 前后面标志翻转立即作废全部物理观测。
        self.assertIn("if (previous != value) VCAMResetObservedPhysicalState();", source)
        # 观测值透传快照日志（与探针 exposureSamples 对表通道）。
        self.assertIn("obs_exp_s=%.6f obs_iso=%.1f obs_bias=%.2f", source)

    def test_metal_renderer_is_gated_probe_verified_and_fails_safe(self) -> None:
        source = (ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefImageUtils.m").read_text(
            encoding="utf-8"
        )
        # 缺省仍软件渲染（ponytail 历史结论不因实验翻转缺省）。
        self.assertIn("kCIContextUseSoftwareRenderer", source)
        self.assertIn('VCAMConfigValueSegment(contents, "metalRenderer", &end)', source)
        # 采用前必须探针验证；帧路径有界等待（CIRenderTask 无 cancel，16.5 SDK
        # 也无 contextWithMetalDevice:——用 UseSoftwareRenderer=NO + 独立队列超时）；
        # 任何真实帧失败永久回退。
        self.assertIn("VCAMCreateProbedMetalContext", source)
        self.assertIn("kCIContextUseSoftwareRenderer: @NO", source)
        self.assertIn("com.codex.vcam.metal-render", source)
        self.assertIn("permanently falling back to software context", source)
        self.assertIn("VCAMMetalContextActive", source)

    def test_self_cpu_windows_exist_for_both_processes(self) -> None:
        media_server = (ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefImageUtils.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("getrusage(RUSAGE_SELF, &usage)", media_server)
        self.assertIn('"self-cpu window elapsedS=%.0f cpuS=%.1f pct=%.1f"', media_server)
        springboard = (ROOT / "Sources" / "UI" / "VCAMMediaPickerController.m").read_text(
            encoding="utf-8"
        )
        self.assertIn("screen-tint self-cpu window", springboard)

    def test_header_exports_observation_api(self) -> None:
        header = (ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefImageUtils.h").read_text(
            encoding="utf-8"
        )
        self.assertIn("void VCAMSetObservedExposure(double durationSeconds, double iso);", header)
        self.assertIn("void VCAMSetObservedExposureBias(double biasEV);", header)
        self.assertIn("void VCAMResetObservedPhysicalState(void);", header)


if __name__ == "__main__":
    unittest.main()
