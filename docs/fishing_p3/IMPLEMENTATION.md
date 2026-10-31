# Fishing System P3 — Implementation

## Scope and verified P2 boundary

P3 adds player interaction and presentation around the existing `FishingEncounterSystem`. P2 remains the only owner of candidate selection, bite events, retrieval state, and authoritative school population settlement. The P3 visual line length is configured independently and never feeds back into P2 encounter calculations.

P2 did not include a catch length on `FishingPendingCatch`; it rolled length during settlement. P3 needs the same length for the temporary fish and final `CatchResult`, so the length roll now happens when P2 creates the pending event, using a separate deterministic RNG stream to keep bite/candidate random draws unchanged.

## Stage status

| Stage | Status | Result |
|---|---|---|
| P3.0 API audit and baseline | PASS | P2 lifecycle, boat roots, HUD and localization entry points identified. |
| P3.1 rod mounts and procedural rig | PASS | Per-hull Resources place a visual-only aft mount; rod, reel, guides, line and splash are built from low-cost fixed-topology visuals. |
| P3.2 rod load and line animation | PASS | Smooth distributed rod bend, short cast, sustained trolling line, retrieval shortening, spool rotation and release are state driven. |
| P3.3 P2 catch lifecycle and display fish | PASS | P2 hook signal drives the display; needlefish/sea trout use their existing GLB and hook-time body length; only P2 settlement awards a catch. |
| P3.4 player and F3 controls/localization | PASS | Player panel selects lures and starts/stops; F3 can exercise valid hook/retrieval/settlement and reset rod visuals; new text has English and Simplified Chinese keys. |
| P3.5 focused validation and final review | PASS | Focused P2/P3 tests, project import/scene scan and diff check recorded. Forward+ visual review remains explicitly NOT RUN. |

## Main implementation decisions

- `FishingRodMountProfile` stores hull-local mount position/rotation, 2.25 m rod length, 7 guides, 12 fixed rod segments, 34° elevation, 0.48 m maximum hook bend and 4.5 m visible line-out length. Profiles live in `resources/fishing/rod_mounts/` for the starter cargo boat and Nordic 28.
- `FishingRodSystem` chooses a mount from the active `BoatController` vessel mode. The fishing rod rig is attached below the corresponding visual root, so it follows that hull's visual motion without adding collision or changing vessel physics.
- `FishingRodRig` updates transforms on fixed rod/guide/line MultiMeshes rather than rebuilding mesh resources per frame. The rod curve holds its root and progressively bends toward its tip. The line is a small number of cylinder segments and ends at a lure/fish position sampled against the existing local wave surface.
- Catch models are temporary instances of the already registered needlefish and sea trout GLBs. The model's X-axis mesh bounds are scaled to `PendingCatch.body_length_m`; the F3 population visuals are not reused as catch size. Nose direction reuses `FishSchoolRenderer.basis_for_model_heading()` and points toward the boat so both Positive-X needlefish and Negative-X sea trout mappings are honored.
- The catch display runs for a configurable 5.6 s retrieval and 2.8 s result presentation by default, inside the requested 4–7 s range. Successful settlement resumes P2 trolling; a rejected settlement clears its matching pending event and grants no catch.
- `FishingPlayerPanel` is a compact HUD control. F3 retains P2 candidate diagnostics/force-hook controls and delegates settlement through the same P3 system when present.
- Debug `visuals_enabled = false` only avoids building meshes; the P2 event and settlement lifecycle remains active for headless testing.

## Files changed for P3

- Boat/HUD integration: `scenes/Boat.tscn`, `scripts/boat_hud.gd`
- Mount and rig: `scripts/fishing_rod_mount_profile.gd`, `scripts/fishing_rod_mount.gd`, `scripts/fishing_rod_rig.gd`, `scripts/fishing_rod_system.gd`, `resources/fishing/rod_mounts/*.tres`
- Interaction and debug: `scripts/fishing_player_panel.gd`, `scripts/fishing_debug_panel.gd`
- P2 event contract needed for consistent display: `scripts/fishing_pending_catch.gd`, `scripts/fishing_encounter_system.gd`
- Localization and focused checks: `resources/translations/fish_species.csv`, `tests/test_fishing_p2.gd`, `tests/test_fishing_p3.gd`
- Stage records: `docs/fishing_p3/IMPLEMENTATION.md`, `TEST_RESULTS.md`, `FINAL_REVIEW.md`

## P3.5 validation notes

Test commands and actual results are recorded in `TEST_RESULTS.md`. Automated headless checks cover Resource/scene loading, fixed rig topology, hook-time length consistency, real Authority school hook, retrieval, settlement, and return to trolling. Interactive Forward+ appearance, layout and mouse operation require a visible game run and remain explicitly marked `NOT RUN` until observed.
