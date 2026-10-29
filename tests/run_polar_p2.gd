extends SceneTree
## Formal-window Nordic 28 Polar execution. This keeps every simulated step at
## the configured 1/60 s while accelerating wall-clock execution only.

const LAB_SCENE := preload("res://scenes/SailboatLab.tscn")
const ENGINE_PHYSICS_HZ := 480
const ACCELERATION_SCALE := 8.0

var _lab: Node3D
var _runner: PolarTestRunner
var _failures: Array[String] = []
var _old_physics_hz := 60
var _old_time_scale := 1.0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var phase := "sparse"
	var resume := false
	for arg in args:
		if str(arg).begins_with("--phase="):
			phase = str(arg).trim_prefix("--phase=")
		elif str(arg) == "--resume":
			resume = true
	if phase not in ["sparse", "full"]:
		push_error("Use -- --phase=sparse or -- --phase=full")
		quit(2)
		return

	_old_physics_hz = Engine.physics_ticks_per_second
	_old_time_scale = Engine.time_scale
	Engine.physics_ticks_per_second = ENGINE_PHYSICS_HZ
	Engine.time_scale = ACCELERATION_SCALE
	_lab = LAB_SCENE.instantiate() as Node3D
	root.add_child(_lab)
	await process_frame
	_runner = _lab.get_node_or_null("PolarTestRunner") as PolarTestRunner
	if _runner == null:
		_failures.append("SailboatLab is missing PolarTestRunner")
	else:
		var config := _sparse_config() if phase == "sparse" else {}
		var started := _runner.resume_latest(config) if resume else _runner.start_new_batch(config)
		if not started:
			_failures.append("Polar batch did not start: %s" % str(_runner.get_status_snapshot().get("status", "unknown")))
		else:
			print("P2 %s scan started · fixed simulated dt=%.8f s · Engine physics=%d Hz · time_scale=%.1f" % [phase, 1.0 / 60.0, ENGINE_PHYSICS_HZ, ACCELERATION_SCALE])
			await _wait_for_batch()
			var final_state := _runner.get_status_snapshot()
			var checkpoint_path := str(final_state.get("output_path", ""))
			print("P2 %s scan finished · state=%s · cases=%d/%d · checkpoint=%s · absolute=%s" % [phase, str(final_state.get("status", "")), int(final_state.get("completed_count", 0)), int(final_state.get("case_count", 0)), checkpoint_path, ProjectSettings.globalize_path(checkpoint_path)])
			if not checkpoint_path.is_empty() and FileAccess.file_exists(checkpoint_path):
				var checkpoint: Variant = JSON.parse_string(FileAccess.get_file_as_string(checkpoint_path))
				if not checkpoint is Dictionary:
					_failures.append("Final checkpoint JSON is not valid")
				else:
					var rows: Array = checkpoint.get("results", [])
					var metadata: Dictionary = checkpoint.get("run_metadata", {})
					print("P2 metadata · run=%s · TWS=%s · rows=%d · Engine ticks=%s · scale=%s · expected dt=%s" % [
						str(checkpoint.get("test_run_id", "")), str(checkpoint.get("config", {}).get("tws_knots", [])), rows.size(),
						str(metadata.get("engine_physics_ticks_per_second", metadata.get("physics_ticks_per_second", ""))), str(metadata.get("time_scale", "")),
						str(metadata.get("physics_step_seconds", "")),
					])
					if int(final_state.get("completed_count", 0)) == int(final_state.get("case_count", -1)) and rows.is_empty():
						_failures.append("Runner reported a complete batch but checkpoint contains no rows")
	Engine.physics_ticks_per_second = _old_physics_hz
	Engine.time_scale = _old_time_scale
	if _lab != null and is_instance_valid(_lab):
		_lab.queue_free()
	if _failures.is_empty():
		quit(0)
	else:
		for failure in _failures:
			push_error("[polar p2] " + failure)
		quit(1)


func _sparse_config() -> Dictionary:
	return {
		"tws_knots": [6.0, 12.0, 20.0],
		"twa_start_degrees": 0.0,
		"twa_end_degrees": 180.0,
		"twa_step_degrees": 30.0,
		"include_port_tack": true,
		"include_starboard_tack": true,
	}


func _wait_for_batch() -> void:
	var last_case := -1
	var last_progress_usec := 0
	var guard_frames := 100000000
	while bool(_runner.get_status_snapshot().get("running", false)) and guard_frames > 0:
		await process_frame
		guard_frames -= 1
		var state := _runner.get_status_snapshot()
		var case_index := int(state.get("case_index", 0))
		var now_usec := Time.get_ticks_usec()
		if case_index != last_case or now_usec - last_progress_usec >= 15000000:
			last_case = case_index
			last_progress_usec = now_usec
			print("P2 progress · %d/%d · sim %.0f s · %s · SOG %.2f kn · TWA %+.1f°" % [
				int(state.get("completed_count", 0)), int(state.get("case_count", 0)),
				float(state.get("simulation_seconds", 0.0)), str(state.get("current_case_id", "")),
				float(state.get("sog_kn", 0.0)), float(state.get("measured_twa_deg", 0.0)),
			])
	if guard_frames <= 0:
		_failures.append("P2 batch exceeded the headless harness frame guard")
		_runner.request_stop()
