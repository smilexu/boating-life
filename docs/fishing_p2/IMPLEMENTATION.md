# Fishing System P2 — Implementation

**Status:** COMPLETE  
**Scope:** trolling encounter, hook/retrieval/settlement API, lure resources, Fish Finder sensor data, and F3-only diagnostics. No rod animation, inventory, or player-facing fishing UI.

## Stage plan

| Stage | Status | Goal | Expected files |
|---|---|---|---|
| 0. Interface check | PASS | Reuse `FishResourceManager`, school-level Authority queries/population changes, `BoatController` speed in m/s, `WorldTimeManager` game time, existing TranslationServer CSV. | Existing fish/time/boat scripts (read only) |
| 1. Lures and profile fishing data | PASS | Add three editable `FishingLure` resources and complete needlefish/sea-trout fishing configuration. | `scripts/fishing_lure.gd`, `resources/fishing/lures/*.tres`, fish profiles, translations |
| 2. Encounter lifecycle | PASS | Add deterministic game-time encounter rate, validated candidates, pending catch lifecycle, one-fish idempotent settlement through Authority. | `scripts/fishing_encounter_system.gd`, pending/result records, `fish_resource_manager.gd` |
| 3. Fish Finder | PASS | Add explicit cone scan using local indexed Authority schools, LAT depth, activity depth, current WaveSampler surface, and bounded history. | `scripts/fish_finder_sensor.gd`, `fish_resource_manager.gd` |
| 4. F3 diagnostics | PASS | Add a localized fishing debug tab for lure/state/rate/candidates/hooks/settlement/Finder. | `scripts/fishing_debug_panel.gd`, `scripts/boat_hud.gd`, translation CSV/import |
| 5. Targeted tests and review | PASS | Run focused resource, probability, lifecycle/idempotency, Finder, localization, and existing population-recovery checks; record actual results. | `tests/test_fishing_p2.gd`, this directory |

## Confirmed existing interfaces

- `FishResourceManager.get_schools_near(world_position, radius_m)` delegates to the active Authority spatial index and returns authoritative `FishSchoolState` snapshots; it does not use MultiMesh counts.
- `FishResourceManager.request_population_change(school_id, delta)` routes through the active Authority adapter and supplies current `WorldTimeManager` game seconds.
- School snapshots distinguish `depth_m` (chart depth below LAT) and `activity_depth_m` (swimming depth below water surface); surface activity state and population are also available.
- `BoatController.speed_mps` is signed metres/second. `cruise_speed_mps` is a per-vessel property; local bow direction is `-global_basis.z`.
- `WorldTimeManager.state` exposes `cycle_seconds`, `day_cycle_index`, `time_scale`, and `paused`; fish Authority already consumes absolute game-time seconds.
- At the P2 baseline, needlefish had no Fishing tags; P2 now supplies its trolling/lure profile. Sea trout's existing trolling tags are retained. Herring and stickleback remain unsupported.
- Bathymetry queries use LAT/chart datum and ignore position Y. `WaveSampler.sample_physics_surface()` supplies the current physical surface Y; the Finder returns chart/LAT and surface-relative depths separately.

## Decisions / constraints

- Event rates are per game hour; use a continuous-time hazard equivalent to `P=1-exp(-lambda*dt_game)`. Paused game time contributes zero. A single pending catch prevents stacked/automatic catches during acceleration.
- Candidate schools are sampled near a simple fixed stern lure point using the Authority spatial index. Distance, population, Fishing tags/method, current activity depth, lure depth preference, speed curve, and vessel-specific cruise cap all affect rate.
- A per-school game-time cooldown and boat speed efficiency prevent repeatedly harvesting one stationary school. Renderer/MultiMesh/F4 visual counts are never inputs.
- Capture settles only after explicit retrieval completion; it uses Authority `request_population_change(-1)`. Catch IDs are unique per system session and duplicate settlements are rejected.
- Fish Finder uses its own configurable downward cone at the boat transducer point; it queries the same Authority but returns anonymized echo targets without species identity or bite chance.
- All new player-visible F3 copy uses localization keys in the existing English/Simplified Chinese translation CSV.
- The encounter evaluates the spatial query at 4 Hz (0.25 real seconds) while accumulating game-clock seconds between samples; this avoids a school scan every rendered frame while preserving the exponential hazard for piecewise-constant encounter rates.

## Stage 0 actual result — 2026-10-30

- Interface inspection complete; no duplicate fish ecology manager or fishing implementation exists.
- No code changes made in this stage. Proceeding with the planned resource and runtime modules.

## Stage 1 actual result — 2026-10-30

- Added `FishingLure` Resource and three preset `.tres` files. Lure depth is a Gaussian-weighted preferred depth clipped to its configured work interval and the local available water column; the interval is not treated as uniform.
- Added per-species trolling optimum/falloff speed and a game-only length-to-weight coefficient. Needlefish now explicitly supports trolling and lure tags; Sea Trout retains its existing trolling tags; Herring and Stickleback remain unsupported.
- Added only localization keys (no player-facing strings in lure Resources). Headless import and Resource loading passed in the focused validation stage.
- Lure work depths/relative bite values and length-weight coefficients are initial game balance values, not real catch data.

## Stage 2–4 implementation record — 2026-10-30

- Added `FishingEncounterSystem` as one child of `FishResourceManager`; it obtains indexed school snapshots only through `get_schools_near()` and never reads visual fish counts.
- Encounter cadence is an exponential hazard with rates in game-hours. It integrates absolute shared game-clock deltas, so pause adds no chance; explicit jumps over 300 game seconds reset the pending hazard. One pending catch and a per-school 600-game-second cooldown prevent stacked events and immediate re-hits.
- The lure point is a simple 8 m stern offset. Valid rate combines configured base rate (1.2 events/game-hour), profile bite tendency, square-root population capped at 3, encounter-distance weight including profile school activity radius, lure depth preference clipped to local available water, and a Gaussian species speed efficiency. Reverse/stationary motion and speed at/above the vessel's own `cruise_speed_mps` produce zero efficiency.
- `PendingCatch` and `CatchResult` are explicit session records. Only `complete_retrieval()` invokes `FishResourceManager.request_population_change(-1)`; it validates school, species profile and availability first, returns length from the biological profile range, and estimates mass as coefficient × length³. A duplicate completion sees no pending retrieval and cannot subtract twice.
- `FishFinderSensor` is a separate downward cone at a configurable transducer offset. It queries the same spatial index, samples chart LAT depth and each target area's current physical wave surface, clips against local bottom clearance, returns bounded anonymized echo history, and does not expose species or catch chance.
- Added the F3 Fishing tab. It offers lure selection, seed, start/stop, a 60-game-second probabilistic check, force-hook only from a valid current Authority candidate, retrieval/settlement/cancel and manual Finder scan. All new visible labels resolve through `resources/translations/fish_species.csv`.
- Encounter binding follows the active boat returned by the manager; replacing the boat cancels a pending catch and returns the system to IDLE.
- Headless import, focused P2 checks, and the existing dedicated population-recovery test passed; exact commands and the headless RID warning are in `TEST_RESULTS.md`.
