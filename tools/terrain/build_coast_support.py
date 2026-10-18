#!/usr/bin/env python3
"""Scan Oresund coast gaps and build separately marked depth/coast support data."""

from __future__ import annotations

import hashlib
import heapq
import json
import math
import struct
from pathlib import Path

import numpy as np
from PIL import Image
from shapely import LineString, STRtree, distance, points

from build_terrain import reconstruct_land_mask


ROOT = Path(__file__).resolve().parents[2]
BATHY_DIR = ROOT / "assets/geodata/processed/bathymetry"
TERRAIN_DIR = ROOT / "assets/terrain/processed/oresund_terrain"
TERRAIN_MANIFEST = TERRAIN_DIR / "manifest.json"
COAST_JSON = ROOT / "assets/geodata/processed/oresund_region.json"
DEPTH_ESTIMATES = BATHY_DIR / "depth_estimates.json"
COAST_MESH = TERRAIN_DIR / "coast_transition.bin"
COAST_METADATA = TERRAIN_DIR / "coast_transition.json"
REPORT_PATH = ROOT / "docs/coast_support_scan_report.json"

INVALID_DEPTH_DM = -32768
LAND_MASK_THRESHOLD = 128
MAX_ESTIMATE_RADIUS_M = 260.0
MAX_ESTIMATE_NEIGHBORS = 4
MAX_NEIGHBOR_SPREAD_M = 12.0
# The terrain is clipped from the processed land mesh. Matching a separate
# shoreline extract can differ by metres and leave the actual terrain edge open.
COAST_MATCH_TOLERANCE_M = 0.05
SEA_LEVEL_Y_M = 0.0
SUBMERGED_DEPTH_M = 0.3
MAX_SLOPE_ANGLE_DEG = 35.0
MAX_SLOPE_WIDTH_M = 16.0
MIN_SLOPE_WIDTH_M = 1.5
COAST_END_FADE_M = 40.0
SAND_UNDERWATER_COLOR = np.array([0.43, 0.39, 0.32, 1.0], dtype=np.float64)


def _iter_lines(geometry):
    if geometry.is_empty:
        return
    if geometry.geom_type == "LineString":
        yield geometry
    elif geometry.geom_type in ("MultiLineString", "GeometryCollection"):
        for part in geometry.geoms:
            yield from _iter_lines(part)


def _terrain_source_coast_segments() -> tuple[list[LineString], bytes]:
    """Build coastline segments from the exact land mask used to clip terrain."""
    source_bytes = COAST_JSON.read_bytes()
    region_data = json.loads(source_bytes)
    land, region, _expected_land_area_km2 = reconstruct_land_mask(region_data)
    coast = land.boundary.difference(region.boundary.buffer(150.0))
    segments: list[LineString] = []
    for line in _iter_lines(coast):
        coordinates = list(line.coords)
        for index in range(len(coordinates) - 1):
            first = coordinates[index]
            second = coordinates[index + 1]
            if math.hypot(second[0] - first[0], second[1] - first[1]) > 1e-6:
                segments.append(LineString((first, second)))
    if not segments:
        raise RuntimeError("The terrain source land mask has no usable coastline segments")
    return segments, source_bytes


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def local_grid_coordinates(metadata: dict) -> tuple[np.ndarray, np.ndarray]:
    """Vectorized WGS84 ECEF-to-ENU transform matching GeoReference."""
    rows = int(metadata["rows"])
    columns = int(metadata["columns"])
    lat = float(metadata["south_latitude_deg"]) + np.arange(rows, dtype=np.float64) * float(metadata["latitude_step_deg"])
    lon = float(metadata["west_longitude_deg"]) + np.arange(columns, dtype=np.float64) * float(metadata["longitude_step_deg"])
    latitude, longitude = np.meshgrid(np.radians(lat), np.radians(lon), indexing="ij")
    a = 6378137.0
    f = 1.0 / 298.257223563
    e2 = f * (2.0 - f)
    origin_lat = math.radians(float(metadata["georeference_origin"]["latitude_deg"]))
    origin_lon = math.radians(float(metadata["georeference_origin"]["longitude_deg"]))

    def ecef(phi: np.ndarray | float, lam: np.ndarray | float) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
        sin_phi = np.sin(phi)
        cos_phi = np.cos(phi)
        radius = a / np.sqrt(1.0 - e2 * sin_phi * sin_phi)
        return (
            radius * cos_phi * np.cos(lam),
            radius * cos_phi * np.sin(lam),
            radius * (1.0 - e2) * sin_phi,
        )

    px, py, pz = ecef(latitude, longitude)
    ox, oy, oz = ecef(origin_lat, origin_lon)
    dx, dy, dz = px - ox, py - oy, pz - oz
    east = -math.sin(origin_lon) * dx + math.cos(origin_lon) * dy
    north = (
        -math.sin(origin_lat) * math.cos(origin_lon) * dx
        - math.sin(origin_lat) * math.sin(origin_lon) * dy
        + math.cos(origin_lat) * dz
    )
    return east, north


