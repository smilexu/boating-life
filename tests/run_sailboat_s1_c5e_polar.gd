extends "res://tests/run_sailboat_s1_c5c_drag_diagnostics.gd"
## Offline single-mainsail polar test. It runs the production SailboatLab body;
## course holding is a test-only PD controller that actuates the real rudder.

const POLAR_MATH := preload("res://tests/sailboat_polar_math.gd")
const C5E_DATA_DIR := "res://docs/sailing/c5e_data"
const TWS_VALUES_MPS := [3.0, 5.0, 8.0, 10.0, 12.0]
const TWA_VALUES_DEGREES := [30.0, 45.0, 60.0, 75.0, 90.0, 105.0, 120.0, 135.0, 150.0, 165.0, 180.0]
const TRIM_MAGNITUDES_DEGREES := [10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0]
const SCREEN_SECONDS := 8
const POLAR_SECONDS := 120
const MIRROR_SECONDS := 60
const WRONG_SIDE_SECONDS := 20
const WIND_FROM_BEARING_DEGREES := 180.0
const RUDDER_P_GAIN := 5.0
const RUDDER_D_GAIN := 3.0
const MAX_STEADY_HEADING_DRIFT_DEGREES := 10.0

var _screen_rows: Array[String] = []
var _polar_rows: Array[String] = []
var _best_trim_rows: Array[String] = []
var _unstable_rows: Array[String] = []
var _control_rows: Array[String] = []
var _mirror_rows: Array[String] = []
var _wrong_side_rows: Array[String] = []
var _headsail_rows: Array[String] = []
var _trim_winners: Dictionary = {}
var _trim_rankings: Dictionary = {}
var _phase := "all"
var _polar_case_index := 0
var _polar_case_total := 0


func _run() -> void:
	_started_usec = Time.get_ticks_usec()
	_original_physics_hz = Engine.physics_ticks_per_second
	_original_time_scale = Engine.time_scale
	Engine.physics_ticks_per_second = int(SIMULATION_HZ * OFFLINE_TIME_SCALE)
	Engine.time_scale = OFFLINE_TIME_SCALE
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--phase="):
			_phase = argument.trim_prefix("--phase=")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(C5E_DATA_DIR))
	if _phase == "smoke":
		await _run_smoke_case()
	elif _phase == "design":
		_write_headsail_candidate()
	elif _phase == "all":
		await _run_trim_screening()
		await _run_selected_polar()
		await _run_mirror_checks()
		await _run_wrong_side_controls()
		_write_headsail_candidate()
	else:
		_failures.append("Unknown phase '%s'. Use all, smoke, or design." % _phase)
	_write_c5e_outputs()
	var elapsed := float(Time.get_ticks_usec() - _started_usec) / 1_000_000.0
	Engine.physics_ticks_per_second = _original_physics_hz
	Engine.time_scale = _original_time_scale
	if _failures.is_empty():
		print("[S1-C5e] phase=%s runs=%d wall=%.2fs output=docs/sailing/c5e_data/" % [_phase, _run_count, elapsed])
		quit(0)
	else:
		for failure in _failures:
			push_error("[S1-C5e] " + failure)
		quit(1)


func _run_smoke_case() -> void:
	for test_case in [
		{"tws": 8.0, "twa": 90.0, "trim": -50.0},
		{"tws": 5.0, "twa": 150.0, "trim": -70.0},
		{"tws": 12.0, "twa": 135.0, "trim": -70.0},
	]:
		var tws := float(test_case["tws"])
		var twa := float(test_case["twa"])
		var trim := float(test_case["trim"])
		if not await _prepare_case(tws, twa, trim):
			return
		var result := await _run_controlled_case(30, twa)
		var summary := _aggregate(result["samples"], 20.0, 30.0, twa)
		print("[S1-C5e][smoke] TWS=%.0f TWA=%.0f trim=%+.0f · HDG error=%.2f° rudder=%.2f° SOG=%.3fkn Vlong=%.3fm/s status=%s" % [
			tws, twa, trim, float(summary["mean_abs_heading_error_deg"]), float(summary["mean_rudder_deg"]),
			float(summary["mean_sog_kn"]), float(summary["mean_vlong_mps"]), _classify(summary, twa),
		])
		_run_count += 1


