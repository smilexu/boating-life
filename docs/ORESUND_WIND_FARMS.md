# Øresund Offshore Wind Farms

## Runtime content

`scenes/OresundWindFarms.tscn` is instanced by `scenes/main.tscn`. The scene converts each WGS84 turbine coordinate through the shared `GeoReference` and seats the visual foundation at the prototype's flat sea plane (`Y=0`). The layout is data-driven in `resources/oresund_wind_farms.json`.

The JSON contains 48 mapped Lillgrund turbine nodes and 20 mapped Middelgrunden turbine nodes. Middelgrunden's source points retain its shallow north-south arc; Lillgrund retains its staggered multi-row array. These are actual OSM turbine point locations rather than a synthetic grid.

## Shared model and rendering

`scripts/offshore_wind_turbine_model.gd` creates shared low-poly meshes for:

- a tapered 65 m tower;
- a simple nacelle and hub;
- a three-blade rotor with a 46.5 m radius (93 m diameter);
- a simplified foundation descending 12 m below the game sea plane;
- muted white-gray tower, nacelle and rotor surfaces, with subdued orange blade tips;
- a dark waterline band, warm safety-yellow transition, maintenance landing, guardrails, ladder, access door and vent panels;
- restrained waterline discoloration streaks;
- an enlarged red nacelle obstacle beacon and two enlarged amber landing lights, all emissive only at night. Their mesh diameter and emissive energy are each doubled from the previous pass.

`scripts/oresund_wind_farms.gd` batches all 68 turbines into six `MultiMeshInstance3D` render batches: near base, near rotors, far base, far rotors, top beacons, and paired platform lamps. The nearest four turbines in near LOD additionally use a pooled set of 12 shadowless OmniLights (one red beacon fill and two amber platform fills per turbine); the pool follows the nearest turbines as the boat moves. These bounded local lights illuminate the tower/platform surfaces without adding lights to all 68 turbines. The rotor transforms update at 16.7 Hz by default, at a steady 0.14 rad/s with deterministic phase offsets.

The near LOD uses 16-sided towers, fuller nacelles, and swept/tapered blades. The far LOD uses 8-sided towers and fewer blade sections. Near LOD defaults to 4 km; turbines remain visible in far LOD to 60 km. Distances, hub/rotor/foundation dimensions, rotor speed, rotation update rate, bearing, beacon/platform emissive strength, and their local OmniLight energy/range are exported on `OresundWindFarms`. The current fill ranges are 80 m for red beacons and 45 m for each amber platform lamp; all pooled lights have shadows disabled.

## Data and attribution

- Lillgrund: Vattenfall reports 48 turbines, 110 MW, offshore in Øresund, about 10 km from the Swedish coast. The exact individual point positions in this build come from [OpenStreetMap relation 5136710](https://www.openstreetmap.org/relation/5136710).
- Middelgrunden: the cooperative documents the 20-turbine park and ownership of the northern/southern turbine groups; the Danish Energy Agency lists 20 turbines and 40 MW. The point positions come from [OpenStreetMap relation 1130880](https://www.openstreetmap.org/relation/1130880), retaining the mapped curve.
- The OSM point snapshot is dated 2026-10-19. OSM data is © OpenStreetMap contributors and available under ODbL-1.0. Source URLs and the snapshot metadata are recorded in `resources/oresund_wind_farms.json`.

## Debug navigation

In a debug/editor run, press **F6** to alternate between sea observation points near Lillgrund and Middelgrunden. Each point is calculated from that farm's turbine-coordinate center, offset 500 m east over open water, with the boat stopped and facing the turbines. Press F6 again to move to the other farm. The previous shallow-water transparency toggle remains available on **Ctrl+F6**.

## Known limits

- This is a visual greybox; turbines have no collision, navigation obstruction, wakes, cable network, or power simulation.
- There is no transformer station in this pass.
- The model is shared between both sites. The 65 m hub plus 46.5 m blade radius gives a 111.5 m rotor-tip height, close to the official 115 m Lillgrund figure, but it is not an engineering-specific turbine model for each site.
- LOD currently has near and far geometry only; no billboard tier is needed at the current 68-instance scale.
- Headless runtime/count checks do not replace visual inspection from a moving boat in Forward+.

## Check

Run the game with F5. Turbine positions and LOD update automatically as the boat moves. Use F6 to inspect the two wind farm areas. The repeatable scene/runtime check is:

```sh
godot --headless --path . --script tests/test_oresund_wind_farms_runtime.gd
```
