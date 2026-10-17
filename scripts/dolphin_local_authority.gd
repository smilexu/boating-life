class_name DolphinLocalAuthority
extends "res://scripts/dolphin_authority_adapter.gd"

## Small deterministic local simulation. Only a few shared animals are updated;
## the visual layer is free to unload them without changing their world state.

const SCHEMA_VERSION := 3
const DEFAULT_SEED := 20261017
const DOLPHIN_COUNT := 4
const ACTIVITY_RADIUS_M := 1500.0
const SIMULATION_STEP := 0.1
const SURFACE_DWELL_SECONDS := 4.2
const SURFACE_APPROACH_DEPTH_M := 0.36
const SURFACE_APPROACH_COMPLETE_DEPTH_M := 0.50
const LEAP_GRAVITY_MPS2 := 9.81 * 0.8
const LEAP_START_DEPTH_M := 0.62
const LEAP_TRAJECTORY_SCRIPT := preload("res://scripts/dolphin_leap_trajectory.gd")
const FOLLOW_LEAP_INTERVAL_MIN := 5.0
const FOLLOW_LEAP_INTERVAL_MAX := 10.0
const FOLLOW_ORBIT_ENTER_SPEED_MPS := 1.5
const FOLLOW_ORBIT_EXIT_SPEED_MPS := 2.0
const FOLLOW_ORBIT_SPEED_MPS := 2.0
const FOLLOW_ORBIT_TRANSITION_SECONDS := 1.0
const FOLLOW_ORBIT_RADII_M := [7.5, 9.0, 10.5, 8.5]

var _bathymetry: BathymetryManager
var _georeference: GeoReference
var _seed := DEFAULT_SEED
var _rng := RandomNumberGenerator.new()
var _dolphins: Dictionary = {}
var _activity_center := Vector3.ZERO
var _patrol_target := Vector3.ZERO
var _patrol_elapsed := 0.0
var _simulation_clock := 0.0
var _step_accumulator := 0.0
var _encounter_elapsed := 0.0
var _encounter_cooldown := 0.0
var _follow_active := false
var _follow_mode := "cruise"
var _follow_remaining := 0.0
var _follow_started_at := 0.0
var _follow_low_speed_elapsed := 0.0
var _follow_resume_speed_elapsed := 0.0
var _follow_debug := false
var _follow_target := Vector3.ZERO
var _follow_forward := Vector3.FORWARD
var _follow_leaps_remaining := 0
var _follow_leaps_started := 0
var _follow_leaps_completed := 0
var _follow_next_leap_at := 0.0
var _state_revision := 1
var _encounter_probability := 0.32
var _follow_max_catchup_bonus_mps := 5.0
var _follow_catchup_full_distance_m := 28.0
var _follow_acceleration_mps2 := 4.0


func authority_source_name() -> String:
	return "Local"


func initialize(bathymetry: BathymetryManager, georeference: GeoReference, seed: int = DEFAULT_SEED) -> bool:
	_bathymetry = bathymetry
	_georeference = georeference
	_seed = seed
	_rng.seed = seed
	_dolphins.clear()
	if _bathymetry == null or _georeference == null or not _bathymetry.data_available:
		return false
	_activity_center = _georeference.geodetic_to_world(55.80, 12.75)
	var center_sample := _bathymetry.get_depth_at_world_position(_activity_center)
	if not bool(center_sample.get("valid", false)) or float(center_sample.get("depth_m", 0.0)) < 10.0:
		push_warning("Dolphin local authority disabled: configured Öresund activity area is not safe water.")
		return false
	_patrol_target = _activity_center
	var offsets := [Vector2(-15.0, -7.0), Vector2(-5.0, 8.0), Vector2(8.0, -6.0), Vector2(16.0, 7.0)]
	for index in range(DOLPHIN_COUNT):
		var offset: Vector2 = offsets[index]
		var position := Vector3(_activity_center.x + offset.x, 0.0, _activity_center.z + offset.y)
		var depth_sample := _bathymetry.get_depth_at_world_position(position)
		if not bool(depth_sample.get("valid", false)) or float(depth_sample.get("depth_m", 0.0)) < 10.0:
			position = _activity_center
		var dolphin_id := "oresund_pod_01_dolphin_%02d" % (index + 1)
		var animal_seed := _seed + 7919 * (index + 1)
		var direction := Vector2.from_angle(_rng.randf_range(-PI, PI))
		_dolphins[dolphin_id] = {
			"dolphin_id": dolphin_id,
			"pod_id": "oresund_pod_01",
			"index": index,
			"seed": animal_seed,
			"position": position,
			"direction": direction,
			"speed_mps": _rng.randf_range(1.5, 2.25),
			"target_speed_mps": _rng.randf_range(1.5, 2.25),
			"depth_m": _rng.randf_range(2.5, 4.0),
			"target_depth_m": _rng.randf_range(2.5, 4.0),
			"behavior_state": "swim",
			"state_elapsed": 0.0,
			"surface_cooldown": _rng.randf_range(28.0, 52.0),
			"leap_cooldown": _rng.randf_range(240.0, 420.0),
			"event_revision": 0,
			"event_type": "",
			"leap_apex_m": 0.75,
			"leap_initial_velocity_mps": 4.6371888,
			"leap_duration_s": 1.0280611,
			"surface_height_y": 0.0,
			"leap_origin_xz": Vector2(position.x, position.z),
			"leap_direction": direction,
			"leap_horizontal_speed_mps": 3.3,
			"leap_started_at": -1.0,
			"leap_start_world_y": -LEAP_START_DEPTH_M,
			"follow_leap_pending": false,
			"follow_leap_active": false,
			"last_updated": 0.0,
		}
	_state_revision = 1
	print("[DolphinWorldManager] Local authority created %d stable dolphins in Öresund test area (seed %d)." % [DOLPHIN_COUNT, _seed])
	return true


