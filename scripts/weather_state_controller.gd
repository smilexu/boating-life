extends Node
class_name WeatherStateController

## Owns the active weather identity and wind targets. Visual weather remains in
## WeatherController; local gust sampling remains in WindField.

enum WeatherId { CLEAR, PARTLY_CLOUDY, OVERCAST }
enum OperatingMode { AUTO, MANUAL }

@export_node_path("Node") var weather_controller_path := NodePath("../WeatherController")
@export_node_path("Node") var wind_field_path := NodePath("../WindField")
@export_node_path("Node") var world_time_manager_path := NodePath("/root/WorldTimeManager")
@export var clear_wind_profile: WeatherWindProfile
@export var partly_cloudy_wind_profile: WeatherWindProfile
@export var overcast_wind_profile: WeatherWindProfile
@export_enum("Clear", "PartlyCloudy", "Overcast") var initial_weather: int = WeatherId.CLEAR
@export_range(1.0, 86400.0, 1.0) var wind_transition_simulation_seconds := 300.0
@export_range(0.1, 60.0, 0.1) var manual_test_transition_real_seconds := 5.0
@export var use_short_real_time_transition_for_testing := false
@export_range(0.1, 30.0, 0.1) var runtime_wind_tracking_seconds := 2.0

signal weather_state_changed(weather_id: StringName, wind_state: Dictionary)
signal operating_mode_changed(mode_name: StringName)
signal precipitation_visual_target_changed(state: Dictionary)

const WEATHER_NAMES := [&"Clear", &"PartlyCloudy", &"Overcast"]
const SAVE_SCHEMA_VERSION := 1

var current_weather_id: StringName = &"Clear"
var target_weather_id: StringName = &"Clear"
var operating_mode: int = OperatingMode.MANUAL
var climate_region_id := ""
var climate_date: Dictionary = {}
var climate_weather_type := ""
var climate_data_quality := "unavailable"
var formal_precipitation_intensity_mm_per_hour := 0.0
var formal_precipitation_available := false
var formal_precipitation_data_quality := "unavailable"

var _weather_controller: Node
var _wind_field: WindField
var _world_time_manager: Node
var _current_wind_state: Dictionary = {}
var _from_wind_state: Dictionary = {}
var _target_wind_state: Dictionary = {}
var _transition_elapsed_seconds := 0.0
var _transition_active := false
var _test_real_time_transition_enabled := false
var _last_weather_simulation_time := 0.0
var _active_visual_preset_index := WeatherId.CLEAR
var _runtime_climate_wind_target: Dictionary = {}
var _runtime_climate_tracking := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_weather_controller = get_node_or_null(weather_controller_path)
	_wind_field = get_node_or_null(wind_field_path) as WindField
	_world_time_manager = get_node_or_null(world_time_manager_path)
	_test_real_time_transition_enabled = use_short_real_time_transition_for_testing
	if _weather_controller == null or _wind_field == null or _world_time_manager == null:
		push_error("WeatherStateController needs WeatherController, WindField, and WorldTimeManager references.")
		set_process(false)
		return

	var start_index := clampi(initial_weather, 0, WEATHER_NAMES.size() - 1)
	var profile := _profile_for_index(start_index)
	if profile == null:
		push_error("WeatherStateController is missing a wind profile for its initial weather.")
		set_process(false)
		return
	if profile.seed_strategy == WeatherWindProfile.SeedStrategy.APPLY_PROFILE_SEED_ON_STARTUP:
		_wind_field.set_random_seed(profile.random_seed)

	current_weather_id = WEATHER_NAMES[start_index]
	target_weather_id = current_weather_id
	_current_wind_state = profile.to_wind_state()
	_from_wind_state = _current_wind_state.duplicate(true)
	_target_wind_state = _current_wind_state.duplicate(true)
	_wind_field.apply_formal_weather_settings(_current_wind_state)
	_weather_controller.call("set_weather_by_index", start_index, true)
	_last_weather_simulation_time = _read_weather_simulation_time()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.physical_keycode:
		KEY_0:
			set_auto_mode()
		KEY_1:
			set_weather_by_index(WeatherId.CLEAR)
		KEY_2:
			set_weather_by_index(WeatherId.PARTLY_CLOUDY)
		KEY_3:
			set_weather_by_index(WeatherId.OVERCAST)
		_:
			return
	get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if operating_mode == OperatingMode.AUTO and _runtime_climate_tracking:
		_track_runtime_climate_wind(delta)
		return
	var elapsed := delta if _test_real_time_transition_enabled else _consume_weather_simulation_delta()
	if not _transition_active or elapsed <= 0.0:
		return
	_transition_elapsed_seconds += elapsed
	var duration := _active_transition_duration()
	var linear_weight := clampf(_transition_elapsed_seconds / duration, 0.0, 1.0)
	var weight := linear_weight * linear_weight * (3.0 - 2.0 * linear_weight)
	_current_wind_state = _interpolate_wind_state(_from_wind_state, _target_wind_state, weight)
	_wind_field.apply_formal_weather_settings(_current_wind_state)
	if linear_weight >= 1.0:
		_transition_active = false
		_current_wind_state = _target_wind_state.duplicate(true)
		_wind_field.apply_formal_weather_settings(_current_wind_state)


