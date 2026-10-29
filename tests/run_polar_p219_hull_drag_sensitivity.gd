extends SceneTree
## P2.19: one-factor longitudinal hull-resistance sensitivity test.
## Reuses the P2.16 boat, lab, PolarTestRunner, and P2.16 stable BASE rows.

const LAB_SCENE := preload("res://scenes/SailboatLabP216.tscn")
const BOAT_SCENE_PATH := "res://scenes/boats/SailingBoat8mP216.tscn"
const BASE_PROFILE_PATH := "res://resources/sailing/nordic28_p216_physics_profile.tres"
const TEST_PROFILE_PATH := "res://resources/sailing/nordic28_p219_physics_profile.tres"
const POLAR_PROFILE := preload("res://resources/sailing/polar_test_profile.tres")
const BASE_RESULTS_PATH := "res://docs/sailing/polar_p216/p216_results.json"
const OUTPUT_ROOT := "res://docs/sailing/polar_p219"
const PHYSICS_HZ := 480
const TIME_SCALE := 8.0
const CASE_TIMEOUT_S := 180.0
const EXPECTED_PHYSICS_STEP_S := 1.0 / 60.0
const PROFILE_DIFFERENCE_ALLOWLIST := ["hull_longitudinal_drag_linear_n_s_m"]
const HASHED_FILES := [
	"res://scripts/sailboat_lab_body.gd",
	"res://scripts/sailboat_aero_math.gd",
	"res://scripts/sailboat_hydrodynamics.gd",
	"res://scripts/polar_test_runner.gd",
	"res://scripts/polar_test_profile.gd",
	"res://scripts/polar_stability_detector.gd",
	"res://scripts/polar_data_exporter.gd",
	BASE_PROFILE_PATH,
	TEST_PROFILE_PATH,
	"res://scenes/SailboatLabP216.tscn",
	BOAT_SCENE_PATH,
	"res://resources/sailing/polar_test_profile.tres",
	"res://project.godot",
	"res://tests/run_polar_p219_hull_drag_sensitivity.gd",
]
const CASES := [
	{"tws": 8.0, "twa": 90.0},
	{"tws": 8.0, "twa": 120.0},
	{"tws": 12.0, "twa": 90.0},
	{"tws": 12.0, "twa": 120.0},
	{"tws": 16.0, "twa": 90.0},
	{"tws": 16.0, "twa": 120.0},
]

