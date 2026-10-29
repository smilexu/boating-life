extends SceneTree
## Runs isolated P2.2 physical experiments by reusing the P1/P2 rigid-body runner.

const LAB_SCENE := preload("res://scenes/SailboatLab.tscn")
const BODY_PROFILE_PATH := "res://resources/sailing/sailboat_lab_profile.tres"
const TEST_PROFILE_PATH := "res://resources/sailing/polar_test_profile.tres"
const EXPERIMENT_PROFILE_PATH := "res://resources/sailing/polar_p22_experiment_profile.tres"
const ENGINE_PHYSICS_HZ := 480
const ACCELERATION_SCALE := 8.0
const P22_ROOT := "res://docs/sailing/polar_p22"

var _lab: Node3D
var _runner: PolarTestRunner
var _profile: Resource
var _root_directory := ""
var _all_results: Array[Dictionary] = []
var _run_index: Array[Dictionary] = []
var _base_area_rows: Array[Dictionary] = []
var _errors: Array[String] = []
var _old_physics_hz := 60
var _old_time_scale := 1.0
var _progress_last_usec := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_profile = load(EXPERIMENT_PROFILE_PATH)
	if _profile == null:
		_errors.append("P2.2 experiment profile failed to load")
		_finish(2)
		return
	var mode := "all"
	for arg in OS.get_cmdline_user_args():
		if str(arg).begins_with("--phase="):
			mode = str(arg).trim_prefix("--phase=")
	if mode not in ["all", "smoke"]:
		_errors.append("Only --phase=all or --phase=smoke is supported; run area/trim scans only after the smoke gate")
		_finish(2)
		return
	_root_directory = _create_run_root()
	_old_physics_hz = Engine.physics_ticks_per_second
	_old_time_scale = Engine.time_scale
	Engine.physics_ticks_per_second = ENGINE_PHYSICS_HZ
	Engine.time_scale = ACCELERATION_SCALE
	print("P2.2 run root: %s" % ProjectSettings.globalize_path(_root_directory))
	print("Fixed step=%.8f s; engine=%d Hz × time_scale %.1f; wind seed=%d; thresholds=60/30/30/300 s" % [
		float(_profile.get("physics_step_seconds")), ENGINE_PHYSICS_HZ, ACCELERATION_SCALE, int(_profile.get("fixed_wind_seed")),
	])
	var smoke_ok := await _run_smoke_stage()
	if not smoke_ok or mode == "smoke":
		_write_progress("smoke_complete" if smoke_ok else "smoke_gate_failed")
		_finish(0 if smoke_ok else 1)
		return
	for total in _profile.get("total_sail_area_candidates_m2"):
		var area_name := _area_name(float(total))
		var rows := await _run_area_scheme(float(total), area_name)
		if rows.is_empty():
			_errors.append("Area group produced no result rows: %s" % area_name)
			_write_progress("area_group_failed")
			_finish(1)
			return
		if area_name == "BASE":
			_base_area_rows = rows.duplicate(true)
		if not _check_mirror_quality(rows, area_name):
			_errors.append("%s left/right mirror check failed; stopping area comparisons" % area_name)
			_write_progress("mirror_gate_failed")
			_finish(1)
			return
	var trim_rows := await _run_trim_sensitivity()
	if trim_rows.is_empty():
		_errors.append("AUTO trim sensitivity produced no result rows")
		_write_progress("trim_group_failed")
		_finish(1)
		return
	_write_progress("complete")
	_finish(0 if _errors.is_empty() else 1)


