extends "res://tests/run_sailboat_s1_c5c_drag_diagnostics.gd"
## Offline Auto Sail Trim validation using the production SailboatLab RigidBody3D.

const C7A_DATA_DIR := "res://docs/sailing/c7a_data"
const FIXED_TRIM_SECONDS := 120
const AUTO_LONG_SECONDS := 120
const STEERING_PRELUDE_SECONDS := 20
const STEERING_HOLD_SECONDS := 60

var _history_rows: Array[String] = []
var _steering_rows: Array[String] = []
var _wind_case_rows: Array[String] = []
var _comparison_rows: Array[String] = []
var _performance_rows: Array[String] = []


func _run() -> void:
	_started_usec = Time.get_ticks_usec()
	_original_physics_hz = Engine.physics_ticks_per_second
	_original_time_scale = Engine.time_scale
	Engine.physics_ticks_per_second = int(SIMULATION_HZ * OFFLINE_TIME_SCALE)
	Engine.time_scale = OFFLINE_TIME_SCALE
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(C7A_DATA_DIR))
	for wind_speed in [0.0, 3.0, 8.0, 12.0]:
		var duration := AUTO_LONG_SECONDS if is_equal_approx(float(wind_speed), 8.0) else 30
		var label := "auto_%02dms" % int(wind_speed)
		var result := await _run_case(label, float(wind_speed), 270.0, "auto", duration, 0.0, 0.0)
		_wind_case_rows.append(_summary_csv(label, float(wind_speed), duration, result))
	for test_case in [
		{"label": "manual_positive_60_45", "main": 60.0, "jib": 45.0},
		{"label": "manual_negative_60_45", "main": -60.0, "jib": -45.0},
	]:
		var label := str(test_case["label"])
		var result := await _run_case(label, 8.0, 270.0, "manual", FIXED_TRIM_SECONDS, float(test_case["main"]), float(test_case["jib"]))
		_wind_case_rows.append(_summary_csv(label, 8.0, FIXED_TRIM_SECONDS, result))
	var steering_result := await _run_auto_steering_case()
	_wind_case_rows.append(_summary_csv("auto_8ms_left_rudder", 8.0, STEERING_PRELUDE_SECONDS + STEERING_HOLD_SECONDS, steering_result))
	_write_outputs()
	var elapsed := float(Time.get_ticks_usec() - _started_usec) / 1_000_000.0
	Engine.physics_ticks_per_second = _original_physics_hz
	Engine.time_scale = _original_time_scale
	if _failures.is_empty():
		print("[S1-C7a] runs=%d simulated=%ds wall=%.2fs output=docs/sailing/c7a_data/" % [_run_count, 30 * 3 + AUTO_LONG_SECONDS + FIXED_TRIM_SECONDS * 2 + STEERING_PRELUDE_SECONDS + STEERING_HOLD_SECONDS, elapsed])
		quit(0)
	else:
		for failure in _failures:
			push_error("[S1-C7a] " + failure)
		quit(1)


func _run_case(case_name: String, wind_speed: float, wind_from: float, mode: String, duration_seconds: int, main_degrees: float, jib_degrees: float) -> Dictionary:
	if not await _configure_lab(wind_speed, wind_from, main_degrees, 0.0, {}):
		return {}
	_boat.call("set_headsail_enabled", true)
	if mode == "auto":
		_boat.call("set_auto_sail_trim_enabled", true)
	else:
		_boat.set("actual_sail_angle_rad", deg_to_rad(main_degrees))
		_boat.call("set_target_sail_angle", deg_to_rad(main_degrees))
		_boat.set("actual_headsail_angle_rad", deg_to_rad(jib_degrees))
		_boat.call("set_target_headsail_angle", deg_to_rad(jib_degrees))
	_wind.call("set_test_simulation_time", 0.0)
	return await _record_case(case_name, wind_speed, mode, duration_seconds, false)