def mask_indices(east: np.ndarray, north: np.ndarray, land_meta: dict, shape: tuple[int, int]) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    min_east, _min_north, _max_east, max_north = map(float, land_meta["bounds_east_north_m"])
    cell_size = float(land_meta["cell_size_m"])
    x = np.floor((east - min_east) / cell_size).astype(np.int32)
    y = np.floor((max_north - north) / cell_size).astype(np.int32)
    inside = (x >= 0) & (x < shape[1]) & (y >= 0) & (y < shape[0])
    return x, y, inside


def scan_depth_holes() -> tuple[dict, list[list[object]]]:
    metadata = read_json(BATHY_DIR / "grid_metadata.json")
    manifest = read_json(BATHY_DIR / "manifest.json")
    grid_path = BATHY_DIR / str(metadata["binary_file"])
    raw = np.fromfile(grid_path, dtype=np.dtype([("depth", "<i2"), ("interpolation", "u1"), ("count", "u1")]))
    rows, columns = int(metadata["rows"]), int(metadata["columns"])
    if raw.size != rows * columns:
        raise RuntimeError("Bathymetry binary dimensions do not match metadata")
    raw = raw.reshape(rows, columns)
    depth_dm = raw["depth"]
    source_valid = depth_dm != int(metadata["invalid_depth_code"])
    east, north = local_grid_coordinates(metadata)
    land_meta = manifest["land_mask"]
    land_mask_path = BATHY_DIR / land_meta["file"]
    land_mask_bytes = land_mask_path.read_bytes()
    land_image = np.asarray(Image.open(land_mask_path).convert("L"))
    mask_x, mask_y, inside = mask_indices(east, north, land_meta, land_image.shape)
    land = np.zeros((rows, columns), dtype=bool)
    land[inside] = land_image[mask_y[inside], mask_x[inside]] >= LAND_MASK_THRESHOLD
    valid_water = source_valid & inside & ~land
    unknown_water = ~source_valid & inside & ~land
    padded_land = np.pad(land_image >= LAND_MASK_THRESHOLD, 1, mode="constant", constant_values=True)
    near_land = np.zeros((rows, columns), dtype=bool)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            ix = np.clip(mask_x + 1 + dx, 0, padded_land.shape[1] - 1)
            iy = np.clip(mask_y + 1 + dy, 0, padded_land.shape[0] - 1)
            near_land |= padded_land[iy, ix] & inside

    def line_is_water(start: tuple[float, float], end: tuple[float, float]) -> bool:
        distance_m = math.hypot(end[0] - start[0], end[1] - start[1])
        steps = max(1, math.ceil(distance_m / (float(land_meta["cell_size_m"]) * 0.5)))
        for step in range(steps + 1):
            t = step / steps
            x = start[0] + (end[0] - start[0]) * t
            y = start[1] + (end[1] - start[1]) * t
            mx = math.floor((x - float(land_meta["bounds_east_north_m"][0])) / float(land_meta["cell_size_m"]))
            my = math.floor((float(land_meta["bounds_east_north_m"][3]) - y) / float(land_meta["cell_size_m"]))
            if not (0 <= mx < land_image.shape[1] and 0 <= my < land_image.shape[0]):
                return False
            if land_image[my, mx] >= LAND_MASK_THRESHOLD:
                return False
        return True

    unknown_rows, unknown_columns = np.nonzero(unknown_water)
    estimates: list[list[object]] = []
    near_coast_count = 0
    rejected_neighbor_spread = 0
    no_neighbors = 0
    for row, column in zip(unknown_rows.tolist(), unknown_columns.tolist()):
        neighbors: list[tuple[float, float]] = []
        origin = (float(east[row, column]), float(north[row, column]))
        for row_offset in range(-2, 3):
            for column_offset in range(-3, 4):
                if row_offset == 0 and column_offset == 0:
                    continue
                neighbor_row = row + row_offset
                neighbor_column = column + column_offset
                if not (0 <= neighbor_row < rows and 0 <= neighbor_column < columns):
                    continue
                if not valid_water[neighbor_row, neighbor_column]:
                    continue
                target = (float(east[neighbor_row, neighbor_column]), float(north[neighbor_row, neighbor_column]))
                distance_m = math.hypot(target[0] - origin[0], target[1] - origin[1])
                if distance_m > MAX_ESTIMATE_RADIUS_M or not line_is_water(origin, target):
                    continue
                neighbors.append((distance_m, float(depth_dm[neighbor_row, neighbor_column]) * 0.1))
        neighbors.sort(key=lambda item: item[0])
        neighbors = neighbors[:MAX_ESTIMATE_NEIGHBORS]
        if len(neighbors) < 3:
            no_neighbors += 1
            continue
        depths = [item[1] for item in neighbors]
        spread = max(depths) - min(depths)
        if spread > MAX_NEIGHBOR_SPREAD_M:
            rejected_neighbor_spread += 1
            continue
        is_near_coast = bool(near_land[row, column])
        near_coast_count += int(is_near_coast)
        uncertainty_m = 2.0 if is_near_coast else 1.0
        estimate_m = max(0.0, min(depths) - uncertainty_m)
        confidence = "low" if is_near_coast or spread > 6.0 else "medium"
        estimates.append([row, column, round(estimate_m * 10.0), len(neighbors), confidence, round(spread * 10.0)])

    estimated_indices = {(int(item[0]), int(item[1])) for item in estimates}
    unresolved_water_cells = [
        [int(row), int(column)]
        for row, column in zip(unknown_rows.tolist(), unknown_columns.tolist())
        if (int(row), int(column)) not in estimated_indices
    ]

    estimate_metadata = {
        "schema_version": 1,
        "grid_rows": rows,
        "grid_columns": columns,
        "source": "Conservative game estimate from nearby valid EMODnet DTM water cells",
        "source_grid_sha256": hashlib.sha256(grid_path.read_bytes()).hexdigest(),
        "source_land_mask_sha256": hashlib.sha256(land_mask_bytes).hexdigest(),
        "source_land_mask": "OpenStreetMap coastline-derived land mask; 30 m cells",
        "method": "Minimum of up to four nearest valid water cells with a water-only line of sight; subtract 1 m inland or 2 m in the coastal buffer; gaps over 12 m neighbor spread stay unknown",
        "quality": "Estimate only; not surveyed and not navigation-grade",
        "max_estimate_radius_m": MAX_ESTIMATE_RADIUS_M,
        "estimates": estimates,
        "unresolved_water_cells": unresolved_water_cells,
    }
    summary = {
        "grid_shape": [rows, columns],
        "grid_resolution_approx_m": [round(float(np.median(np.diff(north[:, 0]))), 1), round(float(np.median(np.diff(east[0, :]))), 1)],
        "source_valid_cells": int(source_valid.sum()),
        "known_osm_land_grid_centers": int((inside & land).sum()),
        "known_osm_water_grid_centers": int((inside & ~land).sum()),
        "unknown_water_cells": int(unknown_water.sum()),
        "estimated_water_cells": len(estimates),
        "estimated_near_coast_cells": near_coast_count,
        "estimated_interior_cells": len(estimates) - near_coast_count,
        "estimate_confidence_counts": {
            level: sum(1 for item in estimates if item[4] == level) for level in ("medium", "low")
        },
        "unknown_cells_without_three_visible_neighbors": no_neighbors,
        "unknown_cells_rejected_for_depth_spread": rejected_neighbor_spread,
        "unknown_cells_not_estimated": int(unknown_water.sum()) - len(estimates),
        "unresolved_water_cell_count": len(unresolved_water_cells),
        "original_grid_sha256": estimate_metadata["source_grid_sha256"],
        "estimate_method": estimate_metadata["method"],
    }
    return {"summary": summary, "metadata": estimate_metadata}, estimates


