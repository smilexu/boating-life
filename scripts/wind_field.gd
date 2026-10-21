extends Node
class_name WindField

## Deterministic, stateless horizontal wind sampling for the independent gust clock.
## Godot map convention: X=east, Y=up, Z=south (one unit is one metre).
## Mean direction is meteorological FROM, degrees clockwise from true north.

@export_category("Mean Wind")
@export_range(0.0, 30.0, 0.1) var mean_wind_speed_mps := 6.0
@export_range(0.0, 360.0, 0.1) var mean_wind_from_degrees := 240.0

@export_category("Gusts")
@export_range(0.0, 15.0, 0.1) var gust_strength_mps := 2.0
@export_range(1.0, 180.0, 0.5) var gust_time_scale_seconds := 24.0
@export_range(50.0, 10000.0, 10.0) var gust_space_scale_meters := 450.0
@export_range(0.0, 30.0, 0.1) var gust_direction_variation_degrees := 8.0
@export var random_seed := 74291

const COORDINATE_WRAP_METERS := 1048576.0

var _speed_noise: FastNoiseLite
var _direction_noise: FastNoiseLite
var _runtime_gust_time_seconds := 0.0
var _sample_gust_time_seconds := 0.0
var _test_time_override_enabled := false
var _weather_controlled := false
var _formal_settings: Dictionary = {}
var _debug_settings: Dictionary = {}
var _debug_override_active := false
var _debug_restore_active := false
var _debug_restore_from: Dictionary = {}
var _debug_restore_elapsed := 0.0
var _debug_restore_duration := 0.0


func _ready() -> void:
	# Wind evolution must stop during a true SceneTree pause, but not when the
	# WorldTimeManager merely pauses the daytime cycle.
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_rebuild_noise()
	_formal_settings = _snapshot_parameters()
	_sample_gust_time_seconds = _runtime_gust_time_seconds


func _physics_process(delta: float) -> void:
	if is_finite(delta) and delta > 0.0:
		_runtime_gust_time_seconds += delta
	if not _test_time_override_enabled:
		_sample_gust_time_seconds = _runtime_gust_time_seconds
	_advance_debug_restore(delta)


## Returns world-space air velocity in m/s. Direction is where the air moves to.
## All queries in a physics frame use the same cached gust-clock time.
func get_wind_at(world_position: Vector3) -> Vector3:
	return _sample_at_time(world_position, _sample_gust_time_seconds)


## Height-aware entry point reserved for a future vertical wind profile.
## W1 is intentionally height-uniform, so height_m currently leaves the result unchanged.
func get_wind_at_height(world_position: Vector3, height_m: float) -> Vector3:
	var sample_position := world_position
	sample_position.y = height_m
	return get_wind_at(sample_position)


## Detailed values used by the WindFieldLab and debug panel.
func get_wind_details_at(world_position: Vector3) -> Dictionary:
	var wind := _sample_at_time(world_position, _sample_gust_time_seconds)
	var speed := wind.length()
	var gust_delta := speed - maxf(mean_wind_speed_mps, 0.0)
	return {
		"mean_speed_mps": maxf(mean_wind_speed_mps, 0.0),
		"instant_speed_mps": speed,
		"mean_wind_from_degrees": fposmod(mean_wind_from_degrees, 360.0),
		"instant_wind_from_degrees": _wind_from_degrees(wind),
		"wind_vector": wind,
		"gust_increment_mps": gust_delta,
		# Keep the legacy key for existing WindFieldLab and graph callers.
		"simulation_time_seconds": _sample_gust_time_seconds,
		"gust_time_seconds": _sample_gust_time_seconds,
		"random_seed": random_seed,
		"debug_override_state": get_debug_override_state(),
	}


func get_simulation_time_seconds() -> float:
	return _sample_gust_time_seconds


func get_gust_time_seconds() -> float:
	return _sample_gust_time_seconds


func get_runtime_gust_time_seconds() -> float:
	return _runtime_gust_time_seconds


