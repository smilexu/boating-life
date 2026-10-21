extends SceneTree

const WEATHER_STATE_SCRIPT := preload("res://scripts/weather_state_controller.gd")
const WIND_FIELD_SCRIPT := preload("res://scripts/wind_field.gd")
const WIND_PROFILE_SCRIPT := preload("res://resources/weather_wind_profile.gd")
const WIND_PANEL_SCRIPT := preload("res://scripts/wind_field_debug_panel.gd")

var _checks := 0
var _failures: Array[String] = []


class FakeWorldClock extends Node:
	var day_cycle_index := 0
	var cycle_seconds := 0.0
	var time_scale := 24.0
	var paused := false

	func get_authoritative_state() -> Dictionary:
		return {
			"day_cycle_index": day_cycle_index,
			"cycle_seconds": cycle_seconds,
			"time_scale": time_scale,
			"paused": paused,
		}


class FakeWeatherVisual extends Node:
	var selected_index := -1
	var immediate := false

	func set_weather_by_index(index: int, apply_immediately: bool = false) -> void:
		selected_index = index
		immediate = apply_immediately


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var host := Node.new()
	host.name = "WeatherWindIntegrationTestHost"
	root.add_child(host)

	var clock := FakeWorldClock.new()
	clock.name = "Clock"
	host.add_child(clock)
	var visual := FakeWeatherVisual.new()
	visual.name = "WeatherController"
	host.add_child(visual)
	var field: WindField = WIND_FIELD_SCRIPT.new() as WindField
	field.name = "WindField"
	field.random_seed = 1234
	field.set_physics_process(false)
	host.add_child(field)

	var clear_profile := _profile(6.0, 350.0, 1.0)
	var partly_profile := _profile(10.0, 10.0, 2.0)
	var overcast_profile := _profile(12.0, 280.0, 4.0)
	var state: WeatherStateController = WEATHER_STATE_SCRIPT.new() as WeatherStateController
	state.name = "WeatherStateController"
	state.weather_controller_path = NodePath("../WeatherController")
	state.wind_field_path = NodePath("../WindField")
	state.world_time_manager_path = NodePath("../Clock")
	state.clear_wind_profile = clear_profile
	state.partly_cloudy_wind_profile = partly_profile
	state.overcast_wind_profile = overcast_profile
	state.wind_transition_simulation_seconds = 100.0
	state.manual_test_transition_real_seconds = 1.0
	host.add_child(state)
	await process_frame
	state.set_process(false)

	_expect(field.mean_wind_speed_mps == 6.0 and field.mean_wind_from_degrees == 350.0, "startup formal weather is applied to WindField")
	_expect(field.random_seed == 1234, "weather profile keeps the existing WindField seed")
	_expect(visual.selected_index == 0 and visual.immediate, "initial visual preset is applied without a startup blend")

	state.set_test_transition_mode(true)
	_expect(state.set_weather_by_index(1), "PartlyCloudy preset is accepted")
	_expect(visual.selected_index == 1 and not visual.immediate, "visual preset selection is routed through WeatherStateController")
	state._process(0.5)
	var halfway := state.get_wind_state()
	_expect(float(halfway["mean_wind_speed_mps"]) > 6.0 and float(halfway["mean_wind_speed_mps"]) < 10.0, "wind speed blends between weather targets")
	_expect(_angle_distance(float(halfway["mean_wind_from_degrees"]), 0.0) < 1.0, "wind direction crosses 0 degrees by the shortest path")

	var before_retarget := state.get_wind_state()
	_expect(state.set_weather_by_index(2), "Overcast preset is accepted during an active blend")
	_expect(_state_distance(before_retarget, state.get_wind_state()) < 0.0001, "continuous weather retarget keeps the current interpolated state")
	state._process(0.02)
	_expect(_state_distance(before_retarget, state.get_wind_state()) < 0.2, "continuous weather retarget advances without a parameter jump")
	state._process(2.0)
	_expect(is_equal_approx(field.get_formal_wind_settings()["mean_wind_speed_mps"], 12.0), "Overcast target reaches the formal WindField settings")
	_expect(field.random_seed == 1234, "switching weather profiles does not reset the gust seed")
	_test_weather_shortcuts(state, visual)

	state.set_test_transition_mode(false)
	state._process(0.0)
	state.set_weather_by_index(0)
	clock.paused = true
	state._process(0.25)
	_expect(is_equal_approx(float(state.get_persistence_snapshot()["transition_elapsed_seconds"]), 0.0), "weather-process transition pauses with the WorldTimeManager cycle")
	clock.paused = false
	clock.time_scale = 60.0
	clock.cycle_seconds = 25.0
	state._process(0.016)
	_expect(is_equal_approx(float(state.get_persistence_snapshot()["transition_elapsed_seconds"]), 25.0), "weather-process transition follows authoritative simulation seconds, not frame delta")
	state.set_test_transition_mode(true)
	state._process(2.0)
	state.set_weather_by_index(2)
	state._process(2.0)

	var formal_before_override := field.get_formal_wind_settings()
	var debug_values := field.get_effective_wind_settings()
	debug_values["mean_wind_speed_mps"] = 20.0
	field.set_debug_wind_override(debug_values)
	state.set_weather_by_index(0)
	state._process(0.5)
	_expect(is_equal_approx(field.mean_wind_speed_mps, 20.0), "debug override controls effective wind while active")
	_expect(not is_equal_approx(float(field.get_formal_wind_settings()["mean_wind_speed_mps"]), float(formal_before_override["mean_wind_speed_mps"])), "formal weather continues evolving behind debug override")
	field.clear_debug_wind_override(1.0)
	var restore_start := field.mean_wind_speed_mps
	state._process(0.25)
	field._physics_process(0.25)
	var restore_mid := field.mean_wind_speed_mps
	state._process(0.25)
	field._physics_process(0.25)
	_expect(restore_mid < restore_start and field.mean_wind_speed_mps < restore_mid, "debug coverage blends smoothly toward the latest formal target")
	state._process(1.0)
	field._physics_process(1.0)
	_expect(field.get_debug_override_state() == "formal", "debug override finishes and releases formal control")
	_expect(is_equal_approx(field.mean_wind_speed_mps, float(state.get_wind_state()["mean_wind_speed_mps"])), "debug release restores the latest, not the stale, weather target")

	var panel := WIND_PANEL_SCRIPT.new()
	panel.name = "WindFieldDebugPanel"
	panel.set("wind_field_path", NodePath("../WindField"))
	panel.set("sample_source_path", NodePath("../SampleSource"))
	panel.set("weather_state_controller_path", NodePath("../WeatherStateController"))
	var sample_source := Node3D.new()
	sample_source.name = "SampleSource"
	host.add_child(sample_source)
	host.add_child(panel)
	await process_frame
	state.set_process(false)
	var mode_label := panel.find_child("WindFieldOperatingMode", true, false) as Label
	_expect(mode_label != null and mode_label.text.contains("正式天气"), "F12 shows whether formal weather or a test override is active")
	var f12 := InputEventKey.new()
	f12.pressed = true
	f12.physical_keycode = KEY_F12
	panel._unhandled_key_input(f12)
	panel._on_mean_speed_changed(3.0)
	panel._on_mean_direction_changed(280.0)
	_expect(field.is_debug_wind_override_enabled() and is_equal_approx(field.mean_wind_speed_mps, 3.0) and is_equal_approx(field.mean_wind_from_degrees, 280.0), "editing F12 speed and direction activates the requested temporary override")
	_expect(mode_label.text.contains("当前有效平均风：3.0 m/s · 280° 来向"), "F12 mode readout explicitly shows the effective override values")
	_expect(is_equal_approx(float(state.get_wind_state()["mean_wind_speed_mps"]), float(field.get_formal_wind_settings()["mean_wind_speed_mps"])), "F12 does not write into WeatherStateController")
	panel._set_test_clock_enabled(true)
	_expect(field.has_test_time_override(), "F12 test clock override is independent from weather parameters")
	panel._unhandled_key_input(f12)
	_expect(not field.is_debug_wind_override_enabled() and field.get_debug_override_state() == "restoring", "closing F12 starts release of its temporary parameter override")
	_expect(not field.has_test_time_override(), "closing F12 also releases its separate test clock")
	field._physics_process(2.0)
	_expect(field.get_debug_override_state() == "formal", "F12 release completes without leaving test state active")

	var gust_before := field.get_runtime_gust_time_seconds()
	clock.paused = true
	for scale in [1.0, 24.0, 60.0]:
		clock.time_scale = float(scale)
		var before := field.get_runtime_gust_time_seconds()
		field._physics_process(0.1)
		_expect(is_equal_approx(field.get_runtime_gust_time_seconds() - before, 0.1), "gust clock advances by runtime delta at world time scale %.0f" % float(scale))
	_expect(field.get_runtime_gust_time_seconds() > gust_before, "WorldTimeManager pause does not stop the gust clock")
	_expect(field.process_mode == Node.PROCESS_MODE_PAUSABLE, "WindField is configured to stop during a true SceneTree pause")

	var snapshot: Dictionary = state.get_persistence_snapshot()
	for key in ["current_weather_id", "target_weather_id", "current_wind_state", "target_wind_state", "transition_elapsed_seconds", "transition_duration_seconds", "climate_region_id", "climate_date", "wind_seed", "gust_time_seconds"]:
		_expect(snapshot.has(key), "weather persistence snapshot includes %s" % key)
	_expect(snapshot.get("climate_region_id", "") == "", "W2.1 leaves climate region unassigned for W2.2")

	await _test_scene_pause(field)
	host.queue_free()
	await process_frame
	if _failures.is_empty():
		print("Weather/WindField integration tests: %d checks passed." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _test_scene_pause(field: WindField) -> void:
	field.set_physics_process(true)
	await physics_frame
	var before := field.get_runtime_gust_time_seconds()
	paused = true
	await create_timer(0.12, true).timeout
	var during_pause := field.get_runtime_gust_time_seconds()
	paused = false
	_expect(is_equal_approx(before, during_pause), "true SceneTree pause stops the pausable gust clock")


func _profile(speed: float, wind_from: float, gust: float) -> WeatherWindProfile:
	var profile: WeatherWindProfile = WIND_PROFILE_SCRIPT.new() as WeatherWindProfile
	profile.mean_wind_speed_mps = speed
	profile.mean_wind_from_degrees = wind_from
	profile.gust_strength_mps = gust
	profile.gust_time_scale_seconds = 20.0
	profile.gust_space_scale_meters = 400.0
	profile.gust_direction_variation_degrees = 8.0
	profile.seed_strategy = WeatherWindProfile.SeedStrategy.KEEP_WINDFIELD_SEED
	profile.random_seed = 74291
	profile.source_note = "Temporary integration test fixture; not climate data."
	return profile


func _test_weather_shortcuts(state: WeatherStateController, visual: FakeWeatherVisual) -> void:
	for shortcut in [
		{"key": KEY_1, "index": 0, "id": &"Clear"},
		{"key": KEY_2, "index": 1, "id": &"PartlyCloudy"},
		{"key": KEY_3, "index": 2, "id": &"Overcast"},
	]:
		var event := InputEventKey.new()
		event.pressed = true
		event.physical_keycode = int(shortcut["key"])
		state._unhandled_key_input(event)
		_expect(state.target_weather_id == shortcut["id"], "shortcut key %d selects its unified weather state" % int(shortcut["key"]))
		_expect(visual.selected_index == int(shortcut["index"]), "shortcut key %d updates the visual preset through the state controller" % int(shortcut["key"]))


func _state_distance(a: Dictionary, b: Dictionary) -> float:
	var total := 0.0
	for key in ["mean_wind_speed_mps", "gust_strength_mps", "gust_time_scale_seconds", "gust_space_scale_meters", "gust_direction_variation_degrees"]:
		total += absf(float(a[key]) - float(b[key]))
	return total + _angle_distance(float(a["mean_wind_from_degrees"]), float(b["mean_wind_from_degrees"]))


func _angle_distance(a: float, b: float) -> float:
	return absf(fposmod(a - b + 180.0, 360.0) - 180.0)


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("Weather/WindField integration failed: %s" % description)
