extends SceneTree
## Runs an official-config, full-sail Nordic 28 Polar sweep with the existing PolarTestRunner.
## --resume-grid resumes the most recent grid checkpoint without repeating symmetry probes.

const LAB_SCENE := preload("res://scenes/SailboatLab.tscn")
const PROFILE := preload("res://resources/sailing/polar_test_profile.tres")
const EXPECTED_SCENE := "res://scenes/boats/SailingBoat8m.tscn"
const EXPECTED_PHYSICS_PROFILE := "res://resources/sailing/sailboat_lab_profile.tres"
const EXPECTED_VISUAL_PROFILE := "res://resources/sailing/nordic28_visual_rig_profile.tres"
const OUTPUT_ROOT := "res://docs/sailing/polar_nordic28_official"
const CONTEXT_PATH := "user://nordic28_official_polar_context.json"
const PHYSICS_HZ := 480
const TIME_SCALE := 8.0
const KNOTS_PER_MPS := 1.9438444924406
const TWS_GRID := [4.0, 8.0, 12.0, 16.0, 20.0]
const ANGLE_GRID := [0.0, 10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0, 90.0, 100.0, 110.0, 120.0, 130.0, 140.0, 150.0, 160.0, 170.0, 180.0]
const HASHED_PATHS := [
	"res://project.godot",
	"res://scenes/SailboatLab.tscn",
	"res://scenes/Boat.tscn",
	"res://scenes/boats/SailingBoat8m.tscn",
	"res://resources/sailing/sailboat_lab_profile.tres",
	"res://resources/sailing/nordic28_visual_rig_profile.tres",
	"res://resources/sailing/polar_test_profile.tres",
	"res://scripts/sailboat_lab_body.gd",
	"res://scripts/sailboat_aero_math.gd",
	"res://scripts/sailboat_hydrodynamics.gd",
	"res://scripts/sailboat_buoyancy_math.gd",
	"res://scripts/sailboat_auto_sail_trim.gd",
	"res://scripts/wind_field.gd",
	"res://scripts/wave_sampler.gd",
	"res://scripts/polar_test_math.gd",
	"res://scripts/polar_test_profile.gd",
	"res://scripts/polar_stability_detector.gd",
	"res://scripts/polar_data_exporter.gd",
	"res://scripts/polar_test_runner.gd",
	"res://tests/run_nordic28_official_polar.gd",
]

var _lab: Node3D
var _boat: Node3D
var _runner: PolarTestRunner
var _profile: Resource
var _old_physics_hz := 60
var _old_time_scale := 1.0
var _output_dir := ""
var _umbrella_run_id := ""
var _errors: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_old_physics_hz = Engine.physics_ticks_per_second
	_old_time_scale = Engine.time_scale
	Engine.physics_ticks_per_second = PHYSICS_HZ
	Engine.time_scale = TIME_SCALE
	_lab = LAB_SCENE.instantiate() as Node3D
	_boat = _lab.get_node_or_null("SailboatBody") as Node3D
	_runner = _lab.get_node_or_null("PolarTestRunner") as PolarTestRunner
	_profile = _boat.get("profile") as Resource if _boat != null else null
	if _boat == null or _runner == null or _profile == null:
		_finish(2, "SailboatLab is missing the official boat, physics Profile, or PolarTestRunner")
		return
	_runner.profile = (PROFILE as Resource).duplicate(true)
	root.add_child(_lab)
	await process_frame
	await process_frame
	var validation := _validate_official_setup()
	if not bool(validation.get("valid", false)):
		_finish(2, str(validation.get("reason", "official setup validation failed")))
		return
	if OS.get_cmdline_user_args().has("--validate-only"):
		var grid_validation := _validate_grid_construction()
		if not bool(grid_validation.get("valid", false)):
			_finish(2, str(grid_validation.get("reason", "grid construction validation failed")))
			return
		_finish(0, "Official Nordic 28 scene/profile and Polar case grids validated: %s" % JSON.stringify(grid_validation))
		return
	if OS.get_cmdline_user_args().has("--resume-grid"):
		await _resume_grid()
	else:
		await _run_symmetry_then_grid()
	Engine.physics_ticks_per_second = _old_physics_hz
	Engine.time_scale = _old_time_scale
	if _lab != null and is_instance_valid(_lab):
		_lab.queue_free()
	if _errors.is_empty():
		print("Nordic 28 official Polar workflow finished · %s" % _output_dir)
		quit(0)
	else:
		for message in _errors:
			push_error("[Nordic 28 official Polar] " + message)
		quit(1)


