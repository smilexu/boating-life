extends RefCounted
## Small pure helpers used by the offline Polar test tool only.

const KNOTS_PER_MPS := 1.9438444924406


static func target_heading_degrees(wind_from_degrees: float, signed_twa_degrees: float) -> float:
	return fposmod(wind_from_degrees - signed_twa_degrees, 360.0)


static func relative_twa_degrees(wind_from_degrees: float, heading_degrees: float) -> float:
	return wrapf(wind_from_degrees - heading_degrees, -180.0, 180.0)


static func rudder_command_degrees(
	heading_error_degrees: float,
	compass_yaw_rate_degrees_s: float,
	proportional_gain: float,
	derivative_gain: float,
	maximum_rudder_degrees: float
) -> float:
	return clampf(
		proportional_gain * heading_error_degrees - derivative_gain * compass_yaw_rate_degrees_s,
		-absf(maximum_rudder_degrees),
		absf(maximum_rudder_degrees)
	)


static func target_course_forward(target_heading_degrees_value: float) -> Vector3:
	var heading := deg_to_rad(target_heading_degrees_value)
	return Vector3(sin(heading), 0.0, -cos(heading))


static func target_course_vmg_kn(horizontal_velocity_world_mps: Vector3, target_heading_degrees_value: float) -> float:
	var velocity := Vector3(horizontal_velocity_world_mps.x, 0.0, horizontal_velocity_world_mps.z)
	return velocity.dot(target_course_forward(target_heading_degrees_value)) * KNOTS_PER_MPS


static func relative_leeway_degrees(longitudinal_speed_mps: float, lateral_speed_mps: float) -> float:
	if not is_finite(longitudinal_speed_mps) or not is_finite(lateral_speed_mps):
		return NAN
	if Vector2(longitudinal_speed_mps, lateral_speed_mps).length() < 0.15:
		return NAN
	return rad_to_deg(atan2(lateral_speed_mps, longitudinal_speed_mps))