func _run_trim_screening() -> void:
	var scenario_count := TWS_VALUES_MPS.size() * TWA_VALUES_DEGREES.size()
	var scenario_index := 0
	for tws in TWS_VALUES_MPS:
		for twa in TWA_VALUES_DEGREES:
			scenario_index += 1
			var candidate_trims := _preferred_trim_candidates(float(twa))
			var rankings: Array[Dictionary] = []
			for trim in candidate_trims:
				if not await _prepare_case(float(tws), float(twa), float(trim)):
					return
				var result := await _run_controlled_case(SCREEN_SECONDS, float(twa))
				var summary := _aggregate(result["samples"], float(SCREEN_SECONDS - 3), float(SCREEN_SECONDS), float(twa))
				var score := _screen_score(summary)
				rankings.append({"trim_deg": float(trim), "score": score, "summary": summary})
				_screen_rows.append(_csv([
					_n(float(tws)), _n(float(twa)), _n(WIND_FROM_BEARING_DEGREES), _n(float(trim)),
					_n(float(summary["mean_sog_kn"])), _n(float(summary["mean_vlong_mps"])), _n(float(summary["mean_abs_heading_error_deg"])),
					_n(float(summary["mean_twa_deg"])), _n(float(summary["mean_aws_mps"])), _n(float(summary["mean_awa_deg"])),
					_n(float(summary["mean_abs_rudder_deg"])), _n(float(summary["rudder_saturation_fraction"])), _n(float(summary["mean_heel_deg"])),
					_n(float(summary["mean_luffing_scale"])), _n(score),
				]))
				_run_count += 1
			rankings.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["score"]) > float(b["score"]))
			var key := _scenario_key(float(tws), float(twa))
			_trim_rankings[key] = rankings.slice(0, mini(3, rankings.size()))
			var best: Dictionary = rankings[0]
			_trim_winners[key] = {"trim_deg": float(best["trim_deg"]), "screen_score": float(best["score"]), "screen_summary": best["summary"]}
			if scenario_index % 5 == 0 or scenario_index == scenario_count:
				var best_summary: Dictionary = best["summary"]
				print("[S1-C5e][screen %d/%d] TWS=%.0f TWA=%.0f trim=%+.0f · %.3fkn Vlong=%.3f err=%.1f° rudder=%.1f°" % [
					scenario_index, scenario_count, tws, twa, float(best["trim_deg"]),
					float(best_summary.get("mean_sog_kn", 0.0)), float(best_summary.get("mean_vlong_mps", 0.0)),
					float(best_summary.get("mean_abs_heading_error_deg", 0.0)), float(best_summary.get("mean_abs_rudder_deg", 0.0)),
				])


func _run_selected_polar() -> void:
	_polar_case_total = TWS_VALUES_MPS.size() * TWA_VALUES_DEGREES.size()
	for tws in TWS_VALUES_MPS:
		for twa in TWA_VALUES_DEGREES:
			_polar_case_index += 1
			var key := _scenario_key(float(tws), float(twa))
			if not _trim_rankings.has(key):
				_failures.append("No trim-screen result for %s." % key)
				return
			var selected_trim := float(_trim_winners[key]["trim_deg"])
			var selected_result: Dictionary = {}
			var selected_final: Dictionary = {}
			var selected_previous: Dictionary = {}
			var selected_status := "not_steady"
			var best_long_score := -INF
			for candidate_index in range(_trim_rankings[key].size()):
				var candidate: Dictionary = _trim_rankings[key][candidate_index]
				var trim := float(candidate["trim_deg"])
				if not await _prepare_case(float(tws), float(twa), trim):
					return
				var result := await _run_controlled_case(POLAR_SECONDS, float(twa))
				_run_count += 1
				var samples: Array = result["samples"]
				var previous := _aggregate(samples, 60.0, 90.0, float(twa))
				var final := _aggregate(samples, 90.0, 120.0, float(twa))
				var status := _classify_with_previous(final, previous, float(twa))
				if status == "steady":
					selected_trim = trim
					selected_result = result
					selected_final = final
					selected_previous = previous
					selected_status = status
					break
				var long_score := float(final["mean_vlong_mps"])
				long_score -= float(final["mean_abs_heading_error_deg"]) * 0.02
				long_score -= float(final["rudder_saturation_fraction"]) * 0.5
				if long_score > best_long_score:
					best_long_score = long_score
					selected_trim = trim
					selected_result = result
					selected_final = final
					selected_previous = previous
					selected_status = status
			var final := selected_final
			var previous := selected_previous
			var status := selected_status
			var result := selected_result
			var trim := selected_trim
			var metrics := _format_polar_metrics(float(tws), float(twa), trim, status, final, previous, result)
			_polar_rows.append(metrics["polar_row"])
			_best_trim_rows.append(metrics["best_trim_row"])
			if status != "steady":
				_unstable_rows.append(metrics["unstable_row"])
			_control_rows.append(metrics["control_row"])
			if _polar_case_index % 5 == 0 or _polar_case_index == _polar_case_total:
				print("[S1-C5e][polar %d/%d] TWS=%.0f TWA=%.0f trim=%+.0f · %.3fkn BSP=%.3f err=%.1f° rudder=%.1f° status=%s" % [
					_polar_case_index, _polar_case_total, tws, twa, trim,
					float(final["mean_sog_kn"]), float(final["mean_vlong_mps"]), float(final["mean_abs_heading_error_deg"]),
					float(final["mean_abs_rudder_deg"]), status,
				])


