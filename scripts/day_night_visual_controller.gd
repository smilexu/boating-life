extends Node
class_name DayNightVisualController

## Composes the world clock's astronomical sun position with the current
## weather baseline. This is the only runtime owner of solar direction,
## directional sunlight, sky palette and environment ambient/fog values.

const SolarPositionScript := preload("res://scripts/solar_position.gd")
const MoonPositionScript := preload("res://scripts/moon_position.gd")

@export_node_path("WorldEnvironment") var world_environment_path := NodePath("../WorldEnvironment")
@export_node_path("DirectionalLight3D") var sunlight_path := NodePath("../Sunlight")
@export_node_path("DirectionalLight3D") var moonlight_path := NodePath("../Moonlight")
@export_node_path("DirectionalLight3D") var night_cloud_fill_path := NodePath("../NightCloudFill")
@export_node_path("OmniLight3D") var boat_sky_fill_path := NodePath("../PlayerBoat/MotionRoot/VisualRoot/BoatSkyFill")
@export_node_path("Node") var weather_controller_path := NodePath("../WeatherController")
@export_node_path("SunshineCloudsDriverGD") var sunshine_clouds_driver_path := NodePath("../SunshineCloudsDriverGD")
@export var georeference: GeoReference
@export var visual_profile: DayNightVisualProfile

var _world_time_manager: Node
var _weather_controller: WeatherController
var _world_environment: WorldEnvironment
var _environment: Environment
var _sunlight: DirectionalLight3D
var _moonlight: DirectionalLight3D
var _night_cloud_fill: DirectionalLight3D
var _boat_sky_fill: OmniLight3D
var _boat_fill_day_energy := 0.0
var _boat_fill_day_color := Color.WHITE
var _boat_fill_day_range := 8.0
var _boat_fill_day_position := Vector3.ZERO
var _water_material: ShaderMaterial
var _sky_material: ShaderMaterial
var _day_sky_gradient_power := 0.72
var _sunshine_clouds: SunshineCloudsGD
var _solar_state: Dictionary = {}
var _moon_state: Dictionary = {}
var _last_calendar_key := ""
var _last_cycle_seconds := -1.0


func _ready() -> void:
	process_priority = 100
	_world_time_manager = get_node_or_null("/root/WorldTimeManager")
	_weather_controller = get_node_or_null(weather_controller_path) as WeatherController
	if _weather_controller != null:
		_water_material = _weather_controller.water_material
	_world_environment = get_node_or_null(world_environment_path) as WorldEnvironment
	_sunlight = get_node_or_null(sunlight_path) as DirectionalLight3D
	_moonlight = get_node_or_null(moonlight_path) as DirectionalLight3D
	_night_cloud_fill = get_node_or_null(night_cloud_fill_path) as DirectionalLight3D
	_boat_sky_fill = get_node_or_null(boat_sky_fill_path) as OmniLight3D
	if _boat_sky_fill != null:
		_boat_fill_day_energy = _boat_sky_fill.light_energy
		_boat_fill_day_color = _boat_sky_fill.light_color
		_boat_fill_day_range = _boat_sky_fill.omni_range
		_boat_fill_day_position = _boat_sky_fill.position
	var clouds_driver := get_node_or_null(sunshine_clouds_driver_path) as SunshineCloudsDriverGD
	if clouds_driver != null:
		_sunshine_clouds = clouds_driver.clouds_resource
	if _world_environment != null:
		_environment = _world_environment.environment
	if _environment != null and _environment.sky != null:
		_sky_material = _environment.sky.sky_material as ShaderMaterial
	if _sky_material != null:
		_day_sky_gradient_power = float(_sky_material.get_shader_parameter("sky_gradient_power"))
	if _world_time_manager == null or _weather_controller == null or _environment == null or _sky_material == null or _sunlight == null or _moonlight == null or _night_cloud_fill == null or georeference == null or visual_profile == null:
		push_error("DayNightVisualController needs WorldTimeManager, WeatherController, WorldEnvironment sky shader, Sunlight, Moonlight, NightCloudFill, GeoReference, and DayNightVisualProfile.")
		set_process(false)
		return
	_update_visuals(true)


