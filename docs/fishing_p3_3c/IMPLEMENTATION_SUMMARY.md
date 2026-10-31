# Fishing P3.3c — Implementation Summary

## Scope

Improved the late retrieval, near-surface struggle, breach, lift and catch display for the existing P3 presentation. The P2 encounter, fish population, pending-catch and settlement APIs are unchanged. The P3.2 debug simulation still uses the same presentation state machine and remains isolated from real catches.

## What changed

- The temporary fish becomes visible during the last 64% of progressive retrieval (profile start value: `0.36`), beginning about 5.8 m aft of the hull root and approaching the configured 2.7 m surface-struggle point. Distance uses a smoothstep, so the model does not pop directly beside the stern.
- Fish depth follows the live WaveSampler surface. Sea Trout moves from 0.58 m below it to 0.14 m below it; Needlefish moves from 0.42 m to 0.10 m below it. Both species use deterministic multi-frequency lateral motion and existing line-burst events for irregular direction changes.
- During Surface & Landing, the fish stays near the sampled water surface, struggles laterally, and the existing Sea Trout breach and gill-wash poses remain active. Surface splashes now use the fish's current X/Z position and sampled water height.
- The water-to-deck transition is a cubic Bezier path. Its control points pass over the stern rail and then turn inboard to each boat's configured deck display point. A short deterministic roll/yaw/pitch wriggle fades during the lift. Catch Presentation continues at the deck point with a small decaying motion.
- The fish line is now a 1.2 mm radius (2.4 mm diameter) warm amber filament, below the 2 mm rod-tip radius. It uses a fixed three-control-point curve; slack sag blends from 0.20 m to 0.018 m under tension. During a catch, its water-entry point is placed 72% of the way from the actual rod tip to the fish hook point and aligned to the sampled water surface, preventing the line from doubling back past the fish.
- Fight Camera focus shifts slightly aft during retrieval to keep the stern-water action in frame. It remains anchored to the active boat mount.

## Configuration and fixed behavior

### Resource-configured values

- `FishingFightProfile`: near-boat visibility progress, approach depths, species-specific lateral amplitude and surface bob, splash strengths/times, Sea Trout breach/gill-wash, lift timing, and airborne struggle.
- `FishingRodMountProfile`: approach start distance, surface-struggle distance, deck display position, rail-clearance arc, and Fight Camera framing. The current cargo boat and Nordic 28 both use 5.8 m / 2.7 m / 0.38 m for the approach start, surface point and landing arc; their deck positions remain hull-specific.
- Sea Trout has stronger near-surface lateral/splash motion and configured breach/gill-wash. Needlefish keeps its stronger narrow-body lateral movement, lighter splash, and no Sea Trout-style gill-wash.

### Algorithm constants

These remain in the shared visual controller/rig: smoothstep easing; deterministic phase offset derived from the animation seed; the two-frequency motion coefficients; the 72% water-entry fraction; per-stage line-tension defaults; Bezier control-point fractions (0.30 and 0.82); small lateral clamps; and the curve's tension-to-sag endpoints. They affect presentation only. No frame-time random sampling, new nodes per frame, mesh rebuild, or physical force was added.

## Files changed

- `scripts/fishing_rod_system.gd`
- `scripts/fishing_rod_rig.gd`
- `scripts/fishing_fight_profile.gd`
- `scripts/fishing_rod_mount_profile.gd`
- `resources/fishing/fight_profiles/sea_trout.tres`
- `resources/fishing/fight_profiles/needlefish.tres`
- `resources/fishing/rod_mounts/starter_cargo_boat.tres`
- `resources/fishing/rod_mounts/nordic28.tres`
- `tests/test_fishing_p3_1.gd`

## Visual verification boundary

Headless tests validate path positions, the sampled water relation, splash attachment, line topology/material/radius, fish length, and final deck targets. Forward+ visual inspection is recorded separately in `TEST_RESULTS.md`; automated geometry checks cannot establish that a line or fish reads naturally from the live camera.
