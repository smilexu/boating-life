#!/usr/bin/env python3
"""Fetch cached Mapzen/Terrarium elevation tiles for the configured Oresund region."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from PIL import Image


PROJECT_ROOT = Path(__file__).resolve().parents[2]
REGION_PATH = PROJECT_ROOT / "assets/geodata/processed/oresund_region.json"
GEOREFERENCE_PATH = PROJECT_ROOT / "resources/oresund_georeference.tres"
TILE_ROOT = PROJECT_ROOT / "assets/terrain/source"
MANIFEST_PATH = TILE_ROOT / "download_manifest.json"
URL_TEMPLATE = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"


def read_georeference() -> dict[str, float]:
    if not GEOREFERENCE_PATH.is_file():
        raise RuntimeError(f"Missing Task 7 GeoReference resource: {GEOREFERENCE_PATH}")
    text = GEOREFERENCE_PATH.read_text(encoding="utf-8")
    field_names = (
        "origin_latitude_deg",
        "origin_longitude_deg",
        "origin_altitude_m",
        "south_latitude_deg",
        "north_latitude_deg",
        "west_longitude_deg",
        "east_longitude_deg",
    )
    result: dict[str, float] = {}
    for field_name in field_names:
        match = re.search(rf"(?m)^{field_name}\s*=\s*([-+0-9.eE]+)\s*$", text)
        if match is None:
            raise RuntimeError(f"GeoReference resource is missing {field_name}")
        result[field_name] = float(match.group(1))
    return result


def read_bounds() -> tuple[float, float, float, float]:
    if not REGION_PATH.is_file():
        raise RuntimeError(f"Missing Task 7 region data: {REGION_PATH}")
    data = json.loads(REGION_PATH.read_text(encoding="utf-8"))
    data_bounds = data.get("wgs84_bounds")
    if not isinstance(data_bounds, list) or len(data_bounds) != 4:
        raise RuntimeError("Task 7 region data does not contain WGS84 bounds")
    georeference = read_georeference()
    bounds = (
        georeference["west_longitude_deg"],
        georeference["south_latitude_deg"],
        georeference["east_longitude_deg"],
        georeference["north_latitude_deg"],
    )
    if any(abs(float(data_bounds[index]) - bounds[index]) > 1e-6 for index in range(4)):
        raise RuntimeError("Task 7 coastline data bounds differ from resources/oresund_georeference.tres; rebuild Task 7 data first")
    west, south, east, north = bounds
    return west, south, east, north


def longitude_to_tile_x(longitude: float, zoom: int) -> int:
    return min((1 << zoom) - 1, max(0, int((longitude + 180.0) / 360.0 * (1 << zoom))))


def latitude_to_tile_y(latitude: float, zoom: int) -> int:
    import math

    clamped = max(-85.05112878, min(85.05112878, latitude))
    value = (1.0 - math.asinh(math.tan(math.radians(clamped))) / math.pi) * 0.5 * (1 << zoom)
    return min((1 << zoom) - 1, max(0, int(value)))


def tile_coordinates(bounds: tuple[float, float, float, float], zoom: int) -> list[tuple[int, int, int]]:
    west, south, east, north = bounds
    x_min = longitude_to_tile_x(west, zoom)
    x_max = longitude_to_tile_x(east, zoom)
    y_min = latitude_to_tile_y(north, zoom)
    y_max = latitude_to_tile_y(south, zoom)
    return [(zoom, x, y) for y in range(y_min, y_max + 1) for x in range(x_min, x_max + 1)]


def tile_path(zoom: int, x: int, y: int) -> Path:
    return TILE_ROOT / str(zoom) / str(x) / f"{y}.png"


def validate_png(payload: bytes) -> tuple[int, int, str]:
    with Image.open(io.BytesIO(payload)) as image:
        image.verify()
    with Image.open(io.BytesIO(payload)) as image:
        if image.size != (256, 256):
            raise ValueError(f"expected 256x256 tile, received {image.size}")
        if image.mode not in ("RGB", "RGBA"):
            raise ValueError(f"expected raw RGB/RGBA PNG, received mode {image.mode}")
        return image.width, image.height, image.mode


def fetch_tile(zoom: int, x: int, y: int) -> tuple[str, str | None]:
    destination = tile_path(zoom, x, y)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_file():
        try:
            payload = destination.read_bytes()
            validate_png(payload)
            return "cached", hashlib.sha256(payload).hexdigest()
        except (OSError, ValueError) as error:
            print(f"Invalid cached tile {zoom}/{x}/{y}: {error}; downloading again", file=sys.stderr)
            destination.unlink(missing_ok=True)

    url = URL_TEMPLATE.format(z=zoom, x=x, y=y)
    last_error: Exception | None = None
    for attempt in range(3):
        try:
            temporary_path = destination.with_suffix(".png.part")
            curl = shutil.which("curl")
            if curl:
                completed = subprocess.run(
                    [curl, "-fL", "--silent", "--show-error", "--connect-timeout", "15", "--max-time", "60", url, "-o", str(temporary_path)],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                if completed.returncode != 0:
                    raise RuntimeError(completed.stderr.strip() or f"curl exited {completed.returncode}")
                payload = temporary_path.read_bytes()
            else:
                request = Request(url, headers={"User-Agent": "SeaPrototype-TerrainBuilder/1.0"})
                with urlopen(request, timeout=45) as response:
                    payload = response.read()
            validate_png(payload)
            if not curl:
                temporary_path.write_bytes(payload)
            temporary_path.replace(destination)
            return "downloaded", hashlib.sha256(payload).hexdigest()
        except (HTTPError, URLError, TimeoutError, OSError, ValueError, RuntimeError) as error:
            last_error = error
            destination.with_suffix(".png.part").unlink(missing_ok=True)
            if attempt < 2:
                delay = 2 ** attempt
                print(f"Tile {zoom}/{x}/{y} failed ({error}); retrying in {delay}s", file=sys.stderr)
                time.sleep(delay)
    return "failed", str(last_error)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zoom", type=int, default=11, help="XYZ zoom level (default: 11)")
    parser.add_argument("--max-tiles", type=int, default=80, help="Fail before download if coverage exceeds this tile count")
    args = parser.parse_args()
    if not 0 <= args.zoom <= 15:
        parser.error("--zoom must be between 0 and 15")

    try:
        bounds = read_bounds()
        tiles = tile_coordinates(bounds, args.zoom)
        if len(tiles) > args.max_tiles:
            raise RuntimeError(
                f"Region requires {len(tiles)} tiles at z={args.zoom}, above --max-tiles={args.max_tiles}; "
                "use z=11 or raise the explicit limit after reviewing the request count"
            )
        print(f"Region WGS84: west={bounds[0]}, south={bounds[1]}, east={bounds[2]}, north={bounds[3]}")
        print(f"XYZ z={args.zoom}, tile count={len(tiles)}, x={min(t[1] for t in tiles)}..{max(t[1] for t in tiles)}, y={min(t[2] for t in tiles)}..{max(t[2] for t in tiles)}")

        entries: list[dict[str, object]] = []
        downloaded = cached = 0
        failures: list[dict[str, object]] = []
        not_attempted: list[dict[str, int]] = []
        consecutive_failures = 0
        for tile_index, (zoom, x, y) in enumerate(tiles):
            status, detail = fetch_tile(zoom, x, y)
            if status == "downloaded":
                downloaded += 1
                consecutive_failures = 0
                entries.append({"z": zoom, "x": x, "y": y, "status": status, "sha256": detail})
            elif status == "cached":
                cached += 1
                consecutive_failures = 0
                entries.append({"z": zoom, "x": x, "y": y, "status": status, "sha256": detail})
            else:
                consecutive_failures += 1
                failures.append({"z": zoom, "x": x, "y": y, "error": detail})
                print(f"FAILED {zoom}/{x}/{y}: {detail}", file=sys.stderr)
                if consecutive_failures >= 3:
                    not_attempted = [{"z": z, "x": tile_x, "y": tile_y} for z, tile_x, tile_y in tiles[tile_index + 1 :]]
                    print(f"Stopping after {consecutive_failures} consecutive failures; {len(not_attempted)} tiles were not attempted.", file=sys.stderr)
                    break

        MANIFEST_PATH.parent.mkdir(parents=True, exist_ok=True)
        manifest = {
            "source": "Mapzen Terrain Tiles / Tilezen Terrarium PNG on AWS Open Data",
            "url_template": URL_TEMPLATE,
            "accessed_at_utc": datetime.now(timezone.utc).isoformat(),
            "wgs84_bounds": {"west": bounds[0], "south": bounds[1], "east": bounds[2], "north": bounds[3]},
            "zoom": args.zoom,
            "tile_count_expected": len(tiles),
            "tile_count_downloaded_this_run": downloaded,
            "tile_count_valid_cached": cached,
            "tile_count_failed": len(failures),
            "tile_count_not_attempted": len(not_attempted),
            "tiles": entries,
            "failures": failures,
            "not_attempted": not_attempted,
        }
        MANIFEST_PATH.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
        print(f"Download summary: new={downloaded}, cached={cached}, failed={len(failures)}, not_attempted={len(not_attempted)}, total={len(tiles)}")
        print(f"Tile cache manifest: {MANIFEST_PATH.relative_to(PROJECT_ROOT)}")
        return 1 if failures else 0
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