def load_terrain_geometry() -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    manifest = read_json(TERRAIN_MANIFEST)
    dtype = np.dtype([("position", "<f4", (3,)), ("normal", "<f4", (3,)), ("color", "<f4", (4,))])
    vertex_positions: list[np.ndarray] = []
    vertex_normals: list[np.ndarray] = []
    vertex_colors: list[np.ndarray] = []
    triangle_indices: list[np.ndarray] = []
    vertex_offset = 0
    for entry in manifest["chunks"]:
        payload = (TERRAIN_DIR / entry["file"]).read_bytes()
        if payload[:4] != b"OZTR":
            raise RuntimeError(f"Invalid terrain chunk header: {entry['file']}")
        version, vertex_count, index_count = struct.unpack_from("<III", payload, 4)
        if version != 1 or len(payload) != 16 + vertex_count * 40 + index_count * 4:
            raise RuntimeError(f"Invalid terrain chunk layout: {entry['file']}")
        vertices = np.frombuffer(payload, dtype=dtype, count=vertex_count, offset=16)
        vertex_positions.append(vertices["position"].astype(np.float64))
        vertex_normals.append(vertices["normal"].astype(np.float64))
        vertex_colors.append(vertices["color"].astype(np.float64))
        indices = np.frombuffer(payload, dtype="<u4", count=index_count, offset=16 + vertex_count * 40).astype(np.int64)
        triangle_indices.append(indices.reshape(-1, 3) + vertex_offset)
        vertex_offset += vertex_count
    positions = np.concatenate(vertex_positions)
    positions[:, 1] = np.maximum(positions[:, 1], 0.5)
    normals = np.concatenate(vertex_normals)
    colors = np.concatenate(vertex_colors)
    triangles = np.concatenate(triangle_indices)
    coordinate_keys = np.rint(positions[:, [0, 2]] * 1000.0).astype(np.int64)
    unique_keys, inverse = np.unique(coordinate_keys, axis=0, return_inverse=True)
    unique_positions = np.empty((len(unique_keys), 3), dtype=np.float64)
    unique_positions[:, 0] = unique_keys[:, 0] / 1000.0
    unique_positions[:, 2] = unique_keys[:, 1] / 1000.0
    for axis in (1,):
        sums = np.bincount(inverse, weights=positions[:, axis], minlength=len(unique_keys))
        counts = np.bincount(inverse, minlength=len(unique_keys))
        unique_positions[:, axis] = sums / counts
    unique_normals = np.column_stack([
        np.bincount(inverse, weights=normals[:, channel], minlength=len(unique_keys))
        for channel in range(3)
    ])
    unique_colors = np.column_stack([
        np.bincount(inverse, weights=colors[:, channel], minlength=len(unique_keys)) / np.bincount(inverse, minlength=len(unique_keys))
        for channel in range(4)
    ])
    return unique_positions, unique_normals, unique_colors, inverse[triangles], triangles