func _process(_delta: float) -> void:
	_update_visuals(false)


func get_solar_state() -> Dictionary:
	return _solar_state.duplicate(true)


func get_moon_state() -> Dictionary:
	return _moon_state.duplicate(true)


func get_sun_elevation_degrees() -> float:
	return float(_solar_state.get("elevation_degrees", 0.0))


func get_sun_azimuth_degrees() -> float:
	return float(_solar_state.get("azimuth_degrees", 0.0))


func get_sun_direction() -> Vector3:
	return _solar_state.get("direction", Vector3.UP)


func get_daylight_strength() -> float:
	return float(_solar_state.get("daylight_strength", 0.0))


func get_blue_hour_strength() -> float:
	return float(_solar_state.get("blue_hour_strength", 0.0))


func get_twilight_warmth() -> float:
	return float(_solar_state.get("twilight_warmth", 0.0))


func _update_visuals(force: bool) -> void:
	var time_snapshot: Dictionary = _world_time_manager.call("get_authoritative_state")
	var date: Dictionary = time_snapshot.get("calendar_date", {})
	if date.is_empty():
		return
	var cycle_seconds := float(time_snapshot.get("cycle_seconds", 0.0))
	var calendar_key := "%04d-%02d-%02d" % [int(date["year"]), int(date["month"]), int(date["day"])]
	var time_changed := calendar_key != _last_calendar_key or absf(cycle_seconds - _last_cycle_seconds) > 0.001
	# Weather transitions are evaluated each frame, while the solar calculation
	# only needs to be recomputed when its calendar/time inputs change.
	if force or time_changed or _solar_state.is_empty():
		_solar_state = SolarPositionScript.calculate(
			date,
			cycle_seconds,
			georeference.origin_latitude_deg,
			georeference.origin_longitude_deg
		)
		_moon_state = MoonPositionScript.calculate(
			date,
			cycle_seconds,
			georeference.origin_latitude_deg,
			georeference.origin_longitude_deg
		)
		_last_calendar_key = calendar_key
		_last_cycle_seconds = cycle_seconds
	if _solar_state.is_empty():
		return
	_apply_composed_visuals(_weather_controller.get_day_night_visual_baseline())


