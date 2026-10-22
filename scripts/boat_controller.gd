class_name BoatController
extends Node3D

signal manual_takeover_requested
signal vessel_mode_changed(sailboat_active: bool)

## Navigation transform for the player boat.
## One Godot unit represents one meter. The motion origin sits on the calm-water
## plane at the boat centerline; the normalized model's bow points along local
## -Z. VisualRoot is separate so wave-driven height, pitch, and roll do not
## change the navigation transform.
## Visual models are corrected below this node so the navigation axes stay stable.

const DEFAULT_VESSEL_LENGTH_M := 5.263
const DEFAULT_VESSEL_BEAM_M := 2.327
const EngineAudioProfileScript = preload("res://scripts/engine_audio_profile.gd")

enum PropulsionType {
	NONE,
	POWERBOAT,
}

@export_category("Movement")
@export_range(1.0, 20.0, 0.5) var max_speed_mps := 12.0
@export_range(0.5, 10.0, 0.1) var acceleration_mps2 := 2.8
@export_range(0.5, 12.0, 0.1) var braking_mps2 := 4.5
@export_range(0.0, 2.0, 0.05) var coast_deceleration_mps2 := 0.18
@export_range(5.0, 60.0, 1.0) var turn_rate_degrees_per_second := 28.0
@export_range(1.0, 12.0, 0.5) var cruise_speed_mps := 7.0
@export_range(0.1, 0.8, 0.05) var reverse_speed_ratio := 0.45

@export_category("Navigation reference · gameplay only")
@export var draft_profile: VesselDraftProfile
@export_range(0.0, 1000000.0, 1.0, "or_greater") var current_cargo_weight_kg := 0.0

@export_category("Vessel audio")
@export var propulsion_type: PropulsionType = PropulsionType.POWERBOAT
@export var engine_audio_profile: EngineAudioProfileScript
@export_node_path("RigidBody3D") var sailboat_body_path := NodePath("../SailingBoat8m")
@export_node_path("Node3D") var sailboat_spawn_point_path := NodePath("../../SailboatSpawn")
@export_node_path("Node") var navigation_depth_provider_path := NodePath("../../NavigationDepthProvider")
@export_range(5.0, 50.0, 1.0) var sailboat_spawn_clearance_m := 14.0

var speed_mps := 0.0
var is_autopilot := false
var is_motion_paused := false
var is_port_docked := false
var manual_input_enabled := true

var _autopilot_steering_input := 0.0
var _autopilot_target_speed_mps := 0.0
var _autopilot_speed_cap_mps := 0.0
var _sailboat_body: RigidBody3D
var _sailboat_spawn_point: Node3D
var _navigation_depth_provider: Node
var _sailboat_active := false


func _ready() -> void:
	_sailboat_body = get_node_or_null(sailboat_body_path) as RigidBody3D
	_sailboat_spawn_point = get_node_or_null(sailboat_spawn_point_path) as Node3D
	_navigation_depth_provider = get_node_or_null(navigation_depth_provider_path)
	if _sailboat_body == null:
		return
	_sailboat_body.set_as_top_level(true)
	_sailboat_body.freeze = true
	_sailboat_body.visible = false
	if _sailboat_body.has_method("set_vessel_active"):
		_sailboat_body.call("set_vessel_active", false)
	if _sailboat_body.has_method("set_keyboard_controls_enabled"):
		_sailboat_body.call("set_keyboard_controls_enabled", false)


func get_current_draft_m() -> float:
	if _sailboat_active and _sailboat_body != null:
		var sail_profile: Resource = _sailboat_body.get("profile") as Resource
		return float(sail_profile.get("draft_m")) if sail_profile != null else 0.9
	if draft_profile == null:
		return -1.0
	return draft_profile.draft_for_cargo_weight(current_cargo_weight_kg)


func get_reverse_max_speed_mps() -> float:
	return max_speed_mps * clampf(reverse_speed_ratio, 0.1, 0.8)


func get_autopilot_speed_cap_mps() -> float:
	return maxf(max_speed_mps, _autopilot_speed_cap_mps)


## Read-only demand estimate for the local engine sound. This does not feed back
## into throttle, propulsion, autopilot, or vessel motion.
func get_engine_audio_state() -> Dictionary:
	if not has_engine():
		return {"running": false, "power": 0.0, "docked": is_port_docked}
	var running := not is_port_docked and not is_motion_paused
	if not running:
		return {"running": false, "power": 0.0, "docked": is_port_docked}
	var throttle_demand := 0.0
	if is_autopilot:
		throttle_demand = clampf(_autopilot_target_speed_mps / maxf(get_autopilot_speed_cap_mps(), 0.1), 0.0, 1.0)
	elif manual_input_enabled:
		throttle_demand = maxf(Input.get_action_strength("boat_accelerate"), Input.get_action_strength("boat_brake"))
	return {
		"running": true,
		"power": clampf(0.15 + throttle_demand * 0.85, 0.0, 1.0),
		"throttle_demand": throttle_demand,
		"docked": is_port_docked,
	}


