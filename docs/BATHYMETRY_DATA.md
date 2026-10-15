# Øresund bathymetry and depth chart

## Intended source and actual acquisition status

- **Dataset:** EMODnet Digital Bathymetry (DTM 2024), ERDDAP dataset `bathymetry_dtm_2024`.
- **Public endpoint:** `https://erddap.emodnet.eu/erddap/griddap/bathymetry_dtm_2024.nc` (HTTPS, no account or API key).
- **Product DOI:** [10.12770/cf51df64-56f9-4a99-b1aa-36b8d7b743a1](https://doi.org/10.12770/cf51df64-56f9-4a99-b1aa-36b8d7b743a1).
- **Region requested:** the existing Task 7 WGS84 crop, 12.25°–13.22° E and 55.35°–56.10° N. `fetch_bathymetry.py` checks the processed OSM crop against `resources/oresund_georeference.tres` before constructing its ERDDAP constraints.
- **Nominal source resolution:** 0.001041667° per axis (1/16 arc-minute). Near 55.7° N this is about 116 m north-south and 65 m east-west; cell size is not uniform in metres.
- **Vertical reference:** Lowest Astronomical Tide (LAT). ERDDAP `elevation` is in metres relative to LAT: negative below LAT, positive above LAT. The game grid stores positive depth as `-elevation` only where the source value is finite and below LAT.
- **Downloaded:** 2026-10-15 15:53:15 UTC. The probe and regional subset both completed successfully; the regional NetCDF returned HTTP 200 (`application/x-netcdf`), 6,067,096 bytes, SHA-256 `e48df714304f1045f3f023bd614c3b2624a9fb4fa4f1e5ad6516573d9b39950d`. The acquisition record is `assets/geodata/source/emodnet_bathymetry_download.json`.

The [ERDDAP dataset metadata](https://erddap.emodnet.eu/erddap/griddap/bathymetry_dtm_2024.html) identifies the grid spacing, variable, sign convention and LAT datum. It also states that the grid is not for navigation or safety at sea. [EMODnet's terms of use](https://emodnet.ec.europa.eu/en/terms-use-emodnet-online-services-data-and-data-products) say EMODnet-created products are generally EU-owned and CC BY 4.0 unless a product or source metadata says otherwise; the contributing originators and any restrictions should still be checked before redistributing downloaded source data. The project must not present this HUD as a safety instrument.

Recommended credit when the dataset is successfully acquired and shipped:

> EMODnet Bathymetry Consortium, EMODnet Digital Bathymetry (DTM 2024), DOI: 10.12770/cf51df64-56f9-4a99-b1aa-36b8d7b743a1. EMODnet data product, © European Union, CC BY 4.0. Verify originator metadata for any additional conditions.

Keep the coastline credit separate: `© OpenStreetMap contributors · ODbL-1.0`.

## Repeatable download and build

The online downloader first requests a small open-water probe. Only a valid NetCDF response enables the full subset request, which includes `elevation`, `interpolation_flag`, and `value_count`.

```sh
.venv/bin/pip install -r tools/requirements-bathymetry.txt
.venv/bin/python tools/terrain/fetch_bathymetry.py --probe-only
.venv/bin/python tools/terrain/fetch_bathymetry.py
.venv/bin/python tools/terrain/build_bathymetry.py
.venv/bin/python tools/terrain/validate_bathymetry.py
```

The regional source cache is `assets/geodata/source/emodnet_bathymetry_2024_oresund.nc`. The processor emits a little-endian grid with 0.1 m depth steps, an interpolation flag and a saturated value count per cell. NaN, positive land elevation and absent values use an invalid sentinel; runtime bilinear sampling returns invalid unless all four surrounding cells are ocean data. The processor extracts 2 m, 5 m, 10 m and 20 m contours only when four source cells are valid ocean cells, then stitches and simplifies the lines. It does not bridge missing data or land.

The Task 7 OSM coastlines and land triangles are also converted to `chart_features.json` and `land_mask.png`; this is shoreline support only and is not bathymetry. It can be rebuilt without pretending there is depth data:

```sh
.venv/bin/python tools/terrain/build_bathymetry.py --coastline-only
```

## Runtime behavior

`BathymetryManager` reads only the local processed cache and uses the existing `GeoReference` WGS84 ECEF-to-ENU transform (Godot X east, Y up, -Z north). Its world-position query ignores Y so wave height never changes chart depth. It returns `valid=false` for missing data, land, grid bounds, or an interpolation neighbourhood containing invalid cells; the HUD shows `-- m` in those cases.

`DepthChartHUD` is in the main scene at the lower left. The numeric depth is sampled every 0.5 s. Its north-up 128×92 chart raster is only rebuilt after the boat moves 45 m; coastline and cached contours are drawn as static polylines. The chart shows shallow-to-deep blue-green bands, OSM land, 2/5/10/20 m isobaths, a centre heading marker, distance rings and a 500 m scale. A missing bathymetry cache is visibly hatched/unknown, never painted as deep water.

## Bathymetry-driven sea color

The existing depth grid is also baked into `depth_texture.rg8`; the offline build reads the cached NetCDF and OSM mask and does not download data. It resamples the EMODnet depth values onto the existing 30 m OSM land-mask grid using the same local ECEF/ENU transform as `GeoReference`. The resulting 2,052×2,788 raw RG8 texture is 11,441,952 bytes before GPU upload. R stores depth from 0–64 m at about 0.25 m per code step; G stores water validity. Invalid texels remain invalid, and a one-cell edge fill copies a neighboring water depth only into R so bilinear filtering does not pull shallow samples toward 64 m. G remains zero there and gates the tint.

At runtime, `BathymetryManager` reads that raw file once, creates an `ImageTexture`, and assigns it to the existing shared sea `ShaderMaterial`. The shader maps world east from X and north from -Z through the texture's ENU bounds; V is flipped so the north edge corresponds to image row zero. This uses absolute world coordinates, so the camera-following ocean mesh does not drag the color pattern with it. Wave Y motion is not used. Outside the texture bounds, over OSM land, and in areas with no valid DTM data, the shader keeps the current weather-driven sea color.

The shader samples the RG texture once per water fragment with linear filtering. It blends shallow, middle, blue, then current weather/Fresnel color at 2, 5, 10, and 20 m using `smoothstep`; default `depth_color_strength` is 0.80. This was increased after visual feedback found the initial 0.46 mix too subtle. The validity fade uses `valid_coverage_min=0.20` and `valid_coverage_max=0.80`, so partial nearshore data remains visible while zero-coverage locations stay unchanged. The blend changes only `surface_color.rgb`, leaving waves, normals, roughness, reflection, foam, transparency, and depth writing alone. Press **B** while playing to toggle the tint for visual/performance comparison; the current state and colors are editable on the shared sea material.

`validate_bathymetry.py` compares the GPU texture's filtered samples with BathymetryManager's CPU grid samples at the five check locations. The 0.74 m Malmö approach sample is retained as partial edge coverage and fades its tint according to the texture validity channel rather than becoming a false full-valid cell.

| Check point | CPU depth | GPU texture depth | Valid coverage / tint weight | Result |
| --- | ---: | ---: | ---: | --- |
| Malmö spawn | 2.243 m | 2.235 m | 1.00 / 1.00 | Full shallow tint; difference 0.008 m |
| Øresund open water | 5.525 m | 5.522 m | 1.00 / 1.00 | Mid-depth tint; difference 0.003 m |
| Malmö coastal approach | 0.737 m | 0.753 m | 0.64 / 0.47 | Partial nearshore tint; difference 0.016 m |
| Copenhagen test point | invalid | 64 m sentinel | 0 / 0 | Original sea color |
| Outside source region | invalid | outside texture | 0 / 0 | Original sea color |

The new shader ran in a Godot 4.7.2 graphical launch using Forward+ / Metal 3.2 on an Apple M2 Pro; the process log showed no shader error. The matching windowed visual check after this change and controlled on/off FPS/frame-time comparison were not captured, so visual tuning and performance impact still need review. The earlier screenshot's instantaneous FPS is not used as an A/B result.

## Current data and validation record

- The open-water probe and full regional request succeeded with HTTP 200. The request included `elevation`, `interpolation_flag`, and `value_count`; the downloaded bytes, hash, URL, and UTC timestamp are retained in `assets/geodata/source/emodnet_bathymetry_download.json`.
- The decoded grid contains 721 rows × 932 columns (0.0625 arc-minute spacing), 270,230 valid water cells, and 401,742 invalid or non-water cells. Valid source depths range from approximately 0 m to 52.96 m. The processed grid is 2,687,888 bytes and includes 2 m, 5 m, 10 m, and 20 m contours where supported by valid ocean cells.
- Five real-data checks are recorded in [`BATHYMETRY_SAMPLE_CHECKS.json`](BATHYMETRY_SAMPLE_CHECKS.json). The current Malmö start point (55.60587° N, 12.96300° E; Godot X/Z 13,424.56/10,459.39 m) samples **2.24 m**. Open Øresund at 55.70000° N, 12.75000° E samples **5.525 m** (interpolated). The Malmö coastal approach at 55.60587° N, 12.97000° E samples **0.74 m**. The Copenhagen-side test point 36 m from the OSM shore is invalid because its bilinear neighborhood contains land/no-data; outside the source bounds also returns invalid.
- The depth chart and the sea surface both use the downloaded depth grid. The ocean tint is a restrained base-color blend; the existing weather albedo, reflections, waves, and foam remain active. The in-game visual balance still needs review against a fresh screenshot.
- A Godot 4.7.2 graphical launch reported Forward+ / Metal 3.2 on an Apple M2 Pro. The supplied screenshot confirms the HUD and live 2.2 m depth readout render in game. No controlled FPS or frame-time comparison has been recorded. The device reported for this run is not an M4.
- This dataset combines multiple source products and has roughly 65–116 m cells here. The nearshore grid may not align exactly with the OSM coastline; current bilinear sampling deliberately reports invalid at land/no-data edges instead of extrapolating across them. The HUD is for game feedback only, not navigation.
