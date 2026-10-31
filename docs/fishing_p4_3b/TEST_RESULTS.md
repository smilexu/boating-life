# Fishing P4.3b — Test Results

| Check | Result | Notes |
|---|---|---|
| P4.3b display mapping, segmentation, marker toggle and localization | PASS | `godot --headless --path . --script res://tests/test_fishing_p4_3b.gd` — 19 assertions passed, failures=0. |
| P4.3a Gain/Range regression | PASS | `godot --headless --path . --script res://tests/test_fishing_p4_3a.gd` — failures=0. |
| P4.2 display and isolated preview regression | PASS | `godot --headless --path . --script res://tests/test_fishing_p4_2.gd` — failures=0. |
| P4.1 sensor regression | PASS | `godot --headless --path . --script res://tests/test_fishing_p4_1.gd` — failures=0. Bathymetry fixture logged its existing no-ShaderMaterial warning. |
| P2 fishing regression | PASS | `godot --headless --path . --script res://tests/test_fishing_p2.gd` — failures=0, including Authority/RNG isolation and Fish Finder integration. Same fixture warning as above. |
| Surface fish visibility regression | NOT RUN | Not needed for display-only changes. |
| Headless Editor import/parse | PASS | `godot --headless --editor --path . --quit` — exit code 0, no project script parse errors. Existing duplicate translation UID warnings and an ObjectDB cleanup warning remain. |
| Whitespace check | PASS | `git diff --check` — no issues. |
| Forward+ visual review | NOT RUN | Requires viewing the live game; no visual pass is inferred from Headless tests. |

The P4.2 suite covers the isolated debug preview source switch; P4.1 covers real aggregate echo provenance and sensor history. No separate P4.2.2 test script exists in this checkout. P2 confirms sonar reads the same Authority schools and does not mutate population or encounter RNG.

