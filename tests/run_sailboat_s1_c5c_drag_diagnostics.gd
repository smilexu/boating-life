extends SceneTree
## Offline S1-C5c force and drag diagnostics using the production SailboatLab
## rigid body and force helpers. Per-case overrides touch only the instantiated
## test node, never the shared vessel Resource or normal game behavior.

const LAB_SCENE := preload("res://scenes/SailboatLab.tscn")
const PROFILE := preload("res://resources/sailing/sailboat_lab_profile.tres")
const HYDRO := preload("res://scripts/sailboat_hydrodynamics.gd")
const DATA_DIR := "res://docs/sailing/c5c_data"
const KNOTS_PER_MPS := 1.9438444924406
const FIXED_SEED := 481516
const SIMULATION_HZ := 60
const OFFLINE_TIME_SCALE := 8.0
const STEADY_CHECKPOINTS := [0.0, 2.0, 5.0, 10.0, 20.0, 30.0, 60.0, 120.0]
const SUMMARY_CHECKPOINTS := [30.0, 60.0, 120.0]
const ACCEL_WINDOW_TICKS := 30

var _lab: Node3D
var _boat: RigidBody3D
var _wind: Node
var _failures: Array[String] = []
var _run_count := 0
var _mode := "all"
var _started_usec := 0
var _steady_rows: Array[String] = []
var _speed_rows: Array[String] = []
var _sensitivity_rows: Array[String] = []
var _area_rows: Array[String] = []
var _original_physics_hz := 60
var _original_time_scale := 1.0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_started_usec = Time.get_ticks_usec()
	_original_physics_hz = Engine.physics_ticks_per_second
	_original_time_scale = Engine.time_scale
	# Keep each physics step at 1/60 s while advancing the offline-only test
	# clock faster than wall time. No production scene uses this setting.
	Engine.physics_ticks_per_second = int(SIMULATION_HZ * OFFLINE_TIME_SCALE)
	Engine.time_scale = OFFLINE_TIME_SCALE
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--phase="):
			_mode = argument.trim_prefix("--phase=")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DATA_DIR))
	if _mode == "steady" or _mode == "all":
		await _run_steady_state()
	if _mode == "drag" or _mode == "all":
		await _run_fixed_speed_drag_curve()
		await _run_natural_deceleration()
	if _mode == "sensitivity" or _mode == "all":
		await _run_drag_sensitivity()
	if _mode == "area" or _mode == "all":
		await _run_sail_area_sensitivity()
	if _mode not in ["steady", "drag", "sensitivity", "area", "all"]:
		_failures.append("Unknown phase '%s'. Use steady, drag, sensitivity, area, or all." % _mode)
	_write_outputs()
	var elapsed := float(Time.get_ticks_usec() - _started_usec) / 1_000_000.0
	Engine.physics_ticks_per_second = _original_physics_hz
	Engine.time_scale = _original_time_scale
	if _failures.is_empty():
		print("[S1-C5c] phase=%s dynamic_cases=%d wall=%.2fs output=docs/sailing/c5c_data/" % [_mode, _run_count, elapsed])
		quit(0)
	else:
		for failure in _failures:
			push_error("[S1-C5c] " + failure)
		quit(1)


func _run_steady_state() -> void:
	var configured := await _configure_lab(8.0, 270.0, 50.0, 0.0, {})
	if not configured:
		return
	var history_velocity: Array[Vector3] = []
	var history_explicit_forward: Array[float] = []
	var history_complete_forward: Array[float] = []
	var initial_position := _boat.global_position
	var initial_forward := -_boat.global_basis.z
	var max_abs_yaw_rate := 0.0
	var next_checkpoint := 0
	var initial := _steady_sample(0.0, initial_position, initial_forward, history_velocity, history_explicit_forward, history_complete_forward, max_abs_yaw_rate)
	_steady_rows.append(_csv_row(initial))
	next_checkpoint = 1
	var total_steps := 120 * SIMULATION_HZ
	for tick in range(1, total_steps + 1):
		await physics_frame
		var sim_time := float(tick) / float(SIMULATION_HZ)
		var snapshot: Dictionary = _boat.call("get_debug_snapshot")
		var velocity: Vector3 = snapshot.get("linear_velocity_mps", Vector3.ZERO)
		var breakdown := _force_breakdown(snapshot)
		var basis := _boat.global_basis
		var mass_value := float(snapshot.get("mass_kg", PROFILE.get("mass_kg")))
		var gravity_local := basis.inverse() * Vector3.DOWN * mass_value * _gravity()
		var buoyancy_local := basis.inverse() * Vector3.UP * float(snapshot.get("buoyancy_total_n", 0.0))
		var full_forward := float(breakdown["explicit_forward_n"]) - gravity_local.z - buoyancy_local.z
		history_velocity.append(velocity)
		history_explicit_forward.append(float(breakdown["explicit_forward_n"]))
		history_complete_forward.append(full_forward)
		if history_velocity.size() > ACCEL_WINDOW_TICKS + 1:
			history_velocity.pop_front()
			history_explicit_forward.pop_front()
			history_complete_forward.pop_front()
		max_abs_yaw_rate = maxf(max_abs_yaw_rate, absf(rad_to_deg(float(snapshot.get("angular_velocity_rad_s", Vector3.ZERO).y))))
		if next_checkpoint < STEADY_CHECKPOINTS.size() and absf(sim_time - float(STEADY_CHECKPOINTS[next_checkpoint])) < 0.00001:
			var row := _steady_sample(sim_time, initial_position, initial_forward, history_velocity, history_explicit_forward, history_complete_forward, max_abs_yaw_rate)
			_steady_rows.append(_csv_row(row))
			next_checkpoint += 1
		if tick % (10 * Engine.physics_ticks_per_second) == 0:
			var brief: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
			print("[S1-C5c][steady] t=%ds HDG=%.2f SOG=%.3fkn Vlong=%.3fm/s" % [int(sim_time), float(brief["heading_degrees"]), float(brief["sog_mps"]) * KNOTS_PER_MPS, float(brief["longitudinal_velocity_mps"])])
	_run_count += 1
	if next_checkpoint != STEADY_CHECKPOINTS.size():
		_failures.append("Steady run missed one or more requested checkpoints.")