func _run_smoke_stage() -> bool:
	var smoke_case := [_case(12.0, -90.0, "smoke_base_12_90_port", "smoke_base", "telemetry_off", "BASE · 12 kn / 90° · Port")]
	var base_off := await _run_group("smoke", "BASE_telemetry_off", 15.32025, 10.16025, 5.16, smoke_case, false)
	var base_on := await _run_group("smoke", "BASE_telemetry_on", 15.32025, 10.16025, 5.16, [_case(12.0, -90.0, "smoke_base_12_90_port", "smoke_base", "telemetry_on", "BASE · 12 kn / 90° · Port")], true)
	if base_off.is_empty() or base_on.is_empty():
		return false
	var off := base_off[0]
	var on := base_on[0]
	var off_sog := float(off.get("mean_sog_kn", -1.0))
	var on_sog := float(on.get("mean_sog_kn", -1.0))
	var status_match := str(off.get("status", "")) == str(on.get("status", ""))
	var sog_delta := absf(off_sog - on_sog)
	var on_telemetry: Dictionary = on.get("extended_telemetry", {})
	var telemetry_valid := bool(on_telemetry.get("telemetry_finite", false))
	var query_counts_ok := is_equal_approx(float(on_telemetry.get("mean_wind_query_count_per_tick", -1.0)), 1.0) and is_equal_approx(float(on_telemetry.get("mean_wave_query_count_per_tick", -1.0)), 4.0)
	print("P2.2 telemetry smoke · status %s / %s · SOG Δ %.5f kn · fields finite %s · queries 1/4 %s" % [
		str(off.get("status", "")), str(on.get("status", "")), sog_delta, str(telemetry_valid), str(query_counts_ok),
	])
	if not status_match or sog_delta > 0.02 or not telemetry_valid or not query_counts_ok:
		_errors.append("BASE telemetry gate failed: physical outcome changed, invalid fields, or sampling budget differed")
		return false
	var sa30_cases: Array[Dictionary] = []
	for angle in [50.0, 70.0, 90.0]:
		sa30_cases.append(_case(12.0, -angle, "smoke_sa30_12_%02d_port" % int(angle), "smoke_sa30", "area_30", "SA30 · 12 kn / %d° · Port" % int(angle)))
	var sa30 := _area_split(30.0)
	var sa30_rows := await _run_group("smoke", "SA30_smoke", 30.0, float(sa30["main_sail_area_m2"]), float(sa30["headsail_area_m2"]), sa30_cases, true)
	if sa30_rows.size() != sa30_cases.size():
		return false
	for row in sa30_rows:
		var telemetry: Dictionary = row.get("extended_telemetry", {})
		if str(row.get("status", "")) == "INVALID" or not bool(telemetry.get("telemetry_finite", false)):
			_errors.append("SA30 smoke contained an INVALID result or non-finite telemetry")
			return false
		var main_expected := float(sa30["main_sail_area_m2"])
		var jib_expected := float(sa30["headsail_area_m2"])
		if absf(float(telemetry.get("mean_main_area_m2", -1.0)) - main_expected) > 0.001 or absf(float(telemetry.get("mean_jib_area_m2", -1.0)) - jib_expected) > 0.001:
			_errors.append("SA30 copied profile did not reach the physics body with expected area values")
			return false
	return true


func _run_area_scheme(total: float, label: String) -> Array[Dictionary]:
	var split := _area_split(total)
	var cases: Array[Dictionary] = []
	for tws in _profile.get("area_test_wind_speeds_kn"):
		for angle in _profile.get("area_test_twa_degrees"):
			if float(tws) == 8.0 and float(angle) == 50.0:
				continue
			for tack in ["PORT", "STARBOARD"]:
				var signed := -float(angle) if tack == "PORT" else float(angle)
				cases.append(_case(float(tws), signed, "%s_%s_%02d_%s" % [label.to_lower(), str(int(tws)), int(angle), tack.to_lower()], label, "area_total_%s_m2" % str(total), "%s · %.0f kn / %d° · %s" % [label, float(tws), int(angle), tack]))
	return await _run_group("area", label, total, float(split["main_sail_area_m2"]), float(split["headsail_area_m2"]), cases, true)


