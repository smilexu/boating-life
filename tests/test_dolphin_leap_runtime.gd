extends SceneTree

const DOLPHIN_VISUAL_SCRIPT := preload("res://scripts/dolphin_visual.gd")
const LEAP_TRAJECTORY_SCRIPT := preload("res://scripts/dolphin_leap_trajectory.gd")

const GRAVITY := 9.81 * 0.8
const START_DEPTH := 0.62
const APEX := 0.95


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if not await _test_visual_trajectory():
		quit(1)
		return
	if not await _test_follow_event():
		quit(1)
		return
	print("DOLPHIN_LEAP_RUNTIME_TEST: PASS")
	quit(0)


func _test_visual_trajectory() -> bool:
	var initial_speed: float = LEAP_TRAJECTORY_SCRIPT.initial_vertical_speed(APEX, START_DEPTH, GRAVITY)
	var duration: float = LEAP_TRAJECTORY_SCRIPT.water_entry_time(initial_speed, START_DEPTH, GRAVITY)
	var apex_time := initial_speed / GRAVITY
	var fps_results: Dictionary = {}
	for fps in [30, 60]:
		var result := await _sample_visual_at_rate(int(fps), initial_speed, duration, apex_time)
		if not bool(result.get("valid", false)):
			return false
		fps_results[fps] = result
	var peak_error := absf(float(fps_results[30]["peak_y"]) - float(fps_results[60]["peak_y"]))
	if peak_error > 0.015:
		push_error("Leap peak changed with frame rate: %.4f m" % peak_error)
		return false
	var expected_apex_y := APEX
	if absf(float(fps_results[60]["peak_y"]) - expected_apex_y) > 0.02:
		push_error("Leap apex does not match requested height: %.3f m" % float(fps_results[60]["peak_y"]))
		return false
	print("Leap Transform trace (60 FPS): start y=-%.2f m, vy=+%.2f m/s; apex t=%.2f s, y=%.2f m, vy≈0; water entry t=%.2f s, vy=%.2f m/s" % [
		START_DEPTH,
		initial_speed,
		apex_time,
		float(fps_results[60]["peak_y"]),
		duration,
		LEAP_TRAJECTORY_SCRIPT.vertical_speed_at(initial_speed, GRAVITY, duration),
	])
	print("Visual Transform writer: %s" % str(fps_results[60]["writer"]))
	return str(fps_results[60]["writer"]) == "DolphinVisual.advance_visual"


func _sample_visual_at_rate(fps: int, initial_speed: float, duration: float, apex_time: float) -> Dictionary:
	var source_model := Node3D.new()
	var mesh := MeshInstance3D.new()
	mesh.mesh = SphereMesh.new()
	source_model.add_child(mesh)
	mesh.owner = source_model
	var packed_model := PackedScene.new()
	if packed_model.pack(source_model) != OK:
		push_error("Unable to build test dolphin visual scene.")
		source_model.free()
		return {"valid": false}
	source_model.free()
	var approach_snapshot := {
		"dolphin_id": "trajectory_test",
		"behavior_state": "leap_approach",
		"world_position": [10.0, 0.0, 20.0],
		"direction": [0.0, 1.0],
		"activity_depth_m": START_DEPTH,
		"movement_speed_mps": 3.0,
		"last_updated": 0.0,
	}
	var visual := DOLPHIN_VISUAL_SCRIPT.new() as DolphinVisual
	root.add_child(visual)
	if not visual.configure(packed_model, approach_snapshot, 2.65, 0.0):
		visual.queue_free()
		return {"valid": false}
	var leap_snapshot: Dictionary = approach_snapshot.duplicate(true)
	leap_snapshot.merge({
		"behavior_state": "leap",
		"state_elapsed": 0.0,
		"event_revision": 1,
		"world_position": [10.0, -START_DEPTH, 20.0],
		"surface_height_y": 0.0,
		"leap_origin_xz": [10.0, 20.0],
		"leap_direction": [0.0, 1.0],
		"leap_horizontal_speed_mps": 3.0,
		"leap_started_at": 0.0,
		"leap_start_world_y": -START_DEPTH,
		"leap_start_depth_m": START_DEPTH,
		"leap_apex_m": APEX,
		"leap_initial_velocity_mps": initial_speed,
		"leap_duration_s": duration,
	}, true)
	visual.set_snapshot(leap_snapshot)
	var step := 1.0 / float(fps)
	var elapsed := 0.0
	var previous_y := -START_DEPTH
	var saw_ascent := false
	var saw_descent := false
	var peak_y := -INF
	var minimum_forward_alignment := 1.0
	while elapsed <= duration:
		visual.advance_visual(step, elapsed, 0.0)
		var y := visual.global_position.y
		var motion := visual.get_motion_debug()
		var expected_forward := Vector3(0.0, float(motion["vertical_speed"]), 3.0).normalized()
		var actual_forward := -visual.global_transform.basis.z.normalized()
		minimum_forward_alignment = minf(minimum_forward_alignment, actual_forward.dot(expected_forward))
		peak_y = maxf(peak_y, y)
		if elapsed > 0.0 and elapsed < apex_time - 0.05:
			if y <= previous_y:
				push_error("Actual visual Transform failed to rise during ascent at %d FPS." % fps)
				visual.queue_free()
				return {"valid": false}
			saw_ascent = saw_ascent or float(motion["vertical_speed"]) > 0.0
		if elapsed > apex_time + 0.05:
			if y >= previous_y:
				push_error("Actual visual Transform failed to descend after apex at %d FPS." % fps)
				visual.queue_free()
				return {"valid": false}
			saw_descent = saw_descent or float(motion["vertical_speed"]) < 0.0
		previous_y = y
		elapsed += step
	var writer := str(visual.get_motion_debug().get("transform_writer", ""))
	visual.queue_free()
	if minimum_forward_alignment < 0.96:
		push_error("Dolphin body orientation did not follow the Leap velocity tangent at %d FPS: dot=%.3f" % [fps, minimum_forward_alignment])
		return {"valid": false}
	return {"valid": saw_ascent and saw_descent, "peak_y": peak_y, "writer": writer}