func _run_auto_steering_case() -> Dictionary:
	if not await _configure_lab(8.0, 270.0, 0.0, 0.0, {}):
		return {}
	_boat.call("set_headsail_enabled", true)
	_boat.call("set_auto_sail_trim_enabled", true)
	_wind.call("set_test_simulation_time", 0.0)
	return await _record_case("auto_8ms_left_rudder", 8.0, "auto", STEERING_PRELUDE_SECONDS + STEERING_HOLD_SECONDS, true)


func _record_case(case_name: String, wind_speed: float, mode: String, duration_seconds: int, hold_left_rudder: bool) -> Dictionary:
	var auto_times := PackedInt64Array()
	var total_physics_average := 0
	var total_physics_p95 := 0
	var wind_queries := 0
	var wave_queries := 0
	var last_navigation: Dictionary = _boat.call("get_navigation_snapshot")
	var last_debug: Dictionary = _boat.call("get_debug_snapshot")
	var left_rudder_set := false
	_append_history_row(case_name, 0, wind_speed, mode, last_navigation, last_debug)
	for tick in range(1, duration_seconds * SIMULATION_HZ + 1):
		await physics_frame
		var elapsed_seconds := float(tick) / float(SIMULATION_HZ)
		if hold_left_rudder and not left_rudder_set and elapsed_seconds >= float(STEERING_PRELUDE_SECONDS):
			var max_rudder := float(_boat.call("get_navigation_snapshot").get("max_rudder_angle_rad", 0.611))
			_boat.call("set_target_rudder_angle", -max_rudder)
			left_rudder_set = true
		last_navigation = _boat.call("get_navigation_snapshot")
		last_debug = _boat.call("get_debug_snapshot")
		wind_queries += int(last_debug.get("wind_query_count_per_tick", 0))
		wave_queries += int(last_debug.get("wave_query_count_per_tick", 0))
		auto_times.append(int(last_debug.get("auto_trim_calculation_usec", 0)))
		total_physics_average = int(last_debug.get("total_physics_calculation_average_usec", 0))
		total_physics_p95 = int(last_debug.get("total_physics_calculation_p95_usec", 0))
		if tick % SIMULATION_HZ == 0:
			_append_history_row(case_name, int(elapsed_seconds), wind_speed, mode, last_navigation, last_debug)
		if tick % (30 * SIMULATION_HZ) == 0:
			print("[S1-C7a][%s t=%ds] HDG=%.1f° SOG=%.3fkn AWA=%+.1f° main=%+.1f° Jib=%+.1f°" % [
				case_name, int(elapsed_seconds), float(last_navigation.get("heading_degrees", 0.0)),
				float(last_navigation.get("sog_knots", 0.0)),
				float(last_navigation.get("apparent_wind_from_relative_degrees", 0.0)),
				rad_to_deg(float(last_navigation.get("actual_sail_angle_rad", 0.0))),
				rad_to_deg(float(last_navigation.get("actual_headsail_angle_rad", 0.0))),
			])
	var timing := _summarize_integer_values(auto_times)
	var auto_avg := int(timing.get("average_usec", 0))
	var auto_p95 := int(timing.get("p95_usec", 0))
	_performance_rows.append(_csv([case_name, mode, _n(float(duration_seconds)), _n(float(auto_avg)), _n(float(auto_p95)), _n(float(wind_queries) / float(maxi(duration_seconds * SIMULATION_HZ, 1))), _n(float(wave_queries) / float(maxi(duration_seconds * SIMULATION_HZ, 1))), str(total_physics_average), str(total_physics_p95)]))
	_run_count += 1
	return {
		"navigation": last_navigation,
		"debug": last_debug,
		"auto_trim_average_usec": auto_avg,
		"auto_trim_p95_usec": auto_p95,
		"wind_queries_per_tick": float(wind_queries) / float(maxi(duration_seconds * SIMULATION_HZ, 1)),
		"wave_queries_per_tick": float(wave_queries) / float(maxi(duration_seconds * SIMULATION_HZ, 1)),
		"total_physics_average_usec": total_physics_average,
		"total_physics_p95_usec": total_physics_p95,
	}


