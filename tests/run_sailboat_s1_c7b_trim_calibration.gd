extends "res://tests/run_sailboat_s1_c6_headsail.gd"
## Controlled Auto Sail Trim calibration using the production SailboatLab body
## and the existing test-only PD course controller that drives the real rudder.

const C7B_DATA_DIR := "res://docs/sailing/c7b_data"
var _c7a_main_curve := PackedVector2Array([
	Vector2(0.0, 10.0), Vector2(30.0, 10.0), Vector2(45.0, 20.0),
	Vector2(60.0, 30.0), Vector2(90.0, 50.0), Vector2(120.0, 60.0),
	Vector2(150.0, 70.0), Vector2(180.0, 75.0),
])
var _c7a_jib_curve := PackedVector2Array([
	Vector2(0.0, 10.0), Vector2(30.0, 10.0), Vector2(45.0, 15.0),
	Vector2(60.0, 25.0), Vector2(90.0, 40.0), Vector2(120.0, 50.0),
	Vector2(150.0, 60.0), Vector2(180.0, 65.0),
])
const C7B_SCREEN_SECONDS := 20
const LONG_SECONDS := 120
const CORE_TWAS := [60.0, 90.0, 120.0, 150.0]
const SUPPLEMENT_TWAS := [90.0, 120.0]

var _controlled_rows: Array[String] = []
var _candidate_rows: Array[String] = []
var _yaw_rows: Array[String] = []
var _performance_rows: Array[String] = []
var _calibration_rows: Array[String] = []
var _free_sailing_rows: Array[String] = []
var _rudder_rows: Array[String] = []
var _curve_rows: Array[String] = []
var _candidate_winners: Dictionary = {}
var _c7b_phase := "screen"
var _last_auto_trim_timing: Dictionary = {"average_usec": 0.0, "p95_usec": 0.0}


func _run() -> void:
	_started_usec = Time.get_ticks_usec()
	_original_physics_hz = Engine.physics_ticks_per_second
	_original_time_scale = Engine.time_scale
	Engine.physics_ticks_per_second = int(SIMULATION_HZ * OFFLINE_TIME_SCALE)
	Engine.time_scale = OFFLINE_TIME_SCALE
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--phase="):
			_c7b_phase = argument.trim_prefix("--phase=")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(C7B_DATA_DIR))
	match _c7b_phase:
		"screen":
			await _run_screening()
			_write_c7b_outputs(false)
		"calibrate":
			_load_candidate_winners()
			await _run_long_candidate_validation()
			_write_c7b_outputs(false)
		"refine":
			await _run_downwind_refinement()
			_write_c7b_outputs(false)
		"verify":
			_load_candidate_winners()
			await _run_final_controlled_matrix()
			await _run_free_sailing_regression()
			await _run_auto_rudder_regression()
			await _run_dynamic_wave_query_guard()
			_write_c7b_outputs(true)
		"regression":
			await _run_free_sailing_regression()
			await _run_auto_rudder_regression()
			await _run_dynamic_wave_query_guard()
			_write_c7b_outputs(true)
		"smoke":
			await _run_smoke()
			_write_c7b_outputs(false)
		_:
			_failures.append("Unknown phase '%s'. Use screen, calibrate, refine, verify, regression, or smoke." % _c7b_phase)
	Engine.physics_ticks_per_second = _original_physics_hz
	Engine.time_scale = _original_time_scale
	var elapsed := float(Time.get_ticks_usec() - _started_usec) / 1_000_000.0
	if _failures.is_empty():
		print("[S1-C7b] phase=%s runs=%d wall=%.2fs output=docs/sailing/c7b_data/" % [_c7b_phase, _run_count, elapsed])
		quit(0)
	else:
		for failure in _failures:
			push_error("[S1-C7b] " + failure)
		quit(1)


func _run_screening() -> void:
	for twa in CORE_TWAS:
		var reference := _reference_trim(8.0, float(twa))
		var auto_result := await _run_long_mode("auto_c7a_baseline", 8.0, float(twa), "auto", 0.0, 0.0)
		_append_long_result("auto_c7a_baseline", 8.0, float(twa), auto_result)
		var manual_result := await _run_long_mode("manual_c6_reference", 8.0, float(twa), "manual", float(reference["main"]), float(reference["jib"]))
		_append_long_result("manual_c6_reference", 8.0, float(twa), manual_result)
		await _screen_candidates(8.0, float(twa), reference)
		print("[S1-C7b][screen] TWS=8 TWA=%+.0f° baseline done" % float(twa))


