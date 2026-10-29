extends SceneTree
## Small real-physics P1 validation only; this does not execute the full Polar grid.

const LAB_SCENE := preload("res://scenes/SailboatLab.tscn")
const EXPORTER := preload("res://scripts/polar_data_exporter.gd")
const SIM_HZ := 60
const FAST_SCALE := 8.0

var _lab: Node3D
var _runner: PolarTestRunner
var _boat: Node3D
var _failures: Array[String] = []
var _runs := 0
var _old_physics_hz := 60
var _old_time_scale := 1.0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_old_physics_hz = Engine.physics_ticks_per_second
	_old_time_scale = Engine.time_scale
	Engine.physics_ticks_per_second = int(float(SIM_HZ) * FAST_SCALE)
	Engine.time_scale = FAST_SCALE
	_lab = LAB_SCENE.instantiate() as Node3D
	root.add_child(_lab)
	await process_frame
	_runner = _lab.get_node("PolarTestRunner") as PolarTestRunner
	_boat = _lab.get_node("SailboatBody")
	if _runner == null or _boat == null:
		_failures.append("SailboatLab did not instantiate the runner and real boat.")
	else:
		await _validate_fixed_wind_and_mirrors()
		await _validate_no_go()
		await _validate_repeatability()
		await _validate_interruption_resume()
	Engine.physics_ticks_per_second = _old_physics_hz
	Engine.time_scale = _old_time_scale
	if _lab != null and is_instance_valid(_lab):
		_lab.queue_free()
	if _failures.is_empty():
		print("Polar P1 real-physics checks passed: %d batches; no full Polar sweep was run." % _runs)
		quit(0)
	else:
		for failure in _failures:
			push_error("[polar p1 integration] " + failure)
		quit(1)


func _prepare_short_profile() -> void:
	var test_profile: Resource = _runner.profile
	test_profile.minimum_warmup_seconds = 3.0
	test_profile.stability_window_seconds = 3.0
	test_profile.sample_window_seconds = 3.0
	test_profile.case_timeout_seconds = 10.0
	test_profile.maximum_speed_standard_deviation_mps = 0.8
	test_profile.maximum_speed_half_window_delta_mps = 0.8


