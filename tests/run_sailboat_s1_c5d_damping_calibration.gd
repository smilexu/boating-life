extends "res://tests/run_sailboat_s1_c5c_drag_diagnostics.gd"
## Offline S1-C5d damping validation. It reuses the C5c real-rigidbody fixture
## and helpers but writes only into c5d_data, leaving C5b/C5c history intact.

const C5D_DATA_DIR := "res://docs/sailing/c5d_data"
const DAMPING_CHECKPOINTS := [0, 2, 5, 10, 20, 30, 60, 120]
const DECEL_CHECKPOINTS := [0, 1, 5, 10, 20, 40]
const WIND_SPEEDS_MPS := [3.0, 5.0, 8.0, 10.0, 12.0]
const RELATIVE_WIND_FROM_DEGREES := [-180.0, -150.0, -120.0, -90.0, -60.0, -45.0, 45.0, 60.0, 90.0, 120.0, 150.0, 180.0]
const WIND_TRIMS_DEGREES := {
	45.0: 30.0,
	60.0: 40.0,
	90.0: 50.0,
	120.0: 62.0,
	150.0: 70.0,
	180.0: 70.0,
}

var _c5d_mode := "validation"
var _damping_rows: Array[String] = []
var _deceleration_rows: Array[String] = []
var _matrix_rows: Array[String] = []
var _dynamic_rows: Array[String] = []
var _matrix_case_index := 0
var _matrix_case_count := 0


func _run() -> void:
	_started_usec = Time.get_ticks_usec()
	_original_physics_hz = Engine.physics_ticks_per_second
	_original_time_scale = Engine.time_scale
	Engine.physics_ticks_per_second = int(SIMULATION_HZ * OFFLINE_TIME_SCALE)
	Engine.time_scale = OFFLINE_TIME_SCALE
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--phase="):
			_c5d_mode = argument.trim_prefix("--phase=")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(C5D_DATA_DIR))
	if _c5d_mode == "validation" or _c5d_mode == "all":
		await _run_damping_comparison()
		await _run_natural_deceleration_c5d()
		await _run_static_buoyancy_check()
		await _run_dynamic_wave_check()
	if _c5d_mode == "waves":
		await _run_dynamic_wave_check()
	if _c5d_mode == "matrix" or _c5d_mode == "all":
		await _run_wind_matrix()
	if _c5d_mode not in ["validation", "waves", "matrix", "all"]:
		_failures.append("Unknown phase '%s'. Use validation, waves, matrix, or all." % _c5d_mode)
	_write_c5d_outputs()
	var elapsed := float(Time.get_ticks_usec() - _started_usec) / 1_000_000.0
	Engine.physics_ticks_per_second = _original_physics_hz
	Engine.time_scale = _original_time_scale
	if _failures.is_empty():
		print("[S1-C5d] phase=%s runs=%d wall=%.2fs output=docs/sailing/c5d_data/" % [_c5d_mode, _run_count, elapsed])
		quit(0)
	else:
		for failure in _failures:
			push_error("[S1-C5d] " + failure)
		quit(1)


