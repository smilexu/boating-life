extends RefCounted
## Lightweight, deterministic helpers for the independent SailboatLab model.

const MIN_AIR_SPEED_MPS := 0.01


static func headsail_clew_from_sheet(tack_local_m: Vector3, neutral_clew_local_m: Vector3, sheet_angle_rad: float) -> Vector3:
	if (
		not _finite_vector3(tack_local_m)
		or not _finite_vector3(neutral_clew_local_m)
		or not is_finite(sheet_angle_rad)
	):
		return neutral_clew_local_m
	# The forestay/head/tack stay in place. Sheet the Clew around the Tack in the
	# horizontal plane, preserving the foot length and keeping it above deck.
	var tack_to_clew := neutral_clew_local_m - tack_local_m
	return tack_local_m + Basis(Vector3.UP, sheet_angle_rad) * tack_to_clew


static func triangular_sail_centroid(head_local_m: Vector3, tack_local_m: Vector3, clew_local_m: Vector3) -> Vector3:
	return (head_local_m + tack_local_m + clew_local_m) / 3.0


static func triangular_sail_area_m2(head_local_m: Vector3, tack_local_m: Vector3, clew_local_m: Vector3) -> float:
	if not _finite_vector3(head_local_m) or not _finite_vector3(tack_local_m) or not _finite_vector3(clew_local_m):
		return 0.0
	return 0.5 * (tack_local_m - head_local_m).cross(clew_local_m - head_local_m).length()


static func calculate_apparent_wind(
	air_velocity_world_mps: Vector3,
	boat_linear_velocity_world_mps: Vector3,
	boat_angular_velocity_world_rad_s: Vector3,
	sail_center_from_com_world_m: Vector3,
	body_basis: Basis
) -> Dictionary:
	var sail_point_velocity := (
		boat_linear_velocity_world_mps
		+ boat_angular_velocity_world_rad_s.cross(sail_center_from_com_world_m)
	)
	var apparent_world := air_velocity_world_mps - sail_point_velocity
	var apparent_local := body_basis.inverse() * apparent_world
	var horizontal_speed := Vector2(apparent_local.x, apparent_local.z).length()
	var valid := is_finite(horizontal_speed) and horizontal_speed >= MIN_AIR_SPEED_MPS
	var apparent_from_angle := 0.0
	var windward_side := "无有效视风"
	if valid:
		# Signed angle from the bow (-Z); positive angles are from starboard (+X).
		apparent_from_angle = rad_to_deg(atan2(-apparent_local.x, apparent_local.z))
		if apparent_from_angle > 0.5:
			windward_side = "右舷来风"
		elif apparent_from_angle < -0.5:
			windward_side = "左舷来风"
		else:
			windward_side = "船首/船尾方向来风"
	return {
		"sail_point_velocity_world_mps": sail_point_velocity,
		"apparent_velocity_world_mps": apparent_world,
		"apparent_velocity_local_mps": apparent_local,
		"apparent_speed_mps": horizontal_speed,
		"apparent_from_angle_degrees": apparent_from_angle,
		"windward_side": windward_side,
		"valid": valid,
	}


static func calculate_sail_forces(
	apparent_velocity_local_mps: Vector3,
	sail_angle_rad: float,
	sail_area_m2: float,
	air_density_kg_m3: float = 1.225,
	maximum_lift_coefficient: float = 1.25,
	stall_angle_rad: float = 0.384,
	base_drag_coefficient: float = 0.08,
	induced_drag_factor: float = 0.55,
	flat_plate_drag_factor: float = 0.90,
	no_sail_wind_from_angle_rad: float = deg_to_rad(35.0),
	full_lift_wind_from_angle_rad: float = deg_to_rad(50.0),
	wrong_side_lift_retention: float = 1.0
) -> Dictionary:
	## Backward-compatible mainsail API. A centred boom/chord points aft (+Z)
	## and positive trim swings toward starboard (+X).
	return calculate_sail_forces_for_chord(
		apparent_velocity_local_mps,
		Vector2(sin(sail_angle_rad), cos(sail_angle_rad)),
		sail_area_m2,
		air_density_kg_m3,
		maximum_lift_coefficient,
		stall_angle_rad,
		base_drag_coefficient,
		induced_drag_factor,
		flat_plate_drag_factor,
		no_sail_wind_from_angle_rad,
		full_lift_wind_from_angle_rad,
		wrong_side_lift_retention
	)