## Test-only clock override. It affects only this WindField instance, not the world clock.
func set_test_simulation_time(seconds: float) -> void:
	if not is_finite(seconds):
		return
	_test_time_override_enabled = true
	_sample_gust_time_seconds = seconds


func clear_test_simulation_time() -> void:
	_test_time_override_enabled = false
	_sample_gust_time_seconds = _runtime_gust_time_seconds


func has_test_time_override() -> bool:
	return _test_time_override_enabled


func set_random_seed(value: int) -> void:
	if random_seed == value:
		return
	if _weather_controlled and not _debug_override_active:
		push_warning("WindField seed is controlled by WeatherStateController; use a temporary debug override or startup seed policy.")
		return
	random_seed = value
	if not _formal_settings.is_empty() and not _weather_controlled:
		_formal_settings["random_seed"] = value
	_rebuild_noise()


func set_mean_wind(speed_mps: float, wind_from_degrees: float) -> void:
	if _weather_controlled:
		push_warning("WindField formal mean wind is owned by WeatherStateController.")
		return
	mean_wind_speed_mps = clampf(speed_mps, 0.0, 30.0)
	mean_wind_from_degrees = fposmod(wind_from_degrees, 360.0)
	_update_formal_from_active()


func set_gust_parameters(strength_mps: float, time_scale_seconds: float, space_scale_meters: float) -> void:
	if _weather_controlled:
		push_warning("WindField formal gust parameters are owned by WeatherStateController.")
		return
	gust_strength_mps = clampf(strength_mps, 0.0, 15.0)
	gust_time_scale_seconds = maxf(time_scale_seconds, 1.0)
	gust_space_scale_meters = maxf(space_scale_meters, 50.0)
	_update_formal_from_active()


## WeatherStateController is the sole writer of formal settings once connected.
## The settings dictionary intentionally excludes the random seed: switching a
## weather profile must not rebuild or reset the gust noise field.
func apply_formal_weather_settings(settings: Dictionary) -> void:
	_weather_controlled = true
	_formal_settings = _normalize_settings(settings, _formal_settings if not _formal_settings.is_empty() else _snapshot_parameters())
	if _debug_override_active:
		return
	if _debug_restore_active:
		_apply_debug_restore()
	else:
		_apply_parameters(_formal_settings)


## Temporary overlay used by F12. It never changes WeatherStateController's
## formal target. The controller may keep updating that target behind the overlay.
func set_debug_wind_override(settings: Dictionary) -> void:
	var base := _snapshot_parameters()
	_debug_settings = _normalize_settings(settings, base)
	_debug_override_active = true
	_debug_restore_active = false
	_debug_restore_elapsed = 0.0
	_apply_parameters(_debug_settings)


func clear_debug_wind_override(restore_seconds: float = 1.5) -> void:
	if not _debug_override_active and not _debug_restore_active:
		return
	_debug_override_active = false
	_debug_restore_from = _snapshot_parameters()
	_debug_restore_elapsed = 0.0
	_debug_restore_duration = maxf(restore_seconds, 0.0)
	_debug_restore_active = _debug_restore_duration > 0.0
	if not _debug_restore_active:
		_debug_settings.clear()
		_apply_parameters(_formal_settings)


func has_debug_wind_override() -> bool:
	return _debug_override_active or _debug_restore_active


func is_debug_wind_override_enabled() -> bool:
	return _debug_override_active


func get_debug_override_state() -> String:
	if _debug_override_active:
		return "active"
	if _debug_restore_active:
		return "restoring"
	return "formal"


func get_effective_wind_settings() -> Dictionary:
	return _snapshot_parameters()


func get_formal_wind_settings() -> Dictionary:
	return _formal_settings.duplicate(true)


func get_debug_wind_settings() -> Dictionary:
	return _debug_settings.duplicate(true)