func _screen_candidates(tws: float, twa: float, reference: Dictionary) -> void:
	var side_sign := -signf(twa)
	var main_center := absf(float(reference["main"]))
	var jib_center := absf(float(reference["jib"]))
	var main_values := _unique_bounded_angles([
		main_center - 10.0, main_center, main_center + 10.0,
	], rad_to_deg(float(PROFILE.get("max_sail_angle_rad"))))
	var jib_values := _unique_bounded_angles([
		jib_center - 10.0, jib_center, jib_center + 10.0,
	], rad_to_deg(float(PROFILE.get("max_headsail_angle_rad"))))
	var winner_score := -INF
	var winner := reference.duplicate(true)
	for main_magnitude in main_values:
		for jib_magnitude in jib_values:
			var main_angle := side_sign * float(main_magnitude)
			var jib_angle := side_sign * float(jib_magnitude)
			var result := await _run_long_mode("manual_screen_candidate", tws, twa, "manual", main_angle, jib_angle, C7B_SCREEN_SECONDS)
			var samples: Array = result.get("samples", [])
			var summary := _aggregate(samples, float(C7B_SCREEN_SECONDS - 10), float(C7B_SCREEN_SECONDS), twa)
			var quality := _extra_window_metrics(samples, float(C7B_SCREEN_SECONDS - 10), float(C7B_SCREEN_SECONDS))
			var status := _classify(summary, twa)
			var score := _candidate_score(summary, quality, status)
			_candidate_rows.append(_csv([
				_n(tws), _n(twa), _n(main_angle), _n(jib_angle), _n(score), status,
				_n(float(summary["mean_sog_kn"])), _n(float(summary["mean_vlong_mps"])), _n(float(summary["mean_vlat_mps"])),
				_n(float(summary["mean_twa_deg"])), _n(float(summary["mean_awa_deg"])),
				_n(float(summary["mean_abs_heading_error_deg"])), _n(float(summary["rudder_saturation_fraction"])),
				_n(float(summary["mean_abs_rudder_deg"])), _n(float(quality["mean_abs_heel_deg"])),
				_n(float(quality["mean_abs_sideslip_deg"])),
				_n(float(summary["mean_sail_forward_n"])), _n(float(summary["mean_headsail_forward_n"])),
				_n(float(summary["mean_sail_yaw_torque_nm"])), _n(float(summary["mean_headsail_yaw_torque_nm"])),
				_n(float(summary["mean_keel_yaw_torque_nm"])), _n(float(summary["mean_rudder_yaw_torque_nm"])),
			]))
			_run_count += 1
			if status == "screen_only" and score > winner_score:
				winner_score = score
				winner = {"main": main_angle, "jib": jib_angle, "score": score, "status": "screen_only"}
	_candidate_winners[_scenario_key(tws, absf(twa))] = winner


func _run_long_candidate_validation() -> void:
	for twa in CORE_TWAS:
		var key := _scenario_key(8.0, float(twa))
		var candidate: Dictionary = _candidate_winners.get(key, _reference_trim(8.0, float(twa)))
		var result := await _run_long_mode("manual_screen_winner", 8.0, float(twa), "manual", float(candidate["main"]), float(candidate["jib"]))
		var previous := _aggregate(result["samples"], 60.0, 90.0, float(twa))
		var final := _aggregate(result["samples"], 90.0, 120.0, float(twa))
		var quality := _extra_window_metrics(result["samples"], 90.0, 120.0)
		var status := _classify_with_previous(final, previous, float(twa))
		var nav: Dictionary = _boat.call("get_navigation_snapshot")
		_calibration_rows.append(_csv([
			_n(8.0), _n(float(twa)), _n(float(candidate["main"])), _n(float(candidate["jib"])),
			_n(float(final["mean_awa_deg"])), _n(float(final["mean_awa_signed_deg"])), _n(float(final["mean_twa_deg"])),
			_n(float(final["mean_sog_kn"])), _n(float(final["mean_vlong_mps"])), _n(float(final["mean_abs_heading_error_deg"])),
			_n(float(final["rudder_saturation_fraction"])), _n(float(final["mean_abs_rudder_deg"])),
			_n(float(quality["mean_abs_heel_deg"])), _n(float(quality["max_abs_heel_deg"])),
			_n(float(quality["mean_abs_sideslip_deg"])), status,
			_n(rad_to_deg(float(nav.get("actual_sail_angle_rad", 0.0)))), _n(rad_to_deg(float(nav.get("actual_headsail_angle_rad", 0.0)))),
		]))
		_append_long_result("manual_screen_winner", 8.0, float(twa), result)
		print("[S1-C7b][calibrate] TWA=%+.0f° winner=%+.1f/%+.1f · %.3fkn %s" % [
			float(twa), float(candidate["main"]), float(candidate["jib"]), float(final["mean_sog_kn"]), status,
		])


func _run_downwind_refinement() -> void:
	# The 150° screen winner was at the upper edge of its local main-sheet
	# range. Check that edge and one headsail trim alternative in long runs.
	for pair in [[-70.0, -70.0], [-79.9849, -70.0], [-79.9849, -60.0]]:
		var main_angle := float(pair[0])
		var jib_angle := float(pair[1])
		var result := await _run_long_mode("manual_downwind_refinement", 8.0, 150.0, "manual", main_angle, jib_angle)
		if result.is_empty():
			_failures.append("Could not run downwind trim refinement at main %.1f / Jib %.1f." % [main_angle, jib_angle])
			continue
		var samples: Array = result.get("samples", [])
		var previous := _aggregate(samples, 60.0, 90.0, 150.0)
		var final := _aggregate(samples, 90.0, 120.0, 150.0)
		var quality := _extra_window_metrics(samples, 90.0, 120.0)
		var status := _classify_with_previous(final, previous, 150.0)
		var nav: Dictionary = _boat.call("get_navigation_snapshot")
		_calibration_rows.append(_csv([
			_n(8.0), _n(150.0), _n(main_angle), _n(jib_angle),
			_n(float(final["mean_awa_deg"])), _n(float(final["mean_awa_signed_deg"])), _n(float(final["mean_twa_deg"])),
			_n(float(final["mean_sog_kn"])), _n(float(final["mean_vlong_mps"])), _n(float(final["mean_abs_heading_error_deg"])),
			_n(float(final["rudder_saturation_fraction"])), _n(float(final["mean_abs_rudder_deg"])),
			_n(float(quality["mean_abs_heel_deg"])), _n(float(quality["max_abs_heel_deg"])),
			_n(float(quality["mean_abs_sideslip_deg"])), status,
			_n(rad_to_deg(float(nav.get("actual_sail_angle_rad", 0.0)))), _n(rad_to_deg(float(nav.get("actual_headsail_angle_rad", 0.0)))),
		]))
		_append_long_result("manual_downwind_refinement", 8.0, 150.0, result)
		print("[S1-C7b][refine] main=%+.1f Jib=%+.1f · %.3fkn %s" % [main_angle, jib_angle, float(final["mean_sog_kn"]), status])


