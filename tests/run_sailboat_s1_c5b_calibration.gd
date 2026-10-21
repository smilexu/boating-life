extends SceneTree
## Offline C5b experiments using the production SailboatLab rigid body and
## sail-force function. Per-case geometry/area overrides never touch the
## shared Resource or enter the normal game loop.

const LAB_SCENE := preload("res://scenes/SailboatLab.tscn")
const PROFILE := preload("res://resources/sailing/sailboat_lab_profile.tres")
const AERO := preload("res://scripts/sailboat_aero_math.gd")
const HYDRO := preload("res://scripts/sailboat_hydrodynamics.gd")
const DATA_DIR := "res://docs/sailing/c5b_data"
const KNOTS_PER_MPS := 1.9438444924406
const FIXED_SEED := 481516
const AREA_M2 := 10.16025
const PC_Z_CANDIDATES_M := [0.55, 0.80, 1.05, 1.30]
const CHECKPOINTS := [0.1, 0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 30.0, 60.0, 120.0]

var _lab: Node3D
var _boat: RigidBody3D
var _wind: Node
var _rows: Array[String] = []
var _failures: Array[String] = []
var _case_count := 0
var _started_usec := 0
var _mode := "geometry"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_started_usec = Time.get_ticks_usec()
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--phase="):
			_mode = argument.trim_prefix("--phase=")
	if Engine.physics_ticks_per_second != 60:
		_failures.append("Expected fixed 60 Hz physics; received %d Hz." % Engine.physics_ticks_per_second)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DATA_DIR))
	if _mode == "geometry":
		await _run_geometry_scan()
	elif _mode == "full":
		await _run_final_sailing_matrix()
		_run_aero_matrix()
		_run_rudder_angle_checks()
		_validate_aerodynamic_semantics()
	elif _mode == "checks":
		_run_aero_matrix()
		_run_rudder_angle_checks()
		_validate_aerodynamic_semantics()
	elif _mode == "initial-speed":
		for initial_knots in [0.0, 1.0, 2.0]:
			await _run_case("initial_speed_%0.1fkn" % initial_knots, 0.80, 50.0, 270.0, 0.0, 2, 2, initial_knots)
	else:
		_failures.append("Unknown phase '%s'. Use --phase=geometry, --phase=checks, --phase=initial-speed, or --phase=full." % _mode)
	if not _rows.is_empty():
		_write_csv("s1_c5b_%s_time_history.csv" % _mode,
			"case,area_m2,pc_sail_frame_y_m,pc_sail_frame_z_m,wind_from_deg,sail_angle_deg,rudder_target_deg,initial_speed_knots,rudder_return_at_s,dynamic_waves,sim_time_s,heading_deg,sog_knots,longitudinal_speed_mps,lateral_speed_mps,forward_displacement_initial_axis_m,cross_displacement_initial_axis_m,yaw_rate_deg_s,max_yaw_rate_deg_s,apparent_wind_from_deg,luffing_scale,heel_deg,sail_forward_force_n,sail_lateral_force_n,sail_yaw_torque_nm,keel_yaw_torque_nm,rudder_yaw_torque_nm,total_measured_yaw_torque_nm,actual_rudder_deg" \
			+ "\n" + "\n".join(_rows) + "\n")
	var elapsed := float(Time.get_ticks_usec() - _started_usec) / 1_000_000.0
	if _failures.is_empty():
		print("[S1-C5b] %s phase: %d dynamic cases, %.2f wall seconds; output docs/sailing/c5b_data/" % [_mode, _case_count, elapsed])
		quit(0)
	else:
		for failure in _failures:
			push_error("[S1-C5b] " + failure)
		quit(1)


func _run_geometry_scan() -> void:
	for pc_z in PC_Z_CANDIDATES_M:
		await _run_case("pc_z_%0.2f" % pc_z, pc_z, 30.0, 270.0, 0.0)
	# A second set checks 30/40/50 degree trim and the port/starboard mirror at
	# the C5a chordwise candidate after matching the physical area to the mesh.
	for sail_degrees in [30.0, 40.0, 50.0]:
		await _run_case("port_trim_%0.0f" % sail_degrees, 0.80, sail_degrees, 270.0, 0.0)
		await _run_case("starboard_trim_%0.0f" % sail_degrees, 0.80, -sail_degrees, 90.0, 0.0)
	_write_csv("s1_c5b_geometry_scan.csv",
		_geometry_header() + "\n"
		+ "\n".join(_rows) + "\n")