func _test_follow_event() -> bool:
	var main_scene := load("res://scenes/main.tscn") as PackedScene
	if main_scene == null:
		push_error("Unable to load the main scene for the follow event test.")
		return false
	var main := main_scene.instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	var manager := main.get_node_or_null("DolphinWorldManager")
	var boat := main.get_node_or_null("PlayerBoat/MotionRoot") as Node3D
	if manager == null or boat == null:
		push_error("Main scene is missing DolphinWorldManager or PlayerBoat/MotionRoot.")
		main.queue_free()
		return false
	manager.set_process(false)
	var summon: Dictionary = manager.call("debug_summon_follow", boat)
	if not bool(summon.get("accepted", false)):
		push_error("Unable to start the F3 follow test: %s" % str(summon.get("reason", "unknown")))
		main.queue_free()
		return false
	var authority: DolphinLocalAuthority = manager.get("_authority") as DolphinLocalAuthority
	if authority == null:
		push_error("Follow test has no local dolphin authority.")
		main.queue_free()
		return false
	var seen_leap_events: Dictionary = {}
	var leap_start_times: Dictionary = {}
	var trajectory_signs: Dictionary = {}
	var trajectory_rows: Dictionary = {}
	for _step in range(800):
		manager.call("_process", 0.1)
		for snapshot in authority.get_dolphin_snapshots():
			var dolphin_id := str(snapshot.get("dolphin_id", ""))
			var event_revision := int(snapshot.get("event_revision", 0))
			if str(snapshot.get("event_type", "")) == "leap_start":
				var event_key := "%s:%d" % [dolphin_id, event_revision]
				seen_leap_events[event_key] = true
				leap_start_times[event_key] = float(snapshot.get("leap_started_at", 0.0))
			if str(snapshot.get("behavior_state", "")) == "leap":
				var visuals: Dictionary = manager.get("_visuals")
				var visual: DolphinVisual = visuals.get(dolphin_id) as DolphinVisual
				if visual != null:
					var motion: Dictionary = visual.get_motion_debug()
					var key := "%s:%d" % [dolphin_id, event_revision]
					var signs: Dictionary = trajectory_signs.get(key, {"up": false, "down": false, "samples": 0})
					signs["up"] = bool(signs["up"]) or float(motion.get("vertical_speed", 0.0)) > 0.1
					signs["down"] = bool(signs["down"]) or float(motion.get("vertical_speed", 0.0)) < -0.1
					signs["samples"] = int(signs["samples"]) + 1
					trajectory_signs[key] = signs
					var rows: Array = trajectory_rows.get(key, [])
					rows.append({
						"t": float(motion.get("leap_elapsed", 0.0)),
						"y": float(motion.get("world_y", 0.0)),
						"vy": float(motion.get("vertical_speed", 0.0)),
					})
					trajectory_rows[key] = rows
	var status: Dictionary = manager.call("get_debug_status")
	var started := int(status.get("follow_leaps_started", 0))
	var completed := int(status.get("follow_leaps_completed", 0))
	var target := int(status.get("follow_leaps_scheduled", 0))
	var valid_traces := 0
	for signs in trajectory_signs.values():
		if bool(signs["up"]) and bool(signs["down"]) and int(signs["samples"]) >= 4:
			valid_traces += 1
	var sorted_start_times: Array = leap_start_times.values()
	sorted_start_times.sort()
	var min_start_gap := INF
	for index in range(1, sorted_start_times.size()):
		min_start_gap = minf(min_start_gap, float(sorted_start_times[index]) - float(sorted_start_times[index - 1]))
	print("75s F3 follow runtime: scheduled=%d, leap starts=%d, completed=%d, observed Transform traces=%d, minimum stagger=%.1f s" % [target, started, completed, valid_traces, min_start_gap])
	for key in trajectory_rows:
		var rows: Array = trajectory_rows[key]
		if rows.size() >= 4:
			var apex_row: Dictionary = rows[0]
			for row in rows:
				if float(row["y"]) > float(apex_row["y"]):
					apex_row = row
			print("Runtime Transform sample %s: t=%.2f y=%.2f vy=%.2f | apex t=%.2f y=%.2f vy=%.2f | last t=%.2f y=%.2f vy=%.2f" % [
				key,
				float(rows[0]["t"]), float(rows[0]["y"]), float(rows[0]["vy"]),
				float(apex_row["t"]), float(apex_row["y"]), float(apex_row["vy"]),
				float(rows[-1]["t"]), float(rows[-1]["y"]), float(rows[-1]["vy"]),
			])
			break
	main.queue_free()
	return started >= 6 and started <= 8 and completed >= 6 and valid_traces >= 6 and seen_leap_events.size() >= 6 and min_start_gap >= 4.9
