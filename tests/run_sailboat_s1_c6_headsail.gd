extends "res://tests/run_sailboat_s1_c5e_polar.gd"
## S1-C6 offline comparison. Reuses the production SailboatLab rigid body,
## C5e's real-rudder course controller, and the published C5e mainsail trims.

const C6_DATA_DIR := "res://docs/sailing/c6_data"
const C6_AERO_MATH := preload("res://scripts/sailboat_aero_math.gd")
const MATRIX_CASES := [
	{"tws": 5.0, "twa": 60.0}, {"tws": 5.0, "twa": 90.0}, {"tws": 5.0, "twa": 120.0},
	{"tws": 8.0, "twa": 45.0}, {"tws": 8.0, "twa": 60.0}, {"tws": 8.0, "twa": 90.0},
	{"tws": 8.0, "twa": 120.0}, {"tws": 8.0, "twa": 150.0},
	{"tws": 12.0, "twa": 60.0}, {"tws": 12.0, "twa": 90.0}, {"tws": 12.0, "twa": 120.0},
]
const MIRROR_CASES := [
	{"tws": 8.0, "twa": -90.0}, {"tws": 8.0, "twa": -120.0},
]
const TRIM_SCREEN_ANGLES := [-60.0, -45.0, -30.0, -15.0, 0.0]

var _c6_phase := "all"
var _geometry_lines: Array[String] = []
var _comparison_lines: Array[String] = []
var _trim_lines: Array[String] = []
var _force_lines: Array[String] = []
var _performance_lines: Array[String] = []
var _wave_performance_lines: Array[String] = []


func _run() -> void:
	_started_usec = Time.get_ticks_usec()
	_original_physics_hz = Engine.physics_ticks_per_second
	_original_time_scale = Engine.time_scale
	Engine.physics_ticks_per_second = int(SIMULATION_HZ * OFFLINE_TIME_SCALE)
	Engine.time_scale = OFFLINE_TIME_SCALE
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--phase="):
			_c6_phase = argument.trim_prefix("--phase=")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(C6_DATA_DIR))
	_write_geometry_data()
	if _c6_phase == "all" or _c6_phase == "matrix":
		await _run_matrix_cases()
	if _c6_phase == "all" or _c6_phase == "long":
		await _run_long_cases()
	if _c6_phase == "all" or _c6_phase == "trim":
		await _run_trim_scan()
	if _c6_phase == "all" or _c6_phase == "wave_performance":
		await _run_dynamic_wave_performance()
	if _c6_phase not in ["all", "matrix", "long", "trim", "wave_performance", "geometry"]:
		_failures.append("Unknown C6 phase '%s'. Use all, matrix, long, trim, wave_performance, or geometry." % _c6_phase)
	_write_c6_outputs()
	var elapsed := float(Time.get_ticks_usec() - _started_usec) / 1_000_000.0
	Engine.physics_ticks_per_second = _original_physics_hz
	Engine.time_scale = _original_time_scale
	if _failures.is_empty():
		print("[S1-C6] phase=%s simulated_groups=%d wall=%.2fs output=docs/sailing/c6_data/" % [_c6_phase, _run_count, elapsed])
		quit(0)
	else:
		for failure in _failures:
			push_error("[S1-C6] " + failure)
		quit(1)


func _write_geometry_data() -> void:
	var head := Vector3(0.0, 4.95, -0.75)
	var tack := Vector3(0.0, 0.65, -3.55)
	var neutral_clew := Vector3(0.0, 0.65, -1.15)
	var neutral_area := C6_AERO_MATH.triangular_sail_area_m2(head, tack, neutral_clew)
	for angle_degrees in [-70.0, -60.0, -30.0, 0.0, 30.0, 60.0, 70.0]:
		var angle := deg_to_rad(float(angle_degrees))
		var clew := C6_AERO_MATH.headsail_clew_from_sheet(tack, neutral_clew, angle)
		var actual_area := C6_AERO_MATH.triangular_sail_area_m2(head, tack, clew)
		var centroid := C6_AERO_MATH.triangular_sail_centroid(head, tack, clew)
		_geometry_lines.append(_csv([
			_n(float(angle_degrees)), _n(neutral_area), _n(actual_area),
			_n(head.x), _n(head.y), _n(head.z), _n(tack.x), _n(tack.y), _n(tack.z),
			_n(clew.x), _n(clew.y), _n(clew.z), _n(centroid.x), _n(centroid.y), _n(centroid.z),
		]))