func _run_final_sailing_matrix() -> void:
	var profile_pc: Vector3 = PROFILE.get("main_sail_pressure_center_from_pivot_m")
	var selected_pc_z := profile_pc.z
	for wind_from in [270.0, 90.0]:
		var signed_trim := 1.0 if wind_from == 270.0 else -1.0
		for trim in [30.0, 40.0, 50.0]:
			await _run_case("cross_%03.0f_trim_%02.0f" % [wind_from, trim], selected_pc_z, trim * signed_trim, wind_from, 0.0)
	# Angle families beyond the core 120-second crosswind cases are shorter
	# deterministic diagnostics (30 s) and still report force/moment snapshots.
	for wind_from in [-150.0, -120.0, -90.0, -60.0, -45.0, 45.0, 60.0, 90.0, 120.0, 150.0, 180.0, 0.0]:
		var sail_angle := _geometric_trim_for_wind(wind_from)
		await _run_case("wind_%03.0f" % wind_from, selected_pc_z, sail_angle, wind_from, 0.0, 30, 30)
	# The already moving hull tests whether small, short helm inputs work once
	# the foil has water flow; the same target is then returned to centre.
	for initial_knots in [0.0, 1.0, 2.0]:
		for helm in [-5.0, -3.0, -2.0, -1.0, 0.0, 1.0, 2.0, 3.0, 5.0]:
			await _run_case("rudder_%0.1fkn_%+0.0f" % [initial_knots, helm], selected_pc_z, 50.0, 270.0, helm, 30, 30, initial_knots)
	for initial_knots in [0.0, 1.0, 2.0]:
		for pulse in [-3.0, 3.0]:
			await _run_case("rudder_pulse_%0.1fkn_%+0.0f" % [initial_knots, pulse], selected_pc_z, 50.0, 270.0, pulse, 30, 30, initial_knots, 5)
	# One normal-wave run exercises the existing four-point sampler after the
	# static-water calibration; it does not change any wave parameters.
	await _run_case("crosswind_normal_waves", selected_pc_z, 50.0, 270.0, 0.0, 120, 120, 0.0, -1, true)


func _geometric_trim_for_wind(wind_from: float) -> float:
	# The mirrored fixed-trim values put the boom on the leeward side for
	# crosswind and beam-reach cases; exact fore/aft wind is centerline.
	var normalized := fposmod(wind_from, 360.0)
	if normalized == 0.0 or normalized == 180.0:
		return 0.0
	var lateral_sign := 1.0 if normalized < 180.0 else -1.0
	return -lateral_sign * 40.0