func _snapshot_parameters() -> Dictionary:
	return {
		"mean_wind_speed_mps": mean_wind_speed_mps,
		"mean_wind_from_degrees": mean_wind_from_degrees,
		"gust_strength_mps": gust_strength_mps,
		"gust_time_scale_seconds": gust_time_scale_seconds,
		"gust_space_scale_meters": gust_space_scale_meters,
		"gust_direction_variation_degrees": gust_direction_variation_degrees,
		"random_seed": random_seed,
	}


func _normalize_settings(settings: Dictionary, fallback: Dictionary) -> Dictionary:
	return {
		"mean_wind_speed_mps": clampf(float(settings.get("mean_wind_speed_mps", fallback.get("mean_wind_speed_mps", mean_wind_speed_mps))), 0.0, 30.0),
		"mean_wind_from_degrees": fposmod(float(settings.get("mean_wind_from_degrees", fallback.get("mean_wind_from_degrees", mean_wind_from_degrees))), 360.0),
		"gust_strength_mps": clampf(float(settings.get("gust_strength_mps", fallback.get("gust_strength_mps", gust_strength_mps))), 0.0, 15.0),
		"gust_time_scale_seconds": maxf(float(settings.get("gust_time_scale_seconds", fallback.get("gust_time_scale_seconds", gust_time_scale_seconds))), 1.0),
		"gust_space_scale_meters": maxf(float(settings.get("gust_space_scale_meters", fallback.get("gust_space_scale_meters", gust_space_scale_meters))), 50.0),
		"gust_direction_variation_degrees": clampf(float(settings.get("gust_direction_variation_degrees", fallback.get("gust_direction_variation_degrees", gust_direction_variation_degrees))), 0.0, 30.0),
		"random_seed": int(settings.get("random_seed", fallback.get("random_seed", random_seed))),
	}


func _apply_parameters(settings: Dictionary) -> void:
	var normalized := _normalize_settings(settings, _snapshot_parameters())
	var seed_changed := random_seed != int(normalized["random_seed"])
	mean_wind_speed_mps = float(normalized["mean_wind_speed_mps"])
	mean_wind_from_degrees = float(normalized["mean_wind_from_degrees"])
	gust_strength_mps = float(normalized["gust_strength_mps"])
	gust_time_scale_seconds = float(normalized["gust_time_scale_seconds"])
	gust_space_scale_meters = float(normalized["gust_space_scale_meters"])
	gust_direction_variation_degrees = float(normalized["gust_direction_variation_degrees"])
	if seed_changed:
		random_seed = int(normalized["random_seed"])
		_rebuild_noise()


func _update_formal_from_active() -> void:
	_formal_settings = _snapshot_parameters()


func _advance_debug_restore(delta: float) -> void:
	if not _debug_restore_active or not is_finite(delta) or delta <= 0.0:
		return
	_debug_restore_elapsed += delta
	_apply_debug_restore()
	if _debug_restore_elapsed >= _debug_restore_duration:
		_debug_restore_active = false
		_debug_settings.clear()
		_debug_restore_from.clear()
		_apply_parameters(_formal_settings)


func _apply_debug_restore() -> void:
	if _formal_settings.is_empty():
		return
	var weight := clampf(_debug_restore_elapsed / maxf(_debug_restore_duration, 0.001), 0.0, 1.0)
	weight = weight * weight * (3.0 - 2.0 * weight)
	var blended := {}
	for key in ["mean_wind_speed_mps", "gust_strength_mps", "gust_time_scale_seconds", "gust_space_scale_meters", "gust_direction_variation_degrees"]:
		blended[key] = lerpf(float(_debug_restore_from.get(key, _formal_settings[key])), float(_formal_settings[key]), weight)
	var from_angle := deg_to_rad(float(_debug_restore_from.get("mean_wind_from_degrees", _formal_settings["mean_wind_from_degrees"])))
	var to_angle := deg_to_rad(float(_formal_settings["mean_wind_from_degrees"]))
	blended["mean_wind_from_degrees"] = fposmod(rad_to_deg(lerp_angle(from_angle, to_angle, weight)), 360.0)
	# The main-game debug panel keeps the formal seed fixed, so a seed switch cannot
	# create an abrupt gust-pattern reset during overlay removal.
	blended["random_seed"] = int(_formal_settings.get("random_seed", random_seed))
	_apply_parameters(blended)


