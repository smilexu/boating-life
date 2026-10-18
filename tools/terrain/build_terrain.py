#!/usr/bin/env python3
"""Build chunked, coast-clipped Godot terrain from cached Terrarium and Task 7 OSM data."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import struct
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

import numpy as np
import shapely
from PIL import Image
from shapely.geometry import LineString, Point, Polygon, box
from shapely.ops import unary_union

from fetch_tiles import REGION_PATH, TILE_ROOT, read_bounds, read_georeference, tile_coordinates, tile_path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
OUTPUT_ROOT = PROJECT_ROOT / "assets/terrain/processed/oresund_terrain"
OUTPUT_MANIFEST = OUTPUT_ROOT / "manifest.json"
ELEVATION_PROFILES_PATH = PROJECT_ROOT / "resources/terrain_elevation_profiles.json"
GEOREFERENCE = read_georeference()
ORIGIN_LAT = GEOREFERENCE["origin_latitude_deg"]
ORIGIN_LON = GEOREFERENCE["origin_longitude_deg"]
ORIGIN_ALT = GEOREFERENCE["origin_altitude_m"]
WGS84_A = 6378137.0
WGS84_F = 1.0 / 298.257223563
WGS84_E2 = WGS84_F * (2.0 - WGS84_F)
VERTEX_DTYPE = np.dtype("<f4")
PROFILE_BOUNDARY_TOLERANCE_M = 0.05
# Peberholm's terrain focus still uses CULL_FRONT in the current runtime split.
# Keep its existing winding until that material workaround is migrated too.
LEGACY_CULL_FRONT_PROFILE_IDS = frozenset({"peberholm"})


def geodetic_to_enu(latitude_deg: float, longitude_deg: float, altitude_m: float = 0.0) -> tuple[float, float, float]:
    """Match scripts/geo_reference.gd: WGS84 ECEF -> the project's ENU frame."""
    latitude = math.radians(latitude_deg)
    longitude = math.radians(longitude_deg)
    origin_latitude = math.radians(ORIGIN_LAT)
    origin_longitude = math.radians(ORIGIN_LON)

    def ecef(phi: float, lam: float, height: float) -> tuple[float, float, float]:
        sin_phi = math.sin(phi)
        prime_vertical = WGS84_A / math.sqrt(1.0 - WGS84_E2 * sin_phi * sin_phi)
        return (
            (prime_vertical + height) * math.cos(phi) * math.cos(lam),
            (prime_vertical + height) * math.cos(phi) * math.sin(lam),
            (prime_vertical * (1.0 - WGS84_E2) + height) * math.sin(phi),
        )

    point = ecef(latitude, longitude, altitude_m)
    origin = ecef(origin_latitude, origin_longitude, ORIGIN_ALT)
    dx, dy, dz = (point[index] - origin[index] for index in range(3))
    east = -math.sin(origin_longitude) * dx + math.cos(origin_longitude) * dy
    north = (
        -math.sin(origin_latitude) * math.cos(origin_longitude) * dx
        - math.sin(origin_latitude) * math.sin(origin_longitude) * dy
        + math.cos(origin_latitude) * dz
    )
    up = (
        math.cos(origin_latitude) * math.cos(origin_longitude) * dx
        + math.cos(origin_latitude) * math.sin(origin_longitude) * dy
        + math.sin(origin_latitude) * dz
    )
    return east, north, up