func _append_history_row(case_name: String, time_seconds: int, wind_speed: float, mode: String, navigation: Dictionary, debug: Dictionary) -> void:
	var auto_trim: Dictionary = navigation.get("auto_sail_trim", {})
	var main_force: Vector3 = debug.get("sail_net_force_local_n", Vector3.ZERO)
	var jib_force: Vector3 = debug.get("headsail_net_force_local_n", Vector3.ZERO)
	var row := _csv([
		case_name, str(time_seconds), _n(wind_speed), mode,
		_n(float(navigation.get("heading_degrees", 0.0))), _n(float(navigation.get("sog_knots", 0.0))),
		_n(float(debug.get("longitudinal_velocity_mps", 0.0))), _n(float(debug.get("lateral_velocity_mps", 0.0))),
		_n(float(navigation.get("true_wind_from_relative_degrees", 0.0))), _n(float(navigation.get("apparent_wind_from_relative_degrees", 0.0))),
		_n(float(navigation.get("apparent_wind_speed_mps", 0.0))),
		_n(rad_to_deg(float(navigation.get("actual_sail_angle_rad", 0.0)))), _n(rad_to_deg(float(navigation.get("target_sail_angle_rad", 0.0)))),
		_n(rad_to_deg(float(navigation.get("actual_headsail_angle_rad", 0.0)))), _n(rad_to_deg(float(navigation.get("target_headsail_angle_rad", 0.0)))),
		_n(rad_to_deg(float(navigation.get("actual_rudder_angle_rad", 0.0)))), _n(rad_to_deg(float(navigation.get("target_rudder_angle_rad", 0.0)))),
		_n(-main_force.z), _n(-jib_force.z),
		_n(float(debug.get("sail_yaw_torque_nm", 0.0))), _n(float(debug.get("headsail_yaw_torque_nm", 0.0))),
		_n(float(debug.get("keel_yaw_torque_nm", 0.0))), _n(float(debug.get("rudder_yaw_torque_nm", 0.0))),
		_n(float(navigation.get("heel_degrees", 0.0))), str(auto_trim.get("selected_side", "")), str(auto_trim.get("status", "")),
		str(bool(auto_trim.get("no_go", false))), str(debug.get("wind_query_count_per_tick", 0)), str(debug.get("wave_query_count_per_tick", 0)),
		str(debug.get("auto_trim_calculation_usec", 0)),
	])
	if case_name == "auto_08ms":
		_history_rows.append(row)
	elif case_name == "auto_8ms_left_rudder":
		_steering_rows.append(row)


func _summary_csv(case_name: String, wind_speed: float, duration_seconds: int, result: Dictionary) -> String:
	var navigation: Dictionary = result.get("navigation", {})
	var debug: Dictionary = result.get("debug", {})
	var auto_trim: Dictionary = navigation.get("auto_sail_trim", {})
	return _csv([
		case_name, _n(wind_speed), str(duration_seconds), str(navigation.get("auto_sail_trim_enabled", false)),
		_n(float(navigation.get("heading_degrees", 0.0))), _n(float(navigation.get("sog_knots", 0.0))),
		_n(float(debug.get("longitudinal_velocity_mps", 0.0))), _n(float(debug.get("lateral_velocity_mps", 0.0))),
		_n(float(navigation.get("true_wind_from_relative_degrees", 0.0))), _n(float(navigation.get("apparent_wind_from_relative_degrees", 0.0))),
		_n(float(navigation.get("apparent_wind_speed_mps", 0.0))),
		_n(rad_to_deg(float(navigation.get("actual_sail_angle_rad", 0.0)))), _n(rad_to_deg(float(navigation.get("target_sail_angle_rad", 0.0)))),
		_n(rad_to_deg(float(navigation.get("actual_headsail_angle_rad", 0.0)))), _n(rad_to_deg(float(navigation.get("target_headsail_angle_rad", 0.0)))),
		_n(rad_to_deg(float(navigation.get("actual_rudder_angle_rad", 0.0)))), _n(rad_to_deg(float(navigation.get("target_rudder_angle_rad", 0.0)))),
		_n(float(debug.get("sail_yaw_torque_nm", 0.0))), _n(float(debug.get("headsail_yaw_torque_nm", 0.0))),
		_n(float(debug.get("rudder_yaw_torque_nm", 0.0))), _n(float(navigation.get("heel_degrees", 0.0))),
		str(auto_trim.get("selected_side", "")), str(auto_trim.get("status", "")), str(bool(auto_trim.get("no_go", false))),
		_n(float(result.get("auto_trim_average_usec", 0))), _n(float(result.get("auto_trim_p95_usec", 0))),
		_n(float(result.get("total_physics_average_usec", 0))), _n(float(result.get("total_physics_p95_usec", 0))),
		_n(float(result.get("wind_queries_per_tick", 0))), _n(float(result.get("wave_queries_per_tick", 0))),
	])