func _run_matrix_cases() -> void:
	var all_cases: Array[Dictionary] = []
	for item in MATRIX_CASES:
		all_cases.append(item)
	for item in MIRROR_CASES:
		all_cases.append(item)
	var case_index := 0
	for test_case in all_cases:
		case_index += 1
		await _run_comparison_case(test_case, 20, false)
		if case_index % 4 == 0 or case_index == all_cases.size():
			print("[S1-C6][matrix %d/%d] TWS=%.0f TWA=%+.0f°" % [case_index, all_cases.size(), float(test_case["tws"]), float(test_case["twa"])])


func _run_long_cases() -> void:
	for test_case in [
		{"tws": 5.0, "twa": 90.0},
		{"tws": 8.0, "twa": 90.0},
		{"tws": 8.0, "twa": 120.0},
		{"tws": 12.0, "twa": 90.0},
	]:
		await _run_comparison_case(test_case, 120, true)


func _run_comparison_case(test_case: Dictionary, duration_seconds: int, long_run: bool) -> void:
	var tws := float(test_case["tws"])
	var twa := float(test_case["twa"])
	var main_trim := _published_main_trim(tws, absf(twa)) * signf(twa)
	if absf(twa) < 0.1:
		main_trim = _published_main_trim(tws, 180.0)
	var jib_trim := -signf(twa) * clampf(absf(twa) * 0.5, 20.0, 65.0)
	if absf(twa) > 179.0:
		jib_trim = 0.0
	var result_by_mode: Dictionary = {}
	for mode in ["main_only", "jib_only", "dual"]:
		if not await _prepare_c6_case(tws, twa, main_trim, jib_trim, mode):
			return
		var run_result := await _run_controlled_case(duration_seconds, twa)
		var samples: Array = run_result.get("samples", [])
		var summary: Dictionary
		var status: String
		if long_run:
			var previous := _aggregate(samples, 60.0, 90.0, twa)
			summary = _aggregate(samples, 90.0, 120.0, twa)
			status = _classify_with_previous(summary, previous, twa)
		else:
			summary = _aggregate(samples, float(duration_seconds - 10), float(duration_seconds), twa)
			status = _classify(summary, twa)
			if status == "screen_only":
				status = "screen_only_not_steady_test"
		var debug: Dictionary = _boat.call("get_debug_snapshot")
		var snapshot := _comparison_row(tws, twa, main_trim, jib_trim, mode, duration_seconds, status, summary, samples, debug)
		result_by_mode[mode] = snapshot
		_run_count += 1
	var main_row: Dictionary = result_by_mode.get("main_only", {})
	if main_row.is_empty():
		return
	for mode in ["main_only", "jib_only", "dual"]:
		if not result_by_mode.has(mode):
			continue
		var row: Dictionary = result_by_mode[mode]
		var main_sog := float(main_row.get("mean_sog_kn", 0.0))
		var main_vlong := float(main_row.get("mean_vlong_mps", 0.0))
		_comparison_lines.append(_csv([
			_n(tws), _n(twa), str(mode), _n(float(row["duration_s"])), _n(main_trim), _n(jib_trim),
			_n(float(row["mean_sog_kn"])), _n(float(row["mean_vlong_mps"])), _n(float(row["mean_vlat_mps"])),
			_n(float(row["mean_twa_deg"])), _n(float(row["mean_aws_mps"])), _n(float(row["mean_heel_deg"])),
			_n(float(row["mean_sideslip_deg"])), _n(float(row["mean_abs_heading_error_deg"])), _n(float(row["mean_abs_rudder_deg"])),
			_n(float(row["mean_sail_forward_n"])), _n(float(row["mean_headsail_forward_n"])), _n(float(row["mean_headsail_lateral_n"])),
			_n(float(row["mean_headsail_roll_torque_nm"])), _n(float(row["mean_sail_yaw_torque_nm"])), _n(float(row["mean_headsail_yaw_torque_nm"])),
			_n(float(row["mean_keel_yaw_torque_nm"])), _n(float(row["mean_rudder_yaw_torque_nm"])),
			_n(float(row["mean_forward_displacement_m"])),
			_n(float(row["mean_sog_kn"]) - main_sog), _n(float(row["mean_vlong_mps"]) - main_vlong),
			str(row["status"]), _n(float(row["total_physics_average_usec"])), _n(float(row["total_physics_p95_usec"])),
			_n(float(row["aero_average_usec"])), _n(float(row["aero_p95_usec"])),
			_n(float(row["headsail_average_usec"])), _n(float(row["headsail_p95_usec"])),
			str(row["wind_query_count"]), str(row["wave_query_count"]),
		]))
		_force_lines.append(_csv([
			_n(tws), _n(twa), str(mode), _n(float(row["mean_sail_forward_n"])),
			_n(float(row["mean_headsail_forward_n"])), _n(float(row["mean_headsail_lateral_n"])),
			_n(float(row["mean_headsail_roll_torque_nm"])), _n(float(row["mean_sail_yaw_torque_nm"])), _n(float(row["mean_headsail_yaw_torque_nm"])),
			_n(float(row["mean_keel_yaw_torque_nm"])), _n(float(row["mean_rudder_yaw_torque_nm"])),
			_n(float(row["mean_abs_rudder_deg"])), str(row["status"]),
		]))
		_performance_lines.append(_csv([
			"static_water", _n(tws), _n(twa), str(mode), _n(float(row["duration_s"])),
			_n(float(row["total_physics_average_usec"])), _n(float(row["total_physics_p95_usec"])),
			_n(float(row["aero_average_usec"])), _n(float(row["aero_p95_usec"])),
			_n(float(row["headsail_average_usec"])), _n(float(row["headsail_p95_usec"])),
			str(row["wind_query_count"]), str(row["wave_query_count"]),
		]))


