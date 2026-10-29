extends SceneTree
## P2.18: compare the independent P2.16 baseline against a profile that changes
## only the main-sail and Jib induced-drag factors.

const LAB_SCENE := preload("res://scenes/SailboatLabP216.tscn")
const BOAT_SCENE_PATH := "res://scenes/boats/SailingBoat8mP216.tscn"
const BASE_PHYSICS_PROFILE_PATH := "res://resources/sailing/nordic28_p216_physics_profile.tres"
const TEST_PHYSICS_PROFILE_PATH := "res://resources/sailing/nordic28_p218_physics_profile.tres"
const POLAR_PROFILE := preload("res://resources/sailing/polar_test_profile.tres")
const AERO_MATH := preload("res://scripts/sailboat_aero_math.gd")
const OUTPUT_ROOT := "res://docs/sailing/polar_p218"
const BASE_8KN_PATH := "res://docs/sailing/polar_p216/remaining/polar_2026-10-29_00-21-29_109491/polar_results.json"
const BASE_12KN_PATH := "res://docs/sailing/polar_p216/smoke/polar_2026-10-29_00-20-26_458381/polar_results.json"
const PHYSICS_HZ := 480
const TIME_SCALE := 8.0
const CASE_TIMEOUT_S := 180.0
const KNOTS_TO_MPS := 0.5144444444444445
const HASHED_FILES := [
	"res://scripts/sailboat_lab_body.gd",
	"res://scripts/sailboat_aero_math.gd",
	"res://scripts/sailboat_hydrodynamics.gd",
	"res://scripts/sailboat_buoyancy_math.gd",
	"res://scripts/polar_test_runner.gd",
	"res://scripts/polar_test_profile.gd",
	"res://scripts/polar_stability_detector.gd",
	"res://scripts/polar_data_exporter.gd",
	"res://resources/sailing/nordic28_p216_physics_profile.tres",
	"res://resources/sailing/nordic28_p218_physics_profile.tres",
	"res://scenes/SailboatLabP216.tscn",
	BOAT_SCENE_PATH,
	"res://resources/sailing/polar_test_profile.tres",
	"res://project.godot",
	"res://tests/run_polar_p218_induced_drag_sensitivity.gd",
]