func _run_final_controlled_matrix() -> void:
	# Core wind speed: both sides at all four target angles. Candidate-selected
	# manual comparisons are run on the calibrated side and mirrored for sign.
	for twa in CORE_TWAS:
		for side_sign in [1.0, -1.0]:
			var signed_twa := float(twa) * float(side_sign)
			var reference := _reference_trim(8.0, signed_twa)
			var auto_result := await _run_long_mode("auto_calibrated", 8.0, signed_twa, "auto", 0.0, 0.0)
			_append_long_result("auto_calibrated", 8.0, signed_twa, auto_result)
			var reference_result := await _run_long_mode("manual_c6_reference", 8.0, signed_twa, "manual", float(reference["main"]), float(reference["jib"]))
			_append_long_result("manual_c6_reference", 8.0, signed_twa, reference_result)
			if side_sign > 0.0:
				var candidate: Dictionary = _candidate_winners.get(_scenario_key(8.0, float(twa)), reference)
				var candidate_result := await _run_long_mode("manual_screen_winner", 8.0, signed_twa, "manual", float(candidate["main"]), float(candidate["jib"]))
				_append_long_result("manual_screen_winner", 8.0, signed_twa, candidate_result)
			print("[S1-C7b][verify 8m/s] TWA=%+.0f° done" % signed_twa)
	# Lower and higher wind validation uses both AUTO and the published C6
	# reference trims on the port-side set. The 8 m/s matrix carries the full
	# left/right mirror burden.
	for tws in [5.0, 12.0]:
		for twa in SUPPLEMENT_TWAS:
			var reference := _reference_trim(float(tws), float(twa))
			var auto_result := await _run_long_mode("auto_calibrated", float(tws), float(twa), "auto", 0.0, 0.0)
			_append_long_result("auto_calibrated", float(tws), float(twa), auto_result)
			var manual_result := await _run_long_mode("manual_c6_reference", float(tws), float(twa), "manual", float(reference["main"]), float(reference["jib"]))
			_append_long_result("manual_c6_reference", float(tws), float(twa), manual_result)
			print("[S1-C7b][verify TWS=%.0f] TWA=%.0f° done" % [float(tws), float(twa)])


func _run_smoke() -> void:
	var twa := 90.0
	var auto_result := await _run_long_mode("auto_c7b_smoke", 8.0, twa, "auto", 0.0, 0.0)
	_append_long_result("auto_c7b_smoke", 8.0, twa, auto_result)
	var reference := _reference_trim(8.0, twa)
	var manual_result := await _run_long_mode("manual_c6_smoke", 8.0, twa, "manual", float(reference["main"]), float(reference["jib"]))
	_append_long_result("manual_c6_smoke", 8.0, twa, manual_result)


func _run_long_mode(label: String, tws: float, twa: float, mode: String, main_deg: float, jib_deg: float, duration: int = LONG_SECONDS) -> Dictionary:
	var main_for_setup := main_deg if mode == "manual" else 0.0
	var jib_for_setup := jib_deg if mode == "manual" else 0.0
	if not await _prepare_c6_case(tws, twa, main_for_setup, jib_for_setup, "dual"):
		return {}
	_wind.call("set_test_simulation_time", 0.0)
	if mode == "auto":
		_boat.call("set_auto_sail_trim_enabled", true)
	return await _run_controlled_case(duration, twa)


func _run_controlled_case(duration_seconds: int, target_twa_degrees: float) -> Dictionary:
	var target_heading := POLAR_MATH.target_heading_degrees(WIND_FROM_BEARING_DEGREES, target_twa_degrees)
	var initial_position: Vector3 = _boat.global_position
	var initial_forward := -_boat.global_basis.z
	var previous_heading := float(_boat.call("get_s1_c4_diagnostic_snapshot").get("heading_degrees", 0.0))
	var unwrapped_heading := previous_heading
	var max_abs_yaw_rate := 0.0
	var samples: Array[Dictionary] = []
	var auto_trim_times: Array[int] = []
	_apply_heading_controller(target_heading)
	for tick in range(duration_seconds * SIMULATION_HZ):
		await physics_frame
		_apply_heading_controller(target_heading)
		var diagnostic: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
		var heading := float(diagnostic.get("heading_degrees", 0.0))
		unwrapped_heading += wrapf(heading - previous_heading, -180.0, 180.0)
		previous_heading = heading
		max_abs_yaw_rate = maxf(max_abs_yaw_rate, absf(rad_to_deg(float(diagnostic.get("yaw_rate_rad_s", 0.0)))))
		auto_trim_times.append(int(_boat.get("_last_auto_trim_calculation_usec")))
		if (tick + 1) % SIMULATION_HZ == 0:
			samples.append(_sample_polar_state(
				float(tick + 1) / float(SIMULATION_HZ), target_heading, target_twa_degrees,
				unwrapped_heading, initial_position, initial_forward, max_abs_yaw_rate
			))
	_last_auto_trim_timing = _summarize_integer_times(auto_trim_times)
	return {"samples": samples, "max_abs_yaw_rate_deg_s": max_abs_yaw_rate}


func _summarize_integer_times(values: Array[int]) -> Dictionary:
	if values.is_empty():
		return {"average_usec": 0.0, "p95_usec": 0.0}
	var sorted_values := values.duplicate()
	sorted_values.sort()
	var total := 0.0
	for value in sorted_values:
		total += float(value)
	var p95_index := clampi(int(ceil(float(sorted_values.size()) * 0.95)) - 1, 0, sorted_values.size() - 1)
	return {"average_usec": total / float(sorted_values.size()), "p95_usec": float(sorted_values[p95_index])}


