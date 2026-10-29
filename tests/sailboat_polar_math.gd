extends RefCounted
## Backwards-compatible test alias for the P1 production test helpers.

const MATH := preload("res://scripts/polar_test_math.gd")

static func target_heading_degrees(wind_from_degrees: float, signed_twa_degrees: float) -> float:
	return MATH.target_heading_degrees(wind_from_degrees, signed_twa_degrees)

static func relative_twa_degrees(wind_from_degrees: float, heading_degrees: float) -> float:
	return MATH.relative_twa_degrees(wind_from_degrees, heading_degrees)

static func rudder_command_degrees(heading_error_degrees: float, compass_yaw_rate_degrees_s: float, proportional_gain: float, derivative_gain: float, maximum_rudder_degrees: float) -> float:
	return MATH.rudder_command_degrees(heading_error_degrees, compass_yaw_rate_degrees_s, proportional_gain, derivative_gain, maximum_rudder_degrees)

static func upwind_vmg_mps(horizontal_velocity_world_mps: Vector3, wind_from_degrees: float) -> float:
	var wind_angle := deg_to_rad(wind_from_degrees)
	var upwind := Vector3(sin(wind_angle), 0.0, -cos(wind_angle))
	var velocity := Vector3(horizontal_velocity_world_mps.x, 0.0, horizontal_velocity_world_mps.z)
	return velocity.dot(upwind)
