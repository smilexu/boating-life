# Fishing P3.3c.2 — Hanging Catch Deformation

## Status

Implemented in code. Targeted Headless checks pass. Forward+ appearance remains `NOT RUN`.

## Model inspection and deformation method

Both current catch GLBs are static, single-surface meshes without a Skeleton3D or blend shapes:

- `assets/fishes/seetrout.glb`: 28,434 vertices, local X body axis, one StandardMaterial3D surface.
- `assets/fishes/needlefish.glb`: 2,361 vertices, local X body axis, one StandardMaterial3D surface.

Because neither asset has deformation bones and the imported geometry already has adequate longitudinal subdivision, the catch visual now uses `shaders/fishing_catch_deform.gdshader`. The imported ArrayMesh remains unchanged. A per-catch ShaderMaterial copies the current GLB albedo, metallic/roughness maps and channels, normal map, UV transform, and specular settings. Only shader uniforms change during the hanging animation; the former per-frame CPU vertex-array upload is removed.

The shader converts local X position to a normalized head-to-tail coordinate using the profile's existing Positive-X / Negative-X nose convention. `q=0` is the mouth hook coordinate and is pinned; `q=1` is the tail. A signed, one-direction C curve is blended with two phase-shifted longitudinal waves. Their phase advances deterministically from hanging elapsed time and simulation seed, so the wave travels toward the tail and produces alternating S shapes. The shader also transforms vertex normals and tangents using the deformation gradient. The mesh instance AABB is expanded for the maximum configured bend.

The line and fish-mouth anchor remain in the existing node transform. Since the shader curve evaluates to zero at the hook coordinate, the mouth does not move as the body bends. The tail probe uses the same CPU mirror of the shader curve for debug/clearance queries; it does not alter the mesh.

## Motion and tuning

The five phases remain 3 / 15 / 22 / 8 / 8 seconds (56 seconds total). Hanging elapsed time starts at the existing lift start and continues through Catch Presentation; settlement at 48 seconds does not restart the fish motion.

`FishingFightProfile` now configures:

- `hanging_body_wriggle_amplitude_ratio`: bend displacement as a fraction of natural body length.
- `hanging_body_wriggle_frequency_hz`: traveling-wave speed.
- `hanging_body_tail_power`: C-curve emphasis toward the tail; the S-curve uses a lower exponent to keep its mid-body lobe visible.
- `hanging_body_wriggle_pulses`: `Vector4(start_seconds, strength, bend_sign, S_curve_mix)` entries.

Sea Trout uses ratio `0.20`, frequency `2.4 Hz`, and tail power `1.65`, with stronger early C/S bursts. Needlefish uses ratio `0.13`, frequency `3.8 Hz`, and tail power `1.95`, producing a quicker, slimmer whip with lower maximum displacement. Both profiles have pulses through about 10 seconds: strongest during the first two seconds, weaker intermittent events over the next few seconds, and small late twitches that fade near the end of the display.

## Changed files

- `scripts/fishing_rod_rig.gd`
- `scripts/fishing_rod_system.gd`
- `scripts/fishing_fight_profile.gd`
- `resources/fishing/fight_profiles/sea_trout.tres`
- `resources/fishing/fight_profiles/needlefish.tres`
- `shaders/fishing_catch_deform.gdshader`
- `tests/test_fishing_p3_3c_1.gd` (deformation assertions updated for the shader path)

P2 catch probability/settlement, rod geometry, line tension, surface path, camera behavior, HUD, and phase durations were not changed.
