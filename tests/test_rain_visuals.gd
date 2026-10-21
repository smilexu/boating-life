extends SceneTree

const RAIN_PROFILE := preload("res://scripts/rain_visual_profile.gd")
const RAIN_CONTROLLER := preload("res://scripts/rain_visual_controller.gd")
const RAIN_DEBUG_PANEL := preload("res://scripts/rain_visual_debug_panel.gd")
const DAY_NIGHT_VISUAL := preload("res://scripts/day_night_visual_controller.gd")
const WEATHER_STATE := preload("res://scripts/weather_state_controller.gd")
const WEATHER_ADAPTER := preload("res://scripts/weather_runtime/weather_runtime_godot_adapter.gd")
const WIND_FIELD := preload("res://scripts/wind_field.gd")
const WIND_PROFILE := preload("res://resources/weather_wind_profile.gd")
const WAVE_SAMPLER := preload("res://scripts/wave_sampler.gd")
const EXTREME_WAVE_PRESETS := preload("res://scripts/extreme_sea_state_presets.gd")

var _checks := 0
var _failures: Array[String] = []


class FakeWorldClock extends Node:
	func get_authoritative_state() -> Dictionary:
		return {"day_cycle_index": 0, "cycle_seconds": 0.0, "time_scale": 24.0, "paused": false}