func _apply_composed_visuals(weather: Dictionary) -> void:
	if weather.is_empty():
		return
	var elevation := float(_solar_state["elevation_degrees"])
	var direction: Vector3 = _solar_state["direction"]
	var direct_visibility := visual_profile.sample_response(visual_profile.direct_light_curve, elevation, 0.0)
	var sun_disk_visibility := visual_profile.sample_response(visual_profile.sun_disk_curve, elevation, 0.0)
	var ambient_daylight := visual_profile.sample_response(visual_profile.ambient_daylight_curve, elevation, 0.0)
	var nightness := 1.0 - ambient_daylight
	var sky_top_daylight := visual_profile.sample_response(visual_profile.sky_top_daylight_curve, elevation, 0.0)
	var sky_horizon_daylight := visual_profile.sample_response(visual_profile.sky_horizon_daylight_curve, elevation, 0.0)
	# Let the zenith settle into night before the low horizon loses its lingering
	# twilight. This only affects negative/low sun angles; the approved daytime
	# sky palette and noon curve remain unchanged.
	sky_top_daylight = minf(sky_top_daylight, smoothstep(
		visual_profile.zenith_night_falloff_start_degrees,
		visual_profile.zenith_night_falloff_end_degrees,
		elevation
	))
	var blue_hour := visual_profile.sample_response(visual_profile.blue_hour_curve, elevation, 0.0)
	var sun_warmth := visual_profile.sample_response(visual_profile.sun_warmth_curve, elevation, 0.0)
	var horizon_warmth := visual_profile.sample_response(visual_profile.horizon_warmth_curve, elevation, 0.0)
	var cloud_daylight := visual_profile.sample_response(visual_profile.cloud_daylight_curve, elevation, ambient_daylight)
	var moon_elevation := float(_moon_state.get("elevation_degrees", -90.0))
	var moon_direction: Vector3 = _moon_state.get("direction", Vector3.UP)
	var moon_rise_visibility := smoothstep(-1.5, 2.5, moon_elevation)
	var cloud_coverage := clampf(float(_weather_controller.call("get_cloud_coverage")), 0.0, 1.0)
	var weather_sky_visibility := lerpf(1.0, visual_profile.overcast_moon_visibility, smoothstep(0.45, 0.9, cloud_coverage))
	var night_factor := 1.0 - ambient_daylight
	var moon_illumination := float(_moon_state.get("illumination_fraction", 0.0))
	var moon_light_strength := (
		visual_profile.moon_light_max_energy
		* pow(moon_illumination, 1.55)
		* moon_rise_visibility
		* night_factor
		* weather_sky_visibility
	)
	var moon_disk_daylight_scale := lerpf(visual_profile.daytime_moon_visibility, 1.0, night_factor)
	var moon_disk_visibility := moon_rise_visibility * weather_sky_visibility * moon_disk_daylight_scale
	var star_night_visibility := 1.0 - smoothstep(visual_profile.stars_full_visibility_solar_elevation, visual_profile.stars_fade_solar_elevation, elevation)
	var star_cloud_visibility := 1.0 - cloud_coverage * 0.82
	var star_moon_visibility := 1.0 - visual_profile.full_moon_star_suppression * moon_illumination
	var star_strength := visual_profile.stars_brightness * star_night_visibility * star_cloud_visibility * star_moon_visibility
	var predawn_blend := blue_hour * smoothstep(0.05, 0.65, direction.x) * (1.0 - horizon_warmth * 0.75)
	var sunset_horizon_warmth := horizon_warmth * (visual_profile.horizon_twilight_mix + smoothstep(0.05, 0.65, -direction.x) * 0.16)

	var daylight_sun_color: Color = weather["sun_color"]
	var final_sun_color := daylight_sun_color.lerp(visual_profile.twilight_color, sun_warmth)
	_sunlight.light_color = final_sun_color
	_sunlight.light_energy = float(weather["sun_energy"]) * direct_visibility
	# Light rays travel opposite the vector from the map origin toward the sun.
	_sunlight.global_basis = Basis.looking_at(-direction, Vector3.UP)

	_sky_material.set_shader_parameter("sun_direction", direction)
	_sky_material.set_shader_parameter("sun_energy", float(weather["sun_energy"]) * sun_disk_visibility)
	_sky_material.set_shader_parameter("sun_disk_color", _color_to_vector3(Color(weather["sun_disk_color"]).lerp(visual_profile.twilight_color, sun_warmth)))
	_sky_material.set_shader_parameter("sun_disk_radius_degrees", float(weather["sun_disk_radius"]) * visual_profile.sun_angular_radius_multiplier)
	_sky_material.set_shader_parameter("sun_edge_softness_degrees", float(weather["sun_disk_edge"]))
	_sky_material.set_shader_parameter("sun_core_radiance", float(weather["sun_core_radiance"]) * visual_profile.sun_core_radiance_multiplier)
	_sky_material.set_shader_parameter("sun_halo_strength", float(weather["sun_halo_strength"]) * visual_profile.sun_halo_strength_multiplier * sun_disk_visibility)
	_sky_material.set_shader_parameter("sun_halo_radius_degrees", float(weather["sun_halo_radius"]))
	_sky_material.set_shader_parameter("moon_direction", moon_direction)
	_sky_material.set_shader_parameter("moon_visibility", moon_disk_visibility)
	_sky_material.set_shader_parameter("moon_disk_color", _color_to_vector3(visual_profile.moon_disk_color))
	_sky_material.set_shader_parameter("moon_angular_radius_degrees", visual_profile.moon_angular_radius_degrees)
	_sky_material.set_shader_parameter("moon_edge_softness_degrees", visual_profile.moon_edge_softness_degrees)
	_sky_material.set_shader_parameter("moon_core_radiance", visual_profile.moon_core_radiance)
	_sky_material.set_shader_parameter("moon_halo_strength", visual_profile.moon_halo_strength)
	_sky_material.set_shader_parameter("moon_halo_radius_degrees", visual_profile.moon_halo_radius_degrees)
	_sky_material.set_shader_parameter("moon_illumination_fraction", moon_illumination)
	_sky_material.set_shader_parameter("star_strength", star_strength)
	_sky_material.set_shader_parameter("star_color", _color_to_vector3(visual_profile.star_color))

	var day_top: Color = weather["sky_top"]
	var day_horizon: Color = weather["sky_horizon"]
	var day_haze: Color = weather["haze"]
	var sky_top := visual_profile.night_sky_top_color.lerp(day_top, sky_top_daylight)
	sky_top = sky_top.lerp(visual_profile.blue_hour_sky_top_color, blue_hour * 0.28)
	sky_top = sky_top.lerp(visual_profile.pre_dawn_sky_top_color, predawn_blend * 0.55)
	sky_top = sky_top.lerp(visual_profile.twilight_color, horizon_warmth * visual_profile.zenith_twilight_mix)
	var sky_horizon := visual_profile.night_sky_horizon_color.lerp(day_horizon, sky_horizon_daylight)
	sky_horizon = sky_horizon.lerp(visual_profile.blue_hour_horizon_color, blue_hour * 0.58)
	sky_horizon = sky_horizon.lerp(visual_profile.pre_dawn_horizon_color, predawn_blend * 0.48)
	sky_horizon = sky_horizon.lerp(visual_profile.twilight_color, sunset_horizon_warmth)
	var ground_haze := visual_profile.night_ground_haze_color.lerp(day_haze, sky_horizon_daylight)
	ground_haze = ground_haze.lerp(visual_profile.blue_hour_ground_haze_color, blue_hour * 0.48)
	ground_haze = ground_haze.lerp(visual_profile.pre_dawn_ground_haze_color, predawn_blend * 0.46)
	ground_haze = ground_haze.lerp(visual_profile.twilight_color, sunset_horizon_warmth * 0.82)
	var ground_bottom: Color = Color(weather.get("ground_bottom", _sky_material.get_shader_parameter("ground_bottom_color")))
	ground_bottom = visual_profile.night_ground_bottom_color.lerp(ground_bottom, lerpf(sky_top_daylight, sky_horizon_daylight, 0.35))
	_sky_material.set_shader_parameter("sky_gradient_power", lerpf(_day_sky_gradient_power, visual_profile.night_sky_gradient_power, nightness))
	_sky_material.set_shader_parameter("sky_top_color", _color_to_vector3(sky_top))
	_sky_material.set_shader_parameter("sky_horizon_color", _color_to_vector3(sky_horizon))
	_sky_material.set_shader_parameter("ground_bottom_color", _color_to_vector3(ground_bottom))
	_sky_material.set_shader_parameter("ground_horizon_color", _color_to_vector3(ground_haze))

	var day_ambient_color: Color = weather["ambient_color"]
	var ambient_color := visual_profile.night_ambient_color.lerp(day_ambient_color, ambient_daylight)
	ambient_color = ambient_color.lerp(visual_profile.blue_hour_ambient_color, blue_hour * 0.30)
	ambient_color = ambient_color.lerp(visual_profile.twilight_color, horizon_warmth * 0.08)
	ambient_color = ambient_color.lerp(visual_profile.moonlight_color, moon_light_strength * 0.65)
	_environment.ambient_light_color = ambient_color
	_environment.ambient_light_energy = lerpf(visual_profile.night_ambient_energy, float(weather["ambient_energy"]), ambient_daylight) + moon_light_strength * 0.18
	if _water_material != null:
		_water_material.set_shader_parameter("night_visual_weight", nightness)
		_water_material.set_shader_parameter("night_surface_lift", _color_to_vector3(visual_profile.night_water_emission_color))
		_water_material.set_shader_parameter("night_specular_scale", visual_profile.night_water_specular_scale)
		_water_material.set_shader_parameter("night_roughness_target", visual_profile.night_water_roughness)
	var day_fog_color: Color = weather["fog_color"]
	var fog_color := visual_profile.night_fog_color.lerp(day_fog_color, sky_horizon_daylight)
	fog_color = fog_color.lerp(visual_profile.blue_hour_fog_color, blue_hour * 0.45)
	fog_color = fog_color.lerp(visual_profile.twilight_color, horizon_warmth * visual_profile.fog_twilight_mix)
	_environment.fog_light_color = fog_color
	_environment.fog_density = float(weather["fog_density"]) * lerpf(visual_profile.night_fog_density_multiplier, 1.0, sky_horizon_daylight)
	_environment.fog_aerial_perspective = lerpf(visual_profile.night_fog_aerial_perspective, float(weather.get("fog_aerial_perspective", 0.13)), sky_horizon_daylight)
	_environment.fog_sun_scatter = lerpf(visual_profile.night_fog_sun_scatter, float(weather.get("fog_sun_scatter", 0.08)), sky_horizon_daylight)
	_apply_cloud_lighting(weather, cloud_daylight, blue_hour, horizon_warmth, moon_light_strength)
	_moonlight.light_color = visual_profile.moonlight_color
	_moonlight.light_energy = moon_light_strength
	_moonlight.light_specular = visual_profile.moon_light_specular_multiplier
	_moonlight.global_basis = Basis.looking_at(-moon_direction, Vector3.UP)
	_night_cloud_fill.light_color = visual_profile.night_cloud_fill_color.lerp(visual_profile.twilight_color, horizon_warmth * 0.30)
	_night_cloud_fill.light_energy = _get_night_cloud_fill_energy(elevation, moon_light_strength, cloud_coverage)
	_apply_boat_night_fill(nightness, moon_light_strength)

	_solar_state["direct_light_strength"] = direct_visibility
	_solar_state["daylight_strength"] = ambient_daylight
	_solar_state["night_strength"] = nightness
	_solar_state["sky_top_daylight"] = sky_top_daylight
	_solar_state["sky_horizon_daylight"] = sky_horizon_daylight
	_solar_state["blue_hour_strength"] = blue_hour
	_solar_state["twilight_warmth"] = horizon_warmth
	_solar_state["sun_warmth"] = sun_warmth
	_solar_state["cloud_daylight"] = cloud_daylight
	_solar_state["moonlight_strength"] = moon_light_strength
	_moon_state["moonlight_strength"] = moon_light_strength
	_moon_state["sky_visibility"] = moon_disk_visibility
	_moon_state["star_strength"] = star_strength
	_moon_state["boat_fill_strength"] = _get_boat_night_fill_energy(nightness, moon_light_strength)
	_moon_state["moonrise_visibility"] = moon_rise_visibility


