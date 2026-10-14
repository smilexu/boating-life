#!/usr/bin/env python3
"""Fetch and build an offline OSM coastline mesh for the Øresund prototype.

Requires Shapely 2.x. A known water seed and coastline crossing parity classify
the clipped region into a small raster before land spans are vectorized.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
import time
from pathlib import Path
from typing import Any, Iterable
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


PROJECT_ROOT = Path(__file__).resolve().parents[1]
RAW_DIR = PROJECT_ROOT / "assets/geodata/source"
OUTPUT_PATH = PROJECT_ROOT / "assets/geodata/processed/oresund_region.json"
OVERPASS_URL = "https://overpass-api.de/api/interpreter"

# WGS84 crop, split into two public Overpass requests to avoid timeouts.
BOUNDS = {"west": 12.25, "south": 55.35, "east": 13.22, "north": 56.10}
ORIGIN = {"latitude": 55.70, "longitude": 12.75, "altitude": 0.0}
QUERY_HALVES = {
    "west": (55.35, 12.25, 56.10, 12.80),
    "east": (55.35, 12.80, 56.10, 13.22),
}

LANDMARKS = {
    "malmo": {"name": "Malmö", "latitude": 55.60587, "longitude": 13.00073},
    "copenhagen": {"name": "Copenhagen", "latitude": 55.67605, "longitude": 12.56883},
    "oresund_bridge": {"name": "Øresund Bridge · approximate midpoint", "latitude": 55.57694, "longitude": 12.82333},
    "saltholm": {"name": "Saltholm · approximate interior point", "latitude": 55.63, "longitude": 12.74},
}

WGS84_A = 6378137.0
WGS84_F = 1.0 / 298.257223563
WGS84_E2 = WGS84_F * (2.0 - WGS84_F)
WATER_SEED = {"latitude": ORIGIN["latitude"], "longitude": ORIGIN["longitude"]}


def geodetic_to_local(latitude_deg: float, longitude_deg: float, altitude_m: float = 0.0) -> tuple[float, float, float]:
    """WGS84 geodetic -> origin-relative (east, north, up), in metres."""
    lat = math.radians(latitude_deg)
    lon = math.radians(longitude_deg)
    lat0 = math.radians(ORIGIN["latitude"])
    lon0 = math.radians(ORIGIN["longitude"])

    def ecef(phi: float, lam: float, height: float) -> tuple[float, float, float]:
        sin_phi = math.sin(phi)
        n = WGS84_A / math.sqrt(1.0 - WGS84_E2 * sin_phi * sin_phi)
        return (
            (n + height) * math.cos(phi) * math.cos(lam),
            (n + height) * math.cos(phi) * math.sin(lam),
            (n * (1.0 - WGS84_E2) + height) * sin_phi,
        )

    point = ecef(lat, lon, altitude_m)
    origin = ecef(lat0, lon0, ORIGIN["altitude"])
    dx, dy, dz = (point[i] - origin[i] for i in range(3))
    east = -math.sin(lon0) * dx + math.cos(lon0) * dy
    north = -math.sin(lat0) * math.cos(lon0) * dx - math.sin(lat0) * math.sin(lon0) * dy + math.cos(lat0) * dz
    up = math.cos(lat0) * math.cos(lon0) * dx + math.cos(lat0) * math.sin(lon0) * dy + math.sin(lat0) * dz
    return east, north, up


def build_query(bounds: tuple[float, float, float, float]) -> str:
    south, west, north, east = bounds
    return (
        '[out:json][timeout:120];'
        f'way["natural"="coastline"]({south},{west},{north},{east});'
        "out geom;"
    )


def fetch_raw_data() -> list[Path]:
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    paths: list[Path] = []
    for side, bounds in QUERY_HALVES.items():
        destination = RAW_DIR / f"oresund_{side}.osm.json"
        body = urlencode({"data": build_query(bounds)}).encode("utf-8")
        request = Request(
            OVERPASS_URL,
            data=body,
            headers={
                "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
                "User-Agent": "SeaPrototype-CoastlineBuilder/1.0 (public OSM coastline query)",
            },
        )
        last_error: Exception | None = None
        for attempt in range(3):
            try:
                with urlopen(request, timeout=180) as response:
                    payload = response.read()
                parsed = json.loads(payload)
                if not isinstance(parsed.get("elements"), list):
                    raise ValueError("Overpass response did not contain an elements array")
                destination.write_bytes(payload)
                print(f"Saved {destination.relative_to(PROJECT_ROOT)} ({len(payload):,} bytes)")
                paths.append(destination)
                break
            except (HTTPError, URLError, TimeoutError, OSError, ValueError, json.JSONDecodeError) as error:
                last_error = error
                if attempt < 2:
                    delay = 2 ** (attempt + 1)
                    print(f"Overpass {side} request failed ({error}); retrying in {delay}s", file=sys.stderr)
                    time.sleep(delay)
        else:
            raise RuntimeError(f"Could not fetch {side} coastline data: {last_error}")
    return paths


def _iter_lines(geometry: Any) -> Iterable[Any]:
    if geometry.is_empty:
        return
    if geometry.geom_type == "LineString":
        yield geometry
    elif geometry.geom_type in ("MultiLineString", "GeometryCollection"):
        for part in geometry.geoms:
            yield from _iter_lines(part)


def _iter_polygons(geometry: Any) -> Iterable[Any]:
    if geometry.is_empty:
        return
    if geometry.geom_type == "Polygon":
        yield geometry
    elif geometry.geom_type in ("MultiPolygon", "GeometryCollection"):
        for part in geometry.geoms:
            yield from _iter_polygons(part)


def _classify_land_from_coastlines(paths: list[Path], raster_resolution_m: float) -> tuple[Any, Any, dict[str, Any]]:
    try:
        import numpy as np
        from shapely.geometry import LineString, Point, Polygon, box
        from shapely.ops import unary_union
        from shapely.strtree import STRtree
        from shapely.validation import make_valid
    except ImportError as error:
        raise RuntimeError("Missing Shapely. Install it with: python3 -m pip install -r tools/requirements-geodata.txt") from error

    ways: dict[int, dict[str, Any]] = {}
    timestamps: list[str] = []
    for source_path in paths:
        payload = json.loads(source_path.read_text(encoding="utf-8"))
        osm_base = payload.get("osm3s", {}).get("timestamp_osm_base")
        if osm_base:
            timestamps.append(osm_base)
        for element in payload.get("elements", []):
            if element.get("type") == "way" and element.get("tags", {}).get("natural") == "coastline":
                if len(element.get("geometry", [])) >= 2:
                    ways[int(element["id"])] = element

    west, south, east, north = BOUNDS["west"], BOUNDS["south"], BOUNDS["east"], BOUNDS["north"]
    boundary_geo: list[tuple[float, float]] = []
    steps = 48
    for index in range(steps):
        t = index / steps
        boundary_geo.append((west + (east - west) * t, south))
    for index in range(steps):
        t = index / steps
        boundary_geo.append((east, south + (north - south) * t))
    for index in range(steps):
        t = index / steps
        boundary_geo.append((east - (east - west) * t, north))
    for index in range(steps):
        t = index / steps
        boundary_geo.append((west, north - (north - south) * t))
    boundary_xy = [geodetic_to_local(lat, lon)[:2] for lon, lat in boundary_geo]
    region = Polygon(boundary_xy)

    clipped_lines: list[Any] = []
    for element in ways.values():
        coordinates = [geodetic_to_local(float(node["lat"]), float(node["lon"]))[:2] for node in element["geometry"]]
        line = LineString(coordinates)
        if line.length <= 0.25:
            continue
        clipped_lines.extend(part for part in _iter_lines(line.intersection(region)) if part.length > 0.25)
    if not clipped_lines:
        raise RuntimeError("No coastline segments intersect the configured WGS84 region")

    # Polygonizing incomplete coast chains leaves large faces that can contain
    # both land and water. Instead, classify a modest offline raster by crossing
    # parity from a known water point, then vectorize only the land runs.
    segment_by_key: dict[tuple[int, int, int, int], Any] = {}
    for line in clipped_lines:
        points = list(line.coords)
        for p0, p1 in zip(points, points[1:]):
            dx = p1[0] - p0[0]
            dy = p1[1] - p0[1]
            length = math.hypot(dx, dy)
            if length < 0.25:
                continue
            # Duplicate segments would toggle parity twice, so keep one copy of
            # each undirected segment at millimetre coordinate precision.
            a = (round(p0[0] * 1000.0), round(p0[1] * 1000.0))
            b = (round(p1[0] * 1000.0), round(p1[1] * 1000.0))
            key = (a[0], a[1], b[0], b[1]) if a <= b else (b[0], b[1], a[0], a[1])
            if key not in segment_by_key:
                segment_by_key[key] = LineString((p0, p1))
    coastline_segments = list(segment_by_key.values())
    if not coastline_segments:
        raise RuntimeError("No usable coastline segments remain after clipping")
    segment_tree = STRtree(coastline_segments)

    min_x, min_y, max_x, max_y = region.bounds
    width = math.ceil((max_x - min_x) / raster_resolution_m)
    height = math.ceil((max_y - min_y) / raster_resolution_m)
    if width * height > 60_000_000:
        raise RuntimeError(f"Raster would contain {width * height:,} cells; increase --raster-resolution")

    water_seed_east, water_seed_north, _up = geodetic_to_local(WATER_SEED["latitude"], WATER_SEED["longitude"])
    water_seed = Point(water_seed_east, water_seed_north)
    _nearest_indices, nearest_distances = segment_tree.query_nearest(water_seed, return_distance=True)
    nearest_coastline_distance_m = float(min(nearest_distances))
    if nearest_coastline_distance_m < raster_resolution_m * 4.0:
        raise RuntimeError("Configured water seed is too close to the coastline; choose a safer sea point")

    x_centres = min_x + (np.arange(width, dtype=np.float64) + 0.5) * raster_resolution_m
    land_spans = []
    land_cell_count = 0
    row_crossing_count = 0
    diagonal_crossing_count = 0
    # The irrational-looking row offset avoids repeatedly sampling exact OSM
    # vertices, where two adjacent segments can otherwise look like one crossing.
    row_offset = 0.38196601125
    for row in range(height):
        y = min_y + (row + row_offset) * raster_resolution_m
        scanline = LineString(((min_x - raster_resolution_m, y), (max_x + raster_resolution_m, y)))
        crossing_xs: list[float] = []
        for segment_index in segment_tree.query(scanline, predicate="crosses"):
            intersection = scanline.intersection(coastline_segments[int(segment_index)])
            if intersection.geom_type == "Point":
                if min_x < intersection.x < max_x:
                    crossing_xs.append(float(intersection.x))
            elif intersection.geom_type == "MultiPoint":
                crossing_xs.extend(float(point.x) for point in intersection.geoms if min_x < point.x < max_x)
        crossing_xs.sort()
        row_crossing_count += len(crossing_xs)

        row_section = region.intersection(scanline)
        if row_section.is_empty:
            continue
        row_left = float(row_section.bounds[0])
        row_right = float(row_section.bounds[2])
        active_columns = np.flatnonzero((x_centres > row_left) & (x_centres < row_right))
        if active_columns.size == 0:
            continue
        first_column = int(active_columns[0])
        last_column = int(active_columns[-1])
        row_start = Point(float(x_centres[first_column]), y)
        water_ray = LineString((water_seed, row_start))
        diagonal_crossings = len(segment_tree.query(water_ray, predicate="crosses")) if water_ray.length > 0.0 else 0
        diagonal_crossing_count += diagonal_crossings
        state_at_first_cell = diagonal_crossings % 2 == 1

        # The seed is water. Every coastline crossing changes land/water side.
        crossings_right_of_start = [x for x in crossing_xs if x > x_centres[first_column]]
        row_x_centres = x_centres[first_column:last_column + 1]
        crossing_counts = np.searchsorted(crossings_right_of_start, row_x_centres, side="left")
        row_is_land = np.logical_xor(state_at_first_cell, crossing_counts % 2 == 1)
        land_cell_count += int(np.count_nonzero(row_is_land))
        padded = np.concatenate((np.array([False]), row_is_land, np.array([False]))).astype(np.int8)
        starts = np.flatnonzero(np.diff(padded) == 1)
        ends = np.flatnonzero(np.diff(padded) == -1)
        cell_bottom = min_y + row * raster_resolution_m
        for start, end in zip(starts, ends):
            start_column = first_column + int(start)
            end_column = first_column + int(end)
            land_spans.append(box(
                min_x + start_column * raster_resolution_m,
                cell_bottom,
                min_x + end_column * raster_resolution_m,
                cell_bottom + raster_resolution_m,
            ))

    if not land_spans:
        raise RuntimeError("Coastline crossing classification found no land cells")
    land = unary_union(land_spans).intersection(region)
    land = make_valid(land)
    polygon_parts = [part for part in _iter_polygons(land) if part.area > 1.0]
    if not polygon_parts:
        raise RuntimeError("Land classification produced no polygonal geometry")
    land = unary_union(polygon_parts)
    bridge_east, bridge_north, _bridge_up = geodetic_to_local(
        LANDMARKS["oresund_bridge"]["latitude"], LANDMARKS["oresund_bridge"]["longitude"]
    )

    qa = {
        "raw_coastline_ways": len(ways),
        "clipped_line_parts": len(clipped_lines),
        "unique_coastline_segments": len(coastline_segments),
        "land_components": len(list(_iter_polygons(land))),
        "land_area_km2": land.area / 1_000_000.0,
        "classification_method": "scanline parity from known water seed",
        "raster_resolution_m": raster_resolution_m,
        "raster_dimensions_cells": [width, height],
        "raster_land_cells": land_cell_count,
        "scanline_crossings": row_crossing_count,
        "water_ray_crossings": diagonal_crossing_count,
        "water_seed_wgs84": WATER_SEED,
        "water_seed_nearest_coastline_m": nearest_coastline_distance_m,
        "water_seed_classified_as_water": not land.covers(water_seed),
        "bridge_midpoint_classified_as_water": not land.covers(Point(bridge_east, bridge_north)),
        "osm_timestamp_base": sorted(set(timestamps)),
        "landmark_checks": {},
    }
    for key in ("malmo", "copenhagen", "saltholm"):
        marker = LANDMARKS[key]
        x, y, _up = geodetic_to_local(marker["latitude"], marker["longitude"])
        qa["landmark_checks"][key] = bool(land.covers(Point(x, y)))
    if not qa["water_seed_classified_as_water"]:
        raise RuntimeError("Land mask includes the configured sea seed; coastline parity is inconsistent")
    if not qa["bridge_midpoint_classified_as_water"]:
        raise RuntimeError("Approximate Øresund Bridge midpoint was classified as land")
    failed_landmarks = [key for key, is_land in qa["landmark_checks"].items() if not is_land]
    if failed_landmarks:
        raise RuntimeError("Expected land reference points classified as water: " + ", ".join(failed_landmarks))
    return land, region, qa


def _mesh_for_geometry(geometry: Any, tolerance_m: float) -> dict[str, Any]:
    from shapely.ops import triangulate

    simplified = geometry.simplify(tolerance_m, preserve_topology=True)
    vertices: list[list[float]] = []
    indices: list[int] = []
    lookup: dict[tuple[int, int], int] = {}
    accepted_triangles = 0

    for polygon in _iter_polygons(simplified):
        for triangle in triangulate(polygon):
            if not polygon.covers(triangle):
                continue
            coords = list(triangle.exterior.coords)[:3]
            if len(coords) != 3 or triangle.area <= 0.001:
                continue
            for east, north in coords:
                key = (round(east * 1000), round(north * 1000))
                vertex_index = lookup.get(key)
                if vertex_index is None:
                    vertex_index = len(vertices)
                    lookup[key] = vertex_index
                    vertices.append([key[0] / 1000.0, key[1] / 1000.0])
                indices.append(vertex_index)
            accepted_triangles += 1

    if not indices:
        raise RuntimeError(f"Triangulation generated no land triangles at {tolerance_m:g} m tolerance")
    return {
        "simplification_tolerance_m": tolerance_m,
        "vertices_east_north_m": vertices,
        "indices": indices,
        "triangle_count": accepted_triangles,
    }


def process(paths: list[Path], output_path: Path, tolerances: list[float], raster_resolution_m: float) -> None:
    if raster_resolution_m <= 0.0:
        raise RuntimeError("Raster resolution must be greater than zero metres")
    land, region, qa = _classify_land_from_coastlines(paths, raster_resolution_m)
    lods = [_mesh_for_geometry(land, tolerance) for tolerance in tolerances]
    min_x, min_y, max_x, max_y = region.bounds
    result = {
        "schema_version": 1,
        "source": "OpenStreetMap contributors · natural=coastline",
        "license": "ODbL-1.0",
        "overpass_endpoint": OVERPASS_URL,
        "source_file_manifest": [
            {"file": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
            for path in paths
        ],
        "wgs84_bounds": [BOUNDS["west"], BOUNDS["south"], BOUNDS["east"], BOUNDS["north"]],
        "local_frame": {
            "method": "WGS84 geodetic to ECEF to local East-North-Up tangent plane",
            "origin_latitude_deg": ORIGIN["latitude"],
            "origin_longitude_deg": ORIGIN["longitude"],
            "origin_altitude_m": ORIGIN["altitude"],
            "godot_axes": "X=east, Y=up, Z=-north; one unit is one metre",
        },
        "mesh_generation": {"method": "coastline scanline parity rasterized to land spans", "raster_resolution_m": raster_resolution_m},
        "bounds_east_north_m": [min_x, min_y, max_x, max_y],
        "qa": qa,
        "lods": lods,
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(result, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    try:
        display_path = output_path.relative_to(PROJECT_ROOT)
    except ValueError:
        display_path = output_path
    print(f"Wrote {display_path} ({output_path.stat().st_size:,} bytes)")
    print(f"Land area: {qa['land_area_km2']:.1f} km² across {qa['land_components']} components")
    print(f"QA: land references={qa['landmark_checks']}; water seed={qa['water_seed_classified_as_water']}; bridge midpoint water={qa['bridge_midpoint_classified_as_water']}")
    print(f"Triangles by LOD: {[lod['triangle_count'] for lod in lods]}")
    print(f"OSM base timestamps: {', '.join(qa['osm_timestamp_base']) or 'missing'}")
    print(f"City anchors on land: {qa['landmark_checks']}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--download", action="store_true", help="Fetch split coastline extracts from Overpass before processing")
    parser.add_argument("--source", action="append", type=Path, help="Raw Overpass JSON file; may be repeated")
    parser.add_argument("--output", type=Path, default=OUTPUT_PATH, help="Processed Godot map data path")
    parser.add_argument("--tolerances", type=float, nargs="+", default=[15.0, 80.0, 250.0], help="Simplification tolerances in metres, from detailed to coarse")
    parser.add_argument("--raster-resolution", type=float, default=15.0, help="Offline land classification cell size in metres (default: 15)")
    args = parser.parse_args()

    try:
        paths = fetch_raw_data() if args.download else (args.source or [RAW_DIR / "oresund_west.osm.json", RAW_DIR / "oresund_east.osm.json"])
        missing = [path for path in paths if not path.is_file()]
        if missing:
            raise RuntimeError("Missing raw OSM input: " + ", ".join(str(path) for path in missing) + ". Run with --download when online.")
        if any(tolerance < 0.0 for tolerance in args.tolerances):
            raise RuntimeError("Simplification tolerances must be non-negative metres")
        process(paths, args.output, args.tolerances, args.raster_resolution)
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
