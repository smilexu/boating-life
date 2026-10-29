extends SceneTree
## Runs the five requested Nordic 28 P2.3 conditions on the isolated rig
## profile, with port and starboard repetitions and the unchanged Polar runner.

const LAB_SCENE := preload("res://scenes/SailboatLabP23.tscn")
const P23_BOAT_SCENE := "res://scenes/boats/SailingBoat8mP23.tscn"
const POLAR_PROFILE := preload("res://resources/sailing/polar_test_profile.tres")
const P23_OUTPUT_ROOT := "res://docs/sailing/polar_p23"
const AERO_MATH := preload("res://scripts/sailboat_aero_math.gd")
const ENGINE_PHYSICS_HZ := 480
const ACCELERATION_SCALE := 8.0

var _lab: Node3D
var _boat: RigidBody3D
var _runner: PolarTestRunner
var _old_physics_hz := 60
var _old_time_scale := 1.0
var _error := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_old_physics_hz = Engine.physics_ticks_per_second
	_old_time_scale = Engine.time_scale
	Engine.physics_ticks_per_second = ENGINE_PHYSICS_HZ
	Engine.time_scale = ACCELERATION_SCALE
	_lab = LAB_SCENE.instantiate() as Node3D
	_boat = _lab.get_node_or_null("SailboatBody") as RigidBody3D
	_runner = _lab.get_node_or_null("PolarTestRunner") as PolarTestRunner
	if _boat == null or _runner == null:
		_finish(2, "P2.3 lab scene is missing SailboatBody or PolarTestRunner")
		return
	_runner.profile = (POLAR_PROFILE as Resource).duplicate(true)
	_runner.profile.set("boat_scene_paths", PackedStringArray([P23_BOAT_SCENE]))
	_boat.set("p22_extended_telemetry_enabled", true)
	root.add_child(_lab)
	await process_frame
	var geometry := _validate_rig()
	if not bool(geometry.get("valid", false)):
		_finish(2, str(geometry.get("reason", "P2.3 rig geometry validation failed")))
		return
	if OS.get_cmdline_user_args().has("--validate-only"):
		print("P2.3 rig validation · %s" % str(geometry))
		_finish(0)
		return
	var cases := _build_cases()
	var started := _runner.start_new_batch({
		"include_extended_telemetry": true,
		"explicit_cases": cases,
	})
	if not started:
		_finish(2, "P2.3 batch failed to start: %s" % str(_runner.get_status_snapshot().get("status", "unknown")))
		return
	print("P2.3 started · run=%s · scene=%s · dt=%.9f s · engine=%d Hz × %.1f · cases=%d" % [
		str(_runner.get_status_snapshot().get("test_run_id", "pending")), P23_BOAT_SCENE,
		1.0 / 60.0, ENGINE_PHYSICS_HZ, ACCELERATION_SCALE, cases.size(),
	])
	await _wait_for_batch()
	var state := _runner.get_status_snapshot()
	var checkpoint_path := str(state.get("output_path", ""))
	if checkpoint_path.is_empty() or not FileAccess.file_exists(checkpoint_path):
		_finish(1, "P2.3 completed without a readable Polar checkpoint")
		return
	var checkpoint_value: Variant = JSON.parse_string(FileAccess.get_file_as_string(checkpoint_path))
	if not checkpoint_value is Dictionary:
		_finish(1, "P2.3 checkpoint JSON could not be parsed")
		return
	var checkpoint: Dictionary = checkpoint_value
	var run_id := str(checkpoint.get("test_run_id", ""))
	var copied_to := _copy_run_artifacts(checkpoint, geometry)
	var results: Array = checkpoint.get("results", [])
	var counts := {}
	for result in results:
		var status := str(result.get("status", "UNKNOWN"))
		counts[status] = int(counts.get(status, 0)) + 1
	_write_json(copied_to.path_join("p23_summary.json"), {
		"experiment": "Nordic 28 P2.3 coherent 28 m2 rig",
		"test_run_id": run_id,
		"polar_config_hash": checkpoint.get("config_hash", ""),
		"boat_scene_path": P23_BOAT_SCENE,
		"physics_profile_path": "res://resources/sailing/nordic28_p23_physics_profile.tres",
		"visual_profile_path": "res://resources/sailing/nordic28_p23_visual_rig_profile.tres",
		"result_count": results.size(),
		"status_counts": counts,
		"geometry": geometry,
		"comparison_baselines": ["P2 frozen Nordic 28", "P2.2 SA28 area-only experiment"],
	})
	print("P2.3 complete · %d/%d · statuses=%s · artifacts=%s" % [
		int(state.get("completed_count", 0)), int(state.get("case_count", 0)), str(counts), copied_to,
	])
	_finish(0 if int(state.get("completed_count", 0)) == cases.size() else 1)