var _old_physics_hz := 60
var _old_time_scale := 1.0
var _lab: Node3D
var _boat: Node3D
var _runner: PolarTestRunner
var _errors: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_old_physics_hz = Engine.physics_ticks_per_second
	_old_time_scale = Engine.time_scale
	var base_profile := load(BASE_PHYSICS_PROFILE_PATH) as Resource
	var test_profile := load(TEST_PHYSICS_PROFILE_PATH) as Resource
	if base_profile == null or test_profile == null:
		_finish(2, "Could not load P2.16/P2.18 physics profiles")
		return
	if not _profiles_differ_only_by_drag_factor(base_profile, test_profile):
		_finish(2, "P2.18 profile differs from P2.16 outside the two approved induced-drag fields")
		return
	var baseline_rows := _load_baselines()
	if baseline_rows.size() != 2:
		_finish(2, "Could not load exact stable PORT P2.16 baseline rows for both conditions")
		return

	var cases: Array[Dictionary] = [
		_make_case(8.0),
		_make_case(12.0),
	]
	var checkpoint_path := ""
	var command_line_args := OS.get_cmdline_user_args()
	var package_arg_index := command_line_args.find("--package-checkpoint")
	if package_arg_index >= 0:
		if package_arg_index + 1 >= command_line_args.size():
			_finish(2, "--package-checkpoint requires a path")
			return
		checkpoint_path = command_line_args[package_arg_index + 1]
	else:
		Engine.physics_ticks_per_second = PHYSICS_HZ
		Engine.time_scale = TIME_SCALE
		_lab = LAB_SCENE.instantiate() as Node3D
		_boat = _lab.get_node_or_null("SailboatBody")
		_runner = _lab.get_node_or_null("PolarTestRunner") as PolarTestRunner
		if _boat == null or _runner == null or _boat.scene_file_path != BOAT_SCENE_PATH:
			_finish(2, "P2.16 SailboatLab fixture is missing the expected real boat or PolarTestRunner")
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
			_finish(2, "P2.18 profile was not active on the P2.16 boat before physics sampling")
			return
		if not _runner.start_new_batch({"include_extended_telemetry": true, "explicit_cases": cases}):
			_finish(2, "P2.18 Polar batch did not start: %s" % str(_runner.get_status_snapshot().get("status", "unknown")))
			return
		print("P2.18 started · 2 cases · PORT · profile=%s · dt=1/60 s · execution=%d Hz × %.1f" % [
			TEST_PHYSICS_PROFILE_PATH, PHYSICS_HZ, TIME_SCALE,
		])
		await _wait_for_batch()
		checkpoint_path = str(_runner.get_status_snapshot().get("output_path", ""))
	if checkpoint_path.is_empty() or not FileAccess.file_exists(checkpoint_path):
		_finish(1, "P2.18 run ended without a readable Polar checkpoint")
		return
	var checkpoint_variant: Variant = JSON.parse_string(FileAccess.get_file_as_string(checkpoint_path))
	if not checkpoint_variant is Dictionary:
		_finish(1, "P2.18 Polar checkpoint is invalid")
		return
	var checkpoint: Dictionary = checkpoint_variant
	var test_rows: Array = checkpoint.get("results", [])
	if test_rows.size() != 2:
		_finish(1, "P2.18 run completed with %d/2 result rows" % test_rows.size())
		return
	for row in test_rows:
		if not _extended_row_valid(row):
			_finish(1, "P2.18 result is missing valid extended sail telemetry: %s" % str(row.get("case_id", "unknown")))
			return

	var run_id := str(checkpoint.get("test_run_id", ""))
	var output_directory := OUTPUT_ROOT.path_join(run_id)
	var absolute_output_directory := ProjectSettings.globalize_path(output_directory)
	if run_id.is_empty() or DirAccess.dir_exists_absolute(absolute_output_directory):
		_finish(2, "P2.18 output directory is empty or already exists; refusing to overwrite")
		return
	if DirAccess.make_dir_recursive_absolute(absolute_output_directory) != OK:
		_finish(2, "Could not create P2.18 output directory")
		return
	var source_directory := str(checkpoint.get("run_directory", ""))
	for filename in ["polar_results.csv", "polar_results.json", "polar_summary.json", "polar_checkpoint.json"]:
		if not _copy_file(source_directory.path_join(filename), output_directory.path_join(filename)):
			_finish(2, "Could not preserve Polar artifact %s" % filename)
			return

	var test_by_case := _index_rows(test_rows)
	var comparison_rows := _make_comparison_rows(baseline_rows, test_by_case)
	var fixed_aero_rows := _make_fixed_input_aero_rows(baseline_rows, base_profile, test_profile)
	if comparison_rows.size() != 2 or fixed_aero_rows.size() != 4:
		_finish(1, "P2.18 comparison data is incomplete")
		return
	if not _write_csv(output_directory.path_join("p218_ab_comparison.csv"), comparison_rows) or not _write_json(output_directory.path_join("p218_ab_comparison.json"), comparison_rows):
		_finish(2, "Could not write P2.18 A/B comparison files")
		return
	if not _write_csv(output_directory.path_join("p218_fixed_input_aero.csv"), fixed_aero_rows) or not _write_json(output_directory.path_join("p218_fixed_input_aero.json"), fixed_aero_rows):
		_finish(2, "Could not write fixed-input aero comparison files")
		return
	var run_manifest := _make_run_manifest(checkpoint, baseline_rows, base_profile, test_profile, cases)
	if not _write_json(output_directory.path_join("p218_manifest.json"), run_manifest):
		_finish(2, "Could not write P2.18 run manifest")
		return
	print("P2.18 complete · run=%s · fingerprint=%s · rows=%d · status=%s" % [
		run_id, str(checkpoint.get("config_hash", "")), test_rows.size(), _status_summary(test_rows),
	])
	_finish(0)


