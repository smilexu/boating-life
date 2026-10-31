# Fishing P3.3c.1 — Test Results

## Targeted checks

| Check | Result | Command / notes |
|---|---|---|
| P2 fishing / settlement / finder regressions | PASS (previous run) | `godot --headless --path . --script res://tests/test_fishing_p2.gd` — `failures=0`. P2 code was untouched by this presentation-only follow-up. |
| P3 automatic catch flow | PASS | Rerun after the wriggle changes: `godot --headless --path . --script res://tests/test_fishing_p3.gd` — `failures=0`. |
| P3.1 fight / camera / hanging trajectory | PASS | Rerun after the wriggle changes: `godot --headless --path . --script res://tests/test_fishing_p3_1.gd` — `failures=0`; verifies same fish instance, dynamic rod tip to mouth line, head-up/tail-down pose, sampled-water tail clearance, no transition pop, and camera cycling. |
| P3.2 simulation isolation and five phases | PASS | Rerun after the wriggle changes: `godot --headless --path . --script res://tests/test_fishing_p3_2.gd` — `failures=0`. |
| P3.3c.1 hanging struggle / result card | PASS | `godot --headless --path . --script res://tests/test_fishing_p3_3c_1.gd --quit-after 180` — `failures=0`; verifies dynamic catch mesh setup for both fish, opposing head/tail vertex displacement around a stable center, alternating S bends, line-to-mouth continuity, return to source mesh pose, decaying motion, and real/simulation card behavior. |
| Godot project script/resource scan | PASS with environment warnings | `godot --headless --editor --path . --quit` exited `0` and registered `FishingRodSystem`. No Fishing parse errors. It reported unrelated duplicate translation UIDs in sailing docs, an OS certificate query error, inability to save user-level editor settings, and a leaked ObjectDB instance at exit. |
| `git diff --check` | PASS for tracked diff | No whitespace errors. New/untracked files are not included by Git's normal `git diff --check`. |
| Trailing whitespace scan | PASS | `rg -n '[[:blank:]]+$'` over the task's changed scripts, resources, translations, tests, and reports found no matches. |
| Forward+ visual inspection | NOT RUN | Headless checks cannot verify actual hanging position against rails/deck, fish visibility, or card composition in each live camera. |
| Windows runtime check | NOT RUN | No Windows runtime available in this run. |

## S-bend follow-up

- `godot --headless --path . --script res://tests/test_fishing_p3_3c_1.gd --quit-after 180` — PASS, failures=0. Includes actual cached GLB vertex comparisons for Sea Trout; Needlefish dynamic mesh and direction are also checked.
- `godot --headless --path . --script res://tests/test_fishing_p3_1.gd --quit-after 240` — PASS, failures=0. Confirms fish remains head-up, tail-down, line end remains at the mouth, and sampled-water clearance tests still pass.
- Forward+ view of the vertex-deformed mesh and its lighting — NOT RUN. Headless results prove data and state behavior, not rendered appearance.
- Attempted to inspect the running Godot app through the screen-control surface; selecting the Godot window timed out, so no live screenshot was available.

## Environment notes

Some headless commands printed `user://logs` write/rotation errors, a macOS certificate query error, or a world-time save warning on shutdown. Each relevant test still exited `0` and reported `failures=0`; these messages are recorded rather than treated as visual validation.