func _validate_official_setup() -> Dictionary:
	if _boat.scene_file_path != EXPECTED_SCENE:
		return {"valid": false, "reason": "SailboatLab loaded %s instead of Main's %s" % [_boat.scene_file_path, EXPECTED_SCENE]}
	if _profile.resource_path != EXPECTED_PHYSICS_PROFILE:
		return {"valid": false, "reason": "official physics Profile is %s" % _profile.resource_path}
	var anchors := _boat.get_node_or_null("VisualRoot/VisualRigAnchors") as Node3D
	var visual := anchors.get("visual_profile") as Resource if anchors != null else null
	if visual == null or visual.resource_path != EXPECTED_VISUAL_PROFILE:
		return {"valid": false, "reason": "official Visual Rig Profile is missing or mismatched"}
	var expected := {
		"main_sail_area_m2": 17.66006,
		"headsail_area_m2": 10.323244,
		"hull_longitudinal_drag_linear_n_s_m": 165.0,
		"hull_longitudinal_drag_quadratic_n_s2_m2": 85.0,
		"sail_induced_drag_factor": 0.55,
		"headsail_induced_drag_factor": 0.55,
	}
	for property_name in expected:
		if absf(float(_profile.get(property_name)) - float(expected[property_name])) > 0.0001:
			return {"valid": false, "reason": "official Profile mismatch: %s=%s" % [property_name, str(_profile.get(property_name))]}
	var deployment: Dictionary = _boat.call("get_sail_deployment_snapshot")
	if float(deployment.get("main_current_deployment", 0.0)) < 0.999 or float(deployment.get("jib_current_deployment", 0.0)) < 0.999:
		return {"valid": false, "reason": "boat did not start at 100% deployment"}
	if bool(deployment.get("auto_reef_enabled", true)):
		return {"valid": false, "reason": "AUTO Reef must be off for a full-sail reference Polar"}
	return {"valid": true}


func _run_symmetry_then_grid() -> void:
	_umbrella_run_id = "nordic28_polar_%s_%d" % [Time.get_datetime_string_from_system(true).replace(":", "").replace("-", "").replace("T", "T"), Time.get_ticks_usec() % 1000000]
	_output_dir = OUTPUT_ROOT.path_join(_umbrella_run_id)
	if not _make_output_directory(_output_dir):
		_errors.append("refusing to overwrite or create output folder %s" % _output_dir)
		return
	var symmetry_cases := _build_symmetry_cases()
	var symmetry_state := await _run_batch(symmetry_cases, "symmetry probes")
	if not bool(symmetry_state.get("ok", false)):
		_errors.append(str(symmetry_state.get("reason", "symmetry probe batch did not complete")))
		return
	var symmetry_rows: Array = symmetry_state.get("results", [])
	var symmetry := _evaluate_symmetry(symmetry_rows)
	if not _copy_runner_artifacts(symmetry_state, _output_dir.path_join("symmetry")):
		_errors.append("could not preserve symmetry probe artifacts")
		return
	if not _write_json(_output_dir.path_join("symmetry_validation.json"), symmetry):
		_errors.append("could not write symmetry validation")
		return
	var grid_cases := _build_grid_cases(bool(symmetry.get("passed", false)), symmetry_rows)
	var grid_ui_config := _grid_ui_config(grid_cases)
	var context := {
		"schema_version": 1,
		"umbrella_run_id": _umbrella_run_id,
		"output_dir": _output_dir,
		"symmetry_validation": symmetry,
		"symmetry_rows": symmetry_rows,
		"symmetry_run_id": symmetry_state.get("run_id", ""),
		"symmetry_config_hash": symmetry_state.get("config_hash", ""),
		"mirror_allowed": bool(symmetry.get("passed", false)),
		"grid_cases": grid_cases,
		"grid_ui_config": grid_ui_config,
		"source_fingerprint": _calculate_source_fingerprint(),
		"updated_at": Time.get_datetime_string_from_system(true),
	}
	if not _write_json(CONTEXT_PATH, context):
		_errors.append("could not persist resumable grid context")
		return
	print("Nordic 28 tack symmetry · %s · mirror=%s · grid cases=%d · output=%s" % [JSON.stringify(symmetry), str(context["mirror_allowed"]), grid_cases.size(), _output_dir])
	var grid_state := await _start_grid(grid_ui_config)
	if not bool(grid_state.get("ok", false)):
		_errors.append(str(grid_state.get("reason", "grid run did not complete")))
		return
	_finalize_run(context, grid_state)


