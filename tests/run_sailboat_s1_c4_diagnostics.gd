extends SceneTree
## Offline, repeatable S1-C4 diagnostic runner. Physics behavior is always
## advanced by the real SailboatLab RigidBody3D at the project's fixed step.
## Run headless; --fixed-fps can remove render-loop wall-clock pacing.

const LAB_SCENE := preload("res://scenes/SailboatLab.tscn")
const PROFILE := preload("res://resources/sailing/sailboat_lab_profile.tres")
const AERO := preload("res://scripts/sailboat_aero_math.gd")
const NAV := preload("res://scripts/sailboat_navigation_math.gd")
const KEY_TIMES := [5, 10, 20, 30, 60, 90, 120, 150, 180]
const SPEEDS_KNOTS := [0.0, 0.5, 1.0, 2.0, 3.0, 5.0]
const RUDDER_DEGREES := [0.0, -10.0, 10.0, -20.0, 20.0]
const SAIL_ANGLES_DEGREES := [0.0, 10.0, -10.0, 20.0, -20.0, 30.0, -30.0, 45.0, -45.0, 55.0, -55.0, 65.0, -65.0]
const GRAVITY_MPS2 := 9.8
const TEST_SEED := 481516
const KNOTS_PER_MPS := 1.9438444924406

var _mode := "ALL"
var _duration_seconds := 120
var _wind_speed_mps := 8.0
var _wind_from_degrees := 270.0
var _lab: Node3D
var _boat: RigidBody3D
var _wind: Node
var _summaries: Array[String] = []
var _histories: Array[String] = []
var _force_rows: Array[String] = []
var _rudder_rows: Array[String] = []
var _physics_step_s := 1.0 / 60.0
var _checks := 0
var _failures: Array[String] = []
var _fixed_step_validated := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_parse_arguments()
	_physics_step_s = 1.0 / float(Engine.physics_ticks_per_second)
	_force_rows.append("wind_from_relative_deg,sail_angle_deg,apparent_wind_speed_mps,apparent_wind_from_relative_deg,angle_of_attack_deg,luffing_scale,cl,cd,sail_force_forward_n,sail_force_lateral_n,sail_force_vertical_n,sail_yaw_torque_local_nm,sail_roll_torque_local_nm,upwind_state")
	_rudder_rows.append("initial_speed_knots,helm_deg,actual_rudder_deg,rudder_water_speed_mps,rudder_force_lateral_n,rudder_yaw_torque_local_nm,yaw_acceleration_rad_s2,keel_yaw_torque_local_nm")
	_histories.append("scenario_id,sim_time_s,heading_deg,heading_unwrapped_deg,cog_deg,sog_mps,sog_knots,longitudinal_velocity_mps,lateral_velocity_mps,forward_displacement_m,cross_displacement_m,yaw_rate_deg_s,heel_deg,apparent_wind_speed_mps,apparent_wind_from_relative_deg,sail_aoa_deg,sail_luffing_scale,sail_cl,sail_cd,sail_forward_force_n,sail_lateral_force_n,sail_vertical_force_n,keel_forward_force_n,keel_lateral_force_n,rudder_forward_force_n,rudder_lateral_force_n,hull_drag_forward_force_n,hull_drag_lateral_force_n,total_horizontal_forward_force_n,total_horizontal_lateral_force_n,sail_yaw_torque_local_nm,sail_yaw_torque_world_vertical_nm,keel_yaw_torque_local_nm,keel_yaw_torque_world_vertical_nm,rudder_yaw_torque_local_nm,rudder_yaw_torque_world_vertical_nm,explicit_yaw_damping_local_nm,total_measured_yaw_torque_local_nm,total_measured_yaw_torque_world_vertical_nm,actual_sail_deg,target_sail_deg,actual_rudder_deg,target_rudder_deg")
	_summaries.append("scenario_id,group,wind_from_deg,wind_speed_mps,sail_target_deg,rudder_target_deg,duration_s,sog_30s_knots,sog_120s_knots,hdg_30s_deg,hdg_120s_deg,max_sog_knots,forward_displacement_m,cross_displacement_m,first_heading_change_s,max_abs_yaw_rate_deg_s,max_yaw_rate_time_s,mean_sail_forward_force_n,mean_sail_lateral_force_n,mean_sail_yaw_torque_nm,mean_keel_yaw_torque_nm,mean_rudder_yaw_torque_nm,mean_hull_drag_forward_n,mean_explicit_yaw_damping_nm,mean_total_measured_yaw_torque_nm,mean_luffing_scale,mean_yaw_rate_deg_s,last30_sog_knots,last30_longitudinal_velocity_mps,last30_lateral_velocity_mps,last30_sail_forward_force_n,last30_hull_drag_forward_n,last30_sail_yaw_torque_nm,last30_keel_yaw_torque_nm,last30_rudder_yaw_torque_nm,last30_explicit_yaw_damping_nm,last30_total_measured_yaw_torque_nm,last30_luffing_scale,convergence,behavior_class")
	_write_outputs()
	print("S1-C4 diagnostics: mode=%s fixed_physics_step=%.8fs seed=%d" % [_mode, _physics_step_s, TEST_SEED])
	if _mode == "D" or _mode == "ALL":
		_run_force_matrix()
	if _mode == "D":
		_finish()
		return

	_lab = LAB_SCENE.instantiate() as Node3D
	root.add_child(_lab)
	await process_frame
	_boat = _lab.get_node("SailboatBody") as RigidBody3D
	_wind = _lab.get_node("WindField")
	_lab.call("set_dynamic_waves_enabled", false)
	var wave_sampler := _lab.get_node_or_null("WaveSampler")
	if wave_sampler != null:
		wave_sampler.set_process(false)
		wave_sampler.set_physics_process(false)
	
	if _mode == "A" or _mode == "ALL":
		await _run_scenario("A_reproduction", "A", 0.0, 30.0, 0.0, _duration_seconds, true)
	if _mode == "B" or _mode == "ALL":
		for sail_deg in [5.0, 15.0, 25.0, 30.0, 40.0, 45.0, 55.0, 65.0]:
			await _run_scenario("B_sail_%+03d" % int(sail_deg), "B", 0.0, sail_deg, 0.0, _duration_seconds, false)
	if _mode == "B5":
		await _run_scenario("B_sail_+05_extended", "B", 0.0, 5.0, 0.0, 180, false)
	if _mode == "C" or _mode == "ALL":
		for rudder_deg in [0.0, 5.0, 10.0, 15.0, 20.0, -5.0, -10.0]:
			await _run_scenario("C_rudder_%+03d" % int(rudder_deg), "C", 0.0, 30.0, rudder_deg, _duration_seconds, false)
	if _mode == "E" or _mode == "ALL":
		await _run_rudder_speed_matrix()
	_write_outputs()
	_lab.queue_free()
	await process_frame
	_finish()