func _run_case(
	label: String,
	pc_z: float,
	sail_deg: float,
	wind_from_deg: float,
	rudder_deg: float,
	duration: int = 120,
	checkpoints_override: int = 120,
	initial_speed_knots: float = 0.0,
	rudder_return_after_seconds: int = -1,
	use_dynamic_waves: bool = false
) -> void:
	await _spawn_fresh_lab()
	if _boat == null or _wind == null:
		return
	_boat.call("set_dynamic_waves_enabled", use_dynamic_waves)
	# C5b measurements use the historical COMBINE + 0.12 setup. Keep this
	# offline fixture stable after the formal SailboatLab profile changes.
	_boat.linear_damp = 0.12
	_boat.set("linear_damp_mode", 0)
	_boat.call("set_water_current_world_velocity", Vector3.ZERO)
	_wind.call("set_random_seed", FIXED_SEED)
	_wind.set("gust_strength_mps", 0.0)
	_wind.set("gust_direction_variation_degrees", 0.0)
	_wind.call("set_test_simulation_time", 0.0)
	_boat.call("set_lab_test_wind", 8.0, wind_from_deg)
	_boat.set("_sail_area_m2", AREA_M2)
	var pressure: Vector3 = PROFILE.get("main_sail_pressure_center_from_pivot_m")
	_boat.set("_sail_pressure_center_from_pivot_m", Vector3(pressure.x, pressure.y, pc_z))
	_boat.call("reset_to_neutral", 0.0)
	_boat.set("actual_sail_angle_rad", deg_to_rad(sail_deg))
	_boat.set("actual_rudder_angle_rad", 0.0)
	_boat.call("set_target_sail_angle", deg_to_rad(sail_deg))
	_boat.call("set_target_rudder_angle", deg_to_rad(rudder_deg))
	# Queue the speed through the test-only _integrate_forces hook so the queued
	# neutral-pose reset cannot overwrite it on the first physics tick.
	_boat.call("set_test_initial_linear_velocity_local", Vector3(0.0, 0.0, -initial_speed_knots / KNOTS_PER_MPS))
	_boat.sleeping = false
	while true:
		var pending_snapshot: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
		if not bool(pending_snapshot.get("pose_command_pending", false)) and not bool(pending_snapshot.get("test_initial_velocity_pending", false)):
			break
		await physics_frame
	_wind.call("set_test_simulation_time", 0.0)
	if use_dynamic_waves:
		var wave_sampler := _lab.get_node_or_null("WaveSampler")
		if wave_sampler != null:
			wave_sampler.set("wave_time_seconds", 0.0)
	var initial_snapshot: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
	var applied_initial_velocity: Vector3 = initial_snapshot.get("test_initial_velocity_applied_local_mps", Vector3.ZERO)
	var expected_initial_velocity := Vector3(0.0, 0.0, -initial_speed_knots / KNOTS_PER_MPS)
	if applied_initial_velocity.distance_to(expected_initial_velocity) > 0.0001:
		_failures.append("%s did not apply the requested initial speed through the physics step." % label)
	var initial_position := _boat.global_position
	var initial_forward := -_boat.global_basis.z
	var initial_right := _boat.global_basis.x
	var max_yaw := 0.0
	var previous_heading := _heading()
	var unwrapped_heading := previous_heading
	var case_rows: Array[String] = []
	var total_steps := duration * Engine.physics_ticks_per_second
	for index in range(1, total_steps + 1):
		await physics_frame
		if rudder_return_after_seconds > 0 and index == rudder_return_after_seconds * Engine.physics_ticks_per_second:
			_boat.call("set_target_rudder_angle", 0.0)
		var sample: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
		var yaw_rate := rad_to_deg(float(sample["yaw_rate_rad_s"]))
		max_yaw = maxf(max_yaw, absf(yaw_rate))
		var heading := float(sample["heading_degrees"])
		unwrapped_heading += wrapf(heading - previous_heading, -180.0, 180.0)
		previous_heading = heading
		var sim_time_seconds := float(index) / float(Engine.physics_ticks_per_second)
		for checkpoint in CHECKPOINTS:
			if absf(sim_time_seconds - float(checkpoint)) > 0.0001 or sim_time_seconds > float(checkpoints_override):
				continue
			var displacement: Vector3 = sample["position_world_m"] - initial_position
			var sail_force: Vector3 = sample["sail_force_local_n"]
			var row := _csv([
				label, _n(AREA_M2), _n(2.4), _n(pc_z), _n(wind_from_deg), _n(sail_deg), _n(rudder_deg), _n(initial_speed_knots), str(rudder_return_after_seconds), str(use_dynamic_waves), _n(sim_time_seconds), _n(heading), _n(float(sample["sog_mps"]) * KNOTS_PER_MPS),
				_n(float(sample["longitudinal_velocity_mps"])), _n(float(sample["lateral_velocity_mps"])), _n(displacement.dot(initial_forward)), _n(displacement.dot(initial_right)), _n(yaw_rate), _n(max_yaw),
				_n(float(sample["apparent_wind_from_angle_degrees"])), _n(float(sample["sail_luffing_scale"])), _n(float(sample["roll_degrees"])), _n(-sail_force.z), _n(sail_force.x),
				_n(float(sample["sail_yaw_torque_local_nm"])), _n(float(sample["keel_yaw_torque_local_nm"])), _n(float(sample["rudder_yaw_torque_local_nm"])), _n(float(sample["summed_measured_yaw_torque_local_nm"])), _n(rad_to_deg(float(sample["actual_rudder_angle_rad"])))
			])
			case_rows.append(row)
			_rows.append(row)
			if _mode == "geometry":
				_write_csv("s1_c5b_geometry_scan.csv", _geometry_header() + "\n" + "\n".join(_rows) + "\n")
		if absf(sim_time_seconds - float(checkpoints_override)) <= 0.0001:
			print("[S1-C5b] %s t=%.2fs · HDG %.1f° · SOG %.3f kn · fwd %.3f m/s · heel %.1f° · max yaw %.2f°/s" % [label, sim_time_seconds, heading, float(sample["sog_mps"]) * KNOTS_PER_MPS, float(sample["longitudinal_velocity_mps"]), float(sample["roll_degrees"]), max_yaw])
	_case_count += 1
	var recorded_end := false
	for row in case_rows:
		var fields := row.split(",")
		if fields.size() > 10 and absf(float(fields[10]) - 120.0) < 0.0001:
			recorded_end = true
	if duration >= 120 and not recorded_end:
		_failures.append("%s did not record the 120 s checkpoint." % label)
	if use_dynamic_waves:
		var perf: Dictionary = _boat.call("get_debug_snapshot")
		print("[S1-C5b_PERF] normal waves total avg/P95=%d/%d μs · wave avg/P95=%d/%d μs · aero avg/P95=%d/%d μs · queries=%d+%d" % [
			int(perf.get("total_physics_calculation_average_usec", 0)),
			int(perf.get("total_physics_calculation_p95_usec", 0)),
			int(perf.get("wave_sample_average_usec", 0)),
			int(perf.get("wave_sample_p95_usec", 0)),
			int(perf.get("aero_calculation_average_usec", 0)),
			int(perf.get("aero_calculation_p95_usec", 0)),
			int(perf.get("wave_query_count_per_tick", 0)),
			int(perf.get("wind_query_count_per_tick", 0)),
		])


