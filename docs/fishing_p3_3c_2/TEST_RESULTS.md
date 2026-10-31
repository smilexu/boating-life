# Fishing P3.3c.2 — Test Results

## Targeted checks

| Check | Result | Evidence |
|---|---|---|
| Hanging deformation and result-card test | PASS | `godot --headless --path . --script res://tests/test_fishing_p3_3c_1.gd --quit-after 180 --log-file /tmp/fishing_p3_3c_2_test.log`; exit `0`, `failures=0`. Covers burst decay, mouth pin, opposing C/S samples, imported mesh retention, material maps, length scaling, shader uniforms, and result-card regressions. |
| P3.1 fight / line / hanging trajectory regression | PASS | `godot --headless --path . --script res://tests/test_fishing_p3_1.gd --quit-after 240 --log-file /tmp/fishing_p3_3c_2_p31.log`; exit `0`, `failures=0`. Covers 56-second timing, fish-mouth line endpoint, hanging pose and clearance, and Fight Camera cycling. |
| Godot editor resource/script scan | PASS with environment and existing warnings | `godot --headless --editor --path . --quit --log-file /tmp/fishing_p3_3c_2_editor.log`; exit `0`, scan completed. It reports duplicate translation UIDs, an ObjectDB leak, and cannot save `~/Library/Application Support/Godot/editor_settings-4.7.tres` in this restricted environment. It says `No rendering device on load`, so this does not verify Forward+ shader compilation or appearance. |
| `git diff --check` + task-file whitespace scan | PASS | `git diff --check` returned clean; a separate scan covered the new untracked implementation, shader, test, and report files. |
| Forward+ shader rendering and motion | NOT RUN | The visible Godot window remained in the editor's 3D workspace. The attempted run action did not open a game window; no shader output was visually inspected. |
| Windows runtime | NOT RUN | No Windows runtime was available. |

## Important validation boundary

Headless checks verify the GLB structure, shader source/material binding, deterministic curve calculations, shader uniforms, bounds expansion, and line-anchor state. They do not prove that Metal renders the S curve smoothly or that the copied PBR appearance exactly matches the imported material. The test log also contains a macOS certificate-store lookup error, a dummy-renderer `Parameter "material" is null` message during teardown, and a warning that world-time state could not be saved; assertions still finish with `failures=0`. These are outside the fishing assertions and need a real Forward+ run to establish actual shader appearance.