func _validate_rig() -> Dictionary:
	var physics: Resource = _boat.get("profile") as Resource
	var anchors := _boat.get_node_or_null("VisualRoot/VisualRigAnchors") as Node3D
	var visual: Resource = anchors.get("visual_profile") as Resource if anchors != null else null
	if physics == null or visual == null:
		return {"valid": false, "reason": "P2.3 variant did not bind its independent physics and visual profiles"}
	var main_head: Vector3 = visual.get("main_head_local_m")
	var boom_pivot: Vector3 = visual.get("boom_pivot_local_m")
	var main_clew := boom_pivot + Vector3(0.0, 0.0, float(visual.get("boom_length_m")))
	var jib_head: Vector3 = visual.get("jib_head_local_m")
	var jib_tack: Vector3 = visual.get("jib_tack_local_m")
	var jib_clew: Vector3 = visual.get("jib_clew_local_m")
	var main_area_visual := AERO_MATH.triangular_sail_area_m2(main_head, boom_pivot, main_clew)
	var jib_area_visual := AERO_MATH.triangular_sail_area_m2(jib_head, jib_tack, jib_clew)
	var main_area_physics := float(physics.get("main_sail_area_m2"))
	var jib_area_physics := float(physics.get("headsail_area_m2"))
	var visual_offset: Vector3 = visual.get("visual_assembly_offset_local_m")
	var main_center_visual_body := (main_head + boom_pivot + main_clew) / 3.0 + visual_offset
	var main_pivot_physics: Vector3 = physics.get("main_sail_pivot_local_m")
	var main_pc_from_pivot: Vector3 = physics.get("main_sail_pressure_center_from_pivot_m")
	var main_center_physics: Vector3 = main_pivot_physics + main_pc_from_pivot
	var jib_center_visual_body := (jib_head + jib_tack + jib_clew) / 3.0 + visual_offset
	var jib_head_physics: Vector3 = physics.get("headsail_head_local_m")
	var jib_tack_physics: Vector3 = physics.get("headsail_tack_local_m")
	var jib_clew_physics: Vector3 = physics.get("headsail_clew_neutral_local_m")
	var jib_pc_offset: Vector3 = physics.get("headsail_pressure_center_offset_from_centroid_m")
	var jib_center_physics: Vector3 = (jib_head_physics + jib_tack_physics + jib_clew_physics) / 3.0 + jib_pc_offset
	var output := {
		"valid": true,
		"boat_scene_file_path": _boat.scene_file_path,
		"physics_profile_path": physics.resource_path,
		"visual_profile_path": visual.resource_path,
		"mast_base_local_m": visual.get("mast_base_local_m"),
		"mast_top_local_m": visual.get("mast_base_local_m") + Vector3.UP * float(visual.get("mast_length_m")),
		"mast_length_m": float(visual.get("mast_length_m")),
		"boom_pivot_local_m": boom_pivot,
		"boom_length_m": float(visual.get("boom_length_m")),
		"main_head_local_m": main_head,
		"main_tack_local_m": boom_pivot,
		"main_clew_neutral_local_m": main_clew,
		"main_visual_area_m2": main_area_visual,
		"main_physics_area_m2": main_area_physics,
		"jib_head_local_m": jib_head,
		"jib_tack_local_m": jib_tack,
		"jib_clew_neutral_local_m": jib_clew,
		"jib_visual_area_m2": jib_area_visual,
		"jib_physics_area_m2": jib_area_physics,
		"total_sail_area_m2": main_area_physics + jib_area_physics,
		"visual_assembly_offset_local_m": visual_offset,
		"main_visual_center_body_local_m": main_center_visual_body,
		"main_physics_center_body_local_m": main_center_physics,
		"main_center_delta_m": main_center_visual_body.distance_to(main_center_physics),
		"jib_visual_center_body_local_m": jib_center_visual_body,
		"jib_physics_center_body_local_m": jib_center_physics,
		"jib_center_delta_m": jib_center_visual_body.distance_to(jib_center_physics),
	}
	if absf(main_area_visual - main_area_physics) > 0.001 or absf(jib_area_visual - jib_area_physics) > 0.001:
		output["valid"] = false
		output["reason"] = "visual triangle area differs from its experimental physics area"
		return output
	if float(output["main_center_delta_m"]) > 0.002 or float(output["jib_center_delta_m"]) > 0.002:
		output["valid"] = false
		output["reason"] = "experimental pressure centre does not align with visual geometry centroid"
		return output
	return output