def build_coast_transition_mesh() -> tuple[dict, bytes]:
    positions, normals, colors, triangles, raw_triangles = load_terrain_geometry()
    edge_pairs = np.concatenate((triangles[:, [0, 1]], triangles[:, [1, 2]], triangles[:, [2, 0]]))
    edge_interiors = np.concatenate((triangles[:, 2], triangles[:, 0], triangles[:, 1]))
    edge_pairs.sort(axis=1)
    unique_edges, first_indices, edge_counts = np.unique(edge_pairs, axis=0, return_index=True, return_counts=True)
    open_edges = unique_edges[edge_counts == 1]
    first_indices = first_indices[edge_counts == 1]
    interior_vertices = edge_interiors[first_indices]

    coast_segments, source_coast_bytes = _terrain_source_coast_segments()
    coast_tree = STRtree(coast_segments)
    midpoint = (positions[open_edges[:, 0]][:, [0, 2]] + positions[open_edges[:, 1]][:, [0, 2]]) * 0.5
    coast_points = points(midpoint[:, 0], -midpoint[:, 1])
    nearest_indices = coast_tree.nearest(coast_points)
    coast_distances = np.asarray(distance(coast_points, np.asarray(coast_segments, dtype=object)[nearest_indices]), dtype=np.float64)
    matched_mask = coast_distances <= COAST_MATCH_TOLERANCE_M
    matched_edges = open_edges[matched_mask]
    matched_interiors = interior_vertices[matched_mask]
    matched_midpoints = midpoint[matched_mask]
    matched_lengths = np.linalg.norm(positions[matched_edges[:, 1]][:, [0, 2]] - positions[matched_edges[:, 0]][:, [0, 2]], axis=1)
    if not len(matched_edges):
        raise RuntimeError("No open terrain edge matches the OSM coastline")

    edge_seaward: list[np.ndarray] = []
    vertex_outward = np.zeros((len(positions), 2), dtype=np.float64)
    vertex_degree = np.zeros(len(positions), dtype=np.int32)
    adjacency: dict[int, list[tuple[int, float]]] = {}
    for edge_index, (first, second) in enumerate(matched_edges):
        a = positions[first, [0, 2]]
        b = positions[second, [0, 2]]
        tangent = b - a
        length = float(np.linalg.norm(tangent))
        if length <= 1e-6:
            edge_seaward.append(np.array([0.0, 0.0]))
            continue
        tangent /= length
        perpendicular = np.array([-tangent[1], tangent[0]])
        midpoint_xz = (a + b) * 0.5
        interior = positions[matched_interiors[edge_index], [0, 2]] - midpoint_xz
        seaward = perpendicular if float(np.dot(perpendicular, interior)) < 0.0 else -perpendicular
        edge_seaward.append(seaward)
        vertex_outward[first] += seaward * length
        vertex_outward[second] += seaward * length
        vertex_degree[first] += 1
        vertex_degree[second] += 1
        adjacency.setdefault(int(first), []).append((int(second), length))
        adjacency.setdefault(int(second), []).append((int(first), length))

    # Fade only where the OSM/terrain run actually terminates (usually the crop edge).
    distance_from_open_end = np.full(len(positions), np.inf, dtype=np.float64)
    heap: list[tuple[float, int]] = []
    for vertex_id, degree in enumerate(vertex_degree):
        if degree == 1:
            distance_from_open_end[vertex_id] = 0.0
            heapq.heappush(heap, (0.0, vertex_id))
    while heap:
        distance_m, vertex_id = heapq.heappop(heap)
        if distance_m != distance_from_open_end[vertex_id]:
            continue
        for neighbor_id, edge_length in adjacency.get(vertex_id, []):
            candidate = distance_m + edge_length
            if candidate < distance_from_open_end[neighbor_id]:
                distance_from_open_end[neighbor_id] = candidate
                heapq.heappush(heap, (candidate, neighbor_id))

    target_y = SEA_LEVEL_Y_M - SUBMERGED_DEPTH_M
    slope_tangent = math.tan(math.radians(MAX_SLOPE_ANGLE_DEG))
    vertex_rows: dict[tuple[int, int], int] = {}
    mesh_vertices: list[np.ndarray] = []
    mesh_normals: list[np.ndarray] = []
    mesh_colors: list[np.ndarray] = []
    normal_sums: list[np.ndarray] = []
    top_normal_by_index: dict[int, np.ndarray] = {}
    max_width = 0.0
    min_top = math.inf
    max_top = -math.inf
    for edge in matched_edges:
        for vertex_id in edge:
            key = int(vertex_id)
            if (key, 0) in vertex_rows:
                continue
            outward = vertex_outward[key]
            norm = float(np.linalg.norm(outward))
            if norm <= 1e-8:
                continue
            outward = outward / norm
            top = positions[key]
            drop = max(float(top[1]) - target_y, 0.0)
            width = min(max(drop * 1.5 / max(slope_tangent, 0.1), MIN_SLOPE_WIDTH_M), MAX_SLOPE_WIDTH_M)
            fade = 1.0
            end_distance = float(distance_from_open_end[key])
            if math.isfinite(end_distance):
                t_fade = min(max(end_distance / COAST_END_FADE_M, 0.0), 1.0)
                fade = t_fade * t_fade * (3.0 - 2.0 * t_fade)
            max_width = max(max_width, width * fade)
            min_top = min(min_top, float(top[1]))
            max_top = max(max_top, float(top[1]))
            for row, row_t in enumerate((0.0, 1.0 / 3.0, 2.0 / 3.0, 1.0)):
                curve = row_t * row_t * (3.0 - 2.0 * row_t)
                position = np.array([
                    top[0] + outward[0] * width * fade * row_t,
                    top[1] - drop * curve,
                    top[2] + outward[1] * width * fade * row_t,
                ], dtype=np.float64)
                color = colors[key] * (1.0 - curve) + SAND_UNDERWATER_COLOR * curve
                vertex_rows[(key, row)] = len(mesh_vertices)
                mesh_vertices.append(position)
                mesh_normals.append(np.array([0.0, 1.0, 0.0], dtype=np.float64))
                normal_sums.append(np.zeros(3, dtype=np.float64))
                mesh_colors.append(color)
                if row == 0:
                    source_normal = normals[key]
                    if source_normal[1] < 0.0:
                        source_normal = -source_normal
                    top_normal_by_index[vertex_rows[(key, row)]] = source_normal

    mesh_indices: list[int] = []
    triangle_count = 0
    winding_error_count = 0
    lower_min = math.inf
    lower_max = -math.inf
    for edge_index, (first, second) in enumerate(matched_edges):
        if not any((int(first), row) in vertex_rows and (int(second), row) in vertex_rows for row in range(4)):
            continue
        seaward = edge_seaward[edge_index]
        expected_normal = np.array([seaward[0], 1.0, seaward[1]], dtype=np.float64)
        expected_normal /= max(float(np.linalg.norm(expected_normal)), 1e-8)
        for row in range(3):
            triangles_for_edge = [
                (vertex_rows[(int(first), row)], vertex_rows[(int(second), row)], vertex_rows[(int(second), row + 1)]),
                (vertex_rows[(int(first), row)], vertex_rows[(int(second), row + 1)], vertex_rows[(int(first), row + 1)]),
            ]
            for tri in triangles_for_edge:
                a, b, c = (mesh_vertices[index] for index in tri)
                face = np.cross(b - a, c - a)
                if float(np.dot(face, face)) < 1e-6:
                    continue
                if float(np.dot(face, expected_normal)) > 0.0:
                    tri = (tri[0], tri[2], tri[1])
                    face = -face
                if float(np.dot(face, expected_normal)) >= -1e-6:
                    winding_error_count += 1
                mesh_indices.extend(tri)
                lighting_normal = -face
                for index in tri:
                    normal_sums[index] += lighting_normal
                triangle_count += 1
        lower = target_y
        lower_min = min(lower_min, lower)
        lower_max = max(lower_max, lower)

    for vertex_index in range(len(mesh_vertices)):
        if vertex_index in top_normal_by_index:
            normal = top_normal_by_index[vertex_index]
        else:
            normal = normal_sums[vertex_index]
            # At concave coastline joins, averaging adjacent outward normals
            # can point below the water plane. Keep lighting normals on the
            # visible sea-facing hemisphere without changing triangle winding.
            if normal[1] < 0.0:
                normal[1] = -normal[1]
        norm = float(np.linalg.norm(normal))
        mesh_normals[vertex_index] = normal / norm if norm > 1e-8 else np.array([0.0, 1.0, 0.0])

    vertex_array = np.column_stack((np.asarray(mesh_vertices), np.asarray(mesh_normals), np.asarray(mesh_colors))).astype("<f4")
    index_array = np.asarray(mesh_indices, dtype="<u4")
    header = b"OZCT" + struct.pack("<III", 1, len(vertex_array), len(index_array))
    payload = header + vertex_array.tobytes(order="C") + index_array.tobytes(order="C")
    diagnostics = {
        "terrain_open_edge_count": int(len(open_edges)),
        "osm_coastline_segment_count": len(coast_segments),
        "matched_coast_edge_count": int(len(matched_edges)),
        "unmatched_terrain_open_edge_count": int(len(open_edges) - len(matched_edges)),
        "matched_coast_length_m": round(float(matched_lengths.sum()), 1),
        "top_height_min_m": round(min_top, 3),
        "top_height_max_m": round(max_top, 3),
        "lower_edge_y_m": round(SEA_LEVEL_Y_M - SUBMERGED_DEPTH_M, 3),
        "max_slope_width_m": round(max_width, 3),
        "transition_vertex_count": len(vertex_array),
        "transition_triangle_count": triangle_count,
        "winding_error_count": winding_error_count,
        "minimum_lighting_normal_y": round(float(np.asarray(mesh_normals)[:, 1].min()), 6),
        "coastline_match_tolerance_m": COAST_MATCH_TOLERANCE_M,
        "source_terrain_manifest_sha256": hashlib.sha256(TERRAIN_MANIFEST.read_bytes()).hexdigest(),
        "source_land_mask": "Exact coastline boundary reconstructed from the OSM land mesh used by build_terrain.py; crop edges excluded",
        "source_coastline_sha256": hashlib.sha256(source_coast_bytes).hexdigest(),
        "mesh_sha256": hashlib.sha256(payload).hexdigest(),
    }
    return diagnostics, payload