func _run_mirror_checks() -> void:
	for twa in [45.0, 90.0, 120.0, 150.0, 180.0]:
		var key := _scenario_key(8.0, float(twa))
		if not _trim_winners.has(key):
			continue
		var positive_trim := float(_trim_winners[key]["trim_deg"])
		for side_value in [1.0, -1.0]:
			var side_sign: float = float(side_value)
			var signed_twa: float = float(twa) * side_sign
			var trim: float = positive_trim * side_sign
			if not await _prepare_case(8.0, signed_twa, trim):
				return
			var result := await _run_controlled_case(MIRROR_SECONDS, signed_twa)
			var summary := _aggregate(result["samples"], 30.0, 60.0, signed_twa)
			var nav: Dictionary = _boat.call("get_navigation_snapshot")
			_mirror_rows.append(_csv([
				_n(8.0), _n(signed_twa), _n(WIND_FROM_BEARING_DEGREES), _n(float(nav["heading_degrees"])), _n(trim),
				_n(float(summary["mean_twa_deg"])), _n(float(summary["mean_sog_kn"])), _n(float(summary["mean_vlong_mps"])),
				_n(float(summary["mean_vlat_mps"])), _n(float(summary["mean_heel_deg"])), _n(float(summary["mean_abs_heading_error_deg"])),
				_n(float(summary["mean_rudder_deg"])), _n(float(summary["mean_sail_yaw_torque_nm"])),
				_n(float(summary["mean_keel_yaw_torque_nm"])), _n(float(summary["mean_rudder_yaw_torque_nm"])),
			]))
			_run_count += 1


func _run_wrong_side_controls() -> void:
	for twa in [90.0, 120.0, 150.0]:
		var preferred := float(_trim_winners[_scenario_key(8.0, twa)]["trim_deg"])
		var wrong_side := -preferred
		if absf(wrong_side) < 10.0:
			wrong_side = 50.0
		if not await _prepare_case(8.0, twa, wrong_side):
			return
		var result := await _run_controlled_case(WRONG_SIDE_SECONDS, twa)
		var summary := _aggregate(result["samples"], 10.0, float(WRONG_SIDE_SECONDS), twa)
		_wrong_side_rows.append(_csv([
			_n(8.0), _n(twa), _n(preferred), _n(wrong_side), _n(float(summary["mean_sog_kn"])), _n(float(summary["mean_vlong_mps"])),
			_n(float(summary["mean_twa_deg"])), _n(float(summary["mean_aws_mps"])), _n(float(summary["mean_luffing_scale"])),
			_n(float(summary["mean_abs_heading_error_deg"])), _n(float(summary["mean_abs_rudder_deg"])), _n(float(summary["mean_sail_forward_n"])),
		]))
		_run_count += 1


func _prepare_case(tws_mps: float, signed_twa_deg: float, trim_deg: float) -> bool:
	if not await _configure_lab(tws_mps, WIND_FROM_BEARING_DEGREES, trim_deg, 0.0, {"linear_damp_mode": 1, "linear_damp": 0.0}):
		return false
	var target_heading := POLAR_MATH.target_heading_degrees(WIND_FROM_BEARING_DEGREES, signed_twa_deg)
	# SailboatLab reset takes Godot's positive yaw, while compass heading grows
	# clockwise. Map the desired compass course through the inverse yaw sign.
	_boat.call("reset_to_neutral", -target_heading)
	_boat.sleeping = false
	while bool(_boat.call("get_s1_c4_diagnostic_snapshot").get("pose_command_pending", false)):
		await physics_frame
	_boat.set("actual_sail_angle_rad", deg_to_rad(trim_deg))
	_boat.call("set_target_sail_angle", deg_to_rad(trim_deg))
	_boat.set("actual_rudder_angle_rad", 0.0)
	_boat.call("set_target_rudder_angle", 0.0)
	_wind.call("set_test_simulation_time", 0.0)
	_boat.sleeping = false
	return true


func _run_controlled_case(duration_seconds: int, target_twa_degrees: float) -> Dictionary:
	var target_heading := POLAR_MATH.target_heading_degrees(WIND_FROM_BEARING_DEGREES, target_twa_degrees)
	var initial_position: Vector3 = _boat.global_position
	var initial_forward := -_boat.global_basis.z
	var previous_heading := float(_boat.call("get_s1_c4_diagnostic_snapshot").get("heading_degrees", 0.0))
	var unwrapped_heading := previous_heading
	var max_abs_yaw_rate := 0.0
	var samples: Array[Dictionary] = []
	_apply_heading_controller(target_heading)
	for tick in range(duration_seconds * SIMULATION_HZ):
		await physics_frame
		_apply_heading_controller(target_heading)
		var diagnostic: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
		var heading := float(diagnostic.get("heading_degrees", 0.0))
		unwrapped_heading += wrapf(heading - previous_heading, -180.0, 180.0)
		previous_heading = heading
		var yaw_rate := absf(rad_to_deg(float(diagnostic.get("yaw_rate_rad_s", 0.0))))
		max_abs_yaw_rate = maxf(max_abs_yaw_rate, yaw_rate)
		if (tick + 1) % SIMULATION_HZ == 0:
			samples.append(_sample_polar_state(
				float(tick + 1) / float(SIMULATION_HZ), target_heading, target_twa_degrees,
				unwrapped_heading, initial_position, initial_forward, max_abs_yaw_rate
			))
	return {"samples": samples, "max_abs_yaw_rate_deg_s": max_abs_yaw_rate}


