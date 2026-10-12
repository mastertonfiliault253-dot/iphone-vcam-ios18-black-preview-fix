# KYC 回传媒体离线检测电池（对齐电商 KYC 的 Injection/Deepfake 检测维度）
# 用法:
#   python tools/kyc_report_scan.py <文件或目录>... [--json out.json]
# 对每个 mp4 计算: PTS 间隔分布 / 相邻帧内容差(重复帧率、内容刷新Hz) /
# 高频噪声指纹(拉普拉斯均值) / 循环与动作重复度(帧签名自相似 lag) / 摩尔纹(行间高频能量比)。
# 纯 stdlib + ffmpeg/ffprobe（与 tmp/frame_diff.py、tmp/noise_fp.py 同源口径）。
import argparse, json, math, re, statistics, subprocess, sys
from pathlib import Path

SIG_W, SIG_H = 96, 72          # 循环重复度签名分辨率（小签名足够且快）
NOISE_W, NOISE_H = 640, 480    # 噪声指纹统一口径
DIFF_STEP = 7                  # 相邻帧差抽样步长（全量太长，统计上等价）


def ffprobe_pts(path):
    # ffmpeg 8 移除了 pkt_pts_time，两代字段都试一次。
    for field in ("pts_time", "pkt_pts_time"):
        r = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0",
                            "-show_entries", f"frame={field}", "-of", "csv=p=0", str(path)],
                           capture_output=True, text=True)
        vals = [x.split(",")[0] for x in r.stdout.splitlines() if x.strip()]
        if vals:
            return [float(v) for v in vals]
    return []


