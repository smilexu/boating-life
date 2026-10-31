# Fishing P3.3c.6 — Implementation Summary

Only the hanging catch's tail contribution and event-driven burst response were tuned. The integrated C-spine algorithm, its body ramp, line-pinned mouth, continuous tail frequency, and damping coefficient remain unchanged.

## Tail contribution

| Species | Previous tail whip | New tail whip | Change |
|---|---:|---:|---:|
| Sea Trout | 38° | 49.5° | +30.3% |
| Needlefish | 42° | 54.5° | +29.8% |

The previous 150° cumulative turn limit clipped the Sea Trout's positive tail peak. The safety limit is now 158° for the terminal tail tangent only. This gives an effective terminal tail contribution of 33° instead of 25° for Sea Trout (+32%), and 54.5° instead of 42° for Needlefish (+29.8%). The head and middle body profile is unchanged. Existing cross-section rotation carries the stronger curvature; no tail vertex offset was added.

## Burst response

`hanging_burst_speed_multiplier = 1.5` is a separate profile parameter. It speeds the existing pulse envelope and event-driven lateral response, without scaling their amplitudes or changing the continuous 6.2 / 6.8 Hz tail-wag frequencies. The pulse curve reaches and leaves its peak 1.5 times faster (effective active envelope about 0.32 s instead of 0.48 s). Damping remains 2.8 and the existing 20° sway cap remains in force. Thus the burst-driven initial angular velocity increases 50%, while the later residual sway does not.

The first pulse in each profile moved from -0.2 s to -0.1 s so its faster peak remains visible at the lift/display transition instead of peaking before it. Remaining event times, total presentation time, and species differences are unchanged.

## Files

- `scripts/fishing_fight_profile.gd`
- `scripts/fishing_rod_rig.gd`
- `scripts/fishing_rod_system.gd`
- `shaders/fishing_catch_deform.gdshader`
- `resources/fishing/fight_profiles/sea_trout.tres`
- `resources/fishing/fight_profiles/needlefish.tres`
- `tests/test_fishing_p3_3c_1.gd`

No P2, rod, reel, surface path, camera, HUD, or 56-second phase timing was changed.
