class_name BoatFishingFightParticipant
extends RefCounted

## Per-catch boat-fishing force/stamina simulation. It does not move scene nodes,
## own line length/tension, or change catch/Authority state.

enum StruggleState { STEADY, BURST, RECOVERY }

const STATE_NAMES := ["steady", "burst", "recovery"]
const MIN_PHASE_SECONDS := 0.05
const MAX_SIMULATION_SUBSTEP_S := 0.05

var _profile: BoatFishingFightProfile
var _catch_id := ""
var _hook_index := -1
var _species_id := ""
var _school_id := ""
var _rig_id := ""
var _body_length_m := 0.0
var _sizing_length_m := 0.0
var _debug_spawned := false
var _fight_seed := 1
var _rng := RandomNumberGenerator.new()
var _initialized := false

var _stamina_ratio := 1.0
var _struggle_state := StruggleState.STEADY
var _phase_remaining_s := 1.0
var _scheduled_burst_interval_s := 1.0
var _active_burst_duration_s := 0.0
var _post_burst_steady_duration_s := 0.0
var _current_pull_n := 0.0
var _size_factor := 1.0
var _swim_direction := Vector3.UP
var _direction_reference_valid := false
var _boat_outward_horizontal := Vector3.ZERO


func initialize_from_pending_catch(
	pending_catch: FishingPendingCatch,
	profile: BoatFishingFightProfile,
	seed_override: int = -1,
	boat_outward_horizontal: Vector3 = Vector3.ZERO
) -> bool:
	if _initialized:
		return false
	if pending_catch == null or profile == null:
		return false
	if pending_catch.fishing_method != "boat_fishing" or not pending_catch.hook_confirmed:
		return false
	if not profile.is_valid_for_species(pending_catch.species_id):
		return false

	_profile = profile
	_catch_id = pending_catch.catch_id
	_hook_index = pending_catch.hook_index
	_species_id = pending_catch.species_id
	_school_id = pending_catch.school_id
	_rig_id = pending_catch.rig_id
	_body_length_m = pending_catch.body_length_m
	_debug_spawned = pending_catch.debug_spawned
	_sizing_length_m = _body_length_m if is_finite(_body_length_m) and _body_length_m > 0.0 else _profile.size_reference_length_m
	_size_factor = _profile.get_size_factor(_sizing_length_m)
	_fight_seed = seed_override if seed_override >= 0 else _seed_from_catch_id(_catch_id)
	if seed_override < 0 and _fight_seed == 0:
		_fight_seed = 1
	_rng.seed = _fight_seed
	_stamina_ratio = 1.0
	_struggle_state = StruggleState.STEADY
	_scheduled_burst_interval_s = _sample_interval()
	_phase_remaining_s = maxf(MIN_PHASE_SECONDS, _scheduled_burst_interval_s)
	_active_burst_duration_s = 0.0
	_post_burst_steady_duration_s = 0.0
	_current_pull_n = _calculate_target_pull_n()
	_initialized = true
	_set_direction_reference(boat_outward_horizontal, true)
	return true


## Pass the current hull-outward horizontal reference on every update. An invalid
## reference intentionally switches the intent to the safe vertical fallback.
func advance(dt_real: float, boat_outward_horizontal: Vector3 = Vector3.ZERO) -> Dictionary:
	if not _initialized or not is_finite(dt_real) or dt_real <= 0.0:
		return get_read_only_snapshot()
	_set_direction_reference(boat_outward_horizontal, false)
	var remaining := dt_real
	# Advance through every phase boundary rather than dropping time beyond a cap.
	# All phase durations have a positive floor, so malformed profiles cannot spin forever.
	while remaining > 0.000001:
		if _phase_remaining_s <= 0.000001:
			_enter_next_phase()
			continue
		var phase_time := minf(remaining, _phase_remaining_s)
		while phase_time > 0.000001:
			var step := minf(phase_time, MAX_SIMULATION_SUBSTEP_S)
			_advance_continuous_state(step)
			_phase_remaining_s = maxf(0.0, _phase_remaining_s - step)
			phase_time = maxf(0.0, phase_time - step)
			remaining = maxf(0.0, remaining - step)
		if _phase_remaining_s <= 0.000001:
			_enter_next_phase()
	return get_read_only_snapshot()