static func calculate_sail_forces_for_chord(
	 apparent_velocity_local_mps: Vector3,
	 chord_direction_xz: Vector2,
	 sail_area_m2: float,
	 air_density_kg_m3: float = 1.225,
	 maximum_lift_coefficient: float = 1.25,
	 stall_angle_rad: float = 0.384,
	 base_drag_coefficient: float = 0.08,
	 induced_drag_factor: float = 0.55,
	 flat_plate_drag_factor: float = 0.90,
	 no_sail_wind_from_angle_rad: float = deg_to_rad(35.0),
	 full_lift_wind_from_angle_rad: float = deg_to_rad(50.0),
	 wrong_side_lift_retention: float = 1.0
) -> Dictionary:
	var result := {
		"valid": false,
		"apparent_speed_mps": 0.0,
		"dynamic_pressure_pa": 0.0,
		"angle_of_attack_rad": 0.0,
		"apparent_wind_from_angle_rad": 0.0,
		"luffing_scale": 0.0,
		"windward_sheet_alignment": 0.0,
		"wrong_side_lift_scale": 1.0,
		"sheet_efficiency_scale": 1.0,
		"cl": 0.0,
		"cd": 0.0,
		"lift_force_local_n": Vector3.ZERO,
		"drag_force_local_n": Vector3.ZERO,
		"net_force_local_n": Vector3.ZERO,
	}
	if (
		not _finite_vector3(apparent_velocity_local_mps)
		or not _finite_vector2(chord_direction_xz)
		or not is_finite(sail_area_m2)
		or not is_finite(air_density_kg_m3)
		or not is_finite(maximum_lift_coefficient)
		or not is_finite(stall_angle_rad)
		or not is_finite(no_sail_wind_from_angle_rad)
		or not is_finite(full_lift_wind_from_angle_rad)
		or not is_finite(wrong_side_lift_retention)
		or sail_area_m2 <= 0.0
		or air_density_kg_m3 <= 0.0
		or maximum_lift_coefficient <= 0.0
		or stall_angle_rad <= 0.0
	):
		return result

	var apparent_xz := Vector2(apparent_velocity_local_mps.x, apparent_velocity_local_mps.z)
	var speed := apparent_xz.length()
	if speed < MIN_AIR_SPEED_MPS:
		return result
	var flow_direction := apparent_xz / speed
	# The aerodynamic chord is an unoriented line; keep its signed attack angle
	# in [-90°, 90°]. The caller supplies the actual local XZ chord direction,
	# allowing a jib and a boom-controlled mainsail to share the same model.
	if chord_direction_xz.length_squared() < 0.000001:
		return result
	var chord_direction := chord_direction_xz.normalized()
	var cross_y := chord_direction.y * flow_direction.x - chord_direction.x * flow_direction.y
	var dot_value := chord_direction.dot(flow_direction)
	var attack_angle := atan2(cross_y, dot_value)
	if attack_angle > PI * 0.5:
		attack_angle -= PI
	elif attack_angle < -PI * 0.5:
		attack_angle += PI

	var cl := lift_coefficient(attack_angle, maximum_lift_coefficient, stall_angle_rad)
	# The sail luffs while pointed into the apparent wind. Lift fades smoothly
	# across the no-sail sector; drag still follows the actual airflow direction.
	var wind_from_angle := absf(atan2(-flow_direction.x, flow_direction.y))
	var no_sail_angle := clampf(no_sail_wind_from_angle_rad, 0.0, PI * 0.49)
	var full_lift_angle := clampf(full_lift_wind_from_angle_rad, no_sail_angle + 0.001, PI)
	var luff_fraction := clampf((wind_from_angle - no_sail_angle) / (full_lift_angle - no_sail_angle), 0.0, 1.0)
	var luffing_scale := luff_fraction * luff_fraction * (3.0 - 2.0 * luff_fraction)
	# Treat the sail's foot/chord as a directed geometric vector for the
	# sheet-side check. If its lateral component points toward the wind source,
	# lift is smoothly reduced as a game-level backing penalty. Drag remains
	# active so following and quartering wind can still drive the boat by windage.
	var wind_from_lateral := -flow_direction.x
	var boom_lateral := chord_direction.x
	var windward_sheet_alignment := maxf(wind_from_lateral * boom_lateral, 0.0)
	var wrong_side_fraction := _smooth_step(0.05, 0.45, windward_sheet_alignment)
	var wrong_side_lift_scale := lerpf(1.0, clampf(wrong_side_lift_retention, 0.0, 1.0), wrong_side_fraction)
	var sheet_efficiency_scale := luffing_scale * wrong_side_lift_scale
	cl *= sheet_efficiency_scale
	var cd := drag_coefficient(
		attack_angle,
		cl,
		base_drag_coefficient,
		induced_drag_factor,
		flat_plate_drag_factor
	)
	var dynamic_pressure := 0.5 * air_density_kg_m3 * speed * speed
	var force_scale := dynamic_pressure * sail_area_m2
	# In local XZ, UP × flow = (flow.z, -flow.x). Signed CL mirrors the lift
	# across port/starboard while keeping the forward lift component consistent.
	var lift_direction := Vector2(flow_direction.y, -flow_direction.x)
	var lift_force := Vector3(lift_direction.x * force_scale * cl, 0.0, lift_direction.y * force_scale * cl)
	var drag_force := Vector3(flow_direction.x * force_scale * cd, 0.0, flow_direction.y * force_scale * cd)
	var net_force := lift_force + drag_force
	result["valid"] = true
	result["apparent_speed_mps"] = speed
	result["dynamic_pressure_pa"] = dynamic_pressure
	result["angle_of_attack_rad"] = attack_angle
	result["apparent_wind_from_angle_rad"] = wind_from_angle
	result["luffing_scale"] = luffing_scale
	result["windward_sheet_alignment"] = windward_sheet_alignment
	result["wrong_side_lift_scale"] = wrong_side_lift_scale
	result["sheet_efficiency_scale"] = sheet_efficiency_scale
	result["cl"] = cl
	result["cd"] = cd
	result["lift_force_local_n"] = lift_force
	result["drag_force_local_n"] = drag_force
	result["net_force_local_n"] = net_force
	return result