func _make_case(tws_kn: float) -> Dictionary:
	return {
		"case_id": "p218_%02dkn_090twa_port" % int(tws_kn),
		"target_tws_kn": tws_kn,
		"target_twa_deg": -90.0,
		"tack": "PORT",
		"experiment_group": "P2.18_INDUCED_DRAG_SENSITIVITY",
		"experiment_variable": "sail_induced_drag_factor",
		"experiment_label": "P2.18 · %.0f kn / 90° / induced drag 0.30" % tws_kn,
		"auto_sail_trim_enabled": true,
	}


func _wait_for_batch() -> void:
	var last_case := ""
	while bool(_runner.get_status_snapshot().get("running", false)):
		await process_frame
		var snapshot := _runner.get_status_snapshot()
		var case_id := str(snapshot.get("current_case_id", ""))
		if case_id != last_case:
			last_case = case_id
			print("P2.18 progress · %d/%d · %s · sim %.0f s · %.2f kn · TWA %+.1f°" % [
				int(snapshot.get("completed_count", 0)), int(snapshot.get("case_count", 0)), case_id,
				float(snapshot.get("simulation_seconds", 0.0)), float(snapshot.get("sog_kn", 0.0)),
				float(snapshot.get("measured_twa_deg", 0.0)),
			])


func _profiles_differ_only_by_drag_factor(base: Resource, candidate: Resource) -> bool:
	if absf(float(base.get("sail_induced_drag_factor")) - 0.55) > 0.000001:
		return false
	if absf(float(base.get("headsail_induced_drag_factor")) - 0.55) > 0.000001:
		return false
	if absf(float(candidate.get("sail_induced_drag_factor")) - 0.30) > 0.000001:
		return false
	if absf(float(candidate.get("headsail_induced_drag_factor")) - 0.30) > 0.000001:
		return false
	for property in base.get_property_list():
		var name := str(property.get("name", ""))
		if name.is_empty() or name == "script" or name.begins_with("resource_"):
			continue
		if name in ["sail_induced_drag_factor", "headsail_induced_drag_factor"]:
			continue
		if base.get(name) != candidate.get(name):
			push_error("P2.18 profile mismatch at %s" % name)
			return false
	return true


func _runtime_profile_is_test_profile(expected: Resource) -> bool:
	if _boat.get("profile") != expected:
		return false
	var actual := _boat.get("profile") as Resource
	return actual != null and actual.resource_path == TEST_PHYSICS_PROFILE_PATH \
		and absf(float(actual.get("sail_induced_drag_factor")) - 0.30) < 0.000001 \
		and absf(float(actual.get("headsail_induced_drag_factor")) - 0.30) < 0.000001


func _load_baselines() -> Dictionary:
	var output := {}
	var sources := {
		8.0: {"path": BASE_8KN_PATH, "case_id": "p216_08kn_090twa_port", "run_id": "polar_2026-10-29_00-21-29_109491"},
		12.0: {"path": BASE_12KN_PATH, "case_id": "p216_12kn_090twa_port", "run_id": "polar_2026-10-29_00-20-26_458381"},
	}
	for tws in sources:
		var source: Dictionary = sources[tws]
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(str(source["path"])))
		if not parsed is Dictionary:
			push_error("Could not read P2.16 BASE JSON %s" % str(source["path"]))
			return {}
		var found: Dictionary = {}
		for row in parsed.get("results", []):
			if str(row.get("case_id", "")) == str(source["case_id"]):
				found = row
				break
		if found.is_empty() or str(found.get("status", "")) != "STABLE" or str(found.get("test_run_id", "")) != str(source["run_id"]):
			push_error("P2.16 BASE row missing, not stable, or run ID mismatched: %s" % str(source["case_id"]))
			return {}
		var extended: Dictionary = found.get("extended_telemetry", {})
		if not bool(extended.get("telemetry_finite", false)):
			push_error("P2.16 BASE extended telemetry is unavailable for %s" % str(source["case_id"]))
			return {}
		output["%.0f" % float(tws)] = found.duplicate(true)
	return output