func _steady_sample(
	sim_time: float,
	initial_position: Vector3,
	initial_forward: Vector3,
	history_velocity: Array[Vector3],
	history_explicit_forward: Array[float],
	history_complete_forward: Array[float],
	max_abs_yaw_rate: float
) -> Dictionary:
	var snapshot: Dictionary = _boat.call("get_debug_snapshot")
	var navigation: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
	var breakdown := _force_breakdown(snapshot)
	var body_basis := _boat.global_basis
	var gravity_local := body_basis.inverse() * Vector3.DOWN * float(snapshot.get("mass_kg", PROFILE.get("mass_kg"))) * _gravity()
	var buoyancy_local := body_basis.inverse() * Vector3.UP * float(snapshot.get("buoyancy_total_n", 0.0))
	var acceleration_force := _measured_longitudinal_inertia_force(history_velocity, body_basis, float(snapshot.get("mass_kg", PROFILE.get("mass_kg"))))
	var average_explicit := _mean_last(history_explicit_forward, ACCEL_WINDOW_TICKS)
	var average_complete := _mean_last(history_complete_forward, ACCEL_WINDOW_TICKS)
	var measured_residual := acceleration_force - average_complete if history_velocity.size() > 1 else 0.0
	var effective_damping := _effective_linear_damping()
	var theoretical_damping := -float(snapshot.get("mass_kg", PROFILE.get("mass_kg"))) * effective_damping * float(navigation.get("longitudinal_velocity_mps", 0.0))
	var post_damping_residual := measured_residual - theoretical_damping
	var displacement := _boat.global_position - initial_position
	var forward_speed := float(navigation.get("longitudinal_velocity_mps", 0.0))
	var sail_lift: Vector3 = snapshot.get("sail_lift_force_local_n", Vector3.ZERO)
	var sail_drag: Vector3 = snapshot.get("sail_drag_force_local_n", Vector3.ZERO)
	return {
		"case": "baseline_8ms_50deg",
		"sim_time_s": sim_time,
		"heading_deg": float(navigation.get("heading_degrees", 0.0)),
		"sog_knots": float(navigation.get("sog_mps", 0.0)) * KNOTS_PER_MPS,
		"longitudinal_speed_mps": forward_speed,
		"lateral_speed_mps": float(navigation.get("lateral_velocity_mps", 0.0)),
		"forward_displacement_initial_axis_m": displacement.dot(initial_forward),
		"sail_lift_forward_n": -sail_lift.z,
		"sail_drag_forward_n": -sail_drag.z,
		"sail_total_forward_n": float(breakdown["sail_forward_n"]),
		"keel_lift_forward_n": float(breakdown["keel_lift_forward_n"]),
		"keel_drag_forward_n": float(breakdown["keel_drag_forward_n"]),
		"keel_total_forward_n": float(breakdown["keel_forward_n"]),
		"rudder_lift_forward_n": float(breakdown["rudder_lift_forward_n"]),
		"rudder_drag_forward_n": float(breakdown["rudder_drag_forward_n"]),
		"rudder_total_forward_n": float(breakdown["rudder_forward_n"]),
		"hull_longitudinal_linear_forward_n": float(breakdown["hull_linear_forward_n"]),
		"hull_longitudinal_quadratic_forward_n": float(breakdown["hull_quadratic_forward_n"]),
		"hull_lateral_forward_projection_n": float(breakdown["hull_lateral_forward_n"]),
		"hull_total_forward_n": float(breakdown["hull_forward_n"]),
		"explicit_force_sum_forward_n": float(breakdown["explicit_forward_n"]),
		"gravity_forward_n": -gravity_local.z,
		"buoyancy_forward_n": -buoyancy_local.z,
		"complete_known_force_forward_n": float(breakdown["explicit_forward_n"]) - gravity_local.z - buoyancy_local.z,
		"measured_inertia_force_forward_n": acceleration_force,
		"simple_linear_damping_estimate_n": theoretical_damping,
		"measured_unresolved_residual_n": measured_residual,
		"post_damping_balance_residual_n": post_damping_residual,
		"avg_explicit_force_window_n": average_explicit,
		"avg_complete_force_window_n": average_complete,
		"max_abs_yaw_rate_deg_s": max_abs_yaw_rate,
		"apparent_wind_from_deg": float(navigation.get("apparent_wind_from_angle_degrees", 0.0)),
		"heel_deg": float(navigation.get("roll_degrees", 0.0)),
		"sail_forward_plus_hull_drag_n": float(breakdown["sail_forward_n"]) + float(breakdown["hull_forward_n"]),
		"linear_damp_property": float(_boat.linear_damp),
		"project_default_linear_damp": float(ProjectSettings.get_setting("physics/3d/default_linear_damp")),
		"effective_linear_damp_coefficient": effective_damping,
	}