func _apply_heading_controller(target_heading_degrees: float) -> void:
	var diagnostic: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
	var heading := float(diagnostic.get("heading_degrees", 0.0))
	var error := wrapf(target_heading_degrees - heading, -180.0, 180.0)
	# Godot local +Y angular velocity decreases compass heading. Negate it so
	# positive feedback rate means clockwise/starboard course change.
	var compass_yaw_rate := -rad_to_deg(float(diagnostic.get("yaw_rate_rad_s", 0.0)))
	var max_rudder_deg := rad_to_deg(float(_boat.call("get_navigation_snapshot").get("max_rudder_angle_rad", 0.611)))
	var command_deg := POLAR_MATH.rudder_command_degrees(error, compass_yaw_rate, RUDDER_P_GAIN, RUDDER_D_GAIN, max_rudder_deg)
	_boat.call("set_target_rudder_angle", deg_to_rad(command_deg))


func _sample_polar_state(
	time_seconds: float,
	target_heading: float,
	target_twa: float,
	unwrapped_heading: float,
	initial_position: Vector3,
	initial_forward: Vector3,
	max_abs_yaw_rate: float
) -> Dictionary:
	var diagnostic: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
	var debug: Dictionary = _boat.call("get_debug_snapshot")
	var nav: Dictionary = _boat.call("get_navigation_snapshot")
	var heading := float(diagnostic.get("heading_degrees", 0.0))
	var heading_error := wrapf(target_heading - heading, -180.0, 180.0)
	var actual_twa := POLAR_MATH.relative_twa_degrees(WIND_FROM_BEARING_DEGREES, heading)
	var body_velocity: Vector3 = _boat.linear_velocity
	var horizontal_velocity := Vector3(body_velocity.x, 0.0, body_velocity.z)
	var breakdown := _force_breakdown(debug)
	var max_rudder_deg := rad_to_deg(float(nav.get("max_rudder_angle_rad", 0.611)))
	var actual_rudder_deg := rad_to_deg(float(nav.get("actual_rudder_angle_rad", 0.0)))
	return {
		"time_s": time_seconds,
		"heading_deg": heading,
		"unwrapped_heading_deg": unwrapped_heading,
		"target_heading_deg": target_heading,
		"heading_error_deg": heading_error,
		"twa_deg": actual_twa,
		"target_twa_deg": target_twa,
		"sog_kn": float(nav.get("sog_knots", 0.0)),
		"vlong_mps": float(diagnostic.get("longitudinal_velocity_mps", 0.0)),
		"vlat_mps": float(diagnostic.get("lateral_velocity_mps", 0.0)),
		"sideslip_deg": rad_to_deg(float(nav.get("keel_side_slip_angle_rad", 0.0))),
		"heel_deg": float(nav.get("heel_degrees", 0.0)),
		"awa_deg": float(nav.get("apparent_wind_from_relative_degrees", 0.0)),
		"aws_mps": float(nav.get("apparent_wind_speed_mps", 0.0)),
		"sail_deg": rad_to_deg(float(nav.get("actual_sail_angle_rad", 0.0))),
		"rudder_deg": actual_rudder_deg,
		"rudder_target_deg": rad_to_deg(float(nav.get("target_rudder_angle_rad", 0.0))),
		"rudder_saturated": absf(actual_rudder_deg) >= maxf(max_rudder_deg - 1.0, 0.0),
		"yaw_rate_abs_deg_s": absf(rad_to_deg(float(diagnostic.get("yaw_rate_rad_s", 0.0)))),
		"max_abs_yaw_rate_deg_s": max_abs_yaw_rate,
		"luffing_scale": float(debug.get("sail_luffing_scale", 0.0)),
		"windward_side": str(debug.get("windward_side", "")),
		"sail_forward_n": float(breakdown.get("sail_forward_n", 0.0)),
		"hull_forward_n": float(breakdown.get("hull_forward_n", 0.0)),
		"keel_forward_n": float(breakdown.get("keel_forward_n", 0.0)),
		"rudder_forward_n": float(breakdown.get("rudder_forward_n", 0.0)),
		"explicit_forward_n": float(breakdown.get("explicit_forward_n", 0.0)),
		"sail_yaw_torque_nm": float(diagnostic.get("sail_yaw_torque_local_nm", 0.0)),
		"headsail_forward_n": -Vector3(debug.get("headsail_net_force_local_n", Vector3.ZERO)).z,
		"headsail_lateral_n": Vector3(debug.get("headsail_net_force_local_n", Vector3.ZERO)).x,
		"headsail_roll_torque_nm": float(debug.get("headsail_roll_torque_local_nm", 0.0)),
		"headsail_yaw_torque_nm": float(debug.get("headsail_yaw_torque_nm", 0.0)),
		"keel_yaw_torque_nm": float(diagnostic.get("keel_yaw_torque_local_nm", 0.0)),
		"rudder_yaw_torque_nm": float(diagnostic.get("rudder_yaw_torque_local_nm", 0.0)),
		"forward_displacement_m": (_boat.global_position - initial_position).dot(initial_forward),
		"upwind_vmg_mps": POLAR_MATH.upwind_vmg_mps(horizontal_velocity, WIND_FROM_BEARING_DEGREES),
	}


