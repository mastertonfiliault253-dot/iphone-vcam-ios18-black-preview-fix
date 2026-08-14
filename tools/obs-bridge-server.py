# -*- coding: utf-8 -*-
"""VCAM OBS-style frame bridge.

Pulls an RTSP stream with FFmpeg on the PC (hardware-accelerated where the
PC supports it), encodes frames to JPEG and pushes them over WebSocket using
the VCAMOBSStreamSource wire protocol:

    bytes[0..3]  "VCAM"
    bytes[4]     version = 1
    bytes[5]     kind = 1 (JPEG)
    bytes[6..15] reserved
    bytes[16..]  JPEG payload

Usage:
    python obs-bridge-server.py --rtsp rtsp://192.168.2.181:8554/live         --port 4455 [--size 720x1280] [--fps 30]
"""
import argparse
import asyncio
import os
import subprocess
import sys
import threading

import websockets

FFMPEG = os.environ.get(
    "VCAM_FFMPEG",
    r"D:\work\IOSVCAN-DS\vcam\tools\ffmpeg-win\ffmpeg-master-latest-win64-gpl\bin\ffmpeg.exe",
)

latest = {"data": None, "seq": 0}
stop_flag = threading.Event()


def ffmpeg_command(args):
    cmd = [
        FFMPEG,
        "-hide_banner",
        "-loglevel", "warning",
        "-rtsp_transport", "tcp",
        "-i", args.rtsp,
        "-an",
        "-vf", f"scale={args.size}",
        "-r", str(args.fps),
        "-f", "image2pipe",
        "-c:v", "mjpeg",
        "-q:v", str(args.quality),
        "pipe:1",
    ]
    return cmd


def read_jpegs(proc):
    """Parse the concatenated JPEG stream (FFD8 ... FFD9) from ffmpeg."""
    buf = bytearray()
    while not stop_flag.is_set():
        chunk = proc.stdout.read(64 * 1024)
        if not chunk:
            break
        buf.extend(chunk)
        while True:
            soi = buf.find(b"\xff\xd8")
            if soi < 0:
                # Keep only a small tail to avoid unbounded growth.
                if len(buf) > 1 << 20:
                    del buf[: max(0, len(buf) - 64)]
                break
            if soi > 0:
                del buf[:soi]
            eoi = buf.find(b"\xff\xd9", 2)
            if eoi < 0:
                break
            jpeg = bytes(buf[: eoi + 2])
            del buf[: eoi + 2]
            if len(jpeg) < 2048:
                continue
            latest["data"] = jpeg
            latest["seq"] += 1


def supervisor(args):
    """Keep the ffmpeg reader alive across stream failures."""
    while not stop_flag.is_set():
        try:
            proc = subprocess.Popen(ffmpeg_command(args), stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL)
            read_jpegs(proc)
            proc.kill()
        except Exception as exc:  # noqa: BLE001
            print(f"[bridge] ffmpeg error: {exc}", flush=True)
        if not stop_flag.is_set():
            print("[bridge] ffmpeg exited; restarting in 2s", flush=True)
            stop_flag.wait(2)


def vcam_packet(jpeg):
    header = b"VCAM" + bytes([1, 1]) + b"\x00" * 10
    return header + jpeg


async def handler(ws):
    peer = ws.remote_address
    print(f"[bridge] client connected: {peer}", flush=True)
    last_seq = -1
    try:
        while not stop_flag.is_set():
            if latest["seq"] != last_seq and latest["data"] is not None:
                last_seq = latest["seq"]
                await ws.send(vcam_packet(latest["data"]))
            await asyncio.sleep(0.016)
    except websockets.exceptions.ConnectionClosed:
        pass
    finally:
        print(f"[bridge] client disconnected: {peer}", flush=True)


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rtsp", default="rtsp://192.168.2.181:8554/live")
    parser.add_argument("--port", type=int, default=4455)
    parser.add_argument("--size", default="720x1280")
    parser.add_argument("--fps", type=int, default=30)
    parser.add_argument("--quality", type=int, default=5)
    args = parser.parse_args()

    thread = threading.Thread(target=supervisor, args=(args,), daemon=True)
    thread.start()
    print(f"[bridge] serving ws://0.0.0.0:{args.port} rtsp={args.rtsp} "
          f"size={args.size} fps={args.fps}", flush=True)
    async with websockets.serve(handler, "0.0.0.0", args.port, max_size=8 << 20):
        await asyncio.Future()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        stop_flag.set()
        sys.exit(0)
