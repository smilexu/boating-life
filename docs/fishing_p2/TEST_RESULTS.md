# Fishing System P2 — Test Results

## Targeted results — 2026-10-30

| Check | Status | Command / evidence |
|---|---|---|
| Godot script class/resource/translation import | PASS | `godot --headless --path . --editor --quit` — exit 0; new classes registered and `fish_species.csv` imported. |
| Lure Resources and depth weights | PASS | `godot --headless --path . --script res://tests/test_fishing_p2.gd` — all three Resources loaded; preferred depth weighted; out-of-range depth rejected. The test now uses a lightweight bathymetry/wave/boat/authority fixture rather than loading `main.tscn`. |
| Species/lure rules | PASS | Same P2 test — needlefish and sea trout match configured lures; herring and stickleback excluded; surface lure compatibility is explicit. |
| Speed, pause, deterministic probability | PASS | Same P2 test — optimum speed, stationary/cap rejection, zero paused delta, split-window hazard composition, fixed-seed candidate selection. |
| No valid Authority candidate | PASS | Same P2 test — no nearby valid school yields zero valid candidates and no forced catch. |
| Hook/retrieval/settlement/idempotency | PASS | Same P2 test — valid school links to PendingCatch, settlement decrements one fish, length uses the species range, repeat settlement is rejected, exhausted school cannot settle stale pending state. |
| Fish Finder geometry/data/privacy/history | PASS | Same P2 test — actual authority school echo under cone, live surface and LAT depth path, no species/school ID/catch chance in echoes, bounded history. |
| Visual/population independence | PASS | Same P2 test disables `visual_enabled` for every species and confirms the authoritative school/population queries remain unchanged; renderer nodes are intentionally absent from the lightweight fixture. |
| English/Simplified Chinese fishing strings | PASS | Same P2 test iterates all `fishing.*` keys from `resources/translations/fish_species.csv` under `en` and `zh_CN`. |
| Existing population recovery dependency | PASS | `godot --headless --path . --script res://tests/test_fish_population_recovery.gd` — dedicated recovery test passed; no full P1 suite run. |
| Whitespace/conflict-marker diff check | PASS | `git diff --check` — exit 0. |
| Interactive Forward+ F3 visual/click validation | NOT RUN | The headless test confirms the Fishing tab node exists; visual layout and actual button interaction require interactive runtime review. |
| Long-duration catch-rate balancing / Monte Carlo | NOT RUN | Explicitly out of scope for P2. |

## Observed environment warnings

- The Fishing P2 headless test exits 0 with `failures=0` and no DummyShader RID leak after switching to the lightweight test fixture. It emits one expected BathymetryManager warning that no water ShaderMaterial is attached, so the optional sea tint remains disabled in this fixture.
- The separate existing population-recovery test still loads `main.tscn`; its prior run passed but emitted the DummyShader RID shutdown warning. That warning is not present in the Fishing P2 command.
- Editor import reports duplicate UIDs in two unrelated historical translation artifacts under `docs/sailing/polar_p25/` and `docs/sailing/polar_p215/`. No P2 fishing resource or translation key warning was reported.
- No Forward+ rendering, actual F3 clicking, or gameplay visual review is claimed.