func _validate_fixed_wind_and_mirrors() -> void:
	_prepare_short_profile()
	var engine_before: Dictionary = _boat.call("get_auxiliary_engine_snapshot")
	var fuel_before := float(engine_before.get("tank", {}).get("remaining_l", 0.0))
	var ok := _runner.start_new_batch(_config([12.0], 90.0, 90.0, true, true))
	_check(ok, "start 12 kn / ±90° real-physics test")
	if not ok:
		return
	await _wait_for_runner()
	_runs += 1
	var checkpoint := _latest_checkpoint()
	var rows: Array = checkpoint.get("results", [])
	_check(rows.size() == 2, "port and starboard 90° cases both exported")
	var by_tack := {}
	for row in rows:
		by_tack[str(row.get("tack", ""))] = row
		_check(str(row.get("status", "")) != "INVALID", "mirror case completed with a classified physical result")
		_check(int(row.get("sample_count", 0)) >= 3, "case contains actual post-initialization physics samples")
		_check(str(row.get("engine_state", "")) == "关闭" or str(row.get("engine_state", "")) == "OFF", "auxiliary engine is stopped for Polar measurement")
		_check(str(row.get("auto_trim_state", "")) == "AUTO", "each measured case records active AUTO Trim state")
		_check(absf(float(row.get("mean_tws_kn", -999.0)) - 12.0) < 0.01, "actual sampled TWS matches configured wind speed")
		_check(is_equal_approx(float(row.get("observed_physics_step_seconds", 0.0)), 1.0 / 60.0), "accelerated smoke run preserves the configured 1/60 s simulated physics step")
		_check(int(row.get("physics_ticks_per_second", 0)) == int(float(SIM_HZ) * FAST_SCALE), "result distinguishes Godot engine tick setting from simulated step cadence")
		_check(is_equal_approx(float(row.get("physics_time_scale", 0.0)), FAST_SCALE), "accelerated smoke run records its time scale")
		_check(is_finite(float(row.get("mean_velocity_world_x_mps", NAN))) and is_finite(float(row.get("mean_velocity_world_z_mps", NAN))), "result preserves world velocity components for independent VMG calculation")
		_check(is_finite(float(row.get("mean_hull_resistance_forward_n", NAN))), "result exports measured hull resistance")
	_check(by_tack.has("PORT") and by_tack.has("STARBOARD"), "tack signs map to separate port and starboard records")
	if by_tack.has("PORT") and by_tack.has("STARBOARD"):
		var port_row: Dictionary = by_tack["PORT"]
		var starboard_row: Dictionary = by_tack["STARBOARD"]
		var port_speed := float(port_row.get("mean_sog_kn", 0.0))
		var starboard_speed := float(starboard_row.get("mean_sog_kn", 0.0))
		var port_heel := float(port_row.get("mean_heel_deg", 0.0))
		var starboard_heel := float(starboard_row.get("mean_heel_deg", 0.0))
		print("[P1 mirror] 12 kn / ±90° · SOG %.3f / %.3f kn · heel %+.2f / %+.2f° · status %s / %s" % [port_speed, starboard_speed, port_heel, starboard_heel, port_row.get("status", ""), starboard_row.get("status", "")])
		_check(is_finite(port_speed) and is_finite(starboard_speed), "both tacks record measured speed")
		if absf(port_heel) >= 0.5 and absf(starboard_heel) >= 0.5:
			_check(port_heel * starboard_heel <= 0.0, "port and starboard heel directions mirror")
	_check(FileAccess.file_exists(_runner.get_last_output_path().get_base_dir().path_join("polar_results.csv")), "CSV results file exported")
	_check(FileAccess.file_exists(_runner.get_last_output_path().get_base_dir().path_join("polar_results.json")), "JSON results file exported")
	var query_debug: Dictionary = _boat.call("get_debug_snapshot")
	_check(int(query_debug.get("wave_query_count_per_tick", -1)) == 4, "static-water Polar mode keeps four live buoyancy sampler queries")
	_check(int(query_debug.get("wind_query_count_per_tick", -1)) == 1, "Polar mode keeps one wind query per physics step")
	var engine_after: Dictionary = _boat.call("get_auxiliary_engine_snapshot")
	var fuel_after := float(engine_after.get("tank", {}).get("remaining_l", 0.0))
	_check(is_equal_approx(fuel_before, fuel_after), "engine-off Polar tests do not consume fuel")
	var wind_before: Vector3 = _lab.get_node("WindField").call("get_wind_at", Vector3.ZERO)
	var wind_after: Vector3 = _lab.get_node("WindField").call("get_wind_at", Vector3.ZERO)
	_check(wind_before.is_equal_approx(wind_after), "fixed wind sample is repeatable at a fixed position/time")


func _validate_no_go() -> void:
	var ok := _runner.start_new_batch(_config([12.0], 20.0, 20.0, true, false))
	_check(ok, "start 12 kn / 20° no-go diagnostic")
	if not ok:
		return
	await _wait_for_runner()
	_runs += 1
	var rows: Array = _latest_checkpoint().get("results", [])
	_check(rows.size() == 1, "no-go diagnostic produced one case row")
	if rows.size() == 1:
		var row: Dictionary = rows[0]
		print("[P1 no-go] 12 kn / TWA %+.0f° · status %s · TWS %.2f kn · TWA measured %+.2f° · Vlong %.3f m/s · rudder %.1f°" % [float(row.get("target_twa_deg", 0.0)), row.get("status", ""), float(row.get("mean_tws_kn", 0.0)), float(row.get("measured_twa_deg", 0.0)), float(row.get("mean_longitudinal_velocity_mps", 0.0)), float(row.get("mean_rudder_deg", 0.0))])
		if str(row.get("status", "")) == "STABLE":
			_check(float(row.get("mean_longitudinal_velocity_mps", 0.0)) > 0.10, "stable near-upwind point requires measured positive bow-forward speed")
		else:
			_check(str(row.get("failure_reason", "")).length() > 0, "non-stable near-upwind point retains a failure reason")
		_check(float(row.get("target_twa_deg", 999.0)) < 0.0, "port tack output preserves signed TWA")