func _extended_row_valid(row: Dictionary) -> bool:
	if str(row.get("status", "")) not in ["STABLE", "HEADING_FAILED", "NO_FORWARD_PROGRESS", "UNSTABLE", "TIMEOUT", "INVALID"]:
		return false
	var extended: Dictionary = row.get("extended_telemetry", {})
	if not bool(extended.get("telemetry_finite", false)) or int(extended.get("telemetry_sample_count", 0)) <= 0:
		return false
	for key in ["mean_main_aoa_deg", "mean_main_cl", "mean_main_cd", "mean_jib_aoa_deg", "mean_jib_cl", "mean_jib_cd", "mean_main_net_forward_force_n", "mean_jib_net_forward_force_n"]:
		if not extended.has(key) or not _is_finite_number(extended[key]):
			return false
	return true


func _index_rows(rows: Array) -> Dictionary:
	var output := {}
	for row in rows:
		output[str(row.get("case_id", ""))] = row
	return output


func _make_comparison_rows(base_by_tws: Dictionary, test_by_case: Dictionary) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	for tws in [8.0, 12.0]:
		var key := "%.0f" % tws
		var case_id := "p218_%02dkn_090twa_port" % int(tws)
		var base: Dictionary = base_by_tws.get(key, {})
		var test: Dictionary = test_by_case.get(case_id, {})
		if base.is_empty() or test.is_empty():
			continue
		var base_ext: Dictionary = base.get("extended_telemetry", {})
		var test_ext: Dictionary = test.get("extended_telemetry", {})
		var base_sog := float(base.get("mean_sog_kn", NAN))
		var test_sog := float(test.get("mean_sog_kn", NAN))
		var item := {
			"target_tws_kn": tws, "target_twa_deg": 90.0, "tack": "PORT",
			"base_status": str(base.get("status", "")), "test_status": str(test.get("status", "")),
			"base_run_id": str(base.get("test_run_id", "")), "test_run_id": str(test.get("test_run_id", "")),
			"base_sog_kn": base_sog, "test_sog_kn": test_sog,
			"sog_delta_kn": test_sog - base_sog,
			"sog_delta_percent": (test_sog / base_sog - 1.0) * 100.0 if base_sog > 0.0 else NAN,
			"base_measured_twa_deg": float(base.get("measured_twa_deg", NAN)),
			"test_measured_twa_deg": float(test.get("measured_twa_deg", NAN)),
			"base_heel_abs_deg": absf(float(base.get("mean_heel_deg", NAN))),
			"test_heel_abs_deg": absf(float(test.get("mean_heel_deg", NAN))),
			"base_leeway_deg": base.get("mean_leeway_deg", null), "test_leeway_deg": test.get("mean_leeway_deg", null),
			"base_rudder_deg": float(base.get("mean_rudder_deg", NAN)), "test_rudder_deg": float(test.get("mean_rudder_deg", NAN)),
			"base_rudder_saturation_fraction": float(base.get("rudder_saturation_fraction", NAN)),
			"test_rudder_saturation_fraction": float(test.get("rudder_saturation_fraction", NAN)),
			"base_main_angle_deg": float(base.get("main_sail_deg", NAN)), "test_main_angle_deg": float(test.get("main_sail_deg", NAN)),
			"base_jib_angle_deg": float(base.get("headsail_deg", NAN)), "test_jib_angle_deg": float(test.get("headsail_deg", NAN)),
			"base_main_aoa_deg": float(base_ext.get("mean_main_aoa_deg", NAN)), "test_main_aoa_deg": float(test_ext.get("mean_main_aoa_deg", NAN)),
			"base_main_cl": float(base_ext.get("mean_main_cl", NAN)), "test_main_cl": float(test_ext.get("mean_main_cl", NAN)),
			"base_main_cd": float(base_ext.get("mean_main_cd", NAN)), "test_main_cd": float(test_ext.get("mean_main_cd", NAN)),
			"base_main_forward_force_n": float(base_ext.get("mean_main_net_forward_force_n", NAN)), "test_main_forward_force_n": float(test_ext.get("mean_main_net_forward_force_n", NAN)),
			"base_jib_aoa_deg": float(base_ext.get("mean_jib_aoa_deg", NAN)), "test_jib_aoa_deg": float(test_ext.get("mean_jib_aoa_deg", NAN)),
			"base_jib_cl": float(base_ext.get("mean_jib_cl", NAN)), "test_jib_cl": float(test_ext.get("mean_jib_cl", NAN)),
			"base_jib_cd": float(base_ext.get("mean_jib_cd", NAN)), "test_jib_cd": float(test_ext.get("mean_jib_cd", NAN)),
			"base_jib_forward_force_n": float(base_ext.get("mean_jib_net_forward_force_n", NAN)), "test_jib_forward_force_n": float(test_ext.get("mean_jib_net_forward_force_n", NAN)),
			"base_aws_kn": float(base.get("mean_aws_kn", NAN)), "test_aws_kn": float(test.get("mean_aws_kn", NAN)),
		}
		output.append(item)
	return output