func _resume_grid() -> void:
	var context_result := _read_json(CONTEXT_PATH)
	if not bool(context_result.get("ok", false)):
		_errors.append("resume context is unavailable: %s" % str(context_result.get("reason", "unknown")))
		return
	var context: Dictionary = context_result["data"]
	_output_dir = str(context.get("output_dir", ""))
	_umbrella_run_id = str(context.get("umbrella_run_id", ""))
	if _output_dir.is_empty() or not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(_output_dir)):
		_errors.append("resume output directory does not exist")
		return
	if str(context.get("source_fingerprint", "")) != _calculate_source_fingerprint():
		_errors.append("resume refused: source/config fingerprint changed since the sweep started")
		return
	var ui_config: Dictionary = context.get("grid_ui_config", {})
	var resumed := _runner.resume_latest(ui_config)
	if not resumed:
		_errors.append("Polar Runner rejected the latest checkpoint/configuration; no scan was restarted")
		return
	await _wait_for_runner()
	var checkpoint := _load_checkpoint()
	if checkpoint.is_empty():
		_errors.append("resumed grid checkpoint is missing")
		return
	var grid_state := {"ok": true, "checkpoint": checkpoint, "results": checkpoint.get("results", []), "run_id": checkpoint.get("test_run_id", ""), "config_hash": checkpoint.get("config_hash", ""), "batch_name": "grid_resumed"}
	_finalize_run(context, grid_state)


func _start_grid(ui_config: Dictionary) -> Dictionary:
	if not _runner.start_new_batch(ui_config):
		return {"ok": false, "reason": "Polar Runner refused the full grid batch"}
	await _wait_for_runner()
	var checkpoint := _load_checkpoint()
	if checkpoint.is_empty():
		return {"ok": false, "reason": "full grid checkpoint is missing"}
	return {"ok": true, "checkpoint": checkpoint, "results": checkpoint.get("results", []), "run_id": checkpoint.get("test_run_id", ""), "config_hash": checkpoint.get("config_hash", ""), "batch_name": "grid"}


func _run_batch(cases: Array[Dictionary], label: String) -> Dictionary:
	var config := {"explicit_cases": cases, "include_extended_telemetry": false}
	if not _runner.start_new_batch(config):
		return {"ok": false, "reason": "Polar Runner refused %s" % label}
	await _wait_for_runner()
	var checkpoint := _load_checkpoint()
	if checkpoint.is_empty():
		return {"ok": false, "reason": "%s checkpoint is missing" % label}
	return {"ok": true, "checkpoint": checkpoint, "results": checkpoint.get("results", []), "run_id": checkpoint.get("test_run_id", ""), "config_hash": checkpoint.get("config_hash", ""), "batch_name": label}


func _wait_for_runner() -> void:
	var previous_case := -1
	var frame_guard := 0
	while bool(_runner.get_status_snapshot().get("running", false)) and frame_guard < 3000000:
		await process_frame
		frame_guard += 1
		var status: Dictionary = _runner.get_status_snapshot()
		var current_case := int(status.get("case_index", -1))
		if current_case != previous_case and current_case > 0 and current_case % 5 == 0:
			print("Polar progress · %s · %d/%d · sim %.0f s" % [str(status.get("test_run_id", "")), current_case, int(status.get("case_count", 0)), float(status.get("simulation_seconds", 0.0))])
			previous_case = current_case
	if bool(_runner.get_status_snapshot().get("running", false)):
		_runner.request_stop()
		_errors.append("test harness frame guard reached; Runner was asked to stop safely")


func _load_checkpoint() -> Dictionary:
	var path := _runner.get_last_output_path()
	if path.is_empty() or not FileAccess.file_exists(path):
		return {}
	var parsed := _read_json(path)
	return parsed.get("data", {}) if bool(parsed.get("ok", false)) else {}


func _build_symmetry_cases() -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	for twa in [90.0, 120.0]:
		output.append(_case(12.0, -twa, "PORT"))
		output.append(_case(12.0, twa, "STARBOARD"))
	return output