func update(delta: float, boat_position: Vector3, boat_forward: Vector3, boat_speed_mps: float) -> void:
	if _dolphins.is_empty():
		return
	_simulation_clock += maxf(delta, 0.0)
	if _follow_active:
		_follow_remaining -= maxf(delta, 0.0)
		_follow_target = boat_position
		_follow_forward = _flat_direction(boat_forward, _follow_forward)
		if _follow_remaining <= 0.0:
			_follow_active = false
			_follow_mode = "cruise"
			_follow_low_speed_elapsed = 0.0
			_follow_resume_speed_elapsed = 0.0
			_follow_debug = false
			_follow_leaps_remaining = 0
			_cancel_pending_follow_leaps()
			_encounter_cooldown = maxf(_encounter_cooldown, 240.0)
			_state_revision += 1
	_step_accumulator += maxf(delta, 0.0)
	while _step_accumulator >= SIMULATION_STEP:
		_step_accumulator -= SIMULATION_STEP
		var step_time := _simulation_clock - _step_accumulator
		_step(SIMULATION_STEP, boat_position, boat_forward, boat_speed_mps, step_time)
	_encounter_elapsed += maxf(delta, 0.0)
	_encounter_cooldown = maxf(0.0, _encounter_cooldown - maxf(delta, 0.0))
	if _encounter_elapsed >= 4.0:
		_encounter_elapsed = fmod(_encounter_elapsed, 4.0)
		_try_natural_encounter(boat_position, boat_forward, boat_speed_mps)


func get_dolphin_snapshots() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for dolphin in _dolphins.values():
		result.append(_serialize_dolphin(dolphin))
	return result


func get_map_snapshot() -> Array[Dictionary]:
	if _dolphins.is_empty():
		return []
	var position_sum := Vector3.ZERO
	var depth_sum := 0.0
	var behavior := "swim"
	for dolphin in _dolphins.values():
		position_sum += dolphin["position"] as Vector3
		depth_sum += float(dolphin["depth_m"])
		if str(dolphin["behavior_state"]) in ["following", "orbiting", "surface_approach", "surface", "leap"]:
			behavior = str(dolphin["behavior_state"])
	var center := position_sum / float(_dolphins.size())
	return [{
		"is_dolphin": true,
		"pod_id": "oresund_pod_01",
		"world_position": [center.x, 0.0, center.z],
		"population": _dolphins.size(),
		"activity_depth_m": depth_sum / float(_dolphins.size()),
		"movement_state": behavior,
		"is_following": _follow_active,
		"last_updated": _simulation_clock,
	}]


func request_follow_event(boat_position: Vector3, boat_forward: Vector3, duration_seconds: float = 60.0, debug: bool = false) -> bool:
	if _dolphins.is_empty() or (_follow_active and not debug):
		return false
	_follow_active = true
	_follow_mode = "cruise"
	_follow_remaining = clampf(duration_seconds, 30.0, 90.0)
	_follow_started_at = _simulation_clock
	_follow_low_speed_elapsed = 0.0
	_follow_resume_speed_elapsed = 0.0
	_follow_target = boat_position
	_follow_forward = _flat_direction(boat_forward, Vector3.FORWARD)
	_follow_debug = debug
	var scheduled_leaps := clampi(roundi(_follow_remaining / 10.5) + _rng.randi_range(0, 1), 3, 8)
	_follow_leaps_remaining = scheduled_leaps
	_follow_leaps_started = 0
	_follow_leaps_completed = 0
	_follow_next_leap_at = _simulation_clock + _rng.randf_range(FOLLOW_LEAP_INTERVAL_MIN, FOLLOW_LEAP_INTERVAL_MAX)
	_encounter_cooldown = maxf(_encounter_cooldown, 240.0)
	for dolphin in _dolphins.values():
		if str(dolphin["behavior_state"]) not in ["leap", "leap_approach"]:
			dolphin["target_speed_mps"] = maxf(float(dolphin["target_speed_mps"]), 2.6)
			if str(dolphin["behavior_state"]) not in ["surface_approach", "surface", "diving"]:
				dolphin["behavior_state"] = "following"
	_state_revision += 1
	return true


func request_leap(dolphin_id: String = "") -> bool:
	if _follow_active and _follow_mode == "orbit":
		return false
	var target: Dictionary = {}
	if dolphin_id.is_empty():
		for dolphin in _dolphins.values():
			if str(dolphin["behavior_state"]) != "leap":
				target = dolphin
				break
	else:
		target = _dolphins.get(dolphin_id, {})
	if target.is_empty() or str(target["behavior_state"]) == "leap":
		return false
	_start_event(target, "leap_approach", "leap_approach")
	target["state_elapsed"] = 0.0
	target["target_depth_m"] = 0.62
	target["leap_cooldown"] = _rng.randf_range(260.0, 460.0)
	target["target_speed_mps"] = 2.8
	_state_revision += 1
	return true