var _old_physics_hz := 60
var _old_time_scale := 1.0
var _lab: Node3D
var _boat: Node3D
var _runner: PolarTestRunner
var _errors: Array[String] = []
var _run_id := ""
var _run_fingerprint := ""
var _base_profile_sha256 := ""
var _test_profile_sha256 := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_old_physics_hz = Engine.physics_ticks_per_second
	_old_time_scale = Engine.time_scale
	var base_profile := load(BASE_PROFILE_PATH) as Resource
	var test_profile := load(TEST_PROFILE_PATH) as Resource
	if base_profile == null or test_profile == null:
		_finish(2, "Could not load P2.16/P2.19 physics Profiles")
		return
	if not _profiles_differ_only_by_linear_drag(base_profile, test_profile):
		_finish(2, "P2.19 Profile differs from P2.16 outside the approved linear longitudinal drag field")
		return
	var baselines := _load_baselines()
	if baselines.size() != CASES.size():
		_finish(2, "Could not load all six stable PORT baselines from P2.16")
		return

	_run_id = "p219_%s_%d" % [Time.get_datetime_string_from_system(true).replace(":", "").replace("-", ""), Time.get_ticks_usec() % 1000000]
	_base_profile_sha256 = FileAccess.get_sha256(BASE_PROFILE_PATH)
	_test_profile_sha256 = FileAccess.get_sha256(TEST_PROFILE_PATH)
	_run_fingerprint = _make_configuration_fingerprint()
	Engine.physics_ticks_per_second = PHYSICS_HZ
	Engine.time_scale = TIME_SCALE
	_lab = LAB_SCENE.instantiate() as Node3D
	_boat = _lab.get_node_or_null("SailboatBody")
	_runner = _lab.get_node_or_null("PolarTestRunner") as PolarTestRunner
	if _boat == null or _runner == null or _boat.scene_file_path != BOAT_SCENE_PATH:
		_finish(2, "P2.16 SailboatLab fixture is missing its P2.16 boat or PolarTestRunner")
		return
	_boat.set("profile", test_profile)
	var polar_profile := (POLAR_PROFILE as Resource).duplicate(true)
	polar_profile.set("boat_scene_paths", PackedStringArray([BOAT_SCENE_PATH]))
	polar_profile.set("case_timeout_seconds", CASE_TIMEOUT_S)
	_runner.profile = polar_profile
	root.add_child(_lab)
	await process_frame
	await process_frame
	if not _runtime_profile_is_test_profile(test_profile):
		_finish(2, "P2.19 profile was not active before test sampling")
		return

	var smoke_case := _make_case(CASES[0])
	var smoke_state := await _run_batch("smoke", [smoke_case])
	if not bool(smoke_state.get("ok", false)):
		_finish(1, str(smoke_state.get("reason", "P2.19 8 kn / 90° smoke failed")))
		return
	var smoke_checkpoint: Dictionary = smoke_state["checkpoint"]
	if not _smoke_is_acceptable(smoke_checkpoint):
		_save_partial(smoke_checkpoint, {}, baselines, base_profile, test_profile, "SMOKE_REJECTED")
		_finish(1, "P2.19 8 kn / 90° smoke was not stable with finite forces; remaining five cases were not started")
		return
	print("P2.19 smoke passed · %s · %.3f kn" % [
		str(smoke_checkpoint.get("test_run_id", "")),
		float(smoke_checkpoint.get("results", [])[0].get("mean_sog_kn", 0.0)),
	])

	var remaining_cases: Array[Dictionary] = []
	for index in range(1, CASES.size()):
		remaining_cases.append(_make_case(CASES[index]))
	var remaining_state := await _run_batch("remaining", remaining_cases)
	if not bool(remaining_state.get("ok", false)):
		_save_partial(smoke_checkpoint, remaining_state.get("checkpoint", {}), baselines, base_profile, test_profile, "REMAINING_FAILED")
		_finish(1, str(remaining_state.get("reason", "P2.19 remaining cases failed")))
		return
	var remaining_checkpoint: Dictionary = remaining_state["checkpoint"]
	var test_rows: Array = smoke_checkpoint.get("results", []) + remaining_checkpoint.get("results", [])
	if test_rows.size() != CASES.size():
		_save_partial(smoke_checkpoint, remaining_checkpoint, baselines, base_profile, test_profile, "INCOMPLETE")
		_finish(1, "P2.19 completed %d/%d test rows" % [test_rows.size(), CASES.size()])
		return
	for row in test_rows:
		if not _result_row_valid(row):
			_save_partial(smoke_checkpoint, remaining_checkpoint, baselines, base_profile, test_profile, "INVALID_ROW")
			_finish(1, "Invalid P2.19 telemetry or physics state in %s" % str(row.get("case_id", "unknown")))
			return

	var comparison_rows := _make_comparison_rows(baselines, test_rows)
	if comparison_rows.size() != CASES.size():
		_save_partial(smoke_checkpoint, remaining_checkpoint, baselines, base_profile, test_profile, "COMPARISON_INCOMPLETE")
		_finish(1, "P2.19 comparison rows are incomplete")
		return
	var absolute_output := ProjectSettings.globalize_path(OUTPUT_ROOT.path_join(_run_id))
	if DirAccess.dir_exists_absolute(absolute_output):
		_finish(2, "Refusing to overwrite existing P2.19 run directory")
		return
	if DirAccess.make_dir_recursive_absolute(absolute_output) != OK:
		_finish(2, "Could not create P2.19 output directory")
		return
	if not _copy_checkpoint_artifacts(smoke_checkpoint, OUTPUT_ROOT.path_join(_run_id).path_join("smoke")):
		_finish(2, "Could not preserve P2.19 smoke run artifacts")
		return
	if not _copy_checkpoint_artifacts(remaining_checkpoint, OUTPUT_ROOT.path_join(_run_id).path_join("remaining")):
		_finish(2, "Could not preserve P2.19 remaining run artifacts")
		return
	if not _write_csv(OUTPUT_ROOT.path_join(_run_id).path_join("p219_comparison.csv"), comparison_rows):
		_finish(2, "Could not write P2.19 comparison CSV")
		return
	if not _write_json(OUTPUT_ROOT.path_join(_run_id).path_join("p219_comparison.json"), comparison_rows):
		_finish(2, "Could not write P2.19 comparison JSON")
		return
	var manifest := _make_manifest(smoke_checkpoint, remaining_checkpoint, baselines, base_profile, test_profile, comparison_rows, "COMPLETE")
	if not _write_json(OUTPUT_ROOT.path_join(_run_id).path_join("p219_manifest.json"), manifest):
		_finish(2, "Could not write P2.19 manifest")
		return
	print("P2.19 complete · run=%s · fingerprint=%s · smoke=%s · remaining=%s · statuses=%s" % [
		_run_id, _run_fingerprint, smoke_checkpoint.get("test_run_id", ""),
		remaining_checkpoint.get("test_run_id", ""), _status_summary(test_rows),
	])
	_finish(0)