func _parse_arguments() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--mode="):
			_mode = argument.trim_prefix("--mode=").to_upper()
		elif argument.begins_with("--duration="):
			_duration_seconds = maxi(120, int(argument.trim_prefix("--duration=")))
		elif argument.begins_with("--wind-speed="):
			_wind_speed_mps = maxf(0.0, float(argument.trim_prefix("--wind-speed=")))
		elif argument.begins_with("--wind-from="):
			_wind_from_degrees = fposmod(float(argument.trim_prefix("--wind-from=")), 360.0)
	if _mode not in ["ALL", "A", "B", "B5", "C", "D", "E"]:
		push_error("Invalid --mode. Expected all, A, B, B5, C, D, or E.")
		quit(2)


func _run_scenario(
	scenario_id: String,
	group: String,
	initial_heading_deg: float,
	sail_deg: float,
	rudder_deg: float,
	duration_seconds: int,
	extend_a_if_unstable: bool
) -> void:
	var initial_rudder_deg := 0.0 if group == "C" else rudder_deg
	await _prepare_initial_state(initial_heading_deg, sail_deg, rudder_deg, Vector3.ZERO, -1.0, initial_rudder_deg)
	var initial_basis := _boat.global_basis
	var initial_position := _boat.global_position
	var initial_forward := (initial_basis * Vector3(0.0, 0.0, -1.0)).normalized()
	var initial_right := (initial_basis * Vector3.RIGHT).normalized()
	var previous_heading := _heading_degrees()
	var unwrapped_heading := previous_heading
	var stats := _new_stats()
	stats["initial_unwrapped_heading"] = unwrapped_heading
	var checkpoint_by_time: Dictionary = {}
	var duration := duration_seconds
	var sample := _boat.call("get_s1_c4_diagnostic_snapshot") as Dictionary
	_record_sample(scenario_id, 0.0, sample, initial_position, initial_forward, initial_right, unwrapped_heading, stats, true)
	_histories.append(_history_csv_row(scenario_id, 0.0, sample, initial_position, initial_forward, initial_right, unwrapped_heading))
	checkpoint_by_time[0] = {"heading": unwrapped_heading, "heading_wrapped": previous_heading, "sog": float(sample["sog_mps"]), "yaw_rate": float(sample["yaw_rate_rad_s"])}
	
	for step_index in range(1, duration * Engine.physics_ticks_per_second + 1):
		await physics_frame
		sample = _boat.call("get_s1_c4_diagnostic_snapshot") as Dictionary
		var sim_time := float(step_index) * _physics_step_s
		var heading := float(sample["heading_degrees"])
		unwrapped_heading += wrapf(heading - previous_heading, -180.0, 180.0)
		previous_heading = heading
		_record_sample(scenario_id, sim_time, sample, initial_position, initial_forward, initial_right, unwrapped_heading, stats, false)
		if step_index % Engine.physics_ticks_per_second == 0:
			checkpoint_by_time[int(round(sim_time))] = {
				"heading": unwrapped_heading,
				"heading_wrapped": heading,
				"sog": float(sample["sog_mps"]),
				"yaw_rate": float(sample["yaw_rate_rad_s"]),
			}
			if int(round(sim_time)) in KEY_TIMES:
				_histories.append(_history_csv_row(scenario_id, sim_time, sample, initial_position, initial_forward, initial_right, unwrapped_heading))
				_write_outputs()
			if int(round(sim_time)) % 30 == 0:
				print("[S1-C4] %s %d/%d s · HDG %.1f° · SOG %.2f kn · yaw %+0.2f°/s" % [
					scenario_id,
					int(round(sim_time)),
					duration,
					heading,
					float(sample["sog_mps"]) * KNOTS_PER_MPS,
					rad_to_deg(float(sample["yaw_rate_rad_s"])),
				])
	
	var convergence := _convergence_state(checkpoint_by_time, duration)
	if extend_a_if_unstable and convergence != "low_change_over_last_30s":
		print("[S1-C4] %s has not converged by %ds; extending key reproduction to 180s." % [scenario_id, duration])
		for step_index in range(duration * Engine.physics_ticks_per_second + 1, 180 * Engine.physics_ticks_per_second + 1):
			await physics_frame
			sample = _boat.call("get_s1_c4_diagnostic_snapshot") as Dictionary
			var sim_time := float(step_index) * _physics_step_s
			var heading := float(sample["heading_degrees"])
			unwrapped_heading += wrapf(heading - previous_heading, -180.0, 180.0)
			previous_heading = heading
			_record_sample(scenario_id, sim_time, sample, initial_position, initial_forward, initial_right, unwrapped_heading, stats, false)
			if step_index % Engine.physics_ticks_per_second == 0:
				checkpoint_by_time[int(round(sim_time))] = {
					"heading": unwrapped_heading,
					"heading_wrapped": heading,
					"sog": float(sample["sog_mps"]),
					"yaw_rate": float(sample["yaw_rate_rad_s"]),
				}
				if int(round(sim_time)) in KEY_TIMES:
					_histories.append(_history_csv_row(scenario_id, sim_time, sample, initial_position, initial_forward, initial_right, unwrapped_heading))
					_write_outputs()
			if int(round(sim_time)) % 30 == 0:
				print("[S1-C4] %s %d/180 s · HDG %.1f° · SOG %.2f kn · yaw %+0.2f°/s" % [
					scenario_id,
					int(round(sim_time)),
					heading,
					float(sample["sog_mps"]) * KNOTS_PER_MPS,
					rad_to_deg(float(sample["yaw_rate_rad_s"])),
				])
		duration = 180
		convergence = _convergence_state(checkpoint_by_time, duration)
	
	var summary := _summary_from_stats(scenario_id, group, sail_deg, rudder_deg, duration, stats, checkpoint_by_time, convergence, sample, initial_position, initial_forward, initial_right)
	_summaries.append(_summary_csv_row(summary))
	_write_outputs()
	print("[S1-C4] completed %s · %ds · classification=%s · convergence=%s" % [scenario_id, duration, summary["behavior_class"], convergence])