func _append_long_result(label: String, tws: float, twa: float, run_result: Dictionary) -> void:
	if run_result.is_empty():
		_failures.append("Could not run %s at TWS %.1f / TWA %.1f." % [label, tws, twa])
		return
	var samples: Array = run_result.get("samples", [])
	var end_s := float(samples.back().get("time_s", 0.0)) if not samples.is_empty() else 0.0
	var final_start_s := maxf(end_s - 30.0, 0.0) if end_s >= 120.0 else maxf(end_s - 10.0, 0.0)
	var previous_start_s := maxf(final_start_s - 30.0, 0.0)
	var previous_end_s := final_start_s if end_s >= 120.0 else maxf(final_start_s - 0.001, 0.0)
	var previous := _aggregate(samples, previous_start_s, previous_end_s, twa)
	var final := _aggregate(samples, final_start_s, end_s, twa)
	var quality := _extra_window_metrics(samples, final_start_s, end_s)
	var status := _classify_with_previous(final, previous, twa) if end_s >= 120.0 else _classify(final, twa)
	var nav: Dictionary = _boat.call("get_navigation_snapshot")
	var debug: Dictionary = _boat.call("get_debug_snapshot")
	if int(debug.get("wind_query_count_per_tick", -1)) != 1 or int(debug.get("wave_query_count_per_tick", -1)) != 0:
		_failures.append("Static-water %s case queried wind=%d/waves=%d per step; expected 1/0." % [
			label, int(debug.get("wind_query_count_per_tick", -1)), int(debug.get("wave_query_count_per_tick", -1)),
		])
	var main_angle := rad_to_deg(float(nav.get("actual_sail_angle_rad", 0.0)))
	var jib_angle := rad_to_deg(float(nav.get("actual_headsail_angle_rad", 0.0)))
	var main_target := rad_to_deg(float(nav.get("target_sail_angle_rad", 0.0)))
	var jib_target := rad_to_deg(float(nav.get("target_headsail_angle_rad", 0.0)))
	var row := _csv([
		label, _n(tws), _n(twa), _n(float(final["mean_twa_deg"])), _n(float(final["mean_awa_signed_deg"])),
		_n(float(final["mean_awa_deg"])), _n(float(final["mean_aws_mps"])), _n(float(final["mean_sog_kn"])),
		_n(float(final["mean_vlong_mps"])), _n(float(final["mean_vlat_mps"])), _n(float(final["mean_upwind_vmg_mps"])),
		_n(main_angle), _n(main_target), _n(jib_angle), _n(jib_target), _n(float(final["mean_sail_forward_n"])),
		_n(float(final["mean_headsail_forward_n"])), _n(float(final["mean_sail_yaw_torque_nm"])),
		_n(float(final["mean_headsail_yaw_torque_nm"])), _n(float(final["mean_keel_yaw_torque_nm"])),
		_n(float(final["mean_rudder_yaw_torque_nm"])), _n(float(final["mean_abs_heading_error_deg"])),
		_n(float(final["mean_rudder_deg"])), _n(float(final["mean_abs_rudder_deg"])),
		_n(float(final["rudder_saturation_fraction"])), _n(float(quality["mean_abs_heel_deg"])),
		_n(float(quality["max_abs_heel_deg"])), _n(float(quality["mean_abs_sideslip_deg"])), status,
	])
	_controlled_rows.append(row)
	_yaw_rows.append(_csv([
		label, _n(tws), _n(twa), _n(main_angle), _n(jib_angle),
		_n(float(final["mean_sail_yaw_torque_nm"])), _n(float(final["mean_headsail_yaw_torque_nm"])),
		_n(float(final["mean_keel_yaw_torque_nm"])), _n(float(final["mean_rudder_yaw_torque_nm"])),
		_n(float(final["mean_abs_rudder_deg"])), _n(float(final["rudder_saturation_fraction"])),
		_n(float(quality["mean_abs_heel_deg"])), _n(float(quality["mean_abs_sideslip_deg"])), status,
	]))
	_performance_rows.append(_csv([
		label, _n(tws), _n(twa), _n(float(_last_auto_trim_timing.get("average_usec", 0))),
		_n(float(_last_auto_trim_timing.get("p95_usec", 0))),
		_n(float(debug.get("total_physics_calculation_average_usec", 0))),
		_n(float(debug.get("total_physics_calculation_p95_usec", 0))),
		_n(float(debug.get("wind_query_count_per_tick", 0))), _n(float(debug.get("wave_query_count_per_tick", 0))),
	]))
	_run_count += 1


func _extra_window_metrics(samples: Array, start_s: float, end_s: float) -> Dictionary:
	var count := 0
	var heel_total := 0.0
	var heel_max := 0.0
	var sideslip_total := 0.0
	for value in samples:
		var sample: Dictionary = value
		var time_s := float(sample.get("time_s", -1.0))
		if time_s < start_s or time_s > end_s:
			continue
		var heel := absf(float(sample.get("heel_deg", 0.0)))
		var sideslip := absf(float(sample.get("sideslip_deg", 0.0)))
		heel_total += heel
		heel_max = maxf(heel_max, heel)
		sideslip_total += sideslip
		count += 1
	return {
		"mean_abs_heel_deg": heel_total / float(maxi(count, 1)),
		"max_abs_heel_deg": heel_max,
		"mean_abs_sideslip_deg": sideslip_total / float(maxi(count, 1)),
	}