func _run_trim_sensitivity() -> Array[Dictionary]:
	var baseline: Dictionary = {}
	for row in _base_area_rows:
		if float(row.get("target_tws_kn", 0.0)) == float(_profile.get("trim_test_wind_speed_kn")) and absf(float(row.get("target_twa_deg", 0.0))) in _profile.get("trim_test_twa_degrees"):
			var key := "%s_%d" % [str(row.get("tack", "")), int(absf(float(row.get("target_twa_deg", 0.0))))]
			baseline[key] = row
	var cases: Array[Dictionary] = []
	var base_profile: Resource = load(BODY_PROFILE_PATH)
	var main_limit := rad_to_deg(float(base_profile.get("max_sail_angle_rad")))
	var jib_limit := rad_to_deg(float(base_profile.get("max_headsail_angle_rad")))
	for angle_value in _profile.get("trim_test_twa_degrees"):
		var angle := float(angle_value)
		for tack in ["PORT", "STARBOARD"]:
			var signed := -angle if tack == "PORT" else angle
			var base_key := "%s_%d" % [tack, int(angle)]
			if not baseline.has(base_key):
				_errors.append("Missing BASE AUTO calibration row for trim sensitivity: %s" % base_key)
				continue
			var base_row: Dictionary = baseline[base_key]
			var ext: Dictionary = base_row.get("extended_telemetry", {})
			var main_base := absf(float(ext.get("mean_main_target_angle_deg", base_row.get("main_sail_deg", 0.0))))
			var jib_base := absf(float(ext.get("mean_jib_target_angle_deg", base_row.get("headsail_deg", 0.0))))
			for offset in _profile.get("trim_offsets_degrees"):
				var requested := maxf(0.0, main_base + float(offset))
				var case := _case(float(_profile.get("trim_test_wind_speed_kn")), signed, "trim_main_%+03d_%s_%02d" % [int(offset), tack.to_lower(), int(angle)], "AUTO_TRIM_SENSITIVITY", "main_%+g_deg" % float(offset), "主帆 %+g° / %s / TWA %d°" % [float(offset), tack, int(angle)])
				case["auto_sail_trim_enabled"] = false
				case["main_trim_magnitude_deg"] = requested
				case["headsail_trim_magnitude_deg"] = jib_base
				case["main_trim_offset_degrees"] = float(offset)
				case["main_trim_limit_clipped"] = requested > main_limit
				case["reference_main_target_magnitude_deg"] = main_base
				case["reference_jib_target_magnitude_deg"] = jib_base
				cases.append(case)
				requested = maxf(0.0, jib_base + float(offset))
				case = _case(float(_profile.get("trim_test_wind_speed_kn")), signed, "trim_jib_%+03d_%s_%02d" % [int(offset), tack.to_lower(), int(angle)], "AUTO_TRIM_SENSITIVITY", "jib_%+g_deg" % float(offset), "Jib %+g° / %s / TWA %d°" % [float(offset), tack, int(angle)])
				case["auto_sail_trim_enabled"] = false
				case["main_trim_magnitude_deg"] = main_base
				case["headsail_trim_magnitude_deg"] = requested
				case["headsail_trim_offset_degrees"] = float(offset)
				case["headsail_trim_limit_clipped"] = requested > jib_limit
				case["reference_main_target_magnitude_deg"] = main_base
				case["reference_jib_target_magnitude_deg"] = jib_base
				cases.append(case)
	return await _run_group("trim", "BASE_trim_sensitivity", 15.32025, float(_profile.get("base_main_sail_area_m2")), float(_profile.get("base_headsail_area_m2")), cases, true)