func _build_cases() -> Array[Dictionary]:
	var conditions: Array[Vector2] = [Vector2(8.0, 90.0), Vector2(12.0, 50.0), Vector2(12.0, 70.0), Vector2(12.0, 90.0), Vector2(12.0, 120.0)]
	var output: Array[Dictionary] = []
	for condition in conditions:
		for tack in ["PORT", "STARBOARD"]:
			var angle := condition.y * (-1.0 if tack == "PORT" else 1.0)
			var id := "p23_%02dkn_%03dtwa_%s" % [int(condition.x), int(condition.y), tack.to_lower()]
			output.append({
				"case_id": id,
				"target_tws_kn": condition.x,
				"target_twa_deg": angle,
				"tack": tack,
				"experiment_group": "P23_GEOMETRIC_28M2",
				"experiment_variable": "coherent_rig_geometry_and_centres",
				"experiment_label": "P2.3 · %.0f kn / %d° / %s" % [condition.x, int(condition.y), tack],
				"auto_sail_trim_enabled": true,
			})
	return output


func _wait_for_batch() -> void:
	var last_case := ""
	var last_log_usec := 0
	while bool(_runner.get_status_snapshot().get("running", false)):
		await process_frame
		var snapshot := _runner.get_status_snapshot()
		var case_id := str(snapshot.get("current_case_id", ""))
		var now := Time.get_ticks_usec()
		if case_id != last_case or now - last_log_usec >= 15000000:
			last_case = case_id
			last_log_usec = now
			print("P2.3 progress · %d/%d · %s · sim %.0f s · %.2f kn · TWA %+.1f°" % [
				int(snapshot.get("completed_count", 0)), int(snapshot.get("case_count", 0)), case_id,
				float(snapshot.get("simulation_seconds", 0.0)), float(snapshot.get("sog_kn", 0.0)), float(snapshot.get("measured_twa_deg", 0.0)),
			])


func _copy_run_artifacts(checkpoint: Dictionary, geometry: Dictionary) -> String:
	var run_id := str(checkpoint.get("test_run_id", "p23_unknown"))
	var destination := P23_OUTPUT_ROOT.path_join(run_id)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(destination))
	var source_directory := str(checkpoint.get("run_directory", ""))
	for filename in ["polar_results.csv", "polar_results.json", "polar_summary.json", "polar_checkpoint.json"]:
		var source := source_directory.path_join(filename)
		if not FileAccess.file_exists(source):
			continue
		var target := ProjectSettings.globalize_path(destination.path_join(filename))
		var file := FileAccess.open(target, FileAccess.WRITE)
		if file == null:
			_error = "Could not copy artifact %s" % target
			continue
		file.store_string(FileAccess.get_file_as_string(source))
	_write_json(destination.path_join("geometry.json"), geometry)
	_write_json(destination.path_join("manifest.json"), {
		"phase": "Nordic 28 P2.3 geometric rig experiment",
		"test_run_id": run_id,
		"polar_config_hash": checkpoint.get("config_hash", ""),
		"boat_scene_path": P23_BOAT_SCENE,
		"boat_config_hash": checkpoint.get("boat_config_hash", ""),
		"physics_profile_path": "res://resources/sailing/nordic28_p23_physics_profile.tres",
		"visual_profile_path": "res://resources/sailing/nordic28_p23_visual_rig_profile.tres",
		"fixed_wind_seed": 481516,
		"fixed_wind_from_degrees": 180.0,
		"wind_speed_knots": [8.0, 12.0],
		"conditions": [[8.0, 90.0], [12.0, 50.0], [12.0, 70.0], [12.0, 90.0], [12.0, 120.0]],
		"tacks": ["PORT", "STARBOARD"],
		"waves": "static zero amplitude; WaveSampler remains active",
		"physics_step_seconds": 1.0 / 60.0,
		"execution_acceleration": {"engine_physics_ticks_per_second": ENGINE_PHYSICS_HZ, "time_scale": ACCELERATION_SCALE},
		"stability_windows_seconds": {"warmup_minimum": 60.0, "window": 30.0, "post_stability_sample": 30.0, "timeout": 300.0},
		"geometry": geometry,
	})
	return destination


func _write_json(resource_path: String, value: Variant) -> void:
	var absolute_path := ProjectSettings.globalize_path(resource_path)
	var file := FileAccess.open(absolute_path, FileAccess.WRITE)
	if file == null:
		_error = "Could not write JSON: %s" % absolute_path
		return
	file.store_string(JSON.stringify(value, "\t") + "\n")


func _finish(exit_code: int, message: String = "") -> void:
	Engine.physics_ticks_per_second = _old_physics_hz
	Engine.time_scale = _old_time_scale
	if _lab != null and is_instance_valid(_lab):
		_lab.queue_free()
	if not message.is_empty():
		push_error("[polar p2.3] " + message)
		quit(exit_code)
		return
	if not _error.is_empty():
		push_error("[polar p2.3] " + _error)
		quit(1)
		return
	quit(exit_code)