def decode_gray(path, w, h):
    r = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path),
                        "-vf", f"scale={w}:{h}", "-f", "rawvideo", "-pix_fmt", "gray", "-"],
                       capture_output=True)
    raw, fs = r.stdout, w * h
    if not raw or len(raw) % fs:
        return []
    return [raw[i * fs:(i + 1) * fs] for i in range(len(raw) // fs)]


def pts_metrics(pts):
    if len(pts) < 3:
        return {"frames": len(pts)}
    gaps = [b - a for a, b in zip(pts, pts[1:])]
    med = statistics.median(gaps)
    return {"frames": len(pts), "ts_fps": round((len(pts) - 1) / (pts[-1] - pts[0]), 2),
            "gap_median_ms": round(med * 1000, 2),
            "gap_p95_ms": round(sorted(gaps)[int(0.95 * len(gaps))] * 1000, 2),
            "gap_stdev_ratio": round(statistics.pstdev(gaps) / med, 3) if med else None}


def frame_diff_metrics(frames, dur):
    diffs = []
    for a, b in zip(frames, frames[1:]):
        s = 0
        for j in range(0, len(a), DIFF_STEP):
            d = a[j] - b[j]
            s += d if d >= 0 else -d
        diffs.append(s / (len(range(0, len(a), DIFF_STEP))))
    dup = [d for d in diffs if d < 0.5]
    content_hz = (len(diffs) - len(dup)) / dur if dur > 0 and len(diffs) else 0.0
    return {"pairs": len(diffs), "dup_ratio": round(len(dup) / len(diffs), 3) if diffs else None,
            "median_diff": round(statistics.median(diffs), 3) if diffs else None,
            "max_diff": round(max(diffs), 3) if diffs else None,
            "content_refresh_hz": round(content_hz, 2),
            "content_frozen": bool(diffs and content_hz < 10 and dur > 1)}


def noise_metric(frames640):
    vals = []
    w, h = NOISE_W, NOISE_H
    for raw in frames640[:3]:
        s = 0
        for y in range(1, h - 1):
            row, up, dn = raw[y * w:(y + 1) * w], raw[(y - 1) * w:y * w], raw[(y + 1) * w:(y + 2) * w]
            for x in range(1, w - 1):
                v = up[x] + row[x - 1] + row[x + 1] + dn[x] - 4 * row[x]
                s += v if v >= 0 else -v
        vals.append(round(s / ((h - 2) * (w - 2)), 2))
    return {"laplacian_mean_abs": vals}


def loop_repeat_metric(sigs, fps):
    """真循环的判据是"对比度"而非"相似度"：短 lag（0.5-1.5s）帧间有动作差异，
    而某个长 lag（≥2s，=源视频时长）上差异骤降到接近零。近静态场景短长 lag 差异同样低，
    相对比不骤降，不会误报（v1 用全体 lag 中位数做基线在静态场景上假阳性）。
    只在 ≥8s 的片段上给结论。"""
    n = len(sigs)
    fps = max(fps, 1)
    if n < 8 * fps:
        return {"note": "片段太短(<8s)，循环重复度不适用"}
    def lag_diff(lag):
        s = sum(sum(abs(a - b) for a, b in zip(sigs[i], sigs[i + lag])) for i in range(n - lag))
        return s / ((n - lag) * len(sigs[0]))
    short = [lag_diff(lag) for lag in range(max(2, int(fps * 0.5)), int(fps * 1.5))]
    short_base = statistics.median(short) if short else 0.0
    lo, hi = max(int(fps * 2), n // 4), int(n * 0.9)
    lags = list(range(lo, hi))
    if not lags:
        return {"short_lag_diff": round(short_base, 2), "note": "片段不足以测 ≥2s 周期"}
    scores = {lag: lag_diff(lag) for lag in lags}
    best_lag = min(scores, key=scores.get)
    ratio = scores[best_lag] / short_base if short_base > 0 else 1.0
    return {"best_lag_frames": best_lag, "best_lag_seconds": round(best_lag / fps, 1),
            "best_lag_diff": round(scores[best_lag], 2),
            "short_lag_diff": round(short_base, 2), "dip_ratio": round(ratio, 3),
            "loop_detected": bool(ratio < 0.5),
            "note": "dip_ratio=长lag最优差/短lag基线；<0.5=内容以该周期原样重复"}


def moire_metric(frames640):
    """行间高频能量比：屏幕翻拍摩尔纹会在空间高频出现能量尖峰。用 1D 差分谱近似。"""
    if not frames640:
        return {}
    raw = frames640[0]
    w, h = NOISE_W, NOISE_H
    hi_energies = []
    for y in range(10, h - 10, 10):
        row = [raw[y * w + x] for x in range(0, 512)]
        d1 = [b - a for a, b in zip(row, row[1:])]
        e_all = sum(v * v for v in d1) or 1
        d2 = [b - a for a, b in zip(d1, d1[1:])]
        hi_energies.append(sum(v * v for v in d2) / e_all)
    return {"highfreq_row_ratio": round(statistics.median(hi_energies), 3),
            "note": "与真实相机基线对照才有意义，绝对值无阈值"}


def scan(path):
    out = {"file": str(path)}
    pts = ffprobe_pts(path)
    out["pts"] = pts_metrics(pts)
    dur = (pts[-1] - pts[0]) if len(pts) > 1 else 0
    big = decode_gray(path, NOISE_W, NOISE_H)
    if not big:
        out["error"] = "decode failed"
        return out
    out["frame_diff"] = frame_diff_metrics(big, dur)
    out["noise"] = noise_metric(big)
    sig = decode_gray(path, SIG_W, SIG_H)
    fps = out["pts"].get("ts_fps") or (len(sig) / dur if dur > 0 else 30)
    out["loop_repeat"] = loop_repeat_metric(sig, fps)
    out["moire"] = moire_metric(big)
    return out


def find_clips(target):
    p = Path(target)
    if p.is_dir():
        return sorted(list(p.glob("flow_*.mp4")) + list(p.glob("record_*.mp4")))
    return [p]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("targets", nargs="+")
    ap.add_argument("--json", default=None)
    args = ap.parse_args()
    results = []
    for t in args.targets:
        for clip in find_clips(t):
            print(f"== scanning {clip}", flush=True)
            r = scan(clip)
            results.append(r)
            print(json.dumps(r, ensure_ascii=False, indent=1))
    if args.json:
        Path(args.json).write_text(json.dumps(results, ensure_ascii=False, indent=1), encoding="utf-8")
    # 简易对照表
    print("\nfile | ts_fps | gap_med | content_hz | frozen | noise_lap | loop")
    for r in results:
        p, fd, n, lr = r.get("pts", {}), r.get("frame_diff", {}), r.get("noise", {}), r.get("loop_repeat", {})
        loop = f"{lr.get('loop_detected')}@{lr.get('best_lag_frames')}" if "loop_detected" in lr else lr.get("note", "-")
        print(f"{Path(r['file']).name} | {p.get('ts_fps')} | {p.get('gap_median_ms')} | "
              f"{fd.get('content_refresh_hz')} | {fd.get('content_frozen')} | "
              f"{(n.get('laplacian_mean_abs') or ['-'])[0]} | {loop}")


if __name__ == "__main__":
    main()
