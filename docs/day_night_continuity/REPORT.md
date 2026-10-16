# 24-hour sky, ocean, and lighting continuity

Date: 2026-10-16

Engine: Godot 4.7.2 stable, Forward+ / Metal 3.2

Capture and performance device: Apple M2 Pro (Apple8)
Capture setup: 1920×1080, High quality, Clear weather, VSync disabled, production boat camera, water animation phase frozen for captures.

## Result

The main scene now composes the NOAA solar position with the active weather baseline through `DayNightVisualController`. Inspector-editable elevation curves drive the sun, sky gradient, ambient fill, fog, and Sunshine Clouds 2 lighting. Solar elevation, rather than fixed clock hours, determines the dawn, daylight, golden-hour, blue-hour, and night response.

The approved July noon sky and water palettes remain unchanged. The ocean shader, Gerstner wave motion, WaveSampler, buoyancy, boat controller, and cloud plugin shader were not modified. No render pass, light, cloud raymarch step, or ocean geometry was added.

## Parameter changes

All curve X positions are solar elevation in degrees remapped to 0–1 using the profile range −24° to +60°. Curves are exposed on `DayNightVisualProfile` for Inspector editing.

| Response at solar elevation | Previous | Current |
| --- | ---: | ---: |
| Ambient daylight at −4° | 0.80 | 0.62 |
| Ambient daylight at 0° | 0.96 | 0.86 |
| Cloud daylight at −4° | 0.81 | 0.65 |
| Cloud daylight at 0° | 0.97 | 0.88 |
| Sun warmth at −4° | 0.50 | 0.56 |
| Sun warmth at 0° | 0.82 | 0.85 |
| Sun warmth at +6° | 0.32 | 0.50 |
| Twilight tint color | (0.92, 0.47, 0.34) | (0.96, 0.46, 0.32) |
| Horizon twilight mix | 0.40 | 0.52 |

Sky top/horizon daylight curves, blue-hour curve, water palette, direct-light curve, and disk curve remain as previously authored. The direct sun fades to zero by −6°; the disk fades out below the horizon band. This leaves a brief natural low-sun transition rather than switching off at one clock time.

## Ownership and weather behavior

- `WorldTimeManager` provides the calendar date and day-cycle phase.
- `WeatherController` owns weather choice, weather interpolation, cloud coverage, wave strength, and water color baselines. Its transitions continue to use real frame time.
- `DayNightVisualController` is the only runtime writer of final sun direction/energy, sky colors, ambient/fog values, and cloud ambient/tint. The sky, DirectionalLight3D, ocean reflections, and tracked Sunshine Clouds 2 light use the same computed sun direction.
- `QualityManager` continues to change rendering-cost settings only. Tests confirmed High, Medium, and Low preserve the same noon and twilight lighting values and water palette; cloud sampling quality still varies by tier as intended.

Cloud coverage and weather are preserved. Cloud ambient/tint are now composed with solar elevation so clouds darken at night and receive a restrained warm tint at low sun. Sunshine Clouds 2 source and raymarch implementation were not changed.

## Screenshot set

Before and after captures use the same production camera, 2026 dates, High quality, Clear weather, 1920×1080, paused world time, and frozen water shader phase. All 16 captures in each set saved with `save_error=0`.

| Phase | Summer before | Summer after | Winter before | Winter after |
| --- | --- | --- | --- | --- |
| Pre-dawn | [PNG](before/summer_pre_dawn_0200.png) | [PNG](after/summer_pre_dawn_0200.png) | [PNG](before/winter_pre_dawn_0657.png) | [PNG](after/winter_pre_dawn_0657.png) |
| Sunrise | [PNG](before/summer_sunrise_0448.png) | [PNG](after/summer_sunrise_0448.png) | [PNG](before/winter_sunrise_0835.png) | [PNG](after/winter_sunrise_0835.png) |
| Noon | [PNG](before/summer_noon_1315.png) | [PNG](after/summer_noon_1315.png) | [PNG](before/winter_noon_1204.png) | [PNG](after/winter_noon_1204.png) |
| Afternoon | [PNG](before/summer_afternoon_1714.png) | [PNG](after/summer_afternoon_1714.png) | [PNG](before/winter_afternoon_1407.png) | [PNG](after/winter_afternoon_1407.png) |
| Golden hour | [PNG](before/summer_golden_hour_2037.png) | [PNG](after/summer_golden_hour_2037.png) | [PNG](before/winter_golden_hour_1437.png) | [PNG](after/winter_golden_hour_1437.png) |
| Sunset | [PNG](before/summer_sunset_2142.png) | [PNG](after/summer_sunset_2142.png) | [PNG](before/winter_sunset_1534.png) | [PNG](after/winter_sunset_1534.png) |
| Blue hour | [PNG](before/summer_blue_hour_2253.png) | [PNG](after/summer_blue_hour_2253.png) | [PNG](before/winter_blue_hour_1632.png) | [PNG](after/winter_blue_hour_1632.png) |
| Night | [PNG](before/summer_deep_night_0115.png) | [PNG](after/summer_deep_night_0115.png) | [PNG](before/winter_deep_night_2359.png) | [PNG](after/winter_deep_night_2359.png) |