func _make_case(definition: Dictionary) -> Dictionary:
	var tws := float(definition["tws"])
	var twa := float(definition["twa"])
	return {
		"case_id": "p219_%02dkn_%03dtwa_port" % [int(tws), int(twa)],
		"target_tws_kn": tws,
		"target_twa_deg": -twa,
		"tack": "PORT",
		"experiment_group": "P2.19_HULL_LONGITUDINAL_DRAG_SENSITIVITY",
		"experiment_variable": "hull_longitudinal_drag_linear_n_s_m",
		"experiment_label": "P2.19 · %.0f kn / %.0f° / hull linear drag 165" % [tws, twa],
		"auto_sail_trim_enabled": true,
	}


func _run_batch(label: String, cases: Array[Dictionary]) -> Dictionary:
	if not _runner.start_new_batch({"include_extended_telemetry": true, "explicit_cases": cases}):
		return {"ok": false, "reason": "P2.19 %s batch did not start: %s" % [label, str(_runner.get_status_snapshot().get("status", "unknown"))]}
	var initial := _runner.get_status_snapshot()
	print("P2.19 %s started · run=%s · %d case(s) · dt=1/60 s · engine=%d Hz × %.1f" % [
		label, str(initial.get("test_run_id", "pending")), cases.size(), PHYSICS_HZ, TIME_SCALE,
	])
	var last_case := ""
	while bool(_runner.get_status_snapshot().get("running", false)):
		await process_frame
		var snapshot := _runner.get_status_snapshot()
		var case_id := str(snapshot.get("current_case_id", ""))
		if case_id != last_case:
			last_case = case_id
			print("P2.19 progress · %s · %d/%d · %s · sim %.0f s · %.2f kn · TWA %+.1f°" % [
				label, int(snapshot.get("completed_count", 0)), int(snapshot.get("case_count", 0)), case_id,
				float(snapshot.get("simulation_seconds", 0.0)), float(snapshot.get("sog_kn", 0.0)),
				float(snapshot.get("measured_twa_deg", 0.0)),
			])
	var state := _runner.get_status_snapshot()
	var output_path := str(state.get("output_path", ""))
	if output_path.is_empty() or not FileAccess.file_exists(output_path):
		return {"ok": false, "reason": "P2.19 %s run ended without a readable checkpoint" % label}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(output_path))
	if not parsed is Dictionary:
		return {"ok": false, "reason": "P2.19 %s checkpoint is invalid" % label}
	var checkpoint: Dictionary = parsed
	if int(state.get("completed_count", 0)) != cases.size() or checkpoint.get("results", []).size() != cases.size():
		return {"ok": false, "reason": "P2.19 %s checkpoint is incomplete (%d/%d)" % [label, checkpoint.get("results", []).size(), cases.size()]}
	return {"ok": true, "checkpoint": checkpoint}


func _profiles_differ_only_by_linear_drag(base: Resource, candidate: Resource) -> bool:
	if absf(float(base.get("hull_longitudinal_drag_linear_n_s_m")) - 220.0) > 0.000001:
		return false
	if absf(float(candidate.get("hull_longitudinal_drag_linear_n_s_m")) - 165.0) > 0.000001:
		return false
	if absf(float(base.get("hull_longitudinal_drag_quadratic_n_s2_m2")) - 85.0) > 0.000001:
		return false
	if absf(float(candidate.get("hull_longitudinal_drag_quadratic_n_s2_m2")) - 85.0) > 0.000001:
		return false
	if absf(float(candidate.get("sail_induced_drag_factor")) - 0.55) > 0.000001:
		return false
	if absf(float(candidate.get("headsail_induced_drag_factor")) - 0.55) > 0.000001:
		return false
	for property_value in base.get_property_list():
		var property: Dictionary = property_value
		var name := str(property.get("name", ""))
		if name.is_empty() or name == "script" or name.begins_with("resource_") or name in PROFILE_DIFFERENCE_ALLOWLIST:
			continue
		if base.get(name) != candidate.get(name):
			push_error("P2.19 Profile mismatch at %s" % name)
			return false
	return true


