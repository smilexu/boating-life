# Øresund Terrain Data

## Source and retrieval

- **Provider:** Mapzen / Tilezen Terrain Tiles, served from the AWS Open Data `elevation-tiles-prod` bucket.
- **Registry:** [AWS Open Data Registry — Terrain Tiles](https://registry.opendata.aws/terrain-tiles/).
- **Tile documentation:** [Mapzen Terrain Tiles service](https://www.mapzen.com/blog/terrain-tile-service/).
- **Tile URL:** `https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png` (no API key).
- **Format:** 256×256 Terrarium RGB PNG; Web Mercator XYZ pixels encode elevation as `R * 256 + G + B / 256.0 - 32768.0` metres. The processor reads stored 8-bit channel bytes directly with Pillow/NumPy and does not apply a color-space conversion.
- **Access date:** 2026-10-14 UTC (2026-10-15 local time). The cache manifest records the exact validation timestamp and SHA-256 for each tile.
- **Region:** the existing Task 7 bounds, 12.25°–13.22° E and 55.35°–56.10° N. The script reads `resources/oresund_georeference.tres` and checks it against the Task 7 processed data before fetching; it does not establish another map frame.
- **Zoom:** z=11; XYZ x=1093–1099, y=636–644; 63 tiles total. All 63 PNGs are cached, with zero failed/invalid tiles. The decoded cache occupies 5,048,217 bytes.

The AWS registry describes this as global bare-earth terrain height data and points to Tilezen's data attribution guide for terms. Tilezen's attribution guide identifies European terrain as EU-DEM layers produced using Copernicus data. The tile service does not expose per-pixel source metadata, so the source is recorded at this regional/provider level rather than as surveyed local elevation.

## Download and build

```sh
.venv/bin/pip install -r tools/requirements-terrain.txt
.venv/bin/python tools/terrain/fetch_tiles.py --zoom 11
.venv/bin/python tools/terrain/build_terrain.py --zoom 11
```

The fetch script caps a request at 80 tiles by default, validates PNG dimensions and raw RGB/RGBA mode, writes each tile to `assets/terrain/source/{z}/{x}/{y}.png`, and records checksums in `assets/terrain/source/download_manifest.json`. It uses the system `curl` when available and Python's standard-library URL client otherwise. The build script is offline and refuses to proceed if any required tile is missing.

Only NumPy, Pillow, and Shapely are added for offline processing. `pyproj` and `requests` are not needed: the script reproduces the existing WGS84 ECEF-to-ENU transform and uses the standard library for network access.

## Sample decode and generated terrain

The initial live sample was `z=11, x=1096, y=640`, saved as `assets/terrain/source/11/1096/640.png`:

- PNG: valid, RGB, 256×256.
- Pixel at the local map origin: `(137, 198)`, raw channels `(127, 250, 244)`.
- Decoded height: `127 * 256 + 250 + 244 / 256 - 32768 = -5.046875 m`.
- Whole tile decoded range: `-16.7578125 m` to `-2.4375 m`, consistent with the sampled water area rather than an RGB/color-space misread.

The full 63-tile mosaic decodes to `-78.00 m` through `209.97 m`, including offshore values. Only Task 7 land geometry is emitted as terrain; sea pixels do not create terrain faces. Land geometry is reconstructed from the highest-detail Task 7 triangle mesh, preserving its holes and approximately 15 m shoreline simplification. Its union is 3,001.99 km² versus Task 7's 3,005.24 km² classification report (about 0.11% difference from the triangulated/simplified representation).

Generated output in `assets/terrain/processed/oresund_terrain/`:

- 58 binary chunks, each up to 10 km square.
- 100 m nominal vertex-grid spacing, bilinear sampling from z=11 Terrarium pixels.
- 324,178 vertices and 617,855 upward-wound triangles.
- 20,382,308 bytes of chunk data.
- Aligned mesh vertex range: 0.50–209.32 m above the game's sea plane.
- Reference samples: Malmö 12.71 m and Copenhagen 12.25 m after alignment; the Øresund Bridge midpoint remains water and is not covered by the land mesh.

The processor converts sample positions from the same WGS84 ECEF/ENU frame used by `GeoReference`, then back to WGS84 before mapping them into Web Mercator tile pixels. It never treats tile pixels as Godot metres. The generated manifest stores the origin, bounds, tile checksums, height range, component count, vertical alignment, and material approximation.

The source tile heights are vertically aligned with one uniform `-0.52 m` offset: the median DEM height 60 m inland of the existing OSM shoreline is aligned to +1.0 m. Vertices below +0.5 m are clamped above the sea plane to prevent land faces from remaining submerged. `OresundRegion.terrain_vertical_offset_m` is an additional Inspector adjustment. These are presentation adjustments, not a surveyed vertical datum conversion.

## Godot display and materials

`scenes/OresundRegion.tscn` loads the generated chunks into a `TerrainChunks` parent. Each chunk is one `ArrayMesh`/`MeshInstance3D`, with shared grid edges, sampled terrain normals, and no per-pixel nodes. If generated data is unavailable, the existing flat coastline mesh remains as a fallback. The main scene continues to use its existing dynamic ocean.

Vertex colors approximate grass, soil, sand, rock, and subtle urban tint using elevation, slope, distance to the Task 7 coastline, and soft proximity to the Malmö/Copenhagen reference anchors. There is no land-cover dataset in this task; those colors are art direction only. No trees, buildings, ports, or bridge model are included.

## Attribution and reuse notes

Recommended in-game and distributed-data credit for the current source set:

> Terrain elevation © Mapzen / Tilezen. European terrain data produced using Copernicus data and information funded by the European Union — EU-DEM layers.

The Task 7 shoreline keeps its separate credit: `© OpenStreetMap contributors · ODbL-1.0`.

The AWS registry links to the [Tilezen attribution guide](https://github.com/tilezen/joerd/blob/master/docs/attribution.md), which lists the required European terrain attribution. The [EEA reuse FAQ](https://www.eea.europa.eu/en/about/contact-us/faqs/can-i-use-eea-content-in-my-work-or-in-my-organisations-products) says EEA data can be reused commercially with source acknowledgement, and also states that EEA content may not be altered without explicit permission. Because the hosted terrain tiles are encoded, resampled, and may combine source layers, the exact underlying EU-DEM version and commercial redistribution conditions for these derived tiles still need confirmation before public/commercial redistribution of the raw tile cache or derived elevation data. No blanket public-domain or unrestricted redistribution claim is made here.

## Validation and limitations

- The AWS URL returned a valid sample PNG and 63 valid z=11 PNGs were cached and decoded.
- The raw Terrarium formula, origin pixel, tile counts, hashes, geometry coverage, terrain file sizes, triangle winding, and absence of degenerate/downward triangles were checked by the offline scripts.
- `godot --headless --path . --editor --quit` and `godot --headless --path . --quit-after 3` exited successfully. A headless runtime probe instantiated `OresundRegion.tscn`, found 58 `TerrainChunks` meshes, and confirmed the flat fallback is hidden; the first loaded chunk contained 1,359 vertices from 0.50 to 21.64 m.
- This restricted execution runner denied DNS for downloads launched from Python or a child `curl` process. The 63 successful downloads were therefore performed by direct, allowlisted `curl` requests; the Python fetch tool then validated all cached files and wrote their hashes. Its added fail-fast behavior avoids spending time retrying every tile after three consecutive network failures.
- One initial probe emitted host `user://logs` and macOS CA-certificate lookup messages; the final runtime probe exited cleanly and loaded the same meshes. No GDScript or terrain-mesh error was reported.
- Visual checks in the Godot renderer and an FPS comparison still need to be performed on the target Mac; headless mode has no rendering device and cannot confirm final appearance, coastline seams, or frame rate. The left HUD/FPS scripts were not changed, but their rendered display was not visually checked in this run.
- z=11 is coarse for local streets and small landforms. The 100 m output mesh smooths data further. It is intended for regional coast scenery, not navigation, property boundaries, or survey use.
- No bathymetry is generated. The coastline remains the OSM Task 7 mask, and the 0.5 m coastal floor / single global offset are game-facing alignment choices.
- There is one terrain detail level and no streaming/LOD in this prototype. The 58 mesh chunks and shadows have not yet been benchmarked in the running game.
