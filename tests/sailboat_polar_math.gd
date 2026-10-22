extends RefCounted
## Small deterministic helpers used only by offline polar diagnostics.


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
	var command := proportional_gain * heading_error_degrees - derivative_gain * compass_yaw_rate_degrees_s
	return clampf(command, -absf(maximum_rudder_degrees), absf(maximum_rudder_degrees))


static func upwind_vmg_mps(horizontal_velocity_world_mps: Vector3, wind_from_degrees: float) -> float:
	var angle := deg_to_rad(wind_from_degrees)
	var toward_wind_source := Vector3(sin(angle), 0.0, -cos(angle))
	var horizontal_velocity := Vector3(horizontal_velocity_world_mps.x, 0.0, horizontal_velocity_world_mps.z)
	return horizontal_velocity.dot(toward_wind_source)