func _prepare_initial_state(
	heading_deg: float,
	sail_deg: float,
	rudder_deg: float,
	initial_velocity_local: Vector3,
	wind_speed_mps: float = -1.0,
	initial_rudder_angle_deg: float = -9999.0
) -> void:
	_boat.call("set_dynamic_waves_enabled", false)
	_boat.call("set_water_current_world_velocity", Vector3.ZERO)
	_wind.call("set_random_seed", TEST_SEED)
	_wind.set("gust_direction_variation_degrees", 0.0)
	_wind.call("set_test_simulation_time", 0.0)
	var test_wind_speed := _wind_speed_mps if wind_speed_mps < 0.0 else wind_speed_mps
	var rudder_start_deg := rudder_deg if initial_rudder_angle_deg < -1000.0 else initial_rudder_angle_deg
	_boat.call("set_lab_test_wind", test_wind_speed, _wind_from_degrees)
	_boat.call("reset_to_neutral", heading_deg)
	_boat.call("set_target_sail_angle", deg_to_rad(sail_deg))
	_boat.call("set_target_rudder_angle", deg_to_rad(rudder_deg))
	_boat.set("actual_sail_angle_rad", deg_to_rad(sail_deg))
	_boat.set("actual_rudder_angle_rad", deg_to_rad(rudder_start_deg))
	await physics_frame
	await physics_frame # Let the queued reset pass through _integrate_forces before defining t=0.
	var float_offsets: PackedVector3Array = PROFILE.get("float_point_offsets_m")
	var mean_float_y := 0.0
	for offset in float_offsets:
		mean_float_y += offset.y
	mean_float_y /= float(float_offsets.size())
	var initial_y := -float(PROFILE.get("rest_submergence_m")) - mean_float_y
	_boat.global_transform = Transform3D(Basis(Vector3.UP, deg_to_rad(heading_deg)), Vector3(0.0, initial_y, 0.0))
	_boat.linear_velocity = _boat.global_basis * initial_velocity_local
	_boat.angular_velocity = Vector3.ZERO
	_boat.set("actual_sail_angle_rad", deg_to_rad(sail_deg))
	_boat.set("actual_rudder_angle_rad", deg_to_rad(rudder_start_deg))
	_boat.call("set_target_sail_angle", deg_to_rad(sail_deg))
	_boat.call("set_target_rudder_angle", deg_to_rad(rudder_deg))
	if not _fixed_step_validated:
		var dt_snapshot: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
		var measured_step := float(dt_snapshot.get("physics_delta_s", 0.0))
		if measured_step > 0.0 and absf(measured_step - _physics_step_s) > 0.00001:
			_failures.append("SailboatLab physics step %.8f differs from configured %.8f" % [measured_step, _physics_step_s])
		else:
			_fixed_step_validated = measured_step > 0.0