func _runtime_profile_is_test_profile(expected: Resource) -> bool:
	if _boat.get("profile") != expected:
		return false
	var actual := _boat.get("profile") as Resource
	return actual != null and actual.resource_path == TEST_PROFILE_PATH \
		and absf(float(actual.get("hull_longitudinal_drag_linear_n_s_m")) - 165.0) < 0.000001 \
		and absf(float(actual.get("hull_longitudinal_drag_quadratic_n_s2_m2")) - 85.0) < 0.000001 \
		and absf(float(actual.get("sail_induced_drag_factor")) - 0.55) < 0.000001 \
		and absf(float(actual.get("headsail_induced_drag_factor")) - 0.55) < 0.000001


func _load_baselines() -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(BASE_RESULTS_PATH))
	if not parsed is Array:
		push_error("P2.16 combined results JSON is invalid")
		return {}
	var indexed := {}
	for row_variant in parsed:
		var row: Dictionary = row_variant
		if str(row.get("status", "")) != "STABLE" or str(row.get("tack", "")) != "PORT":
			continue
		indexed[str(row.get("case_id", ""))] = row
	var output := {}
	for definition in CASES:
		var tws := float(definition["tws"])
		var twa := float(definition["twa"])
		var case_id := "p216_%02dkn_%03dtwa_port" % [int(tws), int(twa)]
		var row: Dictionary = indexed.get(case_id, {})
		var extended: Dictionary = row.get("extended_telemetry", {})
		if row.is_empty() or not bool(extended.get("telemetry_finite", false)) or int(extended.get("telemetry_sample_count", 0)) <= 0:
			push_error("Missing stable finite P2.16 baseline %s" % case_id)
			return {}
		if str(row.get("engine_state", "OFF")) not in ["OFF", "关闭"] or not bool(row.get("auto_sail_trim_enabled", false)):
			push_error("P2.16 baseline has incompatible engine or trim state: %s" % case_id)
			return {}
		output[case_id] = row.duplicate(true)
	return output


func _smoke_is_acceptable(checkpoint: Dictionary) -> bool:
	var rows: Array = checkpoint.get("results", [])
	if rows.size() != 1:
		return false
	var row: Dictionary = rows[0]
	if str(row.get("status", "")) != "STABLE" or not _result_row_valid(row):
		return false
	return float(row.get("mean_sog_kn", 0.0)) > 0.0 and absf(absf(float(row.get("measured_twa_deg", 999.0))) - 90.0) <= 5.0


func _result_row_valid(row: Dictionary) -> bool:
	if str(row.get("status", "")) not in ["STABLE", "HEADING_FAILED", "NO_FORWARD_PROGRESS", "UNSTABLE", "TIMEOUT", "INVALID"]:
		return false
	for key in ["mean_sog_kn", "measured_twa_deg", "mean_heel_deg", "mean_leeway_deg", "mean_rudder_deg", "rudder_saturation_fraction", "mean_main_forward_force_n", "mean_headsail_forward_force_n", "mean_hull_resistance_forward_n", "observed_physics_step_seconds"]:
		if not row.has(key) or not _is_finite_number(row[key]):
			return false
	if absf(float(row.get("observed_physics_step_seconds", NAN)) - EXPECTED_PHYSICS_STEP_S) > 0.0005:
		return false
	if str(row.get("engine_state", "")) not in ["OFF", "关闭"] or not bool(row.get("auto_sail_trim_enabled", false)):
		return false
	var extended: Dictionary = row.get("extended_telemetry", {})
	if not bool(extended.get("telemetry_finite", false)) or int(extended.get("telemetry_sample_count", 0)) <= 0:
		return false
	for key in ["mean_main_net_forward_force_n", "mean_jib_net_forward_force_n", "mean_hull_longitudinal_resistance_forward_n"]:
		if not extended.has(key) or not _is_finite_number(extended[key]):
			return false
	return true