func _run_damping_comparison() -> void:
	var variants := [
		{"name": "historical_combine_0_12", "mode": 0, "damp": 0.12},
		{"name": "combine_0", "mode": 0, "damp": 0.0},
		{"name": "replace_0_12", "mode": 1, "damp": 0.12},
		{"name": "replace_0", "mode": 1, "damp": 0.0},
		{"name": "replace_0_02", "mode": 1, "damp": 0.02},
	]
	for variant in variants:
		var overrides := {
			"linear_damp_mode": int(variant["mode"]),
			"linear_damp": float(variant["damp"]),
		}
		if not await _configure_lab(8.0, 270.0, 50.0, 0.0, overrides):
			return
		var effective := _effective_linear_damping()
		var initial_position := _boat.global_position
		var initial_forward := -_boat.global_basis.z
		var previous_longitudinal := 0.0
		var max_yaw_rate := 0.0
		var checkpoints := {}
		for tick in range(0, 120 * SIMULATION_HZ + 1):
			if tick > 0:
				await physics_frame
			var sim_time := float(tick) / float(SIMULATION_HZ)
			var sample: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
			var debug: Dictionary = _boat.call("get_debug_snapshot")
			var yaw_rate := absf(rad_to_deg(float(sample.get("yaw_rate_rad_s", 0.0))))
			max_yaw_rate = maxf(max_yaw_rate, yaw_rate)
			var longitudinal := float(sample.get("longitudinal_velocity_mps", 0.0))
			var longitudinal_accel := (longitudinal - previous_longitudinal) * float(SIMULATION_HZ) if tick > 0 else 0.0
			previous_longitudinal = longitudinal
			if tick % SIMULATION_HZ == 0 and DAMPING_CHECKPOINTS.has(int(tick / SIMULATION_HZ)):
				var breakdown := _force_breakdown(debug)
				var mass_value := float(debug.get("mass_kg", PROFILE.get("mass_kg")))
				var damp_force := -mass_value * effective * longitudinal
				var disp: Vector3 = _boat.global_position - initial_position
				var performance: Dictionary = debug
				var row := _csv([
					variant["name"], int(variant["mode"]), "COMBINE" if int(variant["mode"]) == 0 else "REPLACE",
					_n(float(variant["damp"])), _n(float(ProjectSettings.get_setting("physics/3d/default_linear_damp"))),
					_n(effective), _n(sim_time), _n(float(sample.get("heading_degrees", 0.0))),
					_n(float(sample.get("sog_mps", 0.0)) * KNOTS_PER_MPS), _n(longitudinal),
					_n(float(sample.get("lateral_velocity_mps", 0.0))), _n(rad_to_deg(atan2(float(sample.get("lateral_velocity_mps", 0.0)), maxf(absf(longitudinal), 0.05)))),
					_n(float(sample.get("roll_degrees", 0.0))), _n(yaw_rate), _n(disp.dot(initial_forward)),
					_n(float(breakdown.get("sail_forward_n", 0.0))), _n(float(breakdown.get("hull_forward_n", 0.0))),
					_n(float(breakdown.get("keel_forward_n", 0.0))), _n(float(breakdown.get("rudder_forward_n", 0.0))),
					_n(float(breakdown.get("explicit_forward_n", 0.0))), _n(damp_force),
					_n(float(breakdown.get("explicit_forward_n", 0.0)) + damp_force), _n(longitudinal_accel),
					_n(max_yaw_rate), int(performance.get("total_physics_calculation_average_usec", 0)),
					int(performance.get("total_physics_calculation_p95_usec", 0)),
				])
				_damping_rows.append(row)
				checkpoints[sim_time] = {"sog_kn": float(sample.get("sog_mps", 0.0)) * KNOTS_PER_MPS, "vlong": longitudinal, "heading": float(sample.get("heading_degrees", 0.0))}
			if tick > 0 and tick % (30 * SIMULATION_HZ) == 0:
				print("[S1-C5d][damping] %s t=%ds Vlong=%.3f m/s SOG=%.3f kn HDG=%.1f°" % [variant["name"], int(sim_time), longitudinal, float(sample.get("sog_mps", 0.0)) * KNOTS_PER_MPS, float(sample.get("heading_degrees", 0.0))])
		_run_count += 1
		if checkpoints.has(60.0) and checkpoints.has(120.0):
			var speed_delta: float = absf(float(checkpoints[120.0]["sog_kn"]) - float(checkpoints[60.0]["sog_kn"]))
			if speed_delta > 0.10:
				print("[S1-C5d][damping] %s has not converged by 120 s (60→120 SOG delta %.3f kn)." % [variant["name"], speed_delta])


func _run_natural_deceleration_c5d() -> void:
	for speed_knots in [0.5, 1.0, 2.0, 4.0, 6.0]:
		if not await _configure_lab(0.0, 270.0, 0.0, 0.0, {"linear_damp_mode": 1, "linear_damp": 0.0}):
			return
		await _run_velocity_release("longitudinal_%0.1fkn" % speed_knots, Vector3(0.0, 0.0, -speed_knots / KNOTS_PER_MPS), 40.0)
	if not await _configure_lab(0.0, 270.0, 0.0, 0.0, {"linear_damp_mode": 1, "linear_damp": 0.0}):
		return
	await _run_velocity_release("lateral_only_0_5mps", Vector3(0.5, 0.0, 0.0), 40.0)
	if not await _configure_lab(0.0, 270.0, 0.0, 0.0, {"linear_damp_mode": 1, "linear_damp": 0.0}):
		return
	_boat.angular_velocity = _boat.global_basis * Vector3(0.0, 0.05, 0.0)
	await _run_velocity_release("yaw_rate_only_0_05rad_s", Vector3.ZERO, 40.0)