func _run_fixed_speed_drag_curve() -> void:
	var configured := await _configure_lab(0.0, 270.0, 0.0, 0.0, {})
	if not configured:
		return
	var rows: Array[String] = []
	for speed_knots in [0.5, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0]:
		rows.append(_fixed_drag_row("fixed", speed_knots, 0.0))
	for beta_degrees in [-10.0, -5.0, 5.0, 10.0]:
		rows.append(_fixed_drag_row("fixed_sideslip", 2.0, beta_degrees))
	_speed_rows.append_array(rows)


func _fixed_drag_row(mode: String, speed_knots: float, sideslip_degrees: float) -> String:
	var speed := speed_knots / KNOTS_PER_MPS
	var beta := deg_to_rad(sideslip_degrees)
	var local_velocity := Vector3(speed * sin(beta), 0.0, -speed * cos(beta))
	var mass := float(PROFILE.get("mass_kg"))
	var gravity := _gravity()
	var max_hull := mass * gravity * float(PROFILE.get("hull_drag_max_force_weight_ratio"))
	var hull_linear_z := -float(PROFILE.get("hull_longitudinal_drag_linear_n_s_m")) * local_velocity.z
	var hull_quad_z := -float(PROFILE.get("hull_longitudinal_drag_quadratic_n_s2_m2")) * absf(local_velocity.z) * local_velocity.z
	var hull_lateral_x := -float(PROFILE.get("hull_lateral_drag_linear_n_s_m")) * local_velocity.x - float(PROFILE.get("hull_lateral_drag_quadratic_n_s2_m2")) * absf(local_velocity.x) * local_velocity.x
	var raw_hull := Vector3(hull_lateral_x, 0.0, hull_linear_z + hull_quad_z)
	var hull := HYDRO.calculate_hull_resistance(
		local_velocity,
		float(PROFILE.get("hull_longitudinal_drag_linear_n_s_m")),
		float(PROFILE.get("hull_longitudinal_drag_quadratic_n_s2_m2")),
		float(PROFILE.get("hull_lateral_drag_linear_n_s_m")),
		float(PROFILE.get("hull_lateral_drag_quadratic_n_s2_m2")),
		max_hull
	)
	var cap_scale := hull.length() / raw_hull.length() if raw_hull.length() > max_hull and raw_hull.length() > 0.0 else 1.0
	var keel := _calculate_foil(local_velocity, 0.0, "keel")
	var rudder := _calculate_foil(local_velocity, 0.0, "rudder")
	var hull_forward := -hull.z
	var hull_lateral_actual := hull.x
	var keel_lateral := Vector3(keel["net_force_local_n"]).x
	var rudder_lateral := Vector3(rudder["net_force_local_n"]).x
	var body_damping_forward := -float(PROFILE.get("mass_kg")) * _effective_linear_damping() * speed * cos(beta)
	var total_including_damping := hull_forward - Vector3(keel["net_force_local_n"]).z - Vector3(rudder["net_force_local_n"]).z + body_damping_forward
	return _csv([
		mode, _n(speed_knots), _n(sideslip_degrees), _n(local_velocity.x),
		_n(-hull_linear_z * cap_scale), _n(-hull_quad_z * cap_scale), _n(hull_forward),
		_n(0.0),
		_n(-Vector3(keel["lift_force_local_n"]).z), _n(-Vector3(keel["drag_force_local_n"]).z), _n(-Vector3(keel["net_force_local_n"]).z),
		_n(-Vector3(rudder["lift_force_local_n"]).z), _n(-Vector3(rudder["drag_force_local_n"]).z), _n(-Vector3(rudder["net_force_local_n"]).z),
		_n(hull_forward + -Vector3(keel["net_force_local_n"]).z + -Vector3(rudder["net_force_local_n"]).z),
		_n(float(keel["water_speed_mps"])), _n(float(keel["angle_of_attack_rad"])),
		"", "", "", "",
		_n(body_damping_forward), _n(total_including_damping),
		_n(hull_lateral_actual), _n(keel_lateral), _n(rudder_lateral), _n(hull_lateral_actual + keel_lateral + rudder_lateral),
	])