func _make_comparison_rows(baselines: Dictionary, test_rows: Array) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	var test_index := {}
	for test_row_variant in test_rows:
		var test_row: Dictionary = test_row_variant
		test_index[str(test_row.get("case_id", ""))] = test_row
	for definition in CASES:
		var tws := float(definition["tws"])
		var twa := float(definition["twa"])
		var base_case_id := "p216_%02dkn_%03dtwa_port" % [int(tws), int(twa)]
		var test_case_id := "p219_%02dkn_%03dtwa_port" % [int(tws), int(twa)]
		var base: Dictionary = baselines.get(base_case_id, {})
		var test: Dictionary = test_index.get(test_case_id, {})
		if base.is_empty() or test.is_empty():
			continue
		var base_ext: Dictionary = base.get("extended_telemetry", {})
		var test_ext: Dictionary = test.get("extended_telemetry", {})
		var base_sog := float(base.get("mean_sog_kn", NAN))
		var test_sog := float(test.get("mean_sog_kn", NAN))
		output.append({
			"target_tws_kn": tws,
			"target_twa_deg": twa,
			"tack": "PORT",
			"base_case_id": base_case_id,
			"test_case_id": test_case_id,
			"base_status": str(base.get("status", "")),
			"test_status": str(test.get("status", "")),
			"base_run_id": str(base.get("source_test_run_id", base.get("test_run_id", ""))),
			"test_run_id": str(test.get("test_run_id", "")),
			"base_configuration_fingerprint": str(base.get("polar_config_fingerprint", "")),
			"test_configuration_fingerprint": str(test.get("polar_config_fingerprint", "")),
			"base_sog_kn": base_sog,
			"test_sog_kn": test_sog,
			"sog_delta_kn": test_sog - base_sog,
			"sog_delta_percent": (test_sog / base_sog - 1.0) * 100.0 if base_sog > 0.0 else NAN,
			"base_measured_twa_deg": float(base.get("measured_twa_deg", NAN)),
			"test_measured_twa_deg": float(test.get("measured_twa_deg", NAN)),
			"base_heel_abs_deg": absf(float(base.get("mean_heel_deg", NAN))),
			"test_heel_abs_deg": absf(float(test.get("mean_heel_deg", NAN))),
			"base_leeway_deg": float(base.get("mean_leeway_deg", NAN)),
			"test_leeway_deg": float(test.get("mean_leeway_deg", NAN)),
			"base_rudder_deg": float(base.get("mean_rudder_deg", NAN)),
			"test_rudder_deg": float(test.get("mean_rudder_deg", NAN)),
			"base_rudder_saturation_fraction": float(base.get("rudder_saturation_fraction", NAN)),
			"test_rudder_saturation_fraction": float(test.get("rudder_saturation_fraction", NAN)),
			"base_main_forward_force_n": float(base_ext.get("mean_main_net_forward_force_n", NAN)),
			"test_main_forward_force_n": float(test_ext.get("mean_main_net_forward_force_n", NAN)),
			"base_jib_forward_force_n": float(base_ext.get("mean_jib_net_forward_force_n", NAN)),
			"test_jib_forward_force_n": float(test_ext.get("mean_jib_net_forward_force_n", NAN)),
			"base_hull_longitudinal_resistance_forward_n": float(base_ext.get("mean_hull_longitudinal_resistance_forward_n", NAN)),
			"test_hull_longitudinal_resistance_forward_n": float(test_ext.get("mean_hull_longitudinal_resistance_forward_n", NAN)),
			"base_sample_count": int(base.get("sample_count", 0)),
			"test_sample_count": int(test.get("sample_count", 0)),
		})
	return output


func _copy_checkpoint_artifacts(checkpoint: Dictionary, destination: String) -> bool:
	var absolute_destination := ProjectSettings.globalize_path(destination)
	if DirAccess.make_dir_recursive_absolute(absolute_destination) != OK and not DirAccess.dir_exists_absolute(absolute_destination):
		return false
	var source_directory := str(checkpoint.get("run_directory", ""))
	for filename in ["polar_results.csv", "polar_results.json", "polar_summary.json", "polar_checkpoint.json"]:
		if not _copy_file(source_directory.path_join(filename), destination.path_join(filename)):
			return false
	return true