func set_surface_height_reference(dolphin_id: String, height_y: float) -> void:
	if _dolphins.has(dolphin_id):
		var dolphin: Dictionary = _dolphins[dolphin_id]
		dolphin["surface_height_y"] = height_y


func create_snapshot() -> Dictionary:
	var entries: Array[Dictionary] = []
	for dolphin in _dolphins.values():
		entries.append(_serialize_dolphin(dolphin))
	return {
		"schema_version": SCHEMA_VERSION,
		"world_seed": _seed,
		"state_revision": _state_revision,
		"simulation_seconds": _simulation_clock,
		"activity_center": [_activity_center.x, _activity_center.y, _activity_center.z],
		# F3 follow is temporary and must never be restored as a saved event.
		"follow_active": _follow_active and not _follow_debug,
		"follow_mode": _follow_mode if not _follow_debug else "cruise",
		"follow_remaining": _follow_remaining if not _follow_debug else 0.0,
		"follow_low_speed_elapsed": _follow_low_speed_elapsed if not _follow_debug else 0.0,
		"follow_resume_speed_elapsed": _follow_resume_speed_elapsed if not _follow_debug else 0.0,
		"follow_target": [_follow_target.x, _follow_target.y, _follow_target.z],
		"follow_forward": [_follow_forward.x, _follow_forward.y, _follow_forward.z],
		"patrol_target": [_patrol_target.x, _patrol_target.y, _patrol_target.z],
		"patrol_elapsed": _patrol_elapsed,
		"encounter_cooldown": _encounter_cooldown,
		"encounter_elapsed": _encounter_elapsed,
		"follow_leaps_remaining": _follow_leaps_remaining,
		"follow_leaps_started": _follow_leaps_started,
		"follow_leaps_completed": _follow_leaps_completed,
		"follow_next_leap_in": maxf(0.0, _follow_next_leap_at - _simulation_clock),
		"rng_state": _rng.state,
		"dolphins": entries,
	}


func restore_snapshot(snapshot: Dictionary) -> bool:
	var snapshot_version := int(snapshot.get("schema_version", -1))
	if snapshot_version < 1 or snapshot_version > SCHEMA_VERSION or int(snapshot.get("world_seed", -1)) != _seed:
		return false
	var values: Variant = snapshot.get("dolphins", [])
	if not values is Array or values.size() != DOLPHIN_COUNT:
		return false
	var restored: Dictionary = {}
	for serialized in values:
		if not serialized is Dictionary:
			return false
		var state := _deserialize_dolphin(serialized)
		if state.is_empty():
			return false
		restored[str(state["dolphin_id"])] = state
	_dolphins = restored
	_simulation_clock = maxf(0.0, float(snapshot.get("simulation_seconds", 0.0)))
	_follow_active = bool(snapshot.get("follow_active", false))
	_follow_debug = false
	_follow_mode = str(snapshot.get("follow_mode", "cruise")) if _follow_active else "cruise"
	if _follow_mode not in ["cruise", "orbit"]:
		_follow_mode = "cruise"
	_follow_remaining = maxf(0.0, float(snapshot.get("follow_remaining", 0.0))) if _follow_active else 0.0
	_follow_low_speed_elapsed = clampf(float(snapshot.get("follow_low_speed_elapsed", 0.0)), 0.0, FOLLOW_ORBIT_TRANSITION_SECONDS) if _follow_active else 0.0
	_follow_resume_speed_elapsed = clampf(float(snapshot.get("follow_resume_speed_elapsed", 0.0)), 0.0, FOLLOW_ORBIT_TRANSITION_SECONDS) if _follow_active else 0.0
	_follow_leaps_remaining = maxi(0, int(snapshot.get("follow_leaps_remaining", 0))) if _follow_active else 0
	_follow_leaps_started = maxi(0, int(snapshot.get("follow_leaps_started", 0)))
	_follow_leaps_completed = maxi(0, int(snapshot.get("follow_leaps_completed", 0)))
	_follow_next_leap_at = _simulation_clock + maxf(0.0, float(snapshot.get("follow_next_leap_in", 0.0)))
	_follow_target = _array_to_vector3(snapshot.get("follow_target", []), _activity_center)
	_follow_forward = _array_to_vector3(snapshot.get("follow_forward", []), Vector3.FORWARD)
	_patrol_target = _array_to_vector3(snapshot.get("patrol_target", []), _activity_center)
	_patrol_elapsed = maxf(0.0, float(snapshot.get("patrol_elapsed", 0.0)))
	_encounter_cooldown = maxf(0.0, float(snapshot.get("encounter_cooldown", 0.0)))
	_encounter_elapsed = maxf(0.0, float(snapshot.get("encounter_elapsed", 0.0)))
	var saved_rng_state := int(snapshot.get("rng_state", 0))
	if saved_rng_state > 0:
		_rng.state = saved_rng_state
	_state_revision = maxi(1, int(snapshot.get("state_revision", 1)))
	return true


func get_state_revision() -> int:
	return _state_revision


func set_natural_encounter_probability(probability: float) -> void:
	_encounter_probability = clampf(probability, 0.05, 0.8)


func configure_follow_motion(max_catchup_bonus_mps: float, catchup_full_distance_m: float, acceleration_mps2: float) -> void:
	_follow_max_catchup_bonus_mps = clampf(max_catchup_bonus_mps, 0.0, 10.0)
	_follow_catchup_full_distance_m = clampf(catchup_full_distance_m, 8.0, 60.0)
	_follow_acceleration_mps2 = clampf(acceleration_mps2, 0.5, 10.0)