func _run_velocity_release(label: String, local_velocity: Vector3, duration_s: float) -> void:
	_boat.call("set_test_initial_linear_velocity_local", local_velocity)
	_boat.sleeping = false
	while bool(_boat.call("get_s1_c4_diagnostic_snapshot").get("test_initial_velocity_pending", false)):
		await physics_frame
	var previous_speed := 0.0
	var max_power_w := -INF
	for tick in range(0, int(duration_s * SIMULATION_HZ) + 1):
		if tick > 0:
			await physics_frame
		var sim_time := float(tick) / float(SIMULATION_HZ)
		var debug: Dictionary = _boat.call("get_debug_snapshot")
		var sample: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
		var velocity: Vector3 = debug.get("local_velocity_mps", Vector3.ZERO)
		var hydro_force: Vector3 = debug.get("total_horizontal_force_local_n", Vector3.ZERO)
		var power := hydro_force.dot(velocity)
		var speed := float(sample.get("sog_mps", 0.0)) * KNOTS_PER_MPS
		max_power_w = maxf(max_power_w, power)
		if tick % SIMULATION_HZ == 0 and DECEL_CHECKPOINTS.has(int(tick / SIMULATION_HZ)):
			_deceleration_rows.append(_csv([
				label, _n(local_velocity.length() * KNOTS_PER_MPS), _n(sim_time), _n(speed),
				_n(float(sample.get("longitudinal_velocity_mps", 0.0))),
				_n(float(sample.get("lateral_velocity_mps", 0.0))),
				_n(float(sample.get("yaw_rate_rad_s", 0.0))), _n(power), _n(max_power_w),
				_n(float(debug.get("roll_degrees", 0.0))), _n(float(debug.get("pitch_degrees", 0.0))),
				_n(float(debug.get("buoyancy_total_n", 0.0))),
			]))
		previous_speed = speed
	if max_power_w > 2.0:
		_failures.append("%s hydrodynamic power became positive (%.3f W), beyond the 2 W numerical tolerance." % [label, max_power_w])
	_run_count += 1
	print("[S1-C5d][decel] %s initial=%.3f kn · final=%.5f kn · max hydro power=%.3f W" % [label, local_velocity.length() * KNOTS_PER_MPS, previous_speed, max_power_w])


func _run_static_buoyancy_check() -> void:
	if not await _configure_lab(0.0, 270.0, 0.0, 0.0, {"linear_damp_mode": 1, "linear_damp": 0.0}):
		return
	var initial_position := _boat.global_position
	var initial_heading := float(_boat.call("get_s1_c4_diagnostic_snapshot").get("heading_degrees", 0.0))
	for _tick in range(60 * SIMULATION_HZ):
		await physics_frame
	var sample: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
	var debug: Dictionary = _boat.call("get_debug_snapshot")
	var height_delta := _boat.global_position.y - initial_position.y
	var row := _csv(["zero_wind_still_water", 60.0, _n(height_delta), _n(float(sample.get("roll_degrees", 0.0))), _n(float(debug.get("pitch_degrees", 0.0))), _n(float(debug.get("buoyancy_total_n", 0.0))), _n(float(sample.get("heading_degrees", 0.0)) - initial_heading), _n(float(debug.get("total_physics_calculation_average_usec", 0))), _n(float(debug.get("total_physics_calculation_p95_usec", 0))), "", "", "", "", "", "", "", "", "", ""])
	_dynamic_rows.append(row)
	if absf(height_delta) > 0.25 or absf(float(sample.get("roll_degrees", 0.0))) > 5.0:
		_failures.append("Still-water buoyancy drifted with REPLACE+0: heave %.3f m, roll %.3f°." % [height_delta, float(sample.get("roll_degrees", 0.0))])
	_run_count += 1