func get_read_only_snapshot() -> Dictionary:
	return {
		"catch_id": _catch_id,
		"hook_index": _hook_index,
		"species_id": _species_id,
		"school_id": _school_id,
		"rig_id": _rig_id,
		"body_length_m": _body_length_m,
		"debug_spawned": _debug_spawned,
		"fight_seed": _fight_seed,
		"size_factor": _size_factor,
		"stamina_ratio": _stamina_ratio,
		"struggle_state": STATE_NAMES[_struggle_state],
		"struggle_state_id": _struggle_state,
		"phase_remaining_s": _phase_remaining_s,
		"current_pull_n": _current_pull_n,
		"swim_direction": _swim_direction,
		"swim_speed_mps": _get_swim_speed_mps(),
		"direction_reference_valid": _direction_reference_valid,
	}


func is_initialized() -> bool:
	return _initialized


func get_size_factor() -> float:
	return _size_factor


func _advance_continuous_state(dt: float) -> void:
	if _struggle_state == StruggleState.BURST:
		_stamina_ratio -= _safe_nonnegative(_profile.stamina_drain_rate) * dt
	else:
		var recovery_scale := 1.0 if _struggle_state == StruggleState.RECOVERY else 0.25
		_stamina_ratio += _safe_nonnegative(_profile.stamina_recovery_rate) * recovery_scale * dt
	_stamina_ratio = clampf(_stamina_ratio, 0.0, 1.0)
	var target_force := _calculate_target_pull_n()
	var time_constant := _safe_positive(_profile.force_rise_time_s, 0.18) if target_force > _current_pull_n else _safe_positive(_profile.force_fall_time_s, 0.3)
	var blend := 1.0 - exp(-dt / time_constant)
	_current_pull_n = _profile.get_bounded_pull_n(lerpf(_current_pull_n, target_force, clampf(blend, 0.0, 1.0)))
	if not is_finite(_current_pull_n):
		_current_pull_n = _profile.get_bounded_pull_n(0.0)


func _enter_next_phase() -> void:
	match _struggle_state:
		StruggleState.STEADY:
			if _stamina_ratio >= clampf(_profile.minimum_burst_stamina_ratio, 0.0, 1.0):
				_begin_burst()
			else:
				_scheduled_burst_interval_s = _sample_interval()
				_phase_remaining_s = maxf(MIN_PHASE_SECONDS, _scheduled_burst_interval_s)
				_stamina_ratio = clampf(_stamina_ratio + _safe_nonnegative(_profile.stamina_recovery_rate) * 0.25 * MIN_PHASE_SECONDS, 0.0, 1.0)
		StruggleState.BURST:
			_begin_recovery()
		StruggleState.RECOVERY:
			_struggle_state = StruggleState.STEADY
			_phase_remaining_s = maxf(MIN_PHASE_SECONDS, _post_burst_steady_duration_s)
			_refresh_swim_direction()


func _begin_burst() -> void:
	_struggle_state = StruggleState.BURST
	var duration_range := _profile.get_safe_burst_duration_range()
	_active_burst_duration_s = _rng.randf_range(duration_range.x, duration_range.y)
	_phase_remaining_s = maxf(MIN_PHASE_SECONDS, _active_burst_duration_s)
	_scheduled_burst_interval_s = maxf(_active_burst_duration_s, _sample_interval())
	_refresh_swim_direction()


func _begin_recovery() -> void:
	_struggle_state = StruggleState.RECOVERY
	var rest_duration := maxf(MIN_PHASE_SECONDS, _scheduled_burst_interval_s - _active_burst_duration_s)
	var recovery_share := 0.58
	_phase_remaining_s = maxf(MIN_PHASE_SECONDS, rest_duration * recovery_share)
	_post_burst_steady_duration_s = maxf(MIN_PHASE_SECONDS, rest_duration - _phase_remaining_s)
	_refresh_swim_direction()