func _aggregate(samples: Array, start_seconds: float, end_seconds: float, target_twa: float) -> Dictionary:
	var selected: Array[Dictionary] = []
	for value in samples:
		var sample: Dictionary = value
		if float(sample.get("time_s", 0.0)) >= start_seconds and float(sample.get("time_s", 0.0)) <= end_seconds:
			selected.append(sample)
	if selected.is_empty():
		return _empty_summary(target_twa)
	var result := _empty_summary(target_twa)
	var angle_sin := 0.0
	var angle_cos := 0.0
	var absolute_angle_sin := 0.0
	var absolute_angle_cos := 0.0
	for sample in selected:
		for key in ["mean_sog_kn", "mean_vlong_mps", "mean_vlat_mps", "mean_abs_heading_error_deg", "mean_heel_deg", "mean_abs_rudder_deg", "mean_aws_mps", "mean_luffing_scale", "mean_sideslip_deg", "mean_sail_forward_n", "mean_headsail_forward_n", "mean_headsail_lateral_n", "mean_headsail_roll_torque_nm", "mean_headsail_yaw_torque_nm", "mean_hull_forward_n", "mean_keel_forward_n", "mean_rudder_forward_n", "mean_explicit_forward_n", "mean_sail_yaw_torque_nm", "mean_keel_yaw_torque_nm", "mean_rudder_yaw_torque_nm", "mean_upwind_vmg_mps", "mean_forward_displacement_m"]:
			var source_key := str(key).trim_prefix("mean_")
			result[key] = float(result[key]) + float(sample.get(source_key, 0.0))
		angle_sin += sin(deg_to_rad(float(sample.get("twa_deg", 0.0))))
		angle_cos += cos(deg_to_rad(float(sample.get("twa_deg", 0.0))))
		absolute_angle_sin += sin(deg_to_rad(absf(float(sample.get("awa_deg", 0.0)))))
		absolute_angle_cos += cos(deg_to_rad(absf(float(sample.get("awa_deg", 0.0)))))
		if bool(sample.get("rudder_saturated", false)):
			result["rudder_saturation_count"] = int(result["rudder_saturation_count"]) + 1
	var count := float(selected.size())
	for key in ["mean_sog_kn", "mean_vlong_mps", "mean_vlat_mps", "mean_abs_heading_error_deg", "mean_heel_deg", "mean_abs_rudder_deg", "mean_aws_mps", "mean_luffing_scale", "mean_sideslip_deg", "mean_sail_forward_n", "mean_headsail_forward_n", "mean_headsail_lateral_n", "mean_headsail_roll_torque_nm", "mean_headsail_yaw_torque_nm", "mean_hull_forward_n", "mean_keel_forward_n", "mean_rudder_forward_n", "mean_explicit_forward_n", "mean_sail_yaw_torque_nm", "mean_keel_yaw_torque_nm", "mean_rudder_yaw_torque_nm", "mean_upwind_vmg_mps", "mean_forward_displacement_m"]:
		result[key] = float(result[key]) / count
	result["mean_twa_deg"] = rad_to_deg(atan2(angle_sin, angle_cos))
	result["mean_awa_deg"] = rad_to_deg(atan2(absolute_angle_sin, absolute_angle_cos))
	result["rudder_saturation_fraction"] = float(result["rudder_saturation_count"]) / count
	result["sample_count"] = selected.size()
	result["mean_abs_heading_error_deg"] = _mean_abs_sample_value(selected, "heading_error_deg")
	result["max_yaw_rate_deg_s"] = 0.0
	result["mean_heading_deg"] = float(selected.back().get("heading_deg", 0.0))
	result["heading_drift_deg"] = float(selected.back().get("unwrapped_heading_deg", 0.0)) - float(selected.front().get("unwrapped_heading_deg", 0.0))
	result["mean_sail_deg"] = float(selected.back().get("sail_deg", 0.0))
	result["mean_rudder_deg"] = _mean_sample_value(selected, "rudder_deg")
	result["mean_rudder_target_deg"] = _mean_sample_value(selected, "rudder_target_deg")
	result["mean_abs_rudder_deg"] = _mean_abs_sample_value(selected, "rudder_deg")
	result["max_abs_rudder_deg"] = _max_abs_sample_value(selected, "rudder_deg")
	result["max_yaw_rate_deg_s"] = _max_sample_value(selected, "yaw_rate_abs_deg_s")
	result["max_abs_yaw_rate_deg_s"] = _max_sample_value(selected, "max_abs_yaw_rate_deg_s")
	result["mean_heading_error_signed_deg"] = _mean_sample_value(selected, "heading_error_deg")
	result["mean_awa_signed_deg"] = _mean_sample_value(selected, "awa_deg")
	return result


