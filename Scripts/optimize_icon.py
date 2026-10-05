#!/usr/bin/env python3
"""Recompress embedded PNG streams without changing pixels or icon variants."""
import struct
import sys
import zlib
from pathlib import Path


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def optimize_png(png):
    parts = []
    offset = 8
    while offset < len(png):
        length = struct.unpack_from(">I", png, offset)[0]
        kind = png[offset + 4:offset + 8]
        data = png[offset + 8:offset + 8 + length]
        parts.append((kind, data))
        offset += length + 12
    original = b"".join(data for kind, data in parts if kind == b"IDAT")
    compressed = zlib.compress(zlib.decompress(original), level=9)
    if len(compressed) >= len(original):
        return png
    result = bytearray(png[:8])
    wrote_data = False
    for kind, data in parts:
        if kind == b"IDAT":
            if wrote_data:
                continue
            data = compressed
            wrote_data = True
        result.extend(chunk(kind, data))
    return bytes(result)


def optimize_icns(icon):
    if icon[:4] != b"icns" or struct.unpack_from(">I", icon, 4)[0] != len(icon):
        raise ValueError("Invalid ICNS container")
    result = bytearray()
    offset = 8
    while offset < len(icon):
        kind = icon[offset:offset + 4]
        length = struct.unpack_from(">I", icon, offset + 4)[0]
        if length < 8 or offset + length > len(icon):
            raise ValueError("Invalid ICNS chunk")
        data = icon[offset + 8:offset + length]
        if data.startswith(b"\x89PNG\r\n\x1a\n"):
            data = optimize_png(data)
        result.extend(kind + struct.pack(">I", len(data) + 8) + data)
        offset += length
    return b"icns" + struct.pack(">I", len(result) + 8) + result


if __name__ == "__main__":
    path = Path(sys.argv[1])
    original = path.read_bytes()
    optimized = optimize_icns(original)
    path.write_bytes(optimized)
    print(f"ICNS: {len(original)} -> {len(optimized)} bytes (lossless)")