func _candidate_score(summary: Dictionary, quality: Dictionary, status: String) -> float:
	if status != "screen_only" or float(summary["mean_vlong_mps"]) <= 0.15:
		return -1000000.0
	var score := float(summary["mean_vlong_mps"])
	score -= float(summary["mean_abs_rudder_deg"]) * 0.003
	score -= float(summary["rudder_saturation_fraction"]) * 0.5
	score -= float(quality["mean_abs_heel_deg"]) * 0.0008
	score -= float(quality["mean_abs_sideslip_deg"]) * 0.002
	return score


func _unique_bounded_angles(values: Array, maximum: float) -> Array[float]:
	var result: Array[float] = []
	for value in values:
		var bounded := clampf(float(value), 0.0, maximum)
		var found := false
		for existing in result:
			if is_equal_approx(existing, bounded):
				found = true
				break
		if not found:
			result.append(bounded)
	return result


func _reference_trim(tws: float, signed_twa: float) -> Dictionary:
	var sign := signf(signed_twa)
	var main_magnitude := absf(float(_published_main_trim(tws, absf(signed_twa))))
	var jib_magnitude := clampf(absf(signed_twa) * 0.5, 20.0, 65.0)
	return {"main": -sign * main_magnitude, "jib": -sign * jib_magnitude}


func _load_candidate_winners() -> void:
	var path := ProjectSettings.globalize_path(C7B_DATA_DIR.path_join("trim_candidate_screening.csv"))
	if not FileAccess.file_exists(path):
		for twa in CORE_TWAS:
			_candidate_winners[_scenario_key(8.0, float(twa))] = _reference_trim(8.0, float(twa))
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_failures.append("Could not read trim candidate screen: %s" % path)
		return
	var header := file.get_csv_line()
	var tws_column := header.find("tws_mps")
	var twa_column := header.find("target_twa_deg")
	var main_column := header.find("main_angle_deg")
	var jib_column := header.find("jib_angle_deg")
	var score_column := header.find("screen_score")
	var status_column := header.find("screen_status")
	while not file.eof_reached():
		var row := file.get_csv_line()
		if row.size() <= maxi(maxi(maxi(tws_column, twa_column), maxi(main_column, jib_column)), status_column):
			continue
		if absf(float(row[tws_column]) - 8.0) > 0.01:
			continue
		if str(row[status_column]) != "screen_only":
			continue
		var key := _scenario_key(8.0, absf(float(row[twa_column])))
		var score := float(row[score_column])
		if not _candidate_winners.has(key) or score > float(_candidate_winners[key].get("score", -INF)):
			_candidate_winners[key] = {
				"main": float(row[main_column]), "jib": float(row[jib_column]),
				"score": score, "status": "screen_only",
			}
	file.close()
	for twa in CORE_TWAS:
		var key := _scenario_key(8.0, float(twa))
		if not _candidate_winners.has(key):
			_candidate_winners[key] = _reference_trim(8.0, float(twa))
	# The 120 s follow-up tested beyond the short-screen boundary and found this
	# max-range mainsail trim better for 150° than the initial ±10° screen.
	_candidate_winners[_scenario_key(8.0, 150.0)] = {
		"main": -79.9849, "jib": -70.0, "status": "steady_refined",
	}


func _run_free_sailing_regression() -> void:
	var c7a_baseline := _read_c7a_summary("auto_08ms")
	_free_sailing_rows.append(_csv(["C7a_baseline", "8.000000", "270.000000", "120", c7a_baseline.get("heading_deg", ""), c7a_baseline.get("sog_knots", ""), c7a_baseline.get("longitudinal_mps", ""), c7a_baseline.get("lateral_mps", ""), c7a_baseline.get("twa_deg", ""), c7a_baseline.get("awa_deg", ""), c7a_baseline.get("main_actual_deg", ""), c7a_baseline.get("jib_actual_deg", ""), "historical; free heading; not a held-TWA polar point"]))
	if not await _configure_lab(8.0, 270.0, 0.0, 0.0, {}):
		return
	_boat.call("set_headsail_enabled", true)
	_boat.call("set_auto_sail_trim_enabled", true)
	_wind.call("set_test_simulation_time", 0.0)
	var history: Array[Dictionary] = []
	for tick in range(1, 120 * SIMULATION_HZ + 1):
		await physics_frame
		if tick % SIMULATION_HZ == 0:
			history.append(_free_state_row(float(tick) / float(SIMULATION_HZ)))
	var summary_60_90 := _mean_free_window(history, 60.0, 90.0)
	var summary_90_120 := _mean_free_window(history, 90.0, 120.0)
	_free_sailing_rows.append(_csv([
		"C7b_calibrated_auto", "8.000000", "270.000000", "120",
		_n(float(summary_90_120["heading_deg"])), _n(float(summary_90_120["sog_knots"])),
		_n(float(summary_90_120["longitudinal_mps"])), _n(float(summary_90_120["lateral_mps"])),
		_n(float(summary_90_120["twa_deg"])), _n(float(summary_90_120["awa_deg"])),
		_n(float(summary_90_120["main_deg"])), _n(float(summary_90_120["jib_deg"])),
		"free heading; 90-120 s average; speed delta vs 60-90 = %.4f kn" % (float(summary_90_120["sog_knots"]) - float(summary_60_90["sog_knots"])),
	]))
	for item in history:
		_free_sailing_rows.append(_csv([
			"C7b_history", "8.000000", "270.000000", _n(float(item["time_s"])),
			_n(float(item["heading_deg"])), _n(float(item["sog_knots"])),
			_n(float(item["longitudinal_mps"])), _n(float(item["lateral_mps"])),
			_n(float(item["twa_deg"])), _n(float(item["awa_deg"])),
			_n(float(item["main_deg"])), _n(float(item["jib_deg"])),
			"heel_deg=%.3f" % float(item["heel_deg"]),
		]))


