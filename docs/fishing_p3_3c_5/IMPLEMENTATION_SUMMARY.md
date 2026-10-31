# Fishing P3.3c.5 — Implementation Summary

## Change

Replaced the hanging fish's layered transverse sine offsets with a cumulative spine curve in `shaders/fishing_catch_deform.gdshader`.

- The body coordinate runs from the line-pinned mouth (`q=0`) to the tail (`q=1`).
- A smooth, same-sign tangent angle ramps from `q=0.18` to `q=0.82`. The shader integrates that tangent in 16 fixed steps to place the spine, producing a continuous C arc instead of local Z-shaped offsets.
- Each cross-section rotates into the local spine frame. Vertex positions, normals and tangents use that frame, retaining the imported mesh thickness without CPU vertex uploads.
- The final tail section adds a bounded, phase-driven whip. The whole-body turn is clamped to 150 degrees.
- The deformed mesh AABB is expanded for the curved silhouette.

`FishingRodRig.set_catch_spine_curl()` sends the angles, phase, direction and bend profile to each catch material. Its CPU mirror supplies tail/probe offsets and deterministic test coverage. The mouth hook remains at the existing catch-container hook offset; the line still terminates at that hook.

## Animation data

`FishingFightProfile` now provides cumulative curl angle, bend power, tail whip angle/frequency and burst events (`seconds after lift`, `strength`, `direction`). The existing F3 `hanging_struggle_intensity` scales both body and tail angles. Event direction reverses the whole C bend; the fixed 0.48-second pulse envelope gives a fast curl and release.

| Species | Whole-body turn | Bend power | Tail whip | Tail frequency | Lateral response |
|---|---:|---:|---:|---:|---:|
| Sea Trout | 125° | 1.00 | 38° | 6.2 Hz | 36° impulse, 1.25 Hz |
| Needlefish | 100° | 1.25 | 42° | 6.8 Hz | 30° impulse, 1.45 Hz |

Whole-fish sway is driven by the same burst events and damped with a 2.8 response coefficient. It rotates around the hanging fish's local UP axis, which swings the tail laterally while the mouth remains fixed. Species and mount profiles cap sway at 20 degrees; residual display sway remains small. Rod mount clearances and the five-stage 56-second schedule are unchanged.

## Modified files

- `scripts/fishing_fight_profile.gd`
- `scripts/fishing_rod_rig.gd`
- `scripts/fishing_rod_system.gd`
- `shaders/fishing_catch_deform.gdshader`
- `resources/fishing/fight_profiles/sea_trout.tres`
- `resources/fishing/fight_profiles/needlefish.tres`
- `resources/fishing/rod_mounts/starter_cargo_boat.tres`
- `resources/fishing/rod_mounts/nordic28.tres`
- `tests/test_fishing_p3_3c_1.gd`
- `docs/fishing_p3_3c_5/*`

No P2 encounter, population, settlement, line/reel, surface path, catch card, camera or total-time logic was changed.