static func lift_coefficient(
	angle_of_attack_rad: float,
	maximum_lift_coefficient: float = 1.25,
	stall_angle_rad: float = 0.384
) -> float:
	if not is_finite(angle_of_attack_rad) or not is_finite(maximum_lift_coefficient) or not is_finite(stall_angle_rad):
		return 0.0
	var safe_stall := clampf(stall_angle_rad, 0.01, PI * 0.49)
	var safe_peak := clampf(maximum_lift_coefficient, 0.0, 2.5)
	var absolute_angle := minf(absf(angle_of_attack_rad), PI * 0.5)
	var magnitude := 0.0
	if absolute_angle <= safe_stall:
		magnitude = safe_peak * sin((PI * 0.5) * absolute_angle / safe_stall)
	else:
		var post_stall_fraction := clampf(
			(absolute_angle - safe_stall) / (PI * 0.5 - safe_stall),
			0.0,
			1.0
		)
		magnitude = safe_peak * cos(post_stall_fraction * PI * 0.5)
	return signf(angle_of_attack_rad) * magnitude


static func drag_coefficient(
	angle_of_attack_rad: float,
	cl: float,
	base_drag_coefficient: float = 0.08,
	induced_drag_factor: float = 0.55,
	flat_plate_drag_factor: float = 0.90
) -> float:
	if not is_finite(angle_of_attack_rad) or not is_finite(cl):
		return 0.0
	var base := maxf(base_drag_coefficient, 0.0)
	var induced := maxf(induced_drag_factor, 0.0) * cl * cl
	var flat_plate := maxf(flat_plate_drag_factor, 0.0) * pow(sin(minf(absf(angle_of_attack_rad), PI * 0.5)), 2.0)
	return clampf(base + induced + flat_plate, 0.0, 2.0)


static func side_resistance_force_local(
	local_velocity_mps: Vector3,
	linear_coefficient_n_s_m: float,
	quadratic_coefficient_n_s2_m2: float,
	maximum_force_n: float
) -> Vector3:
	if not _finite_vector3(local_velocity_mps):
		return Vector3.ZERO
	if not is_finite(linear_coefficient_n_s_m) or not is_finite(quadratic_coefficient_n_s2_m2) or not is_finite(maximum_force_n):
		return Vector3.ZERO
	var lateral_speed := local_velocity_mps.x
	if is_zero_approx(lateral_speed):
		return Vector3.ZERO
	var force_x := (
		-maxf(linear_coefficient_n_s_m, 0.0) * lateral_speed
		-maxf(quadratic_coefficient_n_s2_m2, 0.0) * absf(lateral_speed) * lateral_speed
	)
	return Vector3(clampf(force_x, -maxf(maximum_force_n, 0.0), maxf(maximum_force_n, 0.0)), 0.0, 0.0)


static func move_sail_angle_toward(
	current_angle_rad: float,
	target_angle_rad: float,
	step_seconds: float,
	maximum_rotation_speed_rad_s: float,
	minimum_angle_rad: float,
	maximum_angle_rad: float
) -> float:
	if not is_finite(current_angle_rad) or not is_finite(target_angle_rad):
		return clampf(0.0, minimum_angle_rad, maximum_angle_rad)
	var low := minf(minimum_angle_rad, maximum_angle_rad)
	var high := maxf(minimum_angle_rad, maximum_angle_rad)
	var current := clampf(current_angle_rad, low, high)
	var target := clampf(target_angle_rad, low, high)
	var max_step := maxf(maximum_rotation_speed_rad_s, 0.0) * maxf(step_seconds, 0.0)
	return move_toward(current, target, max_step)


static func _finite_vector3(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)


static func _finite_vector2(value: Vector2) -> bool:
	return is_finite(value.x) and is_finite(value.y)


static func _smooth_step(edge0: float, edge1: float, value: float) -> float:
	if edge1 <= edge0:
		return 1.0 if value >= edge1 else 0.0
	var t := clampf((value - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
