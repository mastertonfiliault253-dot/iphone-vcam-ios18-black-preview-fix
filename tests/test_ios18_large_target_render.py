from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
IMAGE_UTILS = ROOT / "Sources" / "Hooks" / "VCAMMediaServerRefImageUtils.m"


class LargeTargetRenderTests(unittest.TestCase):
    """钉住 2026-10-13 的 1080p 内容冻结修复。

    根因：cameracaptured 的 CoreImage 上下文强制软件渲染，1080p/4K 全尺寸软渲染
    90–135ms 超帧预算 → graph 复用旧帧 → 时间戳正常但内容 ~9Hz（真机基线对照：
    真实相机 30Hz）。修复：实时路径合成尺寸钳制到源细节以内 + 写回阶段一次
    双线性放大，并保持"优先直写、VideoToolbox 仅兜底"的 iOS 18 语义。
    设备端验收复用 tools/kyc_report_scan.py 对 1080p 录像判 frozen=False。
    """

    def setUp(self) -> None:
        self.source = IMAGE_UTILS.read_text(encoding="utf-8")

    def test_realtime_planar_composition_size_is_clamped(self) -> None:
        self.assertIn("static void VCAMClampRealtimeCompositionSize(", self.source)
        # 钳制只作用于实时路径；静态照片保持全尺寸。
        self.assertIn(
            "if (realtimeCompensation) {\n"
            "                VCAMClampRealtimeCompositionSize(&compositionWidth,"
            " &compositionHeight);",
            self.source,
        )

    def test_clamped_composition_writes_back_through_scaled_direct_copy(self) -> None:
        # 合成尺寸小于目标时走放大直写，而不是先 VideoToolbox。
        self.assertIn("VCAMCopyScaledBGRAToPlanarTarget(", self.source)
        scaled_start = self.source.index("static BOOL VCAMCopyScaledBGRAToPlanarTarget(")
        scaled_end = self.source.index(
            "\nstatic BOOL VCAMCopyBGRAToPlanarTarget(", scaled_start + 1)
        scaled_body = self.source[scaled_start:scaled_end]
        self.assertIn("VCAMUpscaleBGRAContent(", scaled_body)
        self.assertIn("VCAMCopyBGRAToPlanarTarget(fullBuffer, targetBuffer)", scaled_body)
        self.assertNotIn("VTPixelTransferSessionTransferImage", scaled_body)

    def test_upscale_helper_is_bilinear(self) -> None:
        start = self.source.index("static void VCAMUpscaleBGRAContent(")
        end = self.source.index("\n// 合成尺寸小于目标", start)
        body = self.source[start:end]
        self.assertIn("weightX", body)
        self.assertIn("weightY", body)

    def test_unclamped_paths_keep_existing_transfer_semantics(self) -> None:
        # 未钳制（尺寸相等）时仍走原 VCAMTransferBGRAIntoPlanarTarget 路径。
        self.assertIn(
            "VCAMTransferBGRAIntoPlanarTarget(\n"
            "                               stagingBuffer, targetBuffer)",
            self.source,
        )

    def test_realtime_identity_composition_bypasses_render_task(self) -> None:
        # 2026-10-14 发热/丢帧优化：实时同尺寸、无加性(torch 补光)增益时
        # CI 图等价直通——跳过 CIRenderTask，用同一写回函数直接转源缓冲
        #（rear 1080p 全幅软渲染 p50 ~32ms 的主要成本）。对角增益（AE×染色）
        # 不算失配：先在私有 BGRA 拷贝上做等价的逐像素定点乘法。
        self.assertIn("BOOL passthroughFastPath = !additiveActive", self.source)
        self.assertIn("VCAMApplyBGRAChannelFactorsInPlace(localSourceBuffer, diagFactor);",
                      self.source)
        self.assertIn("CIRenderTask *task = passthroughFastPath ? nil", self.source)
        self.assertIn(
            "rendered = VCAMTransferBGRAIntoPlanarTarget(ciSourceBuffer, targetBuffer);",
            self.source,
        )
        # 快速路径命中不是渲染失败：不得触发 Metal 永久回退或失败日志。
        self.assertEqual(2, self.source.count("!coreImageRendered && !passthroughFastPath"))


if __name__ == "__main__":
    unittest.main()
