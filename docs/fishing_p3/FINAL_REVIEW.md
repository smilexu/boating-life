# Fishing System P3 — Final Review

**Implementation status: COMPLETE.** Focused P2/P3 tests and Godot import/scene parsing passed. Interactive Forward+ visual and mouse review is **NOT RUN**; see limitations below.

## Player operation

The main Boat HUD now shows a compact **Trolling** panel below the upper-left vessel status. Choose one of the loaded lures (its running depth is shown), then use **Start trolling** or **Stop**. The line casts automatically. A real P2 hook event shows the hook feedback, loads the rod and starts automatic retrieval. Successful P2 settlement briefly shows localized fish name, natural length and estimated weight, then resumes trolling. Stopping during a catch cancels it through P2 and clears the visuals.

For development testing, press **F3 → Fishing**. Use the existing P2 valid-candidate force-hook operation to trigger the same P3 rod/reel path, and use the P3-aware settlement button to skip the remaining visual timer while still calling P2 settlement. **Reset rod to standby** clears the visual rig. F3 candidate IDs, rates and force-hook actions remain debug-only.

## Delivered behavior

- One configurable visual rod mount is attached to each supported hull's visual root; only the active vessel's rig is shown. No collision, hull physics, P2 bite rate or boat handling was changed.
- The procedural dark graphite rod uses 12 fixed MultiMesh segments by default. Seven guide rings follow the rod curve, as do the low-cost line segments. Load rises smoothly from the root toward the tip; line-out and reel-in are state driven. The spool rotates while line is moving; a short ring splash accompanies the near-surface phase.
- Rod mount data lives in `FishingRodMountProfile`; current per-hull profiles are `resources/fishing/rod_mounts/starter_cargo_boat.tres` and `nordic28.tres`. Both start at 2.25 m rod length, seven guides, 12 rod segments, 34° elevation, 0.48 m maximum hook bend and 4.5 m visible line-out length. Mount position is hull-local and can be adjusted per profile.
- The player UI and debug controls use localization keys in `resources/translations/fish_species.csv` (English and Simplified Chinese). No translated text is stored in fishing state or save data.
- The UI currently offers the three existing P2 resources: surface lure, shallow minnow and medium minnow. P2 species compatibility means needlefish and sea trout can enter normal trolling candidates; herring and stickleback remain excluded.
- Temporary catch display reuses only the needlefish and sea-trout GLBs. It scales their imported X-axis body bounds to the natural `PendingCatch.body_length_m`, uses the existing profile's Positive-X/Negative-X nose convention, and points the nose toward the boat. It never creates or removes Authority fish.
- The P2 pending-catch contract now carries a natural body length rolled at hook time with an independent seeded RNG stream. `CatchResult` uses that same value, so displayed length and final length match. The encounter-selection random stream remains independent.
- A rejected settlement grants no catch. P3 clears a matching still-pending event, but will not cancel a newer event with a different catch ID. Successful settlement remains the sole point that decrements one Authority fish.

## Main integration and API

- `scenes/Boat.tscn` adds the P3 controller with the starter-boat and Nordic 28 mount Resources.
- `scripts/boat_hud.gd` creates the player trolling panel and passes the existing `FishResourceManager` and `FishingRodSystem` references.
- `scripts/fishing_rod_system.gd` consumes the manager's existing P2 encounter signals; it does not roll bites. Useful P3 calls are `start_trolling()`, `stop_trolling()`, `get_visual_state_name()`, `debug_complete_retrieval_now()` and `debug_reset_visual()`.
- P2's existing events remain the integration contract: `fish_hooked(PendingCatch)`, `retrieval_started(catch_id)`, `catch_succeeded(CatchResult)`, and `catch_cancelled(catch_id, reason)`. P3 emits `presentation_state_changed(state_name)` and `catch_presentation_started(CatchResult)` for a future UI/audio consumer.
- Catch timing is configurable on `FishingRodSystem`: 1.25 s cast, 0.62 s hook response, 5.6 s retrieval, 2.8 s result display, 1.0 m visual fish lift. These are presentation timers, independent of P2 game's event clock.
- P2's statistical lure point remains controlled by `FishingEncounterSystem.lure_trailing_distance_m`; the rod mount's `line_out_length_m` controls only the visible lure/fish path. Visual rope length does not affect bite probability.

## Validation

- `godot --headless --path . --script res://tests/test_fishing_p3.gd`: **PASS**, exit 0, no assertion failures. Validates resource/scene loading, rod topology/load/bend, line activation, GLB instances and nose-axis mapping, a valid Authority school hook, automatic retrieval, successful one-fish P2 settlement, fixed display/result length, auto-resume and player stop.
- `godot --headless --path . --script res://tests/test_fishing_p2.gd`: **PASS**, exit 0, no assertion failures. P2 settlement, duplicate rejection, catch length, lures, Fish Finder and localization checks pass.
- `godot --headless --path . --editor --quit`: **PASS**, exit 0; P3 scripts/classes and scene/resource scan completed.
- `git diff --check`: **PASS**, no whitespace errors.
- The full test outcomes and warnings are in `docs/fishing_p3/TEST_RESULTS.md`.

## Limitations / manual review

- Forward+ visual inspection and actual mouse operation are **NOT RUN**. Check aft mount placement and clearance on the starter boat and Nordic 28, rod visibility from the usual third-person camera, line path at the water surface, reel/guide readability, fish body orientation/size in 3D, splash timing, and the HUD's overlap/readability at game resolutions and both locales. Headless tests verify the configured model axis mathematically, not the rendered mouth/tail in a live camera.
- The current rig is visual-only: no flexible submerged rope simulation, fish struggle animation, or physical lure path is modeled. Fish presentation rises along the visual retrieval path; the P2 statistical point remains separate.
- Only needlefish and sea trout have designated catch display GLBs in this first version. Other species cannot normally be caught with the configured lures, and no fallback fish model is fabricated.
- This does not implement Fish Finder UI, fish inventory, sale, stopping to fish, manual fighting or multiple rods. The existing `FishFinderSensor` remains suitable as a future P4 data source.
- Windows runtime validation was not available. No frame-rate claim is made; the rig avoids physics bodies and per-frame mesh reconstruction, but live Mac/Windows rendering should be observed during the manual review.

## P4 handoff

P4 can continue to query the existing `FishFinderSensor` through `FishResourceManager.get_fish_finder_sensor()`, and can consume `get_last_scan()` / `get_scan_history()` without coupling sonar UI to fish rendering or trolling. A future inventory can consume `catch_succeeded(CatchResult)`; it should persist `catch_id` with the result and avoid re-settling it.