func _prepare_c6_case(tws: float, twa: float, main_trim: float, jib_trim: float, mode: String) -> bool:
	if not await _prepare_case(tws, twa, main_trim):
		return false
	var main_area := float(PROFILE.get("main_sail_area_m2"))
	_boat.set("_sail_area_m2", 0.0 if mode == "jib_only" else main_area)
	_boat.call("set_headsail_enabled", mode != "main_only")
	_boat.set("actual_headsail_angle_rad", deg_to_rad(jib_trim))
	_boat.call("set_target_headsail_angle", deg_to_rad(jib_trim))
	_boat.call("reset_performance_history")
	_boat.sleeping = false
	return true


func _comparison_row(
	tws: float,
	twa: float,
	main_trim: float,
	jib_trim: float,
	mode: String,
	duration_seconds: int,
	status: String,
	summary: Dictionary,
	samples: Array,
	debug: Dictionary
) -> Dictionary:
	var sample_count := maxf(float(samples.size()), 1.0)
	var last_sample: Dictionary = samples.back() if not samples.is_empty() else {}
	return {
		"tws": tws,
		"twa": twa,
		"mode": mode,
		"duration_s": float(duration_seconds),
		"main_trim_deg": main_trim,
		"jib_trim_deg": jib_trim,
		"mean_sog_kn": float(summary.get("mean_sog_kn", 0.0)),
		"mean_vlong_mps": float(summary.get("mean_vlong_mps", 0.0)),
		"mean_vlat_mps": float(summary.get("mean_vlat_mps", 0.0)),
		"mean_twa_deg": float(summary.get("mean_twa_deg", 0.0)),
		"mean_aws_mps": float(summary.get("mean_aws_mps", 0.0)),
		"mean_heel_deg": float(summary.get("mean_heel_deg", 0.0)),
		"mean_sideslip_deg": float(summary.get("mean_sideslip_deg", 0.0)),
		"mean_abs_heading_error_deg": float(summary.get("mean_abs_heading_error_deg", 0.0)),
		"mean_abs_rudder_deg": float(summary.get("mean_abs_rudder_deg", 0.0)),
		"mean_sail_forward_n": float(summary.get("mean_sail_forward_n", 0.0)),
		"mean_headsail_forward_n": float(summary.get("mean_headsail_forward_n", 0.0)),
		"mean_headsail_lateral_n": float(summary.get("mean_headsail_lateral_n", 0.0)),
		"mean_headsail_roll_torque_nm": float(summary.get("mean_headsail_roll_torque_nm", 0.0)),
		"mean_sail_yaw_torque_nm": float(summary.get("mean_sail_yaw_torque_nm", 0.0)),
		"mean_headsail_yaw_torque_nm": float(summary.get("mean_headsail_yaw_torque_nm", 0.0)),
		"mean_keel_yaw_torque_nm": float(summary.get("mean_keel_yaw_torque_nm", 0.0)),
		"mean_rudder_yaw_torque_nm": float(summary.get("mean_rudder_yaw_torque_nm", 0.0)),
		"mean_forward_displacement_m": float(last_sample.get("forward_displacement_m", 0.0)),
		"status": status,
		"total_physics_average_usec": float(debug.get("total_physics_calculation_average_usec", 0)),
		"total_physics_p95_usec": float(debug.get("total_physics_calculation_p95_usec", 0)),
		"aero_average_usec": float(debug.get("aero_calculation_average_usec", 0)),
		"aero_p95_usec": float(debug.get("aero_calculation_p95_usec", 0)),
		"headsail_average_usec": float(debug.get("headsail_aero_calculation_average_usec", 0)),
		"headsail_p95_usec": float(debug.get("headsail_aero_calculation_p95_usec", 0)),
		"wind_query_count": int(debug.get("wind_query_count_per_tick", 0)),
		"wave_query_count": int(debug.get("wave_query_count_per_tick", 0)),
	}


