extends RefCounted
## Compass and boat-relative display math shared by SailboatLab and its tests.

const MIN_DIRECTION_LENGTH_SQUARED := 0.000001
const MIN_COG_SPEED_MPS := 0.15
const METERS_PER_SECOND_TO_KNOTS := 1.9438444924406


static func heading_degrees_from_forward(forward_world: Vector3) -> float:
	return bearing_degrees_from_vector(forward_world)


static func wind_from_bearing_from_wind_to(wind_to_world_mps: Vector3) -> float:
	return bearing_degrees_from_vector(-wind_to_world_mps)


static func bearing_degrees_from_vector(direction_world: Vector3) -> float:
	var horizontal := Vector2(direction_world.x, direction_world.z)
	if horizontal.length_squared() < MIN_DIRECTION_LENGTH_SQUARED:
		return 0.0
	return fposmod(rad_to_deg(atan2(horizontal.x, -horizontal.y)), 360.0)


static func signed_relative_bearing_degrees(bearing_degrees: float, reference_degrees: float) -> float:
	return wrapf(bearing_degrees - reference_degrees, -180.0, 180.0)


static func relative_bearing_from_world_vector(direction_world: Vector3, heading_degrees: float) -> float:
	return signed_relative_bearing_degrees(bearing_degrees_from_vector(direction_world), heading_degrees)


static func compass_bearing_to_screen_direction(relative_bearing_degrees: float) -> Vector2:
	var angle := deg_to_rad(relative_bearing_degrees)
	return Vector2(sin(angle), -cos(angle))


static func boom_direction_from_sail_angle(sail_angle_rad: float) -> Vector2:
	return Vector2(sin(sail_angle_rad), cos(sail_angle_rad))


static func sog_knots(speed_mps: float) -> float:
	return maxf(speed_mps, 0.0) * METERS_PER_SECOND_TO_KNOTS


static func cog_is_reliable(horizontal_speed_mps: float) -> bool:
	return is_finite(horizontal_speed_mps) and horizontal_speed_mps >= MIN_COG_SPEED_MPS
