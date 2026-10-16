extends SceneTree

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIME_MANAGER_SCRIPT := preload("res://scripts/world_time_manager.gd")
const SOLAR_POSITION_SCRIPT := preload("res://scripts/solar_position.gd")
const DAY_NIGHT_PROFILE := preload("res://resources/day_night_visual_profile.tres")

var _failures: Array[String] = []
var _checks := 0
var _manager: Node
var _manager_was_autoload := false
var _original_snapshot: Dictionary = {}
var _report_rows: Array[Dictionary] = []
var _daylight_hour_counts := {"2026-07-15": 0, "2026-12-15": 0}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_manager = root.get_node_or_null("WorldTimeManager")
	_manager_was_autoload = _manager != null
	if _manager == null:
		_manager = TIME_MANAGER_SCRIPT.new()
		_manager.name = "WorldTimeManager"
		root.add_child(_manager)
		await process_frame
	_manager.set("autosave_enabled", false)
	_original_snapshot = _manager.call("create_snapshot")

	_test_timezone_conversion()
	_test_required_solar_samples()
	_test_daylight_duration()
	_test_visual_curve_continuity()
	await _test_scene_outputs()

	if _manager != null and not _original_snapshot.is_empty():
		_manager.call("restore_snapshot", _original_snapshot)
	if not _manager_was_autoload and _manager != null:
		_manager.queue_free()
	await process_frame
	_write_report()
	if _failures.is_empty():
		print("Day/night solar tests: %d checks passed." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _test_timezone_conversion() -> void:
	var july_utc := TIME_MANAGER_SCRIPT.stockholm_civil_datetime_to_utc({"year": 2026, "month": 7, "day": 15}, 12.0 * 3600.0)
	var december_utc := TIME_MANAGER_SCRIPT.stockholm_civil_datetime_to_utc({"year": 2026, "month": 12, "day": 15}, 12.0 * 3600.0)
	_check(is_equal_approx(july_utc, _utc_timestamp(2026, 7, 15, 10, 0)), "Stockholm summer civil noon converts from CEST to 10:00 UTC")
	_check(is_equal_approx(december_utc, _utc_timestamp(2026, 12, 15, 11, 0)), "Stockholm winter civil noon converts from CET to 11:00 UTC")
	var march_transition := {"year": 2026, "month": 3, "day": 29}
	var march_before := TIME_MANAGER_SCRIPT.stockholm_civil_datetime_to_utc(march_transition, 1.99 * 3600.0)
	var march_after := TIME_MANAGER_SCRIPT.stockholm_civil_datetime_to_utc(march_transition, 2.01 * 3600.0)
	_check(march_after > march_before, "accelerated cycle keeps UTC solar time increasing on the spring DST transition date")
	var october_transition := {"year": 2026, "month": 10, "day": 25}
	var october_before := TIME_MANAGER_SCRIPT.stockholm_civil_datetime_to_utc(october_transition, 1.99 * 3600.0)
	var october_after := TIME_MANAGER_SCRIPT.stockholm_civil_datetime_to_utc(october_transition, 2.01 * 3600.0)
	_check(october_after > october_before, "accelerated cycle keeps UTC solar time increasing on the autumn DST transition date")


func _test_required_solar_samples() -> void:
	var times := [5, 8, 12, 17, 20, 23, 2]
	for date in [{"year": 2026, "month": 7, "day": 15}, {"year": 2026, "month": 12, "day": 15}]:
		for hour in times:
			var solar: Dictionary = SOLAR_POSITION_SCRIPT.calculate(date, float(hour * 3600), 55.7, 12.75)
			var row := {
				"date": "%04d-%02d-%02d" % [int(date["year"]), int(date["month"]), int(date["day"])] ,
				"time": "%02d:00" % hour,
				"elevation_degrees": float(solar["elevation_degrees"]),
				"azimuth_degrees": float(solar["azimuth_degrees"]),
				"declination_degrees": float(solar["declination_degrees"]),
			}
			_report_rows.append(row)
			print("SOLAR_SAMPLE %s %s elevation=%+.2f azimuth=%.2f declination=%+.2f" % [row.date, row.time, row.elevation_degrees, row.azimuth_degrees, row.declination_degrees])
			_check(not solar.is_empty(), "%s %s solar position is valid" % [row.date, row.time])
			_check(float(solar["azimuth_degrees"]) >= 0.0 and float(solar["azimuth_degrees"]) < 360.0, "%s %s azimuth uses clockwise true-north range" % [row.date, row.time])
			_check(absf(Vector3(solar["direction"]).length() - 1.0) < 0.0001, "%s %s returns a normalized Godot direction" % [row.date, row.time])
	var july_noon: Dictionary = SOLAR_POSITION_SCRIPT.calculate({"year": 2026, "month": 7, "day": 15}, 12.0 * 3600.0, 55.7, 12.75)
	var december_noon: Dictionary = SOLAR_POSITION_SCRIPT.calculate({"year": 2026, "month": 12, "day": 15}, 12.0 * 3600.0, 55.7, 12.75)
	_check(float(july_noon["elevation_degrees"]) > float(december_noon["elevation_degrees"]), "summer noon sun is higher than winter noon sun")
	_check(float(july_noon["azimuth_degrees"]) > 90.0 and float(july_noon["azimuth_degrees"]) < 180.0, "12:00 CEST sun is southeast before Malmö's solar noon")
	_check(Vector3(july_noon["direction"]).z > 0.0, "south maps to positive Godot Z for this GeoReference")
	_check(Vector3(july_noon["direction"]).x > 0.0, "morning sun maps to eastern positive Godot X")


func _test_daylight_duration() -> void:
	var july_daylight_hours := 0
	var december_daylight_hours := 0
	for hour in range(24):
		var july: Dictionary = SOLAR_POSITION_SCRIPT.calculate({"year": 2026, "month": 7, "day": 15}, float(hour * 3600), 55.7, 12.75)
		var december: Dictionary = SOLAR_POSITION_SCRIPT.calculate({"year": 2026, "month": 12, "day": 15}, float(hour * 3600), 55.7, 12.75)
		if float(july["elevation_degrees"]) > 0.0:
			july_daylight_hours += 1
		if float(december["elevation_degrees"]) > 0.0:
			december_daylight_hours += 1
	_daylight_hour_counts["2026-07-15"] = july_daylight_hours
	_daylight_hour_counts["2026-12-15"] = december_daylight_hours
	_check(july_daylight_hours > december_daylight_hours, "July has a longer above-horizon solar period than December")
	_check(july_daylight_hours >= 16, "July daylight duration is consistent with the high-latitude summer")
	_check(december_daylight_hours <= 9, "December daylight duration is consistent with the Nordic winter")


func _test_visual_curve_continuity() -> void:
	var curves: Array[Curve] = [
		DAY_NIGHT_PROFILE.direct_light_curve,
		DAY_NIGHT_PROFILE.sun_disk_curve,
		DAY_NIGHT_PROFILE.ambient_daylight_curve,
		DAY_NIGHT_PROFILE.sky_top_daylight_curve,
		DAY_NIGHT_PROFILE.sky_horizon_daylight_curve,
		DAY_NIGHT_PROFILE.blue_hour_curve,
		DAY_NIGHT_PROFILE.sun_warmth_curve,
		DAY_NIGHT_PROFILE.horizon_warmth_curve,
		DAY_NIGHT_PROFILE.cloud_daylight_curve,
	]
	var all_curves_present := true
	for curve in curves:
		all_curves_present = all_curves_present and curve != null
	_check(all_curves_present, "editable day/night response curves are assigned")
	for curve in curves:
		var previous := DAY_NIGHT_PROFILE.sample_response(curve, -24.0, -1.0)
		for step in range(1, 337):
			var elevation := -24.0 + float(step) * 0.25
			var value := DAY_NIGHT_PROFILE.sample_response(curve, elevation, -1.0)
			if not is_finite(value) or value < 0.0 or value > 1.0 or absf(value - previous) > 0.12:
				_check(false, "solar response curve remains finite and visually continuous at %.2f degrees" % elevation)
				return
			previous = value
	_check(true, "solar response curves stay bounded and have no visible step discontinuities")
	_check(absf(DAY_NIGHT_PROFILE.sample_response(DAY_NIGHT_PROFILE.ambient_daylight_curve, -4.0, -1.0) - 0.62) < 0.03, "twilight ambient curve eases toward dusk around -4 degrees")
	_check(absf(DAY_NIGHT_PROFILE.sample_response(DAY_NIGHT_PROFILE.cloud_daylight_curve, -4.0, -1.0) - 0.65) < 0.03, "cloud fill dims with the dusk sky rather than retaining noon brightness")
	_check(DAY_NIGHT_PROFILE.sample_response(DAY_NIGHT_PROFILE.sun_warmth_curve, -4.0, -1.0) > 0.5, "low solar elevation warms the sun near the horizon")


func _test_scene_outputs() -> void:
	var main := MAIN_SCENE.instantiate()
	root.add_child(main)
	await process_frame
	var controller := main.get_node_or_null("DayNightVisualController")
	var weather := main.get_node_or_null("WeatherController")
	var sunlight := main.get_node_or_null("Sunlight") as DirectionalLight3D
	var moonlight := main.get_node_or_null("Moonlight") as DirectionalLight3D
	var night_cloud_fill := main.get_node_or_null("NightCloudFill") as DirectionalLight3D
	var boat_sky_fill := main.get_node_or_null("PlayerBoat/MotionRoot/VisualRoot/BoatSkyFill") as OmniLight3D
	var quality := main.get_node_or_null("QualityManager")
	var clouds_driver := main.get_node_or_null("SunshineCloudsDriverGD") as SunshineCloudsDriverGD
	var clouds: SunshineCloudsGD = clouds_driver.clouds_resource if clouds_driver != null else null
	var water_material := (main.get_node_or_null("WeatherController") as WeatherController).water_material
	_check(controller != null and weather != null and sunlight != null and moonlight != null and night_cloud_fill != null and boat_sky_fill != null and quality != null and clouds != null, "main scene owns solar, lunar, boat fill, cloud-fill, weather, quality and existing cloud systems")
	if controller == null or weather == null or sunlight == null or moonlight == null or night_cloud_fill == null or boat_sky_fill == null or quality == null:
		main.queue_free()
		return
	_manager.call("pause_time")
	_manager.call("set_time_scale", 24.0)
	_manager.call("set_calendar_date", 2026, 7, 15)
	_manager.call("set_day_cycle_time", 12, 0)
	await _await_visual_frame()
	var july_noon_state: Dictionary = controller.call("get_solar_state")
	var july_moon_state: Dictionary = controller.call("get_moon_state")
	var environment := (main.get_node("WorldEnvironment") as WorldEnvironment).environment
	var sky_material := environment.sky.sky_material as ShaderMaterial
	var sky_direction: Vector3 = sky_material.get_shader_parameter("sun_direction")
	var hud := main.get_node("PlayerBoat/BoatHUD")
	hud.call("_update_debug_status")
	var sun_label := hud.get("_sun_label") as Label
	var elevation_slider := hud.get("_sun_elevation_slider") as HSlider
	var azimuth_slider := hud.get("_sun_azimuth_slider") as HSlider
	var moonrise_button := hud.find_child("NextMoonrise", true, false) as Button
	var full_moon_button := hud.find_child("FullMoonTest", true, false) as Button
	var new_moon_button := hud.find_child("NewMoonTest", true, false) as Button
	var clear_date_button := hud.find_child("ClearCalendarOverride", true, false) as Button
	_check(sun_label != null and sun_label.text.contains("太阳：高度 53.2°"), "F3 shows the calculated solar elevation")
	_check(moonrise_button != null and full_moon_button != null and new_moon_button != null and clear_date_button != null, "F3 exposes moonrise, full/new-moon test and real-calendar restore buttons")
	if moonrise_button != null and full_moon_button != null and new_moon_button != null and clear_date_button != null:
		_check(moonrise_button.pressed.is_connected(Callable(hud, "_jump_to_next_moonrise")), "F3 moonrise button calls the authority-gated jump handler")
		_check(full_moon_button.pressed.is_connected(Callable(hud, "_jump_to_lunar_phase").bind(true)), "F3 full-moon button calls the authority-gated date search")
		_check(new_moon_button.pressed.is_connected(Callable(hud, "_jump_to_lunar_phase").bind(false)), "F3 new-moon button calls the authority-gated date search")
		_check(clear_date_button.pressed.is_connected(Callable(hud, "_on_clear_calendar_override_pressed")), "F3 restore button clears the calendar override through the control port")
	_check(elevation_slider != null and not elevation_slider.editable, "F3 solar elevation is a read-only time-driven value")
	_check(azimuth_slider != null and not azimuth_slider.editable, "F3 solar azimuth is a read-only time-driven value")
	_check((sky_direction - Vector3(july_noon_state["direction"])).length() < 0.0001, "sky sun direction matches the NOAA direction")
	_check((sunlight.global_basis.z - Vector3(july_noon_state["direction"])).length() < 0.0001, "DirectionalLight points along the same sun direction")
	_check((Vector3(sky_material.get_shader_parameter("moon_direction")) - Vector3(july_moon_state["direction"])).length() < 0.0001, "sky moon direction matches the lunar ephemeris")
	_check((moonlight.global_basis.z - Vector3(july_moon_state["direction"])).length() < 0.0001, "Moonlight points along the lunar direction")
	_check(is_equal_approx(float(sky_material.get_shader_parameter("moon_angular_radius_degrees")), 1.235), "moon angular radius is increased by about 30 percent for easier viewing")
	_check(is_equal_approx(float(sky_material.get_shader_parameter("moon_core_radiance")), 2.58), "moon disk uses the brighter silver radiance")
	_check(is_equal_approx(float(sky_material.get_shader_parameter("moon_halo_strength")), 0.16), "moon halo strength is increased modestly")
	_check(is_equal_approx(DAY_NIGHT_PROFILE.stars_brightness, 1.75), "star brightness profile is increased to the tuned value")
	_check(float(DAY_NIGHT_PROFILE.moon_light_specular_multiplier) < 1.0, "moonlight highlights are softened independently of diffuse lunar illumination")
	_check(is_equal_approx(float(sky_material.get_shader_parameter("star_strength")), 0.0), "bright daytime suppresses stars")
	_check(is_equal_approx(boat_sky_fill.light_energy, 0.5), "daytime boat fill preserves its authored energy")
	_check(boat_sky_fill.position.is_equal_approx(Vector3(0.0, 2.2, 1.0)), "daytime boat fill keeps its original authored position")
	_check(is_zero_approx(float(water_material.get_shader_parameter("night_visual_weight"))), "daytime water keeps night-only lighting disabled")
	_check(is_equal_approx(float(sky_material.get_shader_parameter("sun_disk_radius_degrees")), 0.63), "sun disk radius is 50% larger while retaining the same sun direction")
	_check(is_equal_approx(float(sky_material.get_shader_parameter("sun_core_radiance")), 4.42), "sun core uses the art-directed radiance multiplier without raising the directional light")
	_check(is_equal_approx(sunlight.light_energy, 1.18), "July clear noon preserves the authored direct-light baseline")
	_check(is_zero_approx(moonlight.light_energy), "moonlight remains negligible in bright daytime")
	_check(is_zero_approx(night_cloud_fill.light_energy) and night_cloud_fill.light_cull_mask == 0, "night cloud fill is disabled by day and never lights scene geometry")
	var noon_top: Vector3 = sky_material.get_shader_parameter("sky_top_color")
	_check(noon_top.distance_to(Vector3(0.055, 0.245, 0.56)) < 0.001, "July clear noon retains the approved sky zenith palette")
	_check(is_equal_approx(float(sky_material.get_shader_parameter("sky_gradient_power")), 0.72), "daytime sky keeps its authored gradient curve")
	var approved_water_color: Color = water_material.get_shader_parameter("albedo")
	_check(approved_water_color.is_equal_approx(Color(0.14, 0.43, 0.58, 1.0)), "day/night composition leaves the approved water base palette unchanged")
	var paused_seconds := float(_manager.call("get_time_state").cycle_seconds)
	var paused_direction: Vector3 = controller.call("get_sun_direction")
	await create_timer(0.15).timeout
	_check(is_equal_approx(float(_manager.call("get_time_state").cycle_seconds), paused_seconds), "pausing world time stops the sun's day-cycle input")
	_check(Vector3(controller.call("get_sun_direction")).distance_to(paused_direction) < 0.0001, "pausing world time leaves the sun direction fixed")

	_manager.call("set_calendar_date", 2026, 12, 15)
	_manager.call("set_day_cycle_time", 2, 0)
	await _await_visual_frame()
	_check(is_zero_approx(sunlight.light_energy), "winter night disables direct sunlight")
	_check(is_zero_approx(float(sky_material.get_shader_parameter("sun_energy"))), "winter night disables the sky sun disk/glow")
	_check(float(sky_material.get_shader_parameter("star_strength")) > 0.0, "night sky enables the procedural star layer")
	_check(float(sky_material.get_shader_parameter("star_strength")) > 0.25, "dark night gives the sparse star field clearly nonzero visibility")
	_check(Vector3(sky_material.get_shader_parameter("star_color")).distance_to(Vector3(DAY_NIGHT_PROFILE.star_color.r, DAY_NIGHT_PROFILE.star_color.g, DAY_NIGHT_PROFILE.star_color.b)) < 0.001, "night sky applies the tuned cool-white star color")
	_check(boat_sky_fill.light_energy < 2.6 and boat_sky_fill.light_energy + 0.001 >= DAY_NIGHT_PROFILE.boat_night_fill_energy, "night boat fill remains art-directed while providing a readable local floor")
	_check(boat_sky_fill.omni_range > 24.0, "night boat fill covers more of the existing sail and hull mesh")
	_check(not boat_sky_fill.position.is_equal_approx(Vector3(0.0, 2.2, 1.0)), "night fill moves out of the hull to illuminate camera-facing sail surfaces")
	_check(float(water_material.get_shader_parameter("night_visual_weight")) > 0.9, "night water receives its low-cost surface visibility lift")
	_check(float(water_material.get_shader_parameter("night_roughness_target")) > 0.05, "night water broadens the moon reflection without changing the wave normals")
	_check(moonlight.light_energy >= 0.0 and moonlight.light_energy <= DAY_NIGHT_PROFILE.moon_light_max_energy, "lunar directional light stays inside its low-energy art limit")
	_check(night_cloud_fill.light_energy > 0.0 and night_cloud_fill.light_energy <= DAY_NIGHT_PROFILE.night_cloud_fill_max_energy and night_cloud_fill.light_cull_mask == 0, "night cloud fill prevents a zero-light compositor state without affecting scene meshes")
	_check(float(controller.call("get_solar_state").get("elevation_degrees")) < -10.0, "winter night sun is below the horizon")
	var deep_night_top: Vector3 = sky_material.get_shader_parameter("sky_top_color")
	_check(float(sky_material.get_shader_parameter("sky_gradient_power")) < 0.72, "night sky confines brighter twilight colors closer to the horizon")
	var expected_night_top := Vector3(DAY_NIGHT_PROFILE.night_sky_top_color.r, DAY_NIGHT_PROFILE.night_sky_top_color.g, DAY_NIGHT_PROFILE.night_sky_top_color.b)
	_check(deep_night_top.distance_to(expected_night_top) < 0.001, "deep night uses the dark blue sky palette")
	var deep_night_horizon: Vector3 = sky_material.get_shader_parameter("sky_horizon_color")
	_check(deep_night_top.length() < deep_night_horizon.length(), "night sky zenith stays darker than its horizon")
	_check(deep_night_horizon.length() < Vector3(0.008, 0.012, 0.026).length(), "deep-night horizon is dimmer than the previous blue palette")
	_check(environment.ambient_light_energy <= DAY_NIGHT_PROFILE.night_ambient_energy + 0.02, "deep night keeps only low ambient fill")
	_check(float(controller.call("get_solar_state").get("cloud_daylight", 1.0)) < 0.1, "deep night dims the cloud lighting input")
	var full_moon_fill := float(controller.call("_get_boat_night_fill_energy", 1.0, DAY_NIGHT_PROFILE.moon_light_max_energy))
	var new_moon_fill := float(controller.call("_get_boat_night_fill_energy", 1.0, 0.0))
	_check(full_moon_fill > new_moon_fill, "full-moon night gently brightens the existing boat fill compared with new moon")
	_check(clouds.cloud_ambient_color.r < 0.8 and clouds.cloud_ambient_color.b > clouds.cloud_ambient_color.r, "night clouds use a bounded cool low-light ambient palette")
	var clear_night_cloud_fill_energy := night_cloud_fill.light_energy
	weather.call("set_weather_by_index", 2)
	await _await_visual_frame()
	_check(night_cloud_fill.light_energy < clear_night_cloud_fill_energy, "overcast night softens cloud fill compared with clear night")
	weather.call("set_weather_by_index", 0)
	await _await_visual_frame()

	_manager.call("set_calendar_date", 2026, 7, 15)
	var sunrise_strengths: Array[float] = []
	for time_seconds in [4.67 * 3600.0, 4.83 * 3600.0, 5.0 * 3600.0]:
		_manager.call("set_day_cycle_time", int(time_seconds / 3600.0), int(fposmod(time_seconds, 3600.0) / 60.0))
		await _await_visual_frame()
		sunrise_strengths.append(float(controller.call("get_solar_state").get("direct_light_strength", 0.0)))
	_check(sunrise_strengths[0] <= sunrise_strengths[1] and sunrise_strengths[1] <= sunrise_strengths[2], "sunrise direct light increases continuously across the horizon")
	_check(sunrise_strengths[2] - sunrise_strengths[1] < 0.6, "sunrise lighting has no large single-step jump")
	var sunset_strengths: Array[float] = []
	for time_seconds in [21.5 * 3600.0, 21.67 * 3600.0, 21.83 * 3600.0, 22.0 * 3600.0]:
		_manager.call("set_day_cycle_time", int(time_seconds / 3600.0), int(fposmod(time_seconds, 3600.0) / 60.0))
		await _await_visual_frame()
		sunset_strengths.append(float(controller.call("get_solar_state").get("direct_light_strength", 0.0)))
	var sunset_is_monotonic := true
	for index in range(1, sunset_strengths.size()):
		if sunset_strengths[index] > sunset_strengths[index - 1] or sunset_strengths[index - 1] - sunset_strengths[index] >= 0.6:
			sunset_is_monotonic = false
	_check(sunset_is_monotonic, "sunset direct light fades continuously without a large single-step jump")
	_manager.call("set_day_cycle_time", 22, 53)
	await _await_visual_frame()
	var blue_hour_state: Dictionary = controller.call("get_solar_state")
	_check(float(blue_hour_state.get("blue_hour_strength", 0.0)) > 0.8, "summer blue hour uses its solar-elevation response")
	_check(is_zero_approx(sunlight.light_energy), "the sun no longer illuminates the sea in established blue hour")
	_check(is_zero_approx(float(sky_material.get_shader_parameter("sun_energy"))), "blue hour has no bright sun disk or halo")
	_manager.call("set_day_cycle_time", 20, 37)
	await _await_visual_frame()
	var golden_hour_state: Dictionary = controller.call("get_solar_state")
	_check(float(golden_hour_state.get("sun_warmth", 0.0)) > 0.2, "low summer sun warms the direct-light color")
	_check(float(golden_hour_state.get("twilight_warmth", 0.0)) > 0.1, "golden-hour horizon receives a restrained warm tint")

	_manager.call("set_calendar_date", 2026, 7, 15)
	_manager.call("set_day_cycle_time", 20, 37)
	await _await_visual_frame()
	var twilight_direction: Vector3 = controller.call("get_sun_direction")
	var twilight_sky_top: Vector3 = sky_material.get_shader_parameter("sky_top_color")
	var twilight_sky_horizon: Vector3 = sky_material.get_shader_parameter("sky_horizon_color")
	var twilight_ambient_color: Color = environment.ambient_light_color
	var twilight_ambient_energy := environment.ambient_light_energy
	var twilight_cloud_color: Color = clouds.cloud_ambient_color
	var twilight_cloud_tint: Color = clouds.cloud_ambient_tint
	var twilight_water_color: Color = water_material.get_shader_parameter("albedo")
	var old_scale := float(_manager.call("get_time_state").time_scale)
	var old_quality := int(quality.call("get_quality_index"))
	for quality_index in range(3):
		quality.call("set_quality_for_benchmark", quality_index)
		await _await_visual_frame()
		_check(Vector3(sky_material.get_shader_parameter("sky_top_color")).distance_to(twilight_sky_top) < 0.001, "quality tier %d keeps the twilight sky palette stable" % quality_index)
		_check(Vector3(sky_material.get_shader_parameter("sky_horizon_color")).distance_to(twilight_sky_horizon) < 0.001, "quality tier %d keeps the twilight horizon palette stable" % quality_index)
		_check(environment.ambient_light_color.is_equal_approx(twilight_ambient_color) and is_equal_approx(environment.ambient_light_energy, twilight_ambient_energy), "quality tier %d keeps composed twilight ambient light stable" % quality_index)
		_check(clouds.cloud_ambient_color.is_equal_approx(twilight_cloud_color) and clouds.cloud_ambient_tint.is_equal_approx(twilight_cloud_tint), "quality tier %d keeps twilight cloud lighting inputs stable" % quality_index)
		_check((water_material.get_shader_parameter("albedo") as Color).is_equal_approx(twilight_water_color), "quality tier %d does not overwrite weather water color" % quality_index)
		_check(Vector3(controller.call("get_sun_direction")).distance_to(twilight_direction) < 0.0001, "quality tier %d leaves the astronomical sun state unchanged" % quality_index)
	quality.call("set_quality_for_benchmark", old_quality)
	await _await_visual_frame()
	_manager.call("set_day_cycle_time", 8, 0)
	await _await_visual_frame()
	var time_driven_direction: Vector3 = controller.call("get_sun_direction")
	_manager.call("set_time_scale", 1.0)
	await _await_visual_frame()
	_check(Vector3(controller.call("get_sun_direction")).distance_to(time_driven_direction) < 0.0001, "changing the time multiplier does not reset the solar position")
	_manager.call("set_time_scale", old_scale)

	_check(water_material != null, "existing ocean material remains available")
	_check(sunlight.light_energy >= 0.0, "solar control never drives negative scene energy")
	var sun_direction_after_jump: Vector3 = sky_material.get_shader_parameter("sun_direction")
	_check(sun_direction_after_jump.distance_to(Vector3(july_noon_state["direction"])) > 0.1, "F3 time jump immediately updates the shared sky and sun direction")
	_manager.call("set_calendar_date", 2026, 7, 15)
	_manager.call("set_day_cycle_time", 12, 0)
	await _await_visual_frame()
	var sky_at_noon_before_quality: Vector3 = sky_material.get_shader_parameter("sky_top_color")
	for quality_index in range(3):
		quality.call("set_quality_for_benchmark", quality_index)
		await _await_visual_frame()
		_check(Vector3(sky_material.get_shader_parameter("sky_top_color")).distance_to(sky_at_noon_before_quality) < 0.001, "quality tier %d preserves the noon sky color" % quality_index)
		_check((water_material.get_shader_parameter("albedo") as Color).is_equal_approx(approved_water_color), "quality tier %d preserves the approved water palette" % quality_index)
	quality.call("set_quality_for_benchmark", old_quality)

	weather.set("transition_seconds", 1.0)
	_manager.call("set_time_scale", 60.0)
	_manager.call("resume_time")
	weather.call("set_weather_by_index", 2)
	await create_timer(0.35).timeout
	var mid_transition_color: Color = water_material.get_shader_parameter("albedo")
	_check(weather.current_weather_name == "Overcast", "weather selection remains independent of the accelerated day clock")
	_check(not mid_transition_color.is_equal_approx(approved_water_color) and not mid_transition_color.is_equal_approx(Color(0.07, 0.30, 0.36, 1.0)), "weather transition advances in real time rather than completing on 60x day-cycle time")
	_check(float(controller.call("get_solar_state").get("elevation_degrees")) > 0.0, "accelerated world time continues to drive the solar state")
	_test_boat_navigation_smoke(main)
	main.queue_free()
	await process_frame


func _test_boat_navigation_smoke(main: Node) -> void:
	var boat_controller := main.get_node("PlayerBoat/MotionRoot") as BoatController
	var buoyancy := main.get_node("PlayerBoat/MotionRoot/VisualRoot") as Node3D
	var initial_position := boat_controller.global_position
	boat_controller.set_process(false)
	Input.action_press("boat_accelerate")
	for _frame in range(60):
		boat_controller._process(1.0 / 60.0)
	Input.action_release("boat_accelerate")
	_check(boat_controller.speed_mps > 2.0 and boat_controller.global_position.distance_to(initial_position) > 0.5, "manual acceleration still advances the boat at game meters per second")
	var initial_heading := boat_controller.rotation.y
	Input.action_press("boat_turn_left")
	for _frame in range(30):
		boat_controller._process(1.0 / 60.0)
	Input.action_release("boat_turn_left")
	_check(absf(wrapf(boat_controller.rotation.y - initial_heading, -PI, PI)) > 0.1, "manual steering still changes the boat heading")
	var autopilot_start := boat_controller.global_position
	boat_controller.call("_toggle_autopilot")
	for _frame in range(60):
		boat_controller._process(1.0 / 60.0)
	_check(boat_controller.is_autopilot and boat_controller.global_position.distance_to(autopilot_start) > 0.5, "autopilot still advances the boat along its held heading")
	boat_controller.set_process(true)
	_check(buoyancy != null and buoyancy.get("_wave_sampler") == main.get_node("WaveSampler"), "boat visual buoyancy remains bound to the shared WaveSampler")


func _utc_timestamp(year: int, month: int, day: int, hour: int, minute: int) -> float:
	return float(Time.get_unix_time_from_datetime_dict({
		"year": year,
		"month": month,
		"day": day,
		"hour": hour,
		"minute": minute,
		"second": 0,
	}))


func _await_visual_frame() -> void:
	await process_frame
	await process_frame


func _write_report() -> void:
	var report := {
		"algorithm": "NOAA fractional-year solar position approximation",
		"location": {"latitude_degrees": 55.7, "longitude_degrees": 12.75},
		"timezone": "Europe/Stockholm",
		"godot_world_frame": "X=east, Y=up, -Z=north",
		"hourly_solar_above_horizon_samples": _daylight_hour_counts,
		"samples": _report_rows,
		"visual_profile_samples": {
			"ambient_daylight_at_minus_4_degrees": DAY_NIGHT_PROFILE.sample_response(DAY_NIGHT_PROFILE.ambient_daylight_curve, -4.0, 0.0),
			"cloud_daylight_at_minus_4_degrees": DAY_NIGHT_PROFILE.sample_response(DAY_NIGHT_PROFILE.cloud_daylight_curve, -4.0, 0.0),
			"sun_warmth_at_minus_4_degrees": DAY_NIGHT_PROFILE.sample_response(DAY_NIGHT_PROFILE.sun_warmth_curve, -4.0, 0.0),
		},
		"checks_passed": _checks - _failures.size(),
		"failures": _failures,
	}
	var file := FileAccess.open("res://docs/day_night_continuity/test_report.json", FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()


func _check(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("FAILED: " + description)