func _run_aero_matrix() -> void:
	var rows: Array[String] = []
	var angles := [-150.0, -120.0, -90.0, -60.0, -45.0, 45.0, 60.0, 90.0, 120.0, 150.0, 180.0]
	var trims := [-70.0, -50.0, -30.0, -10.0, 0.0, 10.0, 30.0, 50.0, 70.0]
	var area := AREA_M2
	for wind_from in angles:
		var angle := deg_to_rad(wind_from)
		var apparent := Vector3(-sin(angle), 0.0, cos(angle)) * 8.0
		for trim in trims:
			var result: Dictionary = AERO.calculate_sail_forces(apparent, deg_to_rad(trim), area, float(PROFILE.get("air_density_kg_m3")), float(PROFILE.get("sail_max_lift_coefficient")), float(PROFILE.get("sail_stall_angle_rad")), float(PROFILE.get("sail_base_drag_coefficient")), float(PROFILE.get("sail_induced_drag_factor")), float(PROFILE.get("sail_flat_plate_drag_factor")), float(PROFILE.get("no_sail_wind_from_angle_rad")), float(PROFILE.get("full_lift_wind_from_angle_rad")), float(PROFILE.get("sail_wrong_side_lift_retention")))
			var lift: Vector3 = result["lift_force_local_n"]
			var drag: Vector3 = result["drag_force_local_n"]
			var total: Vector3 = result["net_force_local_n"]
			rows.append(_csv([_n(wind_from), _n(trim), _n(rad_to_deg(float(result["angle_of_attack_rad"]))), _n(float(result["luffing_scale"])), _n(float(result["sheet_efficiency_scale"])), _n(float(result["cl"])), _n(float(result["cd"])), _n(float(result["dynamic_pressure_pa"])), _n(-lift.z), _n(lift.x), _n(-drag.z), _n(drag.x), _n(-total.z), _n(total.x)]))
	_write_csv("s1_c5b_aero_side_matrix.csv", "wind_from_relative_deg,sail_angle_deg,attack_angle_deg,luffing_scale,sheet_efficiency_scale,cl,cd,dynamic_pressure_pa,lift_forward_n,lift_lateral_n,drag_forward_n,drag_lateral_n,total_forward_n,total_lateral_n\n" + "\n".join(rows) + "\n")
	print("[S1-C5b] static aerodynamic matrix: %d angle/trim pairs." % rows.size())


