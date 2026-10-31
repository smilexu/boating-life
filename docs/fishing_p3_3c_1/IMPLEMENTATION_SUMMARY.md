# Fishing P3.3c.1 — Implementation Summary

## Status

Implemented. Targeted Headless checks passed; live Forward+ visual confirmation remains `NOT RUN`.

## Hanging fish presentation

- Removed the fixed deck landing point and short arc from `scripts/fishing_rod_mount_profile.gd` and both boat mount resources. Surface, breach, and gill-wash motion remain unchanged.
- The same temporary catch model now blends from the existing water pose to a suspended pose. Its mouth anchor is placed `0.45 m` below the **current deformed rod tip** (`FishingRodRig.get_rod_tip_world()`); the line stays visible and terminates at that anchor.
- The fish turns smoothly to a head-up / tail-down pose around the mouth anchor. During its final hanging struggle, the catch mesh itself bends around the body center: vertices near the middle stay close to the original line, while the head and tail move to opposite sides to form an alternating S curve. The visible mouth hook offset follows the deformed head, so the line remains connected. Whole-fish swinging is limited to a small supporting motion instead of making the fish pendulum around its mouth.
- Each catch mesh is copied once to a fixed-topology `ArrayMesh` configured for dynamic vertex updates. The temporary mesh preserves its source surfaces and materials; only vertex positions update during the short hanging struggle, then they return to the imported pose. There is no skeleton, per-fish AI, or physics rope. Imported normals remain unchanged during the bend, so side lighting may be less exact than the silhouette; this needs Forward+ visual review.
- The body-wriggle envelope lasts four seconds and eases to rest over the next two seconds. Sea Trout uses `0.09 m` amplitude at `2.1 Hz`; Needlefish uses `0.075 m` at `3.0 Hz`. Both settings are per-species Resource values. Fixed pulse starts are `0.08 / 0.82 / 1.62 / 2.40 / 3.10 s`, with a `0.72 s` pulse window and decreasing strength. The seed offsets the combined wave so replay remains deterministic.
- Local `WaveSampler` height, fish length, and the mount clearance margin are used to keep the tail above nearby water where possible. The F3 snapshot reports hanging line length and tail clearance.
- Both `starter_cargo_boat` and `nordic28` use a `0.45 m` minimum hanging line, `0.10 m` water-clearance margin, and `12°` mount clearance cap. Both fish profiles use a 4 s hanging struggle. Sea Trout allows up to `4°` whole-body sway and `6°` axial twist; Needlefish allows `4°` and `7°`. The body curve is the fixed function `sin(PI * (u - 0.5))`, where `u` runs from tail (`0`) to head (`1`); the animated signed amplitude reverses it between opposite S bends.

## Settlement UI

- `BoatHUD` owns a screen-space `CatchResultCard` on its existing `CanvasLayer`. It is not attached to the fish or an active camera. It displays localized confirmed-catch or simulation-preview text, species, length, and weight.
- Real result data is supplied only after the existing P2 settlement succeeds. Preview cards use the selected simulation data and never call settlement.
- The card fades in over `0.4 s` using the presentation timeline. Real and simulated result cards remain visible throughout the eight-second presentation and for twelve more seconds after the fish model is cleaned up, fading out at the end of that hold. Switching camera does not restart the card.
- The Trolling panel's session-only “Last catch” line updates only from authoritative `catch_succeeded`; simulation, cancellation, and failed settlement do not update it. It is not persisted.

## Timing and compatibility

The existing 56-second schedule and the P2 settlement point are unchanged. No catch probability, population, species length distribution, vessel physics, or P2 statistical trolling distance was changed. No additional camera or physics simulation was added.

## Tunable versus fixed presentation values

- Resource-configurable: final line length, water margin, per-mount clearance sway cap, per-species hanging duration, S-bend amplitude/frequency, maximum small body sway/twist, and residual sway.
- Fixed in the controller: inferred mouth hook point at `45%` of model length along the mapped nose axis; bend shape and normalized hook location (`u=0.95`); five short body-undulation pulse starts/strengths; post-struggle deformation decay `2 s`; result card fade-in `0.4 s`, hold `12 s` after fish cleanup, fade-out `0.6 s`.
- The mouth point is inferred from the existing GLB body-axis mapping and length; there is no authored mouth marker in these models. The clearance adjustment samples water and fish length, but does not collision-test rails or deck geometry.

## Follow-up: body-centered swimming deformation

- The previous whole-model mouth-pivot swing was replaced with a real mesh-space S bend in `scripts/fishing_rod_rig.gd`. Head and tail vertex bands move in opposite directions, the mid-body stays centered, and `get_catch_hook_point_world()` includes the moving head offset used by the line.
- `FishingFightProfile` now exports `hanging_body_wriggle_amplitude_m` and `hanging_body_wriggle_frequency_hz`. The Sea Trout and Needlefish resources have different amplitudes and rhythms. Existing long-axis rotation values were reduced to small secondary motion.
- Surface-lift and catch-display elapsed time now use the same clock origin (lift start), avoiding a discontinuity when the fish transitions from lift to hanging display.
- New targeted assertions in `tests/test_fishing_p3_3c_1.gd` sample the actual cached catch vertices and verify opposite head/tail displacement, a stable middle, reversed bends, line-to-mouth continuity, and restoration to the source mesh pose.
- Visual inspection remains `NOT RUN`; the dynamic bend has only been checked in Headless.

## Files changed for this task

- `scripts/fishing_rod_mount_profile.gd`
- `scripts/fishing_fight_profile.gd`
- `scripts/fishing_rod_rig.gd`
- `scripts/fishing_rod_system.gd`
- `scripts/fishing_player_panel.gd`
- `scripts/boat_hud.gd`
- `resources/fishing/rod_mounts/starter_cargo_boat.tres`
- `resources/fishing/rod_mounts/nordic28.tres`
- `resources/fishing/fight_profiles/sea_trout.tres`
- `resources/fishing/fight_profiles/needlefish.tres`
- `resources/translations/fish_species.csv`
- `tests/test_fishing_p3_1.gd`
- `tests/test_fishing_p3_3c_1.gd`
- `docs/fishing_p3_3c_1/*.md`

