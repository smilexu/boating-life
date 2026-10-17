# Navigation depth prototype (Milestone 5, Phase 2)

## Scope and data suitability

`NavigationDepthProvider` is a game-logic reference layer. It is intentionally **not** a marine navigation or safety system.

The local dataset is EMODnet Digital Bathymetry DTM 2024 (`bathymetry_dtm_2024`), WGS84 longitude/latitude (EPSG:4326), referenced to Lowest Astronomical Tide (LAT). The processed grid has 932 columns × 721 rows at 0.001041667° spacing. Around Malmö that is roughly 65 m east-west × 116 m north-south. EMODnet explicitly says this product is not for navigation or safety at sea, so it is too coarse and not certified for real vessel decisions. The project has no measured LAT-to-current-water-level/tide offset. The prototype therefore exposes `game_surface_above_lat_m` (default `0.0`) as a clearly stated **game convention** mapping the calm `Y=0` plane to LAT; it does not claim this is the actual water datum.

`BathymetryManager.get_depth_at_world_position()` uses the existing `GeoReference`, ignores world Y/waves, and accepts only a bilinear sample whose four DTM cells are valid. Invalid cells are not extrapolated. `NavigationDepthProvider` separately checks the OSM land mask so a point classified as land is distinguishable from a water-side DTM gap (`no_data`) and an out-of-grid point (`outside_coverage`). These results are all treated as `Unknown` for safety classification.

## Architecture

- `scripts/navigation_depth_provider.gd`: shared world-position query, sample metadata, local polygon overrides, `Safe` / `Caution` / `Unsafe` / `Unknown` evaluator, and conservative status aggregation. Higher-priority local override wins. Missing data never becomes deep water.
- `scripts/navigation_depth_monitor.gd`: every 0.5 s caches a current-point sample and one predicted point. Lead distance is `abs(speed) × 3 s`, clamped to 8–50 m; reverse travel reverses the lead direction.
- `scripts/vessel_draft_profile.gd`: reusable vessel draft resource and clamped linear cargo interpolation.
- `scripts/boat_controller.gd`: stores the vessel profile and current cargo weight, and exposes the reference draft without changing buoyancy or movement.
- `scripts/malmo_harbor_greybox.gd`: adds local gameplay-only water-depth polygons, tests five berth points, and keeps the existing distance/speed/heading/E docking flow. Every sample must be `Safe`; `Caution`, `Unsafe`, or `Unknown` blocks docking.
- `scripts/boat_hud.gd`: compact current/lead depth and status display, with an explicit non-navigation disclaimer.

The shared safety rule is `available depth >= current draft + safety margin`. Default margin is 0.5 m. `Caution` means depth is at least the draft but below draft plus margin. `Unsafe` means the reference depth is below draft. Unknown includes missing/invalid data and land.

## Malmö greybox override values

The overrides live as editable exports on `scenes/MalmoHarbor.tscn` and are registered only by the harbor module. They affect gameplay queries only; they do not edit DTM files, terrain, the water shader, or seabed visuals.

| Area | Footprint | Default depth | Priority | Provenance |
| --- | --- | ---: | ---: | --- |
| Entrance channel | Approach-to-entrance corridor, width `entrance_width + 6 m` | 4.5 m | 100 | Gameplay-configured, unverified |
| Basin | Local EN rectangle `[-116,-47] × [-25,25] m` from harbor anchor | 3.0 m | 110 | Gameplay-configured, unverified |
| Berth | Rotated berth rectangle, expanded 3 m around the berth | 1.6 m | 120 | Gameplay-configured, unverified |

Anchor: 55.619° N, 12.977° E (same test anchor as the Phase 1 greybox; not surveyed port data). The `enable_gameplay_depth_overrides` switch defaults on so the greybox can be tested. Turn it off to remove this gameplay aid; uncovered invalid DTM/land samples remain Unknown and prevent docking. Do not treat these values as measured harbor depths.

## Vessel profile

`resources/vessels/test_sailboat_draft.tres` is explicitly a test profile assigned to the existing boat instance:

- Empty draft: 0.65 m
- Full-load draft: 1.15 m
- Maximum cargo: 1,200 kg
- Current cargo: `PlayerBoat/MotionRoot.current_cargo_weight_kg` (default 0 kg)

Draft is linearly interpolated from empty to full. Negative cargo clamps to zero; cargo over capacity clamps to full load. The profile changes no rendered hull height or floating behavior. Replace it with verified vessel-class values when those become available.

## Debug and manual checks

- Run the main scene normally. The lower-left HUD shows the cached reference depth, draft, margin, combined current/lead status, source class, and non-navigation disclaimer.
- Press **P** to use the existing developer teleport to the harbor approach.
- Press **O** to show/hide harbor debug: position, speed, heading error, current source/quality, all five berth samples, their statuses, and the reason docking is blocked.
- Enter the berth, align to its configured heading, stop below 0.8 m/s, and press **E**. Press **E** again to undock.
- For a shallow warning check, place the boat at the known Malmö DTM point 55.60587° N, 12.97000° E (the source sample is about 0.74 m LAT) using the Remote Inspector/developer transform, outside the harbor override polygons. The monitor refreshes within 0.5 s. Unknown areas should display an explicit unknown state.
- Cargo-loading behavior is currently inspector-configured, not connected to a cargo gameplay system. Set current cargo to 0 or 1,200 kg to compare the test draft.

Automated checks:

```sh
godot --headless --path . --script res://tools/test_navigation_depth.gd
godot --headless --path . --script res://tools/test_malmo_harbor_greybox.gd
```

## Known limitations

- DTM values are coarse chart references and explicitly non-navigation-grade. The status names are gameplay feedback only.
- The game surface/LAT offset currently defaults to zero because no reliable local tide datum is configured.
- The harbor overrides are game-design values, not survey data; they make only the bounded greybox polygons queryable.
- No grounding collision, hull damage, tide prediction, squat, or wave-dependent under-keel clearance is implemented.
- Visual playtesting of the depth label and real harbor/waterline fit remains a human review item. Automated tests validate data and logic, not real-world safety or visual quality.