func _build_grid_cases(mirror_allowed: bool, completed_symmetry_rows: Array) -> Array[Dictionary]:
	var completed_ids := {}
	for row in completed_symmetry_rows:
		var absolute_angle := absf(float(row.get("target_twa_deg", 999.0)))
		var is_grid_probe_point := absf(float(row.get("target_tws_kn", 0.0)) - 12.0) < 0.001 and (is_equal_approx(absolute_angle, 90.0) or is_equal_approx(absolute_angle, 120.0))
		var tack := str(row.get("tack", ""))
		if is_grid_probe_point and (not mirror_allowed or tack == "PORT"):
			completed_ids[str(row.get("case_id", ""))] = true
	var output: Array[Dictionary] = []
	for tws in TWS_GRID:
		for angle in ANGLE_GRID:
			var definitions: Array[Dictionary] = []
			if angle == 0.0 or angle == 180.0:
				definitions.append(_case(tws, angle, "SYMMETRIC"))
			elif mirror_allowed:
				definitions.append(_case(tws, -angle, "PORT"))
			else:
				definitions.append(_case(tws, -angle, "PORT"))
				definitions.append(_case(tws, angle, "STARBOARD"))
			for definition in definitions:
				if completed_ids.has(str(definition["case_id"])):
					continue
				output.append(definition)
	return output


func _case(tws: float, twa: float, tack: String) -> Dictionary:
	var signed := twa
	if tack == "PORT":
		signed = -absf(twa)
	elif tack == "STARBOARD":
		signed = absf(twa)
	else:
		signed = absf(twa)
	var case_label := "%05.2f" % tws
	var angle_label := "%+06.2f" % signed
	return {
		"case_id": "official_tws_%s_twa_%s_%s" % [case_label, angle_label, tack.to_lower()],
		"target_tws_kn": tws,
		"target_twa_deg": signed,
		"tack": tack,
		"auto_sail_trim_enabled": true,
	}


func _grid_ui_config(cases: Array[Dictionary]) -> Dictionary:
	return {"explicit_cases": cases, "include_extended_telemetry": false}


func _validate_grid_construction() -> Dictionary:
	var mirror_rows: Array = [
		_case(12.0, -90.0, "PORT"),
		_case(12.0, 90.0, "STARBOARD"),
		_case(12.0, -120.0, "PORT"),
		_case(12.0, 120.0, "STARBOARD"),
	]
	var mirrored := _build_grid_cases(true, mirror_rows)
	var both_sides := _build_grid_cases(false, mirror_rows)
	var unique_ids := {}
	for test_case in mirrored:
		unique_ids[str(test_case.get("case_id", ""))] = true
	if mirrored.size() != 93 or unique_ids.size() != mirrored.size():
		return {"valid": false, "reason": "mirrored grid should have 93 remaining cases after two PORT symmetry probes; got %d" % mirrored.size()}
	if both_sides.size() != 176:
		return {"valid": false, "reason": "two-tack grid should have 176 remaining cases after four symmetry probes; got %d" % both_sides.size()}
	return {"valid": true, "mirrored_grid_remaining": mirrored.size(), "two_tack_grid_remaining": both_sides.size(), "total_points_mirror": mirrored.size() + 2, "total_points_two_tack": both_sides.size() + 4}