func _run_auto_rudder_regression() -> void:
	var historical := _read_c7a_history("auto_left_rudder_history.csv")
	for row in historical:
		if [0, 20, 21, 30, 40, 60, 80].has(int(row.get("time_s", -1))):
			_rudder_rows.append(_csv(["C7a_baseline", row.get("time_s", ""), row.get("heading_deg", ""), row.get("sog_knots", ""), row.get("awa_deg", ""), row.get("main_actual_deg", ""), row.get("jib_actual_deg", ""), row.get("rudder_actual_deg", ""), row.get("main_yaw_torque_nm", ""), row.get("jib_yaw_torque_nm", ""), row.get("keel_yaw_torque_nm", ""), row.get("rudder_yaw_torque_nm", ""), ""]))
	if not await _configure_lab(8.0, 270.0, 0.0, 0.0, {}):
		return
	_boat.call("set_headsail_enabled", true)
	_boat.call("set_auto_sail_trim_enabled", true)
	_wind.call("set_test_simulation_time", 0.0)
	for tick in range(1, 80 * SIMULATION_HZ + 1):
		await physics_frame
		var time_s := float(tick) / float(SIMULATION_HZ)
		if time_s >= 20.0 and is_zero_approx(float(_boat.call("get_navigation_snapshot").get("target_rudder_angle_rad", 0.0))):
			var max_rudder := float(_boat.call("get_navigation_snapshot").get("max_rudder_angle_rad", 0.611))
			_boat.call("set_target_rudder_angle", -max_rudder)
		var nav: Dictionary = _boat.call("get_navigation_snapshot")
		if tick % SIMULATION_HZ == 0:
			var debug: Dictionary = _boat.call("get_debug_snapshot")
			var diagnostic: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
			var heading := float(nav.get("heading_degrees", 0.0))
			_rudder_rows.append(_csv([
				"C7b_calibrated_auto", _n(time_s), _n(heading), _n(float(nav.get("sog_knots", 0.0))),
				_n(float(nav.get("apparent_wind_from_relative_degrees", 0.0))),
				_n(rad_to_deg(float(nav.get("actual_sail_angle_rad", 0.0)))),
				_n(rad_to_deg(float(nav.get("actual_headsail_angle_rad", 0.0)))),
				_n(rad_to_deg(float(nav.get("actual_rudder_angle_rad", 0.0)))),
				_n(float(diagnostic.get("sail_yaw_torque_local_nm", 0.0))),
				_n(float(debug.get("headsail_yaw_torque_nm", 0.0))),
				_n(float(diagnostic.get("keel_yaw_torque_local_nm", 0.0))),
				_n(float(diagnostic.get("rudder_yaw_torque_local_nm", 0.0))), "",
			]))
	_rudder_rows.append(_csv(["C7b_note", "", "", "", "", "", "", "", "", "", "", "", "manual rudder target -max held after 20s; no auto-helm"]))


func _run_dynamic_wave_query_guard() -> void:
	if not await _configure_lab(8.0, 270.0, 0.0, 0.0, {}):
		return
	_boat.call("set_headsail_enabled", true)
	_boat.call("set_dynamic_waves_enabled", true)
	_boat.call("set_auto_sail_trim_enabled", true)
	_boat.call("reset_performance_history")
	await _run_controlled_case(20, 90.0)
	var debug: Dictionary = _boat.call("get_debug_snapshot")
	var wind_queries := int(debug.get("wind_query_count_per_tick", -1))
	var wave_queries := int(debug.get("wave_query_count_per_tick", -1))
	if wind_queries != 1 or wave_queries != 4:
		_failures.append("Calibrated AUTO dynamic-wave step queried wind=%d/waves=%d; expected 1/4." % [wind_queries, wave_queries])
	_performance_rows.append(_csv([
		"dynamic_wave_guard", _n(8.0), _n(90.0), _n(float(_last_auto_trim_timing.get("average_usec", 0))),
		_n(float(_last_auto_trim_timing.get("p95_usec", 0))),
		_n(float(debug.get("total_physics_calculation_average_usec", 0))),
		_n(float(debug.get("total_physics_calculation_p95_usec", 0))),
		_n(float(wind_queries)), _n(float(wave_queries)),
	]))


func _free_state_row(time_s: float) -> Dictionary:
	var nav: Dictionary = _boat.call("get_navigation_snapshot")
	var diagnostic: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
	return {
		"time_s": time_s,
		"heading_deg": float(nav.get("heading_degrees", 0.0)),
		"sog_knots": float(nav.get("sog_knots", 0.0)),
		"longitudinal_mps": float(diagnostic.get("longitudinal_velocity_mps", 0.0)),
		"lateral_mps": float(diagnostic.get("lateral_velocity_mps", 0.0)),
		"twa_deg": float(nav.get("true_wind_from_relative_degrees", 0.0)),
		"awa_deg": float(nav.get("apparent_wind_from_relative_degrees", 0.0)),
		"main_deg": rad_to_deg(float(nav.get("actual_sail_angle_rad", 0.0))),
		"jib_deg": rad_to_deg(float(nav.get("actual_headsail_angle_rad", 0.0))),
		"heel_deg": float(diagnostic.get("roll_degrees", 0.0)),
	}


func _mean_free_window(rows: Array[Dictionary], start_s: float, end_s: float) -> Dictionary:
	var result := {"heading_deg": 0.0, "sog_knots": 0.0, "longitudinal_mps": 0.0, "lateral_mps": 0.0, "twa_deg": 0.0, "awa_deg": 0.0, "main_deg": 0.0, "jib_deg": 0.0}
	var count := 0
	for row in rows:
		var time_s := float(row["time_s"])
		if time_s < start_s or time_s > end_s:
			continue
		for key in result:
			result[key] = float(result[key]) + float(row[key])
		count += 1
	for key in result:
		result[key] = float(result[key]) / float(maxi(count, 1))
	return result


