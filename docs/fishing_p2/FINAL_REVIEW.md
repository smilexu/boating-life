# Fishing System P2 — Final Review

**Status:** COMPLETE for the requested core APIs and debug workflow. Forward+ interactive visual review remains NOT RUN.

## Delivered

- Three editable `FishingLure` Resources, profile-based lure/method matching, depth preference weighting, and per-species trolling speed/weight tuning.
- One `FishingEncounterSystem` owned by `FishResourceManager`, using the existing local Authority and spatial index.
- Explicit `FishingPendingCatch` and `FishingCatchResult` records, start/hook/retrieval/settlement/cancel signals, and one-fish Authority settlement.
- One configurable `FishFinderSensor` over the same fish Authority, with a downward cone and bounded echo history.
- Localized F3 Fishing tab for balancing and lifecycle checks. No player-facing fishing UI, rod or catch animation was added.

## Modified and added files

- `scripts/fishing_lure.gd`
- `resources/fishing/lures/surface_lure.tres`
- `resources/fishing/lures/shallow_minnow.tres`
- `resources/fishing/lures/medium_minnow.tres`
- `scripts/fish_species_profile.gd`
- `resources/fish_species/needlefish.tres`
- `resources/fish_species/sea_trout.tres`
- `scripts/fishing_pending_catch.gd`
- `scripts/fishing_catch_result.gd`
- `scripts/fishing_encounter_system.gd`
- `scripts/fish_finder_sensor.gd`
- `scripts/fish_resource_manager.gd`
- `scripts/fishing_debug_panel.gd`
- `scripts/boat_hud.gd`
- `resources/translations/fish_species.csv`
- `tests/test_fishing_p2.gd`
- This document and `IMPLEMENTATION.md`, `TEST_RESULTS.md`.

## Lures and species tuning

| Lure ID | Work depth below live surface | Preferred depth | Compatibility |
|---|---:|---:|---|
| `surface_lure` | 0–1.5 m | 0.65 m | `surface_lure` tag; needlefish |
| `shallow_minnow` | 0.5–3 m | 1.7 m | `minnow`, `small_fish_lure`; needlefish and sea trout |
| `medium_minnow` | 2–6 m | 4 m | `minnow`, `small_fish_lure`; needlefish and sea trout |

Each lure uses a Gaussian weight centered at its preferred depth, clipped to the configured interval and local water column above seabed clearance. The player chooses a lure, never a depth. The surface lure only carries its explicit surface tag so Sea Trout's minnow/spoon tags do not accidentally match it.

Needlefish has a 1.6 m/s optimum and 1.0 m/s falloff; Sea Trout has 1.4 m/s and 0.8 m/s. Profile fields are tuning inputs, not real catch observations. Herring and Three-spined Stickleback have no supported trolling method and cannot enter the valid candidate pool.

## Encounter equation and initial expected intervals

Per-school event rates are summed in events per game-hour:

`lambda_i = base_rate × bite_tendency × min(sqrt(population), 3) × distance_weight × depth_weight × speed_efficiency`

`P(event in dt_game) = 1 - exp(-lambda_total × dt_game / 3600)`

The configured base rate is 1.2 per game-hour. School queries use the Authority's indexed `get_schools_near()` snapshots. A simple lure point trails 8 m behind the boat. Distance uses the configured encounter radius plus each species profile's school activity radius; one school is cooled down for 600 game seconds after hooking. Candidate evaluation is sampled at 4 Hz real time and integrates the accumulated shared game-clock time, avoiding a full nearby-school query every rendered frame.

Illustrative idealized intervals at 2.5 kn (1.286 m/s), one school at the lure point, preferred depth, depth/distance weights 1.0:

| Scenario assumption | Rate | Expected interval |
|---|---:|---:|
| Needlefish, shallow minnow, population 6 | 3.358 / game-hour | 17.9 game minutes |
| Sea Trout, medium minnow, population 2 | 1.512 / game-hour | 39.7 game minutes |
| Incompatible lure, no eligible school, inactive depth, or invalid water column | 0 | No encounter |

These are formula-based game-balance estimates, not fishing statistics; real distances and depth weights lengthen the interval. At a 24× world-time scale, the first two ideals correspond to about 45 s and 99 s of real time. A pending catch blocks further hooks, including under accelerated world time.

## Catch lifecycle and API

