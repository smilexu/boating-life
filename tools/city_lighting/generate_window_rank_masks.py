#!/usr/bin/env python3
"""Build deterministic near and far window masks from the city GLB albedo atlases.

Requires ImageMagick's `magick` command. Source GLBs and albedo textures are read
only. Each selected connected window group receives a stable 8-bit rank; runtime
shaders compare that rank with the current occupancy ratio.
"""

from __future__ import annotations

import array
import random
import re
import shutil
import subprocess
import sys
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
OUTPUT_DIR = ROOT / "assets/cities/malmo/window_lighting"

SOURCES = {
    "turning_torso": {
        "path": ROOT / "assets/cities/malmo/turning_torso_texture_pbr_20250901.jpg",
        "fx": "((b > r*1.18) && (g > r*1.10) && (b < 0.72) && (r < 0.48)) ? 1 : 0",
        "seed": 301,
    },
    "white_building": {
        "path": ROOT / "assets/cities/common/white_building_texture_pbr_20250901.jpg",
        "fx": "((b > r*1.12) && (g > r*1.04) && (b < 0.68) && (r < 0.50)) ? 1 : 0",
        "seed": 419,
    },
    "blue_building": {
        "path": ROOT / "assets/cities/common/blue_building_texture_pbr_20250901.jpg",
        "fx": "((b < 0.34) && (r < 0.34) && (g < 0.36)) ? 1 : 0",
        "seed": 557,
    },
    "brown_building": {
        "path": ROOT / "assets/cities/common/brown_building_texture_pbr_20250901.jpg",
        "fx": "((b > r*1.10) && (g > r*1.08) && (b < 0.55) && (r < 0.42)) ? 1 : 0",
        "seed": 673,
    },
}

COMPONENT_PATTERN = re.compile(
    r"\s*(\d+):\s+(\d+)x(\d+)\+(\d+)\+(\d+)\s+"
    r"[\d.]+,[\d.]+\s+([\d.]+)\s+"
)
CLUSTER_BUCKET_SIZE = 192.0
CLUSTER_MAX_COMPONENTS = 4