func _run_dynamic_wave_check() -> void:
	var variants := [
		{"name": "historical_combine_0_12", "mode": 0, "damp": 0.12},
		{"name": "replace_0", "mode": 1, "damp": 0.0},
	]
	for variant in variants:
		var overrides := {"linear_damp_mode": int(variant["mode"]), "linear_damp": float(variant["damp"])}
		if not await _configure_lab(8.0, 270.0, 50.0, 0.0, overrides):
			return
		var sampler := _lab.get_node_or_null("WaveSampler") as WaveSampler
		if sampler == null:
			_failures.append("Normal-wave damping check could not resolve WaveSampler.")
			return
		sampler.wave_time_seconds = 0.0
		sampler.set_process(true)
		sampler.set_physics_process(true)
		_boat.call("set_dynamic_waves_enabled", true)
		_boat.call("reset_performance_history")
		var max_speed := 0.0
		var max_abs_roll := 0.0
		var max_abs_pitch := 0.0
		var max_abs_heave := 0.0
		var initial_y := _boat.global_position.y
		for tick in range(1, 60 * SIMULATION_HZ + 1):
			await physics_frame
			var sample: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
			var debug: Dictionary = _boat.call("get_debug_snapshot")
			max_speed = maxf(max_speed, float(sample.get("sog_mps", 0.0)))
			max_abs_roll = maxf(max_abs_roll, absf(float(sample.get("roll_degrees", 0.0))))
			max_abs_pitch = maxf(max_abs_pitch, absf(float(debug.get("pitch_degrees", 0.0))))
			max_abs_heave = maxf(max_abs_heave, absf(_boat.global_position.y - initial_y))
		if max_speed > 20.0 or max_abs_roll > 85.0 or max_abs_pitch > 85.0:
			_failures.append("%s normal-wave run exceeded safety envelope: speed %.3f m/s roll %.1f° pitch %.1f°." % [variant["name"], max_speed, max_abs_roll, max_abs_pitch])
		var final_sample: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
		var final_debug: Dictionary = _boat.call("get_debug_snapshot")
		_dynamic_rows.append(_csv([
			"%s_normal_waves_8ms_crosswind" % variant["name"], 60.0, _n(max_abs_heave), _n(max_abs_roll), _n(max_abs_pitch),
			_n(float(final_debug.get("buoyancy_total_n", 0.0))), _n(float(final_sample.get("heading_degrees", 0.0))),
			int(final_debug.get("total_physics_calculation_average_usec", 0)), int(final_debug.get("total_physics_calculation_p95_usec", 0)),
			_n(float(final_sample.get("sog_mps", 0.0)) * KNOTS_PER_MPS), _n(float(final_sample.get("longitudinal_velocity_mps", 0.0))),
			_n(float(final_sample.get("lateral_velocity_mps", 0.0))), _n(max_speed), _n(max_abs_roll), _n(max_abs_pitch),
			int(final_debug.get("wave_query_count_per_tick", 0)), int(final_debug.get("wind_query_count_per_tick", 0)),
			int(final_debug.get("wave_sample_average_usec", 0)), int(final_debug.get("wave_sample_p95_usec", 0)),
		]))
		if int(final_debug.get("wave_query_count_per_tick", 0)) != 4 or int(final_debug.get("wind_query_count_per_tick", 0)) != 1:
			_failures.append("%s dynamic-wave test changed the existing sampling budget (waves=%d, wind=%d)." % [variant["name"], int(final_debug.get("wave_query_count_per_tick", 0)), int(final_debug.get("wind_query_count_per_tick", 0))])
		_run_count += 1
		print("[S1-C5d][waves] %s 60s SOG=%.3f kn · max speed=%.3f m/s · roll/pitch=%.1f°/%.1f° · queries=%d+%d · physics avg/P95=%d/%d μs" % [
			variant["name"], float(final_sample.get("sog_mps", 0.0)) * KNOTS_PER_MPS, max_speed, max_abs_roll, max_abs_pitch,
			int(final_debug.get("wave_query_count_per_tick", 0)), int(final_debug.get("wind_query_count_per_tick", 0)),
			int(final_debug.get("total_physics_calculation_average_usec", 0)), int(final_debug.get("total_physics_calculation_p95_usec", 0)),
		])