func get_activity_center() -> Vector3:
	return _activity_center


func is_following() -> bool:
	return _follow_active


func get_follow_remaining() -> float:
	return _follow_remaining


func get_follow_leap_status() -> Dictionary:
	var paused := _follow_active and _follow_mode == "orbit"
	return {
		"remaining": _follow_leaps_remaining,
		"started": _follow_leaps_started,
		"completed": _follow_leaps_completed,
		"next_in": maxf(0.0, _follow_next_leap_at - _simulation_clock) if _follow_leaps_remaining > 0 and not paused else -1.0,
		"paused": paused,
	}


func get_follow_mode() -> String:
	return _follow_mode if _follow_active else "inactive"


func get_follow_speed_thresholds() -> Dictionary:
	return {
		"orbit_enter_mps": FOLLOW_ORBIT_ENTER_SPEED_MPS,
		"cruise_resume_mps": FOLLOW_ORBIT_EXIT_SPEED_MPS,
		"transition_seconds": FOLLOW_ORBIT_TRANSITION_SECONDS,
	}


func _step(delta: float, boat_position: Vector3, boat_forward: Vector3, boat_speed_mps: float, step_time: float) -> void:
	_patrol_elapsed += delta
	if not _follow_active and _patrol_elapsed >= 75.0:
		_patrol_elapsed = 0.0
		_patrol_target = _choose_patrol_target()
	if _follow_active:
		_update_follow_mode(delta, boat_speed_mps, step_time)
		_schedule_follow_leap(step_time)
	for dolphin in _dolphins.values():
		_advance_dolphin(dolphin, delta, boat_position, boat_forward, boat_speed_mps, step_time)


func _schedule_follow_leap(step_time: float) -> void:
	if _follow_mode == "orbit" or _follow_leaps_remaining <= 0 or _follow_remaining <= 2.0 or step_time < _follow_next_leap_at:
		return
	var candidates: Array[Dictionary] = []
	for dolphin in _dolphins.values():
		var behavior := str(dolphin["behavior_state"])
		if behavior in ["swim", "following"]:
			candidates.append(dolphin)
	if candidates.is_empty():
		_follow_next_leap_at = step_time + 0.75
		return
	var chosen: Dictionary = candidates[_rng.randi_range(0, candidates.size() - 1)]
	_start_event(chosen, "leap_approach", "leap_approach")
	chosen["follow_leap_pending"] = true
	chosen["target_depth_m"] = LEAP_START_DEPTH_M
	chosen["target_speed_mps"] = maxf(float(chosen["target_speed_mps"]), 2.8)
	_follow_leaps_remaining -= 1
	_follow_next_leap_at = step_time + _rng.randf_range(FOLLOW_LEAP_INTERVAL_MIN, FOLLOW_LEAP_INTERVAL_MAX)
	_state_revision += 1


func _cancel_pending_follow_leaps(restore_schedule: bool = false) -> void:
	var restored_count := 0
	for dolphin in _dolphins.values():
		if bool(dolphin.get("follow_leap_pending", false)) and str(dolphin["behavior_state"]) == "leap_approach":
			dolphin["follow_leap_pending"] = false
			dolphin["target_depth_m"] = float(dolphin["depth_m"])
			_start_event(dolphin, "follow_leap_cancelled", "following" if _follow_active else "swim")
			restored_count += 1
	if restore_schedule and restored_count > 0:
		_follow_leaps_remaining += restored_count


func _update_follow_mode(delta: float, boat_speed_mps: float, step_time: float) -> void:
	var speed := absf(boat_speed_mps)
	if _follow_mode == "cruise":
		_follow_low_speed_elapsed = _follow_low_speed_elapsed + delta if speed <= FOLLOW_ORBIT_ENTER_SPEED_MPS else 0.0
		_follow_resume_speed_elapsed = 0.0
		if _follow_low_speed_elapsed >= FOLLOW_ORBIT_TRANSITION_SECONDS:
			_follow_mode = "orbit"
			_follow_low_speed_elapsed = 0.0
			_cancel_pending_follow_leaps(true)
			_state_revision += 1
	else:
		_follow_resume_speed_elapsed = _follow_resume_speed_elapsed + delta if speed >= FOLLOW_ORBIT_EXIT_SPEED_MPS else 0.0
		_follow_low_speed_elapsed = 0.0
		if _follow_resume_speed_elapsed >= FOLLOW_ORBIT_TRANSITION_SECONDS:
			_follow_mode = "cruise"
			_follow_resume_speed_elapsed = 0.0
			_follow_next_leap_at = maxf(_follow_next_leap_at, step_time + 6.0)
			_state_revision += 1