func _validate_repeatability() -> void:
	var mean_speeds: Array[float] = []
	for _run_index in range(3):
		var ok := _runner.start_new_batch(_config([12.0], 90.0, 90.0, true, false))
		_check(ok, "start repeatability run")
		if not ok:
			return
		await _wait_for_runner()
		_runs += 1
		var rows: Array = _latest_checkpoint().get("results", [])
		if rows.size() == 1 and rows[0].get("mean_sog_kn", null) != null:
			mean_speeds.append(float(rows[0]["mean_sog_kn"]))
	_check(mean_speeds.size() == 3, "three repeat runs export numeric real-physics speeds")
	if mean_speeds.size() == 3:
		var spread := maxf(maxf(mean_speeds[0], mean_speeds[1]), mean_speeds[2]) - minf(minf(mean_speeds[0], mean_speeds[1]), mean_speeds[2])
		print("[P1 repeatability] three 12 kn / 90° runs: %s kn; spread=%.4f kn" % [str(mean_speeds), spread])
		_check(spread <= 0.25, "repeat-run mean SOG spread is within the short-run tolerance")


func _validate_interruption_resume() -> void:
	var test_profile: Resource = _runner.profile
	test_profile.minimum_warmup_seconds = 60.0
	test_profile.case_timeout_seconds = 300.0
	var config := _config([12.0], 90.0, 90.0, true, false)
	var ok := _runner.start_new_batch(config)
	_check(ok, "start checkpoint interruption case")
	if not ok:
		return
	for _frame in range(90):
		await physics_frame
	_runner.request_stop()
	await _wait_for_runner()
	_runs += 1
	var interrupted := _latest_checkpoint()
	var interrupted_rows: Array = interrupted.get("results", [])
	_check(interrupted_rows.size() == 1 and str(interrupted_rows[0].get("status", "")) == "INTERRUPTED", "safe stop writes the current case into its checkpoint")
	test_profile.minimum_warmup_seconds = 3.0
	test_profile.case_timeout_seconds = 10.0
	# The config identity intentionally includes stability thresholds; restore them
	# to the same values used when the checkpoint was created before resume.
	# At interruption creation the test profile used warmup=60 and timeout=300.
	test_profile.minimum_warmup_seconds = 60.0
	test_profile.case_timeout_seconds = 300.0
	var rejected := _runner.resume_latest(_config([8.0], 90.0, 90.0, true, false))
	_check(not rejected, "resume rejects a mismatched wind configuration instead of mixing results")
	var resumed := _runner.resume_latest(config)
	_check(resumed, "resume accepts a matching scene/profile/config fingerprint")
	if resumed:
		await _wait_for_runner()
		_runs += 1
		var resumed_rows: Array = _latest_checkpoint().get("results", [])
		_check(resumed_rows.size() == 1 and str(resumed_rows[0].get("status", "")) != "INTERRUPTED", "resume reruns the interrupted case instead of duplicating it")


func _latest_checkpoint() -> Dictionary:
	var path := _runner.get_last_output_path()
	if path.is_empty() or not FileAccess.file_exists(path):
		_failures.append("Could not read Polar checkpoint at %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		_failures.append("Polar checkpoint did not parse as a Dictionary.")
		return {}
	return parsed


func _wait_for_runner() -> void:
	var timeout_frames := 12000
	while bool(_runner.get_status_snapshot().get("running", false)) and timeout_frames > 0:
		await process_frame
		timeout_frames -= 1
	if timeout_frames <= 0:
		_failures.append("Polar runner did not finish within the test harness wait cap.")
		_runner.request_stop()


func _config(speeds: Array[float], twa_start: float, twa_end: float, port: bool, starboard: bool) -> Dictionary:
	return {
		"tws_knots": speeds,
		"twa_start_degrees": twa_start,
		"twa_end_degrees": twa_end,
		"twa_step_degrees": 10.0,
		"include_port_tack": port,
		"include_starboard_tack": starboard,
	}


func _check(condition: bool, label: String) -> void:
	if not condition:
		_failures.append(label)
