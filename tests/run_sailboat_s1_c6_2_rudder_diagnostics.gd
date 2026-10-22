extends "res://tests/run_sailboat_s1_c5c_drag_diagnostics.gd"
## C6.2 offline hard-over yaw study. It replays the production SailboatLab
## rigid body with a deterministic local wind field and static water.

const C6_2_DATA_DIR := "res://docs/sailing/c6_2_data"
const TARGET_HEADING_DEG := 61.0
const TARGET_SOG_KNOTS := 1.12
const MAX_PRECONDITION_SECONDS := 180
const RUDDER_HOLD_SECONDS := 60
const HEADING_TOLERANCE_DEG := 3.5
const SOG_TOLERANCE_KNOTS := 0.20
const YAW_RATE_TOLERANCE_DEG_S := 1.5
const MATCH_STREAK_SECONDS := 3

var _precondition_seconds := 0
var _precondition_matched := false
var _precondition_rows: Array[String] = []
var _time_rows: Array[String] = []
var _torque_rows: Array[String] = []
var _summary_rows: Array[String] = []
var _c6_2_start_usec := 0


func _run() -> void:
	_c6_2_start_usec = Time.get_ticks_usec()
	_original_physics_hz = Engine.physics_ticks_per_second
	_original_time_scale = Engine.time_scale
	Engine.physics_ticks_per_second = int(SIMULATION_HZ * OFFLINE_TIME_SCALE)
	Engine.time_scale = OFFLINE_TIME_SCALE
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(C6_2_DATA_DIR))
	await _find_free_sailing_precondition()
	if _failures.is_empty():
		for test_case in [
			{"name": "dual_full_port", "headsail": true, "rudder_deg": -999.0},
			{"name": "main_only_full_port", "headsail": false, "rudder_deg": -999.0},
			{"name": "dual_port_15", "headsail": true, "rudder_deg": -15.0},
			{"name": "dual_center", "headsail": true, "rudder_deg": 0.0},
		]:
			await _run_steering_case(test_case)
	_write_outputs()
	var wall_seconds := float(Time.get_ticks_usec() - _c6_2_start_usec) / 1_000_000.0
	Engine.physics_ticks_per_second = _original_physics_hz
	Engine.time_scale = _original_time_scale
	if _failures.is_empty():
		print("[S1-C6.2] precondition=%ds matched=%s cases=4 simulated=%ds wall=%.2fs output=docs/sailing/c6_2_data/" % [
			_precondition_seconds, str(_precondition_matched), _precondition_seconds * 5 + RUDDER_HOLD_SECONDS * 4, wall_seconds,
		])
		quit(0)
	else:
		for failure in _failures:
			push_error("[S1-C6.2] " + failure)
		quit(1)


func _find_free_sailing_precondition() -> void:
	if not await _prepare_turn_case():
		return
	var best_score := INF
	var best_seconds := 0
	var streak := 0
	var nav: Dictionary = _boat.call("get_navigation_snapshot")
	var physics: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
	_precondition_rows.append(_precondition_csv_row(0, nav, physics))
	for second in range(1, MAX_PRECONDITION_SECONDS + 1):
		for _tick in range(SIMULATION_HZ):
			await physics_frame
		nav = _boat.call("get_navigation_snapshot")
		physics = _boat.call("get_s1_c4_diagnostic_snapshot")
		_precondition_rows.append(_precondition_csv_row(second, nav, physics))
		var heading_error := absf(wrapf(float(nav.get("heading_degrees", 0.0)) - TARGET_HEADING_DEG, -180.0, 180.0))
		var speed_error := absf(float(nav.get("sog_knots", 0.0)) - TARGET_SOG_KNOTS)
		var yaw_rate := absf(rad_to_deg(float(physics.get("yaw_rate_rad_s", 0.0))))
		var score := heading_error + speed_error * 12.0 + yaw_rate * 0.15
		if score < best_score:
			best_score = score
			best_seconds = second
		var matches := heading_error <= HEADING_TOLERANCE_DEG and speed_error <= SOG_TOLERANCE_KNOTS and yaw_rate <= YAW_RATE_TOLERANCE_DEG_S
		streak = streak + 1 if matches else 0
		if streak >= MATCH_STREAK_SECONDS:
			_precondition_seconds = second
			_precondition_matched = true
			break
		if second % 30 == 0:
			print("[S1-C6.2][free %ds] HDG=%.2f° SOG=%.3fkn local_yaw=%+.2f°/s" % [
				second, float(nav.get("heading_degrees", 0.0)), float(nav.get("sog_knots", 0.0)), rad_to_deg(float(physics.get("yaw_rate_rad_s", 0.0))),
			])
	if not _precondition_matched:
		_precondition_seconds = best_seconds
		var selected := _precondition_rows[best_seconds]
		print("[S1-C6.2] Target state not held for %ds; replaying nearest observed state at %ds. %s" % [
			MATCH_STREAK_SECONDS, best_seconds, selected,
		])
	else:
		print("[S1-C6.2] Reproducible free-sailing state found at %ds." % _precondition_seconds)