func _run_rudder_angle_checks() -> void:
	var rows: Array[String] = []
	for speed_knots in [0.0, 0.5, 1.0, 2.0, 3.0]:
		for rudder_deg in [-5.0, -3.0, -2.0, -1.0, 0.0, 1.0, 2.0, 3.0, 5.0]:
			var local_velocity := Vector3(0.0, 0.0, -speed_knots / KNOTS_PER_MPS)
			var result := HYDRO.calculate_foil_forces(local_velocity, deg_to_rad(rudder_deg), float(PROFILE.get("rudder_area_m2")), float(PROFILE.get("water_density_kg_m3")), float(PROFILE.get("rudder_lift_slope_per_rad")), float(PROFILE.get("rudder_max_lift_coefficient")), float(PROFILE.get("rudder_stall_angle_rad")), float(PROFILE.get("rudder_base_drag_coefficient")), float(PROFILE.get("rudder_induced_drag_factor")), float(PROFILE.get("rudder_flat_plate_drag_factor")), float(PROFILE.get("mass_kg")) * 9.8 * float(PROFILE.get("rudder_max_force_weight_ratio")))
			var force: Vector3 = result["net_force_local_n"]
			var moment := (Vector3(0.0, -0.88, 3.18) - Vector3(0.0, -0.65, 0.0)).cross(force).y
			rows.append(_csv([_n(speed_knots), _n(rudder_deg), _n(float(result["water_speed_mps"])), _n(float(result["angle_of_attack_rad"])), _n(force.x), _n(force.z), _n(moment)]))
	_write_csv("s1_c5b_rudder_small_angle_matrix.csv", "initial_speed_knots,rudder_angle_deg,local_water_speed_mps,angle_of_attack_rad,force_lateral_n,force_longitudinal_n,yaw_moment_local_y_nm\n" + "\n".join(rows) + "\n")
	for speed in [0.0, 0.5, 1.0, 2.0, 3.0]:
		var zero := _rudder_moment_for(speed, 0.0)
		var left := _rudder_moment_for(speed, -5.0)
		var right := _rudder_moment_for(speed, 5.0)
		if speed == 0.0 and (absf(left) > 0.001 or absf(right) > 0.001):
			_failures.append("Zero-speed rudder generated a nonzero yaw moment.")
		if speed > 0.0 and left * right >= 0.0:
			_failures.append("Mirrored rudder moments were not opposite at %.1f kn." % speed)
		if absf(zero) > 0.001:
			_failures.append("Centered rudder generated a zero-angle yaw moment at %.1f kn." % speed)
	print("[S1-C5b] small-angle rudder force/moment matrix: %d cases." % rows.size())


func _validate_aerodynamic_semantics() -> void:
	var retention := float(PROFILE.get("sail_wrong_side_lift_retention"))
	for wind_from_deg in [-150.0, -120.0, -90.0, -60.0, -45.0, 45.0, 60.0, 90.0, 120.0, 150.0]:
		var beta := deg_to_rad(wind_from_deg)
		var apparent := Vector3(-sin(beta), 0.0, cos(beta)) * 8.0
		var best_leeward_forward := -INF
		var best_windward_forward := -INF
		for trim_deg in range(-80, 81, 10):
			var result := _profile_sail_force(apparent, deg_to_rad(float(trim_deg)))
			var forward_force := -Vector3(result["net_force_local_n"]).z
			var boom_windward_alignment := sin(beta) * sin(deg_to_rad(float(trim_deg)))
			if boom_windward_alignment > 0.0:
				best_windward_forward = maxf(best_windward_forward, forward_force)
			else:
				best_leeward_forward = maxf(best_leeward_forward, forward_force)
		if best_windward_forward >= best_leeward_forward:
			_failures.append("Windward/backed side matched or exceeded the best leeward forward force at %.0f degrees." % wind_from_deg)
		if absf(wind_from_deg) == 90.0:
			var wrong_side := _profile_sail_force(apparent, deg_to_rad(30.0 * signf(wind_from_deg)))
			if float(wrong_side["wrong_side_lift_scale"]) > retention + 0.001:
				_failures.append("Full crosswind backing did not reach the configured lift-retention limit.")
	for trim in [-70.0, -40.0, 0.0, 40.0, 70.0]:
		var head_flow := Vector3(0.0, 0.0, 8.0)
		var headwind: Dictionary = _profile_sail_force(head_flow, deg_to_rad(trim))
		if -Vector3(headwind["net_force_local_n"]).z > 0.01 or absf(float(headwind["cl"])) > 0.0001:
			_failures.append("Direct headwind produced sail propulsion at trim %.0f degrees." % trim)
	for trim in [-60.0, 60.0]:
		var following: Dictionary = _profile_sail_force(Vector3(0.0, 0.0, -8.0), deg_to_rad(trim))
		if Vector3(following["net_force_local_n"]).z >= 0.0:
			_failures.append("Following wind did not retain drag-based drive at trim %.0f degrees." % trim)