func _summarize_integer_values(values: PackedInt64Array) -> Dictionary:
	if values.is_empty():
		return {"average_usec": 0, "p95_usec": 0}
	var sorted_values := values.duplicate()
	sorted_values.sort()
	var total := 0
	for value in sorted_values:
		total += value
	var p95_index := clampi(int(ceil(float(sorted_values.size() - 1) * 0.95)), 0, sorted_values.size() - 1)
	return {"average_usec": int(round(float(total) / float(sorted_values.size()))), "p95_usec": sorted_values[p95_index]}


func _write_outputs() -> void:
	var history_header := "case,time_s,tws_mps,mode,heading_deg,sog_knots,longitudinal_mps,lateral_mps,twa_deg,awa_deg,aws_mps,main_actual_deg,main_target_deg,jib_actual_deg,jib_target_deg,rudder_actual_deg,rudder_target_deg,main_forward_force_n,jib_forward_force_n,main_yaw_torque_nm,jib_yaw_torque_nm,keel_yaw_torque_nm,rudder_yaw_torque_nm,heel_deg,selected_sheet_side,status,no_go,wind_queries_per_tick,wave_queries_per_tick,auto_calculation_usec\n"
	_write_c7a_csv("auto_trim_history_8ms.csv", history_header + "\n".join(_history_rows) + "\n")
	_write_c7a_csv("auto_left_rudder_history.csv", history_header + "\n".join(_steering_rows) + "\n")
	_write_c7a_csv("wind_cases_and_fixed_trim_comparison.csv", "case,tws_mps,duration_s,auto_enabled,final_heading_deg,final_sog_knots,final_longitudinal_mps,final_lateral_mps,final_twa_deg,final_awa_deg,final_aws_mps,main_actual_deg,main_target_deg,jib_actual_deg,jib_target_deg,rudder_actual_deg,rudder_target_deg,main_yaw_torque_nm,jib_yaw_torque_nm,rudder_yaw_torque_nm,heel_deg,selected_sheet_side,status,no_go,auto_trim_average_usec,auto_trim_p95_usec,total_physics_average_usec,total_physics_p95_usec,wind_queries_per_tick,wave_queries_per_tick\n" + "\n".join(_wind_case_rows) + "\n")
	_write_c7a_csv("auto_trim_performance.csv", "case,mode,duration_s,auto_calculation_average_usec,auto_calculation_p95_usec,wind_queries_per_tick,wave_queries_per_tick,total_physics_average_usec,total_physics_p95_usec\n" + "\n".join(_performance_rows) + "\n")


func _write_c7a_csv(filename: String, content: String) -> void:
	var file := FileAccess.open(C7A_DATA_DIR.path_join(filename), FileAccess.WRITE)
	if file == null:
		_failures.append("Could not write %s: %s" % [filename, error_string(FileAccess.get_open_error())])
		return
	file.store_string(content)
