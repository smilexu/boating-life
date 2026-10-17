#!/usr/bin/env python3
"""Resize embedded GLB textures while preserving geometry and PBR data maps.

This is an offline authoring utility. It uses ImageMagick's `magick` command,
which is not needed at game runtime. By default it writes optimized copies to
an output directory; pass --in-place only after preserving a source backup.
"""

from __future__ import annotations

import argparse
import json
import struct
import subprocess
import tempfile
from pathlib import Path


JSON_CHUNK = 0x4E4F534A
BIN_CHUNK = 0x004E4942


def _read_glb(path: Path) -> tuple[dict, bytes, list[tuple[int, bytes]]]:
    data = path.read_bytes()
    if len(data) < 20:
        raise ValueError(f"{path}: file is too short to be a GLB")
    magic, version, total_length = struct.unpack_from("<III", data, 0)
    if magic != 0x46546C67 or version != 2 or total_length != len(data):
        raise ValueError(f"{path}: invalid GLB v2 header")
    chunks: list[tuple[int, bytes]] = []
    offset = 12
    while offset < len(data):
        length, chunk_type = struct.unpack_from("<II", data, offset)
        offset += 8
        chunks.append((chunk_type, data[offset : offset + length]))
        offset += length
    json_chunks = [payload for kind, payload in chunks if kind == JSON_CHUNK]
    bin_chunks = [payload for kind, payload in chunks if kind == BIN_CHUNK]
    if len(json_chunks) != 1 or len(bin_chunks) != 1:
        raise ValueError(f"{path}: expected one JSON and one BIN chunk")
    return json.loads(json_chunks[0].decode("utf-8")), bin_chunks[0], chunks


def _run_magick(args: list[str]) -> None:
    result = subprocess.run(args, check=False, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "ImageMagick failed")


def _texture_role(name: str) -> tuple[str, str, bool]:
    lowered = name.lower()
    if "normal" in lowered:
        return "normal", ".png", False
    if "roughness" in lowered or "metallic" in lowered or "orm" in lowered:
        return "orm", ".png", False
    return "albedo", ".jpg", True


def _resize_image(source: bytes, is_color: bool, max_size: int, jpeg_quality: int) -> tuple[bytes, str]:
    with tempfile.TemporaryDirectory(prefix="reef_glb_texture_") as temp_dir:
        temp = Path(temp_dir)
        source_path = temp / "source.png"
        output_path = temp / ("output.jpg" if is_color else "output.png")
        source_path.write_bytes(source)
        base_args = ["magick", str(source_path), "-filter", "Lanczos", "-resize", f"{max_size}x{max_size}", "-strip"]
        if is_color:
            base_args.extend(["-alpha", "off", "-sampling-factor", "4:4:4", "-quality", str(jpeg_quality)])
        else:
            base_args.extend(["-define", "png:compression-level=9", "-define", "png:compression-filter=5"])
        base_args.append(str(output_path))
        _run_magick(base_args)
        return output_path.read_bytes(), "image/jpeg" if is_color else "image/png"


def _pad4(data: bytearray, value: int = 0) -> None:
    while len(data) % 4:
        data.append(value)