func _run_rudder_speed_matrix() -> void:
	for speed_knots in SPEEDS_KNOTS:
		for rudder_deg in RUDDER_DEGREES:
			await _prepare_initial_state(0.0, 0.0, rudder_deg, Vector3(0.0, 0.0, -speed_knots / KNOTS_PER_MPS), 0.0)
			var initial_yaw_rate := float((_boat.global_basis.inverse() * _boat.angular_velocity).y)
			var snapshot: Dictionary = {}
			for _sample_step in range(10):
				await physics_frame
				snapshot = _boat.call("get_s1_c4_diagnostic_snapshot") as Dictionary
			var dt := float(snapshot.get("physics_delta_s", _physics_step_s))
			var yaw_rate := float(snapshot["yaw_rate_rad_s"])
			var rudder_force: Vector3 = snapshot["rudder_force_local_n"]
			_rudder_rows.append(",".join([
				_num(speed_knots),
				_num(rudder_deg),
				_num(rad_to_deg(float(snapshot["actual_rudder_angle_rad"]))),
				_num(float(snapshot["rudder_water_speed_mps"])),
				_num(rudder_force.x),
				_num(float(snapshot["rudder_yaw_torque_local_nm"])),
				_num((yaw_rate - initial_yaw_rate) / maxf(dt * 10.0, 0.0001)),
				_num(float(snapshot["keel_yaw_torque_local_nm"])),
			]))
			_write_outputs()
	print("[S1-C4] completed E rudder speed matrix: %d cases" % (SPEEDS_KNOTS.size() * RUDDER_DEGREES.size()))


func _run_force_matrix() -> void:
	var wind_offsets := [-180.0, -150.0, -120.0, -90.0, -60.0, -45.0, -30.0, 0.0, 30.0, 45.0, 60.0, 90.0, 120.0, 150.0, 180.0]
	var force_lookup: Dictionary = {}
	var zero_wind := AERO.calculate_sail_forces(Vector3.ZERO, deg_to_rad(30.0), float(PROFILE.get("main_sail_area_m2")))
	_expect(Vector3(zero_wind["net_force_local_n"]) == Vector3.ZERO, "zero wind yields exactly zero sail force")
	for wind_from_relative in wind_offsets:
		for sail_deg in SAIL_ANGLES_DEGREES:
			var apparent_from := deg_to_rad(wind_from_relative)
			var apparent_velocity := Vector3(-sin(apparent_from), 0.0, cos(apparent_from)) * _wind_speed_mps
			var result: Dictionary = AERO.calculate_sail_forces(
				apparent_velocity,
				deg_to_rad(sail_deg),
				float(PROFILE.get("main_sail_area_m2")),
				float(PROFILE.get("air_density_kg_m3")),
				float(PROFILE.get("sail_max_lift_coefficient")),
				float(PROFILE.get("sail_stall_angle_rad")),
				float(PROFILE.get("sail_base_drag_coefficient")),
				float(PROFILE.get("sail_induced_drag_factor")),
				float(PROFILE.get("sail_flat_plate_drag_factor")),
				float(PROFILE.get("no_sail_wind_from_angle_rad")),
				float(PROFILE.get("full_lift_wind_from_angle_rad"))
			)
			var force: Vector3 = result["net_force_local_n"]
			var sail_pivot: Vector3 = PROFILE.get("main_sail_pivot_local_m")
			var sail_pc_from_pivot: Vector3 = PROFILE.get("main_sail_pressure_center_from_pivot_m")
			var pressure_center := sail_pivot + Basis(Vector3.UP, deg_to_rad(sail_deg)) * sail_pc_from_pivot
			var com: Vector3 = PROFILE.get("center_of_mass_m")
			var torque := (pressure_center - com).cross(force)
			force_lookup[_force_key(wind_from_relative, sail_deg)] = {"force": force, "torque": torque}
			var luffing_scale := float(result["luffing_scale"])
			var upwind_state := "powered"
			if luffing_scale < 0.001:
				upwind_state = "luffing_zone"
			elif luffing_scale < 0.999:
				upwind_state = "luff_transition"
			_force_rows.append(",".join([
				_num(wind_from_relative),
				_num(sail_deg),
				_num(float(result["apparent_speed_mps"])),
				_num(rad_to_deg(float(result["apparent_wind_from_angle_rad"]))),
				_num(rad_to_deg(float(result["angle_of_attack_rad"]))),
				_num(luffing_scale),
				_num(float(result["cl"])),
				_num(float(result["cd"])),
				_num(-force.z),
				_num(force.x),
				_num(force.y),
				_num(torque.y),
				_num(torque.z),
				upwind_state,
			]))
	for wind_from_relative in wind_offsets:
		for sail_deg in SAIL_ANGLES_DEGREES:
			if wind_from_relative < 0.0 or (is_zero_approx(wind_from_relative) and sail_deg < 0.0):
				continue
			var original: Dictionary = force_lookup[_force_key(wind_from_relative, sail_deg)]
			var mirrored: Dictionary = force_lookup[_force_key(-wind_from_relative, -sail_deg)]
			var original_force: Vector3 = original["force"]
			var mirrored_force: Vector3 = mirrored["force"]
			var original_torque: Vector3 = original["torque"]
			var mirrored_torque: Vector3 = mirrored["torque"]
			_expect(absf(original_force.z - mirrored_force.z) < 0.05, "mirrored tacks preserve longitudinal sail force")
			_expect(absf(original_force.x + mirrored_force.x) < 0.05, "mirrored tacks reverse lateral sail force")
			_expect(absf(original_torque.y + mirrored_torque.y) < 0.05, "mirrored tacks reverse sail yaw moment")
			_expect(absf(original_torque.z + mirrored_torque.z) < 0.05, "mirrored tacks reverse sail heel moment")
	var headwind: Dictionary = force_lookup[_force_key(0.0, 30.0)]
	var headwind_force: Vector3 = headwind["force"]
	var headwind_case: Dictionary = AERO.calculate_sail_forces(Vector3(0.0, 0.0, _wind_speed_mps), deg_to_rad(30.0), 26.0)
	_expect(headwind_force.z >= -0.05 and float(headwind_case["luffing_scale"]) < 0.001, "headwind trim remains luffing and cannot create forward propulsion")
	_write_outputs()
	print("[S1-C4] completed D sail force matrix: %d combinations · %d checks" % [wind_offsets.size() * SAIL_ANGLES_DEGREES.size(), _checks])


