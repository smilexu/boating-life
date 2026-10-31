# Fishing System P3 — Test Results

Date: 2026-10-30. Godot 4.7.2 stable.

| Test | Status | Command / result |
|---|---|---|
| P3 focused visual rig and lifecycle | PASS | `godot --headless --path . --script res://tests/test_fishing_p3.gd`; exit 0, `failures=0`. Checks Boat scene/profile loading, player panel controls, separate visual trailing distance, fixed rod/guide MultiMesh topology, loaded line, gradual tip bend, needlefish and sea-trout GLB presentation instances and profile nose-axis mapping toward the hull, a real valid Authority school hook, hook-time body length, automatic P2 retrieval/settlement, identical display/settlement length, resume and stop. |
| P2 focused fishing regression | PASS | `godot --headless --path . --script res://tests/test_fishing_p2.gd`; exit 0, `failures=0`. Confirms catch length consistency, one-fish settlement, duplicate rejection, Authority queries, Fish Finder and all fishing translations. |
| Project import / global script registration | PASS | `godot --headless --path . --editor --quit`; exit 0. P3 global classes registered and scene/resource scan completed. |
| Formatting / whitespace | PASS | `git diff --check`; no output. |
| Interactive Forward+ visual / mouse review | NOT RUN | Requires a visible runtime. Check mount placement and hull clearance on both vessel types, line/water intersection, natural catch-model orientation and apparent size, splash, localization/layout, and player mouse interaction. Headless test does not certify these. |
| Windows runtime | NOT RUN | No Windows runtime available in this session. |

## Test notes

- P2/P3 lightweight fixture runs emit an expected `BathymetryManager has no ShaderMaterial reference; sea tint stays disabled` warning because the fixture omits the optional sea visualization material. It does not fail the fishing assertions.
- The editor scan reports pre-existing duplicate translation UIDs under `docs/sailing/polar_p25/` and `docs/sailing/polar_p215/`; no P3 resource is involved. The headless editor also reports no rendering device and one ObjectDB instance leaked during editor shutdown. It exits successfully; this does not count as graphical verification.
- No FPS or visual quality claims are made from headless runs.
