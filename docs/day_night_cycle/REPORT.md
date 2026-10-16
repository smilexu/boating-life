# Day and night cycle

This report documents Task 3's solar calculation and runtime ownership. The
automated scene/math checks and timestamped sun positions are written to
`test_report.json` by `tests/test_day_night_cycle.gd`.

Run the regression checks with:

```sh
godot --headless --path . --script res://tests/test_day_night_cycle.gd
```

## Verified solar samples

At the GeoReference origin (55.7000° N, 12.7500° E), the calculation produces:

| Date | Time (Stockholm) | Elevation | Azimuth from true north |
|---|---:|---:|---:|
| 2026-07-15 | 05:00 | +0.87° | 50.64° |
| 2026-07-15 | 08:00 | +24.08° | 86.37° |
| 2026-07-15 | 12:00 | +53.23° | 150.15° |
| 2026-07-15 | 17:00 | +36.53° | 254.23° |
| 2026-07-15 | 20:00 | +11.63° | 291.44° |
| 2026-07-15 | 23:00 | -7.58° | 328.63° |
| 2026-07-15 | 02:00 | -11.98° | 10.74° |
| 2026-12-15 | 05:00 | -27.91° | 90.84° |
| 2026-12-15 | 08:00 | -4.27° | 126.29° |
| 2026-12-15 | 12:00 | +11.08° | 179.05° |
| 2026-12-15 | 17:00 | -10.53° | 243.93° |
| 2026-12-15 | 20:00 | -35.21° | 280.22° |
| 2026-12-15 | 23:00 | -55.44° | 333.36° |
| 2026-12-15 | 02:00 | -51.10° | 45.26° |

The simple hourly-above-horizon check counts 17 summer hours and 7 winter hours.
At 12:00 in July the sun is still southeast (150°); the local solar noon is
after 12:00 CEST because the region lies west of the CEST meridian.

## Captures

The images use one fixed third-person camera, a frozen ocean phase, Clear weather,
High quality and 1920×1080 on Godot 4.7.2 / Forward+ / Apple M2 Pro Metal. VSync
was disabled only for the capture run. The FPS label remains the live game
counter and was not used as a performance measurement.

| Summer | Winter |
|---|---|
| [05:00](screenshots/summer_0500.png) · [08:00](screenshots/summer_0800.png) · [12:00](screenshots/summer_1200.png) · [17:00](screenshots/summer_1700.png) · [20:00](screenshots/summer_2000.png) · [23:00](screenshots/summer_2300.png) · [02:00](screenshots/summer_0200.png) | [05:00](screenshots/winter_0500.png) · [08:00](screenshots/winter_0800.png) · [12:00](screenshots/winter_1200.png) · [17:00](screenshots/winter_1700.png) · [20:00](screenshots/winter_2000.png) · [23:00](screenshots/winter_2300.png) · [02:00](screenshots/winter_0200.png) |

Capture metadata is in `screenshots/capture_report.json`. These are actual
renderer captures; the automated verification does not assert artistic quality.

## Capture the production view

Run this with the normal graphical renderer (not `--headless`) to save a set of
summer and winter sky views under `docs/day_night_cycle/screenshots/`:

```sh
godot --path . --script res://tools/capture_day_night_cycle.gd
```

The script pauses WorldTimeManager, freezes the existing ocean's animation phase
for comparison, fixes the existing third-person camera, and restores the saved
world-time snapshot before exit. It does not save the temporary test date.

## Algorithm and coordinate convention

`SolarPositionCalculator` uses NOAA's fractional-year approximation for solar
declination and equation of time. Solar azimuth is clockwise from true north.
The map's `GeoReference` sets X east, Y up and -Z north; the calculated solar
vector is converted to that frame before it is sent to both the sky shader and
the directional light. The ocean continues to receive its sun through the same
DirectionalLight, so the sky disk, clouds, direct light and ocean specular all
share one direction.

The accelerated day cycle always contains 24 distinct hours. On the spring and
autumn Stockholm DST transition dates, the post-transition UTC offset is applied
for the whole simulated cycle. This small calendar-day approximation avoids a
one-hour sun jump on a day that would otherwise have a skipped or repeated local
civil hour. Real calendar dates still use WorldTimeManager's UTC based Stockholm
conversion. This controller is a presentation approximation, not a navigation
or astronomical ephemeris tool.

Algorithm reference: [NOAA General Solar Position Calculations](https://gml.noaa.gov/grad/solcalc/solareqns.PDF).

## Runtime ownership and limitations

`WeatherController` now owns only weather baselines, cloud settings and water
weather parameters. `QualityManager` changes render quality and shadow settings.
`DayNightVisualController` is the only runtime writer for solar direction,
directional-light energy, sky palette/sun disk, ambient light and fog color.
The day-night blend is intentionally a first pass; there is no moon, star field,
night weather, or high-accuracy atmospheric refraction. Some dark-hours screenshots
show a silhouette-level boat, which is the intended minimum readability for this
stage.

On shutdown after graphical capture, Godot printed renderer RID-leak warnings for
compositor/compute resources. It exited successfully and all screenshots were
written; these warnings were not associated with GDScript errors during capture.
