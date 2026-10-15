#!/usr/bin/env python3
"""Print real EMODnet depth checks at representative Øresund locations."""

from __future__ import annotations

import json
import math
import struct
import datetime as dt
from pathlib import Path

from build_bathymetry import GRID_META_PATH, GRID_PATH, INVALID_DEPTH_DM, parse_georeference_origin, geodetic_to_local


ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "docs/BATHYMETRY_SAMPLE_CHECKS.json"
SAMPLES = (
    ("Malmo_start_water", 55.60587, 12.96300),
    ("Oresund_open_water", 55.70000, 12.75000),
    ("Copenhagen_side_water", 55.70000, 12.60000),
    ("Malmo_coastal_approach", 55.60587, 12.97000),
    ("Outside_region_and_data", 56.12000, 13.23000),
)


def nearest_coastline_distance(east: float, north: float, segments: list[tuple[tuple[float, float], tuple[float, float]]]) -> float | None:
    nearest = math.inf
    for a, b in segments:
        dx, dy = b[0] - a[0], b[1] - a[1]
        length_sq = dx * dx + dy * dy
        t = 0.0 if length_sq <= 1e-12 else max(0.0, min(1.0, ((east - a[0]) * dx + (north - a[1]) * dy) / length_sq))
        nearest = min(nearest, math.hypot(east - a[0] - t * dx, north - a[1] - t * dy))
    return None if math.isinf(nearest) else nearest


def load_coastline_geometry() -> tuple[list[tuple[tuple[float, float], tuple[float, float]]], dict]:
    features_path = ROOT / "assets/geodata/processed/bathymetry/chart_features.json"
    segments: list[tuple[tuple[float, float], tuple[float, float]]] = []
    if features_path.is_file():
        features = json.loads(features_path.read_text(encoding="utf-8"))
        for line in features.get("coastlines_east_north_m", []):
            points = [(float(point[0]), float(point[1])) for point in line]
            segments.extend(zip(points, points[1:]))
    land_mask = {}
    manifest_path = ROOT / "assets/geodata/processed/bathymetry/manifest.json"
    if manifest_path.is_file():
        land_mask = json.loads(manifest_path.read_text(encoding="utf-8")).get("land_mask", {})
    return segments, land_mask


def sample_osm_land_mask(east: float, north: float, mask_meta: dict) -> bool | None:
    mask_path = ROOT / "assets/geodata/processed/bathymetry/land_mask.png"
    if not mask_meta or not mask_path.is_file():
        return None
    try:
        from PIL import Image
    except ImportError:
        return None
    bounds = mask_meta["bounds_east_north_m"]
    min_east, min_north, max_east, max_north = map(float, bounds)
    if not (min_east <= east < max_east and min_north <= north < max_north):
        return None
    cell = float(mask_meta["cell_size_m"])
    with Image.open(mask_path) as image:
        x = max(0, min(image.width - 1, int((east - min_east) / cell)))
        y = max(0, min(image.height - 1, int((max_north - north) / cell)))
        return image.convert("L").getpixel((x, y)) >= 128


def sample_depth(metadata: dict, data: bytes, latitude: float, longitude: float) -> dict:
    rows = int(metadata["rows"])
    columns = int(metadata["columns"])
    x = (longitude - float(metadata["west_longitude_deg"])) / float(metadata["longitude_step_deg"])
    y = (latitude - float(metadata["south_latitude_deg"])) / float(metadata["latitude_step_deg"])
    if x < 0.0 or y < 0.0 or x > columns - 1 or y > rows - 1:
        return {"valid": False, "reason": "Outside source grid"}
    x0 = min(int(math.floor(x)), columns - 2)
    y0 = min(int(math.floor(y)), rows - 2)
    tx, ty = max(0.0, min(1.0, x - x0)), max(0.0, min(1.0, y - y0))
    cells = []
    for column, row in ((x0, y0), (x0 + 1, y0), (x0 + 1, y0 + 1), (x0, y0 + 1)):
        offset = (row * columns + column) * 4
        depth_dm, interpolated, count = struct.unpack_from("<hBB", data, offset)
        if depth_dm == INVALID_DEPTH_DM:
            return {"valid": False, "reason": "Land, above LAT, or no-data cell in the bilinear neighbourhood"}
        cells.append((depth_dm / 10.0, interpolated == 1, count if count != 255 else None))
    south = cells[0][0] * (1.0 - tx) + cells[1][0] * tx
    north = cells[3][0] * (1.0 - tx) + cells[2][0] * tx
    counts = [cell[2] for cell in cells]
    return {
        "valid": True,
        "depth_m": south * (1.0 - ty) + north * ty,
        "interpolated": any(cell[1] for cell in cells),
        "quality_min_value_count": min(counts) if all(value is not None for value in counts) else None,
    }