func _apply_cloud_lighting(weather: Dictionary, cloud_daylight: float, blue_hour: float, horizon_warmth: float, moon_light_strength: float) -> void:
	if _sunshine_clouds == null:
		return
	var day_color: Color = weather.get("cloud_ambient_color", Color.WHITE)
	var day_tint: Color = weather.get("cloud_ambient_tint", Color(0.3, 0.4, 0.5))
	var cloud_color := visual_profile.night_cloud_ambient_color.lerp(day_color, cloud_daylight)
	var cloud_tint := visual_profile.night_cloud_ambient_tint.lerp(day_tint, cloud_daylight)
	cloud_color = cloud_color.lerp(visual_profile.blue_hour_ambient_color, blue_hour * 0.16)
	cloud_color = cloud_color.lerp(visual_profile.twilight_color, horizon_warmth * visual_profile.cloud_twilight_mix)
	var moon_cloud_mix := clampf(moon_light_strength / maxf(visual_profile.moon_light_max_energy, 0.001), 0.0, 1.0) * 0.28
	cloud_color = cloud_color.lerp(visual_profile.moonlit_cloud_ambient_color, moon_cloud_mix)
	cloud_tint = cloud_tint.lerp(visual_profile.moonlit_cloud_ambient_tint, moon_cloud_mix)
	_sunshine_clouds.cloud_ambient_color = cloud_color
	_sunshine_clouds.cloud_ambient_tint = cloud_tint