func set_weather_by_index(index: int) -> bool:
	if index < 0 or index >= WEATHER_NAMES.size():
		return false
	var profile := _profile_for_index(index)
	if profile == null:
		push_warning("WeatherStateController has no wind profile for weather index %d." % index)
		return false
	set_manual_mode()
	_set_weather_target(WEATHER_NAMES[index], index, profile)
	return true


func set_weather_by_name(weather_name: StringName) -> bool:
	for index in range(WEATHER_NAMES.size()):
		if WEATHER_NAMES[index] == weather_name:
			return set_weather_by_index(index)
	return false


func set_manual_mode() -> void:
	if operating_mode == OperatingMode.MANUAL:
		return
	operating_mode = OperatingMode.MANUAL
	_runtime_climate_tracking = false
	_set_formal_precipitation(0.0, false, "manual")
	operating_mode_changed.emit(&"MANUAL")


func set_auto_mode() -> void:
	if operating_mode == OperatingMode.AUTO:
		return
	operating_mode = OperatingMode.AUTO
	_transition_active = false
	_runtime_climate_tracking = false
	operating_mode_changed.emit(&"AUTO")


## Receives a low-frequency sample from WeatherRuntimeGodotAdapter. The core
## already interpolates continuous weather fields, so this method replaces the
## 300-second preset transition with a small real-time tracking filter and only
## starts the sky transition when the visual preset actually changes.
func apply_runtime_climate_sample(
	weather_type: String,
	visual_preset_index: int,
	wind_state: Dictionary,
	region_id: String,
	date: Dictionary,
	data_quality: String,
	precipitation_intensity_mm_per_hour: float = 0.0,
	precipitation_available: bool = false
) -> bool:
	if operating_mode != OperatingMode.AUTO or visual_preset_index < 0 or visual_preset_index >= WEATHER_NAMES.size():
		return false
	climate_region_id = region_id
	climate_date = date.duplicate(true)
	climate_weather_type = weather_type
	climate_data_quality = data_quality
	_set_formal_precipitation(
		precipitation_intensity_mm_per_hour,
		precipitation_available,
		data_quality
	)
	var visual_changed := visual_preset_index != _active_visual_preset_index
	if visual_changed and _weather_controller != null:
		_weather_controller.call("set_weather_by_index", visual_preset_index, false)
		_active_visual_preset_index = visual_preset_index
		current_weather_id = WEATHER_NAMES[visual_preset_index]
		target_weather_id = current_weather_id
		weather_state_changed.emit(target_weather_id, wind_state.duplicate(true))
	if not wind_state.is_empty() and _is_complete_wind_state(wind_state):
		_runtime_climate_wind_target = wind_state.duplicate(true)
		_target_wind_state = _runtime_climate_wind_target.duplicate(true)
		_runtime_climate_tracking = true
		_transition_active = false
	return true