func _evaluate_symmetry(rows: Array) -> Dictionary:
	var pairs := []
	var passed := rows.size() == 4
	var by_key := {}
	for row in rows:
		var key := "%.3f|%.3f" % [float(row.get("target_tws_kn", 0.0)), absf(float(row.get("target_twa_deg", 0.0)))]
		if not by_key.has(key):
			by_key[key] = {}
		by_key[key][str(row.get("tack", ""))] = row
	for key in by_key:
		var pair: Dictionary = by_key[key]
		var port: Dictionary = pair.get("PORT", {})
		var starboard: Dictionary = pair.get("STARBOARD", {})
		var row_passed := not port.is_empty() and not starboard.is_empty()
		var relative_speed_delta: Variant = null
		var port_heel: Variant = null
		var starboard_heel: Variant = null
		var port_twa_error: Variant = null
		var starboard_twa_error: Variant = null
		if row_passed:
			row_passed = str(port.get("status", "")) == "STABLE" and str(starboard.get("status", "")) == "STABLE"
		if row_passed:
			var port_speed := float(port.get("mean_sog_kn", 0.0))
			var starboard_speed := float(starboard.get("mean_sog_kn", 0.0))
			var mean_speed := maxf((port_speed + starboard_speed) * 0.5, 0.1)
			relative_speed_delta = absf(port_speed - starboard_speed) / mean_speed
			port_heel = float(port.get("mean_heel_deg", 0.0))
			starboard_heel = float(starboard.get("mean_heel_deg", 0.0))
			var heel_mirrors: bool = absf(float(port_heel)) < 0.5 or absf(float(starboard_heel)) < 0.5 or float(port_heel) * float(starboard_heel) < 0.0
			port_twa_error = absf(absf(float(port.get("measured_twa_deg", 999.0))) - absf(float(port.get("target_twa_deg", 0.0))))
			starboard_twa_error = absf(absf(float(starboard.get("measured_twa_deg", 999.0))) - absf(float(starboard.get("target_twa_deg", 0.0))))
			row_passed = float(relative_speed_delta) <= 0.05 and heel_mirrors and float(port_twa_error) <= 5.0 and float(starboard_twa_error) <= 5.0
		passed = passed and row_passed
		pairs.append({
			"condition": key,
			"passed": row_passed,
			"port_case_id": port.get("case_id", ""),
			"starboard_case_id": starboard.get("case_id", ""),
			"relative_sog_difference": relative_speed_delta,
			"port_heel_deg": port_heel,
			"starboard_heel_deg": starboard_heel,
			"port_twa_error_deg": port_twa_error,
			"starboard_twa_error_deg": starboard_twa_error,
		})
	return {
		"passed": passed,
		"method": "12 kn / 90° and 120° PORT vs STARBOARD; both must be STABLE, speed difference <=5%, measured TWA error <=5°, and heel sign must mirror when visible",
		"pair_count": pairs.size(),
		"pairs": pairs,
	}


func _finalize_run(context: Dictionary, grid_state: Dictionary) -> void:
	var grid_rows: Array = grid_state.get("results", [])
	var symmetry_rows: Array = context.get("symmetry_rows", [])
	if grid_rows.size() != (context.get("grid_cases", []) as Array).size():
		_errors.append("grid result count %d does not match its case count" % grid_rows.size())
		return
	if not _copy_runner_artifacts(grid_state, _output_dir.path_join("grid")):
		_errors.append("could not preserve full grid artifacts")
		return
	var measurements := _make_formal_measurements(symmetry_rows, grid_rows, bool(context.get("mirror_allowed", false)))
	var expected_count := 95 if bool(context.get("mirror_allowed", false)) else 180
	var status_counts := _count_statuses(measurements)
	var fingerprint := _calculate_source_fingerprint()
	var dataset := _make_release_dataset(measurements, context, grid_state, fingerprint, expected_count, status_counts)
	if not _write_json(_output_dir.path_join("nordic28_polar.json"), dataset):
		_errors.append("could not write the generated Polar data copy")
		return
	if not _write_json("res://resources/sailing/nordic28_polar.json", dataset):
		_errors.append("could not update the official Nordic 28 Polar data resource")
		return
	var manifest := {
		"umbrella_run_id": _umbrella_run_id,
		"symmetry_run_id": str(context.get("symmetry_run_id", "")),
		"grid_run_id": str(grid_state.get("run_id", "")),
		"symmetry_configuration_fingerprint": str(context.get("symmetry_config_hash", "")),
		"grid_configuration_fingerprint": str(grid_state.get("config_hash", "")),
		"release_configuration_fingerprint": fingerprint,
		"symmetry_validation": context.get("symmetry_validation", {}),
		"expected_measurement_count": expected_count,
		"measurement_count": measurements.size(),
		"status_counts": status_counts,
		"profile_paths": {"physics": EXPECTED_PHYSICS_PROFILE, "visual_rig": EXPECTED_VISUAL_PROFILE, "boat_scene": EXPECTED_SCENE},
		"profile_sha256": {EXPECTED_PHYSICS_PROFILE: FileAccess.get_sha256(EXPECTED_PHYSICS_PROFILE), EXPECTED_VISUAL_PROFILE: FileAccess.get_sha256(EXPECTED_VISUAL_PROFILE)},
		"source_sha256": _source_hashes(),
		"created_at": Time.get_datetime_string_from_system(true),
		"raw_artifact_directories": ["symmetry/", "grid/"],
		"completed": measurements.size() == expected_count,
	}
	_write_json(_output_dir.path_join("official_polar_manifest.json"), manifest)
	_write_json("user://nordic28_official_polar_context.json", {"completed": true, "umbrella_run_id": _umbrella_run_id, "output_dir": _output_dir, "release_configuration_fingerprint": fingerprint})
	print("Nordic 28 Polar data written · run=%s · fingerprint=%s · points=%d/%d · statuses=%s · release_eligible=%s" % [
		_umbrella_run_id, fingerprint, measurements.size(), expected_count, JSON.stringify(status_counts), str(dataset.get("release_eligible", false)),
	])