func _profile_sail_force(apparent: Vector3, trim_rad: float) -> Dictionary:
	return AERO.calculate_sail_forces(
		apparent,
		trim_rad,
		float(PROFILE.get("main_sail_area_m2")),
		float(PROFILE.get("air_density_kg_m3")),
		float(PROFILE.get("sail_max_lift_coefficient")),
		float(PROFILE.get("sail_stall_angle_rad")),
		float(PROFILE.get("sail_base_drag_coefficient")),
		float(PROFILE.get("sail_induced_drag_factor")),
		float(PROFILE.get("sail_flat_plate_drag_factor")),
		float(PROFILE.get("no_sail_wind_from_angle_rad")),
		float(PROFILE.get("full_lift_wind_from_angle_rad")),
		float(PROFILE.get("sail_wrong_side_lift_retention"))
	)


func _rudder_moment_for(speed_knots: float, degrees: float) -> float:
	var result := HYDRO.calculate_foil_forces(Vector3(0.0, 0.0, -speed_knots / KNOTS_PER_MPS), deg_to_rad(degrees), float(PROFILE.get("rudder_area_m2")), float(PROFILE.get("water_density_kg_m3")), float(PROFILE.get("rudder_lift_slope_per_rad")), float(PROFILE.get("rudder_max_lift_coefficient")), float(PROFILE.get("rudder_stall_angle_rad")), float(PROFILE.get("rudder_base_drag_coefficient")), float(PROFILE.get("rudder_induced_drag_factor")), float(PROFILE.get("rudder_flat_plate_drag_factor")), float(PROFILE.get("mass_kg")) * 9.8 * float(PROFILE.get("rudder_max_force_weight_ratio")))
	return (Vector3(0.0, -0.88, 3.18) - Vector3(0.0, -0.65, 0.0)).cross(result["net_force_local_n"]).y


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


func _heading() -> float:
	return float(_boat.call("get_s1_c4_diagnostic_snapshot")["heading_degrees"])


func _geometry_header() -> String:
	return "case,area_m2,pc_sail_frame_y_m,pc_sail_frame_z_m,wind_from_deg,sail_angle_deg,rudder_target_deg,initial_speed_knots,rudder_return_at_s,dynamic_waves,sim_time_s,heading_deg,sog_knots,longitudinal_speed_mps,lateral_velocity_mps,forward_displacement_initial_axis_m,cross_displacement_initial_axis_m,yaw_rate_deg_s,max_yaw_rate_deg_s,apparent_wind_from_deg,luffing_scale,heel_deg,sail_forward_force_n,sail_lateral_force_n,sail_yaw_torque_nm,keel_yaw_torque_nm,rudder_yaw_torque_nm,total_measured_yaw_torque_nm,actual_rudder_deg"


func _csv(values: Array) -> String:
	var result: Array[String] = []
	for value in values:
		result.append(str(value))
	return ",".join(result)


func _n(value: float) -> String:
	return "%.6f" % value


func _write_csv(filename: String, content: String) -> void:
	var path := ProjectSettings.globalize_path(DATA_DIR.path_join(filename))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_failures.append("Could not write %s: %s" % [path, error_string(FileAccess.get_open_error())])
		return
	file.store_string(content)
	file.close()
