# Fishing P3.3c.5 — Test Results

| Check | Result | Notes |
|---|---|---|
| `godot --headless --path . --script res://tests/test_fishing_p3_3c_1.gd` | PASS | Exit 0; `failures=0`. Covered C-angle progression/reversal, bounded tail turn, lateral swing range and axis, repeatable burst state, body-length scaling, shader uniforms, mesh/normals, and mouth/line anchoring for Sea Trout and Needlefish. |
| `godot --headless --path . --editor --quit` | PASS | Exit 0; project scan completed. Existing duplicate translation UID warnings appeared. Headless editor reported no rendering device and one ObjectDB instance leak on exit. |
| `git diff --check` | PASS | No whitespace errors. |
| Forward+ visual check using F3 simulation | NOT RUN | The available Godot window is the editor with `main.tscn`; no running game window is available. Headless mode has no rendering device, so it cannot establish that the C silhouette, tail whip, mesh surface quality or framing look correct in-game. |

The targeted SceneTree test also prints a non-fatal Dummy Renderer error, `Parameter "material" is null`, during the existing HUD setup. The test continues and exits 0; it is unrelated to the new spine calculation.
