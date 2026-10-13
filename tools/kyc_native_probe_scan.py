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
        out.append(("INFO", f"[{label}] captured={s.get('capturedW')}x{s.get('capturedH')} "
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


def analyze_extended(report):
    """扩展收集项（IDFV/亮度/音频路由/人脸细节/Vision 质量/实时曝光/最大拍照档位/深度/气压）。"""
    cam = report.get("camera", {})
    env = report.get("environment", {})
    out = []
    # 零帧定位：会话事件与丢弃计数（探针增强版起才有这些键）。
    for ev in cam.get("sessionEvents", []):
        name = ev.get("event", "")
        if "RuntimeError" in name:
            out.append(("RISK", f"会话运行时错误: {ev.get('errDomain')} code={ev.get('errCode')} "
                                f"{str(ev.get('errDesc'))[:120]}"))
        elif "WasInterrupted" in name:
            out.append(("RISK", f"会话被打断 reason={ev.get('reason')}"))
    dropped = cam.get("droppedVideo")
    if dropped and report.get("noFramesAfter5s"):
        out.append(("RISK", f"帧被管线丢弃 droppedVideo={dropped}（didOutput 未到回调——在投递层，非会话启动层）"))
    idfv = env.get("identifierForVendor")
    if idfv and idfv != "none":
        audio = env.get("audio", {})
        out.append(("INFO", f"IDFV 可得；brightness={env.get('screenBrightness')} "
                            f"barometerAvailable={env.get('barometerAvailable')} "
                            f"audio inputs={len(audio.get('inputs', []))} outputs={len(audio.get('outputs', []))}"))
    else:
        out.append(("RISK", "identifierForVendor 不可得（供应商 SDK 常用设备指纹缺位）"))
    fs = cam.get("faceSamples", [])
    yawn = sum(1 for f in fs if "yaw" in f)
    rolln = sum(1 for f in fs if "roll" in f)
    if fs:
        out.append(("INFO", f"人脸 metadata 细节 {len(fs)} 条（yaw={yawn} roll={rolln}）——faceID 跨帧跟踪可用"))
    else:
        out.append(("RISK", "无 faceID/yaw/roll 细节样本（零帧时先查 cameraSessionDiag/noFramesAfter5s）"))
    vs = cam.get("visionSamples", [])
    if vs:
        quals = [q for v in vs for q in v.get("qual", []) if isinstance(q, (int, float))]
        msg = f"Vision 人脸质量 {len(vs)} 样本 / {len(quals)} 个质量值"
        if quals:
            msg += f"，mean={sum(quals)/len(quals):.3f} min={min(quals):.3f}"
        out.append(("INFO", msg))
    else:
        out.append(("RISK", "无 Vision 质量样本（检测栈同源信号缺位）"))
    es = cam.get("exposureSamples", [])
    if es:
        ds = [e.get("exposureUs", 0) for e in es]
        iso = [e.get("iso", 0) for e in es]
        spread = "有变化(AE 活跃, 真实传感器特征)" if max(ds) > min(ds) or max(iso) > min(iso) else "恒定(AE 锁死?)"
        out.append(("INFO", f"实时曝光采样 {len(es)} 条 exposureUs {min(ds)}~{max(ds)} iso {min(iso)}~{max(iso)}：{spread}"))
    else:
        out.append(("RISK", "无实时曝光/ISO 采样"))
    mr = cam.get("maxPhotoDims", {})
    if mr:
        out.append(("INFO", f"最大拍照档位 supported={mr.get('supported')} applied={mr.get('applied')}"))
    sr = cam.get("sensorRanges", {})
    if sr:
        out.append(("INFO", f"sensor 范围 maxExposureMs={sr.get('maxExposureMs')} ISO {sr.get('minISO')}~{sr.get('maxISO')} "
                            f"FOV={sr.get('videoFieldOfView')} maxFPS={sr.get('activeMaxFPS')}"))
    tr = cam.get("trueDepth", {})
    dep = cam.get("depth", {})
    if tr.get("frontTrueDepthPresent"):
        out.append(("INFO", f"TrueDepth 前置存在，depthFrames={dep.get('frames')}（3D liveness 通道可尝试）"))
    else:
        out.append(("NA", "TrueDepth 前置不可得 → 3D 深度 liveness 通道无法打开（真实 KYC 硬缺项，文档已记）"))
    al = report.get("altimeter", {})
    if al.get("samples"):
        out.append(("INFO", f"气压样本 {len(al['samples'])} 条"))
    else:
        out.append(("NA", "无气压样本"))
    return out


def analyze_persona_replica(report):
    """Persona 复刻段（清单文档"复刻规格"）：锁帧结果、cameraProperties 遥测、
    torch 脉冲 ↔ 画面亮度一致性（检测点 #5）。"""
    out = []
    af = report.get("appliedFormat", {})
    for label in ("low", "high"):
        lock = af.get(f"{label}_fpsLock")
        if lock == "30":
            out.append(("INFO", f"activeFormat {label} 档已锁 30fps（对齐 Persona 锁帧时长行为）"))
        elif lock:
            out.append(("RISK", f"activeFormat {label} 档锁帧失败: {lock}"))
    cps = report.get("cameraProperties", [])
    if cps:
        lines = ", ".join(f"{c.get('position')}={c.get('width')}x{c.get('height')}@{c.get('activeMaxFPS')}fps"
                          for c in cps)
        out.append(("INFO", f"cameraProperties 遥测在场（Persona 同款上报口径）: {lines}"))
    else:
        out.append(("NA", "无 cameraProperties 遥测（旧版探针）"))
    rear = report.get("rearTorch")
    luma = report.get("lumaWindow_rear")
    if rear is None and luma is None:
        out.append(("NA", "无后置 torch 脉冲阶段（旧版探针或设备无后置）"))
        return out
    if isinstance(rear, dict) and rear.get("error"):
        out.append(("NA", f"后置 torch 阶段未运行: {rear['error']}"))
        return out
    if not isinstance(luma, dict) or luma.get("error"):
        why = report.get("noFramesAfter5s") and "零帧通道限制（jb 通道不投递帧）" or "无亮度样本"
        out.append(("NA", f"torch 亮度窗无样本: {luma.get('error') if isinstance(luma, dict) else '缺段'}（{why}）"))
        return out
    n, delta = luma.get("n", 0), luma.get("delta", 0)
    if abs(delta) < 2:
        out.append(("RISK", f"torch off→on→off 脉冲期间画面亮度无响应 Δ={delta}（n={n}）"
                            f"——检测点#5：注入画面未跟随 torch，是真机可测的强注入信号"))
    else:
        out.append(("PASS", f"torch 脉冲与画面亮度一致 Δ={delta}（n={n}）"))
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
    verdicts += analyze_extended(report)
    verdicts += analyze_persona_replica(report)

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