func _run_natural_deceleration() -> void:
	for speed_knots in [0.5, 1.0, 2.0, 4.0]:
		var configured := await _configure_lab(0.0, 270.0, 0.0, speed_knots, {})
		if not configured:
			return
		var total_steps := 20 * SIMULATION_HZ
		for tick in range(0, total_steps + 1):
			if tick > 0:
				await physics_frame
			var time_s := float(tick) / float(SIMULATION_HZ)
			if tick in [0, 60, 300, 600, 1200]:
				var sample: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
				_speed_rows.append(_csv([
					"natural_release", _n(speed_knots), "0.000000", "0.000000", "", "", "", "",
					"", "", "", "", "", "", "", "", "", _n(time_s),
					_n(float(sample["longitudinal_velocity_mps"]) * KNOTS_PER_MPS),
					_n(float(sample["sog_mps"]) * KNOTS_PER_MPS), _n(float(sample["heading_degrees"])), "", "", "", "", "", "",
				]))
		_run_count += 1


func _run_drag_sensitivity() -> void:
	var base_case := {"name": "baseline", "property": "", "value": 0.0}
	var variants := [
		base_case,
		{"name": "hull_long_linear_x0_5", "property": "_hull_longitudinal_drag_linear", "value": float(PROFILE.get("hull_longitudinal_drag_linear_n_s_m")) * 0.5},
		{"name": "hull_long_quadratic_x0_5", "property": "_hull_longitudinal_drag_quadratic", "value": float(PROFILE.get("hull_longitudinal_drag_quadratic_n_s2_m2")) * 0.5},
		{"name": "keel_base_cd_x0_5", "property": "_keel_base_drag_coefficient", "value": float(PROFILE.get("keel_base_drag_coefficient")) * 0.5},
		{"name": "keel_induced_drag_x0_5", "property": "_keel_induced_drag_factor", "value": float(PROFILE.get("keel_induced_drag_factor")) * 0.5},
		{"name": "keel_flat_plate_drag_x0_5", "property": "_keel_flat_plate_drag_factor", "value": float(PROFILE.get("keel_flat_plate_drag_factor")) * 0.5},
		{"name": "keel_lift_slope_x1_25", "property": "_keel_lift_slope_per_rad", "value": float(PROFILE.get("keel_lift_slope_per_rad")) * 1.25},
		{"name": "body_linear_damp_zero_combine", "property": "linear_damp", "value": 0.0},
		{"name": "body_damping_replace_global_default", "property": "linear_damp_mode", "value": 1.0},
	]
	for variant in variants:
		var overrides := {}
		if not str(variant["property"]).is_empty():
			overrides[str(variant["property"])] = float(variant["value"])
		var configured := await _configure_lab(8.0, 270.0, 50.0, 0.0, overrides)
		if not configured:
			return
		var history: Array[Vector3] = []
		var start_position := _boat.global_position
		var start_forward := -_boat.global_basis.z
		var max_abs_yaw := 0.0
		for tick in range(1, 120 * SIMULATION_HZ + 1):
			await physics_frame
			var snapshot: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
			var yaw_deg := rad_to_deg(float(snapshot["yaw_rate_rad_s"]))
			max_abs_yaw = maxf(max_abs_yaw, absf(yaw_deg))
			var world_velocity: Vector3 = _boat.linear_velocity
			history.append(world_velocity)
			if history.size() > 30:
				history.pop_front()
			var time_s := float(tick) / float(SIMULATION_HZ)
			if time_s in SUMMARY_CHECKPOINTS:
				var breakdown := _force_breakdown(_boat.call("get_debug_snapshot"))
				var displacement := _boat.global_position - start_position
				_sensitivity_rows.append(_csv([
					str(variant["name"]), str(variant["property"]), _n(float(variant["value"])), _n(time_s),
					_n(float(snapshot["longitudinal_velocity_mps"])), _n(float(snapshot["sog_mps"]) * KNOTS_PER_MPS),
					_n(float(snapshot["heading_degrees"])), _n(displacement.dot(start_forward)),
					_n(float(snapshot["lateral_velocity_mps"])),
					_n(rad_to_deg(atan2(float(snapshot["lateral_velocity_mps"]), maxf(absf(float(snapshot["longitudinal_velocity_mps"])), 0.05)))),
					_n(float(breakdown["keel_lateral_n"])), _n(float(snapshot["roll_degrees"])), _n(max_abs_yaw),
				]))
			if tick % (30 * Engine.physics_ticks_per_second) == 0:
				print("[S1-C5c][sensitivity] %s t=%ds Vlong=%.3fm/s SOG=%.3fkn HDG=%.1f°" % [str(variant["name"]), int(time_s), float(snapshot["longitudinal_velocity_mps"]), float(snapshot["sog_mps"]) * KNOTS_PER_MPS, float(snapshot["heading_degrees"])])
		_run_count += 1