func _run_group(phase: String, label: String, total: float, main_area: float, jib_area: float, cases: Array, telemetry: bool) -> Array[Dictionary]:
	_lab = LAB_SCENE.instantiate() as Node3D
	var boat := _lab.get_node_or_null("SailboatBody") as RigidBody3D
	_runner = _lab.get_node_or_null("PolarTestRunner") as PolarTestRunner
	if boat == null or _runner == null:
		_errors.append("SailboatLab instance missing body or PolarTestRunner")
		_lab.free()
		return []
	var body_profile := (load(BODY_PROFILE_PATH) as Resource).duplicate(true)
	body_profile.set("main_sail_area_m2", main_area)
	body_profile.set("headsail_area_m2", jib_area)
	boat.set("profile", body_profile)
	boat.set("p22_extended_telemetry_enabled", telemetry)
	_runner.profile = (load(TEST_PROFILE_PATH) as Resource).duplicate(true)
	root.add_child(_lab)
	await process_frame
	var started := _runner.start_new_batch({
		"include_extended_telemetry": telemetry,
		"explicit_cases": cases,
	})
	if not started:
		_errors.append("Could not start %s/%s batch: %s" % [phase, label, str(_runner.get_status_snapshot().get("status", "unknown"))])
		_lab.queue_free()
		await process_frame
		return []
	print("P2.2 batch started · %s/%s · total %.5f m² · main %.5f m² · Jib %.5f m² · cases %d · telemetry %s" % [phase, label, total, main_area, jib_area, cases.size(), str(telemetry)])
	await _wait_for_batch(phase, label)
	var state: Dictionary = _runner.get_status_snapshot()
	var checkpoint_path := str(state.get("output_path", ""))
	var checkpoint: Dictionary = {}
	if not checkpoint_path.is_empty() and FileAccess.file_exists(checkpoint_path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(checkpoint_path))
		if parsed is Dictionary:
			checkpoint = parsed
	if checkpoint.is_empty():
		_errors.append("Missing or invalid checkpoint after %s/%s" % [phase, label])
		_lab.queue_free()
		await process_frame
		return []
	var rows := _decode_rows(checkpoint.get("results", []))
	var run_id := str(checkpoint.get("test_run_id", ""))
	var copy_path := _copy_run_artifacts(phase, label, run_id, checkpoint, total, main_area, jib_area)
	_run_index.append({"phase": phase, "label": label, "run_id": run_id, "config_hash": checkpoint.get("config_hash", ""), "case_count": rows.size(), "status": state.get("status", ""), "artifact_directory": copy_path})
	for row in rows:
		var enriched := row.duplicate(true)
		enriched["experiment_phase"] = phase
		enriched["experiment_group"] = str(enriched.get("experiment_group", label))
		enriched["configured_total_sail_area_m2"] = total
		enriched["configured_main_sail_area_m2"] = main_area
		enriched["configured_headsail_area_m2"] = jib_area
		_all_results.append(enriched)
	if int(state.get("completed_count", 0)) != int(state.get("case_count", -1)):
		_errors.append("Batch did not complete all requested cases for %s/%s" % [phase, label])
	_lab.queue_free()
	await process_frame
	return rows


func _wait_for_batch(phase: String, label: String) -> void:
	var previous_case := ""
	while bool(_runner.get_status_snapshot().get("running", false)):
		await process_frame
		var state := _runner.get_status_snapshot()
		var case_id := str(state.get("current_case_id", ""))
		var now := Time.get_ticks_usec()
		if case_id != previous_case or now - _progress_last_usec > 15000000:
			previous_case = case_id
			_progress_last_usec = now
			print("P2.2 progress · %s/%s · %d/%d · sim %.0f s · %s · %.2f kn · TWA %+.1f°" % [
				phase, label, int(state.get("completed_count", 0)), int(state.get("case_count", 0)), float(state.get("simulation_seconds", 0.0)),
				case_id, float(state.get("sog_kn", 0.0)), float(state.get("measured_twa_deg", 0.0)),
			])


func _case(tws: float, twa: float, case_id: String, group_name: String, variable: String, label: String) -> Dictionary:
	var tack := "PORT" if twa < 0.0 else "STARBOARD" if twa > 0.0 else "SYMMETRIC"
	return {
		"target_tws_kn": tws,
		"target_twa_deg": twa,
		"tack": tack,
		"case_id": case_id,
		"experiment_group": group_name,
		"experiment_variable": variable,
		"experiment_label": label,
		"auto_sail_trim_enabled": true,
	}


func _area_split(total: float) -> Dictionary:
	var scale := total / (float(_profile.get("base_main_sail_area_m2")) + float(_profile.get("base_headsail_area_m2")))
	return {
		"main_sail_area_m2": float(_profile.get("base_main_sail_area_m2")) * scale,
		"headsail_area_m2": float(_profile.get("base_headsail_area_m2")) * scale,
	}


func _area_name(total: float) -> String:
	if is_equal_approx(total, 15.32025):
		return "BASE"
	return "SA%d" % int(round(total))


