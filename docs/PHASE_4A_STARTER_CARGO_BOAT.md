# Phase 4A — Starter Cargo Boat

## Asset audit and optimization

The original `assets/boats/first_boat.glb` remains unchanged and is retained as the source asset.

| Property | Source GLB | Optimized runtime GLB |
|---|---:|---:|
| File size | 41,528,804 bytes (39.6 MiB) | 14,167,720 bytes (13.5 MiB) |
| Meshes / surfaces | 1 / 1 | 1 / 1 |
| Triangles | 50,000 | 50,000 |
| Position vertices | 37,838 | 37,838 |
| Materials | 1 | 1 |
| Embedded textures | 3 | 3 |

The three embedded maps are 8-bit RGB PNGs: a normal map, base color map, and packed metallic/roughness map. Each source map is 4096×4096. They were resampled to 2048×2048 with the built-in macOS image utility; no geometry or source GLB data was rewritten. The optimized GLB is 65.9% smaller.

| Map | Original PNG | Optimized PNG | Dimensions |
|---|---:|---:|---:|
| Normal | 11,229,575 bytes | 4,109,835 bytes | 4096² → 2048² |
| Base color | 19,193,182 bytes | 5,588,285 bytes | 4096² → 2048² |
| Metallic/roughness | 9,593,259 bytes | 2,956,815 bytes | 4096² → 2048² |

Godot 4.7 imports both boat GLBs with **Embed as Basis Universal** and mipmaps. This keeps the textures inside each model resource, avoids extracting duplicate PNGs beside the GLBs, and uses Godot's cross-platform compressed-texture path. The material remains opaque, double-sided PBR with one surface; it has no transparency, skeleton, animation, or morph targets. The GLB declares `KHR_materials_specular`, which Godot imports to `StandardMaterial3D`.

## Model calibration

The imported unscaled mesh bounds are 1.08319 m along GLB +X, 0.576753 m high, and 0.384345 m across. The wheelhouse/high structure is concentrated toward +X; the aft half is the broad, low open deck. The visual frame rotates +X to the navigation node's -Z forward axis and applies a uniform scale of 6.647381. The result is 7.200×2.555×3.834 m (length×beam×height). The frame is lowered 0.32 m, matching the current empty-draft value while keeping the hull in the water and exposing the side tires/fenders; it remains shifted -0.293 m along boat-local Z to center its measured length.

The cargo slots are under `VisualRoot/CargoSlots`, so they follow the existing heave/pitch/roll and cargo-load sink response. The slot root is raised 0.40 m to stay aligned with the raised hull; both slots are centered on the open aft deck, have 1.19 m separation along the vessel, and place their container bottoms at about 0.22 m above the deck at empty load. Their positions remain editable in `Boat.tscn`.

## Cargo data

`StarterCargoBoat` is configured with two space units, a 500 kg maximum, a 0.32 m empty draft, and a 0.75 m full-load draft. Draft values are explicitly game-test values, not certified vessel data. The test cargo weighs 200 kg and uses one space, so the developer cycle represents 0 kg, 200 kg, and 400 kg while filling 0/1/2 slots. The 400 kg state fills all cargo slots but remains below the weight limit. The visual hull now sinks by the same draft increase used by navigation: 0 m empty, 0.172 m at 200 kg, and 0.344 m at 400 kg. A damped spring applies this offset with the existing wave response, so loading does not snap the boat vertically.

`CargoLoadoutController` owns the cargo manifest and the pooled slot visuals. It derives total cargo weight from the manifest and writes it to the existing `BoatController.current_cargo_weight_kg`; `VesselDraftProfile` remains the sole draft calculation. `BoatBuoyancy` reads the same draft delta for visual load sink, while the navigation-depth monitor and harbor checks consume the same calculated draft.

## Developer test controls

- **F12** cycles empty → one container → two containers → empty. It is a debug/editor-only action.
- **O** opens the Malmö harbor diagnostics, which now report vessel dimensions, cargo count, space, weight, maximum load, and current draft.
- The existing **P** harbor test relocation can be used to reach the Malmö berth area.

F9 is already used by the shallow-reef cluster debug controls, and F10 is used by water diagnostics, so the cargo cycle uses F12.

## Validation

- `tools/test_starter_cargo_boat.gd`: passed. Confirms model import and triangle count, corrected bow direction, measured dimensions, raised empty visual placement, two slots, pooled visuals, 0/200/400 kg loadouts, space and weight rejection, matching navigation/visual draft deltas, navigation-monitor draft propagation, Malmö dock/undock, and F12 cycle.
- `tools/test_malmo_harbor_greybox.gd`: passed.
- `tools/test_navigation_depth.gd`: passed. Its loaded-draft rejection now uses a dedicated 1.0 m shallow test berth; the default Malmö berth remains 1.6 m and can accept this vessel when loaded within its configured draft.
- `tools/test_port_services.gd`: passed.
- The headless runs still report the existing dummy-renderer shader RID allocation at exit. No new script or resource loading errors appeared.

Headless checks do not verify the final camera composition, water-driven visual float, tire/fender exposure, precise crate-to-deck appearance, or the Mac/Windows GPU output. Please make the final visual check in the running game: press F12 three times and inspect empty/one/two containers from the stern camera, then use P to test the Malmö approach and verify docking/undocking. No Mac/Windows GPU comparison was run in this environment.