def run(arguments: list[str], *, capture_output: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(
        arguments,
        check=True,
        text=capture_output,
        stdout=subprocess.PIPE if capture_output else None,
        stderr=subprocess.PIPE if capture_output else None,
    )


def build_window_clusters(components: dict[int, dict[str, int]]) -> tuple[dict[int, int], int]:
    """Give nearby window components a shared deterministic occupancy rank.

    The atlas windows are connected-component segmented, so independent ranks
    look like isolated pinpricks at sea. Local spatial clustering keeps pairs
    and small 2–4 window groups in sync without changing their UV locations.
    """
    centers: dict[int, tuple[float, float]] = {}
    buckets: dict[tuple[int, int], list[int]] = {}
    for component_id, bounds in components.items():
        center = (
            bounds["x"] + bounds["width"] * 0.5,
            bounds["y"] + bounds["height"] * 0.5,
        )
        centers[component_id] = center
        bucket = (int(center[0] // CLUSTER_BUCKET_SIZE), int(center[1] // CLUSTER_BUCKET_SIZE))
        buckets.setdefault(bucket, []).append(component_id)

    candidates: list[tuple[float, int, int]] = []
    for component_id, bounds in components.items():
        center_x, center_y = centers[component_id]
        bucket_x = int(center_x // CLUSTER_BUCKET_SIZE)
        bucket_y = int(center_y // CLUSTER_BUCKET_SIZE)
        for offset_y in range(-4, 5):
            for offset_x in range(-4, 5):
                for other_id in buckets.get((bucket_x + offset_x, bucket_y + offset_y), []):
                    if other_id <= component_id:
                        continue
                    other = components[other_id]
                    other_x, other_y = centers[other_id]
                    dx = abs(center_x - other_x)
                    dy = abs(center_y - other_y)
                    scale_x = max(4.0, (bounds["width"] + other["width"]) * 0.5)
                    scale_y = max(4.0, (bounds["height"] + other["height"]) * 0.5)
                    same_row = dx <= max(scale_x * 3.2, 42.0) and dy <= max(scale_y * 1.45, 14.0)
                    same_column = dy <= max(scale_y * 3.2, 42.0) and dx <= max(scale_x * 1.45, 14.0)
                    if not same_row and not same_column:
                        continue
                    score = ((dx / scale_x) ** 2 + (dy / scale_y) ** 2) ** 0.5
                    candidates.append((score, component_id, other_id))

    candidates.sort()
    owner = {component_id: component_id for component_id in components}
    members = {component_id: [component_id] for component_id in components}
    for _score, first_id, second_id in candidates:
        first_root = owner[first_id]
        second_root = owner[second_id]
        if first_root == second_root:
            continue
        merged = members[first_root] + members[second_root]
        if len(merged) > CLUSTER_MAX_COMPONENTS:
            continue
        root = min(first_root, second_root)
        removed = max(first_root, second_root)
        members[root] = merged
        del members[removed]
        for member_id in merged:
            owner[member_id] = root

    cluster_ids = {root: index for index, root in enumerate(sorted(members))}
    component_clusters = {component_id: cluster_ids[owner[component_id]] for component_id in components}
    return component_clusters, len(members)


def main() -> int:
    magick = shutil.which("magick")
    if magick is None:
        print("ImageMagick `magick` was not found; no masks were generated.", file=sys.stderr)
        return 2
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    for name, config in SOURCES.items():
        source = Path(config["path"])
        candidate = OUTPUT_DIR / f".{name}_candidate.png"
        labels_png = OUTPUT_DIR / f".{name}_labels.png"
        labels_raw = OUTPUT_DIR / f".{name}_labels.raw"
        output = OUTPUT_DIR / f"{name}_window_rank.png"
        far_proxy_output = OUTPUT_DIR / f"{name}_window_far_proxy.png"

        run([magick, str(source), "-fx", str(config["fx"]), "-threshold", "50%", "-morphology", "Open", "Disk:1", str(candidate)])
        components = run(
            [magick, str(candidate), "-define", "connected-components:verbose=true", "-connected-components", "8", str(labels_png)],
            capture_output=True,
        )
        width_text, height_text = run(
            [magick, str(source), "-format", "%w %h", "info:"], capture_output=True
        ).stdout.split()
        width, height = int(width_text), int(height_text)
        run([magick, str(labels_png), "-endian", "LSB", "-depth", "16", f"gray:{labels_raw}"])

        eligible: dict[int, dict[str, int]] = {}
        for line in components.stdout.splitlines():
            match = COMPONENT_PATTERN.match(line)
            if match is None:
                continue
            component_id, box_width, box_height, x_text, y_text, area_text = match.groups()
            component_id = int(component_id)
            if component_id == 0:
                continue
            box_width, box_height = int(box_width), int(box_height)
            area = float(area_text)
            box_area = float(box_width * box_height)
            fill_ratio = area / box_area if box_area > 0.0 else 0.0
            aspect = box_width / float(box_height) if box_height > 0 else 0.0

            # The material atlases contain windows plus dark seams and AO. Keep
            # compact, reasonably filled groups and discard large wall/roof islands.
            if area < 28.0 or area > 9000.0:
                continue
            if box_width < 4 or box_height < 4 or box_width > 220 or box_height > 220:
                continue
            if fill_ratio < 0.19 or not 0.22 <= aspect <= 4.5:
                continue
            eligible[component_id] = {
                "x": int(x_text),
                "y": int(y_text),
                "width": box_width,
                "height": box_height,
                "area": int(area),
            }

        labels = array.array("H")
        labels.frombytes(labels_raw.read_bytes())
        if sys.byteorder != "little":
            labels.byteswap()
        if len(labels) != width * height:
            raise RuntimeError(f"Unexpected label dimensions for {name}: {len(labels)} != {width * height}")

        rng = random.Random(int(config["seed"]))
        component_clusters, cluster_count = build_window_clusters(eligible)
        cluster_ranks: dict[int, int] = {}
        for cluster_id in sorted(set(component_clusters.values())):
            cluster_ranks[cluster_id] = rng.randrange(1, 256)
        ranks = {
            component_id: cluster_ranks[cluster_id]
            for component_id, cluster_id in component_clusters.items()
        }
        output_pixels = bytearray(width * height)
        far_proxy_pixels = bytearray(width * height)
        for pixel_index, component_id in enumerate(labels):
            rank = ranks.get(component_id)
            if rank is not None:
                output_pixels[pixel_index] = rank

        # Remote windows are deliberately broadened into small rectangular
        # light cards in the same UV atlas. Their material pass stays attached
        # to the source facade mesh, so twisted architecture remains aligned.
        far_scale = 1.75
        for component_id, bounds in eligible.items():
            rank = ranks[component_id]
            center_x = bounds["x"] + bounds["width"] * 0.5
            center_y = bounds["y"] + bounds["height"] * 0.5
            half_width = bounds["width"] * far_scale * 0.5
            half_height = bounds["height"] * far_scale * 0.5
            left = max(0, int(center_x - half_width))
            right = min(width, int(center_x + half_width + 0.5))
            top = max(0, int(center_y - half_height))
            bottom = min(height, int(center_y + half_height + 0.5))
            for y in range(top, bottom):
                row_start = y * width
                for x in range(left, right):
                    pixel_index = row_start + x
                    previous = far_proxy_pixels[pixel_index]
                    if previous == 0 or rank < previous:
                        far_proxy_pixels[pixel_index] = rank

        raw_path = OUTPUT_DIR / f".{name}_rank.raw"
        raw_path.write_bytes(output_pixels)
        run([magick, "-size", f"{width}x{height}", "-depth", "8", f"gray:{raw_path}", "-define", "png:compression-level=9", str(output)])
        far_proxy_raw = OUTPUT_DIR / f".{name}_far_proxy.raw"
        far_proxy_raw.write_bytes(far_proxy_pixels)
        run([magick, "-size", f"{width}x{height}", "-depth", "8", f"gray:{far_proxy_raw}", "-define", "png:compression-level=9", str(far_proxy_output)])

        selected_pixels = sum(1 for value in output_pixels if value > 0)
        far_pixels = sum(1 for value in far_proxy_pixels if value > 0)
        cluster_sizes = Counter(component_clusters.values())
        clustered_components = sum(size for size in cluster_sizes.values() if size > 1)
        print(
            f"{name}: {len(eligible)} detected windows → {cluster_count} occupancy clusters "
            f"({clustered_components} windows grouped), "
            f"{selected_pixels:,} near / {far_pixels:,} far-mask pixels, {width}x{height}"
        )
        for temporary in (candidate, labels_png, labels_raw, raw_path, far_proxy_raw):
            temporary.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
