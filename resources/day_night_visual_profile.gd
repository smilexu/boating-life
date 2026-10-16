extends Resource
class_name DayNightVisualProfile

## Art-directed response curves driven by solar elevation, not civil clock time.
## Every curve uses x=0..1 mapped through solar_elevation_min/max_degrees.

@export_group("Curve input")
@export_range(-60.0, -6.0, 0.5) var solar_elevation_min_degrees := -24.0
@export_range(24.0, 75.0, 0.5) var solar_elevation_max_degrees := 60.0

@export_group("Solar response curves")
@export var direct_light_curve: Curve
@export var sun_disk_curve: Curve
@export var ambient_daylight_curve: Curve
@export var sky_top_daylight_curve: Curve
@export var sky_horizon_daylight_curve: Curve
@export var blue_hour_curve: Curve
@export var sun_warmth_curve: Curve
@export var horizon_warmth_curve: Curve
@export var cloud_daylight_curve: Curve

@export_group("Night palette")
@export var night_ambient_color := Color(0.025, 0.034, 0.063, 1.0)
@export_range(0.05, 0.8, 0.01) var night_ambient_energy := 0.21
@export var night_sky_top_color := Color(0.0015, 0.0019, 0.0070, 1.0)
@export var night_sky_horizon_color := Color(0.0048, 0.0075, 0.0180, 1.0)
@export var night_ground_bottom_color := Color(0.0013, 0.0018, 0.0060, 1.0)
@export var night_ground_haze_color := Color(0.0060, 0.0085, 0.0190, 1.0)
@export var night_fog_color := Color(0.0060, 0.0085, 0.0170, 1.0)

@export_group("Blue hour palette")
@export var blue_hour_sky_top_color := Color(0.010, 0.018, 0.038, 1.0)
@export var blue_hour_horizon_color := Color(0.045, 0.065, 0.100, 1.0)
@export var blue_hour_ground_haze_color := Color(0.038, 0.055, 0.086, 1.0)
@export var blue_hour_fog_color := Color(0.025, 0.038, 0.066, 1.0)
@export var blue_hour_ambient_color := Color(0.025, 0.038, 0.066, 1.0)
@export var pre_dawn_sky_top_color := Color(0.016, 0.018, 0.038, 1.0)
@export var pre_dawn_horizon_color := Color(0.056, 0.064, 0.096, 1.0)
@export var pre_dawn_ground_haze_color := Color(0.052, 0.060, 0.088, 1.0)
@export_range(0.2, 1.2, 0.01) var night_sky_gradient_power := 0.34

@export_group("Twilight palette")
@export var twilight_color := Color(0.96, 0.46, 0.32, 1.0)
@export_range(0.0, 0.75, 0.01) var horizon_twilight_mix := 0.62
@export_range(0.0, 0.25, 0.01) var zenith_twilight_mix := 0.02
@export_range(-18.0, 0.0, 0.5) var zenith_night_falloff_start_degrees := -4.0
@export_range(-6.0, 12.0, 0.5) var zenith_night_falloff_end_degrees := 2.0
@export_range(0.0, 0.3, 0.01) var fog_twilight_mix := 0.12
@export_range(0.0, 0.4, 0.01) var cloud_twilight_mix := 0.14

@export_group("Night atmosphere")
@export_range(0.0, 1.0, 0.01) var night_fog_density_multiplier := 0.72
@export_range(0.0, 1.0, 0.01) var night_fog_aerial_perspective := 0.05
@export_range(0.0, 1.0, 0.01) var night_fog_sun_scatter := 0.01
@export var night_cloud_ambient_color := Color(0.48, 0.57, 0.74, 1.0)
@export var night_cloud_ambient_tint := Color(0.52, 0.60, 0.76, 1.0)
@export var night_cloud_fill_color := Color(0.42, 0.53, 0.72, 1.0)
@export_range(0.0, 0.8, 0.01) var night_cloud_fill_max_energy := 0.45
@export_range(0.25, 1.0, 0.01) var partly_cloudy_fill_scale := 0.90
@export_range(0.25, 1.0, 0.01) var overcast_cloud_fill_scale := 0.58

@export_group("Sun disk art direction")
@export_range(1.0, 2.0, 0.05) var sun_angular_radius_multiplier := 1.5
@export_range(1.0, 2.0, 0.05) var sun_core_radiance_multiplier := 1.3
@export_range(0.5, 1.5, 0.05) var sun_halo_strength_multiplier := 1.0

@export_group("Moon and star rendering")
@export_range(0.1, 1.5, 0.01) var moon_angular_radius_degrees := 1.235
@export_range(0.005, 0.15, 0.005) var moon_edge_softness_degrees := 0.035
@export_range(0.1, 4.0, 0.05) var moon_core_radiance := 2.58
@export_range(0.0, 0.5, 0.01) var moon_halo_strength := 0.16
@export_range(0.5, 6.0, 0.1) var moon_halo_radius_degrees := 3.2
@export_range(0.0, 0.2, 0.005) var moon_light_max_energy := 0.105
@export_range(0.0, 1.0, 0.01) var moon_light_specular_multiplier := 0.20
@export var moon_disk_color := Color(0.80, 0.88, 1.0, 1.0)
@export var moonlight_color := Color(0.60, 0.72, 0.96, 1.0)
@export_range(0.0, 0.5, 0.01) var daytime_moon_visibility := 0.16
@export_range(0.0, 1.0, 0.01) var overcast_moon_visibility := 0.18
@export_range(0.0, 2.0, 0.01) var stars_brightness := 1.75
@export_range(0.0, 1.0, 0.01) var full_moon_star_suppression := 0.42
@export_range(-24.0, -6.0, 0.5) var stars_full_visibility_solar_elevation := -10.0
@export_range(-12.0, 0.0, 0.5) var stars_fade_solar_elevation := -2.5
@export var star_color := Color(0.84, 0.90, 1.0, 1.0)
@export var moonlit_cloud_ambient_color := Color(0.66, 0.76, 0.92, 1.0)
@export var moonlit_cloud_ambient_tint := Color(0.66, 0.76, 0.91, 1.0)
@export_range(0.0, 1.2, 0.01) var boat_night_fill_energy := 0.55
@export_range(0.0, 2.5, 0.01) var boat_moon_fill_bonus := 2.0
@export_range(8.0, 40.0, 0.5) var boat_night_fill_range := 32.0
@export var boat_night_fill_color := Color(0.60, 0.72, 0.96, 1.0)
@export var boat_night_fill_position := Vector3(0.0, 3.0, -1.5)

@export_group("Night water")
@export var night_water_emission_color := Color(0.010, 0.024, 0.052, 1.0)
@export_range(0.0, 1.0, 0.01) var night_water_specular_scale := 0.68
@export_range(0.05, 0.5, 0.01) var night_water_roughness := 0.20


func sample_response(curve: Curve, solar_elevation_degrees: float, fallback: float) -> float:
	if curve == null:
		return fallback
	var span := maxf(solar_elevation_max_degrees - solar_elevation_min_degrees, 0.001)
	var normalized_elevation := clampf((solar_elevation_degrees - solar_elevation_min_degrees) / span, 0.0, 1.0)
	return clampf(curve.sample_baked(normalized_elevation), 0.0, 1.0)