func _read_c7a_summary(case_name: String) -> Dictionary:
	var path := ProjectSettings.globalize_path("res://docs/sailing/c7a_data/wind_cases_and_fixed_trim_comparison.csv")
	var empty := {"heading_deg": "", "sog_knots": "", "longitudinal_mps": "", "lateral_mps": "", "twa_deg": "", "awa_deg": "", "main_actual_deg": "", "jib_actual_deg": ""}
	if not FileAccess.file_exists(path):
		return empty
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return empty
	var header := file.get_csv_line()
	while not file.eof_reached():
		var row := file.get_csv_line()
		if row.size() != header.size() or str(row[0]) != case_name:
			continue
		var values := empty.duplicate()
		var source_columns := {
			"heading_deg": "final_heading_deg", "sog_knots": "final_sog_knots",
			"longitudinal_mps": "final_longitudinal_mps", "lateral_mps": "final_lateral_mps",
			"twa_deg": "final_twa_deg", "awa_deg": "final_awa_deg",
			"main_actual_deg": "main_actual_deg", "jib_actual_deg": "jib_actual_deg",
		}
		for key in values:
			var index := header.find(str(source_columns[key]))
			if index >= 0:
				values[key] = row[index]
		file.close()
		return values
	file.close()
	return empty


func _read_c7a_history(filename: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var path := ProjectSettings.globalize_path(C7B_DATA_DIR.get_base_dir().path_join("c7a_data").path_join(filename))
	if not FileAccess.file_exists(path):
		return result
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return result
	var header := file.get_csv_line()
	while not file.eof_reached():
		var row := file.get_csv_line()
		if row.size() != header.size():
			continue
		var values: Dictionary = {}
		for index in range(header.size()):
			values[str(header[index])] = row[index]
		result.append(values)
	file.close()
	return result


func _write_c7b_outputs(include_verify: bool) -> void:
	if _c7b_phase == "screen":
		_write_csv("controlled_auto_vs_manual.csv", "phase,tws_mps,target_twa_deg,mean_actual_twa_deg,mean_signed_awa_deg,mean_abs_awa_deg,mean_aws_mps,mean_sog_kn,mean_vlong_mps,mean_vlat_mps,mean_upwind_vmg_mps,main_actual_deg,main_target_deg,jib_actual_deg,jib_target_deg,main_forward_n,jib_forward_n,main_yaw_nm,jib_yaw_nm,keel_yaw_nm,rudder_yaw_nm,mean_abs_heading_error_deg,mean_rudder_deg,mean_abs_rudder_deg,rudder_saturation_fraction,mean_abs_heel_deg,max_abs_heel_deg,mean_abs_sideslip_deg,status\n" + "\n".join(_controlled_rows) + "\n")
		_write_csv("trim_candidate_screening.csv", "tws_mps,target_twa_deg,main_angle_deg,jib_angle_deg,screen_score,screen_status,mean_sog_kn,mean_vlong_mps,mean_vlat_mps,mean_actual_twa_deg,mean_abs_awa_deg,mean_abs_heading_error_deg,rudder_saturation_fraction,mean_abs_rudder_deg,mean_abs_heel_deg,mean_abs_sideslip_deg,mean_main_forward_n,mean_jib_forward_n,mean_main_yaw_nm,mean_jib_yaw_nm,mean_keel_yaw_nm,mean_rudder_yaw_nm\n" + "\n".join(_candidate_rows) + "\n")
		_write_csv("yaw_balance_comparison.csv", "phase,tws_mps,target_twa_deg,main_angle_deg,jib_angle_deg,main_yaw_nm,jib_yaw_nm,keel_yaw_nm,rudder_yaw_nm,mean_abs_rudder_deg,rudder_saturation_fraction,mean_abs_heel_deg,mean_abs_sideslip_deg,status\n" + "\n".join(_yaw_rows) + "\n")
		_write_csv("auto_trim_performance_comparison.csv", "phase,tws_mps,target_twa_deg,auto_calc_avg_usec,auto_calc_p95_usec,body_calc_avg_usec,body_calc_p95_usec,wind_queries_per_tick,wave_queries_per_tick\n" + "\n".join(_performance_rows) + "\n")
	if _c7b_phase == "calibrate":
		_write_csv("candidate_long_validation.csv", "tws_mps,target_twa_deg,main_angle_deg,jib_angle_deg,mean_abs_awa_deg,mean_signed_awa_deg,mean_actual_twa_deg,mean_sog_kn,mean_vlong_mps,mean_abs_heading_error_deg,rudder_saturation_fraction,mean_abs_rudder_deg,mean_abs_heel_deg,max_abs_heel_deg,mean_abs_sideslip_deg,status,final_main_angle_deg,final_jib_angle_deg\n" + "\n".join(_calibration_rows) + "\n")
	if _c7b_phase == "refine":
		_append_csv_rows("candidate_long_validation.csv", _calibration_header(), _calibration_rows)
	if _c7b_phase in ["calibrate", "refine"]:
		_append_csv_rows("controlled_auto_vs_manual.csv", _controlled_header(), _controlled_rows)
		_append_csv_rows("yaw_balance_comparison.csv", _yaw_header(), _yaw_rows)
		_append_csv_rows("auto_trim_performance_comparison.csv", _performance_header(), _performance_rows)
	if include_verify:
		_append_csv_rows("controlled_auto_vs_manual.csv", _controlled_header(), _controlled_rows)
		_append_csv_rows("yaw_balance_comparison.csv", _yaw_header(), _yaw_rows)
		_append_csv_rows("auto_trim_performance_comparison.csv", _performance_header(), _performance_rows)
		_write_csv("free_sailing_before_after.csv", "phase,tws_mps,wind_from_deg,duration_s,heading_deg,sog_knots,longitudinal_mps,lateral_mps,twa_deg,awa_deg,main_deg,jib_deg,notes\n" + "\n".join(_free_sailing_rows) + "\n")
		_write_csv("auto_rudder_regression.csv", "phase,time_s,heading_deg,sog_knots,awa_deg,main_deg,jib_deg,rudder_deg,main_yaw_nm,jib_yaw_nm,keel_yaw_nm,rudder_yaw_nm,notes\n" + "\n".join(_rudder_rows) + "\n")
		_write_curve_output()
	if not _calibration_rows.is_empty() and _c7b_phase not in ["calibrate", "refine"]:
		_append_csv_rows("candidate_long_validation.csv", _calibration_header(), _calibration_rows)
	_write_c7a_original_curve()


func _write_curve_output() -> void:
	var main_points: PackedVector2Array = PROFILE.get("auto_main_trim_curve_points_degrees")
	var jib_points: PackedVector2Array = PROFILE.get("auto_headsail_trim_curve_points_degrees")
	for index in range(main_points.size()):
		_curve_rows.append(_csv(["main", str(index), _n(main_points[index].x), _n(main_points[index].y), "profile_resource"]))
	for index in range(jib_points.size()):
		_curve_rows.append(_csv(["jib", str(index), _n(jib_points[index].x), _n(jib_points[index].y), "profile_resource"]))
	_write_csv("calibrated_auto_trim_curve.csv", "sail,point_index,awa_abs_degrees,sheet_magnitude_degrees,source\n" + "\n".join(_curve_rows) + "\n")


func _write_c7a_original_curve() -> void:
	var rows: Array[String] = []
	for index in range(_c7a_main_curve.size()):
		rows.append(_csv(["main", str(index), _n(_c7a_main_curve[index].x), _n(_c7a_main_curve[index].y), "C7a_historical_baseline"]))
	for index in range(_c7a_jib_curve.size()):
		rows.append(_csv(["jib", str(index), _n(_c7a_jib_curve[index].x), _n(_c7a_jib_curve[index].y), "C7a_historical_baseline"]))
	_write_csv("c7a_original_trim_curve.csv", "sail,point_index,awa_abs_degrees,sheet_magnitude_degrees,source\n" + "\n".join(rows) + "\n")


func _write_csv(filename: String, content: String) -> void:
	var path := ProjectSettings.globalize_path(C7B_DATA_DIR.path_join(filename))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_failures.append("Could not write %s: %s" % [path, error_string(FileAccess.get_open_error())])
		return
	file.store_string(content)
	file.close()


func _append_csv_rows(filename: String, header: String, rows: Array[String]) -> void:
	if rows.is_empty():
		return
	var path := ProjectSettings.globalize_path(C7B_DATA_DIR.path_join(filename))
	var file: FileAccess
	if FileAccess.file_exists(path):
		file = FileAccess.open(path, FileAccess.READ_WRITE)
		if file != null:
			var original_length := file.get_length()
			if original_length > 0:
				file.seek(original_length - 1)
				if file.get_8() != 10:
					file.seek_end()
					file.store_string("\n")
			file.seek_end()
			file.store_string("\n".join(rows) + "\n")
	else:
		file = FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(header + "\n" + "\n".join(rows) + "\n")
	if file == null:
		_failures.append("Could not append %s: %s" % [path, error_string(FileAccess.get_open_error())])
		return
	file.close()


func _controlled_header() -> String:
	return "phase,tws_mps,target_twa_deg,mean_actual_twa_deg,mean_signed_awa_deg,mean_abs_awa_deg,mean_aws_mps,mean_sog_kn,mean_vlong_mps,mean_vlat_mps,mean_upwind_vmg_mps,main_actual_deg,main_target_deg,jib_actual_deg,jib_target_deg,main_forward_n,jib_forward_n,main_yaw_nm,jib_yaw_nm,keel_yaw_nm,rudder_yaw_nm,mean_abs_heading_error_deg,mean_rudder_deg,mean_abs_rudder_deg,rudder_saturation_fraction,mean_abs_heel_deg,max_abs_heel_deg,mean_abs_sideslip_deg,status\n"


func _yaw_header() -> String:
	return "phase,tws_mps,target_twa_deg,main_angle_deg,jib_angle_deg,main_yaw_nm,jib_yaw_nm,keel_yaw_nm,rudder_yaw_nm,mean_abs_rudder_deg,rudder_saturation_fraction,mean_abs_heel_deg,mean_abs_sideslip_deg,status\n"


func _performance_header() -> String:
	return "phase,tws_mps,target_twa_deg,auto_calc_avg_usec,auto_calc_p95_usec,body_calc_avg_usec,body_calc_p95_usec,wind_queries_per_tick,wave_queries_per_tick\n"


func _calibration_header() -> String:
	return "tws_mps,target_twa_deg,main_angle_deg,jib_angle_deg,mean_abs_awa_deg,mean_signed_awa_deg,mean_actual_twa_deg,mean_sog_kn,mean_vlong_mps,mean_abs_heading_error_deg,rudder_saturation_fraction,mean_abs_rudder_deg,mean_abs_heel_deg,max_abs_heel_deg,mean_abs_sideslip_deg,status,final_main_angle_deg,final_jib_angle_deg\n"
