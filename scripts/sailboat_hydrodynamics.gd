extends RefCounted
## Lightweight, deterministic foil and hull-resistance helpers for SailboatLab.

const MIN_WATER_SPEED_MPS := 0.02
const MIN_FORWARD_SPEED_FOR_SIDESLIP_MPS := 0.15


static func calculate_foil_forces(
	relative_velocity_local_mps: Vector3,
	foil_angle_rad: float,
	area_m2: float,
	water_density_kg_m3: float = 1025.0,
	lift_slope_per_rad: float = 3.2,
	maximum_lift_coefficient: float = 1.2,
	stall_angle_rad: float = 0.45,
	base_drag_coefficient: float = 0.025,
	induced_drag_factor: float = 0.12,
	flat_plate_drag_factor: float = 0.85,
	maximum_force_n: float = 0.0
) -> Dictionary:
	var result := {
		"valid": false,
		"water_speed_mps": 0.0,
		"side_slip_angle_rad": 0.0,
		"angle_of_attack_rad": 0.0,
		"dynamic_pressure_pa": 0.0,
		"cl": 0.0,
		"cd": 0.0,
		"lift_force_local_n": Vector3.ZERO,
		"drag_force_local_n": Vector3.ZERO,
		"net_force_local_n": Vector3.ZERO,
	}
	if (
		not _finite_vector3(relative_velocity_local_mps)
		or not is_finite(foil_angle_rad)
		or not is_finite(area_m2)
		or not is_finite(water_density_kg_m3)
		or not is_finite(lift_slope_per_rad)
		or not is_finite(maximum_lift_coefficient)
		or not is_finite(stall_angle_rad)
		or not is_finite(base_drag_coefficient)
		or not is_finite(induced_drag_factor)
		or not is_finite(flat_plate_drag_factor)
		or area_m2 <= 0.0
		or water_density_kg_m3 <= 0.0
		or maximum_lift_coefficient <= 0.0
	):
		return result

	var boat_velocity_xz := Vector2(relative_velocity_local_mps.x, relative_velocity_local_mps.z)
	var water_speed := boat_velocity_xz.length()
	if water_speed < MIN_WATER_SPEED_MPS:
		return result
	var flow_direction := -boat_velocity_xz / water_speed
	var forward_sign := -1.0 if relative_velocity_local_mps.z > 0.0 else 1.0
	var side_slip := atan2(
		relative_velocity_local_mps.x * forward_sign,
		maxf(absf(relative_velocity_local_mps.z), MIN_FORWARD_SPEED_FOR_SIDESLIP_MPS)
	)
	var effective_angle := clampf(side_slip + foil_angle_rad, -PI * 0.5, PI * 0.5)
	var safe_stall := clampf(stall_angle_rad, 0.05, PI * 0.49)
	var safe_max_cl := clampf(maximum_lift_coefficient, 0.0, 1.8)
	var safe_lift_slope := clampf(lift_slope_per_rad, 0.0, 8.0)
	var linear_cl := safe_lift_slope * effective_angle
	var absolute_angle := absf(effective_angle)
	var cl_magnitude := 0.0
	if absolute_angle <= safe_stall:
		cl_magnitude = minf(safe_lift_slope * absolute_angle, safe_max_cl)
	else:
		# A stalled keel still provides bounded side force; it does not disappear
		# at 90 degrees. Flat-plate drag supplies most of the force at large slip.
		var stalled_fraction := clampf((absolute_angle - safe_stall) / (PI * 0.5 - safe_stall), 0.0, 1.0)
		var cl_at_stall := minf(safe_lift_slope * safe_stall, safe_max_cl)
		cl_magnitude = cl_at_stall * (0.82 + 0.18 * cos(stalled_fraction * PI * 0.5))
	var cl := signf(linear_cl) * cl_magnitude
	var cd := clampf(
		maxf(base_drag_coefficient, 0.0)
		+ maxf(induced_drag_factor, 0.0) * cl * cl
		+ maxf(flat_plate_drag_factor, 0.0) * sin(absolute_angle) * sin(absolute_angle),
		0.0,
		2.0
	)
	var dynamic_pressure := 0.5 * water_density_kg_m3 * water_speed * water_speed
	var scale := dynamic_pressure * area_m2
	# In local XZ, rotate incoming flow clockwise in this handed convention.
	# For forward motion and positive (starboard) rudder, this yields negative X
	# force at the stern, hence negative yaw torque and a starboard turn.
	var lift_direction := Vector2(-flow_direction.y, flow_direction.x)
	var lift_force := Vector3(lift_direction.x * scale * cl, 0.0, lift_direction.y * scale * cl)
	var drag_force := Vector3(flow_direction.x * scale * cd, 0.0, flow_direction.y * scale * cd)
	var net_force := lift_force + drag_force
	if maximum_force_n > 0.0 and net_force.length() > maximum_force_n:
		net_force = net_force.normalized() * maximum_force_n
		var total_length := lift_force.length() + drag_force.length()
		if total_length > 0.0:
			lift_force = net_force * (lift_force.length() / total_length)
			drag_force = net_force - lift_force
	result["valid"] = true
	result["water_speed_mps"] = water_speed
	result["side_slip_angle_rad"] = side_slip
	result["angle_of_attack_rad"] = effective_angle
	result["dynamic_pressure_pa"] = dynamic_pressure
	result["cl"] = cl
	result["cd"] = cd
	result["lift_force_local_n"] = lift_force
	result["drag_force_local_n"] = drag_force
	result["net_force_local_n"] = net_force
	return result


static func calculate_hull_resistance(
	local_velocity_mps: Vector3,
	longitudinal_linear_n_s_m: float,
	longitudinal_quadratic_n_s2_m2: float,
	lateral_linear_n_s_m: float,
	lateral_quadratic_n_s2_m2: float,
	maximum_force_n: float = 0.0
) -> Vector3:
	if (
		not _finite_vector3(local_velocity_mps)
		or not is_finite(longitudinal_linear_n_s_m)
		or not is_finite(longitudinal_quadratic_n_s2_m2)
		or not is_finite(lateral_linear_n_s_m)
		or not is_finite(lateral_quadratic_n_s2_m2)
	):
		return Vector3.ZERO
	var force := Vector3(
		_axis_resistance(local_velocity_mps.x, lateral_linear_n_s_m, lateral_quadratic_n_s2_m2),
		0.0,
		_axis_resistance(local_velocity_mps.z, longitudinal_linear_n_s_m, longitudinal_quadratic_n_s2_m2)
	)
	if maximum_force_n > 0.0 and force.length() > maximum_force_n:
		force = force.normalized() * maximum_force_n
	return force


static func move_rudder_angle_toward(
	current_angle_rad: float,
	target_angle_rad: float,
	step_seconds: float,
	maximum_rotation_speed_rad_s: float,
	maximum_angle_rad: float
) -> float:
	if not is_finite(current_angle_rad) or not is_finite(target_angle_rad):
		return 0.0
	var limit := maxf(maximum_angle_rad, 0.0)
	var current := clampf(current_angle_rad, -limit, limit)
	var target := clampf(target_angle_rad, -limit, limit)
	var max_step := maxf(maximum_rotation_speed_rad_s, 0.0) * maxf(step_seconds, 0.0)
	return move_toward(current, target, max_step)


static func _axis_resistance(speed_mps: float, linear: float, quadratic: float) -> float:
	return -maxf(linear, 0.0) * speed_mps - maxf(quadratic, 0.0) * absf(speed_mps) * speed_mps


static func _finite_vector3(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)