func _make_fixed_input_aero_rows(base_by_tws: Dictionary, base_profile: Resource, test_profile: Resource) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	for tws in [8.0, 12.0]:
		var base: Dictionary = base_by_tws.get("%.0f" % tws, {})
		var extended: Dictionary = base.get("extended_telemetry", {})
		for sail_key in ["main", "jib"]:
			var aws := float(extended.get("mean_%s_aws_mps" % sail_key, NAN))
			var awa := float(extended.get("mean_%s_awa_deg" % sail_key, NAN))
			var trim_deg := float(extended.get("mean_%s_actual_angle_deg" % sail_key, NAN))
			if not is_finite(aws) or not is_finite(awa) or not is_finite(trim_deg) or aws <= 0.01:
				return []
			var apparent_local := Vector3(-sin(deg_to_rad(awa)) * aws, 0.0, cos(deg_to_rad(awa)) * aws)
			var base_force := _fixed_sail_result(sail_key, apparent_local, trim_deg, base_profile)
			var test_force := _fixed_sail_result(sail_key, apparent_local, trim_deg, test_profile)
			var item := {
				"target_tws_kn": tws, "sail": "MAIN" if sail_key == "main" else "JIB",
				"fixed_source_case_id": str(base.get("case_id", "")),
				"fixed_aws_mps": aws, "fixed_awa_from_deg": awa, "fixed_actual_sail_angle_deg": trim_deg,
				"base_induced_drag_factor": float(base_profile.get("sail_induced_drag_factor")) if sail_key == "main" else float(base_profile.get("headsail_induced_drag_factor")),
				"test_induced_drag_factor": float(test_profile.get("sail_induced_drag_factor")) if sail_key == "main" else float(test_profile.get("headsail_induced_drag_factor")),
			}
			_add_aero_result(item, "base", base_force)
			_add_aero_result(item, "test", test_force)
			item["cd_delta"] = float(item["test_cd"]) - float(item["base_cd"])
			item["net_forward_delta_n"] = float(item["test_net_forward_n"]) - float(item["base_net_forward_n"])
			item["net_lateral_delta_n"] = float(item["test_net_lateral_n"]) - float(item["base_net_lateral_n"])
			output.append(item)
	return output