func _calculate_target_pull_n() -> float:
	if _profile == null:
		return 0.0
	var stamina_force_factor := lerpf(clampf(_profile.low_stamina_pull_multiplier, 0.0, 1.0), 1.0, sqrt(clampf(_stamina_ratio, 0.0, 1.0)))
	var force := _profile.base_pull_n * _size_factor * stamina_force_factor
	match _struggle_state:
		StruggleState.BURST:
			var minimum_burst := maxf(1.0, _profile.minimum_burst_multiplier)
			var maximum_burst := maxf(minimum_burst, _profile.burst_multiplier)
			var stamina_scaled_burst := lerpf(minimum_burst, maximum_burst, sqrt(clampf(_stamina_ratio, 0.0, 1.0)))
			force *= stamina_scaled_burst
		StruggleState.RECOVERY:
			force *= clampf(_profile.recovery_pull_multiplier, 0.0, 1.0)
	return _profile.get_bounded_pull_n(force)


func _get_swim_speed_mps() -> float:
	if _profile == null:
		return 0.0
	match _struggle_state:
		StruggleState.BURST:
			return _safe_nonnegative(_profile.burst_swim_speed_mps) * lerpf(0.25, 1.0, sqrt(_stamina_ratio))
		StruggleState.RECOVERY:
			return _safe_nonnegative(_profile.recovery_swim_speed_mps)
		_:
			return _safe_nonnegative(_profile.steady_swim_speed_mps)


func _sample_interval() -> float:
	var safe_range := _profile.get_safe_burst_interval_range()
	return _rng.randf_range(safe_range.x, safe_range.y)


func _set_direction_reference(direction: Vector3, force_refresh: bool) -> void:
	var horizontal := Vector3(direction.x, 0.0, direction.z)
	var valid := horizontal.is_finite() and horizontal.length_squared() > 0.000001
	if valid:
		horizontal = horizontal.normalized()
	var was_valid := _direction_reference_valid
	_direction_reference_valid = valid
	_boat_outward_horizontal = horizontal if valid else Vector3.ZERO
	if force_refresh or (valid and not was_valid) or (valid and _swim_direction.dot(_boat_outward_horizontal) < -0.0001):
		_refresh_swim_direction()
	elif not valid:
		_swim_direction = Vector3.UP


func _refresh_swim_direction() -> void:
	if not _direction_reference_valid:
		_swim_direction = Vector3.UP
		return
	var outward := _boat_outward_horizontal
	var side := Vector3.UP.cross(outward).normalized()
	if side.length_squared() < 0.000001:
		_swim_direction = Vector3.UP
		return
	var outward_weight := _rng.randf_range(0.2, 1.0)
	var lateral_weight := _rng.randf_range(-0.9, 0.9)
	var vertical_weight := _rng.randf_range(-0.45, 0.45)
	var candidate := outward * outward_weight + side * lateral_weight + Vector3.UP * vertical_weight
	if candidate.length_squared() < 0.000001 or not candidate.is_finite():
		_swim_direction = outward
		return
	candidate = candidate.normalized()
	if candidate.dot(outward) < 0.0:
		candidate -= outward * candidate.dot(outward)
	if candidate.length_squared() < 0.000001:
		candidate = outward
	_swim_direction = candidate.normalized()


static func _seed_from_catch_id(catch_id: String) -> int:
	# FNV-1a over UTF-8 bytes, explicitly bounded to a positive RNG seed.
	var hash_value: int = 2166136261
	for byte_value in catch_id.to_utf8_buffer():
		hash_value = int((hash_value ^ int(byte_value)) * 16777619) & 0x7fffffff
	if hash_value == 0:
		return 1
	return hash_value


static func _safe_nonnegative(value: float) -> float:
	return maxf(0.0, value) if is_finite(value) else 0.0


static func _safe_positive(value: float, fallback: float) -> float:
	return value if is_finite(value) and value > 0.0001 else fallback