func _advance_dolphin(dolphin: Dictionary, delta: float, boat_position: Vector3, boat_forward: Vector3, boat_speed_mps: float, step_time: float) -> void:
	var behavior := str(dolphin["behavior_state"])
	dolphin["surface_cooldown"] = maxf(0.0, float(dolphin["surface_cooldown"]) - delta)
	dolphin["leap_cooldown"] = maxf(0.0, float(dolphin["leap_cooldown"]) - delta)
	dolphin["state_elapsed"] = float(dolphin["state_elapsed"]) + delta
	if behavior == "leap":
		_advance_active_leap(dolphin, step_time)
		return
	var index := int(dolphin["index"])
	var offset := Vector2(float(index - 1) * 7.0, (1.0 if index % 2 == 0 else -1.0) * 7.0)
	var target := _patrol_target + Vector3(offset.x, 0.0, offset.y)
	if _follow_active:
		var forward := _flat_direction(boat_forward, _follow_forward)
		if _follow_mode == "orbit":
			target = boat_position
			if behavior not in ["surface_approach", "surface", "diving", "leap", "leap_approach"]:
				behavior = "orbiting"
		else:
			var side := Vector3(-forward.z, 0.0, forward.x)
			var row := float(index / 2)
			var side_sign := -1.0 if index % 2 == 0 else 1.0
			target = boat_position + forward * (10.0 + row * 5.0) + side * side_sign * 7.0
			var current_position: Vector3 = dolphin["position"]
			var follow_distance := Vector2(target.x - current_position.x, target.z - current_position.z).length()
			# Match vessel speed in formation and use a bounded bonus only while catching up.
			var vessel_speed := absf(boat_speed_mps)
			var catchup_blend := smoothstep(6.0, _follow_catchup_full_distance_m, follow_distance)
			var speed_scaled_bonus := minf(_follow_max_catchup_bonus_mps, maxf(1.25, vessel_speed * 0.35))
			var catchup_bonus := speed_scaled_bonus * catchup_blend
			dolphin["target_speed_mps"] = vessel_speed + catchup_bonus
			if behavior not in ["surface_approach", "surface", "diving", "leap", "leap_approach"]:
				behavior = "following"
	else:
		if behavior == "leap_approach":
			dolphin["target_speed_mps"] = maxf(float(dolphin["target_speed_mps"]), 2.8)
		else:
			dolphin["target_speed_mps"] = 1.5 + float(index % 3) * 0.28
		if behavior in ["following", "orbiting"]:
			behavior = "swim"
	if behavior in ["swim", "following", "orbiting"] and float(dolphin["surface_cooldown"]) <= 0.0:
		_start_event(dolphin, "surface_approach_start", "surface_approach")
		behavior = "surface_approach"
		_state_revision += 1
	if behavior == "surface_approach":
		dolphin["target_depth_m"] = SURFACE_APPROACH_DEPTH_M
		if float(dolphin["depth_m"]) <= SURFACE_APPROACH_COMPLETE_DEPTH_M:
			_start_event(dolphin, "surface_start", "surface")
			behavior = "surface"
			_state_revision += 1
	elif behavior == "surface":
		dolphin["target_depth_m"] = SURFACE_APPROACH_DEPTH_M
		if float(dolphin["state_elapsed"]) >= SURFACE_DWELL_SECONDS:
			_start_event(dolphin, "dive_start", "diving")
			dolphin["target_depth_m"] = _rng.randf_range(2.2, 4.2)
			dolphin["surface_cooldown"] = _rng.randf_range(32.0, 58.0)
			behavior = "diving"
			_state_revision += 1
	elif behavior == "leap_approach":
		dolphin["target_depth_m"] = LEAP_START_DEPTH_M
		if float(dolphin["depth_m"]) <= 0.70 and float(dolphin["state_elapsed"]) >= 0.8:
			_begin_leap(dolphin, step_time)
			behavior = "leap"
			_state_revision += 1
	elif behavior == "diving":
		if float(dolphin["state_elapsed"]) >= 3.4:
			behavior = ("orbiting" if _follow_mode == "orbit" else "following") if _follow_active else "swim"
			_state_revision += 1
	elif behavior in ["swim", "following"] and not _follow_active and float(dolphin["leap_cooldown"]) <= 0.0:
		var current_position: Vector3 = dolphin["position"]
		if Vector2(boat_position.x - current_position.x, boat_position.z - current_position.z).length() < 600.0:
			_start_event(dolphin, "leap_approach", "leap_approach")
			dolphin["target_depth_m"] = LEAP_START_DEPTH_M
			dolphin["follow_leap_pending"] = false
			behavior = "leap_approach"
			_state_revision += 1
	if behavior == "leap":
		_advance_active_leap(dolphin, step_time)
		return
	var position: Vector3 = dolphin["position"]
	var direction: Vector2 = dolphin["direction"]
	var target_direction := Vector2(target.x - position.x, target.z - position.z)
	if target_direction.length_squared() < 1.0:
		if _follow_active:
			# At the formation slot, keep travelling with the boat instead of
			# falling back to a distant patrol target.
			target_direction = Vector2(_follow_forward.x, _follow_forward.z)
		else:
			target = _patrol_target + Vector3(_rng.randf_range(-80.0, 80.0), 0.0, _rng.randf_range(-80.0, 80.0))
			target_direction = Vector2(target.x - position.x, target.z - position.z)
	if _follow_active and behavior in ["surface_approach", "surface", "diving", "leap_approach"]:
		# Preserve the action while softly bending the route toward the vessel.
		var follow_direction := Vector2(target.x - position.x, target.z - position.z)
		target_direction = target_direction.lerp(follow_direction, 0.35)
	if _follow_active and _follow_mode == "orbit":
		var orbit_velocity := _get_orbit_velocity(index, position, boat_position, boat_forward, boat_speed_mps)
		if orbit_velocity.length_squared() > 0.001:
			target_direction = orbit_velocity
			dolphin["target_speed_mps"] = orbit_velocity.length()
	var desired_angle := atan2(target_direction.y, target_direction.x)
	var current_angle := atan2(direction.y, direction.x)
	var turn_response := 1.0 - exp(-delta * (0.30 if behavior == "leap_approach" else 0.72))
	var next_angle := lerp_angle(current_angle, desired_angle, turn_response)
	direction = Vector2(cos(next_angle), sin(next_angle)).normalized()
	dolphin["direction"] = direction
	# Build launch speed while approaching the launch depth.
	var speed_acceleration := _follow_acceleration_mps2 if _follow_active else (2.2 if behavior == "leap_approach" else 0.75)
	dolphin["speed_mps"] = move_toward(float(dolphin["speed_mps"]), float(dolphin["target_speed_mps"]), speed_acceleration * delta)
	position.x += direction.x * float(dolphin["speed_mps"]) * delta
	position.z += direction.y * float(dolphin["speed_mps"]) * delta
	var depth := move_toward(float(dolphin["depth_m"]), float(dolphin["target_depth_m"]), 0.55 * delta)
	dolphin["depth_m"] = depth
	var bottom := _bathymetry.get_depth_at_world_position(position)
	if not bool(bottom.get("valid", false)) or float(bottom.get("depth_m", 0.0)) < 8.0:
		position.x -= direction.x * float(dolphin["speed_mps"]) * delta
		position.z -= direction.y * float(dolphin["speed_mps"]) * delta
		direction = Vector2(_activity_center.x - position.x, _activity_center.z - position.z).normalized()
		dolphin["direction"] = direction
		if depth > 5.5:
			dolphin["target_depth_m"] = 4.5
	else:
		position.y = 0.0
	dolphin["position"] = position
	dolphin["behavior_state"] = behavior
	dolphin["last_updated"] = step_time