func _force_key(wind_from_relative: float, sail_angle: float) -> String:
	var wind_key := 0.0 if is_zero_approx(wind_from_relative) else wind_from_relative
	var sail_key := 0.0 if is_zero_approx(sail_angle) else sail_angle
	return _num(wind_key) + "/" + _num(sail_key)


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(description)


func _record_sample(
	scenario_id: String,
	sim_time: float,
	sample: Dictionary,
	initial_position: Vector3,
	initial_forward: Vector3,
	initial_right: Vector3,
	unwrapped_heading: float,
	stats: Dictionary,
	initial_sample: bool
) -> void:
	var sog := float(sample["sog_mps"])
	var yaw_rate := float(sample["yaw_rate_rad_s"])
	var sail_force: Vector3 = sample["sail_force_local_n"]
	var keel_force: Vector3 = sample["keel_force_local_n"]
	var rudder_force: Vector3 = sample["rudder_force_local_n"]
	var hull_drag: Vector3 = sample["hull_drag_force_local_n"]
	var position: Vector3 = sample["position_world_m"]
	var forward_displacement := (position - initial_position).dot(initial_forward)
	var cross_displacement := (position - initial_position).dot(initial_right)
	stats["sample_count"] = int(stats["sample_count"]) + 1
	stats["sog_sum"] = float(stats["sog_sum"]) + sog
	stats["yaw_rate_sum"] = float(stats["yaw_rate_sum"]) + yaw_rate
	stats["sail_forward_sum"] = float(stats["sail_forward_sum"]) - sail_force.z
	stats["sail_lateral_sum"] = float(stats["sail_lateral_sum"]) + sail_force.x
	stats["sail_yaw_sum"] = float(stats["sail_yaw_sum"]) + float(sample["sail_yaw_torque_local_nm"])
	stats["keel_yaw_sum"] = float(stats["keel_yaw_sum"]) + float(sample["keel_yaw_torque_local_nm"])
	stats["rudder_yaw_sum"] = float(stats["rudder_yaw_sum"]) + float(sample["rudder_yaw_torque_local_nm"])
	stats["hull_forward_sum"] = float(stats["hull_forward_sum"]) - hull_drag.z
	stats["damping_yaw_sum"] = float(stats["damping_yaw_sum"]) + float(sample["explicit_yaw_damping_torque_local_nm"])
	stats["total_yaw_sum"] = float(stats["total_yaw_sum"]) + float(sample["summed_measured_yaw_torque_local_nm"])
	stats["luffing_sum"] = float(stats["luffing_sum"]) + float(sample["sail_luffing_scale"])
	stats["max_sog"] = maxf(float(stats["max_sog"]), sog)
	if absf(yaw_rate) > float(stats["max_abs_yaw"]):
		stats["max_abs_yaw"] = absf(yaw_rate)
		stats["max_abs_yaw_time_s"] = sim_time
	if int(stats["sample_count"]) == 1:
		stats["max_lateral"] = absf(float(sample["lateral_velocity_mps"]))
	else:
		stats["max_lateral"] = maxf(float(stats["max_lateral"]), absf(float(sample["lateral_velocity_mps"])))
	if not initial_sample and is_equal_approx(sim_time, float(round(sim_time))):
		var second_samples: Dictionary = stats["second_samples"]
		second_samples[int(round(sim_time))] = {
			"heading": unwrapped_heading,
			"heading_wrapped": float(sample["heading_degrees"]),
			"sog": sog,
			"yaw_rate": yaw_rate,
			"sail_forward": -sail_force.z,
			"sail_lateral": sail_force.x,
			"sail_yaw": float(sample["sail_yaw_torque_local_nm"]),
			"keel_yaw": float(sample["keel_yaw_torque_local_nm"]),
			"rudder_yaw": float(sample["rudder_yaw_torque_local_nm"]),
			"hull_forward": -hull_drag.z,
			"damping_yaw": float(sample["explicit_yaw_damping_torque_local_nm"]),
			"total_yaw": float(sample["summed_measured_yaw_torque_local_nm"]),
			"luffing": float(sample["sail_luffing_scale"]),
			"longitudinal_velocity": float(sample["longitudinal_velocity_mps"]),
			"lateral_velocity": float(sample["lateral_velocity_mps"]),
		}
		stats["second_samples"] = second_samples
	if not initial_sample and absf(unwrapped_heading - float(stats["initial_unwrapped_heading"])) > 0.1 and not bool(stats["has_heading_change"]):
		stats["first_heading_change_s"] = sim_time
		stats["has_heading_change"] = true