func has_engine() -> bool:
	return not _sailboat_active and propulsion_type == PropulsionType.POWERBOAT


func supports_sail_trim() -> bool:
	return _sailboat_active and _sailboat_body != null


func supports_engine_throttle() -> bool:
	return has_engine()


func supports_autopilot() -> bool:
	return not _sailboat_active


func supports_cargo() -> bool:
	return not _sailboat_active


func get_sailing_body() -> Node:
	return _sailboat_body if _sailboat_active else null


func is_sailing_active() -> bool:
	return _sailboat_active


func set_sailing_enabled(enabled: bool) -> bool:
	if enabled == _sailboat_active:
		return true
	if enabled and _sailboat_body == null:
		push_warning("BoatController cannot select sailboat: SailingBoat8m scene is not attached.")
		return false
	if enabled:
		disengage_autopilot()
		is_motion_paused = false
		_sailboat_body.set_as_top_level(true)
		if _sailboat_body.has_method("prepare_for_main_spawn"):
			var spawn_transform := _find_nearby_safe_sailing_spawn()
			_sailboat_body.call("prepare_for_main_spawn", spawn_transform)
		_sailboat_active = true
		_sailboat_body.call("set_vessel_active", true)
		_sailboat_body.call("set_keyboard_controls_enabled", manual_input_enabled)
		_set_powerboat_visuals_active(false)
		speed_mps = 0.0
	else:
		_sync_sailing_proxy()
		_sailboat_body.call("set_vessel_active", false)
		_sailboat_active = false
		is_motion_paused = false
		_set_powerboat_visuals_active(true)
		speed_mps = 0.0
	vessel_mode_changed.emit(_sailboat_active)
	return true


func _find_nearby_safe_sailing_spawn() -> Transform3D:
	var heading_basis := Basis(Vector3.UP, global_rotation.y)
	var fallback_transform := Transform3D(heading_basis, Vector3(global_position.x, 0.0, global_position.z))
	if is_instance_valid(_sailboat_spawn_point):
		fallback_transform = _sailboat_spawn_point.global_transform
	if _navigation_depth_provider == null or _sailboat_body == null:
		return fallback_transform

	var forward := -heading_basis.z
	forward.y = 0.0
	forward = forward.normalized() if forward.length_squared() > 0.0001 else Vector3.FORWARD
	var right := heading_basis.x
	right.y = 0.0
	right = right.normalized() if right.length_squared() > 0.0001 else Vector3.RIGHT
	var clearance := sailboat_spawn_clearance_m
	var candidate_offsets := [
		right * clearance,
		-right * clearance,
		forward * clearance,
		-forward * clearance,
		right * clearance * 1.5,
		-right * clearance * 1.5,
		forward * clearance * 1.5,
		-forward * clearance * 1.5,
	]
	for candidate_offset: Vector3 in candidate_offsets:
		var candidate := Transform3D(
			heading_basis,
			Vector3(global_position.x + candidate_offset.x, 0.0, global_position.z + candidate_offset.z)
		)
		if _is_sailing_spawn_depth_safe(candidate.origin) and _is_sailing_spawn_collision_free(candidate):
			return candidate
	return fallback_transform


func _is_sailing_spawn_depth_safe(world_position: Vector3) -> bool:
	if _navigation_depth_provider == null or _sailboat_body == null:
		return false
	var profile := _sailboat_body.get("profile") as Resource
	if profile == null:
		return false
	var draft_m := float(profile.get("draft_m"))
	var margin_m := float(_navigation_depth_provider.get("safety_margin_m"))
	var result: Dictionary = _navigation_depth_provider.call(
		"evaluate_world_position", world_position, draft_m, margin_m
	)
	return bool(result.get("valid", false)) \
		and str(result.get("data_state", "")) == "water" \
		and str(result.get("status", "")) == NavigationDepthProvider.STATUS_SAFE


func _is_sailing_spawn_collision_free(spawn_transform: Transform3D) -> bool:
	if _sailboat_body == null or get_world_3d() == null:
		return false
	var collision_shape := _sailboat_body.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if collision_shape == null or collision_shape.shape == null:
		return false
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = collision_shape.shape
	query.transform = spawn_transform * collision_shape.transform
	query.collision_mask = _sailboat_body.collision_mask
	query.exclude = [_sailboat_body.get_rid()]
	query.collide_with_areas = false
	return get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()


