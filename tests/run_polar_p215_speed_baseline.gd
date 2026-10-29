extends SceneTree
## P2.15: fill only the missing P2.3c speed-baseline cases at 8 and 16 kn.
## Uses the existing PolarTestRunner and production rigid-body physics.

const LAB_SCENE := preload("res://scenes/SailboatLabP23c.tscn")
const BOAT_SCENE := "res://scenes/boats/SailingBoat8mP23c.tscn"
const PHYSICS_PROFILE_PATH := "res://resources/sailing/nordic28_p23c_physics_profile.tres"
const VISUAL_PROFILE_PATH := "res://resources/sailing/nordic28_p23c_visual_rig_profile.tres"
const POLAR_PROFILE := preload("res://resources/sailing/polar_test_profile.tres")
const OUTPUT_ROOT := "res://docs/sailing/polar_p215"
const AERO_MATH := preload("res://scripts/sailboat_aero_math.gd")
const ENGINE_PHYSICS_HZ := 480
const ACCELERATION_SCALE := 8.0
const CASE_TIMEOUT_S := 180.0

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
		_finish(2, "P2.3c lab scene is missing SailboatBody or PolarTestRunner")
		return
	var test_profile := (POLAR_PROFILE as Resource).duplicate(true)
	test_profile.set("boat_scene_paths", PackedStringArray([BOAT_SCENE]))
	test_profile.set("case_timeout_seconds", CASE_TIMEOUT_S)
	_runner.profile = test_profile
	_boat.set("p22_extended_telemetry_enabled", true)
	root.add_child(_lab)
	await process_frame
	var geometry := _validate_rig()
	if not bool(geometry.get("valid", false)):
		_finish(2, str(geometry.get("reason", "P2.3c rig validation failed")))
		return
	if OS.get_cmdline_user_args().has("--validate-only"):
		print("P2.15 rig validation · %s" % str(geometry))
		_finish(0)
		return
	var cases := _build_cases()
	if cases.size() != 8:
		_finish(2, "P2.15 must contain exactly eight missing mirrored cases, got %d" % cases.size())
		return
	if not _runner.start_new_batch({"include_extended_telemetry": true, "explicit_cases": cases}):
		_finish(2, "P2.15 batch failed to start: %s" % str(_runner.get_status_snapshot().get("status", "unknown")))
		return
	var initial_state := _runner.get_status_snapshot()
	print("P2.15 started · run=%s · boat=%s · dt=%.9f s · engine=%d Hz × %.1f · cases=%d" % [
		str(initial_state.get("test_run_id", "pending")), BOAT_SCENE,
		1.0 / 60.0, ENGINE_PHYSICS_HZ, ACCELERATION_SCALE, cases.size(),
	])
	await _wait_for_batch()
	var state := _runner.get_status_snapshot()
	var checkpoint_path := str(state.get("output_path", ""))
	if checkpoint_path.is_empty() or not FileAccess.file_exists(checkpoint_path):
		_finish(1, "P2.15 completed without a readable Polar checkpoint")
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(checkpoint_path))
	if not parsed is Dictionary:
		_finish(1, "P2.15 checkpoint JSON could not be parsed")
		return
	var checkpoint: Dictionary = parsed
	var run_id := str(checkpoint.get("test_run_id", "p215_unknown"))
	var destination := OUTPUT_ROOT.path_join(run_id)
	if FileAccess.file_exists(destination.path_join("polar_results.json")):
		_finish(1, "Refusing to overwrite existing P2.15 artifacts: %s" % destination)
		return
	if not _copy_run_artifacts(checkpoint, destination, geometry):
		_finish(1, _error)
		return
	var results: Array = checkpoint.get("results", [])
	var counts: Dictionary = {}
	for result in results:
		var status := str(result.get("status", "UNKNOWN"))
		counts[status] = int(counts.get(status, 0)) + 1
	_write_json(destination.path_join("p215_summary.json"), {
		"experiment": "Nordic 28 P2.15 missing 8/16 kn speed baseline cases",
		"test_run_id": run_id,
		"polar_config_hash": checkpoint.get("config_hash", ""),
		"boat_config_hash": checkpoint.get("boat_config_hash", ""),
		"boat_scene_path": BOAT_SCENE,
		"physics_profile_path": PHYSICS_PROFILE_PATH,
		"visual_profile_path": VISUAL_PROFILE_PATH,
		"result_count": results.size(),
		"status_counts": counts,
		"geometry": geometry,
	})
	print("P2.15 complete · %d/%d · run=%s · statuses=%s · artifacts=%s" % [
		int(state.get("completed_count", 0)), int(state.get("case_count", 0)), run_id, str(counts), destination,
	])
	_finish(0 if int(state.get("completed_count", 0)) == cases.size() and results.size() == cases.size() else 1)


