class_name BoatController
extends Node3D

## Navigation transform for the player boat.
## One Godot unit represents one meter. The motion origin sits on the calm-water
## plane at the boat centerline; the normalized model's bow points along local
## -Z. VisualRoot is separate so wave-driven height, pitch, and roll do not
## change the navigation transform.
## Visual models are corrected below this node so the navigation axes stay stable.

const DEFAULT_VESSEL_LENGTH_M := 5.263
const DEFAULT_VESSEL_BEAM_M := 2.327

@export_category("Movement")
@export_range(1.0, 20.0, 0.5) var max_speed_mps := 12.0
@export_range(0.5, 10.0, 0.1) var acceleration_mps2 := 2.8
@export_range(0.5, 12.0, 0.1) var braking_mps2 := 4.5
@export_range(0.0, 2.0, 0.05) var coast_deceleration_mps2 := 0.18
@export_range(5.0, 60.0, 1.0) var turn_rate_degrees_per_second := 28.0
@export_range(1.0, 12.0, 0.5) var cruise_speed_mps := 7.0

@export_category("Navigation reference · gameplay only")
@export var draft_profile: VesselDraftProfile
@export_range(0.0, 1000000.0, 1.0, "or_greater") var current_cargo_weight_kg := 0.0

var speed_mps := 0.0
var is_autopilot := false
var is_motion_paused := false
var is_port_docked := false

var _autopilot_heading_radians := 0.0


func get_current_draft_m() -> float:
	if draft_profile == null:
		return -1.0
	return draft_profile.draft_for_cargo_weight(current_cargo_weight_kg)


func get_vessel_length_m() -> float:
	if draft_profile != null and draft_profile.vessel_length_m > 0.0:
		return draft_profile.vessel_length_m
	return DEFAULT_VESSEL_LENGTH_M


func get_vessel_beam_m() -> float:
	if draft_profile != null and draft_profile.vessel_beam_m > 0.0:
		return draft_profile.vessel_beam_m
	return DEFAULT_VESSEL_BEAM_M


func get_vessel_dimensions_m() -> Vector3:
	if draft_profile == null:
		return Vector3(DEFAULT_VESSEL_LENGTH_M, 0.0, DEFAULT_VESSEL_BEAM_M)
	return Vector3(draft_profile.vessel_length_m, draft_profile.vessel_beam_m, draft_profile.vessel_height_m)


func get_cargo_debug_snapshot() -> Dictionary:
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
		is_autopilot = false


func _process(delta: float) -> void:
	if is_port_docked:
		speed_mps = 0.0
		is_motion_paused = true
		return

	if Input.is_action_just_pressed("boat_pause"):
		is_motion_paused = not is_motion_paused

	if Input.is_action_just_pressed("boat_toggle_autopilot"):
		_toggle_autopilot()

	if is_motion_paused:
		return

	if is_autopilot:
		_update_autopilot(delta)
	else:
		_update_manual_controls(delta)

	var forward_direction := -global_transform.basis.z
	forward_direction.y = 0.0
	if forward_direction.length_squared() > 0.0001:
		global_position += forward_direction.normalized() * speed_mps * delta


func _update_manual_controls(delta: float) -> void:
	var throttle := Input.get_axis("boat_brake", "boat_accelerate")
	if throttle > 0.0:
		speed_mps = move_toward(speed_mps, max_speed_mps, acceleration_mps2 * throttle * delta)
	elif throttle < 0.0:
		speed_mps = move_toward(speed_mps, 0.0, braking_mps2 * absf(throttle) * delta)
	else:
		speed_mps = move_toward(speed_mps, 0.0, coast_deceleration_mps2 * delta)

	var steering := float(Input.is_action_pressed("boat_turn_left"))
	steering -= float(Input.is_action_pressed("boat_turn_right"))
	var speed_factor := clampf(absf(speed_mps) / 3.0, 0.0, 1.0)
	if speed_factor > 0.0:
		var reverse_factor := signf(speed_mps)
		rotation.y += steering * reverse_factor * deg_to_rad(turn_rate_degrees_per_second) * speed_factor * delta


func _update_autopilot(delta: float) -> void:
	speed_mps = move_toward(speed_mps, cruise_speed_mps, acceleration_mps2 * delta)
	var heading_error := wrapf(_autopilot_heading_radians - rotation.y, -PI, PI)
	var max_heading_change := deg_to_rad(turn_rate_degrees_per_second) * delta
	rotation.y += clampf(heading_error, -max_heading_change, max_heading_change)


func _toggle_autopilot() -> void:
	is_autopilot = not is_autopilot
	if is_autopilot:
		_autopilot_heading_radians = rotation.y