func _run_trim_scan() -> void:
	var tws := 8.0
	var twa := 90.0
	var main_trim := _published_main_trim(tws, twa)
	for jib_trim in TRIM_SCREEN_ANGLES:
		if not await _prepare_c6_case(tws, twa, main_trim, float(jib_trim), "dual"):
			return
		var run_result := await _run_controlled_case(25, twa)
		var samples: Array = run_result.get("samples", [])
		var summary := _aggregate(samples, 15.0, 25.0, twa)
		var status := _classify(summary, twa)
		var debug: Dictionary = _boat.call("get_debug_snapshot")
		_trim_lines.append(_csv([
			_n(tws), _n(twa), _n(main_trim), _n(float(jib_trim)),
			_n(float(summary.get("mean_sog_kn", 0.0))), _n(float(summary.get("mean_vlong_mps", 0.0))),
			_n(float(summary.get("mean_abs_heading_error_deg", 0.0))), _n(float(summary.get("mean_abs_rudder_deg", 0.0))),
			_n(float(summary.get("mean_heel_deg", 0.0))), _n(float(summary.get("mean_headsail_forward_n", 0.0))),
			_n(float(summary.get("mean_headsail_roll_torque_nm", 0.0))), _n(float(summary.get("mean_headsail_yaw_torque_nm", 0.0))),
			_n(float(debug.get("total_physics_calculation_average_usec", 0))), status,
		]))
		_run_count += 1


func _run_dynamic_wave_performance() -> void:
	for mode in ["main_only", "dual"]:
		if not await _prepare_c6_case(8.0, 90.0, _published_main_trim(8.0, 90.0), -45.0, mode):
			return
		_boat.call("set_dynamic_waves_enabled", true)
		_boat.call("reset_performance_history")
		var run_result := await _run_controlled_case(20, 90.0)
		var samples: Array = run_result.get("samples", [])
		var summary := _aggregate(samples, 10.0, 20.0, 90.0)
		var debug: Dictionary = _boat.call("get_debug_snapshot")
		var wind_queries := int(debug.get("wind_query_count_per_tick", 0))
		var wave_queries := int(debug.get("wave_query_count_per_tick", 0))
		if wind_queries != 1 or wave_queries != 4:
			_failures.append("Dynamic-wave %s case queried wind=%d/waves=%d per step; expected 1/4." % [mode, wind_queries, wave_queries])
		_wave_performance_lines.append(_csv([
			"dynamic_waves", "8.0", "90.0", mode, "20.0",
			_n(float(summary.get("mean_sog_kn", 0.0))), _n(float(summary.get("mean_vlong_mps", 0.0))),
			_n(float(summary.get("mean_abs_heading_error_deg", 0.0))), _n(float(summary.get("mean_heel_deg", 0.0))), _n(float(summary.get("mean_headsail_roll_torque_nm", 0.0))),
			_n(float(debug.get("total_physics_calculation_average_usec", 0))), _n(float(debug.get("total_physics_calculation_p95_usec", 0))),
			_n(float(debug.get("aero_calculation_average_usec", 0))), _n(float(debug.get("aero_calculation_p95_usec", 0))),
			_n(float(debug.get("headsail_aero_calculation_average_usec", 0))), _n(float(debug.get("headsail_aero_calculation_p95_usec", 0))),
			str(wind_queries), str(wave_queries),
		]))
		_run_count += 1