def sample_gpu_texture(metadata: dict, data: bytes, latitude: float, longitude: float, origin: tuple[float, float, float]) -> dict:
    texture_meta = metadata.get("gpu_depth_texture", {})
    if not texture_meta:
        return {"valid_coverage": 0.0, "reason": "No GPU depth texture was generated"}
    width = int(texture_meta["width"])
    height = int(texture_meta["height"])
    bounds = list(map(float, texture_meta["bounds_east_north_m"]))
    min_east, min_north, max_east, max_north = bounds
    east, north = geodetic_to_local(latitude, longitude, origin)
    u = (east - min_east) / (max_east - min_east)
    v = (max_north - north) / (max_north - min_north)
    if u < 0.0 or v < 0.0 or u > 1.0 or v > 1.0:
        return {"valid_coverage": 0.0, "reason": "Outside GPU texture bounds"}

    texel_x = u * width - 0.5
    texel_y = v * height - 0.5
    floor_x, floor_y = math.floor(texel_x), math.floor(texel_y)
    tx, ty = texel_x - floor_x, texel_y - floor_y
    x0, x1 = max(0, min(width - 1, floor_x)), max(0, min(width - 1, floor_x + 1))
    y0, y1 = max(0, min(height - 1, floor_y)), max(0, min(height - 1, floor_y + 1))

    def read_channel(x: int, y: int, channel: int) -> float:
        return float(data[(y * width + x) * 2 + channel]) / 255.0

    def bilinear(channel: int) -> float:
        top = read_channel(x0, y0, channel) * (1.0 - tx) + read_channel(x1, y0, channel) * tx
        bottom = read_channel(x0, y1, channel) * (1.0 - tx) + read_channel(x1, y1, channel) * tx
        return top * (1.0 - ty) + bottom * ty

    depth_m = bilinear(0) * 64.0
    valid_coverage = bilinear(1)
    coverage_t = max(0.0, min(1.0, (valid_coverage - 0.20) / (0.80 - 0.20)))
    tint_weight = coverage_t * coverage_t * (3.0 - 2.0 * coverage_t)
    return {
        "depth_m": depth_m,
        "valid_coverage": valid_coverage,
        "tint_weight": tint_weight,
        "valid": valid_coverage > 0.0,
        "full_coverage": valid_coverage >= 0.98,
    }


def main() -> int:
    origin = parse_georeference_origin()
    coast_segments, land_mask_meta = load_coastline_geometry()
    if not GRID_META_PATH.is_file() or not GRID_PATH.is_file():
        samples = []
        for name, latitude, longitude in SAMPLES:
            east, north = geodetic_to_local(latitude, longitude, origin)
            samples.append({
                "name": name,
                "latitude_deg": latitude,
                "longitude_deg": longitude,
                "godot_world_east_up_south_m": [round(east, 2), 0.0, round(-north, 2)],
                "osm_land_mask": sample_osm_land_mask(east, north, land_mask_meta),
                "nearest_osm_coastline_m": nearest_coastline_distance(east, north, coast_segments),
                "valid": None,
                "depth_m": None,
            })
        report = {
            "status": "not_run",
            "reason": "The real EMODnet regional NetCDF has not been downloaded and processed.",
            "source_required": "EMODnet Bathymetry DTM 2024 · bathymetry_dtm_2024",
            "samples": samples,
        }
        OUTPUT.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(json.dumps(report, indent=2, ensure_ascii=False))
        return 2
    metadata = json.loads(GRID_META_PATH.read_text(encoding="utf-8"))
    data = GRID_PATH.read_bytes()
    texture_meta = metadata.get("gpu_depth_texture", {})
    texture_path = GRID_META_PATH.parent / str(texture_meta.get("file", ""))
    texture_data = texture_path.read_bytes() if texture_meta and texture_path.is_file() else b""
    output_samples = []
    for name, latitude, longitude in SAMPLES:
        east, north = geodetic_to_local(latitude, longitude, origin)
        sample = sample_depth(metadata, data, latitude, longitude)
        texture_sample = sample_gpu_texture(metadata, texture_data, latitude, longitude, origin) if texture_data else {"valid_coverage": 0.0, "reason": "GPU texture file is missing"}
        if bool(sample.get("valid", False)) and float(texture_sample.get("valid_coverage", 0.0)) > 0.0:
            texture_sample["source_depth_error_m"] = float(texture_sample["depth_m"]) - float(sample["depth_m"])
        output_samples.append({
            "name": name,
            "latitude_deg": latitude,
            "longitude_deg": longitude,
            "godot_world_east_up_south_m": [round(east, 2), 0.0, round(-north, 2)],
            "osm_land_mask": sample_osm_land_mask(east, north, land_mask_meta),
            "nearest_osm_coastline_m": nearest_coastline_distance(east, north, coast_segments),
            **sample,
            "gpu_texture_sample": texture_sample,
            "source": metadata.get("source"),
            "vertical_datum": metadata.get("vertical_datum"),
        })
    report = {
        "status": "complete",
        "checked_at_utc": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat(),
        "source": metadata.get("source"),
        "gpu_texture": metadata.get("gpu_depth_texture", {}),
        "samples": output_samples,
    }
    OUTPUT.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
