# Fishing P4.3b — Implementation Summary

Status: implementation and targeted Headless checks complete. Forward+ visual review remains NOT RUN.

## Display changes

- `scripts/fish_finder_display.gd` replaces the old per-school horizontal line and round dots with a deterministic three-layer echo blob: dark red/orange fringe, strength-mapped body, and a smaller bright core.
- Blob footprint uses the recorded `echo_width_m`, mapped echo strength, and current plot size. A stable phase derived from `echo_id` controls small edge variations; there is no random call and no scan value is rewritten.
- Same-school records are joined only across adjacent recorded scans no more than 0.75 seconds apart. The connecting ribbon follows the recorded depth at each endpoint. Empty, invalid, missing, out-of-order, or stale columns break the segment. No standard fish arc or unobserved depth is synthesized.
- Bottom shading remains tied to valid recorded bottom depths. The connection gap is limited to 0.75 seconds; true depth steps are preserved rather than smoothed away.
- Existing P4.3a Gain mapping remains the sole fish-return brightness mapping. Sensor history, raw strength, overlap, school count, scan cadence, and fishing rules are unchanged.
- Expanded settings add `Fish Symbols`, default off. When enabled, the display selects at most one strongest eligible echo from each uninterrupted School segment and places a small generic marker at that recorded time/depth. It shows no species or fish count. Session state is shared by mini/expanded view and debug preview.
- F3 reports whether Fish Symbols is enabled. New labels use the existing English and Simplified Chinese translation catalog.

## Files

- `scripts/fish_finder_display.gd`
- `scripts/fishing_debug_panel.gd`
- `resources/translations/fish_species.csv` and generated translations
- `tests/test_fishing_p4_3b.gd`
- `docs/fishing_p4_3b/`

## Verification

- P4.3b: 19 assertions passed.
- P4.3a, P4.2, P4.1, and P2 targeted suites: all passed with `failures=0`.
- Headless Editor import/parse and `git diff --check`: passed.
- Forward+ visual comparison: NOT RUN.