func _prepare_turn_case() -> bool:
	if not await _configure_lab(8.0, 270.0, -60.0, 0.0, {"linear_damp_mode": 1, "linear_damp": 0.0}):
		return false
	_boat.call("set_headsail_enabled", true)
	_boat.set("actual_sail_angle_rad", deg_to_rad(-60.0))
	_boat.call("set_target_sail_angle", deg_to_rad(-60.0))
	_boat.set("actual_headsail_angle_rad", deg_to_rad(-45.0))
	_boat.call("set_target_headsail_angle", deg_to_rad(-45.0))
	_boat.set("actual_rudder_angle_rad", 0.0)
	_boat.call("set_target_rudder_angle", 0.0)
	_wind.call("set_test_simulation_time", 0.0)
	return true


func _run_steering_case(test_case: Dictionary) -> void:
	await _spawn_fresh_lab()
	if not await _prepare_turn_case():
		return
	for _second in range(_precondition_seconds):
		for _tick in range(SIMULATION_HZ):
			await physics_frame
	var replay_start_nav: Dictionary = _boat.call("get_navigation_snapshot")
	var replay_start_physics: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
	var replay_heading_error := absf(wrapf(float(replay_start_nav.get("heading_degrees", 0.0)) - _precondition_heading(), -180.0, 180.0))
	var replay_speed_error := absf(float(replay_start_nav.get("sog_knots", 0.0)) - _precondition_sog())
	if replay_heading_error > 0.2 or replay_speed_error > 0.02:
		_failures.append("%s free-sailing precondition did not replay deterministically (HDG error %.3f°, SOG error %.4fkn)." % [test_case["name"], replay_heading_error, replay_speed_error])
		return
	if not bool(test_case["headsail"]):
		_boat.call("set_headsail_enabled", false)
	var max_rudder := float(PROFILE.get("max_rudder_angle_rad"))
	var target_deg := -rad_to_deg(max_rudder) if float(test_case["rudder_deg"]) < -100.0 else float(test_case["rudder_deg"])
	_boat.call("set_target_rudder_angle", deg_to_rad(target_deg))
	await physics_frame
	var control_start_nav: Dictionary = _boat.call("get_navigation_snapshot")
	var control_start_physics: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
	var case_name := str(test_case["name"])
	var unwrapped_heading := float(control_start_nav.get("heading_degrees", 0.0))
	var previous_heading := unwrapped_heading
	_record_sample(case_name, 0, control_start_nav, control_start_physics, unwrapped_heading)
	var maximum_heading := unwrapped_heading
	var minimum_heading := unwrapped_heading
	var yaw_rates: Array[float] = []
	var rudder_torques: Array[float] = []
	var measured_sums: Array[float] = []
	for second in range(1, RUDDER_HOLD_SECONDS + 1):
		for _tick in range(SIMULATION_HZ):
			await physics_frame
		var nav: Dictionary = _boat.call("get_navigation_snapshot")
		var physics: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
		if second == 1 and target_deg <= -34.0:
			var first_second_rudder := rad_to_deg(float(physics.get("actual_rudder_angle_rad", 0.0)))
			if first_second_rudder > -34.5:
				_failures.append("%s did not reach the left mechanical stop within 1 s (actual %.2f°)." % [case_name, first_second_rudder])
			var initial_left_moment := float(physics.get("rudder_yaw_torque_local_nm", 0.0))
			if initial_left_moment <= 0.0:
				_failures.append("%s left rudder did not produce the expected positive local +Y yaw moment at 1 s (%.3f N·m)." % [case_name, initial_left_moment])
		var heading := float(nav.get("heading_degrees", 0.0))
		unwrapped_heading += wrapf(heading - previous_heading, -180.0, 180.0)
		previous_heading = heading
		maximum_heading = maxf(maximum_heading, unwrapped_heading)
		minimum_heading = minf(minimum_heading, unwrapped_heading)
		_record_sample(case_name, second, nav, physics, unwrapped_heading)
		yaw_rates.append(-rad_to_deg(float(physics.get("yaw_rate_rad_s", 0.0))))
		rudder_torques.append(float(physics.get("rudder_yaw_torque_local_nm", 0.0)))
		measured_sums.append(float(physics.get("summed_measured_yaw_torque_local_nm", 0.0)))
		if second % 10 == 0:
			print("[S1-C6.2][%s t=%ds] HDG=%.2f° SOG=%.3fkn rudder=%+.2f° HDG_rate=%+.3f°/s M_rudder=%+.1f Nm M_measured=%+.1f Nm" % [
				case_name, second, heading, float(nav.get("sog_knots", 0.0)), rad_to_deg(float(physics.get("actual_rudder_angle_rad", 0.0))),
				-rad_to_deg(float(physics.get("yaw_rate_rad_s", 0.0))), float(physics.get("rudder_yaw_torque_local_nm", 0.0)),
				float(physics.get("summed_measured_yaw_torque_local_nm", 0.0)),
			])
	var end_nav: Dictionary = _boat.call("get_navigation_snapshot")
	var end_physics: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
	var debug: Dictionary = _boat.call("get_debug_snapshot")
	if int(debug.get("wind_query_count_per_tick", -1)) != 1:
		_failures.append("%s used %d WindField queries in the sampled physics tick, expected 1." % [case_name, int(debug.get("wind_query_count_per_tick", -1))])
	if int(debug.get("wave_query_count_per_tick", -1)) != 0:
		_failures.append("%s used %d WaveSampler queries in static-water diagnosis, expected 0." % [case_name, int(debug.get("wave_query_count_per_tick", -1))])
	_summary_rows.append(_csv([
		case_name, str(_precondition_seconds), str(_precondition_matched), _n(float(replay_start_nav.get("heading_degrees", 0.0))),
		_n(float(replay_start_nav.get("sog_knots", 0.0))), _n(float(control_start_nav.get("heading_degrees", 0.0))),
		_n(float(control_start_nav.get("sog_knots", 0.0))), _n(float(end_nav.get("heading_degrees", 0.0))),
		_n(float(end_nav.get("sog_knots", 0.0))), _n(float(end_physics.get("longitudinal_velocity_mps", 0.0))),
		_n(float(end_physics.get("lateral_velocity_mps", 0.0))), _n(float(end_physics.get("yaw_rate_rad_s", 0.0))),
		_n(minimum_heading), _n(maximum_heading), _n(_mean_last(yaw_rates, 10)), _n(_mean_last(rudder_torques, 10)),
		_n(_mean_last(measured_sums, 10)), _n(float(debug.get("total_physics_calculation_average_usec", 0))),
		_n(float(debug.get("total_physics_calculation_p95_usec", 0))), _n(float(debug.get("wind_query_count_per_tick", 0))),
		_n(float(debug.get("wave_query_count_per_tick", 0))), _n(target_deg),
	]))
	_run_count += 1