func _run_sail_area_sensitivity() -> void:
	var variants := [
		{"name": "current_visual_main", "category": "current_main", "area": 10.16025},
		{"name": "enlarged_main_reference", "category": "area_only_main_geometry_needed", "area": 13.0},
		{"name": "enlarged_main_reference_2", "category": "area_only_main_geometry_needed", "area": 16.0},
		{"name": "concept_main_plus_foresail_total", "category": "area_only_not_two_sail_equivalent", "area": 20.0},
	]
	for variant in variants:
		var configured := await _configure_lab(8.0, 270.0, 50.0, 0.0, {"_sail_area_m2": float(variant["area"])})
		if not configured:
			return
		var start_position := _boat.global_position
		var start_forward := -_boat.global_basis.z
		var max_abs_yaw := 0.0
		for tick in range(1, 120 * SIMULATION_HZ + 1):
			await physics_frame
			var snapshot: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
			max_abs_yaw = maxf(max_abs_yaw, absf(rad_to_deg(float(snapshot["yaw_rate_rad_s"]))))
			var time_s := float(tick) / float(SIMULATION_HZ)
			if time_s in SUMMARY_CHECKPOINTS:
				var debug: Dictionary = _boat.call("get_debug_snapshot")
				var breakdown := _force_breakdown(debug)
				var displacement := _boat.global_position - start_position
				_area_rows.append(_csv([
					str(variant["name"]), str(variant["category"]), _n(float(variant["area"])), _n(time_s),
					_n(float(snapshot["longitudinal_velocity_mps"])), _n(float(snapshot["sog_mps"]) * KNOTS_PER_MPS),
					_n(float(snapshot["heading_degrees"])), _n(displacement.dot(start_forward)),
					_n(float(snapshot["lateral_velocity_mps"])), _n(float(snapshot["roll_degrees"])), _n(max_abs_yaw),
					_n(float(breakdown["sail_forward_n"])), _n(float(breakdown["sail_lateral_n"])), _n(float(breakdown["keel_lateral_n"])),
				]))
			if tick % (30 * Engine.physics_ticks_per_second) == 0:
				print("[S1-C5c][area] %s %.2fm² t=%ds Vlong=%.3fm/s SOG=%.3fkn HDG=%.1f°" % [str(variant["name"]), float(variant["area"]), int(time_s), float(snapshot["longitudinal_velocity_mps"]), float(snapshot["sog_mps"]) * KNOTS_PER_MPS, float(snapshot["heading_degrees"])])
		_run_count += 1


func _configure_lab(wind_speed: float, wind_from: float, sail_degrees: float, initial_knots: float, overrides: Dictionary) -> bool:
	if _lab == null or not is_instance_valid(_lab):
		await _spawn_fresh_lab()
	if _boat == null or _wind == null:
		return false
	_reset_runtime_parameters()
	_boat.call("set_dynamic_waves_enabled", false)
	_boat.call("set_water_current_world_velocity", Vector3.ZERO)
	_wind.call("set_random_seed", FIXED_SEED)
	_wind.set("gust_strength_mps", 0.0)
	_wind.set("gust_direction_variation_degrees", 0.0)
	_wind.call("set_test_simulation_time", 0.0)
	if not bool(_boat.call("set_lab_test_wind", wind_speed, wind_from)):
		_failures.append("SailboatLab refused diagnostic wind override.")
		return false
	for property_name in overrides:
		_boat.set(str(property_name), overrides[property_name])
	_boat.call("reset_to_neutral", 0.0)
	_boat.set("actual_sail_angle_rad", deg_to_rad(sail_degrees))
	_boat.set("actual_rudder_angle_rad", 0.0)
	_boat.call("set_target_sail_angle", deg_to_rad(sail_degrees))
	_boat.call("set_target_rudder_angle", 0.0)
	_boat.call("set_test_initial_linear_velocity_local", Vector3(0.0, 0.0, -initial_knots / KNOTS_PER_MPS))
	_boat.sleeping = false
	while true:
		var pending: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
		if not bool(pending.get("pose_command_pending", false)) and not bool(pending.get("test_initial_velocity_pending", false)):
			break
		await physics_frame
	_wind.call("set_test_simulation_time", 0.0)
	var timestep := float(_boat.call("get_debug_snapshot").get("physics_delta_s", 0.0))
	if absf(timestep - 1.0 / float(SIMULATION_HZ)) > 0.0005:
		_failures.append("Accelerated runner changed the effective physical step to %.6f s." % timestep)
	var applied: Vector3 = _boat.call("get_s1_c4_diagnostic_snapshot").get("test_initial_velocity_applied_local_mps", Vector3.ZERO)
	var expected := Vector3(0.0, 0.0, -initial_knots / KNOTS_PER_MPS)
	if applied.distance_to(expected) > 0.0001:
		_failures.append("Test initial speed was not applied to the instantiated body.")
	return true