func _get_orbit_velocity(index: int, position: Vector3, boat_position: Vector3, boat_forward: Vector3, boat_speed_mps: float) -> Vector2:
	var radial := Vector2(position.x - boat_position.x, position.z - boat_position.z)
	if radial.length_squared() < 0.25:
		var fallback_angle := TAU * float(index) / float(DOLPHIN_COUNT)
		radial = Vector2(cos(fallback_angle), sin(fallback_angle))
	var radius := radial.length()
	var radial_direction := radial / radius
	var target_radius: float = float(FOLLOW_ORBIT_RADII_M[index % FOLLOW_ORBIT_RADII_M.size()])
	var turn_sign := 1.0 if index % 2 == 0 else -1.0
	var tangent := Vector2(-radial_direction.y, radial_direction.x) * turn_sign
	var boat_direction := _flat_direction(boat_forward, _follow_forward)
	var boat_velocity := Vector2(boat_direction.x, boat_direction.z) * boat_speed_mps
	var radial_correction := radial_direction * clampf((target_radius - radius) * 0.35, -0.9, 0.9)
	return boat_velocity + tangent * FOLLOW_ORBIT_SPEED_MPS + radial_correction


func _begin_leap(dolphin: Dictionary, step_time: float) -> void:
	_assign_leap_trajectory(dolphin)
	var position: Vector3 = dolphin["position"]
	var direction: Vector2 = dolphin["direction"].normalized()
	if direction.length_squared() < 0.001:
		direction = Vector2.RIGHT
	var start_depth := clampf(float(dolphin["depth_m"]), 0.3, 0.7)
	var surface_y := float(dolphin.get("surface_height_y", 0.0))
	var apex_height := float(dolphin["leap_apex_m"])
	var initial_velocity: float = LEAP_TRAJECTORY_SCRIPT.initial_vertical_speed(apex_height, start_depth, LEAP_GRAVITY_MPS2)
	var duration: float = LEAP_TRAJECTORY_SCRIPT.water_entry_time(initial_velocity, start_depth, LEAP_GRAVITY_MPS2)
	var horizontal_speed := maxf(float(dolphin["speed_mps"]), 2.8)
	dolphin["leap_origin_xz"] = Vector2(position.x, position.z)
	dolphin["leap_direction"] = direction
	dolphin["leap_horizontal_speed_mps"] = horizontal_speed
	dolphin["leap_started_at"] = step_time
	dolphin["leap_start_depth_m"] = start_depth
	dolphin["leap_start_world_y"] = surface_y - start_depth
	dolphin["leap_initial_velocity_mps"] = initial_velocity
	dolphin["leap_duration_s"] = duration
	dolphin["target_speed_mps"] = horizontal_speed
	dolphin["speed_mps"] = horizontal_speed
	_start_event(dolphin, "leap_start", "leap")
	if bool(dolphin.get("follow_leap_pending", false)) and _follow_active:
		_follow_leaps_started += 1
		dolphin["follow_leap_active"] = true
	else:
		dolphin["follow_leap_active"] = false
	dolphin["follow_leap_pending"] = false


