class_name BoatController
extends Node3D

## Navigation transform for the player boat.
## One Godot unit represents one meter. The motion origin sits on the calm-water
## plane at the boat centerline; the normalized model's bow points along local
## -Z. VisualRoot is separate so wave-driven height, pitch, and roll do not
## change the navigation transform.
## The supplied FBX bow already faces -Z. It is scaled 5x; its resulting length
## is about 5.3 m, with the model origin lowered 0.5 m so the hull straddles the waterline.

@export_category("Movement")
@export_range(1.0, 20.0, 0.5) var max_speed_mps := 12.0
@export_range(0.5, 10.0, 0.1) var acceleration_mps2 := 2.8
@export_range(0.5, 12.0, 0.1) var braking_mps2 := 4.5
@export_range(0.0, 2.0, 0.05) var coast_deceleration_mps2 := 0.18
@export_range(5.0, 60.0, 1.0) var turn_rate_degrees_per_second := 28.0
@export_range(1.0, 12.0, 0.5) var cruise_speed_mps := 7.0

var speed_mps := 0.0
var is_autopilot := false
var is_motion_paused := false

var _autopilot_heading_radians := 0.0


func _process(delta: float) -> void:
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

