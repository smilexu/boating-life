# Øresund Bridge Greybox V1

## Official engineering data

The bridge layout uses the Øresundsbron facts page as the engineering reference:

- Total bridge length: 7,845 m
- West approach: 3,014 m
- High bridge: 1,092 m
- East approach: 3,739 m
- Main free span: 490 m
- Pylons: 203.5 m high
- Navigational clearance: 57 m
- Upper road deck and lower railway deck; four pylons and 80 pairs of stay cables

Sources: [Bridge, pylons, and cable stays](https://www.oresundsbron.com/en/about-oresundsbron/about-us/facts-about-oresundsbron/bridge-pylons-and-cable-stays) and [Peberholm](https://www.oresundsbron.com/en/about-oresundsbron/about-us/facts-about-oresundsbron/peberholm). The Peberholm page reports 4,055 m × 500 m and an area of 1.3 km².

## Geospatial source and placement

The game uses `GeoReference.geodetic_to_world()` from the shared `oresund_georeference.tres`: WGS84 → ECEF → local ENU, with X east, Y up, Z south, and one Godot unit per metre. The bridge is fixed from WGS84 data and does not follow the camera.

The layout file is generated from the repository's dated OpenStreetMap shoreline extracts in `assets/geodata/source/`:

- 51 `bridge:support=pier` footprints
- 4 `bridge:support=pylon` footprints, grouped into two tower axes
- Peberholm coastline from OSM ways 4248218 and 1039870252, whose endpoint node IDs close the island outline
- OSM base timestamps: 2026-10-14 22:24:30Z and 22:25:33Z

Data is © OpenStreetMap contributors, ODbL-1.0. See [`assets/geodata/README.md`](../assets/geodata/README.md) for attribution and distribution notes. The coast outline measures approximately 1.23 km² in this snapshot, close to the official 1.3 km².

The 51 pier centers and two pylon-axis centers form the ordered bridge alignment. The data's first and last support points do not reach the official bridge ends, so the layout extends each end along the neighboring OSM tangent by 118.6 m until the projected line is 7,845 m long. Those two short endpoint sections are engineering approximations. The resulting approximate endpoints are **Peberholm 55.589176°N, 12.776389°E** and **Lernacken 55.565514°N, 12.892471°E**. All ordered support anchors are retained in `centerline_anchors` in the layout JSON.

The pylons' four positions are taken from OSM ways 121292169, 121292281, 121292283, and 121292284. Their two axis centers are 489.9 m apart in the current WGS84 projection, consistent with the official 490 m span. Pier footprints and pylon footprints are positioned from their OSM polygons, not hand-entered coordinates.

## Vertical reference and approximations

The project's calm water reference comes from `WaveSampler.get_mean_water_height()`. The official facts page gives 57 m clearance and 203.5 m pylon height but does not state a vertical datum. For the greybox, the bottom of the high-bridge deck is placed 57 m above the calm in-game water plane, and pylon tops are placed 203.5 m above that plane. This is a gameplay interpretation of the published values, not a surveyed conversion between chart datum, sea datum, and the game's ellipsoid-based height.

Approximate geometry values are centralized in `resources/oresund_bridge_layout.json`:

- 25 m total deck width
- 3.2 m lower deck and 2.4 m upper deck thickness
- 6.6 m between the deck levels
- approach underside height rising from 10 m at each bridge end to 57 m over the high bridge
- pier/foundation visual extension 25 m below the calm-water plane

The project currently has no ship-to-bridge collision or mast-height system. Static bodies and simple box shapes are present on near-LOD bridge decks, piers, and pylons as future collision hooks, but the current `BoatController` directly moves a `Node3D`; these shapes do not stop the player boat. The open 490 m free span has no OSM pier support footprint between its pylon axes. `StarterCargoBoat` currently has a configured overall-height value of 3.834 m in its `VesselDraftProfile` (gameplay dimensions, not a survey measurement), leaving 53.166 m nominal vertical margin under the 57 m opening. The bridge check reads the height component from the vessel dimensions tuple. The approaches have lower vertical clearance and are not intended as an alternate high-clearance shipping gate.

At the center of the main span, the bundled EMODnet DTM currently returns a 9.43 m LAT reference depth; the test boat's empty draft is 0.32 m and the provider classifies that sample as meeting its 0.5 m gameplay margin. This is a coarse/interpolated, explicitly non-navigation-grade sample. The bridge does not add a depth override or change the DTM.

## Scene and LOD structure

`scenes/OresundBridge.tscn` is an independent module instanced by `scenes/main.tscn`. It builds:

- `BridgeSegments/BridgeCell_XX`: 500 m spatial cells with lazy near, mid, far, or hidden geometry
- `HighBridgeCore`: the four pylon columns, portal cross beams, and close-range cable MultiMesh
- `PeberholmOutline`: the OSM coastline outline over the existing regional terrain
- `DebugMarkers` and `DebugLayer`: developer-only GPS/LOD inspection

LOD thresholds are 3.5 km (near detail and simplified collision), 15 km (middle structure), and 45 km (far bridge silhouette and visible tower profile). Outside 45 km the bridge geometry unloads. The central tower/cable assembly is separately distance-switched so the full structure is not kept at the highest detail.

All segments are regenerated from stable GPS data when the bridge scene loads. The project has no active runtime floating-origin service. A future origin manager should update the shared GeoReference and call `OresundBridge.reproject_for_georeference_change()`; source coordinates remain stable WGS84 so every client can reproduce the same placement.

The Inspector exposes optional `pylon_visual_scene` and `pier_visual_scene` PackedScene sockets with scale and rotation corrections. Each replacement is instantiated under a GPS-derived anchor at the corresponding OSM footprint, so swapping a visual GLB does not change the bridge alignment or its separately generated collision hook. Replacement assets should put their base/pivot at the local origin; tune their visual scale and rotation on the bridge node.

## Developer observation

Run the project normally. In a debug/editor run:

- **F5** toggles bridge markers and the diagnostics panel.
- **Shift+F5** cycles through the nearby observation area, main pylon/cable viewpoint, and water point directly below the high-span navigation gate. Each test relocation stops the boat and leaves the normal movement and wave systems in control afterward.

The panel shows current GPS, active LOD cell counts, loaded support counts, nominal clearance margin, and endpoint extension. The first test relocation is across open water near the bridge; the third is centered under the 57 m span, not a teleport into a harbor.

## Checks

Run the focused headless scene/layout check:

```sh
godot --headless --path . --script tests/test_oresund_bridge_runtime.gd
```

It checks scene integration, GPS projection, official length, OSM support counts, tower spacing, free-span clearance, vessel height, and near/mid/far/unloaded LOD changes. Headless mode cannot verify lighting, silhouette, actual waterline appearance, or navigation from the rendered camera. Those need normal-window observation using Shift+F5.