func set_sailing_manual_controls_enabled(enabled: bool) -> void:
	manual_input_enabled = enabled
	if _sailboat_body != null and _sailboat_active and _sailboat_body.has_method("set_keyboard_controls_enabled"):
		_sailboat_body.call("set_keyboard_controls_enabled", enabled)


func get_engine_audio_profile() -> EngineAudioProfileScript:
	return engine_audio_profile


func set_autopilot_speed_cap_mps(speed_cap_mps: float) -> void:
	if not is_finite(speed_cap_mps) or speed_cap_mps <= 0.0:
		_autopilot_speed_cap_mps = 0.0
	else:
		_autopilot_speed_cap_mps = maxf(max_speed_mps, speed_cap_mps)


func get_vessel_length_m() -> float:
	if _sailboat_active and _sailboat_body != null:
		var sail_profile: Resource = _sailboat_body.get("profile") as Resource
		if sail_profile != null:
			return float(sail_profile.get("vessel_length_m"))
	if draft_profile != null and draft_profile.vessel_length_m > 0.0:
		return draft_profile.vessel_length_m
	return DEFAULT_VESSEL_LENGTH_M


func get_vessel_beam_m() -> float:
	if _sailboat_active and _sailboat_body != null:
		var sail_profile: Resource = _sailboat_body.get("profile") as Resource
		if sail_profile != null:
			return float(sail_profile.get("vessel_beam_m"))
	if draft_profile != null and draft_profile.vessel_beam_m > 0.0:
		return draft_profile.vessel_beam_m
	return DEFAULT_VESSEL_BEAM_M


func get_vessel_dimensions_m() -> Vector3:
	if _sailboat_active and _sailboat_body != null:
		return Vector3(get_vessel_length_m(), get_vessel_beam_m(), 4.95)
	if draft_profile == null:
		return Vector3(DEFAULT_VESSEL_LENGTH_M, 0.0, DEFAULT_VESSEL_BEAM_M)
	return Vector3(draft_profile.vessel_length_m, draft_profile.vessel_beam_m, draft_profile.vessel_height_m)


func get_cargo_debug_snapshot() -> Dictionary:
	if _sailboat_active:
		return {
			"vessel_name": "8 m 帆船",
			"model_dimensions_m": get_vessel_dimensions_m(),
			"container_count": 0,
			"used_space_units": 0,
			"space_capacity_units": 0,
			"cargo_weight_kg": 0.0,
			"max_cargo_weight_kg": 0.0,
			"current_draft_m": get_current_draft_m(),
			"visual_cargo_sink_m": 0.0,
			"supports_cargo": false,
		}
	var cargo_loadout := get_node_or_null("CargoLoadout") as CargoLoadoutController
	if cargo_loadout != null:
		return cargo_loadout.get_debug_snapshot()
	var buoyancy := get_node_or_null("VisualRoot")
	return {
		"vessel_name": draft_profile.vessel_display_name if draft_profile != null else "未配置船型",
		"model_dimensions_m": get_vessel_dimensions_m(),
		"container_count": 0,
		"used_space_units": 0,
		"space_capacity_units": draft_profile.cargo_capacity_space_units if draft_profile != null else 0,
		"cargo_weight_kg": current_cargo_weight_kg,
		"max_cargo_weight_kg": draft_profile.max_cargo_weight_kg if draft_profile != null else 0.0,
		"current_draft_m": get_current_draft_m(),
		"visual_cargo_sink_m": float(buoyancy.call("get_visual_cargo_sink_m")) if buoyancy != null else 0.0,
	}


func set_port_docked(docked: bool) -> void:
	is_port_docked = docked
	if docked:
		speed_mps = 0.0
		is_motion_paused = true
		disengage_autopilot()


func _process(delta: float) -> void:
	if _sailboat_active and _sailboat_body != null:
		if manual_input_enabled and Input.is_action_just_pressed("boat_pause"):
			is_motion_paused = not is_motion_paused
		if _sailboat_body.freeze != is_motion_paused:
			_sailboat_body.freeze = is_motion_paused
			if not is_motion_paused:
				_sailboat_body.sleeping = false
		if _sailboat_body.has_method("set_keyboard_controls_enabled"):
			_sailboat_body.call("set_keyboard_controls_enabled", manual_input_enabled)
		_sync_sailing_proxy()
		return
	if is_port_docked:
		speed_mps = 0.0
		is_motion_paused = true
		return

	if manual_input_enabled and Input.is_action_just_pressed("boat_pause"):
		is_motion_paused = not is_motion_paused

	if manual_input_enabled and is_autopilot and _has_manual_drive_input():
		manual_takeover_requested.emit()
		if is_autopilot:
			disengage_autopilot()

	if is_motion_paused:
		return

	if is_autopilot:
		_update_autopilot_motion(delta)
	elif manual_input_enabled:
		_update_manual_controls(delta)

	var forward_direction := -global_transform.basis.z
	forward_direction.y = 0.0
	if forward_direction.length_squared() > 0.0001:
		global_position += forward_direction.normalized() * speed_mps * delta