func _make_formal_measurements(symmetry_rows: Array, grid_rows: Array, mirror_allowed: bool) -> Array[Dictionary]:
	var combined: Array = symmetry_rows + grid_rows
	var output: Array[Dictionary] = []
	var seen := {}
	for raw in combined:
		if not raw is Dictionary:
			continue
		var tws := float(raw.get("target_tws_kn", 0.0))
		var signed_twa := float(raw.get("target_twa_deg", 0.0))
		var tack := str(raw.get("tack", ""))
		if mirror_allowed and tack == "STARBOARD":
			continue
		var unique_key := "%.3f|%+.3f|%s" % [tws, signed_twa, tack]
		if seen.has(unique_key):
			continue
		seen[unique_key] = true
		output.append(_normalize_measurement(raw))
	output.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if float(a["target_tws_kn"]) == float(b["target_tws_kn"]):
			return float(a["target_twa_deg_signed"]) < float(b["target_twa_deg_signed"])
		return float(a["target_tws_kn"]) < float(b["target_tws_kn"])
	)
	return output


func _normalize_measurement(raw: Dictionary) -> Dictionary:
	var wind_from := float(raw.get("wind_from_deg", 180.0))
	var wind_rad := deg_to_rad(wind_from)
	var velocity_x := float(raw.get("mean_velocity_world_x_mps", 0.0))
	var velocity_z := float(raw.get("mean_velocity_world_z_mps", 0.0))
	var upwind_vmg := (velocity_x * sin(wind_rad) + velocity_z * -cos(wind_rad)) * KNOTS_PER_MPS
	var deployment_main: Variant = raw.get("main_sail_deployment", null)
	var deployment_jib: Variant = raw.get("jib_deployment", null)
	return {
		"case_id": str(raw.get("case_id", "")),
		"boat_scene_path": EXPECTED_SCENE,
		"target_tws_kn": float(raw.get("target_tws_kn", 0.0)),
		"target_twa_deg_signed": float(raw.get("target_twa_deg", 0.0)),
		"twa_deg_absolute": absf(float(raw.get("target_twa_deg", 0.0))),
		"tack": str(raw.get("tack", "")),
		"status": str(raw.get("status", "INVALID")),
		"failure_reason": str(raw.get("failure_reason", "")),
		"measured_twa_deg": raw.get("measured_twa_deg", null),
		"sog_kn": raw.get("mean_sog_kn", null),
		"stw_kn": raw.get("mean_stw_kn", null),
		"vmg_upwind_kn": upwind_vmg,
		"vmg_downwind_kn": -upwind_vmg,
		"mean_longitudinal_velocity_mps": raw.get("mean_longitudinal_velocity_mps", null),
		"mean_velocity_world_mps": {"east_x": velocity_x, "south_z": velocity_z},
		"mean_heel_deg": raw.get("mean_heel_deg", null),
		"mean_leeway_deg": raw.get("mean_leeway_deg", null),
		"mean_rudder_deg": raw.get("mean_rudder_deg", null),
		"rudder_saturation_fraction": raw.get("rudder_saturation_fraction", null),
		"main_sail_deg": raw.get("main_sail_deg", null),
		"jib_deg": raw.get("headsail_deg", null),
		"main_sail_deployment": deployment_main,
		"jib_deployment": deployment_jib,
		"auto_reef_enabled": bool(raw.get("auto_reef_enabled", false)),
		"auto_trim_state": str(raw.get("auto_trim_state", "")),
		"engine_state": str(raw.get("engine_state", "")),
		"sample_count": int(raw.get("sample_count", 0)),
		"elapsed_simulation_seconds": raw.get("elapsed_simulation_seconds", null),
		"source": {
			"test_run_id": str(raw.get("test_run_id", "")),
			"runner_configuration_fingerprint": str(raw.get("boat_config_hash", "")),
			"timestamp": str(raw.get("timestamp", "")),
			"wave_mode": str(raw.get("wave_mode", "")),
			"physics_ticks_per_second": int(raw.get("physics_ticks_per_second", 0)),
			"time_scale": float(raw.get("physics_time_scale", 1.0)),
		},
	}