func _check_mirror_quality(rows: Array[Dictionary], label: String) -> bool:
	var by_key: Dictionary = {}
	for row in rows:
		var key := "%.0f_%.0f" % [float(row.get("target_tws_kn", 0.0)), absf(float(row.get("target_twa_deg", 0.0)))]
		if not by_key.has(key):
			by_key[key] = {}
		by_key[key][str(row.get("tack", ""))] = row
	var passed := true
	for key in by_key:
		var pair: Dictionary = by_key[key]
		if not pair.has("PORT") or not pair.has("STARBOARD"):
			continue
		var port: Dictionary = pair["PORT"]
		var starboard: Dictionary = pair["STARBOARD"]
		var status_match := str(port.get("status", "")) == str(starboard.get("status", ""))
		var sog_delta := absf(float(port.get("mean_sog_kn", 0.0)) - float(starboard.get("mean_sog_kn", 0.0)))
		var yaw_mirror_delta := absf(float(port.get("extended_telemetry", {}).get("mean_measured_yaw_torque_sum_nm", 0.0)) + float(starboard.get("extended_telemetry", {}).get("mean_measured_yaw_torque_sum_nm", 0.0)))
		if not status_match or sog_delta > 0.08 or yaw_mirror_delta > 50.0:
			passed = false
			print("P2.2 mirror warning · %s %s · statuses %s/%s · ΔSOG %.3f kn · yaw mirror residual %.1f N·m" % [label, key, str(port.get("status", "")), str(starboard.get("status", "")), sog_delta, yaw_mirror_delta])
	return passed


func _decode_rows(value: Variant) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	if value is Array:
		for item in value:
			if item is Dictionary:
				rows.append(item)
	return rows


func _copy_run_artifacts(phase: String, label: String, run_id: String, checkpoint: Dictionary, total: float, main_area: float, jib_area: float) -> String:
	var source_directory := str(checkpoint.get("run_directory", ""))
	var destination := _root_directory.path_join("runs/%s/%s/%s" % [phase, label, run_id])
	var destination_abs := ProjectSettings.globalize_path(destination)
	DirAccess.make_dir_recursive_absolute(destination_abs)
	for filename in ["polar_results.csv", "polar_results.json", "polar_summary.json", "polar_checkpoint.json"]:
		var source := source_directory.path_join(filename)
		if not FileAccess.file_exists(source):
			continue
		var target_abs := destination_abs.path_join(filename)
		var file := FileAccess.open(target_abs, FileAccess.WRITE)
		if file == null:
			_errors.append("Could not copy run artifact: %s" % target_abs)
			continue
		file.store_string(FileAccess.get_file_as_string(source))
	var manifest := {
		"phase": phase,
		"group": label,
		"test_run_id": run_id,
		"boat_scene_path": str(checkpoint.get("boat_scene_path", "")),
		"boat_config_hash": str(checkpoint.get("boat_config_hash", "")),
		"configured_total_sail_area_m2": total,
		"configured_main_sail_area_m2": main_area,
		"configured_headsail_area_m2": jib_area,
		"config": checkpoint.get("config", {}),
		"case_count": _decode_rows(checkpoint.get("results", [])).size(),
	}
	_write_json_absolute(destination_abs.path_join("manifest.json"), manifest)
	return destination


func _create_run_root() -> String:
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-").replace("T", "_").replace(" ", "_")
	var path := P22_ROOT.path_join("p22_" + stamp + "_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path))
	return path


func _write_progress(status: String) -> void:
	_write_json_absolute(ProjectSettings.globalize_path(_root_directory.path_join("p22_progress.json")), {
		"status": status,
		"completed_runs": _run_index,
		"errors": _errors,
		"completed_results": _all_results.size(),
	})


func _write_json_absolute(path: String, value: Variant) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_errors.append("Failed to write JSON artifact: %s" % path)
		return
	file.store_string(JSON.stringify(value, "\t") + "\n")


func _finish(exit_code: int) -> void:
	Engine.physics_ticks_per_second = _old_physics_hz
	Engine.time_scale = _old_time_scale
	if not _root_directory.is_empty():
		_write_json_absolute(ProjectSettings.globalize_path(_root_directory.path_join("run_index.json")), {"runs": _run_index, "errors": _errors})
		_write_json_absolute(ProjectSettings.globalize_path(_root_directory.path_join("raw_results.json")), {"results": _all_results})
		print("P2.2 output directory: %s" % ProjectSettings.globalize_path(_root_directory))
	for error in _errors:
		push_error("[polar p2.2] " + error)
	quit(exit_code)