func _new_stats() -> Dictionary:
	return {
		"sample_count": 0,
		"sog_sum": 0.0,
		"yaw_rate_sum": 0.0,
		"sail_forward_sum": 0.0,
		"sail_lateral_sum": 0.0,
		"sail_yaw_sum": 0.0,
		"keel_yaw_sum": 0.0,
		"rudder_yaw_sum": 0.0,
		"hull_forward_sum": 0.0,
		"damping_yaw_sum": 0.0,
		"total_yaw_sum": 0.0,
		"luffing_sum": 0.0,
		"max_sog": 0.0,
		"max_abs_yaw": 0.0,
		"max_abs_yaw_time_s": 0.0,
		"first_heading_change_s": -1.0,
		"has_heading_change": false,
		"max_lateral": 0.0,
		"second_samples": {},
	}


func _summary_from_stats(
	scenario_id: String,
	group: String,
	sail_deg: float,
	rudder_deg: float,
	duration: int,
	stats: Dictionary,
	checkpoints: Dictionary,
	convergence: String,
	final_sample: Dictionary,
	initial_position: Vector3,
	initial_forward: Vector3,
	initial_right: Vector3
) -> Dictionary:
	var count := maxf(float(stats["sample_count"]), 1.0)
	var final_position: Vector3 = final_sample["position_world_m"]
	var forward_displacement := (final_position - initial_position).dot(initial_forward)
	var cross_displacement := (final_position - initial_position).dot(initial_right)
	var sample_30: Dictionary = checkpoints.get(30, checkpoints.get(120, {}))
	var sample_120: Dictionary = checkpoints.get(120, {})
	var heading_delta_120 := float(sample_120.get("heading_wrapped", final_sample["heading_degrees"]))
	var sog_30 := float(sample_30.get("sog", 0.0))
	var sog_120 := float(sample_120.get("sog", final_sample["sog_mps"]))
	var behavior := "持续航行"
	var mean_sog := float(stats["sog_sum"]) / count
	var mean_luff := float(stats["luffing_sum"]) / count
	var final_heading_unwrapped := float(checkpoints.get(duration, {}).get("heading", final_sample["heading_degrees"]))
	var yaw_degrees := absf(final_heading_unwrapped - float(checkpoints.get(90, {}).get("heading", final_heading_unwrapped)))
	if mean_sog < 0.15:
		behavior = "失速/近停"
	elif mean_sog < 0.50:
		behavior = "低速漂移或缓慢转向"
	elif convergence == "low_change_over_last_30s":
		behavior = "稳定航行状态候选"
	elif yaw_degrees > 8.0:
		behavior = "持续航行并偏航"
	if mean_luff < 0.25:
		behavior += " · 多数时间帆有效受风"
	else:
		behavior += " · 帆有较多失风/过渡时间"
	return {
		"scenario_id": scenario_id,
		"group": group,
		"sail_target_deg": sail_deg,
		"rudder_target_deg": rudder_deg,
		"duration_s": duration,
		"sog_30s_knots": sog_30 * KNOTS_PER_MPS,
		"sog_120s_knots": sog_120 * KNOTS_PER_MPS,
		"hdg_30s_deg": float(sample_30.get("heading_wrapped", sample_30.get("heading", 0.0))),
		"hdg_120s_deg": heading_delta_120,
		"max_sog_knots": float(stats["max_sog"]) * KNOTS_PER_MPS,
		"forward_displacement_m": forward_displacement,
		"cross_displacement_m": cross_displacement,
		"first_heading_change_s": float(stats["first_heading_change_s"]),
		"max_abs_yaw_rate_deg_s": rad_to_deg(float(stats["max_abs_yaw"])),
		"max_yaw_rate_time_s": float(stats["max_abs_yaw_time_s"]),
		"mean_sail_forward_force_n": float(stats["sail_forward_sum"]) / count,
		"mean_sail_lateral_force_n": float(stats["sail_lateral_sum"]) / count,
		"mean_sail_yaw_torque_nm": float(stats["sail_yaw_sum"]) / count,
		"mean_keel_yaw_torque_nm": float(stats["keel_yaw_sum"]) / count,
		"mean_rudder_yaw_torque_nm": float(stats["rudder_yaw_sum"]) / count,
		"mean_hull_drag_forward_n": float(stats["hull_forward_sum"]) / count,
		"mean_explicit_yaw_damping_nm": float(stats["damping_yaw_sum"]) / count,
		"mean_total_measured_yaw_torque_nm": float(stats["total_yaw_sum"]) / count,
		"mean_luffing_scale": mean_luff,
		"mean_yaw_rate_deg_s": rad_to_deg(float(stats["yaw_rate_sum"]) / count),
		"last30_sog_knots": _mean_second_samples(stats, duration, "sog") * KNOTS_PER_MPS,
		"last30_longitudinal_velocity_mps": _mean_second_samples(stats, duration, "longitudinal_velocity"),
		"last30_lateral_velocity_mps": _mean_second_samples(stats, duration, "lateral_velocity"),
		"last30_sail_forward_force_n": _mean_second_samples(stats, duration, "sail_forward"),
		"last30_hull_drag_forward_n": _mean_second_samples(stats, duration, "hull_forward"),
		"last30_sail_yaw_torque_nm": _mean_second_samples(stats, duration, "sail_yaw"),
		"last30_keel_yaw_torque_nm": _mean_second_samples(stats, duration, "keel_yaw"),
		"last30_rudder_yaw_torque_nm": _mean_second_samples(stats, duration, "rudder_yaw"),
		"last30_explicit_yaw_damping_nm": _mean_second_samples(stats, duration, "damping_yaw"),
		"last30_total_measured_yaw_torque_nm": _mean_second_samples(stats, duration, "total_yaw"),
		"last30_luffing_scale": _mean_second_samples(stats, duration, "luffing"),
		"convergence": convergence,
		"behavior_class": behavior,
	}