func _validate_rig() -> Dictionary:
	if _boat.scene_file_path != BOAT_SCENE:
		return {"valid": false, "reason": "P2.15 lab instantiated %s instead of %s" % [_boat.scene_file_path, BOAT_SCENE]}
	var physics: Resource = _boat.get("profile") as Resource
	var anchors := _boat.get_node_or_null("VisualRoot/VisualRigAnchors") as Node3D
	var visual: Resource = anchors.get("visual_profile") as Resource if anchors != null else null
	if physics == null or visual == null or physics.resource_path != PHYSICS_PROFILE_PATH or visual.resource_path != VISUAL_PROFILE_PATH:
		return {"valid": false, "reason": "P2.3c scene is not bound to the requested independent profiles"}
	var main_area := float(physics.get("main_sail_area_m2"))
	var jib_area := float(physics.get("headsail_area_m2"))
	var main_head: Vector3 = visual.get("main_head_local_m")
	var boom_pivot: Vector3 = visual.get("boom_pivot_local_m")
	var main_clew := boom_pivot + Vector3(0.0, 0.0, float(visual.get("boom_length_m")))
	var jib_head: Vector3 = visual.get("jib_head_local_m")
	var jib_tack: Vector3 = visual.get("jib_tack_local_m")
	var jib_clew: Vector3 = visual.get("jib_clew_local_m")
	var visual_main_area := AERO_MATH.triangular_sail_area_m2(main_head, boom_pivot, main_clew)
	var visual_jib_area := AERO_MATH.triangular_sail_area_m2(jib_head, jib_tack, jib_clew)
	var output := {
		"valid": true,
		"boat_scene_path": _boat.scene_file_path,
		"physics_profile_path": physics.resource_path,
		"visual_profile_path": visual.resource_path,
		"main_physics_area_m2": main_area,
		"jib_physics_area_m2": jib_area,
		"total_physics_area_m2": main_area + jib_area,
		"main_visual_area_m2": visual_main_area,
		"jib_visual_area_m2": visual_jib_area,
		"visual_assembly_offset_local_m": visual.get("visual_assembly_offset_local_m"),
		"main_center_delta_m": _main_center_delta(physics, visual, main_head, boom_pivot, main_clew),
		"jib_center_delta_m": _jib_center_delta(physics, visual, jib_head, jib_tack, jib_clew),
	}
	if absf(main_area - 15.90006) > 0.001 or absf(jib_area - 6.59991) > 0.001:
		output["valid"] = false
		output["reason"] = "P2.3c physical areas differ from the recorded 22.49997 m2 rig"
		return output
	if absf(visual_main_area - main_area) > 0.001 or absf(visual_jib_area - jib_area) > 0.001:
		output["valid"] = false
		output["reason"] = "P2.3c visual triangle areas differ from physical areas"
		return output
	if float(output["main_center_delta_m"]) > 0.002 or float(output["jib_center_delta_m"]) > 0.002:
		output["valid"] = false
		output["reason"] = "P2.3c visual centroid differs from physical pressure center"
	return output


func _main_center_delta(physics: Resource, visual: Resource, head: Vector3, tack: Vector3, clew: Vector3) -> float:
	var offset: Vector3 = visual.get("visual_assembly_offset_local_m")
	var visual_center := (head + tack + clew) / 3.0 + offset
	var physical_center: Vector3 = physics.get("main_sail_pivot_local_m") + physics.get("main_sail_pressure_center_from_pivot_m")
	return visual_center.distance_to(physical_center)


func _jib_center_delta(physics: Resource, visual: Resource, head: Vector3, tack: Vector3, clew: Vector3) -> float:
	var offset: Vector3 = visual.get("visual_assembly_offset_local_m")
	var visual_center := (head + tack + clew) / 3.0 + offset
	var physical_center: Vector3 = (physics.get("headsail_head_local_m") + physics.get("headsail_tack_local_m") + physics.get("headsail_clew_neutral_local_m")) / 3.0 + physics.get("headsail_pressure_center_offset_from_centroid_m")
	return visual_center.distance_to(physical_center)