`FishResourceManager` exposes:

- `get_fishing_encounter_system()`
- `get_fish_finder_sensor()`
- `get_world_game_time_seconds()`
- Existing `get_schools_near()`, `get_school()`, `get_species_profile()` and `request_population_change()` remain the sole ecological interfaces.

Encounter methods include `select_lure()`, `start_trolling()`, `stop_trolling()`, `evaluate_candidates()`, `begin_retrieval()`, `complete_retrieval()` and `cancel_pending_catch()`. Debug-only controls are `set_random_seed()`, `debug_roll_bite_once()` and `debug_force_hook_valid_candidate()`; force-hook still requires a valid current school candidate.

Signals: `trolling_started`, `trolling_stopped`, `fish_hooked`, `retrieval_started`, `retrieval_completed`, `catch_succeeded`, `catch_cancelled`, and `state_changed`.

`FishHooked` creates a `PendingCatch`; it does not reduce population. Only successful `complete_retrieval()` validates the current school/profile and asks the Authority for `-1`. `CatchResult` contains catch/species/school/lure IDs, natural body length, estimated mass (`species coefficient × length³`), capture game time, and population before/after. Repeated completion is rejected and cannot remove a second fish. If the boat reference changes, pending state is cancelled. Catch IDs are unique within the active encounter-system session; a future persisted inventory should use a durable transaction/idempotency ledger across save sessions.

Population recovery remains inside the existing Authority. The dedicated existing recovery test passed; no duplicate recovery data or renderer-dependent population was added.

## Fish Finder output

Call `FishFinderSensor.scan(force := false)`; ordinary scans honor `scan_interval_game_seconds` (2 s by default), and F3 requests a forced manual scan. `get_last_scan()` and `get_scan_history()` expose bounded history (12 by default).

Scan results include probe world position, chart depth below LAT, live surface height, water-column depth, scan game time and anonymous echo entries. Echoes contain relative position, fish depth below live surface, slant/horizontal range, simplified strength, activity state and a coarse group-size band. They deliberately omit `species_id`, `school_id` and bite chance. Probe/bait location are separate; Finder and trolling query the same Authority and never instantiate deep logical fish.

## Debug access

Press **F3** and open the **Fishing** tab. It provides lure selection, deterministic seed input, start/stop trolling, a one-window 60-game-second probabilistic check, force-hook from a valid school, begin/complete retrieval, cancel, and manual Fish Finder scan. It displays speed, effective lure depth, candidates and rejection reasons, depth/speed weights, total rate, pending catch, last result/population change, and recent sonar echo summary. New text uses the project's English and Simplified Chinese translation CSV.

## Validation and limitations

- `godot --headless --path . --editor --quit`: PASS, exit 0; classes and translation CSV imported.
- `godot --headless --path . --script res://tests/test_fishing_p2.gd`: PASS, all focused assertions.
- `godot --headless --path . --script res://tests/test_fish_population_recovery.gd`: PASS, existing dedicated recovery assertions.
- `git diff --check`: PASS.
- The Fishing P2 test now uses a lightweight fixture instead of loading `main.tscn`; it exits 0 with `failures=0` and no DummyShader RID leak. It prints an expected warning because the fixture has no water `ShaderMaterial`, so optional sea tint is disabled. The separate population-recovery test still loads `main.tscn` and previously emitted the dummy-renderer shutdown warning; that does not affect the Fishing P2 test. Editor import also reports duplicate UIDs in unrelated historical P2.5/P2.15 report translations.
- Interactive Forward+ layout/click validation is NOT RUN. The headless run confirms the Fishing tab exists and test controls call the APIs, but it does not certify visual spacing or actual mouse interaction.
- No long Monte Carlo or catch-rate calibration was run. Initial intervals are starting game tuning values.

## P3 integration suggestions

1. Connect `fish_hooked` to rod/line feedback and suspend encounter checks while pending.
2. Call `begin_retrieval()` when the player starts the retrieval action.
3. On a successful animation outcome call `complete_retrieval(catch_id)`; on lost/cancelled outcomes call `cancel_pending_catch()`.
4. Consume `catch_succeeded(CatchResult)` to add the fish to a future inventory. Persist the result and settlement ID atomically before allowing retries.
5. Drive a future rolling sonar UI by calling `scan(false)` on its visual update timer; do not create visual schools from echo data.