func _make_release_dataset(measurements: Array[Dictionary], context: Dictionary, grid_state: Dictionary, fingerprint: String, expected_count: int, statuses: Dictionary) -> Dictionary:
	var valid_points := 0
	var deployment_ok := true
	for row in measurements:
		if _is_stable_forward_point(row):
			valid_points += 1
		if row.get("main_sail_deployment", null) == null or row.get("jib_deployment", null) == null or absf(float(row.get("main_sail_deployment", 0.0)) - 1.0) > 0.001 or absf(float(row.get("jib_deployment", 0.0)) - 1.0) > 0.001 or bool(row.get("auto_reef_enabled", true)):
			deployment_ok = false
	var invalid_count := int(statuses.get("INVALID", 0)) + int(statuses.get("INTERRUPTED", 0))
	var complete := measurements.size() == expected_count
	var release_eligible := complete and deployment_ok and invalid_count == 0 and bool(context.get("mirror_allowed", false))
	return {
		"schema_version": 2,
		"vessel_name": "Nordic 28",
		"boat_scene_path": EXPECTED_SCENE,
		"test_date": Time.get_datetime_string_from_system(true),
		"tester_version": "PolarTestRunner · official Nordic 28 full-sail",
		"godot_version": Engine.get_version_info(),
		"test_run_id": _umbrella_run_id,
		"configuration_fingerprint": fingerprint,
		"release_eligible": release_eligible,
		"release_quality_gate": {
			"passed": release_eligible,
			"complete": complete,
			"expected_case_count": expected_count,
			"result_count": measurements.size(),
			"stable_forward_point_count": valid_points,
			"status_counts": statuses,
			"full_sail_verified": deployment_ok,
			"mirror_symmetry_verified": bool(context.get("mirror_allowed", false)),
			"errors": [] if release_eligible else ["data is incomplete, contains invalid rows, lacks full-sail proof, or did not pass symmetry validation"],
			"warnings": ["failed or non-forward-progress cases remain classified and are excluded from plotted speed curves"],
		},
		"units": {"tws": "kn", "twa": "degree", "sog": "kn", "stw": "kn", "vmg": "kn", "heel": "degree", "velocity": "m/s"},
		"conditions": {"main_sail_deployment": 1.0, "jib_deployment": 1.0, "auto_reef": false, "auto_trim": true, "engine": "OFF", "waves": "zero amplitude; WaveSampler remains enabled", "water_current_mps": 0.0, "wind": "fixed true wind, no randomized gusts", "physics_step_seconds": 1.0 / 60.0, "physics_ticks_per_second_setting": PHYSICS_HZ, "time_scale": TIME_SCALE},
		"tws_grid_kn": TWS_GRID,
		"absolute_twa_grid_deg": ANGLE_GRID,
		"vmg_sign_convention": "vmg_upwind is actual world velocity projected toward the true-wind-from bearing; vmg_downwind is the opposite projection.",
		"symmetry_validation": context.get("symmetry_validation", {}),
		"summary_by_tws": _summarize_by_wind(measurements),
		"source_runs": {"symmetry_probe_run_id": context.get("symmetry_run_id", ""), "grid_run_id": grid_state.get("run_id", ""), "grid_runner_configuration_fingerprint": grid_state.get("config_hash", "")},
		"measurements": measurements,
	}


func _summarize_by_wind(measurements: Array[Dictionary]) -> Dictionary:
	var output := {}
	for tws_value in TWS_GRID:
		var rows: Array[Dictionary] = []
		for row in measurements:
			if absf(float(row.get("target_tws_kn", 0.0)) - tws_value) < 0.01:
				rows.append(row)
		var stable := rows.filter(func(row: Dictionary) -> bool: return _is_stable_forward_point(row))
		var maximum: Dictionary = {}
		var upwind: Dictionary = {}
		var downwind: Dictionary = {}
		for row in stable:
			var speed := float(row.get("sog_kn", 0.0))
			if maximum.is_empty() or speed > float(maximum["sog_kn"]):
				maximum = {"sog_kn": speed, "twa_deg_signed": row.get("target_twa_deg_signed", 0.0)}
			var angle := absf(float(row.get("target_twa_deg_signed", 0.0)))
			if angle <= 90.0 and float(row.get("vmg_upwind_kn", 0.0)) > 0.0 and (upwind.is_empty() or float(row["vmg_upwind_kn"]) > float(upwind["vmg_kn"])):
				upwind = {"vmg_kn": row["vmg_upwind_kn"], "twa_deg_signed": row["target_twa_deg_signed"]}
			if angle >= 90.0 and float(row.get("vmg_downwind_kn", 0.0)) > 0.0 and (downwind.is_empty() or float(row["vmg_downwind_kn"]) > float(downwind["vmg_kn"])):
				downwind = {"vmg_kn": row["vmg_downwind_kn"], "twa_deg_signed": row["target_twa_deg_signed"]}
		output[str(int(tws_value))] = {"stable_point_count": stable.size(), "maximum_speed": maximum, "best_upwind_vmg": upwind, "best_downwind_vmg": downwind}
	return output