The summer night sample is the local solar minimum at −12.57°: Malmö does not reach astronomical night (−18°) on July 15. Winter reaches −57.53° at its night sample. This is a real seasonal limitation, not a missing capture.

Weather regression captures, at the same summer low-sun state unless noted:

- [PartlyCloudy golden hour, 20:37](after/weather_regressions/summer_partly_cloudy_golden_hour.png)
- [Overcast golden hour, 20:37](after/weather_regressions/summer_overcast_golden_hour.png)
- [Overcast blue hour, 22:53](after/weather_regressions/summer_overcast_blue_hour.png)

The after set shows the intended darker blue transition after sunset and a reduced late-night ambient level, while keeping the ship readable. Clear July noon remains visually aligned with the prior baseline. The brief low-sun transition still carries some daylight and specular reflection near the geometric horizon; those values fade out as elevation falls.

## Automated checks

- `godot --headless --path . --script res://tests/test_day_night_cycle.gd`: **119 checks passed**, including July/December solar samples, day lengths, curve continuity, immediate F3 time jumps, no direct sun in established blue hour/night, real-time weather interpolation at accelerated day-cycle time, High/Medium/Low visual-input stability, and a manual-acceleration/turn/autopilot plus shared-WaveSampler smoke check.
- `godot --headless --path . --script res://tests/test_world_time_manager.gd`: **58 checks passed**.
- `godot --headless --path . --script res://tests/test_world_time_admin_controls.gd`: **22 checks passed**.
- Graphical screenshot capture ran on Godot 4.7.2 Forward+/Metal. Seasonal and weather screenshots saved successfully.
- `git diff --check`: passed.
- `godot --headless --path . --quit` loaded the scene and bathymetry cache, but this sandbox could not write Godot's `user://logs` or autosave the user time state at process exit. The graphical captures and scripted scene tests completed; the failure was limited to user-data writes in this environment.

## Performance comparison

Same 1920×1080 High Clear scene, M2 Pro, VSync disabled, unlimited FPS, 240 measured frames per case. GPU time is not exposed by the Godot runtime monitors used by this benchmark. Each before/after case was measured once, so small differences should be treated as run-to-run variance.

| Case | Before FPS / avg ms / P95 ms | After FPS / avg ms / P95 ms | Draw calls before → after |
| --- | --- | --- | ---: |
| Summer noon | 93.03 / 10.75 / 20.76 | 88.39 / 11.31 / 22.83 | 147 → 147 |
| Summer sunset | 96.88 / 10.32 / 21.96 | 95.34 / 10.49 / 21.61 | 146 → 146 |
| Winter noon | 99.14 / 10.09 / 17.09 | 97.14 / 10.29 / 18.99 | 146 → 146 |
| Winter night | 86.45 / 11.57 / 23.73 | 97.33 / 10.27 / 16.41 | 146 → 146 |
| Four-case mean | 93.88 / 10.68 / 20.88 | 94.55 / 10.59 / 19.96 | 146 avg → 146 avg |

The aggregate run did not show a measurable average regression or draw-call increase. The noon single-run result is lower by about 5 FPS, while the other cases are close or faster; repeat runs would be needed to attribute that difference. No extra render pass or cloud sampling was introduced.

Raw data: [before](performance_before.json), [after](performance_after.json), [solar and visual tests](test_report.json), [before captures](before/capture_report.json), [after captures](after/capture_report.json).

## Known limits

- No moon, stars, or moonlight were added, per scope. Winter night uses low ambient fill, so the ship hull remains dark by design.
- Summer Malmö does not reach astronomical night in July; the darkest July image is nautical twilight.
- Lighting and color are continuous curves but remain an art-directed approximation. The sky shader has a global horizon palette and does not spatially localize twilight color around the sun azimuth.
- GPU render time was unavailable. The local headless process could not write its `user://` log/autosave files, though the graphical run and scene tests succeeded.
