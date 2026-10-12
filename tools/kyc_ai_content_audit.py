# AI 生成人脸视频"去 AI 痕迹"体检（阶段4 生成侧调优的量化前后对比工具）
# 用法:
#   python tools/kyc_ai_content_audit.py <视频文件>... [--json out.json]
# 检查项与电商 KYC 的 Deepfake/传感器级/时间连续性检测维度对应：
#   encode   码率bpp/关键帧GOP —— "高码率短GOP、禁止二次转码"导出规范
#   hf       逐帧拉普拉斯高频能量与帧间变化率 —— 过度平滑 vs 静态纹理式噪声
#            （校准: 真相机 720 录像 lap≈3.0-3.8 且帧间波动 ±30%；
#             AI 源 lap≈11.1 且帧间几乎不变 = 静态纹理噪声，传感器级检测可辨）
#   motion   相邻帧差能量与静止帧占比 —— 真人静止也有呼吸/微晃（真基线≈1.36，
#            AI 源≈0.54、47.5% 相邻帧几乎相同）
#   periodic 运动能量序列自相关峰值 —— 固定动作周期的痕迹
#   loop     复用 kyc_report_scan 的 dip_ratio 循环判据
# 纯 stdlib + ffmpeg/ffprobe，度量口径与 kyc_report_scan.py 一致（import 复用）。
import argparse, json, statistics, subprocess, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import kyc_report_scan as ks

HF_FRAMES = 6          # 高频能量采样帧数（均匀取帧）
STATIC_DIFF = 0.5      # 相邻帧"几乎相同"阈值（与 dup 判据一致）


def encode_profile(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0",
                        "-show_entries",
                        "stream=codec_name,width,height,r_frame_rate,bit_rate,nb_frames",
                        "-of", "csv=p=0", str(path)], capture_output=True, text=True)
    parts = r.stdout.strip().split(",")
    if len(parts) < 4:
        return {"error": r.stderr.strip() or "ffprobe 无输出"}
    codec, w, h, rate = parts[0], int(parts[1]), int(parts[2]), parts[3]
    num, _, den = rate.partition("/")
    fps = float(num) / float(den or 1) if num else 0.0
    bitrate = int(parts[4]) if len(parts) > 4 and parts[4].strip().isdigit() else 0
    kr = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0",
                         "-show_frames", "-show_entries", "frame=key_frame",
                         "-of", "csv=p=0", str(path)], capture_output=True, text=True)
    keys = [i for i, line in enumerate(kr.stdout.splitlines())
            if line.strip().startswith("1")]
    gops = [b - a for a, b in zip(keys, keys[1:])]
    bpp = bitrate / (w * h * fps) if bitrate and w and h and fps else None
    return {"codec": codec, "size": f"{w}x{h}", "fps": round(fps, 2),
            "bitrate": bitrate,
            "bpp": round(bpp, 4) if bpp is not None else None,
            "keyframes": len(keys),
            "gop_frames_max": max(gops) if gops else None,
            "gop_seconds_max": round(max(gops) / fps, 1) if gops and fps else None}


def hf_series(path, frames640):
    idx = sorted({int(i * (len(frames640) - 1) / max(HF_FRAMES - 1, 1))
                  for i in range(min(HF_FRAMES, len(frames640)))})
    vals = [v for v in ks.noise_metric([frames640[i] for i in idx])
            ["laplacian_mean_abs"]]
    if not vals:
        return {}
    mean = statistics.mean(vals)
    cv = statistics.pstdev(vals) / mean if mean else 0.0
    return {"samples": len(vals), "laplacian_mean_abs": round(mean, 2),
            "inter_frame_cv": round(cv, 3),
            "note": "真相机基线≈3且帧间波动±30%；AI常见两种失败：过度平滑(<1.2)或静态纹理噪声(高且cv≈0)"}


def motion_series(frames_sig):
    diffs = []
    for a, b in zip(frames_sig, frames_sig[1:]):
        s = 0
        for j in range(0, len(a), ks.DIFF_STEP):
            d = a[j] - b[j]
            s += d if d >= 0 else -d
        diffs.append(s / len(range(0, len(a), ks.DIFF_STEP)))
    return diffs