func _save_partial(smoke: Dictionary, remaining: Dictionary, baselines: Dictionary, base_profile: Resource, test_profile: Resource, outcome: String) -> void:
	var directory := OUTPUT_ROOT.path_join(_run_id)
	var absolute_directory := ProjectSettings.globalize_path(directory)
	if DirAccess.make_dir_recursive_absolute(absolute_directory) != OK and not DirAccess.dir_exists_absolute(absolute_directory):
		return
	if not smoke.is_empty():
		_copy_checkpoint_artifacts(smoke, directory.path_join("smoke"))
	if not remaining.is_empty():
		_copy_checkpoint_artifacts(remaining, directory.path_join("remaining"))
	var manifest := _make_manifest(smoke, remaining, baselines, base_profile, test_profile, [], outcome)
	_write_json(directory.path_join("p219_manifest.json"), manifest)


func _make_manifest(smoke: Dictionary, remaining: Dictionary, baselines: Dictionary, base_profile: Resource, test_profile: Resource, comparison_rows: Array, outcome: String) -> Dictionary:
	var base_sources := {}
	for case_id in baselines:
		var row: Dictionary = baselines[case_id]
		base_sources[case_id] = {
			"test_run_id": row.get("source_test_run_id", row.get("test_run_id", "")),
			"configuration_fingerprint": row.get("polar_config_fingerprint", ""),
			"status": row.get("status", ""),
		}
	var source_hashes := {}
	for path in HASHED_FILES:
		source_hashes[path] = FileAccess.get_sha256(path) if FileAccess.file_exists(path) else "missing"
	return {
		"phase": "Nordic 28 P2.19 longitudinal hull drag sensitivity",
		"created_at": Time.get_datetime_string_from_system(true),
		"p219_run_id": _run_id,
		"p219_configuration_fingerprint": _run_fingerprint,
		"status": outcome,
		"boat_scene_path": BOAT_SCENE_PATH,
		"base_profile_path": BASE_PROFILE_PATH,
		"test_profile_path": TEST_PROFILE_PATH,
		"base_profile_sha256": FileAccess.get_sha256(BASE_PROFILE_PATH),
		"test_profile_sha256": FileAccess.get_sha256(TEST_PROFILE_PATH),
		"base_drag_values": {
			"hull_longitudinal_drag_linear_n_s_m": base_profile.get("hull_longitudinal_drag_linear_n_s_m"),
			"hull_longitudinal_drag_quadratic_n_s2_m2": base_profile.get("hull_longitudinal_drag_quadratic_n_s2_m2"),
		},
		"test_drag_values": {
			"hull_longitudinal_drag_linear_n_s_m": test_profile.get("hull_longitudinal_drag_linear_n_s_m"),
			"hull_longitudinal_drag_quadratic_n_s2_m2": test_profile.get("hull_longitudinal_drag_quadratic_n_s2_m2"),
		},
		"profile_difference_allowlist": PROFILE_DIFFERENCE_ALLOWLIST,
		"p216_base_results_path": BASE_RESULTS_PATH,
		"base_data_sources": base_sources,
		"case_statuses": _status_sources(smoke, remaining),
		"comparison_row_count": comparison_rows.size(),
		"conditions": CASES,
		"tack_tested": "PORT; BASE uses matching P2.16 PORT samples",
		"polar_stability_profile": {
			"minimum_warmup_seconds": float(POLAR_PROFILE.get("minimum_warmup_seconds")),
			"stability_window_seconds": float(POLAR_PROFILE.get("stability_window_seconds")),
			"sample_window_seconds": float(POLAR_PROFILE.get("sample_window_seconds")),
			"case_timeout_seconds": CASE_TIMEOUT_S,
			"fixed_physics_step_seconds": EXPECTED_PHYSICS_STEP_S,
		},
		"execution": {
			"godot_version": Engine.get_version_info(),
			"engine_physics_ticks_per_second": PHYSICS_HZ,
			"engine_time_scale": TIME_SCALE,
			"wind": "fixed true wind per case; randomized gust amplitude 0",
			"wave_mode": "WaveSampler enabled with zero amplitude",
			"water_current_mps": 0.0,
			"engine_state": "OFF",
			"auto_trim": true,
		},
		"runner_configuration_fingerprints": {
			"smoke": smoke.get("config_hash", ""),
			"remaining": remaining.get("config_hash", ""),
		},
		"runner_test_run_ids": {
			"smoke": smoke.get("test_run_id", ""),
			"remaining": remaining.get("test_run_id", ""),
		},
		"source_sha256": source_hashes,
		"errors": _errors,
	}


