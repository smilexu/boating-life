#!/usr/bin/env python3
"""Build compact local bathymetry and chart features from EMODnet DTM 2024."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parents[2]
REGION_JSON = ROOT / "assets/geodata/processed/oresund_region.json"
GEOREFERENCE_TRES = ROOT / "resources/oresund_georeference.tres"
OSM_DIR = ROOT / "assets/geodata/source"
NETCDF_PATH = OSM_DIR / "emodnet_bathymetry_2024_oresund.nc"
OUTPUT_DIR = ROOT / "assets/geodata/processed/bathymetry"
GRID_PATH = OUTPUT_DIR / "depth_grid.bin"
GRID_META_PATH = OUTPUT_DIR / "grid_metadata.json"
DEPTH_TEXTURE_PATH = OUTPUT_DIR / "depth_texture.rg8"
FEATURES_PATH = OUTPUT_DIR / "chart_features.json"
LAND_MASK_PATH = OUTPUT_DIR / "land_mask.png"
MANIFEST_PATH = OUTPUT_DIR / "manifest.json"
DOWNLOAD_MANIFEST_PATH = OSM_DIR / "emodnet_bathymetry_download.json"
SOURCE_URL = "https://erddap.emodnet.eu/erddap/griddap/bathymetry_dtm_2024.nc"
CONTOUR_LEVELS_M = (2.0, 5.0, 10.0, 20.0)
LAND_MASK_CELL_M = 30.0
INVALID_DEPTH_DM = -32768


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def parse_georeference_origin() -> tuple[float, float, float]:
    text = GEOREFERENCE_TRES.read_text(encoding="utf-8")
    values: dict[str, float] = {}
    for name in ("origin_latitude_deg", "origin_longitude_deg", "origin_altitude_m"):
        match = re.search(rf"^{name}\s*=\s*(-?[0-9.]+)", text, flags=re.MULTILINE)
        if match is None:
            raise RuntimeError(f"Could not read {name} from {GEOREFERENCE_TRES}")
        values[name] = float(match.group(1))
    return values["origin_latitude_deg"], values["origin_longitude_deg"], values["origin_altitude_m"]


def geodetic_to_local(latitude_deg: float, longitude_deg: float, origin: tuple[float, float, float]) -> tuple[float, float]:
    """Mirror GeoReference.geodetic_to_world() and return (east, north) metres."""
    a = 6378137.0
    f = 1.0 / 298.257223563
    e2 = f * (2.0 - f)

    def ecef(latitude: float, longitude: float, altitude: float) -> tuple[float, float, float]:
        phi = math.radians(latitude)
        lam = math.radians(longitude)
        sp, cp = math.sin(phi), math.cos(phi)
        n = a / math.sqrt(1.0 - e2 * sp * sp)
        return ((n + altitude) * cp * math.cos(lam), (n + altitude) * cp * math.sin(lam), (n * (1.0 - e2) + altitude) * sp)

    lat0, lon0, alt0 = origin
    px, py, pz = ecef(latitude_deg, longitude_deg, 0.0)
    ox, oy, oz = ecef(lat0, lon0, alt0)
    dx, dy, dz = px - ox, py - oy, pz - oz
    lat0_rad, lon0_rad = math.radians(lat0), math.radians(lon0)
    east = -math.sin(lon0_rad) * dx + math.cos(lon0_rad) * dy
    north = (
        -math.sin(lat0_rad) * math.cos(lon0_rad) * dx
        - math.sin(lat0_rad) * math.sin(lon0_rad) * dy
        + math.cos(lat0_rad) * dz
    )
    return east, north


def local_to_geodetic_arrays(east, north, origin: tuple[float, float, float]):
    """Vectorized inverse of GeoReference.world_to_geodetic() for the texture bake."""
    import numpy as np

    a = 6378137.0
    f = 1.0 / 298.257223563
    e2 = f * (2.0 - f)
    lat0 = math.radians(origin[0])
    lon0 = math.radians(origin[1])
    alt0 = origin[2]

    def ecef(latitude: float, longitude: float, altitude: float) -> tuple[float, float, float]:
        sin_lat = math.sin(latitude)
        cos_lat = math.cos(latitude)
        radius = a / math.sqrt(1.0 - e2 * sin_lat * sin_lat)
        return (
            (radius + altitude) * cos_lat * math.cos(longitude),
            (radius + altitude) * cos_lat * math.sin(longitude),
            (radius * (1.0 - e2) + altitude) * sin_lat,
        )

    ox, oy, oz = ecef(lat0, lon0, alt0)
    sin_lat0, cos_lat0 = math.sin(lat0), math.cos(lat0)
    sin_lon0, cos_lon0 = math.sin(lon0), math.cos(lon0)
    x = ox - sin_lon0 * east - sin_lat0 * cos_lon0 * north
    y = oy + cos_lon0 * east - sin_lat0 * sin_lon0 * north
    z = oz + cos_lat0 * north
    longitude = np.arctan2(y, x)
    horizontal = np.sqrt(x * x + y * y)
    latitude = np.arctan2(z, horizontal * (1.0 - e2))
    altitude = np.zeros_like(latitude)
    for _iteration in range(8):
        sin_lat = np.sin(latitude)
        cos_lat = np.cos(latitude)
        radius = a / np.sqrt(1.0 - e2 * sin_lat * sin_lat)
        altitude = horizontal / np.maximum(np.abs(cos_lat), 0.000001) - radius
        denominator = radius + altitude
        latitude = np.arctan2(z, horizontal * (1.0 - e2 * radius / denominator))
    return np.rad2deg(latitude), np.rad2deg(longitude)


def build_depth_texture(depth_dm, valid, interpolation_byte, latitude, longitude, origin, land_mask_meta) -> dict:
    """Bake the real grid into a world-aligned, linearly-filterable RG8 texture."""
    import numpy as np
    from PIL import Image

    source_rows, source_columns = depth_dm.shape
    lat_step = float(latitude[1] - latitude[0])
    lon_step = float(longitude[1] - longitude[0])
    land_mask_path = OUTPUT_DIR / str(land_mask_meta.get("file", "land_mask.png"))
    if not land_mask_path.is_file() or not land_mask_meta:
        raise RuntimeError("The OSM land mask is required to build the GPU depth texture")
    mask_image = np.asarray(Image.open(land_mask_path).convert("L"), dtype=np.uint8)
    texture_height, texture_width = mask_image.shape
    mask_min_east, mask_min_north, mask_max_east, mask_max_north = map(float, land_mask_meta["bounds_east_north_m"])
    mask_cell_m = float(land_mask_meta.get("cell_size_m", LAND_MASK_CELL_M))
    # Reuse the native 30 m OSM mask grid. Depth is only resampled from EMODnet;
    # the finer texels prevent valid nearshore water being erased by a coarse mask.
    min_east = mask_min_east
    max_east = mask_min_east + texture_width * mask_cell_m
    max_north = mask_max_north
    min_north = mask_max_north - texture_height * mask_cell_m

    east_values = min_east + (np.arange(texture_width, dtype=np.float64) + 0.5) * mask_cell_m
    north_values = max_north - (np.arange(texture_height, dtype=np.float64) + 0.5) * mask_cell_m
    east_grid, north_grid = np.meshgrid(east_values, north_values)
    sample_latitude, sample_longitude = local_to_geodetic_arrays(east_grid, north_grid, origin)
    fx = (sample_longitude - float(longitude[0])) / lon_step
    fy = (sample_latitude - float(latitude[0])) / lat_step
    inside = (fx >= 0.0) & (fy >= 0.0) & (fx <= source_columns - 1) & (fy <= source_rows - 1)
    x0 = np.clip(np.floor(fx).astype(np.int32), 0, source_columns - 2)
    y0 = np.clip(np.floor(fy).astype(np.int32), 0, source_rows - 2)
    tx = np.clip(fx - x0, 0.0, 1.0)
    ty = np.clip(fy - y0, 0.0, 1.0)
    source_valid = (
        valid[y0, x0]
        & valid[y0, x0 + 1]
        & valid[y0 + 1, x0 + 1]
        & valid[y0 + 1, x0]
    )
    depth_south = depth_dm[y0, x0] * (1.0 - tx) + depth_dm[y0, x0 + 1] * tx
    depth_north = depth_dm[y0 + 1, x0] * (1.0 - tx) + depth_dm[y0 + 1, x0 + 1] * tx
    sampled_depth_dm = depth_south * (1.0 - ty) + depth_north * ty
    source_interpolated = (
        (interpolation_byte[y0, x0] == 1)
        | (interpolation_byte[y0, x0 + 1] == 1)
        | (interpolation_byte[y0 + 1, x0 + 1] == 1)
        | (interpolation_byte[y0 + 1, x0] == 1)
    )

    land_mask = mask_image >= 128
    texture_valid = inside & source_valid & ~land_mask
    # RG8: R stores 0–64 m depth (about 0.25 m steps), G stores valid-water coverage.
    # The validity channel always controls whether color is applied. For the
    # depth channel, fill one texel around valid water from adjacent water depths
    # so linear filtering at a coast does not average shallow water toward 64 m.
    depth_m = np.clip(sampled_depth_dm.astype(np.float64) * 0.1, 0.0, 64.0)
    source_depth_m = depth_m.copy()
    depth_m[~texture_valid] = 64.0
    padded_depth = np.pad(source_depth_m, 1, mode="constant", constant_values=64.0)
    padded_valid = np.pad(texture_valid, 1, mode="constant", constant_values=False)
    neighbor_depth_sum = np.zeros((texture_height, texture_width), dtype=np.float64)
    neighbor_valid_count = np.zeros((texture_height, texture_width), dtype=np.uint8)
    for offset_y in (-1, 0, 1):
        for offset_x in (-1, 0, 1):
            if offset_x == 0 and offset_y == 0:
                continue
            neighbor_slice = (
                slice(1 + offset_y, 1 + offset_y + texture_height),
                slice(1 + offset_x, 1 + offset_x + texture_width),
            )
            neighbor_is_valid = padded_valid[neighbor_slice]
            neighbor_depth_sum += np.where(neighbor_is_valid, padded_depth[neighbor_slice], 0.0)
            neighbor_valid_count += neighbor_is_valid.astype(np.uint8)
    edge_fill = ~texture_valid & (neighbor_valid_count > 0)
    depth_m[edge_fill] = neighbor_depth_sum[edge_fill] / neighbor_valid_count[edge_fill]
    texture = np.empty((texture_height, texture_width, 2), dtype=np.uint8)
    texture[:, :, 0] = np.rint(depth_m * (255.0 / 64.0)).astype(np.uint8)
    texture[:, :, 1] = np.where(texture_valid, 255, 0).astype(np.uint8)
    DEPTH_TEXTURE_PATH.write_bytes(texture.tobytes(order="C"))

    return {
        "file": DEPTH_TEXTURE_PATH.name,
        "format": "raw RG8",
        "width": texture_width,
        "height": texture_height,
        "cell_size_m": mask_cell_m,
        "channels": {
            "R": "positive depth metres mapped to 0–64 m (about 0.25 m per code value)",
            "G": "valid water coverage; 255 valid, 0 land/no-data/outside coverage",
        },
        "filtering": "GPU linear filtering; validity channel gates tint, and one invalid texel adjacent to water carries neighboring depth only to avoid coast interpolation bias",
        "bounds_east_north_m": [min_east, min_north, max_east, max_north],
        "bytes": DEPTH_TEXTURE_PATH.stat().st_size,
        "valid_texture_cells": int(np.count_nonzero(texture_valid)),
        "masked_osm_land_cells": int(np.count_nonzero(land_mask)),
        "source_interpolated_cells": int(np.count_nonzero(texture_valid & source_interpolated)),
    }


def build_land_mask(region: dict) -> dict:
    try:
        from PIL import Image, ImageDraw
    except ImportError as error:
        raise RuntimeError("Missing Pillow. Install with: .venv/bin/pip install -r tools/requirements-bathymetry.txt") from error

    lods = region.get("lods", [])
    if not lods:
        raise RuntimeError("Processed coastline JSON contains no land mesh LODs")
    lod = lods[0]
    vertices = lod.get("vertices_east_north_m", [])
    indices = lod.get("indices", [])
    if not vertices or len(indices) < 3:
        raise RuntimeError("Processed coastline LOD 0 is empty")
    min_e, min_n, max_e, max_n = map(float, region["bounds_east_north_m"])
    width = math.ceil((max_e - min_e) / LAND_MASK_CELL_M)
    height = math.ceil((max_n - min_n) / LAND_MASK_CELL_M)
    image = Image.new("L", (width, height), 0)
    draw = ImageDraw.Draw(image)
    for offset in range(0, len(indices), 3):
        points = []
        for index in indices[offset:offset + 3]:
            east, north = vertices[int(index)]
            px = (float(east) - min_e) / LAND_MASK_CELL_M
            py = (max_n - float(north)) / LAND_MASK_CELL_M
            points.append((px, py))
        draw.polygon(points, fill=255)
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    image.save(LAND_MASK_PATH, optimize=True)
    return {
        "file": LAND_MASK_PATH.name,
        "width": width,
        "height": height,
        "cell_size_m": LAND_MASK_CELL_M,
        "bounds_east_north_m": [min_e, min_n, max_e, max_n],
        "source": "Task 7 OSM coastline-derived land mesh, LOD 0",
    }


def load_osm_coastlines(origin: tuple[float, float, float]) -> list[list[list[float]]]:
    lines: dict[int, list[list[float]]] = {}
    for source in sorted(OSM_DIR.glob("oresund_*.osm.json")):
        payload = json.loads(source.read_text(encoding="utf-8"))
        for element in payload.get("elements", []):
            if element.get("type") != "way" or element.get("tags", {}).get("natural") != "coastline":
                continue
            geometry = element.get("geometry", [])
            if len(geometry) < 2:
                continue
            points = []
            for point in geometry:
                east, north = geodetic_to_local(float(point["lat"]), float(point["lon"]), origin)
                points.append([round(east, 3), round(north, 3)])
            lines[int(element["id"])] = points
    if not lines:
        raise RuntimeError("No Task 7 OSM coastline source files were found")
    return list(lines.values())


def write_features(coastlines: list[list[list[float]]], contours: dict[str, list[list[list[float]]]] | None = None) -> None:
    payload = {
        "schema_version": 1,
        "coordinate_space": "east_north_m from resources/oresund_georeference.tres; same ECEF-to-ENU formula as GeoReference",
        "coastline_source": "OpenStreetMap contributors · natural=coastline · ODbL-1.0",
        "coastlines_east_north_m": coastlines,
        "contour_levels_m": {key: lines for key, lines in (contours or {}).items()},
    }
    FEATURES_PATH.write_text(json.dumps(payload, separators=(",", ":"), ensure_ascii=False) + "\n", encoding="utf-8")


def _point_key(point: tuple[float, float]) -> tuple[int, int]:
    return round(point[0] * 1_000_000), round(point[1] * 1_000_000)


def stitch_segments(segments: list[tuple[tuple[float, float], tuple[float, float]]]) -> list[list[tuple[float, float]]]:
    adjacency: dict[tuple[int, int], list[int]] = defaultdict(list)
    for index, (a, b) in enumerate(segments):
        adjacency[_point_key(a)].append(index)
        adjacency[_point_key(b)].append(index)
    used: set[int] = set()
    lines: list[list[tuple[float, float]]] = []
    for first_index, (a, b) in enumerate(segments):
        if first_index in used:
            continue
        endpoint = a if len(adjacency[_point_key(a)]) == 1 else b if len(adjacency[_point_key(b)]) == 1 else a
        line = [endpoint]
        current = endpoint
        while True:
            candidates = [index for index in adjacency[_point_key(current)] if index not in used]
            if not candidates:
                break
            segment_index = candidates[0]
            used.add(segment_index)
            p0, p1 = segments[segment_index]
            following = p1 if _point_key(p0) == _point_key(current) else p0
            line.append(following)
            current = following
            if _point_key(current) == _point_key(line[0]):
                break
        if len(line) >= 2:
            lines.append(line)
    return lines


def simplify_line(points: list[tuple[float, float]], tolerance_m: float) -> list[tuple[float, float]]:
    if len(points) <= 2:
        return points
    keep = {0, len(points) - 1}
    stack = [(0, len(points) - 1)]
    threshold = tolerance_m * tolerance_m
    while stack:
        first, last = stack.pop()
        ax, ay = points[first]
        bx, by = points[last]
        dx, dy = bx - ax, by - ay
        denominator = dx * dx + dy * dy
        maximum = -1.0
        selected = -1
        for index in range(first + 1, last):
            px, py = points[index]
            if denominator <= 1e-12:
                distance_sq = (px - ax) ** 2 + (py - ay) ** 2
            else:
                t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / denominator))
                qx, qy = ax + t * dx, ay + t * dy
                distance_sq = (px - qx) ** 2 + (py - qy) ** 2
            if distance_sq > maximum:
                maximum, selected = distance_sq, index
        if selected >= 0 and maximum > threshold:
            keep.add(selected)
            stack.append((first, selected))
            stack.append((selected, last))
    return [points[index] for index in sorted(keep)]


def make_contours(depth_dm, valid, latitudes, longitudes, origin) -> dict[str, list[list[list[float]]]]:
    import numpy as np

    rows, columns = depth_dm.shape
    result: dict[str, list[list[list[float]]]] = {}
    for level_m in CONTOUR_LEVELS_M:
        level_dm = level_m * 10.0
        segments: list[tuple[tuple[float, float], tuple[float, float]]] = []
        for row in range(rows - 1):
            for column in range(columns - 1):
                if not (valid[row, column] and valid[row, column + 1] and valid[row + 1, column + 1] and valid[row + 1, column]):
                    continue
                values = (
                    float(depth_dm[row, column]),
                    float(depth_dm[row, column + 1]),
                    float(depth_dm[row + 1, column + 1]),
                    float(depth_dm[row + 1, column]),
                )
                if min(values) > level_dm or max(values) < level_dm:
                    continue
                corners = ((column, row), (column + 1, row), (column + 1, row + 1), (column, row + 1))
                intersections: dict[int, tuple[float, float]] = {}
                for edge in range(4):
                    next_edge = (edge + 1) % 4
                    va, vb = values[edge], values[next_edge]
                    if (va < level_dm) == (vb < level_dm):
                        continue
                    t = 0.5 if abs(vb - va) < 1e-8 else (level_dm - va) / (vb - va)
                    ax, ay = corners[edge]
                    bx, by = corners[next_edge]
                    intersections[edge] = (ax + (bx - ax) * t, ay + (by - ay) * t)
                edges = sorted(intersections)
                if len(edges) == 2:
                    segments.append((intersections[edges[0]], intersections[edges[1]]))
                elif len(edges) == 4:
                    center_high = sum(values) * 0.25 >= level_dm
                    corner0_high = values[0] >= level_dm
                    pairs = ((0, 1), (2, 3)) if center_high == corner0_high else ((0, 3), (1, 2))
                    for edge_a, edge_b in pairs:
                        segments.append((intersections[edge_a], intersections[edge_b]))
        lines_geo = stitch_segments(segments)
        lines_local: list[list[list[float]]] = []
        for line in lines_geo:
            local: list[tuple[float, float]] = []
            for column, row in line:
                latitude = float(latitudes[0]) + row * float(latitudes[1] - latitudes[0])
                longitude = float(longitudes[0]) + column * float(longitudes[1] - longitudes[0])
                local.append(geodetic_to_local(latitude, longitude, origin))
            simplified = simplify_line(local, 18.0)
            if len(simplified) >= 2:
                lines_local.append([[round(x, 2), round(y, 2)] for x, y in simplified])
        result[f"{level_m:g}"] = lines_local
        print(f"Isobath {level_m:g} m: {len(lines_local)} polylines")
    return result


def process_netcdf(land_mask_meta: dict) -> dict:
    try:
        import netCDF4
        import numpy as np
    except ImportError as error:
        raise RuntimeError("Missing NetCDF processing dependencies. Install with: .venv/bin/pip install -r tools/requirements-bathymetry.txt") from error
    if not NETCDF_PATH.is_file():
        raise RuntimeError(f"Missing regional NetCDF cache: {NETCDF_PATH}; run tools/terrain/fetch_bathymetry.py first")

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    region = json.loads(REGION_JSON.read_text(encoding="utf-8"))
    origin = parse_georeference_origin()
    with netCDF4.Dataset(NETCDF_PATH, "r") as dataset:
        latitude = np.asarray(dataset.variables["latitude"][:], dtype=np.float64)
        longitude = np.asarray(dataset.variables["longitude"][:], dtype=np.float64)
        def read_grid_variable(name: str):
            variable = dataset.variables.get(name)
            if variable is None:
                raise RuntimeError(f"NetCDF is missing the required variable {name!r}")
            dimensions = tuple(variable.dimensions)
            array = np.ma.asarray(variable[:])
            if dimensions == ("longitude", "latitude"):
                array = array.T
            elif dimensions != ("latitude", "longitude"):
                raise RuntimeError(f"Unexpected dimensions for {name}: {dimensions}")
            return array

        elevation = np.ma.asarray(read_grid_variable("elevation"), dtype=np.float64)
        if "interpolation_flag" not in dataset.variables or "value_count" not in dataset.variables:
            raise RuntimeError("The downloaded file must contain interpolation_flag and value_count")
        interpolation = read_grid_variable("interpolation_flag")
        value_count = read_grid_variable("value_count")
        dataset_title = getattr(dataset, "title", "The EMODnet Grid")
        dataset_history = getattr(dataset, "history", "")

    lat_order = np.argsort(latitude)
    lon_order = np.argsort(longitude)
    latitude = latitude[lat_order]
    longitude = longitude[lon_order]
    elevation = elevation[lat_order, :][:, lon_order]
    interpolation = interpolation[lat_order, :][:, lon_order]
    value_count = value_count[lat_order, :][:, lon_order]
    if len(latitude) < 2 or len(longitude) < 2:
        raise RuntimeError("Downloaded NetCDF subset has fewer than two samples per axis")
    lat_step = float(np.median(np.diff(latitude)))
    lon_step = float(np.median(np.diff(longitude)))
    if lat_step <= 0.0 or lon_step <= 0.0 or np.max(np.abs(np.diff(latitude) - lat_step)) > 1e-8 or np.max(np.abs(np.diff(longitude) - lon_step)) > 1e-8:
        raise RuntimeError("EMODnet coordinates are not a regular ascending grid")

    elev = np.asarray(elevation.filled(np.nan), dtype=np.float64)
    valid = np.isfinite(elev) & (elev < 0.0)
    if not np.any(valid):
        raise RuntimeError("The regional NetCDF contains no valid below-LAT cells")
    depth_m = -elev
    if np.any(depth_m[valid] > 3276.0):
        raise RuntimeError("A depth exceeds the compact signed-decimetre storage range")
    depth_dm = np.full(elev.shape, INVALID_DEPTH_DM, dtype="<i2")
    depth_dm[valid] = np.rint(depth_m[valid] * 10.0).astype("<i2")
    interpolation_mask = np.ma.getmaskarray(interpolation)
    interpolation_values = np.asarray(np.ma.filled(interpolation, 127), dtype=np.int16)
    interp_byte = np.full(elev.shape, 255, dtype=np.uint8)
    interp_byte[valid & ~interpolation_mask] = (interpolation_values[valid & ~interpolation_mask] > 0).astype(np.uint8)
    count_mask = np.ma.getmaskarray(value_count)
    count_values = np.asarray(np.ma.filled(value_count, 255), dtype=np.int64)
    count_byte = np.full(elev.shape, 255, dtype=np.uint8)
    count_byte[valid & ~count_mask] = np.clip(count_values[valid & ~count_mask], 0, 255).astype(np.uint8)

    records = np.empty(elev.shape, dtype=np.dtype([("depth_dm", "<i2"), ("interpolated", "u1"), ("value_count", "u1")]))
    records["depth_dm"] = depth_dm
    records["interpolated"] = interp_byte
    records["value_count"] = count_byte
    records.tofile(GRID_PATH)
    depth_texture_meta = build_depth_texture(depth_dm, valid, interp_byte, latitude, longitude, origin, land_mask_meta)
    grid_meta = {
        "schema_version": 1,
        "source": "EMODnet Digital Bathymetry (DTM 2024), bathymetry_dtm_2024 ERDDAP griddap",
        "source_url": SOURCE_URL,
        "downloaded_at_utc": json.loads(DOWNLOAD_MANIFEST_PATH.read_text(encoding="utf-8")).get("downloaded_at_utc") if DOWNLOAD_MANIFEST_PATH.exists() else None,
        "processed_at_utc": utc_now(),
        "dataset_title": str(dataset_title),
        "dataset_history": str(dataset_history)[-1000:],
        "coordinate_system": "WGS84 longitude/latitude (EPSG:4326); runtime positions use the project GeoReference ECEF-to-ENU conversion",
        "vertical_datum": "Lowest Astronomical Tide (LAT)",
        "source_elevation_convention": "elevation in metres relative to LAT; negative values below LAT, positive values above LAT",
        "stored_value_convention": "positive water depth = -elevation, quantized to 0.1 m; only finite source values below LAT are valid water cells",
        "rows": int(elev.shape[0]),
        "columns": int(elev.shape[1]),
        "south_latitude_deg": float(latitude[0]),
        "north_latitude_deg": float(latitude[-1]),
        "west_longitude_deg": float(longitude[0]),
        "east_longitude_deg": float(longitude[-1]),
        "latitude_step_deg": lat_step,
        "longitude_step_deg": lon_step,
        "resolution_arc_minutes": 1.0 / 16.0,
        "binary_file": GRID_PATH.name,
        "binary_record_bytes": 4,
        "binary_record_layout": "little-endian int16 depth_decimetres; uint8 interpolation_flag (0/1, 255 invalid); uint8 value_count saturated to 255 (255 invalid)",
        "gpu_depth_texture": depth_texture_meta,
        "invalid_depth_code": INVALID_DEPTH_DM,
        "valid_water_cells": int(np.count_nonzero(valid)),
        "invalid_or_non_water_cells": int(valid.size - np.count_nonzero(valid)),
        "water_depth_range_m": [float(np.min(depth_m[valid])), float(np.max(depth_m[valid]))] if np.any(valid) else None,
        "interpolated_water_cells": int(np.count_nonzero(valid & (interp_byte == 1))),
        "grid_bytes": int(GRID_PATH.stat().st_size),
        "georeference_origin": {"latitude_deg": origin[0], "longitude_deg": origin[1], "altitude_m": origin[2]},
        "region_bounds_wgs84_wsen": region["wgs84_bounds"],
    }
    GRID_META_PATH.write_text(json.dumps(grid_meta, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    features = json.loads(FEATURES_PATH.read_text(encoding="utf-8")) if FEATURES_PATH.exists() else {"coastlines_east_north_m": load_osm_coastlines(origin)}
    contours = make_contours(depth_dm, valid, latitude, longitude, origin)
    write_features(features.get("coastlines_east_north_m", []), contours)
    return grid_meta


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--coastline-only", action="store_true", help="build the Task 7 coastline cache without bathymetry")
    args = parser.parse_args()
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    region = json.loads(REGION_JSON.read_text(encoding="utf-8"))
    origin = parse_georeference_origin()
    land_mask = build_land_mask(region)
    coastlines = load_osm_coastlines(origin)
    write_features(coastlines)
    if args.coastline_only:
        MANIFEST_PATH.write_text(json.dumps({
            "schema_version": 1,
            "bathymetry_ready": False,
            "generated_at_utc": utc_now(),
            "coastline_source": "OpenStreetMap contributors · natural=coastline · ODbL-1.0",
            "coastline_polylines": len(coastlines),
            "land_mask": land_mask,
            "note": "Only shoreline/map support was generated. No bathymetry has been downloaded or substituted.",
        }, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"Wrote {len(coastlines)} OSM coastline polylines and a {land_mask['width']}×{land_mask['height']} land mask.")
        return 0
    grid_meta = process_netcdf(land_mask)
    MANIFEST_PATH.write_text(json.dumps({
        "schema_version": 1,
        "bathymetry_ready": True,
        "generated_at_utc": utc_now(),
        "source": grid_meta["source"],
        "source_url": SOURCE_URL,
        "doi": "https://doi.org/10.12770/cf51df64-56f9-4a99-b1aa-36b8d7b743a1",
        "license": "CC BY 4.0 for the EMODnet data product; verify dataset and underlying originator metadata before redistribution",
        "land_mask": land_mask,
        "grid_metadata": GRID_META_PATH.name,
        "features": FEATURES_PATH.name,
        "grid": GRID_PATH.name,
        "gpu_depth_texture": grid_meta["gpu_depth_texture"],
        "contour_levels_m": CONTOUR_LEVELS_M,
        "grid_summary": grid_meta,
    }, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Wrote {grid_meta['valid_water_cells']:,} valid water cells; depth range {grid_meta['water_depth_range_m']} m.")
    print(f"Data grid: {GRID_PATH.relative_to(ROOT)} ({GRID_PATH.stat().st_size:,} bytes)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"Bathymetry build failed: {error}", file=sys.stderr)
        raise SystemExit(2)