def optimize_glb(source_path: Path, output_path: Path, max_size: int, jpeg_quality: int) -> tuple[int, int, list[dict]]:
    gltf, original_bin, chunks = _read_glb(source_path)
    original_size = source_path.stat().st_size
    image_views: dict[int, tuple[bytes, str, str, str]] = {}
    removed_views: set[int] = set()
    report = []
    for image_index, image in enumerate(gltf.get("images", [])):
        image_name = image.get("name", f"image_{image_index}")
        role, extension, is_color = _texture_role(image_name)
        if "bufferView" in image:
            view_index = int(image["bufferView"])
            view = gltf["bufferViews"][view_index]
            start = int(view.get("byteOffset", 0))
            end = start + int(view["byteLength"])
            source_bytes = original_bin[start:end]
            removed_views.add(view_index)
            before_bytes = end - start
        elif "uri" in image and not str(image["uri"]).startswith("data:"):
            image_source = source_path.parent / str(image["uri"])
            if not image_source.is_file():
                raise FileNotFoundError(f"{source_path}: external texture not found: {image_source}")
            source_bytes = image_source.read_bytes()
            before_bytes = len(source_bytes)
        else:
            raise ValueError(f"{source_path}: unsupported embedded/data URI image {image_name}")
        replacement, mime_type = _resize_image(source_bytes, is_color, max_size, jpeg_quality)
        texture_filename = f"{source_path.stem}_{role}{extension}"
        image_views[image_index] = (replacement, mime_type, texture_filename, image_name)
        image_output = output_path.parent / texture_filename
        image_output.parent.mkdir(parents=True, exist_ok=True)
        image_output.write_bytes(replacement)
        image.pop("bufferView", None)
        image.pop("mimeType", None)
        image["uri"] = texture_filename
        report.append({"name": image_name, "before_bytes": before_bytes, "after_bytes": len(replacement), "mime_type": mime_type, "path": texture_filename})

    if not image_views:
        raise ValueError(f"{source_path}: no embedded PNG images were found")

    buffer_views = gltf.get("bufferViews", [])
    ranges = []
    new_bin = bytearray()
    old_ranges = []
    for view_index, view in sorted(enumerate(buffer_views), key=lambda item: int(item[1].get("byteOffset", 0))):
        if view_index in removed_views:
            continue
        old_start = int(view.get("byteOffset", 0))
        old_end = old_start + int(view["byteLength"])
        old_ranges.append((old_start, old_end, view_index))
    for previous, current in zip(old_ranges, old_ranges[1:]):
        if previous[1] > current[0]:
            raise ValueError(f"{source_path}: overlapping bufferViews are not supported")

    view_remap: dict[int, int] = {}
    compact_views = []
    for _old_start, _old_end, view_index in old_ranges:
        view_remap[view_index] = len(compact_views)
        compact_views.append(buffer_views[view_index])

    def remap_view_references(value: object) -> None:
        if isinstance(value, dict):
            if "bufferView" in value:
                old_index = int(value["bufferView"])
                if old_index in removed_views:
                    raise ValueError(f"{source_path}: non-image data references removed image bufferView {old_index}")
                if old_index in view_remap:
                    value["bufferView"] = view_remap[old_index]
            for child in value.values():
                remap_view_references(child)
        elif isinstance(value, list):
            for child in value:
                remap_view_references(child)

    for accessor in gltf.get("accessors", []):
        remap_view_references(accessor)
    for view_index in range(len(compact_views)):
        view = compact_views[view_index]
        old_start = int(view.get("byteOffset", 0))
        old_end = old_start + int(view["byteLength"])
        if len(new_bin) % 4:
            _pad4(new_bin)
        view["byteOffset"] = len(new_bin)
        new_bin.extend(original_bin[old_start:old_end])
    gltf["bufferViews"] = compact_views
    gltf["buffers"][0]["byteLength"] = len(new_bin)
    _pad4(new_bin)
    json_payload = json.dumps(gltf, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    json_chunk = bytearray(json_payload)
    _pad4(json_chunk, 0x20)
    bin_chunk = bytes(new_bin)
    output = bytearray(struct.pack("<III", 0x46546C67, 2, 12))
    for kind, payload in chunks:
        if kind == JSON_CHUNK:
            payload = bytes(json_chunk)
        elif kind == BIN_CHUNK:
            payload = bin_chunk
        output.extend(struct.pack("<II", len(payload), kind))
        output.extend(payload)
    struct.pack_into("<I", output, 8, len(output))
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(output)
    external_size = sum(len(image[0]) for image in image_views.values())
    return original_size, len(output) + external_size, report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", type=Path, help="GLB files; defaults to assets/rocks/*.glb")
    parser.add_argument("--output-dir", type=Path, help="write optimized copies here (default: assets/environment/underwater/rocks)")
    parser.add_argument("--in-place", action="store_true", help="replace source GLBs; make a backup first")
    parser.add_argument("--max-size", type=int, default=1024, help="maximum texture dimension (default: 1024)")
    parser.add_argument("--jpeg-quality", type=int, default=90, help="base color JPEG quality (default: 90)")
    args = parser.parse_args()

    project_root = Path(__file__).resolve().parents[1]
    sources = args.paths or sorted((project_root / "assets/rocks").glob("*.glb"))
    if not sources:
        parser.error("no GLB files found")
    if args.in_place and args.output_dir:
        parser.error("choose either --in-place or --output-dir")
    if not args.in_place and args.output_dir is None:
        args.output_dir = project_root / "assets/environment/underwater/rocks"

    total_before = total_after = 0
    for source in sources:
        source = source.resolve()
        destination = source if args.in_place else args.output_dir / source.name
        before, after, images = optimize_glb(source, destination, args.max_size, args.jpeg_quality)
        total_before += before
        total_after += after
        print(f"{source.name}: {before / 1048576:.2f} MiB -> {after / 1048576:.2f} MiB ({100.0 * (1.0 - after / before):.1f}% smaller)")
        for image in images:
            print(f"  {image['name']}: {image['before_bytes'] / 1048576:.2f} -> {image['after_bytes'] / 1048576:.2f} MiB, {image['mime_type']}")
    print(f"TOTAL: {total_before / 1048576:.2f} MiB -> {total_after / 1048576:.2f} MiB ({100.0 * (1.0 - total_after / total_before):.1f}% smaller)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