func _update_manual_controls(delta: float) -> void:
	var throttle := Input.get_axis("boat_brake", "boat_accelerate")
	if absf(throttle) > 0.001:
		var target_speed := 0.0
		if throttle > 0.0:
			target_speed = max_speed_mps if speed_mps >= 0.0 else 0.0
		else:
			target_speed = -get_reverse_max_speed_mps() if speed_mps <= 0.0 else 0.0
		var changing_direction := speed_mps * target_speed < -0.001
		var slowing_down := absf(target_speed) < absf(speed_mps) or changing_direction
		var acceleration := braking_mps2 if slowing_down else acceleration_mps2
		speed_mps = move_toward(speed_mps, target_speed, acceleration * absf(throttle) * delta)
	else:
		speed_mps = move_toward(speed_mps, 0.0, coast_deceleration_mps2 * delta)

	var steering := float(Input.is_action_pressed("boat_turn_left"))
	steering -= float(Input.is_action_pressed("boat_turn_right"))
	var speed_factor := clampf(absf(speed_mps) / 3.0, 0.0, 1.0)
	if speed_factor > 0.0:
		var reverse_factor := signf(speed_mps)
		rotation.y += steering * reverse_factor * deg_to_rad(turn_rate_degrees_per_second) * speed_factor * delta


func submit_autopilot_command(steering_input: float, target_speed_mps: float) -> void:
	if not supports_autopilot():
		return
	_autopilot_steering_input = clampf(steering_input, -1.0, 1.0)
	_autopilot_target_speed_mps = clampf(target_speed_mps, 0.0, get_autopilot_speed_cap_mps())
	is_autopilot = true


func disengage_autopilot() -> void:
	is_autopilot = false
	_autopilot_steering_input = 0.0
	_autopilot_target_speed_mps = 0.0
	_autopilot_speed_cap_mps = 0.0


func _update_autopilot_motion(delta: float) -> void:
	var target_speed := clampf(_autopilot_target_speed_mps, 0.0, get_autopilot_speed_cap_mps())
	var acceleration := acceleration_mps2 if target_speed >= speed_mps else braking_mps2
	speed_mps = move_toward(speed_mps, target_speed, acceleration * delta)
	var speed_factor := clampf(absf(speed_mps) / 3.0, 0.0, 1.0)
	rotation.y += _autopilot_steering_input * deg_to_rad(turn_rate_degrees_per_second) * speed_factor * delta


func _has_manual_drive_input() -> bool:
	var focused_control := get_viewport().gui_get_focus_owner()
	if is_instance_valid(focused_control):
		return false
	return Input.get_axis("boat_brake", "boat_accelerate") != 0.0 \
		or Input.is_action_pressed("boat_turn_left") \
		or Input.is_action_pressed("boat_turn_right")


func _sync_sailing_proxy() -> void:
	if _sailboat_body == null:
		return
	var body_transform := _sailboat_body.get_global_transform_interpolated()
	var forward := -body_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		return
	forward = forward.normalized()
	var yaw := atan2(-forward.x, -forward.z)
	global_transform = Transform3D(
		Basis(Vector3.UP, yaw),
		Vector3(body_transform.origin.x, 0.0, body_transform.origin.z)
	)
	var local_velocity := _sailboat_body.global_basis.inverse() * _sailboat_body.linear_velocity
	speed_mps = -local_velocity.z


func _set_powerboat_visuals_active(active: bool) -> void:
	var visual_root := get_node_or_null("VisualRoot") as Node3D
	if visual_root == null:
		return
	var wake := visual_root.get_node_or_null("WakeSystem")
	var exhaust := visual_root.get_node_or_null("ExhaustSmokeSystem")
	if not active:
		if wake != null and wake.has_method("set_wake_enabled"):
			wake.call("set_wake_enabled", false)
		if exhaust != null and exhaust.has_method("_stop_and_clear_smoke"):
			exhaust.call("_stop_and_clear_smoke")
	visual_root.visible = active
	visual_root.process_mode = Node.PROCESS_MODE_INHERIT if active else Node.PROCESS_MODE_DISABLED
	if active and wake != null and wake.has_method("set_wake_enabled"):
		wake.call("set_wake_enabled", true)

