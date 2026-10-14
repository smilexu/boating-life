# Øresund coastal data

## Source and scope

- Source: OpenStreetMap `natural=coastline` ways, queried through the public Overpass API at `https://overpass-api.de/api/interpreter`.
- Crop: WGS84 longitude 12.25°–13.22°, latitude 55.35°–56.10°. Two adjacent queries split at 12.80° keep the requests small. The target includes Malmö, Copenhagen, the Øresund crossing, Amager, Saltholm, Peberholm, and nearby coastlines.
- The Overpass response includes `timestamp_osm_base`; the build tool preserves those timestamps in the processed resource.
- The coastline geometry comes from OSM contributors. Its positional accuracy varies with the source mapping; WGS84 decimal coordinates are not a guarantee of metre-level ground accuracy.
- The build emits 15 m, 80 m, and 250 m simplification levels. Those are geometry tolerances, not claims about source survey accuracy.

## Repeatable build

Install the geometry dependency and fetch/process the source extracts:

```sh
python3 -m pip install -r tools/requirements-geodata.txt
python3 tools/build_oresund_map.py --download
```

The command writes the raw Overpass responses to `assets/geodata/source/` and the triangulated local-coordinate mesh data to `assets/geodata/processed/oresund_region.json`. To rebuild from an archived snapshot without network access, omit `--download`.

The processor clips the source ways to the WGS84 crop, then classifies a 15 m scanline raster by crossing parity from a known water point at the map origin. This avoids treating polygonized faces containing unclosed coastline chains as wholly land or wholly water. Land runs are dissolved and clipped to the projected crop boundary; holes remain water. It exports only triangles fully covered by the resulting land geometry. The source is checked against Malmö, Copenhagen, Saltholm, and the water seed before a mesh is written.

## Current snapshot status

The data was retrieved on **2026-10-15**. The west response has OSM base timestamp **2026-10-14T22:24:30Z** and the east response **2026-10-14T22:25:33Z**. Those raw files are bundled as the reproducible build snapshot:

| Extract | SHA-256 |
| --- | --- |
| `oresund_west.osm.json` | `b3a969f02e3b01cc8a6611260c1cb2f15df5daa3e5f17c8e2a30283256f91100` |
| `oresund_east.osm.json` | `1b4c3316d9bb17878aa14d13f716df2b66fb987bfc301980f8c1f98d7afef584` |

The generated mesh QA records 431 coastline ways, 24,934 clipped coastline segments, a 15 m raster at 4,103 × 5,575 cells, and approximately 3,005 km² of land. The detailed, medium, and coarse meshes contain 6,463, 1,889, and 1,255 triangles. The city anchors and Saltholm sample classify as land; the map-origin water seed and approximate bridge midpoint classify as water. These are geometry sanity checks, not a survey accuracy claim.

## Attribution and ODbL

The coastline is derived from the OpenStreetMap database and is available under the [Open Database License 1.0 (ODbL)](https://opendatacommons.org/licenses/odbl/1-0/). Attribute the data as **© OpenStreetMap contributors** and link to [openstreetmap.org/copyright](https://www.openstreetmap.org/copyright).

The game artwork and application are not automatically relicensed just because they display OSM-derived geometry. However, extracted or transformed coastline data may constitute a derivative database. Before distributing raw or processed coastline data, check the ODbL attribution, share-alike, and public-access requirements for the exact distribution model. Include the ODbL notice with distributed map data and place visible attribution in the game credits or map information screen.