func _get_night_cloud_fill_energy(solar_elevation_degrees: float, moon_light_strength: float, cloud_coverage: float) -> float:
	# Sunshine Clouds 2 multiplies its cloud ambient fill by total tracked-light
	# power. At night, the solar light is correctly off, which otherwise leaves
	# cloud density fully black. This sky-only, no-shadow helper supplies a small
	# residual fill when moonlight is weak; it does not illuminate scene geometry.
	# The cloud compositor's own sun-up gate fades out around the horizon, before
	# the authored sky twilight curve reaches night. Start the fill in late golden
	# hour so clouds do not turn into dark cutouts as the sun approaches that gate.
	var visibility := 1.0 - smoothstep(-4.0, 12.0, solar_elevation_degrees)
	var moon_compensation := 1.0 - clampf(moon_light_strength / maxf(visual_profile.moon_light_max_energy, 0.001), 0.0, 1.0) * 0.35
	var partly_mix := smoothstep(0.45, 0.72, cloud_coverage)
	var overcast_mix := smoothstep(0.74, 0.9, cloud_coverage)
	var weather_fill_scale := lerpf(1.0, visual_profile.partly_cloudy_fill_scale, partly_mix)
	weather_fill_scale = lerpf(weather_fill_scale, visual_profile.overcast_cloud_fill_scale, overcast_mix)
	return visual_profile.night_cloud_fill_max_energy * visibility * moon_compensation * weather_fill_scale