func _reset_runtime_parameters() -> void:
	# Preserve the published C5c baseline after SailboatLab's production profile
	# adopts a different damping policy in S1-C5d.
	_boat.linear_damp = 0.12
	_boat.set("linear_damp_mode", 0)
	_boat.set("_sail_area_m2", float(PROFILE.get("main_sail_area_m2")))
	_boat.set("_hull_longitudinal_drag_linear", float(PROFILE.get("hull_longitudinal_drag_linear_n_s_m")))
	_boat.set("_hull_longitudinal_drag_quadratic", float(PROFILE.get("hull_longitudinal_drag_quadratic_n_s2_m2")))
	_boat.set("_keel_base_drag_coefficient", float(PROFILE.get("keel_base_drag_coefficient")))
	_boat.set("_keel_induced_drag_factor", float(PROFILE.get("keel_induced_drag_factor")))
	_boat.set("_keel_flat_plate_drag_factor", float(PROFILE.get("keel_flat_plate_drag_factor")))
	_boat.set("_keel_lift_slope_per_rad", float(PROFILE.get("keel_lift_slope_per_rad")))


func _spawn_fresh_lab() -> void:
	if _lab != null and is_instance_valid(_lab):
		_lab.queue_free()
		await process_frame
	_lab = LAB_SCENE.instantiate() as Node3D
	root.add_child(_lab)
	await process_frame
	_boat = _lab.get_node_or_null("SailboatBody") as RigidBody3D
	_wind = _lab.get_node_or_null("WindField")
	if _boat == null or _wind == null:
		_failures.append("SailboatLab did not provide SailboatBody and WindField.")
		return
	var wave_sampler := _lab.get_node_or_null("WaveSampler")
	if wave_sampler != null:
		wave_sampler.set("wave_time_seconds", 0.0)
		wave_sampler.set_process(false)
		wave_sampler.set_physics_process(false)


func _force_breakdown(snapshot: Dictionary) -> Dictionary:
	var sail_lift: Vector3 = snapshot.get("sail_lift_force_local_n", Vector3.ZERO)
	var sail_drag: Vector3 = snapshot.get("sail_drag_force_local_n", Vector3.ZERO)
	var sail_net: Vector3 = snapshot.get("sail_net_force_local_n", sail_lift + sail_drag)
	var keel_velocity: Vector3 = snapshot.get("keel_relative_water_velocity_local_mps", Vector3.ZERO)
	var rudder_velocity: Vector3 = snapshot.get("rudder_relative_water_velocity_local_mps", Vector3.ZERO)
	var keel_result := _calculate_foil(keel_velocity, 0.0, "keel")
	var rudder_angle := float(snapshot.get("actual_rudder_angle_rad", 0.0))
	var rudder_result := _calculate_foil(rudder_velocity, rudder_angle, "rudder")
	var local_velocity: Vector3 = snapshot.get("local_velocity_mps", Vector3.ZERO)
	var raw_linear := -float(_boat.get("_hull_longitudinal_drag_linear")) * local_velocity.z
	var raw_quadratic := -float(_boat.get("_hull_longitudinal_drag_quadratic")) * absf(local_velocity.z) * local_velocity.z
	var raw_lateral := -float(_boat.get("_hull_lateral_drag_linear")) * local_velocity.x - float(_boat.get("_hull_lateral_drag_quadratic")) * absf(local_velocity.x) * local_velocity.x
	var raw_hull := Vector3(raw_lateral, 0.0, raw_linear + raw_quadratic)
	var actual_hull: Vector3 = snapshot.get("hull_drag_force_local_n", Vector3.ZERO)
	var hull_scale := actual_hull.length() / raw_hull.length() if raw_hull.length() > 0.000001 else 1.0
	raw_linear *= hull_scale
	raw_quadratic *= hull_scale
	raw_lateral *= hull_scale
	var keel_lift: Vector3 = keel_result.get("lift_force_local_n", Vector3.ZERO)
	var keel_drag: Vector3 = keel_result.get("drag_force_local_n", Vector3.ZERO)
	var keel_net: Vector3 = keel_result.get("net_force_local_n", Vector3.ZERO)
	var rudder_lift: Vector3 = rudder_result.get("lift_force_local_n", Vector3.ZERO)
	var rudder_drag: Vector3 = rudder_result.get("drag_force_local_n", Vector3.ZERO)
	var rudder_net: Vector3 = rudder_result.get("net_force_local_n", Vector3.ZERO)
	return {
		"sail_forward_n": -sail_net.z,
		"sail_lateral_n": sail_net.x,
		"keel_lift_forward_n": -keel_lift.z,
		"keel_drag_forward_n": -keel_drag.z,
		"keel_forward_n": -keel_net.z,
		"keel_lateral_n": keel_net.x,
		"rudder_lift_forward_n": -rudder_lift.z,
		"rudder_drag_forward_n": -rudder_drag.z,
		"rudder_forward_n": -rudder_net.z,
		"hull_linear_forward_n": -raw_linear,
		"hull_quadratic_forward_n": -raw_quadratic,
		"hull_lateral_forward_n": 0.0,
		"hull_forward_n": -actual_hull.z,
		"explicit_forward_n": -sail_net.z - keel_net.z - rudder_net.z - actual_hull.z,
	}