func _record_sample(case_name: String, second: int, nav: Dictionary, physics: Dictionary, unwrapped_heading: float) -> void:
	var actual_rudder := float(physics.get("actual_rudder_angle_rad", 0.0))
	var target_rudder := float(physics.get("target_rudder_angle_rad", 0.0))
	var max_rudder := float(PROFILE.get("max_rudder_angle_rad"))
	var at_limit := absf(actual_rudder) >= maxf(max_rudder - deg_to_rad(0.5), 0.0)
	var limit_label := "left" if actual_rudder < 0.0 else "right" if actual_rudder > 0.0 else "none"
	if not at_limit:
		limit_label = "none"
	var heading_rate := -rad_to_deg(float(physics.get("yaw_rate_rad_s", 0.0)))
	_time_rows.append(_csv([
		case_name, str(second), _n(float(nav.get("heading_degrees", 0.0))), _n(unwrapped_heading), _n(float(nav.get("sog_knots", 0.0))),
		_n(float(physics.get("longitudinal_velocity_mps", 0.0))), _n(float(physics.get("lateral_velocity_mps", 0.0))),
		_n(float(nav.get("true_wind_from_relative_degrees", 0.0))), _n(float(nav.get("apparent_wind_from_relative_degrees", 0.0))),
		_n(rad_to_deg(target_rudder)), _n(rad_to_deg(actual_rudder)), str(at_limit), limit_label,
		_n(rad_to_deg(float(physics.get("yaw_rate_rad_s", 0.0)))), _n(heading_rate),
		_n(float(physics.get("rudder_water_speed_mps", 0.0))), _n(rad_to_deg(float(_boat.get_debug_snapshot().get("rudder_angle_of_attack_rad", 0.0)))),
	]))
	_torque_rows.append(_csv([
		case_name, str(second), _n(float(physics.get("sail_yaw_torque_local_nm", 0.0))),
		_n(float(physics.get("headsail_yaw_torque_local_nm", 0.0))), _n(float(physics.get("keel_yaw_torque_local_nm", 0.0))),
		_n(float(physics.get("rudder_yaw_torque_local_nm", 0.0))), _n(float(physics.get("explicit_yaw_damping_torque_local_nm", 0.0))),
		_n(float(physics.get("summed_measured_yaw_torque_local_nm", 0.0))), _n(float(physics.get("summed_measured_yaw_torque_world_vertical_nm", 0.0))),
	]))