def main() -> None:
    depth_data, _ = scan_depth_holes()
    coast_diagnostics, coast_payload = build_coast_transition_mesh()
    DEPTH_ESTIMATES.write_text(json.dumps(depth_data["metadata"], ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    COAST_MESH.write_bytes(coast_payload)
    coast_metadata = {
        "schema_version": 1,
        "source": "Static coastal transition generated from open terrain edges matched to the exact OSM land-mask boundary used to clip terrain",
        "quality": "Gameplay visual geometry; not surveyed coastal engineering",
        **coast_diagnostics,
    }
    COAST_METADATA.write_text(json.dumps(coast_metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    report = {
        "schema_version": 1,
        "scan_scope": "Existing Oresund region: current EMODnet grid, OSM land mask/coastlines, and all generated terrain chunks",
        "depth_holes": depth_data["summary"],
        "shoreline_gaps": coast_diagnostics,
        "outputs": {
            "depth_estimates": str(DEPTH_ESTIMATES.relative_to(ROOT)),
            "coast_transition_mesh": str(COAST_MESH.relative_to(ROOT)),
            "coast_transition_metadata": str(COAST_METADATA.relative_to(ROOT)),
        },
        "limitations": [
            "Estimated depths are gameplay-only, conservative interpolation from nearby water cells, and not navigation-grade.",
            "Terrain openings not matched to the source land-mask boundary within 0.05 m are left untouched; they are likely crop boundaries or data holes and require separate review.",
            "The static coast transition closes the matched terrain/OSM shoreline gap visually; it does not add vessel collision.",
        ],
    }
    REPORT_PATH.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