func _empty_summary(target_twa: float) -> Dictionary:
	return {
		"mean_sog_kn": 0.0, "mean_vlong_mps": 0.0, "mean_vlat_mps": 0.0,
		"mean_abs_heading_error_deg": 0.0, "mean_heading_error_signed_deg": 0.0,
		"mean_twa_deg": target_twa, "mean_heel_deg": 0.0, "mean_abs_rudder_deg": 0.0,
		"mean_rudder_deg": 0.0, "mean_rudder_target_deg": 0.0, "max_abs_rudder_deg": 0.0,
		"rudder_saturation_count": 0, "rudder_saturation_fraction": 0.0,
		"mean_aws_mps": 0.0, "mean_awa_deg": 0.0, "mean_awa_signed_deg": 0.0,
		"mean_luffing_scale": 0.0, "mean_sideslip_deg": 0.0,
		"mean_sail_forward_n": 0.0, "mean_hull_forward_n": 0.0,
		"mean_headsail_forward_n": 0.0, "mean_headsail_lateral_n": 0.0, "mean_headsail_roll_torque_nm": 0.0, "mean_headsail_yaw_torque_nm": 0.0,
		"mean_keel_forward_n": 0.0, "mean_rudder_forward_n": 0.0,
		"mean_explicit_forward_n": 0.0, "mean_sail_yaw_torque_nm": 0.0,
		"mean_keel_yaw_torque_nm": 0.0, "mean_rudder_yaw_torque_nm": 0.0,
		"mean_upwind_vmg_mps": 0.0, "mean_forward_displacement_m": 0.0,
		"mean_heading_deg": 0.0, "heading_drift_deg": 0.0,
		"max_yaw_rate_deg_s": 0.0, "max_abs_yaw_rate_deg_s": 0.0, "sample_count": 0,
	}


func _format_polar_metrics(tws: float, twa: float, trim: float, status: String, final: Dictionary, previous: Dictionary, run_result: Dictionary) -> Dictionary:
	var target_vmg := -float(final["mean_upwind_vmg_mps"]) if twa > 90.0 else float(final["mean_upwind_vmg_mps"])
	var speed_delta := float(final["mean_sog_kn"]) - float(previous["mean_sog_kn"])
	var target_heading := POLAR_MATH.target_heading_degrees(WIND_FROM_BEARING_DEGREES, twa)
	var samples: Array = run_result["samples"]
	var net_forward_displacement := float(samples.back().get("forward_displacement_m", 0.0)) if not samples.is_empty() else 0.0
	var values := [
		_n(tws), _n(twa), _n(WIND_FROM_BEARING_DEGREES), _n(target_heading), _n(trim), _n(float(final["mean_twa_deg"])),
		_n(float(final["mean_sog_kn"])), _n(float(final["mean_vlong_mps"])), _n(float(final["mean_vlat_mps"])),
		_n(net_forward_displacement),
		_n(float(final["mean_upwind_vmg_mps"])), _n(target_vmg), _n(float(final["mean_aws_mps"])), _n(float(final["mean_awa_deg"])),
		_n(float(final["mean_sail_deg"])), _n(float(final["mean_rudder_deg"])), _n(float(final["mean_abs_rudder_deg"])),
		_n(float(final["max_abs_rudder_deg"])), _n(float(final["rudder_saturation_fraction"])),
		_n(float(final["mean_abs_heading_error_deg"])), _n(float(final["mean_heading_error_signed_deg"])), _n(float(final["heading_drift_deg"])),
		_n(float(final["mean_heel_deg"])), _n(float(final["mean_sideslip_deg"])), _n(float(final["mean_luffing_scale"])),
		_n(speed_delta), _n(float(final["mean_sail_forward_n"])), _n(float(final["mean_hull_forward_n"])),
		_n(float(final["mean_keel_forward_n"])), _n(float(final["mean_rudder_forward_n"])), _n(float(final["mean_explicit_forward_n"])),
		_n(float(final["mean_sail_yaw_torque_nm"])), _n(float(final["mean_keel_yaw_torque_nm"])), _n(float(final["mean_rudder_yaw_torque_nm"])),
		_n(float(final["max_abs_yaw_rate_deg_s"])), status,
	]
	var best := _csv([_n(tws), _n(twa), _n(trim), _n(float(final["mean_sog_kn"])), _n(float(final["mean_vlong_mps"])), _n(target_vmg), status, _n(float(final["mean_abs_rudder_deg"])), _n(float(final["mean_heel_deg"]))])
	var unstable := _csv([_n(tws), _n(twa), _n(trim), status, _n(float(final["mean_sog_kn"])), _n(float(final["mean_vlong_mps"])), _n(float(final["mean_abs_heading_error_deg"])), _n(float(final["heading_drift_deg"])), _n(float(final["rudder_saturation_fraction"])), _n(float(final["mean_abs_rudder_deg"])), _n(float(final["mean_luffing_scale"])), _n(speed_delta)])
	var control := _csv([_n(tws), _n(twa), _n(trim), _n(float(final["mean_abs_heading_error_deg"])), _n(float(final["mean_heading_error_signed_deg"])), _n(float(final["mean_twa_deg"])), _n(float(final["heading_drift_deg"])), _n(float(final["mean_rudder_deg"])), _n(float(final["mean_abs_rudder_deg"])), _n(float(final["max_abs_rudder_deg"])), _n(float(final["rudder_saturation_fraction"])), _n(float(final["mean_sail_yaw_torque_nm"])), _n(float(final["mean_keel_yaw_torque_nm"])), _n(float(final["mean_rudder_yaw_torque_nm"])), _n(float(final["max_abs_yaw_rate_deg_s"])), status])
	return {"polar_row": _csv(values), "best_trim_row": best, "unstable_row": unstable, "control_row": control}