func _convergence_state(checkpoints: Dictionary, duration: int) -> String:
	if duration < 60 or not checkpoints.has(duration) or not checkpoints.has(duration - 30) or not checkpoints.has(duration - 60):
		return "insufficient_window"
	var end: Dictionary = checkpoints[duration]
	var last30: Dictionary = checkpoints[duration - 30]
	var previous30: Dictionary = checkpoints[duration - 60]
	var heading_slope := absf(float(end["heading"]) - float(last30["heading"])) / 30.0
	var sog_change := absf(float(end["sog"]) - float(last30["sog"]))
	var prior_sog_change := absf(float(last30["sog"]) - float(previous30["sog"]))
	var yaw_rate := absf(float(end["yaw_rate"]))
	if heading_slope < 0.25 and yaw_rate < deg_to_rad(0.5) and absf(sog_change - prior_sog_change) < 0.03:
		return "low_change_over_last_30s"
	return "not_converged"


func _mean_second_samples(stats: Dictionary, end_second: int, field: String) -> float:
	var seconds: Dictionary = stats["second_samples"]
	var total := 0.0
	var count := 0
	for second in range(end_second - 29, end_second + 1):
		if seconds.has(second):
			total += float(seconds[second].get(field, 0.0))
			count += 1
	return total / float(count) if count > 0 else 0.0


func _history_csv_row(scenario_id: String, sim_time: float, sample: Dictionary, origin: Vector3, forward: Vector3, right: Vector3, heading_unwrapped: float) -> String:
	var position: Vector3 = sample["position_world_m"]
	var displacement := position - origin
	var sail_force: Vector3 = sample["sail_force_local_n"]
	var keel_force: Vector3 = sample["keel_force_local_n"]
	var rudder_force: Vector3 = sample["rudder_force_local_n"]
	var hull_drag: Vector3 = sample["hull_drag_force_local_n"]
	var total_force: Vector3 = sample["total_force_local_n"]
	return ",".join([
		_quote(scenario_id), _num(sim_time), _num(float(sample["heading_degrees"])), _num(heading_unwrapped),
		_num(float(sample["cog_degrees"])), _num(float(sample["sog_mps"])), _num(float(sample["sog_mps"]) * KNOTS_PER_MPS),
		_num(float(sample["longitudinal_velocity_mps"])), _num(float(sample["lateral_velocity_mps"])),
		_num(displacement.dot(forward)), _num(displacement.dot(right)), _num(rad_to_deg(float(sample["yaw_rate_rad_s"]))),
		_num(float(sample["roll_degrees"])), _num(float(sample["apparent_wind_speed_mps"])), _num(float(sample["apparent_wind_from_angle_degrees"])),
		_num(float(sample["sail_attack_angle_degrees"])), _num(float(sample["sail_luffing_scale"])), _num(float(sample["sail_cl"])), _num(float(sample["sail_cd"])),
		_num(-sail_force.z), _num(sail_force.x), _num(sail_force.y), _num(-keel_force.z), _num(keel_force.x), _num(-rudder_force.z), _num(rudder_force.x),
		_num(-hull_drag.z), _num(hull_drag.x), _num(-total_force.z), _num(total_force.x),
		_num(float(sample["sail_yaw_torque_local_nm"])), _num(float(sample["sail_yaw_torque_world_vertical_nm"])),
		_num(float(sample["keel_yaw_torque_local_nm"])), _num(float(sample["keel_yaw_torque_world_vertical_nm"])),
		_num(float(sample["rudder_yaw_torque_local_nm"])), _num(float(sample["rudder_yaw_torque_world_vertical_nm"])),
		_num(float(sample["explicit_yaw_damping_torque_local_nm"])), _num(float(sample["summed_measured_yaw_torque_local_nm"])),
		_num(float(sample["summed_measured_yaw_torque_world_vertical_nm"])),
		_num(rad_to_deg(float(sample["actual_sail_angle_rad"]))), _num(rad_to_deg(float(sample["target_sail_angle_rad"]))),
		_num(rad_to_deg(float(sample["actual_rudder_angle_rad"]))), _num(rad_to_deg(float(sample["target_rudder_angle_rad"])))
	])