def autocorr_peak(diffs, fps):
    n = len(diffs)
    if n < 4 * fps:
        return {"note": "片段太短(<4s)，周期运动自相关不适用"}
    mean = statistics.mean(diffs)
    var = statistics.pvariance(diffs)
    if var <= 1e-9:
        return {"max_autocorr": None, "note": "运动能量恒定（几乎静止），自相关无意义"}
    rho_at = {}
    for lag in range(int(fps * 0.5), n // 2 + 1):
        cov = sum((diffs[i] - mean) * (diffs[i + lag] - mean) for i in range(n - lag)) / (n - lag)
        rho_at[lag] = cov / var
    # 周期信号在整数倍周期上自相关都接近 1，取最小局部峰才是基周期。
    lags = sorted(rho_at)
    for k in range(1, len(lags) - 1):
        lag = lags[k]
        if rho_at[lag] >= 0.6 and rho_at[lag] > rho_at[lags[k - 1]] \
                and rho_at[lag] >= rho_at[lags[k + 1]]:
            return {"max_autocorr": round(rho_at[lag], 3),
                    "period_seconds": round(lag / fps, 2)}
    best_lag = max(lags, key=lambda l: rho_at[l]) if lags else None
    return {"max_autocorr": round(rho_at[best_lag], 3) if lags else None,
            "period_seconds": round(best_lag / fps, 2) if best_lag else None,
            "note": "无 ≥0.6 的局部峰，返回全局最大值（不构成周期性判级）"}


def audit(path):
    out = {"file": str(path)}
    out["encode"] = encode_profile(path)
    enc = out["encode"]
    fps = enc.get("fps") or 25.0
    sigs = ks.decode_gray(path, ks.SIG_W, ks.SIG_H)
    frames640 = ks.decode_gray(path, ks.NOISE_W, ks.NOISE_H)
    if not sigs:
        out["error"] = "解码失败（检查文件与 ffmpeg）"
        return out
    out["hf"] = hf_series(path, frames640)
    # 微动作必须在 640×480 口径测：96×72 签名会把真相机的传感器噪声/呼吸微动
    # 平均到 dup 阈值以下（2026-10-13 真基线在粗签名上 static_ratio=1.0 误报）。
    diffs = motion_series(frames640 if frames640 else sigs)
    static = [d for d in diffs if d < STATIC_DIFF]
    out["motion"] = {"pairs": len(diffs),
                     "median_diff": round(statistics.median(diffs), 3) if diffs else None,
                     "static_ratio": round(len(static) / len(diffs), 3) if diffs else None,
                     "note": "96x72 签名口径；真基线静止场景 median≈1.36 static≈0；AI 微动作不足时该值升高"}
    out["periodic"] = autocorr_peak(diffs, fps)
    out["loop"] = ks.loop_repeat_metric(sigs, fps)

    verdicts = []
    if enc.get("bpp") is not None and enc["bpp"] < 0.04:
        verdicts.append(f"RISK 码率偏低 bpp={enc['bpp']}（建议 ≥0.06，720p30 约 4-8Mbps）")
    if enc.get("gop_seconds_max") is not None and enc["gop_seconds_max"] > 2.0:
        verdicts.append(f"WARN GOP {enc['gop_seconds_max']}s > 2s（服务端逐帧分析依赖短 GOP）")
    hf = out.get("hf") or {}
    if hf.get("laplacian_mean_abs") is not None:
        if hf["laplacian_mean_abs"] < 1.2:
            verdicts.append("RISK 高频能量过低，疑似过度平滑（deepfake 首要特征）")
        elif hf["laplacian_mean_abs"] > 6.0 and hf.get("inter_frame_cv", 1) < 0.05:
            verdicts.append(f"WARN 高频能量高({hf['laplacian_mean_abs']})且帧间恒定(cv={hf['inter_frame_cv']})"
                            "：静态纹理式噪声，真实传感器噪声应帧间随机变化")
    if (out["motion"].get("static_ratio") or 0) > 0.35:
        verdicts.append(f"RISK 静止帧占比 {out['motion']['static_ratio']}：微动作不足"
                        "（真人静止有呼吸/微晃/眨眼，需生成侧注入）")
    ac = out.get("periodic") or {}
    if ac.get("max_autocorr") is not None and ac["max_autocorr"] >= 0.7:
        verdicts.append(f"WARN 运动能量以 {ac['period_seconds']}s 周期重复"
                        "（rho={:.2f}）：固定动作周期痕迹".format(ac["max_autocorr"]))
    if out.get("loop", {}).get("loop_detected"):
        verdicts.append(f"RISK 内容以 {out['loop']['best_lag_seconds']}s 原样循环"
                        "（dip_ratio={:.3f}）".format(out["loop"]["dip_ratio"]))
    out["verdicts"] = verdicts or ["PASS 无自动判级风险（仍需与真机基线对照目视）"]
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--json", dest="json_out")
    args = ap.parse_args()
    reports = [audit(p) for p in args.paths]
    for rep in reports:
        print(json.dumps(rep, ensure_ascii=False, indent=2))
    if args.json_out:
        Path(args.json_out).write_text(json.dumps(reports, ensure_ascii=False, indent=2),
                                       encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