func _calculate_foil(local_velocity: Vector3, angle: float, kind: String) -> Dictionary:
	var is_keel := kind == "keel"
	var area := float(_boat.get("_keel_area_m2" if is_keel else "_rudder_area_m2"))
	var lift_slope := float(_boat.get("_keel_lift_slope_per_rad" if is_keel else "_rudder_lift_slope_per_rad"))
	var max_cl := float(_boat.get("_keel_max_lift_coefficient" if is_keel else "_rudder_max_lift_coefficient"))
	var stall := float(_boat.get("_keel_stall_angle_rad" if is_keel else "_rudder_stall_angle_rad"))
	var base_cd := float(_boat.get("_keel_base_drag_coefficient" if is_keel else "_rudder_base_drag_coefficient"))
	var induced := float(_boat.get("_keel_induced_drag_factor" if is_keel else "_rudder_induced_drag_factor"))
	var flat_plate := float(_boat.get("_keel_flat_plate_drag_factor" if is_keel else "_rudder_flat_plate_drag_factor"))
	var max_ratio := float(_boat.get("_keel_max_force_weight_ratio" if is_keel else "_rudder_max_force_weight_ratio"))
	var result: Dictionary = HYDRO.calculate_foil_forces(
		local_velocity,
		angle,
		area,
		float(PROFILE.get("water_density_kg_m3")),
		lift_slope,
		max_cl,
		stall,
		base_cd,
		induced,
		flat_plate,
		float(PROFILE.get("mass_kg")) * _gravity() * max_ratio
	)
	return result


func _measured_longitudinal_inertia_force(velocity_history: Array[Vector3], current_basis: Basis, body_mass: float) -> float:
	if velocity_history.size() < 2:
		return 0.0
	var window_count := mini(ACCEL_WINDOW_TICKS, velocity_history.size() - 1)
	var first := velocity_history.size() - window_count - 1
	var first_velocity := velocity_history[first]
	var last_velocity := velocity_history[velocity_history.size() - 1]
	var elapsed := float(window_count) / float(SIMULATION_HZ)
	var acceleration_forward := ((last_velocity - first_velocity) / elapsed).dot(-current_basis.z)
	return body_mass * acceleration_forward


func _mean_last(values: Array[float], desired_count: int) -> float:
	var count := mini(desired_count, values.size())
	if count <= 0:
		return 0.0
	var total := 0.0
	for index in range(values.size() - count, values.size()):
		total += values[index]
	return total / float(count)


