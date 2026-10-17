class_name DolphinLeapTrajectory
extends RefCounted

## Shared, time-based ballistic math for authoritative dolphin state and its
## client visual. Height is measured from a fixed launch-time water surface.

static func initial_vertical_speed(apex_height_m: float, start_depth_m: float, gravity_mps2: float) -> float:
	var total_rise := maxf(0.0, apex_height_m) + maxf(0.0, start_depth_m)
	return sqrt(2.0 * maxf(0.001, gravity_mps2) * total_rise)


static func water_entry_time(initial_vertical_speed_mps: float, start_depth_m: float, gravity_mps2: float) -> float:
	var gravity := maxf(0.001, gravity_mps2)
	var depth := maxf(0.0, start_depth_m)
	var discriminant := maxf(0.0, initial_vertical_speed_mps * initial_vertical_speed_mps - 2.0 * gravity * depth)
	return (initial_vertical_speed_mps + sqrt(discriminant)) / gravity


static func height_at(start_world_y: float, initial_vertical_speed_mps: float, gravity_mps2: float, elapsed_seconds: float) -> float:
	var time := maxf(0.0, elapsed_seconds)
	return start_world_y + initial_vertical_speed_mps * time - 0.5 * gravity_mps2 * time * time


static func vertical_speed_at(initial_vertical_speed_mps: float, gravity_mps2: float, elapsed_seconds: float) -> float:
	return initial_vertical_speed_mps - gravity_mps2 * maxf(0.0, elapsed_seconds)


static func horizontal_position_at(origin_xz: Vector2, direction: Vector2, speed_mps: float, elapsed_seconds: float) -> Vector2:
	return origin_xz + direction.normalized() * maxf(0.0, speed_mps) * maxf(0.0, elapsed_seconds)
