# 原生检测探针报告离线分析（阶段 6）。对应 docs/kyc/DETECTION-PLAN-NATIVE-APP-ZH.md §2。
# 用法:
#   python tools/kyc_native_probe_scan.py <probe_report.json>
#          [--browser-report <kyc-flow report.json>] [--video probe_phase*.mp4]...
# 输入是 App 经 POST /report 回传并被 kyc_upload_server 存档的 JSON。
# 输出：环境/相机 attachment/运动/EXIF 的判级，以及与浏览器报告逐项并排（若有 --browser-report）。
# 纯 stdlib；--video 复用 kyc_report_scan 帧连续性口径（需 ffmpeg）。
import argparse, json, math, sys
from pathlib import Path


EXPOSURE_HINTS = ("xposure", "ISO", "ISOGain", "Sensor", "ExposureTime", "Luminance")


def _fmt(v):
    if isinstance(v, float):
        return f"{v:.4g}"
    return str(v)


def analyze_environment(env):
    out = []
    jb = env.get("jbPaths", {})
    if jb.get("/var/jb"):
        out.append(("RISK", "rootless /var/jb 从 App 进程可见（越狱可被 stat 检出）"))
    else:
        out.append(("PASS", "/var/jb 不可见（该 App 视角未暴露 rootless 根）"))
    hook = env.get("dyldSuspicious", [])
    if hook:
        out.append(("RISK", f"{len(hook)} 个可疑注入镜像: " + ", ".join(hook[:5])))
    else:
        out.append(("PASS", "本进程 dyld 未见已知 hook 框架（注意：这只反映探针自身，非宿主 App）"))
    return out


def analyze_sessions(sessions):
    out = []
    for s in sessions:
        label = s.get("label", "?")
        att = s.get("attachmentStats", {})
        exp_keys = [k for k in att if any(h.lower() in k.lower() for h in EXPOSURE_HINTS)]
        frames = int(s.get("frames", 0))
        face = int(s.get("faceFrames", 0))
        if not exp_keys:
            out.append(("RISK", f"[{label}] 无逐帧曝光/ISO attachment（注入虚拟流常见破绽；真实传感器必有抖动）"))
        else:
            zero = [k for k in exp_keys if att[k].get("sd", 0) == 0]
            if zero:
                out.append(("WARN", f"[{label}] 曝光/ISO attachment 恒定无抖动: {', '.join(zero)}"))
            else:
                out.append(("PASS", f"[{label}] 逐帧曝光参数存在且有方差: " + ", ".join(exp_keys[:4])))
        if frames > 0:
            cov = face / frames
            out.append((("PASS" if cov > 0.5 else "RISK"),
                        f"[{label}] 人脸 metadata 覆盖 {cov*100:.0f}%（帧中有人而无人脸框=矛盾信号）"))
        out.append(("INFO", f"[{label}] activeFormat={s.get('activeFormatW')}x{s.get('activeFormatH')} "
                            f"frames={frames} attachmentKeys={len(att)}"))
    return out


def analyze_motion(m):
    out = []
    if not m:
        return [("NA", "无运动样本")]
    n = int(m.get("sampleCount", 0))
    if n == 0:
        return [("NA", "motion.sampleCount=0")]
    out.append((("RISK" if m.get("activity") == "static" else "INFO"),
                f"设备运动 activity={m.get('activity')} gyroStdev={_fmt(m.get('gyroStdev'))} "
                f"samples={n}（真实手持应非静止；静止设备播虚拟视频→IMU 与帧差相关性≈0）"))
    return out


def analyze_photo(p):
    out = []
    if not p or not p.get("saved"):
        return [("RISK", "未获得照片（原生快门路径未跑通）")]
    kc = int(p.get("exifKeyCount", 0))
    out.append((("PASS" if kc >= 8 else "RISK"),
                f"EXIF 字段 {kc} 项，{p.get('width')}x{p.get('height')}"
                "（vcam 注入下应保留真实设备 EXIF；过少=破绽）"))
    return out


def cross_compare(native_items, browser_report):
    rows = []
    bitems = {}
    if browser_report and isinstance(browser_report.get("items"), list):
        for it in browser_report["items"]:
            bitems[it.get("name", "?")] = it.get("status", "?")
    for name, status, detail in native_items:
        rows.append((name, status, bitems.get(name, "-")))
    return rows


def analyze(report_path, browser_path=None, videos=None):
    report = json.loads(Path(report_path).read_text(encoding="utf-8"))
    browser = None
    if browser_path:
        browser = json.loads(Path(browser_path).read_text(encoding="utf-8"))

    print("== native probe:", Path(report_path).name)
    meta = report.get("meta", {})
    print(" meta:", {k: meta.get(k) for k in ("flow", "machine", "systemRelease", "appVersion")})
    if report.get("error"):
        print(" ERROR:", report["error"])

    verdicts = []
    env = report.get("environment", {})
    verdicts += analyze_environment(env)
    cam = report.get("camera", {})
    verdicts += analyze_sessions(cam.get("sessions", []))
    verdicts += analyze_motion(report.get("motion"))
    verdicts += analyze_photo(cam.get("photo"))

    print("\n-- verdicts --")
    for lvl, msg in verdicts:
        print(f"  [{lvl}] {msg}")

    native_items = [(it.get("name", "?"), it.get("status", "?"), it.get("detail", ""))
                    for it in report.get("items", [])]
    if native_items:
        print("\n-- 与浏览器报告逐项对照（- = 浏览器无该项）--")
        print(f"  {'item':38s} native  browser")
        for name, nstat, bstat in cross_compare(native_items, browser):
            print(f"  {name:38s} {nstat:6s}  {bstat}")

    if videos:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import kyc_report_scan
        print("\n-- probe 视频帧连续性（复用检测电池口径）--")
        for v in videos:
            r = kyc_report_scan.scan(v)
            fd = r.get("frame_diff", {})
            print(f"  {Path(v).name}: ts_fps={r.get('pts',{}).get('ts_fps')} "
                  f"content_hz={fd.get('content_refresh_hz')} frozen={fd.get('content_frozen')} "
                  f"loop={r.get('loop_repeat',{}).get('loop_detected')}")
    return verdicts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("report")
    ap.add_argument("--browser-report")
    ap.add_argument("--video", action="append", default=[])
    a = ap.parse_args()
    analyze(a.report, a.browser_report, a.video)
    return 0


if __name__ == "__main__":
    sys.exit(main())