func _advance_active_leap(dolphin: Dictionary, step_time: float) -> void:
	var duration := maxf(0.05, float(dolphin.get("leap_duration_s", 0.9)))
	var elapsed := minf(float(dolphin["state_elapsed"]), duration)
	var origin: Vector2 = dolphin.get("leap_origin_xz", Vector2.ZERO)
	var direction: Vector2 = dolphin.get("leap_direction", dolphin["direction"]).normalized()
	var horizontal_speed := maxf(0.0, float(dolphin.get("leap_horizontal_speed_mps", 2.8)))
	var start_y := float(dolphin.get("leap_start_world_y", -LEAP_START_DEPTH_M))
	var initial_velocity := float(dolphin.get("leap_initial_velocity_mps", 4.0))
	var position := Vector3.ZERO
	var horizontal: Vector2 = LEAP_TRAJECTORY_SCRIPT.horizontal_position_at(origin, direction, horizontal_speed, elapsed)
	position.x = horizontal.x
	position.z = horizontal.y
	position.y = LEAP_TRAJECTORY_SCRIPT.height_at(start_y, initial_velocity, LEAP_GRAVITY_MPS2, elapsed)
	dolphin["position"] = position
	dolphin["direction"] = direction
	dolphin["speed_mps"] = horizontal_speed
	dolphin["target_speed_mps"] = horizontal_speed
	dolphin["depth_m"] = maxf(0.0, float(dolphin.get("surface_height_y", 0.0)) - position.y)
	dolphin["last_updated"] = step_time
	if float(dolphin["state_elapsed"]) >= duration:
		dolphin["depth_m"] = 0.0
		dolphin["target_depth_m"] = _rng.randf_range(1.8, 3.6)
		dolphin["leap_cooldown"] = _rng.randf_range(260.0, 460.0)
		if bool(dolphin.get("follow_leap_active", false)):
			_follow_leaps_completed += 1
			dolphin["follow_leap_active"] = false
		_start_event(dolphin, "dive_start", "diving")
		_state_revision += 1


func _choose_patrol_target() -> Vector3:
	for _attempt in range(16):
		var angle := _rng.randf_range(0.0, TAU)
		var radius := _rng.randf_range(280.0, ACTIVITY_RADIUS_M)
		var candidate := Vector3(_activity_center.x + cos(angle) * radius, 0.0, _activity_center.z + sin(angle) * radius)
		var sample := _bathymetry.get_depth_at_world_position(candidate)
		if bool(sample.get("valid", false)) and float(sample.get("depth_m", 0.0)) >= 9.0:
			return candidate
	return _activity_center


func _try_natural_encounter(boat_position: Vector3, boat_forward: Vector3, boat_speed_mps: float) -> void:
	if _follow_active or _encounter_cooldown > 0.0 or boat_speed_mps < 2.0 or boat_speed_mps > 9.0:
		return
	for dolphin in _dolphins.values():
		if str(dolphin["behavior_state"]) in ["leap", "leap_approach"]:
			return
	var center := Vector3.ZERO
	for dolphin in _dolphins.values():
		var dolphin_position: Vector3 = dolphin["position"]
		center += dolphin_position
	center /= float(_dolphins.size())
	if Vector2(boat_position.x - center.x, boat_position.z - center.z).length() > 220.0:
		return
	_encounter_cooldown = 28.0
	if _rng.randf() <= _encounter_probability:
		request_follow_event(boat_position, boat_forward, _rng.randf_range(35.0, 85.0), false)


func _start_event(dolphin: Dictionary, event_type: String, behavior: String) -> void:
	dolphin["event_revision"] = int(dolphin.get("event_revision", 0)) + 1
	dolphin["event_type"] = event_type
	dolphin["behavior_state"] = behavior
	dolphin["state_elapsed"] = 0.0


func _serialize_dolphin(dolphin: Dictionary) -> Dictionary:
	var position: Vector3 = dolphin["position"]
	var direction: Vector2 = dolphin["direction"]
	var leap_origin: Vector2 = dolphin.get("leap_origin_xz", Vector2.ZERO)
	var leap_direction: Vector2 = dolphin.get("leap_direction", Vector2.RIGHT)
	return {
		"dolphin_id": str(dolphin["dolphin_id"]),
		"pod_id": str(dolphin["pod_id"]),
		"index": int(dolphin["index"]),
		"seed": int(dolphin["seed"]),
		"world_position": [position.x, position.y, position.z],
		"direction": [direction.x, direction.y],
		"movement_speed_mps": float(dolphin["speed_mps"]),
		"activity_depth_m": float(dolphin["depth_m"]),
		"target_depth_m": float(dolphin["target_depth_m"]),
		"behavior_state": str(dolphin["behavior_state"]),
		"state_elapsed": float(dolphin["state_elapsed"]),
		"event_revision": int(dolphin["event_revision"]),
		"event_type": str(dolphin["event_type"]),
		"leap_apex_m": float(dolphin.get("leap_apex_m", 0.75)),
		"leap_initial_velocity_mps": float(dolphin.get("leap_initial_velocity_mps", 4.6371888)),
		"leap_duration_s": float(dolphin.get("leap_duration_s", 1.0280611)),
		"leap_duration": float(dolphin.get("leap_duration_s", 1.0280611)),
		"surface_height_y": float(dolphin.get("surface_height_y", 0.0)),
		"leap_origin_xz": [leap_origin.x, leap_origin.y],
		"leap_direction": [leap_direction.x, leap_direction.y],
		"leap_horizontal_speed_mps": float(dolphin.get("leap_horizontal_speed_mps", 2.8)),
		"leap_started_at": float(dolphin.get("leap_started_at", -1.0)),
		"leap_start_depth_m": float(dolphin.get("leap_start_depth_m", LEAP_START_DEPTH_M)),
		"leap_start_world_y": float(dolphin.get("leap_start_world_y", -LEAP_START_DEPTH_M)),
		"follow_leap_pending": bool(dolphin.get("follow_leap_pending", false)),
		"follow_leap_active": bool(dolphin.get("follow_leap_active", false)),
		"follow_remaining": _follow_remaining,
		"surface_cooldown": float(dolphin["surface_cooldown"]),
		"leap_cooldown": float(dolphin["leap_cooldown"]),
		"target_speed_mps": float(dolphin["target_speed_mps"]),
		"last_updated": float(dolphin["last_updated"]),
	}