## Future ClimateModel entry point. The climate provider supplies a target
## profile; it does not write WindField parameters or visual nodes directly.
func apply_climate_weather_target(
	weather_id: StringName,
	visual_preset_index: int,
	wind_profile: WeatherWindProfile,
	region_id: String = "",
	date: Dictionary = {}
) -> bool:
	if wind_profile == null or visual_preset_index < 0 or visual_preset_index >= WEATHER_NAMES.size():
		return false
	climate_region_id = region_id
	climate_date = date.duplicate(true)
	_set_weather_target(weather_id, visual_preset_index, wind_profile)
	return true


func set_test_transition_mode(enabled: bool) -> void:
	if _test_real_time_transition_enabled == enabled:
		return
	_test_real_time_transition_enabled = enabled
	use_short_real_time_transition_for_testing = enabled
	if _transition_active:
		_from_wind_state = _current_wind_state.duplicate(true)
		_transition_elapsed_seconds = 0.0
	_last_weather_simulation_time = _read_weather_simulation_time()


func is_transitioning() -> bool:
	return _transition_active


func get_current_weather_name() -> StringName:
	return current_weather_id


func get_wind_state() -> Dictionary:
	return _current_wind_state.duplicate(true)


func get_operating_mode_name() -> StringName:
	return &"AUTO" if operating_mode == OperatingMode.AUTO else &"MANUAL"


func get_precipitation_visual_state() -> Dictionary:
	return _precipitation_visual_state()


func _set_formal_precipitation(rate_mm_per_hour: float, available: bool, quality: String) -> void:
	var safe_rate := maxf(rate_mm_per_hour, 0.0) if is_finite(rate_mm_per_hour) and available else 0.0
	var changed := (
		absf(safe_rate - formal_precipitation_intensity_mm_per_hour) > 0.001
		or available != formal_precipitation_available
		or quality != formal_precipitation_data_quality
	)
	formal_precipitation_intensity_mm_per_hour = safe_rate
	formal_precipitation_available = available
	formal_precipitation_data_quality = quality
	if changed:
		precipitation_visual_target_changed.emit(_precipitation_visual_state())


func _precipitation_visual_state() -> Dictionary:
	return {
		"intensity_mm_per_hour": formal_precipitation_intensity_mm_per_hour,
		"available": formal_precipitation_available,
		"data_quality": formal_precipitation_data_quality,
		"operating_mode": String(get_operating_mode_name()),
	}


## Describes future save fields only; no weather save/load is implemented in W2.1.
func get_persistence_snapshot() -> Dictionary:
	return {
		"schema_version": SAVE_SCHEMA_VERSION,
		"operating_mode": String(get_operating_mode_name()),
		"current_weather_id": String(current_weather_id),
		"target_weather_id": String(target_weather_id),
		"current_wind_state": _current_wind_state.duplicate(true),
		"target_wind_state": _target_wind_state.duplicate(true),
		"transition_elapsed_seconds": _transition_elapsed_seconds,
		"transition_duration_seconds": _active_transition_duration(),
		"transition_clock": "real_test" if _test_real_time_transition_enabled else "world_simulation",
		"transition_active": _transition_active,
		"climate_region_id": climate_region_id,
		"climate_date": climate_date.duplicate(true),
		"climate_weather_type": climate_weather_type,
		"climate_data_quality": climate_data_quality,
		"wind_seed": _wind_field.random_seed if _wind_field != null else 0,
		"gust_time_seconds": _wind_field.get_runtime_gust_time_seconds() if _wind_field != null else 0.0,
	}


func _set_weather_target(weather_id: StringName, visual_index: int, profile: WeatherWindProfile) -> void:
	if _weather_controller == null or _wind_field == null:
		return
	var next_target := profile.to_wind_state()
	if weather_id == target_weather_id and next_target == _target_wind_state:
		return
	_from_wind_state = _current_wind_state.duplicate(true)
	_target_wind_state = next_target
	_runtime_climate_tracking = false
	target_weather_id = weather_id
	_transition_elapsed_seconds = 0.0
	_transition_active = true
	_weather_controller.call("set_weather_by_index", visual_index, false)
	_active_visual_preset_index = visual_index
	if wind_transition_simulation_seconds <= 0.0:
		_current_wind_state = _target_wind_state.duplicate(true)
		_transition_active = false
		_wind_field.apply_formal_weather_settings(_current_wind_state)
	current_weather_id = weather_id
	weather_state_changed.emit(target_weather_id, _current_wind_state.duplicate(true))