func _status_sources(smoke: Dictionary, remaining: Dictionary) -> Dictionary:
	var output := {}
	for checkpoint in [smoke, remaining]:
		for row in checkpoint.get("results", []):
			output[str(row.get("case_id", ""))] = str(row.get("status", ""))
	return output


func _make_configuration_fingerprint() -> String:
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	for path in HASHED_FILES:
		hasher.update(path.to_utf8_buffer())
		hasher.update(FileAccess.get_file_as_bytes(path))
	hasher.update(JSON.stringify({
		"test_cases": CASES,
		"tack": "PORT",
		"physics_hz": PHYSICS_HZ,
		"time_scale": TIME_SCALE,
		"expected_step_seconds": EXPECTED_PHYSICS_STEP_S,
		"case_timeout_seconds": CASE_TIMEOUT_S,
		"stability_profile": {
			"minimum_warmup_seconds": float(POLAR_PROFILE.get("minimum_warmup_seconds")),
			"stability_window_seconds": float(POLAR_PROFILE.get("stability_window_seconds")),
			"sample_window_seconds": float(POLAR_PROFILE.get("sample_window_seconds")),
		},
		"engine": "OFF",
		"waves": "zero amplitude",
		"current_mps": 0.0,
		"base_data_path": BASE_RESULTS_PATH,
	}, "", true).to_utf8_buffer())
	return hasher.finish().hex_encode()


func _write_csv(path: String, rows: Array[Dictionary]) -> bool:
	if rows.is_empty():
		return false
	var absolute_path := ProjectSettings.globalize_path(path)
	var directory := absolute_path.get_base_dir()
	if DirAccess.make_dir_recursive_absolute(directory) != OK and not DirAccess.dir_exists_absolute(directory):
		return false
	var file := FileAccess.open(absolute_path, FileAccess.WRITE)
	if file == null:
		return false
	var keys: Array = rows[0].keys()
	var header := PackedStringArray()
	for key in keys:
		header.append(str(key))
	file.store_csv_line(header)
	for row in rows:
		var values := PackedStringArray()
		for key in keys:
			values.append(str(row.get(key, "")))
		file.store_csv_line(values)
	file.close()
	return true


func _write_json(path: String, data: Variant) -> bool:
	var absolute_path := ProjectSettings.globalize_path(path)
	var directory := absolute_path.get_base_dir()
	if DirAccess.make_dir_recursive_absolute(directory) != OK and not DirAccess.dir_exists_absolute(directory):
		return false
	var file := FileAccess.open(absolute_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	return true


func _copy_file(source: String, target: String) -> bool:
	if not FileAccess.file_exists(source):
		return false
	return _write_text(target, FileAccess.get_file_as_string(source))


func _write_text(path: String, value: String) -> bool:
	var absolute_path := ProjectSettings.globalize_path(path)
	var directory := absolute_path.get_base_dir()
	if DirAccess.make_dir_recursive_absolute(directory) != OK and not DirAccess.dir_exists_absolute(directory):
		return false
	var file := FileAccess.open(absolute_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(value)
	file.close()
	return true


func _is_finite_number(value: Variant) -> bool:
	return typeof(value) in [TYPE_FLOAT, TYPE_INT] and is_finite(float(value))


func _status_summary(rows: Array) -> String:
	var counts := {}
	for row in rows:
		var status := str(row.get("status", "UNKNOWN"))
		counts[status] = int(counts.get(status, 0)) + 1
	return JSON.stringify(counts)


func _finish(exit_code: int, message: String = "") -> void:
	if not message.is_empty():
		print(message)
	if Engine.physics_ticks_per_second != _old_physics_hz:
		Engine.physics_ticks_per_second = _old_physics_hz
	if not is_equal_approx(Engine.time_scale, _old_time_scale):
		Engine.time_scale = _old_time_scale
	quit(exit_code)