func _get_boat_night_fill_energy(nightness: float, moon_light_strength: float) -> float:
	var moon_weight := clampf(moon_light_strength / maxf(visual_profile.moon_light_max_energy, 0.001), 0.0, 1.0)
	var night_energy := visual_profile.boat_night_fill_energy + moon_weight * visual_profile.boat_moon_fill_bonus
	return lerpf(_boat_fill_day_energy, night_energy, smoothstep(0.18, 0.88, nightness))


func _apply_boat_night_fill(nightness: float, moon_light_strength: float) -> void:
	if _boat_sky_fill == null:
		return
	var night_blend := smoothstep(0.18, 0.88, nightness)
	_boat_sky_fill.light_energy = _get_boat_night_fill_energy(nightness, moon_light_strength)
	_boat_sky_fill.light_color = _boat_fill_day_color.lerp(visual_profile.boat_night_fill_color, night_blend)
	_boat_sky_fill.omni_range = lerpf(_boat_fill_day_range, visual_profile.boat_night_fill_range, night_blend)
	# Move the existing no-shadow fill to the stern-facing side at night. The
	# imported sails are largely single-sided; centering the light inside the
	# hull leaves their camera-facing backs almost black when the moon is behind.
	_boat_sky_fill.position = _boat_fill_day_position.lerp(visual_profile.boat_night_fill_position, night_blend)


func _color_to_vector3(color: Color) -> Vector3:
	return Vector3(color.r, color.g, color.b)