func _fixed_sail_result(sail_key: String, apparent_local: Vector3, trim_deg: float, profile: Resource) -> Dictionary:
	var angle_rad := deg_to_rad(trim_deg)
	var area := float(profile.get("main_sail_area_m2"))
	var max_cl := float(profile.get("sail_max_lift_coefficient"))
	var stall := float(profile.get("sail_stall_angle_rad"))
	var base_cd := float(profile.get("sail_base_drag_coefficient"))
	var induced := float(profile.get("sail_induced_drag_factor"))
	var flat_plate := float(profile.get("sail_flat_plate_drag_factor"))
	var density := float(profile.get("air_density_kg_m3"))
	var no_sail := float(profile.get("no_sail_wind_from_angle_rad"))
	var full_lift := float(profile.get("full_lift_wind_from_angle_rad"))
	var wrong_side := float(profile.get("sail_wrong_side_lift_retention"))
	var result: Dictionary
	if sail_key == "main":
		result = AERO_MATH.calculate_sail_forces(apparent_local, angle_rad, area, density, max_cl, stall, base_cd, induced, flat_plate, no_sail, full_lift, wrong_side)
	else:
		var jib_area := float(profile.get("headsail_area_m2"))
		var jib_head: Vector3 = profile.get("headsail_head_local_m")
		var jib_tack: Vector3 = profile.get("headsail_tack_local_m")
		var jib_clew_neutral: Vector3 = profile.get("headsail_clew_neutral_local_m")
		var jib_clew := AERO_MATH.headsail_clew_from_sheet(jib_tack, jib_clew_neutral, angle_rad)
		var chord := jib_clew - jib_tack
		var chord_xz := Vector2(chord.x, chord.z)
		result = AERO_MATH.calculate_sail_forces_for_chord(
			apparent_local, chord_xz, jib_area, density,
			float(profile.get("headsail_max_lift_coefficient")),
			float(profile.get("headsail_stall_angle_rad")),
			float(profile.get("headsail_base_drag_coefficient")), induced,
			float(profile.get("headsail_flat_plate_drag_factor")),
			float(profile.get("headsail_no_sail_wind_from_angle_rad")),
			float(profile.get("headsail_full_lift_wind_from_angle_rad")),
			float(profile.get("headsail_wrong_side_lift_retention"))
		)
	return result


func _add_aero_result(target: Dictionary, prefix: String, result: Dictionary) -> void:
	var lift: Vector3 = result.get("lift_force_local_n", Vector3.ZERO)
	var drag: Vector3 = result.get("drag_force_local_n", Vector3.ZERO)
	var net: Vector3 = result.get("net_force_local_n", Vector3.ZERO)
	target[prefix + "_aoa_deg"] = rad_to_deg(float(result.get("angle_of_attack_rad", NAN)))
	target[prefix + "_cl"] = float(result.get("cl", NAN))
	target[prefix + "_cd"] = float(result.get("cd", NAN))
	target[prefix + "_lift_forward_n"] = -lift.z
	target[prefix + "_drag_forward_n"] = -drag.z
	target[prefix + "_net_forward_n"] = -net.z
	target[prefix + "_net_lateral_n"] = net.x
	target[prefix + "_valid"] = bool(result.get("valid", false))


func _write_csv(path: String, rows: Array[Dictionary]) -> bool:
	if rows.is_empty():
		return false
	var keys: Array = rows[0].keys()
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	var header := PackedStringArray()
	for key in keys:
		header.append(str(key))
	file.store_csv_line(header)
	for row in rows:
		var values := PackedStringArray()
		for key in keys:
			var value: Variant = row.get(key, "")
			values.append("" if value == null else str(value))
		file.store_csv_line(values)
	file.close()
	return true


func _write_json(path: String, data: Variant) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
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
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(value)
	file.close()
	return true