func _run_wind_matrix() -> void:
	_matrix_case_count = WIND_SPEEDS_MPS.size() * RELATIVE_WIND_FROM_DEGREES.size()
	for wind_speed in WIND_SPEEDS_MPS:
		for relative_from in RELATIVE_WIND_FROM_DEGREES:
			_matrix_case_index += 1
			var absolute_from := fposmod(relative_from, 360.0)
			var abs_angle := absf(relative_from)
			var trim_magnitude := float(WIND_TRIMS_DEGREES[abs_angle])
			var sail_degrees := -signf(relative_from) * trim_magnitude
			if not await _configure_lab(wind_speed, absolute_from, sail_degrees, 0.0, {"linear_damp_mode": 1, "linear_damp": 0.0}):
				return
			await _run_matrix_case(wind_speed, relative_from, absolute_from, sail_degrees)


func _run_matrix_case(wind_speed: float, relative_from: float, absolute_from: float, sail_degrees: float) -> void:
	var initial_forward := -_boat.global_basis.z
	var initial_position := _boat.global_position
	var previous_heading := float(_boat.call("get_s1_c4_diagnostic_snapshot").get("heading_degrees", 0.0))
	var unwrapped_heading := previous_heading
	var headings_at := {}
	var checkpoints := {}
	var prior_vlong := 0.0
	var max_yaw := 0.0
	for tick in range(0, 120 * SIMULATION_HZ + 1):
		if tick > 0:
			await physics_frame
		var sample: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
		var debug: Dictionary = _boat.call("get_debug_snapshot")
		var heading := float(sample.get("heading_degrees", 0.0))
		if tick > 0:
			unwrapped_heading += wrapf(heading - previous_heading, -180.0, 180.0)
		previous_heading = heading
		var yaw_deg := absf(rad_to_deg(float(sample.get("yaw_rate_rad_s", 0.0))))
		max_yaw = maxf(max_yaw, yaw_deg)
		var time_s := float(tick) / float(SIMULATION_HZ)
		if tick in [30 * SIMULATION_HZ, 60 * SIMULATION_HZ, 120 * SIMULATION_HZ]:
			var sog_kn := float(sample.get("sog_mps", 0.0)) * KNOTS_PER_MPS
			var vlong := float(sample.get("longitudinal_velocity_mps", 0.0))
			var vlat := float(sample.get("lateral_velocity_mps", 0.0))
			var position: Vector3 = sample.get("position_world_m", _boat.global_position)
			var perf: Dictionary = debug
			var row_data := {
				"time": time_s, "heading": heading, "unwrapped": unwrapped_heading,
				"sog": sog_kn, "vlong": vlong, "vlat": vlat,
				"heel": float(sample.get("roll_degrees", 0.0)), "yaw": yaw_deg,
				"sideslip": rad_to_deg(atan2(vlat, maxf(absf(vlong), 0.05))),
				"disp": (position - initial_position).dot(initial_forward),
				"apparent": float(sample.get("apparent_wind_from_angle_degrees", 0.0)),
				"luff": float(sample.get("sail_luffing_scale", 0.0)),
				"sail": rad_to_deg(float(sample.get("actual_sail_angle_rad", 0.0))),
				"avg": int(perf.get("total_physics_calculation_average_usec", 0)),
				"p95": int(perf.get("total_physics_calculation_p95_usec", 0)),
			}
			checkpoints[time_s] = row_data
			headings_at[time_s] = unwrapped_heading
			prior_vlong = vlong
		if tick > 0 and tick % (30 * SIMULATION_HZ) == 0:
			print("[S1-C5d][matrix %d/%d] wind=%.0f relative=%+.0f trim=%+.0f t=%ds SOG=%.2f Vlong=%.2f HDG=%.1f°" % [
				_matrix_case_index, _matrix_case_count, wind_speed, relative_from, sail_degrees, int(time_s),
				float(sample.get("sog_mps", 0.0)) * KNOTS_PER_MPS, float(sample.get("longitudinal_velocity_mps", 0.0)), heading,
			])
	var s30: Dictionary = checkpoints.get(30.0, {})
	var s60: Dictionary = checkpoints.get(60.0, {})
	var s120: Dictionary = checkpoints.get(120.0, {})
	var speed_delta := absf(float(s120.get("sog", 0.0)) - float(s60.get("sog", 0.0)))
	var heading_delta := absf(float(s120.get("unwrapped", 0.0)) - float(s60.get("unwrapped", 0.0)))
	var course_status := "steady_course" if speed_delta < 0.10 and heading_delta < 10.0 else ("steady_speed_turning" if speed_delta < 0.10 else "not_steady")
	for time_s in [30.0, 60.0, 120.0]:
		var data: Dictionary = checkpoints.get(time_s, {})
		_matrix_rows.append(_csv([
			_n(wind_speed), _n(relative_from), _n(absolute_from), _n(sail_degrees), _n(time_s),
			_n(float(data.get("heading", 0.0))), _n(float(data.get("unwrapped", 0.0))), _n(float(data.get("sog", 0.0))),
			_n(float(data.get("vlong", 0.0))), _n(float(data.get("vlat", 0.0))), _n(float(data.get("sideslip", 0.0))),
			_n(float(data.get("heel", 0.0))), _n(float(data.get("yaw", 0.0))), _n(max_yaw), _n(float(data.get("disp", 0.0))),
			_n(float(data.get("apparent", 0.0))), _n(float(data.get("luff", 0.0))), _n(float(data.get("sail", 0.0))),
			_n(speed_delta), _n(heading_delta), course_status, int(data.get("avg", 0)), int(data.get("p95", 0)),
		]))
	_run_count += 1