func _profile_for_index(index: int) -> WeatherWindProfile:
	match index:
		WeatherId.CLEAR:
			return clear_wind_profile
		WeatherId.PARTLY_CLOUDY:
			return partly_cloudy_wind_profile
		WeatherId.OVERCAST:
			return overcast_wind_profile
	return null


func _active_transition_duration() -> float:
	return maxf(manual_test_transition_real_seconds, 0.05) if _test_real_time_transition_enabled else maxf(wind_transition_simulation_seconds, 0.05)


func _consume_weather_simulation_delta() -> float:
	var now := _read_weather_simulation_time()
	var elapsed := maxf(0.0, now - _last_weather_simulation_time)
	_last_weather_simulation_time = now
	return elapsed


func _read_weather_simulation_time() -> float:
	if not is_instance_valid(_world_time_manager):
		return _last_weather_simulation_time
	var snapshot: Dictionary = _world_time_manager.call("get_authoritative_state")
	return float(snapshot.get("day_cycle_index", 0)) * 86400.0 + float(snapshot.get("cycle_seconds", 0.0))


func _interpolate_wind_state(from_state: Dictionary, to_state: Dictionary, weight: float) -> Dictionary:
	var result := {}
	for key in ["mean_wind_speed_mps", "gust_strength_mps", "gust_time_scale_seconds", "gust_space_scale_meters", "gust_direction_variation_degrees"]:
		result[key] = lerpf(float(from_state[key]), float(to_state[key]), weight)
	var from_angle := deg_to_rad(float(from_state["mean_wind_from_degrees"]))
	var to_angle := deg_to_rad(float(to_state["mean_wind_from_degrees"]))
	result["mean_wind_from_degrees"] = fposmod(rad_to_deg(lerp_angle(from_angle, to_angle, weight)), 360.0)
	return result


func _track_runtime_climate_wind(delta: float) -> void:
	if delta <= 0.0 or _runtime_climate_wind_target.is_empty():
		return
	var time_constant := maxf(runtime_wind_tracking_seconds, 0.05)
	var weight := 1.0 - exp(-delta / time_constant)
	_current_wind_state = _interpolate_wind_state(_current_wind_state, _runtime_climate_wind_target, weight)
	_wind_field.apply_formal_weather_settings(_current_wind_state)
	if _wind_states_close(_current_wind_state, _runtime_climate_wind_target, 0.005):
		_current_wind_state = _runtime_climate_wind_target.duplicate(true)
		_wind_field.apply_formal_weather_settings(_current_wind_state)
		_runtime_climate_tracking = false


func _is_complete_wind_state(value: Dictionary) -> bool:
	for key in [
		"mean_wind_speed_mps", "mean_wind_from_degrees", "gust_strength_mps",
		"gust_time_scale_seconds", "gust_space_scale_meters", "gust_direction_variation_degrees",
	]:
		if not value.has(key) or not is_finite(float(value[key])):
			return false
	return float(value["mean_wind_speed_mps"]) >= 0.0 and float(value["gust_strength_mps"]) >= 0.0


func _wind_states_close(a: Dictionary, b: Dictionary, tolerance: float) -> bool:
	for key in ["mean_wind_speed_mps", "gust_strength_mps", "gust_time_scale_seconds", "gust_space_scale_meters", "gust_direction_variation_degrees"]:
		if absf(float(a.get(key, 0.0)) - float(b.get(key, 0.0))) > tolerance:
			return false
	var angle_a := deg_to_rad(float(a.get("mean_wind_from_degrees", 0.0)))
	var angle_b := deg_to_rad(float(b.get("mean_wind_from_degrees", 0.0)))
	return absf(rad_to_deg(atan2(sin(angle_b - angle_a), cos(angle_b - angle_a)))) <= tolerance