func _sample_at_time(world_position: Vector3, simulation_time_seconds: float) -> Vector3:
	if not _is_finite_vector3(world_position) or not is_finite(simulation_time_seconds):
		return Vector3.ZERO

	var average_speed := clampf(mean_wind_speed_mps, 0.0, 30.0)
	# A zero mean setting is a true calm test even if gust strength is nonzero.
	if average_speed <= 0.0001:
		return Vector3.ZERO
	if _speed_noise == null or _direction_noise == null:
		_rebuild_noise()

	# Limit coordinates before noise evaluation to keep far-world inputs numerically
	# stable. The wrap period is over 1,000 km, far beyond this prototype's region.
	var east := fposmod(world_position.x + COORDINATE_WRAP_METERS * 0.5, COORDINATE_WRAP_METERS)
	var north := fposmod(-world_position.z + COORDINATE_WRAP_METERS * 0.5, COORDINATE_WRAP_METERS)
	var space_scale := maxf(gust_space_scale_meters, 50.0)
	var time_scale := maxf(gust_time_scale_seconds, 1.0)
	var x := east / space_scale
	var z := north / space_scale
	# Keep FastNoiseLite inputs bounded even after very long world sessions.
	# The noise domain drifts continuously on three incommensurate gust periods;
	# wrapping each phase at a full cycle preserves continuity at the wrap point.
	var phase_a := _phase(simulation_time_seconds, time_scale)
	var phase_b := _phase(simulation_time_seconds, time_scale * sqrt(2.0))
	var phase_c := _phase(simulation_time_seconds, time_scale * sqrt(3.0))
	var speed_noise := _speed_noise.get_noise_3d(
		x + sin(phase_a) * 0.8,
		z + cos(phase_b) * 0.8,
		sin(phase_c) * 0.8
	)
	var direction_noise := _direction_noise.get_noise_3d(
		x + 13.7 + cos(phase_b) * 0.8,
		z - 29.1 + sin(phase_c) * 0.8,
		cos(phase_a) * 0.8
	)
	var gust_increment := speed_noise * maxf(gust_strength_mps, 0.0)
	var instant_speed := maxf(0.0, average_speed + gust_increment)
	var direction_delta := direction_noise * minf(
		maxf(gust_direction_variation_degrees, 0.0),
		maxf(gust_strength_mps, 0.0) * 4.0
	)
	var toward := _wind_toward_direction(mean_wind_from_degrees + direction_delta)
	var result := toward * instant_speed
	return result if _is_finite_vector3(result) else Vector3.ZERO


func _rebuild_noise() -> void:
	_speed_noise = _make_noise(random_seed)
	_direction_noise = _make_noise(random_seed + 104729)


func _make_noise(seed_value: int) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 1.0
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 2
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = 0.45
	return noise


func _wind_toward_direction(wind_from_degrees: float) -> Vector3:
	var angle := deg_to_rad(fposmod(wind_from_degrees, 360.0))
	# X=east, Z=south: north-origin clockwise bearing, meteorological FROM.
	return Vector3(-sin(angle), 0.0, cos(angle)).normalized()


func _wind_from_degrees(wind_to: Vector3) -> float:
	if wind_to.length_squared() <= 0.000001:
		return fposmod(mean_wind_from_degrees, 360.0)
	# Bearing uses east and north components; world north is -Z.
	var toward_bearing := fposmod(rad_to_deg(atan2(wind_to.x, -wind_to.z)), 360.0)
	return fposmod(toward_bearing + 180.0, 360.0)


func _phase(time_seconds: float, period_seconds: float) -> float:
	var safe_period := maxf(period_seconds, 1.0)
	return TAU * fposmod(time_seconds, safe_period) / safe_period


func _is_finite_vector3(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)