func _write_c5d_outputs() -> void:
	if not _damping_rows.is_empty():
		_write_c5d_csv("damping_comparison.csv", "case,mode_enum,mode,body_linear_damp,project_default_linear_damp,effective_linear_damp_per_s,sim_time_s,heading_deg,sog_knots,longitudinal_speed_mps,lateral_speed_mps,sideslip_proxy_deg,heel_deg,yaw_rate_abs_deg_s,forward_displacement_initial_axis_m,sail_forward_n,hull_forward_n,keel_forward_n,rudder_forward_n,explicit_forward_sum_n,rigidbody_damping_estimate_n,known_force_plus_damping_n,longitudinal_acceleration_m_s2,max_abs_yaw_rate_deg_s,physics_avg_usec,physics_p95_usec\n" + "\n".join(_damping_rows) + "\n")
	if not _deceleration_rows.is_empty():
		_write_c5d_csv("natural_deceleration.csv", "case,initial_speed_knots,sim_time_s,sog_knots,longitudinal_speed_mps,lateral_speed_mps,yaw_rate_rad_s,hydrodynamic_power_w,max_positive_hydrodynamic_power_to_date_w,heel_deg,pitch_deg,total_buoyancy_n\n" + "\n".join(_deceleration_rows) + "\n")
	if not _matrix_rows.is_empty():
		_write_c5d_csv("wind_speed_direction_matrix.csv", "wind_speed_mps,relative_wind_from_deg,absolute_wind_from_deg,representative_sail_angle_deg,sim_time_s,heading_deg,unwrapped_heading_deg,sog_knots,longitudinal_speed_mps,lateral_speed_mps,sideslip_proxy_deg,heel_deg,yaw_rate_abs_deg_s,max_abs_yaw_rate_deg_s,forward_displacement_initial_axis_m,apparent_wind_from_relative_deg,luffing_scale,actual_sail_angle_deg,sog_delta_60_to_120_kn,heading_drift_60_to_120_deg,steady_status,physics_avg_usec,physics_p95_usec\n" + "\n".join(_matrix_rows) + "\n")
	if not _dynamic_rows.is_empty():
		_write_c5d_csv("damping_stability_checks.csv", "case,duration_s,heave_delta_m,roll_deg,pitch_deg,buoyancy_n,heading_delta_deg,physics_avg_usec,physics_p95_usec,sog_knots,longitudinal_speed_mps,lateral_speed_mps,max_speed_mps,max_abs_roll_deg,max_abs_pitch_deg,wave_queries_per_tick,wind_queries_per_tick,wave_sample_avg_usec,wave_sample_p95_usec\n" + "\n".join(_dynamic_rows) + "\n")


func _write_c5d_csv(filename: String, content: String) -> void:
	var path := ProjectSettings.globalize_path(C5D_DATA_DIR.path_join(filename))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_failures.append("Could not write %s: %s" % [path, error_string(FileAccess.get_open_error())])
		return
	file.store_string(content)
	file.close()

