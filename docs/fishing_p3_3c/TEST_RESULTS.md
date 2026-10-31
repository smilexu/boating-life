# Fishing P3.3c — Test Results

## Targeted automated checks

| Command | Result | Notes |
|---|---|---|
| `godot --headless --path . --script res://tests/test_fishing_p3_1.gd` | PASS | Checks deterministic near-boat approach, below-water depth, side-to-side motion, non-reversing line water entry, splash following, Sea Trout breach/gill-wash, curved lift to deck, both species' presentation, and the 2.4 mm line versus rod-tip diameter. |
| `godot --headless --path . --script res://tests/test_fishing_p2.gd` | PASS | P2 lure, encounter, Authority settlement, duplicate-settlement protection, and Fish Finder checks pass. Existing test fixture warning: BathymetryManager has no ShaderMaterial reference, so sea tint stays disabled. |
| `godot --headless --path . --script res://tests/test_fishing_p3.gd` | PASS | Real hook, automatic retrieval/settlement, catch length, cancellation, and resuming trolling pass. Same non-fatal test-fixture bathymetry warning. |
| `godot --headless --path . --script res://tests/test_fishing_p3_2.gd` | PASS | Simulated catch, phase seeking, pause/speed/replay, no Authority population change, and no P2 RNG change pass. Same non-fatal test-fixture bathymetry warning. |
| `godot --headless --editor --path . --quit` | PASS | Godot 4.7.2 scanned project classes and loaded the initial scene, then exited 0. It reported pre-existing duplicate translation UID warnings under `docs/sailing/` and one ObjectDB instance leak at shutdown; no GDScript parse error appeared. |
| `git diff --check` | PASS | No whitespace errors. |

All four test scripts report `failures=0`. They ran on Godot 4.7.2 headless. Their output does not establish Forward+ appearance or performance.

During iteration, an initial single-frame lateral-offset assertion was too strict because the seeded pose can be near its center crossing. The check was changed to sample the deterministic motion across several times; the final side-to-side range check passes.

## Visual verification

**Forward+ live-scene check: NOT RUN.** No visual pass is claimed. Please inspect the P3.2 simulated catch on both the starter cargo boat and Nordic 28, especially the thin line against blue water, fish visibility during the last retrieval seconds, rail clearance, splash placement, and the final deck pose. The near-surface and landing paths are automated geometry checks only.

## Known limitation

The temporary fish remains a rigid GLB with whole-model pose changes; no skeletal tail animation was added. Sea Trout has a configured breach and side-on gill-wash; Needlefish uses the shared near-surface/lift path without a Sea Trout-specific gill-wash action.