class FakeWeatherVisual extends Node:
	func set_weather_by_index(_index: int, _immediate: bool = false) -> void:
		pass


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_pure_profile()
	await _test_formal_weather_and_debug_isolation()
	if _failures.is_empty():
		print("Rain visual tests: %d checks passed." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _test_pure_profile() -> void:
	var dry := RAIN_PROFILE.from_precipitation_rate(0.0)
	_expect(float(dry["intensity"]) == 0.0, "zero mm/h maps to no rain")
	_expect(float(dry["streak_density"]) == 0.0 and float(dry["sea_impact_density"]) == 0.0, "zero mm/h disables rain sub-effects")
	_expect(float(dry["haze_strength"]) == 0.0 and float(dry["audio_intensity"]) == 0.0, "zero mm/h clears haze and reserved audio output")
	_expect(float(dry["mid_streak_alpha_scale"]) == 0.0 and float(dry["mid_streak_length_scale"]) == 0.0, "zero mm/h clears mid-layer rain shaping")
	var rates := [0.1, 0.5, 2.5, 7.5, 15.0, 30.0]
	var previous := dry
	for rate in rates:
		var current := RAIN_PROFILE.from_precipitation_rate(float(rate))
		_expect(float(current["intensity"]) >= float(previous["intensity"]), "rain response is monotonic and allows visual saturation at %.1f mm/h" % float(rate))
		for key in ["intensity", "streak_density", "near_streak_density", "mid_streak_alpha_scale", "mid_streak_length_scale", "micro_impact_density", "sea_impact_density", "sea_impact_strength", "haze_strength", "audio_intensity"]:
			_expect(is_finite(float(current[key])) and float(current[key]) >= 0.0 and float(current[key]) <= 1.0, "%s remains finite and normalized" % key)
		previous = current
	var around := absf(float(RAIN_PROFILE.from_precipitation_rate(5.001)["intensity"]) - float(RAIN_PROFILE.from_precipitation_rate(4.999)["intensity"]))
	_expect(around < 0.001, "rain response has no step at a nominal category boundary")
	_expect(float(RAIN_PROFILE.from_precipitation_rate(1.5)["intensity"]) >= 0.30, "light rain reaches a clearly visible presentation level")
	_expect(float(RAIN_PROFILE.from_precipitation_rate(5.0)["intensity"]) >= 0.60, "moderate rain receives a stronger visual response")
	_expect(float(RAIN_PROFILE.from_precipitation_rate(11.0)["intensity"]) >= 0.72, "heavy rain approaches the strong-rain visual range")
	_expect(float(RAIN_PROFILE.from_precipitation_rate(22.0)["intensity"]) >= 0.99, "strong rain reaches the full visual response")
	var moderate := RAIN_PROFILE.from_precipitation_rate(5.0)
	var strong := RAIN_PROFILE.from_precipitation_rate(22.0)
	_expect(float(strong["near_streak_density"]) > float(moderate["near_streak_density"]) * 1.8, "22 mm/h adds substantially more concentrated near rain than 5 mm/h")
	_expect(float(strong["micro_impact_density"]) > float(moderate["micro_impact_density"]), "strong rain increases fine water impact density")
	_expect(float(strong["sea_impact_density"]) > float(moderate["sea_impact_density"]), "strong rain increases sparse ring probability")
	_expect(float(moderate["mid_streak_alpha_scale"]) < float(strong["mid_streak_alpha_scale"]), "mid-rain streak opacity eases back while strong rain retains full visibility")
	_expect(float(moderate["mid_streak_length_scale"]) < float(strong["mid_streak_length_scale"]), "mid-rain streak length eases back while strong rain retains full length")
	_expect(float(moderate["mid_streak_alpha_scale"]) > 0.90 and float(moderate["mid_streak_length_scale"]) > 0.90, "moderate-rain streak adjustment remains small")
	_expect(is_equal_approx(float(strong["mid_streak_alpha_scale"]), 1.0) and is_equal_approx(float(strong["mid_streak_length_scale"]), 1.0), "strong-rain streaks are not reduced by the moderate-rain adjustment")
	_expect(float(moderate["haze_strength"]) < 0.25, "5 mm/h keeps the distant horizon readable")
	_expect(float(strong["haze_strength"]) > float(moderate["haze_strength"]) * 2.5 and float(strong["haze_strength"]) <= 0.62, "strong rain gets a bounded far-curtain increase over moderate rain")
	_expect(float(strong["sea_impact_density"]) <= 0.14, "sparse ring rate remains capped as micro impacts take visual priority")
	var day_night_visual: DayNightVisualController = DAY_NIGHT_VISUAL.new() as DayNightVisualController
	_expect(day_night_visual.rain_fog_density_multiplier <= 0.60, "rain haze remains a bounded additive factor in the shared environment fog")
	day_night_visual.free()
	for level in range(3):
		var quality: Dictionary = RAIN_CONTROLLER._quality_configuration(level)
		_expect(float(quality["haze_cap"]) <= 0.62, "quality %d keeps the far-rain curtain bounded" % level)
	var just_below_strong := RAIN_PROFILE.from_precipitation_rate(21.999)
	_expect(absf(float(strong["haze_strength"]) - float(just_below_strong["haze_strength"])) < 0.001, "far-rain curtain has no intensity step near 22 mm/h")
	_test_shader_rain_detail_contract()
	var first_step := RAIN_PROFILE.smooth_value(0.0, 10.0, 0.5, 2.0)
	var next_step := RAIN_PROFILE.smooth_value(first_step, 10.0, 0.016, 2.0)
	_expect(first_step > 0.0 and first_step < 10.0 and next_step > first_step and next_step - first_step < 0.2, "visual rain smoothing is progressive and frame-stable")
	var no_wind := RAIN_PROFILE.blend_wind_flow_toward(Vector3.ZERO, 0.22)
	_expect(no_wind.is_equal_approx(Vector3.DOWN), "no-wind rain falls vertically")
	var east_flow := RAIN_PROFILE.blend_wind_flow_toward(Vector3(10.0, 0.0, 0.0), 0.22)
	_expect(east_flow.x > 0.0 and east_flow.y < 0.0, "rain tilts with world airflow TO, not meteorological FROM")
	_expect(not RAIN_CONTROLLER._should_create_client_visuals(true, "vulkan"), "dedicated server skips local rain visuals")
	_expect(not RAIN_CONTROLLER._should_create_client_visuals(false, "headless"), "headless display skips GPU rain resources")
	_expect(RAIN_CONTROLLER._should_create_client_visuals(false, "wayland"), "interactive client may create rain visuals")
	for level in range(3):
		var quality: Dictionary = RAIN_CONTROLLER._quality_configuration(level)
		_expect(int(quality["amount"]) > 0 and float(quality["cell_size"]) > 0.0, "quality %d has bounded particle and impact settings" % level)
		_expect(int(quality["mid_amount"]) + int(quality["near_amount"]) == int(quality["amount"]), "quality %d splits, but does not increase, the particle budget" % level)
		_expect(float(quality["micro_cell_size"]) < float(quality["cell_size"]), "quality %d uses finer spacing for micro impacts than for rings" % level)


func _test_shader_rain_detail_contract() -> void:
	var shader_source := FileAccess.get_file_as_string("res://shaders/sea_water.gdshader")
	_expect(shader_source.contains("fwidth(world_coordinates.x)") and shader_source.contains("pixel_footprint * 0.65"), "micro impacts use bounded screen-footprint filtering for changing camera scale")
	var function_start := shader_source.find("vec4 rain_micro_impact_detail(")
	var function_end := shader_source.find("\n}", function_start)
	var function_body := shader_source.substr(function_start, function_end - function_start) if function_start >= 0 and function_end > function_start else ""
	_expect(not function_body.contains("VERTEX"), "micro impacts remain fragment shading only and do not move wave vertices")
	_expect(function_body.contains("cell_size * 0.0080") and function_body.contains("area_compensation"), "micro impacts have a visible local normal response with bounded footprint energy")
	_expect(function_body.contains("clamp(physical_sigma / sigma, 0.78, 1.0)"), "screen footprint filtering no longer attenuates small rain impacts below a visible floor")
	_expect(function_body.contains("small_ripple") and function_body.contains("return vec4(slope, spot, small_ripple)"), "water impacts include a separate compact ripple rim and core signal")
	_expect(shader_source.contains("ALBEDO += vec3(0.035, 0.048, 0.055)"), "rain impact shading uses a restrained blue-grey ripple edge instead of a bright full ring")
	_expect(shader_source.contains("smoothstep(35.0, 75.0, distance_from_camera)"), "near-water impacts remain visible into the medium-distance surface")
	_expect(shader_source.contains("ripple_chance = step(0.56") and shader_source.contains("arc_mask = smoothstep"), "only some impacts draw randomized partial ripple arcs")
	_expect(not shader_source.contains("atan(offset.y, offset.x)"), "partial ripple arcs avoid per-fragment angle trigonometry")


func _test_formal_weather_and_debug_isolation() -> void:
	var host := Node.new()
	host.name = "RainVisualTestHost"
	root.add_child(host)
	var clock := FakeWorldClock.new()
	clock.name = "Clock"
	host.add_child(clock)
	var weather_visual := FakeWeatherVisual.new()
	weather_visual.name = "WeatherController"
	host.add_child(weather_visual)
	var wind := WIND_FIELD.new() as WindField
	wind.name = "WindField"
	wind.set_physics_process(false)
	host.add_child(wind)
	var state: WeatherStateController = WEATHER_STATE.new() as WeatherStateController
	state.name = "WeatherStateController"
	state.weather_controller_path = NodePath("../WeatherController")
	state.wind_field_path = NodePath("../WindField")
	state.world_time_manager_path = NodePath("../Clock")
	state.clear_wind_profile = _wind_profile(6.0, 240.0)
	state.partly_cloudy_wind_profile = _wind_profile(8.0, 230.0)
	state.overcast_wind_profile = _wind_profile(10.0, 220.0)
	host.add_child(state)
	var adapter: WeatherRuntimeGodotAdapter = WEATHER_ADAPTER.new() as WeatherRuntimeGodotAdapter
	adapter.name = "Adapter"
	adapter.weather_state_controller_path = NodePath("../WeatherStateController")
	host.add_child(adapter)
	var water_material = load("res://materials/sea_water_material.tres").duplicate(true) as ShaderMaterial
	var rain: RainVisualController = RAIN_CONTROLLER.new() as RainVisualController
	rain.name = "RainVisualController"
	rain.weather_state_controller_path = NodePath("../WeatherStateController")
	rain.wind_field_path = NodePath("../WindField")
	rain.weather_controller_path = NodePath("../WeatherController")
	rain.water_material = water_material
	host.add_child(rain)
	var debug_panel: RainVisualDebugPanel = RAIN_DEBUG_PANEL.new() as RainVisualDebugPanel
	debug_panel.name = "RainVisualDebugPanel"
	debug_panel.rain_visual_controller_path = NodePath("../RainVisualController")
	host.add_child(debug_panel)
	await process_frame
	state.set_process(false)
	_expect(not rain.get_diagnostic_state()["visuals_created"], "headless rain controller does not instantiate GPU particles")
	_expect(rain.get_child_count() == 0, "headless rain controller remains node-free")
	rain._create_particle_system()
	_expect(rain.get_node_or_null("LocalRainVolume") is GPUParticles3D and rain.get_node_or_null("NearRainVolume") is GPUParticles3D, "rain visual factory builds distinct medium and near GPU layers")
	var mid_particles := rain.get_node("LocalRainVolume") as GPUParticles3D
	var near_particles := rain.get_node("NearRainVolume") as GPUParticles3D
	_expect(mid_particles.amount + near_particles.amount == 2200, "Medium quality keeps the prior total GPU particle budget")
	_expect(near_particles.lifetime < mid_particles.lifetime and near_particles.process_material != mid_particles.process_material, "near rain uses a short-lived, separately configured layer")

	state.set_auto_mode()
	var adapter_result: Dictionary = adapter.apply_sample({
		"visual_weather_id": "Overcast",
		"weather_type": "Precipitation",
		"mean_wind_speed_mps": 8.0,
		"wind_from_direction_deg": 250.0,
		"precipitation_intensity_mm_per_hour": 2.4,
		"data_quality": "fresh",
		"calendar_day_label": "2026-10-21",
	}, "oresund")
	_expect(bool(adapter_result.get("ok", false)), "runtime adapter accepts formal precipitation sample")
	_expect(bool(adapter_result.get("precipitation_available", false)) and is_equal_approx(float(adapter_result["precipitation_intensity_mm_per_hour"]), 2.4), "adapter preserves authoritative mm/h value")
	_expect(is_equal_approx(float(state.get_precipitation_visual_state()["intensity_mm_per_hour"]), 2.4), "WeatherStateController exposes the formal rain target")
	_expect(is_equal_approx(float(rain.get_formal_precipitation_state()["intensity_mm_per_hour"]), 2.4), "rain controller receives formal rain through the state signal")

	var no_amount: Dictionary = adapter.apply_sample({"visual_weather_id": "Overcast", "weather_type": "Overcast", "data_quality": "stale"}, "oresund")
	_expect(not bool(no_amount["precipitation_available"]), "missing precipitation remains N/A instead of inferred from Overcast")
	_expect(is_equal_approx(float(rain.formal_rate_mm_per_hour), 0.0), "missing precipitation produces no fabricated rain")
	var invalid_amount: Dictionary = adapter.apply_sample({
		"visual_weather_id": "Overcast",
		"weather_type": "Precipitation",
		"precipitation_intensity_mm_per_hour": NAN,
		"data_quality": "partial",
	}, "oresund")
	_expect(not bool(invalid_amount["precipitation_available"]), "non-finite precipitation is marked unavailable rather than valid zero")

	var formal_before_debug: Dictionary = state.get_precipitation_visual_state()
	rain.set_debug_override(12.0)
	rain.set_debug_controls({"streak_density_multiplier": 1.5, "wind_tilt_influence": 0.35, "sea_impact_multiplier": 0.9, "haze_multiplier": 0.7})
	_expect(rain.is_debug_override_active(), "local debug rain override activates")
	_expect(state.get_precipitation_visual_state() == formal_before_debug, "visual debug override cannot modify formal precipitation data")
	_expect(not wind.is_debug_wind_override_enabled(), "rain debug controls do not enable F12 WindField override")
	var key := InputEventKey.new()
	key.pressed = true
	key.physical_keycode = KEY_F7
	debug_panel._unhandled_key_input(key)
	_expect(not debug_panel.visible, "plain F7 remains reserved for the existing seabed toggle")
	key.physical_keycode = KEY_R
	debug_panel._unhandled_key_input(key)
	_expect(debug_panel.visible, "rain panel opens with the unassigned single R key")
	debug_panel._unhandled_key_input(key)
	_expect(not debug_panel.visible and not rain.is_debug_override_active(), "pressing R again closes the panel and clears local override")
	_expect(state.get_precipitation_visual_state() == formal_before_debug, "closing the rain panel leaves formal sample untouched")

	state.set_manual_mode()
	_expect(is_equal_approx(float(rain.formal_rate_mm_per_hour), 0.0) and not rain.formal_rate_available, "manual weather clears formal rain visuals without guessing from preset")
	state.set_auto_mode()
	_expect(is_equal_approx(float(rain.formal_rate_mm_per_hour), 0.0), "AUTO waits for a new authoritative sample after manual mode")
	var resumed_sample: Dictionary = adapter.apply_sample({
		"visual_weather_id": "PartlyCloudy",
		"weather_type": "Precipitation",
		"precipitation_intensity_mm_per_hour": 1.2,
		"data_quality": "fresh",
	}, "oresund")
	_expect(bool(resumed_sample.get("ok", false)), "rain visual reconnects when the latest authoritative sample resumes after AUTO restoration")
	_expect(is_equal_approx(rain.formal_rate_mm_per_hour, 1.2), "restored AUTO target updates rain without restoring an old visual override")

	_test_surface_parameter_isolation(water_material, rain)
	water_material = null
	host.queue_free()
	await process_frame


func _test_surface_parameter_isolation(material: ShaderMaterial, rain: RainVisualController) -> void:
	var sampler: WaveSampler = WAVE_SAMPLER.new() as WaveSampler
	sampler.wave_settings = load("res://resources/sea_waves.tres") as SeaWaveSettings
	sampler.water_material = material
	sampler.wave_strength = 1.0
	var revision := sampler.get_wave_parameter_revision()
	var wave_count := int(material.get_shader_parameter("WaveCount"))
	var wave_time := float(material.get_shader_parameter("WaveTime"))
	material.set_shader_parameter("rain_impact_density", 0.7)
	material.set_shader_parameter("rain_impact_strength", 0.5)
	material.set_shader_parameter("rain_impact_cell_size", 1.0)
	material.set_shader_parameter("rain_micro_density", 0.8)
	material.set_shader_parameter("rain_micro_cell_size", 0.4)
	material.set_shader_parameter("rain_ring_size", 0.8)
	rain.quality_level = RainVisualController.Quality.MEDIUM
	rain._set_surface_rain_parameters(0.14, 1.0, 0.8, 0.8)
	var rain_diagnostics: Dictionary = rain.get_diagnostic_state()
	_expect(is_equal_approx(float(rain_diagnostics["surface_micro_density"]), 0.8), "rain debug diagnostics read the density actually sent to the shared water material")
	_expect(is_equal_approx(float(rain_diagnostics["surface_impact_strength"]), 1.0) and is_equal_approx(float(rain_diagnostics["surface_micro_cell_size"]), 0.42), "rain debug diagnostics expose active shader intensity and Medium impact scale")
	_expect(is_equal_approx(float(rain_diagnostics["surface_ring_density"]), 0.14), "rain debug diagnostics expose the actual ring-density shader input")
	_expect(sampler.get_wave_parameter_revision() == revision, "rain surface uniforms do not modify WaveSampler parameter revision")
	_expect(int(material.get_shader_parameter("WaveCount")) == wave_count and is_equal_approx(float(material.get_shader_parameter("WaveTime")), wave_time), "rain surface uniforms leave shared wave count and phase unchanged")
	_expect(is_equal_approx(float(material.get_shader_parameter("rain_micro_density")), 0.8) and is_equal_approx(float(material.get_shader_parameter("rain_ring_size")), 0.8), "micro impacts and ring tuning stay in visual-only water shader inputs")
	_expect(int(material.get_shader_parameter("water_diagnostic_mode")) == 0, "rain settings do not overwrite F3 sea diagnostic controls")
	var base_settings := load("res://resources/sea_waves.tres") as SeaWaveSettings
	for height in [5.0, 10.0, 20.0, 30.0]:
		var extreme_settings: SeaWaveSettings = EXTREME_WAVE_PRESETS.build_settings(base_settings, float(height))
		var accepted := sampler.set_extreme_sea_test(extreme_settings, float(height))
		var impact_density := float(material.get_shader_parameter("rain_impact_density"))
		var wave_parameters_valid := extreme_settings != null and accepted
		material.set_shader_parameter("rain_impact_density", impact_density)
		_expect(wave_parameters_valid and is_equal_approx(float(material.get_shader_parameter("rain_impact_density")), impact_density), "rain shader uniforms coexist with the %d m extreme-wave preset" % int(height))
	sampler.water_material = null
	sampler.wave_settings = null
	sampler.free()


func _wind_profile(speed: float, direction: float) -> WeatherWindProfile:
	var profile: WeatherWindProfile = WIND_PROFILE.new() as WeatherWindProfile
	profile.mean_wind_speed_mps = speed
	profile.mean_wind_from_degrees = direction
	profile.gust_strength_mps = 1.0
	return profile


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("[check %d] %s" % [_checks, description])