func _classify_with_previous(final: Dictionary, previous: Dictionary, target_twa: float) -> String:
	var speed_change := absf(float(final["mean_sog_kn"]) - float(previous["mean_sog_kn"]))
	var max_rudder := rad_to_deg(float(PROFILE.get("max_rudder_angle_rad")))
	var heading_error := float(final["mean_abs_heading_error_deg"])
	var target_twa_error := absf(wrapf(float(final["mean_twa_deg"]) - target_twa, -180.0, 180.0))
	var speed_tolerance := maxf(0.10, float(final["mean_sog_kn"]) * 0.04)
	if (
		float(final["rudder_saturation_fraction"]) >= 0.20
		or heading_error > 5.0
		or target_twa_error > 5.0
		or absf(float(final["heading_drift_deg"])) > MAX_STEADY_HEADING_DRIFT_DEGREES
	):
		return "control_limited"
	if speed_change > speed_tolerance:
		return "not_steady"
	if float(final["mean_vlong_mps"]) <= 0.15:
		return "no_forward_progress"
	if max_rudder <= 0.0 or float(final["max_abs_rudder_deg"]) > max_rudder + 0.1:
		return "control_limited"
	return "steady"


func _classify(summary: Dictionary, target_twa: float) -> String:
	var error := float(summary["mean_abs_heading_error_deg"])
	var twa_error := absf(wrapf(float(summary["mean_twa_deg"]) - target_twa, -180.0, 180.0))
	if float(summary["rudder_saturation_fraction"]) >= 0.20 or error > 5.0 or twa_error > 5.0:
		return "control_limited"
	if float(summary["mean_vlong_mps"]) <= 0.15:
		return "no_forward_progress"
	return "screen_only"


func _screen_score(summary: Dictionary) -> float:
	var score := float(summary["mean_vlong_mps"])
	score -= float(summary["mean_abs_heading_error_deg"]) * 0.012
	score -= float(summary["mean_abs_rudder_deg"]) * 0.0008
	score -= float(summary["rudder_saturation_fraction"]) * 0.25
	score -= maxf(absf(float(summary["mean_heel_deg"])) - 25.0, 0.0) * 0.002
	if float(summary["mean_luffing_scale"]) < 0.2:
		score -= 0.10
	return score


func _preferred_trim_candidates(signed_twa: float) -> Array[float]:
	var candidates: Array[float] = [0.0]
	if absf(signed_twa) >= 179.9:
		for magnitude in TRIM_MAGNITUDES_DEGREES:
			candidates.append(float(magnitude))
			candidates.append(-float(magnitude))
	else:
		var leeward_sign := -signf(signed_twa)
		for magnitude in TRIM_MAGNITUDES_DEGREES:
			candidates.append(leeward_sign * float(magnitude))
	return candidates


func _write_headsail_candidate() -> void:
	# Proposed independent jib sail: no production profile or force code is changed.
	var head := Vector3(0.0, 4.95, -0.75)
	var tack := Vector3(0.0, 0.62, -3.55)
	var clew := Vector3(0.0, 0.62, -1.15)
	var area := 0.5 * absf((head.y - tack.y) * (clew.z - tack.z))
	var center := (head + tack + clew) / 3.0
	_headsail_rows = [_csv([
		"8m_cruising_jib_candidate_v1", "prototype_candidate_only", _n(area),
		_n(head.x), _n(head.y), _n(head.z), _n(tack.x), _n(tack.y), _n(tack.z),
		_n(clew.x), _n(clew.y), _n(clew.z), _n(center.x), _n(center.y), _n(center.z),
		"independent_from_main_sail", "profile_resource_candidate_not_implemented",
	])]


