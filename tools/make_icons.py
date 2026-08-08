#!/usr/bin/env python3
"""Generate the icon set a Control4 universal minidriver needs.

Writes a rounded-square gradient tile at every size the driver.xml references.
Pure stdlib - there is no image library here, so the PNGs are encoded by hand.

These are placeholders, deliberately: they are a plain gradient rather than any
app's actual logo. Drop real artwork over them at the same paths and sizes if you
want the real mark in Navigator.

    python tools/make_icons.py driver/um_jellyfin/www --color1 AA5CC3 --color2 00A4DC
"""

from __future__ import annotations

import argparse
import struct
import zlib
from pathlib import Path

# (relative path, pixel size) - these are exactly what the driver.xml references.
ICONS = [
    ("icons/device_sm.png", 16),
    ("icons/device_lg.png", 32),
    ("icons/device/experience_70.png", 70),
    ("icons/device/experience_90.png", 90),
    ("icons/device/experience_300.png", 300),
    ("icons/device/experience_512.png", 512),
    ("icons/device/experience_1024.png", 1024),
]


def write_png(path: Path, width: int, height: int, pixels: bytearray) -> None:
    """Encode 8-bit RGBA. Each scanline is prefixed with filter type 0."""
    def chunk(kind: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))

    raw = b"".join(
        b"\x00" + bytes(pixels[y * width * 4:(y + 1) * width * 4])
        for y in range(height)
    )
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


def coverage(x: int, y: int, size: int, radius: float) -> float:
    """Rounded-square alpha, supersampled 3x3 so the corners are not jagged."""
    hits, samples = 0, 3
    for sy in range(samples):
        for sx in range(samples):
            px = x + (sx + 0.5) / samples
            py = y + (sy + 0.5) / samples
            # Distance outside the rounded rectangle's inner box.
            dx = max(radius - px, px - (size - radius), 0.0)
            dy = max(radius - py, py - (size - radius), 0.0)
            if dx * dx + dy * dy <= radius * radius:
                hits += 1
    return hits / (samples * samples)


def make_tile(size: int, c1: tuple[int, int, int], c2: tuple[int, int, int]) -> bytearray:
    radius = max(2.0, size * 0.22)
    pixels = bytearray(size * size * 4)
    span = max(1, (size - 1) * 2)

    for y in range(size):
        for x in range(size):
            t = (x + y) / span                       # diagonal gradient
            r = round(c1[0] + (c2[0] - c1[0]) * t)
            g = round(c1[1] + (c2[1] - c1[1]) * t)
            b = round(c1[2] + (c2[2] - c1[2]) * t)
            a = round(255 * coverage(x, y, size, radius))
            i = (y * size + x) * 4
            pixels[i:i + 4] = bytes((r, g, b, a))
    return pixels


def parse_hex(value: str) -> tuple[int, int, int]:
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))  # type: ignore[return-value]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("out", type=Path, help="the driver's www/ directory")
    parser.add_argument("--color1", default="AA5CC3", help="gradient start (hex)")
    parser.add_argument("--color2", default="00A4DC", help="gradient end (hex)")
    args = parser.parse_args()

    c1, c2 = parse_hex(args.color1), parse_hex(args.color2)

    for rel, size in ICONS:
        path = args.out / rel
        write_png(path, size, size, make_tile(size, c1, c2))
        print(f"  {rel:<40} {size}x{size}  {path.stat().st_size:,} bytes")


if __name__ == "__main__":
    main()
