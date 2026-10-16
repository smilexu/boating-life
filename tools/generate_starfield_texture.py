#!/usr/bin/env python3
"""Generate the deterministic, sparse equirectangular star field used by sea_sky.gdshader."""

from __future__ import annotations

import math
import random
import struct
import zlib
from pathlib import Path


WIDTH = 2048
HEIGHT = 1024
SEED = 20261016
OUTPUT = Path(__file__).resolve().parents[1] / "assets" / "sky" / "stars_equirectangular.png"


def _chunk(kind: bytes, data: bytes) -> bytes:
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def main() -> None:
    rng = random.Random(SEED)
    pixels = bytearray(WIDTH * HEIGHT)
    # A sparse spherical distribution avoids a visible grid or repeated tile.
    for index in range(560):
        longitude = rng.random()
        sin_latitude = rng.uniform(-1.0, 1.0)
        latitude = math.asin(sin_latitude) / math.pi + 0.5
        center_x = int(longitude * WIDTH) % WIDTH
        center_y = min(HEIGHT - 1, max(0, int(latitude * HEIGHT)))
        sigma = rng.uniform(0.32, 0.78)
        brightness = rng.uniform(66.0, 190.0)
        if index < 24:
            sigma *= 1.35
            # Keep the same sparse bright-star cohort, with stronger separation
            # from ordinary stars instead of adding more points.
            brightness = rng.uniform(205.0, 255.0)
        radius = max(1, int(math.ceil(sigma * 2.6)))
        for offset_y in range(-radius, radius + 1):
            y = center_y + offset_y
            if y < 0 or y >= HEIGHT:
                continue
            for offset_x in range(-radius, radius + 1):
                x = (center_x + offset_x) % WIDTH
                distance_squared = float(offset_x * offset_x + offset_y * offset_y)
                if distance_squared > radius * radius:
                    continue
                sample = int(brightness * math.exp(-0.5 * distance_squared / (sigma * sigma)))
                pixel_index = y * WIDTH + x
                pixels[pixel_index] = max(pixels[pixel_index], min(255, sample))

    raw = b"".join(b"\x00" + pixels[y * WIDTH : (y + 1) * WIDTH] for y in range(HEIGHT))
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    png = b"\x89PNG\r\n\x1a\n"
    png += _chunk(b"IHDR", struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 0, 0, 0, 0))
    png += _chunk(b"IDAT", zlib.compress(raw, 9))
    png += _chunk(b"IEND", b"")
    OUTPUT.write_bytes(png)
    print(f"Wrote {OUTPUT} ({WIDTH}x{HEIGHT}, R8, seed={SEED})")


if __name__ == "__main__":
    main()