func _build_cases() -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	var wind_speeds: Array[float] = [8.0, 16.0]
	var wind_angles: Array[float] = [90.0, 120.0]
	for tws: float in wind_speeds:
		for angle: float in wind_angles:
			for tack in ["PORT", "STARBOARD"]:
				var signed_angle: float = -angle if tack == "PORT" else angle
				output.append({
					"case_id": "p215_%02dkn_%03dtwa_%s" % [int(tws), int(angle), tack.to_lower()],
					"target_tws_kn": tws,
					"target_twa_deg": signed_angle,
					"tack": tack,
					"experiment_group": "P215_NORDIC28_P23C_SPEED_BASELINE",
					"experiment_variable": "tws_and_twa",
					"experiment_label": "P2.15 · %.0f kn / %.0f° / %s" % [tws, angle, tack],
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
			print("P2.15 progress · %d/%d · %s · sim %.0f s · %.2f kn · TWA %+.1f°" % [
				int(snapshot.get("completed_count", 0)), int(snapshot.get("case_count", 0)), case_id,
				float(snapshot.get("simulation_seconds", 0.0)), float(snapshot.get("sog_kn", 0.0)), float(snapshot.get("measured_twa_deg", 0.0)),
			])


func _copy_run_artifacts(checkpoint: Dictionary, destination: String, geometry: Dictionary) -> bool:
	var absolute_directory := ProjectSettings.globalize_path(destination)
	if DirAccess.make_dir_recursive_absolute(absolute_directory) != OK:
		_error = "Could not create P2.15 output directory %s" % absolute_directory
		return false
	var source_directory := str(checkpoint.get("run_directory", ""))
	for filename in ["polar_results.csv", "polar_results.json", "polar_summary.json", "polar_checkpoint.json"]:
		var source := source_directory.path_join(filename)
		if not FileAccess.file_exists(source):
			_error = "Missing test artifact %s" % source
			return false
		var file := FileAccess.open(absolute_directory.path_join(filename), FileAccess.WRITE)
		if file == null:
			_error = "Could not write P2.15 artifact %s" % filename
			return false
		file.store_string(FileAccess.get_file_as_string(source))
	var metadata: Dictionary = checkpoint.get("run_metadata", {})
	_write_json(destination.path_join("p215_manifest.json"), {
		"phase": "Nordic 28 P2.15 speed baseline",
		"test_run_id": checkpoint.get("test_run_id", ""),
		"polar_config_hash": checkpoint.get("config_hash", ""),
		"boat_config_hash": checkpoint.get("boat_config_hash", ""),
		"boat_scene_path": BOAT_SCENE,
		"boat_scene_sha256": _sha256_file(BOAT_SCENE),
		"physics_profile_path": PHYSICS_PROFILE_PATH,
		"physics_profile_sha256": _sha256_file(PHYSICS_PROFILE_PATH),
		"visual_profile_path": VISUAL_PROFILE_PATH,
		"visual_profile_sha256": _sha256_file(VISUAL_PROFILE_PATH),
		"rig_geometry": geometry,
		"conditions": metadata.get("config", {}).get("explicit_cases", []),
		"engine_state_expected": "OFF",
		"auto_trim": true,
		"wave_mode": "WaveSampler remains active; amplitude zero",
		"water_current": "zero",
		"physics_step_seconds": 1.0 / 60.0,
		"execution_acceleration": {"engine_physics_ticks_per_second": ENGINE_PHYSICS_HZ, "time_scale": ACCELERATION_SCALE, "simulated_step_seconds": 1.0 / 60.0},
		"stability_parameters": metadata.get("config", {}),
		"configuration_note": "No vessel physics/profile values were modified; only the missing P2.3c cases were run.",
	})
	return true


func _sha256_file(resource_path: String) -> String:
	var file := FileAccess.open(resource_path, FileAccess.READ)
	if file == null:
		return "UNAVAILABLE"
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(file.get_buffer(file.get_length()))
	return context.finish().hex_encode()


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
		push_error("[polar p2.15] " + message)
		quit(exit_code)
		return
	if not _error.is_empty():
		push_error("[polar p2.15] " + _error)
		quit(1)
		return
	quit(exit_code)
