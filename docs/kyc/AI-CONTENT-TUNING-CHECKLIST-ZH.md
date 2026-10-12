# AI 生成人脸视频"去 AI 痕迹"调优清单（阶段4）

对象：真人照片 AI 生成的人脸视频（KYC 人脸侧内容形态）。证件侧为真实证件照片，不在本清单范围。
工具：`tools/kyc_ai_content_audit.py <视频> [--json out.json]`（纯 stdlib + ffmpeg，度量口径与
`tools/kyc_report_scan.py` 一致；回归测试 `tests/test_kyc_ai_content_audit.py`）。

## 1. 调优项 ↔ 检测维度 ↔ 量化判据

| # | 生成/导出侧调优项 | 针对的检测维度 | audit 量化项 | 判据（2026-10-13 校准） |
|---|---|---|---|---|
| 1 | 皮肤纹理不过度平滑 | Deepfake 分类器首要特征 | `hf.laplacian_mean_abs` | 真相机 720 录像基线 ≈3.0–3.8；`<1.2` 判 RISK |
| 2 | 噪声必须帧间随机（传感器级动态），不可"贴静态纹理" | 传感器级：逐帧曝光/噪声一致性 | `hf.inter_frame_cv` | 真基线帧间波动 ±10–30%；高能量且 `cv<0.05` 判 WARN |
| 3 | 微动作：眨眼（14–17 次/分）、呼吸、头部微晃 | 逐帧时间连续性 / 活体 | `motion.static_ratio`、`median_diff` | 真基线静止场景 static_ratio≈0、median_diff≈1.3（640×480 口径）；`static_ratio>0.35` 判 RISK |
| 4 | 无固定动作周期 | 时间连续性（周期信号） | `periodic.max_autocorr` | 运动能量自相关局部峰 ≥0.6 即报周期（秒） |
| 5 | 时长 ≥ 单次 KYC 会话，消除原样循环 | 循环接缝检测 | `loop`（dip_ratio） | `loop_detected`（dip_ratio<0.5）判 RISK；选段或加长生成 |
| 6 | 成片规格：目标分辨率、30fps、高码率（bpp≥0.06）、短 GOP（≤2s）、禁止二次转码 | 压缩痕迹/转码指纹 | `encode.bpp`、`gop_seconds_max` | `bpp<0.04` RISK；GOP>2s WARN（Safari MediaRecorder 本身 GOP ~10s，属浏览器链路，非生成侧） |
| 7 | 光线/背景微变化、口型与语音同步（若流程有朗读） | 光学活体 / Challenge Response | 人工目视 + 阶段6 探针 | 不可自动化，列入人工检查 |

## 2. 本轮实测基线（供调优前后对比）

资产：`tmp/source-6C48B2AC.mov`（736×992@24fps，8s loop，本次测试用 AI 源视频）。
对照：`tmp/kyccheck/off_true/flow_record_720x1280.mp4`（真相机经 Safari 录制的设备侧录像）。

| 指标 | AI 源视频 | 真机真相机录像 | 解读 |
|---|---|---|---|
| hf 拉普拉斯均值 | 10.45 | 3.37 | AI 源高频能量约为真实链路 3×——本例风险不是"过度平滑"而是噪声偏重（场景不同，绝对值仅供参考） |
| hf 帧间 cv | 0.112 | 0.099 | 两者帧间都有变化，未触发"静态纹理噪声"判据 |
| motion median_diff | 1.881（前 2s 内 0.54） | 1.338 | AI 片开头近静止段（96s 前 2 秒 dup_ratio 0.475），后段有动作 |
| motion static_ratio | 0.244 | 0.0 | 未触发 RISK（阈值 0.35）但明显高于真实链路；剪掉近静止开头段可进一步降低 |
| periodic | rho 0.609 @1.0s | —（片段<4s 不适用） | 有轻度 1s 周期运动能量痕迹 |
| loop（8s 源、<8s 片段规则外的整片） | dip_ratio 0.584 未达 0.5 | — | 设备侧录到 24.7s 处的真循环证据见检测电池记录（多轮播放放大原样重复）；本地单轮 8s 不足以判 |
| encode | bpp 0.105，无关键帧间隔数据（单 GOP） | bpp 0.374（Safari 链路），GOP 9.8s | 源片码率充分 |

audit 完整输出存档：`tmp/kyccheck/ai_audit_baseline.json`（tmp 不入库）。

## 3. 使用流程

1. 生成侧产出候选视频后：`python tools/kyc_ai_content_audit.py <候选.mp4> --json tmp/audit_new.json`。
2. 与上表基线对照；任何 RISK 项按第 1 节对应行调整生成参数（加长动作、注入眨眼/微晃、重打光、换更长片段）。
3. 通过后再上设备跑 `probe/kyc-flow.html?auto=1` 全流程（检测电池），确认设备侧录出的
   `flow_record_*` 无 `content_frozen`、loop 项按选段时长规避。
4. 更换生成模型/参数时重新出基线并更新第 2 节表格。

## 4. 未覆盖（如实标注）

- 商用 deepfake 检测器（Rekognition BlurAndFaceAttributes、内建 rPPG）的实际得分无法本地复现，
  只能以"信号存在性"作为代理；最终通过性需供应商实测（阶段6 原生探针 + 真账号）。
- 3D 深度结构光（Persona/Veriff glow scan 类）对单目注入视频不可测，属结构性缺口，非调优可解。
- Challenge Response 随机动作响应：当前预生成管线不支持指令驱动分支，保持 NA
  （阶段5 备注：若管线支持按指令生成片段再接入）。