func _summary_csv_row(summary: Dictionary) -> String:
	return ",".join([
		_quote(str(summary["scenario_id"])), _quote(str(summary["group"])), _num(_wind_from_degrees), _num(_wind_speed_mps),
		_num(float(summary["sail_target_deg"])), _num(float(summary["rudder_target_deg"])), str(summary["duration_s"]),
		_num(float(summary["sog_30s_knots"])), _num(float(summary["sog_120s_knots"])), _num(float(summary["hdg_30s_deg"])), _num(float(summary["hdg_120s_deg"])),
		_num(float(summary["max_sog_knots"])), _num(float(summary["forward_displacement_m"])), _num(float(summary["cross_displacement_m"])),
		_num(float(summary["first_heading_change_s"])), _num(float(summary["max_abs_yaw_rate_deg_s"])), _num(float(summary["max_yaw_rate_time_s"])),
		_num(float(summary["mean_sail_forward_force_n"])), _num(float(summary["mean_sail_lateral_force_n"])),
		_num(float(summary["mean_sail_yaw_torque_nm"])), _num(float(summary["mean_keel_yaw_torque_nm"])), _num(float(summary["mean_rudder_yaw_torque_nm"])),
		_num(float(summary["mean_hull_drag_forward_n"])), _num(float(summary["mean_explicit_yaw_damping_nm"])), _num(float(summary["mean_total_measured_yaw_torque_nm"])),
		_num(float(summary["mean_luffing_scale"])), _num(float(summary["mean_yaw_rate_deg_s"])),
		_num(float(summary["last30_sog_knots"])), _num(float(summary["last30_longitudinal_velocity_mps"])), _num(float(summary["last30_lateral_velocity_mps"])),
		_num(float(summary["last30_sail_forward_force_n"])), _num(float(summary["last30_hull_drag_forward_n"])),
		_num(float(summary["last30_sail_yaw_torque_nm"])), _num(float(summary["last30_keel_yaw_torque_nm"])), _num(float(summary["last30_rudder_yaw_torque_nm"])),
		_num(float(summary["last30_explicit_yaw_damping_nm"])), _num(float(summary["last30_total_measured_yaw_torque_nm"])), _num(float(summary["last30_luffing_scale"])),
		_quote(str(summary["convergence"])), _quote(str(summary["behavior_class"])),
	])


func _write_outputs() -> void:
	var base_path := ProjectSettings.globalize_path("res://docs/sailing/c4_data")
	DirAccess.make_dir_recursive_absolute(base_path)
	var suffix := "_b_plus05_extended" if _mode == "B5" else ""
	_write_text(base_path.path_join("s1_c4_scenario_summary%s.csv" % suffix), "\n".join(_summaries) + "\n")
	_write_text(base_path.path_join("s1_c4_time_history%s.csv" % suffix), "\n".join(_histories) + "\n")
	if _mode != "B5":
		_write_text(base_path.path_join("s1_c4_force_matrix.csv"), "\n".join(_force_rows) + "\n")
		_write_text(base_path.path_join("s1_c4_rudder_effect.csv"), "\n".join(_rudder_rows) + "\n")


func _write_text(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("S1-C4 could not write %s: %s" % [path, error_string(FileAccess.get_open_error())])
		return
	file.store_string(content)
	file.close()


func _heading_degrees() -> float:
	return NAV.heading_degrees_from_forward(-_boat.global_basis.z)


func _num(value: float) -> String:
	return "%.6f" % value


func _quote(value: String) -> String:
	return "\"%s\"" % value.replace("\"", "\"\"")


func _finish() -> void:
	if _failures.is_empty():
		print("S1-C4 diagnostics completed. CSV output: docs/sailing/c4_data/")
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)