func _write_c5e_outputs() -> void:
	if not _screen_rows.is_empty():
		_write_c5e_csv("trim_screening.csv", "tws_mps,target_twa_deg,wind_from_bearing_deg,screen_sail_angle_deg,screen_sog_knots,screen_vlong_mps,mean_abs_heading_error_deg,mean_actual_twa_deg,mean_aws_mps,mean_abs_awa_deg,mean_abs_rudder_deg,rudder_saturation_fraction,mean_heel_deg,mean_luffing_scale,screen_score\n" + "\n".join(_screen_rows) + "\n")
	if not _polar_rows.is_empty():
		_write_c5e_csv("single_mainsail_polar.csv", "tws_mps,target_twa_deg,wind_from_bearing_deg,target_heading_deg,selected_sail_angle_deg,mean_actual_twa_deg,mean_sog_knots,mean_longitudinal_speed_mps,mean_lateral_speed_mps,net_forward_displacement_m,upwind_vmg_mps,target_vmg_mps,mean_aws_mps,mean_abs_awa_deg,mean_actual_sail_angle_deg,mean_rudder_angle_deg,mean_abs_rudder_deg,max_abs_rudder_deg,rudder_saturation_fraction,mean_abs_heading_error_deg,mean_signed_heading_error_deg,heading_drift_deg,mean_heel_deg,mean_sideslip_deg,mean_luffing_scale,sog_change_vs_previous_30s_knots,mean_sail_forward_n,mean_hull_forward_n,mean_keel_forward_n,mean_rudder_forward_n,mean_explicit_forward_n,mean_sail_yaw_torque_nm,mean_keel_yaw_torque_nm,mean_rudder_yaw_torque_nm,max_yaw_rate_deg_s,status\n" + "\n".join(_polar_rows) + "\n")
	if not _best_trim_rows.is_empty():
		_write_c5e_csv("best_trim_by_wind_angle.csv", "tws_mps,target_twa_deg,selected_sail_angle_deg,mean_sog_knots,mean_longitudinal_speed_mps,target_vmg_mps,status,mean_abs_rudder_deg,mean_heel_deg\n" + "\n".join(_best_trim_rows) + "\n")
	if not _unstable_rows.is_empty():
		_write_c5e_csv("unstable_and_limited_conditions.csv", "tws_mps,target_twa_deg,selected_sail_angle_deg,status,mean_sog_knots,mean_longitudinal_speed_mps,mean_abs_heading_error_deg,heading_drift_deg,rudder_saturation_fraction,mean_abs_rudder_deg,mean_luffing_scale,sog_change_previous_30s_knots\n" + "\n".join(_unstable_rows) + "\n")
	if not _control_rows.is_empty():
		_write_c5e_csv("heading_control_and_torque.csv", "tws_mps,target_twa_deg,selected_sail_angle_deg,mean_abs_heading_error_deg,mean_signed_heading_error_deg,mean_actual_twa_deg,heading_drift_deg,mean_rudder_deg,mean_abs_rudder_deg,max_abs_rudder_deg,rudder_saturation_fraction,mean_sail_yaw_torque_nm,mean_keel_yaw_torque_nm,mean_rudder_yaw_torque_nm,max_yaw_rate_deg_s,status\n" + "\n".join(_control_rows) + "\n")
	if not _mirror_rows.is_empty():
		_write_c5e_csv("port_starboard_mirror_validation.csv", "tws_mps,signed_twa_deg,wind_from_bearing_deg,initial_heading_deg,sail_angle_deg,mean_actual_twa_deg,mean_sog_knots,mean_longitudinal_speed_mps,mean_lateral_speed_mps,mean_heel_deg,mean_abs_heading_error_deg,mean_rudder_deg,mean_sail_yaw_torque_nm,mean_keel_yaw_torque_nm,mean_rudder_yaw_torque_nm\n" + "\n".join(_mirror_rows) + "\n")
	if not _wrong_side_rows.is_empty():
		_write_c5e_csv("wrong_side_trim_controls.csv", "tws_mps,target_twa_deg,screen_selected_leeward_trim_deg,wrong_side_trim_deg,mean_sog_knots,mean_longitudinal_speed_mps,mean_actual_twa_deg,mean_aws_mps,mean_luffing_scale,mean_abs_heading_error_deg,mean_abs_rudder_deg,mean_sail_forward_n\n" + "\n".join(_wrong_side_rows) + "\n")
	if not _headsail_rows.is_empty():
		_write_c5e_csv("headsail_geometry_candidate.csv", "candidate_id,usage,area_m2,head_x_m,head_y_m,head_z_m,tack_x_m,tack_y_m,tack_z_m,clew_x_m,clew_y_m,clew_z_m,pressure_center_x_m,pressure_center_y_m,pressure_center_z_m,trim_control,implementation_status\n" + "\n".join(_headsail_rows) + "\n")


func _write_c5e_csv(filename: String, content: String) -> void:
	var path := ProjectSettings.globalize_path(C5E_DATA_DIR.path_join(filename))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_failures.append("Could not write %s: %s" % [path, error_string(FileAccess.get_open_error())])
		return
	file.store_string(content)
	file.close()


func _scenario_key(tws: float, twa: float) -> String:
	return "%d_%d" % [int(round(tws * 10.0)), int(round(twa))]


func _mean_sample_value(samples: Array[Dictionary], key: String) -> float:
	if samples.is_empty():
		return 0.0
	var total := 0.0
	for sample in samples:
		total += float(sample.get(key, 0.0))
	return total / float(samples.size())


func _mean_abs_sample_value(samples: Array[Dictionary], key: String) -> float:
	if samples.is_empty():
		return 0.0
	var total := 0.0
	for sample in samples:
		total += absf(float(sample.get(key, 0.0)))
	return total / float(samples.size())


func _max_abs_sample_value(samples: Array[Dictionary], key: String) -> float:
	var maximum := 0.0
	for sample in samples:
		maximum = maxf(maximum, absf(float(sample.get(key, 0.0))))
	return maximum


func _max_sample_value(samples: Array[Dictionary], key: String) -> float:
	var maximum := 0.0
	for sample in samples:
		maximum = maxf(maximum, float(sample.get(key, 0.0)))
	return maximum