func _published_main_trim(tws: float, twa: float) -> float:
	var path := ProjectSettings.globalize_path("res://docs/sailing/c5e_data/best_trim_by_wind_angle.csv")
	if not FileAccess.file_exists(path):
		return -50.0 if twa >= 45.0 and twa <= 120.0 else -60.0
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return -50.0
	var header := file.get_csv_line()
	var tws_column := header.find("tws_mps")
	var twa_column := header.find("target_twa_deg")
	var trim_column := header.find("selected_sail_angle_deg")
	var status_column := header.find("status")
	var fallback := -50.0
	while not file.eof_reached():
		var row := file.get_csv_line()
		if row.size() <= max(max(tws_column, twa_column), trim_column):
			continue
		if absf(float(row[tws_column]) - tws) < 0.01 and absf(float(row[twa_column]) - twa) < 0.1:
			fallback = float(row[trim_column])
			if status_column >= 0 and str(row[status_column]) != "steady":
				break
			break
	file.close()
	return fallback


func _write_c6_outputs() -> void:
	if not _geometry_lines.is_empty():
		_write_c6_csv("headsail_geometry_and_force.csv", "sheet_angle_deg,profile_cloth_area_m2,visual_triangle_area_m2,head_x_m,head_y_m,head_z_m,tack_x_m,tack_y_m,tack_z_m,clew_x_m,clew_y_m,clew_z_m,centroid_x_m,centroid_y_m,centroid_z_m\n" + "\n".join(_geometry_lines) + "\n")
	if not _comparison_lines.is_empty():
		_write_c6_csv("single_vs_double_sail.csv", "tws_mps,target_twa_deg,configuration,duration_s,main_trim_deg,jib_trim_deg,mean_sog_kn,mean_vlong_mps,mean_vlat_mps,mean_actual_twa_deg,mean_aws_mps,mean_heel_deg,mean_sideslip_deg,mean_abs_heading_error_deg,mean_abs_rudder_deg,mean_mainsail_forward_n,mean_jib_forward_n,mean_jib_lateral_n,mean_jib_roll_torque_nm,mean_mainsail_yaw_torque_nm,mean_jib_yaw_torque_nm,mean_keel_yaw_torque_nm,mean_rudder_yaw_torque_nm,forward_displacement_m,sog_delta_vs_main_kn,vlong_delta_vs_main_mps,status,total_physics_avg_usec,total_physics_p95_usec,aero_avg_usec,aero_p95_usec,jib_avg_usec,jib_p95_usec,wind_queries_per_step,wave_queries_per_step\n" + "\n".join(_comparison_lines) + "\n")
	if not _trim_lines.is_empty():
		_write_c6_csv("double_sail_trim_scan.csv", "tws_mps,target_twa_deg,mainsail_angle_deg,jib_angle_deg,mean_sog_kn,mean_vlong_mps,mean_heading_error_deg,mean_abs_rudder_deg,mean_heel_deg,mean_jib_forward_n,mean_jib_roll_torque_nm,mean_jib_yaw_torque_nm,total_physics_avg_usec,status\n" + "\n".join(_trim_lines) + "\n")
	if not _force_lines.is_empty():
		_write_c6_csv("double_sail_force_torque.csv", "tws_mps,target_twa_deg,configuration,mean_mainsail_forward_n,mean_jib_forward_n,mean_jib_lateral_n,mean_jib_roll_torque_nm,mean_mainsail_yaw_torque_nm,mean_jib_yaw_torque_nm,mean_keel_yaw_torque_nm,mean_rudder_yaw_torque_nm,mean_abs_rudder_deg,status\n" + "\n".join(_force_lines) + "\n")
	if not _performance_lines.is_empty():
		_write_c6_csv("sail_performance_comparison.csv", "water_mode,tws_mps,target_twa_deg,configuration,duration_s,total_physics_avg_usec,total_physics_p95_usec,aero_avg_usec,aero_p95_usec,jib_avg_usec,jib_p95_usec,wind_queries_per_step,wave_queries_per_step\n" + "\n".join(_performance_lines) + "\n")
	if not _wave_performance_lines.is_empty():
		_write_c6_csv("sail_performance_dynamic_waves.csv", "water_mode,tws_mps,target_twa_deg,configuration,duration_s,mean_sog_kn,mean_vlong_mps,mean_heading_error_deg,mean_heel_deg,mean_jib_roll_torque_nm,total_physics_avg_usec,total_physics_p95_usec,aero_avg_usec,aero_p95_usec,jib_avg_usec,jib_p95_usec,wind_queries_per_step,wave_queries_per_step\n" + "\n".join(_wave_performance_lines) + "\n")


func _write_c6_csv(filename: String, content: String) -> void:
	var path := ProjectSettings.globalize_path(C6_DATA_DIR.path_join(filename))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_failures.append("Could not write %s: %s" % [path, error_string(FileAccess.get_open_error())])
		return
	file.store_string(content)
	file.close()
