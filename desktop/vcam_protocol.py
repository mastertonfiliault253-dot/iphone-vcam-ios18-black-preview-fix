"""Wire protocol shared by the OBS desktop bridge and its tests."""

from __future__ import annotations

import struct
import time

MAGIC = b"VCAM"
VERSION = 1
KIND_JPEG_VIDEO = 1
KIND_PCM_AUDIO = 2
HEADER = struct.Struct(">4sBBHQ")


def pack_packet(kind: int, payload: bytes, *, timestamp_us: int | None = None) -> bytes:
    if kind not in (KIND_JPEG_VIDEO, KIND_PCM_AUDIO):
        raise ValueError(f"unsupported packet kind: {kind}")
    if not payload:
        raise ValueError("payload must not be empty")
    timestamp = timestamp_us if timestamp_us is not None else time.monotonic_ns() // 1_000
    return HEADER.pack(MAGIC, VERSION, kind, 0, timestamp) + payload


def unpack_packet(packet: bytes) -> tuple[int, int, bytes]:
    if len(packet) <= HEADER.size:
        raise ValueError("packet is shorter than header plus payload")
    magic, version, kind, _flags, timestamp = HEADER.unpack_from(packet)
    if magic != MAGIC:
        raise ValueError("invalid magic")
    if version != VERSION:
        raise ValueError(f"unsupported protocol version: {version}")
    if kind not in (KIND_JPEG_VIDEO, KIND_PCM_AUDIO):
        raise ValueError(f"unsupported packet kind: {kind}")
    return kind, timestamp, packet[HEADER.size :]