func _is_stable_forward_point(row: Dictionary) -> bool:
	return str(row.get("status", "")) == "STABLE" and float(row.get("sog_kn", 0.0)) > 0.0 and float(row.get("mean_longitudinal_velocity_mps", 0.0)) > 0.10


func _count_statuses(measurements: Array[Dictionary]) -> Dictionary:
	var counts := {}
	for row in measurements:
		var status := str(row.get("status", "INVALID"))
		counts[status] = int(counts.get(status, 0)) + 1
	return counts


func _copy_runner_artifacts(state: Dictionary, destination: String) -> bool:
	var checkpoint: Dictionary = state.get("checkpoint", {})
	var source_dir := str(checkpoint.get("run_directory", ""))
	if source_dir.is_empty():
		return false
	var absolute := ProjectSettings.globalize_path(destination)
	if DirAccess.make_dir_recursive_absolute(absolute) != OK and not DirAccess.dir_exists_absolute(absolute):
		return false
	for filename in ["polar_results.csv", "polar_results.json", "polar_summary.json", "polar_checkpoint.json"]:
		var source := source_dir.path_join(filename)
		var target := destination.path_join(filename)
		if not _copy_file(source, target):
			return false
	return true


func _copy_file(source: String, target: String) -> bool:
	var source_file := FileAccess.open(source, FileAccess.READ)
	if source_file == null:
		return false
	var contents := source_file.get_buffer(source_file.get_length())
	var target_file := FileAccess.open(target, FileAccess.WRITE)
	if target_file == null:
		return false
	target_file.store_buffer(contents)
	target_file.flush()
	return target_file.get_error() == OK


func _calculate_source_fingerprint() -> String:
	var payload := {
		"files": _source_hashes(),
		"boat_scene_path": EXPECTED_SCENE,
		"physics_profile_path": EXPECTED_PHYSICS_PROFILE,
		"visual_profile_path": EXPECTED_VISUAL_PROFILE,
		"full_sail": true,
		"auto_reef": false,
		"auto_trim": true,
		"engine": "OFF",
		"tws_grid_kn": TWS_GRID,
		"absolute_twa_grid_deg": ANGLE_GRID,
		"stability": {"warmup_s": 60.0, "window_s": 30.0, "sample_s": 30.0, "timeout_s": 300.0},
		"physics_step_seconds": 1.0 / 60.0,
		"godot_version": Engine.get_version_info(),
	}
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(JSON.stringify(payload).to_utf8_buffer())
	return context.finish().hex_encode()


func _source_hashes() -> Dictionary:
	var output := {}
	for path in HASHED_PATHS:
		output[path] = FileAccess.get_sha256(path) if FileAccess.file_exists(path) else "MISSING"
	return output


func _make_output_directory(path: String) -> bool:
	var absolute := ProjectSettings.globalize_path(path)
	if DirAccess.dir_exists_absolute(absolute):
		return false
	return DirAccess.make_dir_recursive_absolute(absolute) == OK


func _write_json(path: String, value: Variant) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Could not write %s" % path)
		return false
	file.store_string(JSON.stringify(value, "\t") + "\n")
	return true


func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "reason": "cannot open %s" % path}
	var json := JSON.new()
	var error := json.parse(file.get_as_text())
	if error != OK or not json.data is Dictionary:
		return {"ok": false, "reason": json.get_error_message()}
	return {"ok": true, "data": json.data}


func _finish(code: int, message: String = "") -> void:
	if not message.is_empty():
		if code == 0:
			print(message)
		else:
			_errors.append(message)
	Engine.physics_ticks_per_second = _old_physics_hz
	Engine.time_scale = _old_time_scale
	if _lab != null and is_instance_valid(_lab):
		_lab.queue_free()
	if code == 0 and _errors.is_empty():
		quit(0)
	else:
		for error in _errors:
			push_error("[Nordic 28 official Polar] " + error)
		quit(maxi(code, 1))