func _deserialize_dolphin(data: Dictionary) -> Dictionary:
	var position: Array = data.get("world_position", [])
	var direction: Array = data.get("direction", [])
	if position.size() != 3 or direction.size() != 2:
		return {}
	var dolphin_id := str(data.get("dolphin_id", ""))
	if dolphin_id.is_empty():
		return {}
	var position_vector := Vector3(float(position[0]), float(position[1]), float(position[2]))
	var direction_vector := Vector2(float(direction[0]), float(direction[1])).normalized()
	var movement_speed := float(data.get("movement_speed_mps", 1.5))
	var state_elapsed := float(data.get("state_elapsed", 0.0))
	var surface_height := float(data.get("surface_height_y", 0.0))
	var start_depth := float(data.get("leap_start_depth_m", LEAP_START_DEPTH_M))
	var leap_origin_fallback := Vector2(position_vector.x, position_vector.z) - direction_vector * movement_speed * state_elapsed
	var leap_start_time_fallback := float(data.get("last_updated", 0.0)) - state_elapsed
	return {
		"dolphin_id": dolphin_id,
		"pod_id": str(data.get("pod_id", "oresund_pod_01")),
		"index": int(data.get("index", 0)),
		"seed": int(data.get("seed", _seed)),
		"position": position_vector,
		"direction": direction_vector,
		"speed_mps": movement_speed,
		"target_speed_mps": float(data.get("target_speed_mps", data.get("movement_speed_mps", 1.5))),
		"depth_m": float(data.get("activity_depth_m", 3.0)),
		"target_depth_m": float(data.get("target_depth_m", 3.0)),
		"behavior_state": str(data.get("behavior_state", "swim")),
		"state_elapsed": state_elapsed,
		"surface_cooldown": float(data.get("surface_cooldown", 30.0)),
		"leap_cooldown": float(data.get("leap_cooldown", 300.0)),
		"event_revision": int(data.get("event_revision", 0)),
		"event_type": str(data.get("event_type", "")),
		"leap_apex_m": float(data.get("leap_apex_m", 0.75)),
		"leap_initial_velocity_mps": float(data.get("leap_initial_velocity_mps", 4.6371888)),
		"leap_duration_s": float(data.get("leap_duration_s", data.get("leap_duration", 1.0280611))),
		"surface_height_y": surface_height,
		"leap_origin_xz": _array_to_vector2(data.get("leap_origin_xz", []), leap_origin_fallback),
		"leap_direction": _array_to_vector2(data.get("leap_direction", []), direction_vector),
		"leap_horizontal_speed_mps": float(data.get("leap_horizontal_speed_mps", 2.8)),
		"leap_started_at": float(data.get("leap_started_at", leap_start_time_fallback)),
		"leap_start_depth_m": start_depth,
		"leap_start_world_y": float(data.get("leap_start_world_y", surface_height - start_depth)),
		"follow_leap_pending": bool(data.get("follow_leap_pending", false)),
		"follow_leap_active": bool(data.get("follow_leap_active", false)),
		"last_updated": float(data.get("last_updated", 0.0)),
	}


func _assign_leap_trajectory(dolphin: Dictionary) -> void:
	var choice := _rng.randf()
	if choice < 0.58:
		dolphin["leap_apex_m"] = 0.35
	elif choice < 0.94:
		dolphin["leap_apex_m"] = 0.95
	else:
		dolphin["leap_apex_m"] = 1.45
	var start_depth := clampf(float(dolphin.get("depth_m", LEAP_START_DEPTH_M)), 0.3, 0.7)
	var initial_velocity: float = LEAP_TRAJECTORY_SCRIPT.initial_vertical_speed(float(dolphin["leap_apex_m"]), start_depth, LEAP_GRAVITY_MPS2)
	dolphin["leap_initial_velocity_mps"] = initial_velocity
	dolphin["leap_duration_s"] = LEAP_TRAJECTORY_SCRIPT.water_entry_time(initial_velocity, start_depth, LEAP_GRAVITY_MPS2)
	dolphin["leap_start_depth_m"] = start_depth


func _array_to_vector2(value: Variant, fallback: Vector2) -> Vector2:
	if not value is Array or value.size() < 2:
		return fallback
	return Vector2(float(value[0]), float(value[1]))


func _array_to_vector3(value: Variant, fallback: Vector3) -> Vector3:
	if not value is Array or value.size() < 3:
		return fallback
	return Vector3(float(value[0]), float(value[1]), float(value[2]))


func _flat_direction(value: Vector3, fallback: Vector3) -> Vector3:
	var flat := Vector3(value.x, 0.0, value.z)
	if flat.length_squared() < 0.001:
		flat = Vector3(fallback.x, 0.0, fallback.z)
	return flat.normalized() if flat.length_squared() > 0.001 else Vector3.FORWARD