func _precondition_csv_row(second: int, nav: Dictionary, physics: Dictionary) -> String:
	return _csv([
		str(second), _n(float(nav.get("heading_degrees", 0.0))), _n(float(nav.get("sog_knots", 0.0))),
		_n(float(physics.get("longitudinal_velocity_mps", 0.0))), _n(float(physics.get("lateral_velocity_mps", 0.0))),
		_n(rad_to_deg(float(physics.get("yaw_rate_rad_s", 0.0)))), _n(float(nav.get("true_wind_from_relative_degrees", 0.0))),
		_n(float(nav.get("apparent_wind_from_relative_degrees", 0.0))), _n(float(physics.get("sail_yaw_torque_local_nm", 0.0))),
		_n(float(physics.get("headsail_yaw_torque_local_nm", 0.0))), _n(float(physics.get("keel_yaw_torque_local_nm", 0.0))),
		_n(float(physics.get("rudder_yaw_torque_local_nm", 0.0))), _n(float(physics.get("summed_measured_yaw_torque_local_nm", 0.0))),
	])


func _precondition_heading() -> float:
	var columns := _precondition_rows[_precondition_seconds].split(",")
	return float(columns[1])


func _precondition_sog() -> float:
	var columns := _precondition_rows[_precondition_seconds].split(",")
	return float(columns[2])


func _write_outputs() -> void:
	_write_c6_2_csv("free_sailing_precondition.csv", "sim_time_s,heading_deg,sog_knots,v_long_mps,v_lat_mps,local_yaw_rate_deg_s,twa_deg,awa_relative_from_deg,main_yaw_torque_local_nm,jib_yaw_torque_local_nm,keel_yaw_torque_local_nm,rudder_yaw_torque_local_nm,measured_yaw_subtotal_local_nm\n" + "\n".join(_precondition_rows) + "\n")
	_write_c6_2_csv("rudder_time_series.csv", "case,steering_time_s,heading_deg,heading_unwrapped_deg,sog_knots,v_long_mps,v_lat_mps,twa_relative_deg,awa_relative_from_deg,rudder_target_deg,rudder_actual_deg,rudder_at_mechanical_limit,limit_side,local_yaw_rate_deg_s,hdg_rate_deg_s,rudder_water_speed_mps,rudder_aoa_deg\n" + "\n".join(_time_rows) + "\n")
	_write_c6_2_csv("yaw_torque_decomposition.csv", "case,steering_time_s,main_sail_yaw_torque_local_y_nm,jib_yaw_torque_local_y_nm,keel_yaw_torque_local_y_nm,rudder_yaw_torque_local_y_nm,explicit_yaw_damping_local_y_nm,measured_subtotal_local_y_nm,measured_subtotal_world_vertical_nm\n" + "\n".join(_torque_rows) + "\n")
	_write_c6_2_csv("rudder_case_summary.csv", "case,precondition_time_s,precondition_matched_target,precondition_hdg_deg,precondition_sog_knots,control_start_hdg_deg,control_start_sog_knots,end_hdg_deg,end_sog_knots,end_v_long_mps,end_v_lat_mps,end_local_yaw_rate_rad_s,min_unwrapped_hdg_deg,max_unwrapped_hdg_deg,mean_last10_hdg_rate_deg_s,mean_last10_rudder_torque_local_nm,mean_last10_measured_subtotal_nm,physics_avg_usec,physics_p95_usec,wind_queries_per_tick,wave_queries_per_tick,rudder_target_deg\n" + "\n".join(_summary_rows) + "\n")


func _write_c6_2_csv(filename: String, content: String) -> void:
	var path := ProjectSettings.globalize_path(C6_2_DATA_DIR.path_join(filename))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_failures.append("Could not write %s: %s" % [path, error_string(FileAccess.get_open_error())])
		return
	file.store_string(content)
	file.close()