func _make_run_manifest(checkpoint: Dictionary, baselines: Dictionary, base_profile: Resource, test_profile: Resource, cases: Array[Dictionary]) -> Dictionary:
	var base_ids := {}
	for tws in baselines:
		var row: Dictionary = baselines[tws]
		base_ids[tws] = {
			"test_run_id": row.get("test_run_id", ""),
			"boat_config_hash": row.get("boat_config_hash", ""),
			"case_id": row.get("case_id", ""),
			"status": row.get("status", ""),
		}
	var source_hashes := {}
	for path in HASHED_FILES:
		source_hashes[path] = FileAccess.get_sha256(path) if FileAccess.file_exists(path) else "missing"
	var polar_config: Dictionary = checkpoint.get("config", {})
	var result_rows: Array = checkpoint.get("results", [])
	var first_result: Dictionary = result_rows[0] if not result_rows.is_empty() else {}
	return {
		"phase": "Nordic 28 P2.18 induced-drag factor sensitivity",
		"created_at": Time.get_datetime_string_from_system(true),
		"test_run_id": checkpoint.get("test_run_id", ""),
		"polar_config_fingerprint": checkpoint.get("config_hash", ""),
		"boat_config_fingerprint": checkpoint.get("boat_config_hash", ""),
		"boat_scene_path": BOAT_SCENE_PATH,
		"physics_profile_base": BASE_PHYSICS_PROFILE_PATH,
		"physics_profile_test": TEST_PHYSICS_PROFILE_PATH,
		"physics_profile_base_sha256": FileAccess.get_sha256(BASE_PHYSICS_PROFILE_PATH),
		"physics_profile_test_sha256": FileAccess.get_sha256(TEST_PHYSICS_PROFILE_PATH),
		"profile_difference_allowlist": ["sail_induced_drag_factor", "headsail_induced_drag_factor"],
		"factor_values": {"base": 0.55, "test": 0.30},
		"conditions": cases,
		"base_data_sources": base_ids,
		"fixed_input_aero_source": "Matching P2.16 PORT stable-row mean AWS/AWA and actual sheet angles; both coefficient calculations reuse these same fixed inputs.",
		"polar_stability_profile": {
			"warmup_seconds": polar_config.get("minimum_warmup_seconds", null),
			"stability_window_seconds": polar_config.get("stability_window_seconds", null),
			"sample_window_seconds": polar_config.get("sample_window_seconds", null),
			"case_timeout_seconds": polar_config.get("case_timeout_seconds", null),
			"fixed_physics_step_seconds": polar_config.get("physics_step_seconds", null),
		},
		"execution": {
			"godot_version": first_result.get("physics_version", Engine.get_version_info().get("string", "Godot")),
			"physics_ticks_per_second": polar_config.get("engine_physics_ticks_per_second", null),
			"time_scale": polar_config.get("time_scale", null),
			"observed_physics_step_seconds": first_result.get("observed_physics_step_seconds", null),
			"water_current": "zero",
			"wave_mode": "WaveSampler enabled, static zero amplitude",
			"engine_state": "OFF",
			"auto_trim": true,
		},
		"source_sha256": source_hashes,
		"test_errors": _errors,
	}


func _status_summary(rows: Array) -> String:
	var counts := {}
	for row in rows:
		var status := str(row.get("status", "UNKNOWN"))
		counts[status] = int(counts.get(status, 0)) + 1
	return JSON.stringify(counts)


func _is_finite_number(value: Variant) -> bool:
	return typeof(value) in [TYPE_FLOAT, TYPE_INT] and is_finite(float(value))


func _finish(exit_code: int, message: String = "") -> void:
	if not message.is_empty():
		print(message)
	if Engine.physics_ticks_per_second != _old_physics_hz:
		Engine.physics_ticks_per_second = _old_physics_hz
	if not is_equal_approx(Engine.time_scale, _old_time_scale):
		Engine.time_scale = _old_time_scale
	quit(exit_code)