func _write_outputs() -> void:
	if not _steady_rows.is_empty():
		_write_csv("s1_c5c_steady_force_decomposition.csv", "case,sim_time_s,heading_deg,sog_knots,longitudinal_speed_mps,lateral_speed_mps,forward_displacement_initial_axis_m,sail_lift_forward_n,sail_drag_forward_n,sail_total_forward_n,keel_lift_forward_n,keel_drag_forward_n,keel_total_forward_n,rudder_lift_forward_n,rudder_drag_forward_n,rudder_total_forward_n,hull_longitudinal_linear_forward_n,hull_longitudinal_quadratic_forward_n,hull_lateral_forward_projection_n,hull_total_forward_n,explicit_force_sum_forward_n,gravity_forward_n,buoyancy_forward_n,complete_known_force_forward_n,measured_inertia_force_forward_n,engine_linear_damping_estimate_n,measured_residual_before_damping_n,measured_residual_after_damping_n,avg_explicit_force_window_n,avg_complete_force_window_n,max_abs_yaw_rate_deg_s,apparent_wind_from_deg,heel_deg,sail_forward_plus_hull_drag_n,body_linear_damp,project_default_linear_damp,effective_linear_damp_coefficient\n" + "\n".join(_steady_rows) + "\n")
	if not _speed_rows.is_empty():
		_write_csv("s1_c5c_speed_drag_curve.csv", "mode,initial_speed_knots,sideslip_deg,lateral_velocity_mps,hull_linear_forward_n,hull_quadratic_forward_n,hull_total_forward_n,hull_lateral_forward_projection_n,keel_lift_forward_n,keel_drag_forward_n,keel_total_forward_n,rudder_lift_forward_n,rudder_drag_forward_n,rudder_total_forward_n,total_hydrodynamic_forward_n,keel_water_speed_mps,keel_angle_of_attack_rad,sim_time_s,natural_longitudinal_speed_knots,natural_sog_knots,heading_deg,body_linear_damping_forward_estimate_n,total_drag_including_linear_damping_estimate_n,hull_lateral_force_local_x_n,keel_lateral_force_local_x_n,rudder_lateral_force_local_x_n,total_lateral_force_local_x_n\n" + "\n".join(_speed_rows) + "\n")
	if not _sensitivity_rows.is_empty():
		_write_csv("s1_c5c_drag_sensitivity.csv", "case,overridden_property,override_value,sim_time_s,longitudinal_speed_mps,sog_knots,heading_deg,forward_displacement_initial_axis_m,lateral_speed_mps,approx_sideslip_deg,keel_lateral_force_n,heel_deg,max_abs_yaw_rate_deg_s\n" + "\n".join(_sensitivity_rows) + "\n")
	if not _area_rows.is_empty():
		_write_csv("s1_c5c_sail_area_sensitivity.csv", "case,interpretation,area_only_m2,sim_time_s,longitudinal_speed_mps,sog_knots,heading_deg,forward_displacement_initial_axis_m,lateral_speed_mps,heel_deg,max_abs_yaw_rate_deg_s,sail_forward_force_n,sail_lateral_force_n,keel_lateral_force_n\n" + "\n".join(_area_rows) + "\n")


func _csv_row(values: Dictionary) -> String:
	var keys := [
		"case", "sim_time_s", "heading_deg", "sog_knots", "longitudinal_speed_mps", "lateral_speed_mps", "forward_displacement_initial_axis_m",
		"sail_lift_forward_n", "sail_drag_forward_n", "sail_total_forward_n", "keel_lift_forward_n", "keel_drag_forward_n", "keel_total_forward_n",
		"rudder_lift_forward_n", "rudder_drag_forward_n", "rudder_total_forward_n", "hull_longitudinal_linear_forward_n", "hull_longitudinal_quadratic_forward_n",
		"hull_lateral_forward_projection_n", "hull_total_forward_n", "explicit_force_sum_forward_n", "gravity_forward_n", "buoyancy_forward_n",
		"complete_known_force_forward_n", "measured_inertia_force_forward_n", "simple_linear_damping_estimate_n", "measured_unresolved_residual_n",
		"post_damping_balance_residual_n", "avg_explicit_force_window_n", "avg_complete_force_window_n", "max_abs_yaw_rate_deg_s", "apparent_wind_from_deg", "heel_deg",
		"sail_forward_plus_hull_drag_n", "linear_damp_property", "project_default_linear_damp", "effective_linear_damp_coefficient",
	]
	var row: Array[String] = []
	for key in keys:
		var value: Variant = values.get(key, "")
		row.append(str(value) if value is String else _n(float(value)))
	return ",".join(row)


func _write_csv(filename: String, content: String) -> void:
	var path := ProjectSettings.globalize_path(DATA_DIR.path_join(filename))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_failures.append("Could not write %s: %s" % [path, error_string(FileAccess.get_open_error())])
		return
	file.store_string(content)
	file.close()


func _csv(values: Array) -> String:
	var result: Array[String] = []
	for value in values:
		result.append(str(value))
	return ",".join(result)


func _n(value: float) -> String:
	return "%.6f" % value


func _gravity() -> float:
	return float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))


func _effective_linear_damping() -> float:
	var body_value := float(_boat.linear_damp)
	var project_value := float(ProjectSettings.get_setting("physics/3d/default_linear_damp"))
	# Godot's default rigid-body damping mode is COMBINE (enum value 0).
	# If the scene explicitly switches to REPLACE, only the body value applies.
	return body_value + project_value if int(_boat.get("linear_damp_mode")) == 0 else body_value