def local_to_geodetic(east: np.ndarray, north: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Vectorized inverse of the project's local ENU conversion, with local up=0."""
    latitude0 = math.radians(ORIGIN_LAT)
    longitude0 = math.radians(ORIGIN_LON)
    sin_lat = math.sin(latitude0)
    cos_lat = math.cos(latitude0)
    sin_lon = math.sin(longitude0)
    cos_lon = math.cos(longitude0)
    delta_x = -sin_lon * east - sin_lat * cos_lon * north
    delta_y = cos_lon * east - sin_lat * sin_lon * north
    delta_z = cos_lat * north

    sin_origin = math.sin(latitude0)
    origin_n = WGS84_A / math.sqrt(1.0 - WGS84_E2 * sin_origin * sin_origin)
    origin_x = (origin_n + ORIGIN_ALT) * cos_lat * cos_lon
    origin_y = (origin_n + ORIGIN_ALT) * cos_lat * sin_lon
    origin_z = (origin_n * (1.0 - WGS84_E2) + ORIGIN_ALT) * sin_lat
    x = origin_x + delta_x
    y = origin_y + delta_y
    z = origin_z + delta_z
    longitude = np.arctan2(y, x)
    horizontal = np.sqrt(x * x + y * y)
    latitude = np.arctan2(z, horizontal * (1.0 - WGS84_E2))
    altitude = np.zeros_like(latitude)
    for _ in range(8):
        sin_value = np.sin(latitude)
        prime_vertical = WGS84_A / np.sqrt(1.0 - WGS84_E2 * sin_value * sin_value)
        altitude = horizontal / np.maximum(np.abs(np.cos(latitude)), 1e-9) - prime_vertical
        latitude = np.arctan2(
            z,
            horizontal * (1.0 - WGS84_E2 * prime_vertical / (prime_vertical + altitude)),
        )
    return np.degrees(latitude), np.degrees(longitude)


def lon_lat_to_global_pixel(longitude: np.ndarray, latitude: np.ndarray, zoom: int) -> tuple[np.ndarray, np.ndarray]:
    scale = float((1 << zoom) * 256)
    x = (longitude + 180.0) / 360.0 * scale
    latitude = np.clip(latitude, -85.05112878, 85.05112878)
    y = (1.0 - np.arcsinh(np.tan(np.radians(latitude))) / math.pi) * 0.5 * scale
    return x, y


def read_terrarium_mosaic(zoom: int, bounds: tuple[float, float, float, float]) -> tuple[np.ndarray, int, int, list[dict[str, object]]]:
    tiles = tile_coordinates(bounds, zoom)
    if not tiles:
        raise RuntimeError("Configured region does not intersect any terrain tiles")
    x_min = min(tile[1] for tile in tiles)
    x_max = max(tile[1] for tile in tiles)
    y_min = min(tile[2] for tile in tiles)
    y_max = max(tile[2] for tile in tiles)
    mosaic = np.empty(((y_max - y_min + 1) * 256, (x_max - x_min + 1) * 256), dtype=np.float32)
    entries: list[dict[str, object]] = []
    for tile_zoom, x, y in tiles:
        path = tile_path(tile_zoom, x, y)
        if not path.is_file():
            raise RuntimeError(f"Missing required Terrarium tile {tile_zoom}/{x}/{y}; run tools/terrain/fetch_tiles.py --zoom {zoom}")
        payload = path.read_bytes()
        with Image.open(path) as image:
            if image.size != (256, 256) or image.mode not in ("RGB", "RGBA"):
                raise RuntimeError(f"Invalid Terrarium PNG {path}: mode={image.mode}, size={image.size}")
            # Read stored byte channels as-is. Do not convert through a color-space API.
            raw = np.asarray(image, dtype=np.uint8)
            red = raw[:, :, 0].astype(np.float32)
            green = raw[:, :, 1].astype(np.float32)
            blue = raw[:, :, 2].astype(np.float32)
        elevation = red * 256.0 + green + blue / 256.0 - 32768.0
        row = (y - y_min) * 256
        column = (x - x_min) * 256
        mosaic[row : row + 256, column : column + 256] = elevation
        entries.append({
            "z": tile_zoom,
            "x": x,
            "y": y,
            "sha256": hashlib.sha256(payload).hexdigest(),
            "bytes": len(payload),
        })
    return mosaic, x_min * 256, y_min * 256, entries


class TerrariumSampler:
    def __init__(self, heights: np.ndarray, pixel_x_origin: int, pixel_y_origin: int, zoom: int) -> None:
        self.heights = heights
        self.pixel_x_origin = pixel_x_origin
        self.pixel_y_origin = pixel_y_origin
        self.zoom = zoom

    def sample(self, east: np.ndarray, north: np.ndarray) -> np.ndarray:
        latitude, longitude = local_to_geodetic(np.asarray(east, dtype=np.float64), np.asarray(north, dtype=np.float64))
        global_x, global_y = lon_lat_to_global_pixel(longitude, latitude, self.zoom)
        pixel_x = global_x - self.pixel_x_origin
        pixel_y = global_y - self.pixel_y_origin
        x0 = np.floor(pixel_x).astype(np.int64)
        y0 = np.floor(pixel_y).astype(np.int64)
        x0 = np.clip(x0, 0, self.heights.shape[1] - 2)
        y0 = np.clip(y0, 0, self.heights.shape[0] - 2)
        tx = np.clip(pixel_x - x0, 0.0, 1.0)
        ty = np.clip(pixel_y - y0, 0.0, 1.0)
        h00 = self.heights[y0, x0]
        h10 = self.heights[y0, x0 + 1]
        h01 = self.heights[y0 + 1, x0]
        h11 = self.heights[y0 + 1, x0 + 1]
        return ((1.0 - ty) * ((1.0 - tx) * h00 + tx * h10) + ty * ((1.0 - tx) * h01 + tx * h11)).astype(np.float32)


def _iter_polygons(geometry: object) -> Iterable[Polygon]:
    if geometry.is_empty:
        return
    if geometry.geom_type == "Polygon":
        yield geometry
    elif geometry.geom_type in ("MultiPolygon", "GeometryCollection"):
        for part in geometry.geoms:
            yield from _iter_polygons(part)


def _iter_lines(geometry: object) -> Iterable[LineString]:
    if geometry.is_empty:
        return
    if geometry.geom_type == "LineString":
        yield geometry
    elif geometry.geom_type in ("MultiLineString", "GeometryCollection"):
        for part in geometry.geoms:
            yield from _iter_lines(part)


def reconstruct_land_mask(region_data: dict[str, object]) -> tuple[object, Polygon, float]:
    lod = region_data["lods"][0]
    vertices = lod["vertices_east_north_m"]
    indices = lod["indices"]
    triangles = [
        Polygon((vertices[indices[index]], vertices[indices[index + 1]], vertices[indices[index + 2]]))
        for index in range(0, len(indices), 3)
    ]
    land = unary_union(triangles)
    if not land.is_valid:
        land = shapely.make_valid(land)
    bounds = region_data["wgs84_bounds"]
    west, south, east, north = (float(value) for value in bounds)
    frame: list[tuple[float, float]] = []
    steps = 48
    for index in range(steps + 1):
        t = index / steps
        frame.append(geodetic_to_enu(south, west + (east - west) * t)[:2])
    for index in range(1, steps + 1):
        t = index / steps
        frame.append(geodetic_to_enu(south + (north - south) * t, east)[:2])
    for index in range(1, steps + 1):
        t = index / steps
        frame.append(geodetic_to_enu(north, east - (east - west) * t)[:2])
    for index in range(1, steps):
        t = index / steps
        frame.append(geodetic_to_enu(north - (north - south) * t, west)[:2])
    region = Polygon(frame)
    expected_area = float(region_data["qa"]["land_area_km2"])
    return land, region, expected_area


def estimate_shoreline_offset(land: object, region: Polygon, sampler: TerrariumSampler, target_height_m: float) -> tuple[float, dict[str, object]]:
    inward_land = land.buffer(-60.0, join_style="mitre")
    if inward_land.is_empty:
        return 0.0, {"method": "unavailable; used zero offset", "sample_count": 0}
    # Eroding land moves the sample point inland from the shoreline. Remove the
    # crop-frame boundary so inland crop edges do not affect sea-level alignment.
    shoreline_band = inward_land.boundary.difference(region.boundary.buffer(250.0))
    sample_east: list[float] = []
    sample_north: list[float] = []
    for line in _iter_lines(shoreline_band):
        sample_count = max(1, math.ceil(line.length / 300.0))
        for index in range(sample_count):
            point = line.interpolate((index + 0.5) * line.length / sample_count)
            sample_east.append(point.x)
            sample_north.append(point.y)
    if len(sample_east) < 16:
        return 0.0, {"method": "insufficient shoreline samples; used zero offset", "sample_count": len(sample_east)}
    samples = sampler.sample(np.asarray(sample_east), np.asarray(sample_north))
    median = float(np.median(samples))
    offset = target_height_m - median
    return offset, {
        "method": "uniform offset aligns median Terrarium elevation 60 m inland of the OSM shoreline to the configured sea-edge target",
        "sample_count": int(samples.size),
        "median_source_height_m": median,
        "p10_source_height_m": float(np.percentile(samples, 10)),
        "p90_source_height_m": float(np.percentile(samples, 90)),
        "target_height_m": target_height_m,
        "applied_uniform_offset_m": offset,
    }


def smoothstep(low: float, high: float, value: np.ndarray) -> np.ndarray:
    if high <= low:
        return (value >= high).astype(np.float32)
    t = np.clip((value - low) / (high - low), 0.0, 1.0)
    return (t * t * (3.0 - 2.0 * t)).astype(np.float32)


def load_gameplay_elevation_profiles(land: object) -> tuple[list[dict[str, object]], dict[str, object]]:
    """Load gameified height profiles against the exact land polygons rendered by the game."""
    if not ELEVATION_PROFILES_PATH.is_file():
        raise RuntimeError(f"Missing gameplay elevation profile config: {ELEVATION_PROFILES_PATH}")
    config = json.loads(ELEVATION_PROFILES_PATH.read_text(encoding="utf-8"))
    if int(config.get("schema_version", -1)) != 1 or not isinstance(config.get("profiles"), list):
        raise RuntimeError("Gameplay elevation profile config has an unsupported schema")

    loaded: list[dict[str, object]] = []
    metadata: list[dict[str, object]] = []
    layout_cache: dict[Path, dict[str, object]] = {}
    land_components = list(_iter_polygons(land))
    for profile_data in config["profiles"]:
        profile_id = str(profile_data.get("profile_id", ""))
        layout_path = PROJECT_ROOT / str(profile_data.get("layout_file", ""))
        if not profile_id or not layout_path.is_file():
            raise RuntimeError(f"Invalid gameplay elevation profile source for {profile_id!r}")
        if layout_path not in layout_cache:
            layout_cache[layout_path] = json.loads(layout_path.read_text(encoding="utf-8"))
        outline: object = layout_cache[layout_path]
        outline_path = profile_data.get("outline_path", [])
        if not isinstance(outline_path, list) or not outline_path:
            raise RuntimeError(f"Profile {profile_id} has no outline path")
        for key in outline_path:
            if not isinstance(outline, dict) or key not in outline:
                raise RuntimeError(f"Profile {profile_id} references a missing outline key: {key}")
            outline = outline[key]
        if not isinstance(outline, list) or len(outline) < 4:
            raise RuntimeError(f"Profile {profile_id} outline must contain at least four [lat, lon] points")
        local_outline = [geodetic_to_enu(float(point[0]), float(point[1]))[:2] for point in outline]
        selector = Polygon(local_outline)
        if not selector.is_valid:
            selector = shapely.make_valid(selector)
        if selector.is_empty or selector.area <= 0.0:
            raise RuntimeError(f"Profile {profile_id} outline does not form a usable polygon")
        if not land_components:
            raise RuntimeError("The generated OSM land mask contains no polygon components")
        polygon = max(land_components, key=lambda component: component.intersection(selector).area)
        overlap_area = float(polygon.intersection(selector).area)
        selector_overlap_ratio = overlap_area / float(selector.area)
        if selector_overlap_ratio < 0.5:
            raise RuntimeError(
                f"Profile {profile_id} selector only overlaps the rendered land mask by {selector_overlap_ratio:.1%}"
            )
        shoreline_height = float(profile_data["shoreline_height_m"])
        plateau_height = float(profile_data["plateau_height_m"])
        transition_distance = float(profile_data["plateau_distance_from_shore_m"])
        if transition_distance <= 0.0 or plateau_height <= shoreline_height:
            raise RuntimeError(f"Profile {profile_id} has invalid height or transition values")
        loaded.append({
            "profile_id": profile_id,
            "polygon": polygon,
            "coverage_polygon": polygon.buffer(PROFILE_BOUNDARY_TOLERANCE_M),
            # Runtime Peberholm splitting selects the OSM outline plus a 75 m
            # edge margin and keeps that top on its legacy CULL_FRONT material.
            "winding_preserve_polygon": selector.buffer(75.0),
            "shoreline_height_m": shoreline_height,
            "plateau_height_m": plateau_height,
            "plateau_distance_from_shore_m": transition_distance,
        })
        metadata.append({
            "profile_id": profile_id,
            "source_outline": f"{profile_data['layout_file']}#{'.'.join(str(key) for key in outline_path)}",
            "shoreline_height_m": shoreline_height,
            "plateau_height_m": plateau_height,
            "plateau_distance_from_shore_m": transition_distance,
            "polygon_area_km2": round(float(polygon.area / 1_000_000.0), 3),
            "selector_overlap_ratio": round(selector_overlap_ratio, 5),
            "quality": str(config.get("quality", "Gameplay approximation")),
        })
    return loaded, {"quality": str(config.get("quality", "Gameplay approximation")), "profiles": metadata}


def apply_gameplay_elevation_profiles(
    east: np.ndarray,
    north: np.ndarray,
    heights: np.ndarray,
    profiles: list[dict[str, object]],
) -> np.ndarray:
    """Replace elevations only inside land components selected by gameplay outlines."""
    result = heights.astype(np.float32, copy=True)
    if not profiles or result.size == 0:
        return result
    points = shapely.points(east, north)
    for profile in profiles:
        polygon = profile["polygon"]
        # Terrain polygon vertices are quantized to millimetres and then stored
        # as float32. A tiny round-off can put an exact shoreline vertex just
        # outside the polygon and leave it at the old submerged source height.
        inside = np.asarray(shapely.covers(profile["coverage_polygon"], points), dtype=bool)
        if not np.any(inside):
            continue
        distance_from_shore = np.asarray(shapely.distance(polygon.boundary, points), dtype=np.float32)
        t = np.clip(
            distance_from_shore / float(profile["plateau_distance_from_shore_m"]),
            0.0,
            1.0,
        )
        blend = t * t * (3.0 - 2.0 * t)
        profile_height = float(profile["shoreline_height_m"]) + (
            float(profile["plateau_height_m"]) - float(profile["shoreline_height_m"])
        ) * blend
        result = np.where(inside, profile_height, result)
    return result.astype(np.float32)


def vertex_colors(east: np.ndarray, north: np.ndarray, heights: np.ndarray, normals: np.ndarray, coast: object) -> np.ndarray:
    points = shapely.points(east, north)
    coast_distance = shapely.distance(coast, points).astype(np.float32)
    slope_degrees = np.degrees(np.arccos(np.clip(normals[:, 1], -1.0, 1.0)))
    height_blend = smoothstep(4.0, 130.0, heights)
    grass_low = np.array([0.33, 0.43, 0.29], dtype=np.float32)
    grass_high = np.array([0.43, 0.48, 0.35], dtype=np.float32)
    grass = grass_low[None, :] * (1.0 - height_blend[:, None] * 0.45) + grass_high[None, :] * (height_blend[:, None] * 0.45)
    soil = np.array([0.45, 0.39, 0.30], dtype=np.float32)
    rock = np.array([0.43, 0.44, 0.42], dtype=np.float32)
    sand = np.array([0.67, 0.59, 0.43], dtype=np.float32)
    urban = np.array([0.41, 0.42, 0.39], dtype=np.float32)

    soil_weight = smoothstep(9.0, 25.0, slope_degrees) * 0.32
    result = grass * (1.0 - soil_weight[:, None]) + soil[None, :] * soil_weight[:, None]
    rock_weight = smoothstep(22.0, 43.0, slope_degrees) * 0.72
    result = result * (1.0 - rock_weight[:, None]) + rock[None, :] * rock_weight[:, None]
    shore_weight = 1.0 - smoothstep(22.0, 75.0, coast_distance)
    result = result * (1.0 - shore_weight[:, None]) + sand[None, :] * shore_weight[:, None]

    for latitude, longitude in ((55.60587, 13.00073), (55.67605, 12.56883)):
        city_east, city_north, _up = geodetic_to_enu(latitude, longitude)
        city_distance = np.hypot(east - city_east, north - city_north)
        urban_weight = (1.0 - smoothstep(900.0, 6000.0, city_distance)) * 0.20
        result = result * (1.0 - urban_weight[:, None]) + urban[None, :] * urban_weight[:, None]

    broad_variation = 0.97 + 0.03 * (0.5 + 0.5 * np.sin(east * 0.00037 + north * 0.00012) * np.sin(north * 0.00031 - east * 0.00008))
    result *= broad_variation[:, None]
    alpha = np.ones((result.shape[0], 1), dtype=np.float32)
    return np.concatenate((result, alpha), axis=1).astype(np.float32)


def build_chunk(
    land: object,
    coast: object,
    sampler: TerrariumSampler,
    chunk_min_east: float,
    chunk_min_north: float,
    chunk_size_m: float,
    cell_size_m: float,
    vertical_offset_m: float,
    coastal_floor_m: float,
    gameplay_elevation_profiles: list[dict[str, object]],
    output_path: Path,
    preserve_profile_winding_ids: set[str] | None = None,
) -> dict[str, object] | None:
    cells_per_axis = round(chunk_size_m / cell_size_m)
    coordinates = np.arange(cells_per_axis, dtype=np.float64) * cell_size_m
    east_grid, north_grid = np.meshgrid(chunk_min_east + coordinates, chunk_min_north + coordinates)
    east0 = east_grid.ravel()
    north0 = north_grid.ravel()
    cells = shapely.box(east0, north0, east0 + cell_size_m, north0 + cell_size_m)
    intersects = np.asarray(shapely.intersects(land, cells), dtype=bool)
    if not np.any(intersects):
        return None
    covered = np.asarray(shapely.covers(land, cells), dtype=bool)
    full_cells = np.flatnonzero(intersects & covered)
    edge_cells = np.flatnonzero(intersects & ~covered)

    vertices_east_north: list[tuple[float, float]] = []
    indices: list[int] = []
    vertex_lookup: dict[tuple[int, int], int] = {}
    preserve_profile_winding_ids = preserve_profile_winding_ids or set()
    preserve_winding_polygons = [
        profile["winding_preserve_polygon"]
        for profile in gameplay_elevation_profiles
        if str(profile["profile_id"]) in preserve_profile_winding_ids
    ]

    def should_preserve_winding(points_east_north: list[tuple[float, float]]) -> bool:
        if not preserve_winding_polygons:
            return False
        center_east = sum(point[0] for point in points_east_north) / 3.0
        center_north = sum(point[1] for point in points_east_north) / 3.0
        return any(bool(shapely.contains_xy(polygon, center_east, center_north)) for polygon in preserve_winding_polygons)

    def vertex_index(east: float, north: float) -> int:
        key = (round(east * 1000.0), round(north * 1000.0))
        found = vertex_lookup.get(key)
        if found is None:
            found = len(vertices_east_north)
            vertex_lookup[key] = found
            vertices_east_north.append((key[0] / 1000.0, key[1] / 1000.0))
        return found

    for cell_index in full_cells:
        east = float(east0[cell_index])
        north = float(north0[cell_index])
        p00 = vertex_index(east, north)
        p10 = vertex_index(east + cell_size_m, north)
        p01 = vertex_index(east, north + cell_size_m)
        p11 = vertex_index(east + cell_size_m, north + cell_size_m)
        for triangle in ((p00, p10, p11), (p00, p11, p01)):
            triangle_points = [vertices_east_north[index] for index in triangle]
            if should_preserve_winding(triangle_points):
                indices.extend(triangle)
            else:
                # Godot's front-face test for X=east, Z=-north expects
                # clockwise triangles when viewed from above.
                indices.extend((triangle[0], triangle[2], triangle[1]))

    for cell_index in edge_cells:
        cell = cells[cell_index]
        clipped = shapely.intersection(land, cell)
        for polygon in _iter_polygons(clipped):
            if polygon.area < 0.05:
                continue
            triangulation = shapely.constrained_delaunay_triangles(polygon)
            for triangle in _iter_polygons(triangulation):
                coordinates = list(triangle.exterior.coords)[:3]
                if len(coordinates) != 3 or triangle.area < 0.01 or not polygon.covers(triangle):
                    continue
                quantized = [(round(float(point[0]) * 1000.0) / 1000.0, round(float(point[1]) * 1000.0) / 1000.0) for point in coordinates]
                if len(set(quantized)) != 3:
                    continue
                signed_area = (
                    (quantized[1][0] - quantized[0][0]) * (quantized[2][1] - quantized[0][1])
                    - (quantized[1][1] - quantized[0][1]) * (quantized[2][0] - quantized[0][0])
                )
                if abs(signed_area) < 1e-6:
                    continue
                positive_area_order = quantized if signed_area > 0.0 else (quantized[0], quantized[2], quantized[1])
                if should_preserve_winding(positive_area_order):
                    ordered = positive_area_order
                else:
                    # Match Godot's front-face winding for X=east, Z=-north:
                    # negative signed area in EN is the visible side from above.
                    ordered = (positive_area_order[0], positive_area_order[2], positive_area_order[1])
                indices.extend(vertex_index(float(point[0]), float(point[1])) for point in ordered)

    if not indices:
        return None

    local_east = np.asarray([point[0] for point in vertices_east_north], dtype=np.float64)
    local_north = np.asarray([point[1] for point in vertices_east_north], dtype=np.float64)
    raw_height = sampler.sample(local_east, local_north)
    height = np.maximum(raw_height + vertical_offset_m, coastal_floor_m).astype(np.float32)
    height = apply_gameplay_elevation_profiles(local_east, local_north, height, gameplay_elevation_profiles)

    gradient_step_m = 55.0
    height_east_plus = np.maximum(sampler.sample(local_east + gradient_step_m, local_north) + vertical_offset_m, coastal_floor_m)
    height_east_minus = np.maximum(sampler.sample(local_east - gradient_step_m, local_north) + vertical_offset_m, coastal_floor_m)
    height_north_plus = np.maximum(sampler.sample(local_east, local_north + gradient_step_m) + vertical_offset_m, coastal_floor_m)
    height_north_minus = np.maximum(sampler.sample(local_east, local_north - gradient_step_m) + vertical_offset_m, coastal_floor_m)
    height_east_plus = apply_gameplay_elevation_profiles(local_east + gradient_step_m, local_north, height_east_plus, gameplay_elevation_profiles)
    height_east_minus = apply_gameplay_elevation_profiles(local_east - gradient_step_m, local_north, height_east_minus, gameplay_elevation_profiles)
    height_north_plus = apply_gameplay_elevation_profiles(local_east, local_north + gradient_step_m, height_north_plus, gameplay_elevation_profiles)
    height_north_minus = apply_gameplay_elevation_profiles(local_east, local_north - gradient_step_m, height_north_minus, gameplay_elevation_profiles)
    inside_east_plus = shapely.contains_xy(land, local_east + gradient_step_m, local_north)
    inside_east_minus = shapely.contains_xy(land, local_east - gradient_step_m, local_north)
    inside_north_plus = shapely.contains_xy(land, local_east, local_north + gradient_step_m)
    inside_north_minus = shapely.contains_xy(land, local_east, local_north - gradient_step_m)
    height_east_plus = np.where(inside_east_plus, height_east_plus, height)
    height_east_minus = np.where(inside_east_minus, height_east_minus, height)
    height_north_plus = np.where(inside_north_plus, height_north_plus, height)
    height_north_minus = np.where(inside_north_minus, height_north_minus, height)
    derivative_east = (height_east_plus - height_east_minus) / (2.0 * gradient_step_m)
    derivative_north = (height_north_plus - height_north_minus) / (2.0 * gradient_step_m)
    normals = np.column_stack((-derivative_east, np.ones_like(height), derivative_north)).astype(np.float32)
    normals /= np.maximum(np.linalg.norm(normals, axis=1, keepdims=True), 1e-8)
    colors = vertex_colors(local_east, local_north, height, normals, coast)
    positions = np.column_stack((local_east, height, -local_north)).astype(VERTEX_DTYPE)
    records = np.column_stack((positions, normals, colors)).astype(VERTEX_DTYPE)
    index_bytes = np.asarray(indices, dtype="<u4").tobytes()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("wb") as output:
        output.write(b"OZTR")
        output.write(struct.pack("<III", 1, len(records), len(indices)))
        output.write(records.tobytes())
        output.write(index_bytes)
    return {
        "file": output_path.relative_to(OUTPUT_ROOT).as_posix(),
        "east_min_m": float(np.min(local_east)),
        "east_max_m": float(np.max(local_east)),
        "north_min_m": float(np.min(local_north)),
        "north_max_m": float(np.max(local_north)),
        "vertex_count": len(records),
        "triangle_count": len(indices) // 3,
        "file_bytes": output_path.stat().st_size,
        "height_min_m": float(np.min(height)),
        "height_max_m": float(np.max(height)),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zoom", type=int, default=11, help="XYZ/Terrarium zoom level (default: 11)")
    parser.add_argument("--cell-size-m", type=float, default=100.0, help="Land mesh sample spacing (default: 100 m)")
    parser.add_argument("--chunk-size-m", type=float, default=10000.0, help="Square chunk side length (default: 10 km)")
    parser.add_argument("--shore-target-m", type=float, default=1.0, help="Target median elevation 60 m inland after alignment (default: 1 m)")
    parser.add_argument("--coastal-floor-m", type=float, default=0.5, help="Clamp low land vertices above the sea plane (default: 0.5 m)")
    parser.add_argument("--vertical-offset-m", type=float, help="Use this fixed offset instead of shoreline auto-alignment")
    parser.add_argument(
        "--chunk",
        help="Rebuild only one existing chunk (e.g. e+0_n-20); leave the shared manifest untouched",
    )
    args = parser.parse_args()

    try:
        if args.cell_size_m <= 0.0 or args.chunk_size_m <= 0.0 or args.chunk_size_m / args.cell_size_m < 1:
            raise RuntimeError("Cell and chunk sizes must be positive, and chunks must contain cells")
        cells_per_axis = round(args.chunk_size_m / args.cell_size_m)
        if not math.isclose(cells_per_axis * args.cell_size_m, args.chunk_size_m, abs_tol=1e-6):
            raise RuntimeError("chunk-size-m must be an integer multiple of cell-size-m for seamless chunk edges")
        selected_chunk_basename: str | None = None
        if args.chunk:
            selected_chunk_basename = Path(args.chunk).name
            if selected_chunk_basename.endswith(".bin"):
                selected_chunk_basename = selected_chunk_basename[:-4]
            if not selected_chunk_basename.startswith("chunk_"):
                selected_chunk_basename = f"chunk_{selected_chunk_basename}"
            selected_chunk_basename += ".bin"
            if not OUTPUT_MANIFEST.is_file():
                raise RuntimeError("--chunk requires an existing terrain manifest")
            existing_manifest = json.loads(OUTPUT_MANIFEST.read_text(encoding="utf-8"))
            chunk_entries = existing_manifest.get("chunks", [])
            if not any(Path(str(entry.get("file", ""))).name == selected_chunk_basename for entry in chunk_entries):
                raise RuntimeError(f"Requested chunk is not listed in the existing manifest: {selected_chunk_basename}")
            if not (OUTPUT_ROOT / "chunks" / selected_chunk_basename).is_file():
                raise RuntimeError(f"Requested chunk file is missing: {selected_chunk_basename}")
            if int(existing_manifest.get("tile_zoom", -1)) != args.zoom:
                raise RuntimeError("--chunk zoom must match the existing terrain manifest")
            if not math.isclose(float(existing_manifest.get("terrain_grid_spacing_m", -1.0)), args.cell_size_m, abs_tol=1e-6):
                raise RuntimeError("--chunk cell size must match the existing terrain manifest")
            if not math.isclose(float(existing_manifest.get("terrain_chunk_size_m", -1.0)), args.chunk_size_m, abs_tol=1e-6):
                raise RuntimeError("--chunk size must match the existing terrain manifest")
        bounds = read_bounds()
        region_data = json.loads(REGION_PATH.read_text(encoding="utf-8"))
        print(f"Loading Task 7 land mesh: {REGION_PATH.relative_to(PROJECT_ROOT)}")
        land, region, expected_land_area_km2 = reconstruct_land_mask(region_data)
        land_area_km2 = float(land.area / 1_000_000.0)
        print(f"Reconstructed land mask: {land.geom_type}, {len(land.geoms) if hasattr(land, 'geoms') else 1} components, {land_area_km2:.2f} km² (Task 7 QA {expected_land_area_km2:.2f} km²)")
        gameplay_elevation_profiles, gameplay_elevation_profile_metadata = load_gameplay_elevation_profiles(land)
        for profile in gameplay_elevation_profile_metadata["profiles"]:
            print(
                "Gameplay elevation profile %s: shoreline %.2f m -> plateau %.2f m over %.0f m (%s)"
                % (
                    profile["profile_id"],
                    profile["shoreline_height_m"],
                    profile["plateau_height_m"],
                    profile["plateau_distance_from_shore_m"],
                    profile["quality"],
                )
            )

        print(f"Loading {args.zoom=} Terrarium tiles from {TILE_ROOT.relative_to(PROJECT_ROOT)}")
        mosaic, pixel_x_origin, pixel_y_origin, tile_manifest = read_terrarium_mosaic(args.zoom, bounds)
        sampler = TerrariumSampler(mosaic, pixel_x_origin, pixel_y_origin, args.zoom)
        tile_count = len(tile_manifest)
        print(f"Terrarium cache coverage: {tile_count} valid PNG tiles; raw decoded range {float(mosaic.min()):.2f}..{float(mosaic.max()):.2f} m")

        if args.vertical_offset_m is None:
            vertical_offset_m, offset_report = estimate_shoreline_offset(land, region, sampler, args.shore_target_m)
        else:
            vertical_offset_m = args.vertical_offset_m
            offset_report = {
                "method": "user-specified uniform vertical offset",
                "sample_count": 0,
                "applied_uniform_offset_m": vertical_offset_m,
            }
        if selected_chunk_basename is not None:
            expected_offset = float(existing_manifest.get("vertical_alignment", {}).get("applied_uniform_offset_m", math.nan))
            expected_floor = float(existing_manifest.get("vertical_alignment", {}).get("coastal_floor_m", math.nan))
            if not math.isclose(vertical_offset_m, expected_offset, abs_tol=1e-5):
                raise RuntimeError("--chunk computed vertical offset differs from the existing manifest; refusing to alter elevations")
            if not math.isclose(args.coastal_floor_m, expected_floor, abs_tol=1e-6):
                raise RuntimeError("--chunk coastal floor must match the existing terrain manifest")
        print(f"Vertical alignment: offset {vertical_offset_m:+.2f} m; {offset_report}")

        region_min_east, region_min_north, region_max_east, region_max_north = region_data["bounds_east_north_m"]
        start_east = math.floor(region_min_east / args.chunk_size_m) * args.chunk_size_m
        start_north = math.floor(region_min_north / args.chunk_size_m) * args.chunk_size_m
        chunk_count_east = math.ceil((region_max_east - start_east) / args.chunk_size_m)
        chunk_count_north = math.ceil((region_max_north - start_north) / args.chunk_size_m)
        coast = land.boundary.difference(region.boundary.buffer(150.0))
        shapely.prepare(land)
        chunks: list[dict[str, object]] = []
        for north_index in range(chunk_count_north):
            for east_index in range(chunk_count_east):
                chunk_east = start_east + east_index * args.chunk_size_m
                chunk_north = start_north + north_index * args.chunk_size_m
                file_name = f"chunk_e{round(chunk_east / 1000):+d}_n{round(chunk_north / 1000):+d}.bin"
                if selected_chunk_basename is not None and file_name != selected_chunk_basename:
                    continue
                output_path = OUTPUT_ROOT / "chunks" / file_name
                result = build_chunk(
                    land,
                    coast,
                    sampler,
                    chunk_east,
                    chunk_north,
                    args.chunk_size_m,
                    args.cell_size_m,
                    vertical_offset_m,
                    args.coastal_floor_m,
                    gameplay_elevation_profiles,
                    output_path,
                    LEGACY_CULL_FRONT_PROFILE_IDS,
                )
                if result is not None:
                    chunks.append(result)
                    print(f"Built {result['file']}: {result['vertex_count']:,} vertices, {result['triangle_count']:,} triangles")

        if not chunks:
            raise RuntimeError("No terrain chunks were generated")
        if selected_chunk_basename is not None:
            built_chunk = chunks[0]
            print(
                "Selective rebuild complete: %s (%s vertices, %s triangles). Existing manifest and all other chunk files were left untouched."
                % (
                    built_chunk["file"],
                    f"{built_chunk['vertex_count']:,}",
                    f"{built_chunk['triangle_count']:,}",
                )
            )
            return 0
        all_heights = [chunk["height_min_m"] for chunk in chunks] + [chunk["height_max_m"] for chunk in chunks]
        landmark_samples: dict[str, dict[str, object]] = {}
        for name, latitude, longitude in (
            ("malmo", 55.60587, 13.00073),
            ("copenhagen", 55.67605, 12.56883),
            ("oresund_bridge_midpoint", 55.57694, 12.82333),
        ):
            east, north, _up = geodetic_to_enu(latitude, longitude)
            source_height = float(sampler.sample(np.asarray([east]), np.asarray([north]))[0])
            landmark_samples[name] = {
                "latitude": latitude,
                "longitude": longitude,
                "land_mask_contains_point": bool(land.covers(Point(east, north))),
                "source_raster_height_m": source_height,
                "aligned_sample_height_m": max(source_height + vertical_offset_m, args.coastal_floor_m),
            }
        manifest = {
            "schema_version": 1,
            "format": "OZTR little-endian binary chunks (position XYZ, normal XYZ, color RGBA; uint32 indices)",
            "source": "Mapzen Terrain Tiles / Tilezen Terrarium PNG from the AWS Open Data elevation-tiles-prod bucket",
            "source_url_template": "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png",
            "accessed_at_utc": datetime.now(timezone.utc).isoformat(),
            "task7_land_data": "assets/geodata/processed/oresund_region.json · OpenStreetMap natural=coastline · ODbL-1.0",
            "wgs84_bounds": {"west": bounds[0], "south": bounds[1], "east": bounds[2], "north": bounds[3]},
            "local_frame": {
                "method": "same WGS84 ECEF-to-ENU transform as scripts/geo_reference.gd",
                "origin_latitude_deg": ORIGIN_LAT,
                "origin_longitude_deg": ORIGIN_LON,
                "origin_altitude_m": ORIGIN_ALT,
                "godot_axes": "X=east, Y=up, Z=-north; one unit is one metre",
            },
            "tile_zoom": args.zoom,
            "tile_count": tile_count,
            "tile_xyz_range": {
                "x": [min(int(tile["x"]) for tile in tile_manifest), max(int(tile["x"]) for tile in tile_manifest)],
                "y": [min(int(tile["y"]) for tile in tile_manifest), max(int(tile["y"]) for tile in tile_manifest)],
            },
            "tile_sha256": tile_manifest,
            "terrain_grid_spacing_m": args.cell_size_m,
            "terrain_chunk_size_m": args.chunk_size_m,
            "source_raster_decoded_range_m": [float(mosaic.min()), float(mosaic.max())],
            "land_vertex_height_range_m_with_alignment": [min(all_heights), max(all_heights)],
            "land_mask": {
                "source": "Task 7's highest detail mesh, reconstructed from its land-only triangles",
                "component_count": len(land.geoms) if hasattr(land, "geoms") else 1,
                "area_km2_from_mesh_union": land_area_km2,
                "area_km2_from_task7_qa": expected_land_area_km2,
                "holes_preserved": True,
            },
            "vertical_alignment": {
                **offset_report,
                "coastal_floor_m": args.coastal_floor_m,
                "inspector_extra_offset_m": "OresundRegion.terrain_vertical_offset_m",
            },
            "gameplay_elevation_profiles": gameplay_elevation_profile_metadata,
            "reference_elevation_samples": landmark_samples,
            "material_approximation": "Vertex colors use elevation, slope, distance to OSM coast, and soft city-anchor proximity; no land-cover dataset was used.",
            "chunks": chunks,
        }
        OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)
        OUTPUT_MANIFEST.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
        total_vertices = sum(int(chunk["vertex_count"]) for chunk in chunks)
        total_triangles = sum(int(chunk["triangle_count"]) for chunk in chunks)
        total_bytes = sum(int(chunk["file_bytes"]) for chunk in chunks)
        print(f"Wrote {OUTPUT_MANIFEST.relative_to(PROJECT_ROOT)}")
        print(f"Generated chunks={len(chunks)}, vertices={total_vertices:,}, triangles={total_triangles:,}, bytes={total_bytes:,}")
        print(f"Aligned terrain height range={min(all_heights):.2f}..{max(all_heights):.2f} m")
        print("Source tiles:")
        print(f"  valid={tile_count}, failed=0; decoded channel formula: R*256 + G + B/256 - 32768")
        return 0
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
