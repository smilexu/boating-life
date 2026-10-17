extends SceneTree

const MAIN_SCENE := preload("res://scenes/main.tscn")
const OUTPUT_PATH := "res://docs/fish_resources/motion_smoothing_performance.txt"
const FPS_CAPS := [30, 60, 120]
const SMOOTHING_MODES := [false, true]
const WARMUP_SECONDS := 1.0
const SAMPLE_SECONDS := 3.0
const REPEAT_COUNT := 3


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_root := MAIN_SCENE.instantiate()
	root.add_child(main_root)
	await create_timer(5.0).timeout
	var manager := main_root.get_node("FishResourceManager") as FishResourceManager
	var renderer := main_root.get_node("FishResourceManager/FishSchoolRenderer") as FishSchoolRenderer
	var boat := main_root.get_node("PlayerBoat/MotionRoot") as Node3D
	boat.set_physics_process(false)
	boat.set_process(false)
	manager.set_process(false)
	var hotspot := _densest_school_cluster(manager, 1200.0)
	if not hotspot.is_empty():
		var values: Array = hotspot["world_position"]
		var school_position := Vector3(float(values[0]), 0.0, float(values[2]))
		boat.global_position = school_position + Vector3(500.0, 0.0, 500.0)
		var observation_started := renderer.begin_observation(str(hotspot["school_id"]))
		if not observation_started:
			push_warning("Could not start the underwater fish observation camera; benchmark will use the current camera.")

	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var lines := PackedStringArray()
	lines.append("Fish visual smoothing A/B benchmark")
	lines.append("Godot 4.7.2 Forward+ / Metal · Apple M2 Pro · plugged into power")
	lines.append("1920x1080 project viewport · FishObservationCamera at the densest real school cluster within 1200m")
	lines.append("Same weather, time and scene for all runs; local authority and boat movement frozen; animation shader enabled.")
	lines.append("VSync disabled for controlled 30/60/120 FPS caps. GPU-only timing is unavailable; frame metrics include whole-engine/render wall time.")
	lines.append("AI tick remains %.2f Hz (%.3fs). Warmup %.1fs, sample %.1fs, repeats %d." % [1.0 / renderer.movement_update_interval, renderer.movement_update_interval, WARMUP_SECONDS, SAMPLE_SECONDS, REPEAT_COUNT])
	for fps_cap in FPS_CAPS:
		Engine.max_fps = fps_cap
		for smoothing_enabled in SMOOTHING_MODES:
			renderer.maximum_visible_fish = 360
			renderer.visible = true
			renderer.set_process(true)
			renderer.set_animation_enabled(true)
			renderer.set_smooth_motion_enabled(smoothing_enabled)
			var repeats: Array[Dictionary] = []
			for repeat_index in range(REPEAT_COUNT):
				await create_timer(WARMUP_SECONDS).timeout
				var sample := await _sample_condition(renderer, SAMPLE_SECONDS)
				var stats := renderer.get_render_statistics()
				sample["visible_fish"] = int(stats["visible_fish"])
				sample["triangles"] = int(stats["triangles"])
				sample["draw_calls"] = float(sample["average_draw_calls"])
				repeats.append(sample)
				var label := "cap_%d_%s" % [fps_cap, "smooth_on" if smoothing_enabled else "smooth_off"]
				lines.append("%s repeat %d: fps=%.2f frame_ms=%.3f p95_ms=%.3f p99_ms=%.3f worst_ms=%.3f draw_calls=%.1f fish=%d triangles=%d ai_ms=%.3f multimesh_tick_submit_ms=%.3f visual_submit_ms=%.4f" % [
					label, repeat_index + 1,
					float(sample["average_fps"]), float(sample["average_frame_ms"]), float(sample["p95_ms"]), float(sample["p99_ms"]), float(sample["worst_ms"]),
					float(sample["average_draw_calls"]), int(stats["visible_fish"]), int(stats["triangles"]),
					float(sample["ai_update_ms"]), float(sample["tick_submit_ms"]), float(sample["visual_submit_ms"]),
				])
				print("[FISH_SMOOTH_BENCH] " + lines[-1])
			var summary := _average_repeats(repeats)
			var final_stats := renderer.get_render_statistics()
			lines.append("cap_%d_%s mean: fps=%.2f frame_ms=%.3f p95_ms=%.3f p99_ms=%.3f worst_ms=%.3f draw_calls=%.1f fish=%d triangles=%d ai_ms=%.3f multimesh_tick_submit_ms=%.3f visual_submit_ms=%.4f" % [
				fps_cap, "smooth_on" if smoothing_enabled else "smooth_off",
				float(summary["average_fps"]), float(summary["average_frame_ms"]), float(summary["p95_ms"]), float(summary["p99_ms"]), float(summary["worst_ms"]),
				float(summary["average_draw_calls"]), int(final_stats["visible_fish"]), int(final_stats["triangles"]),
				float(summary["ai_update_ms"]), float(summary["tick_submit_ms"]), float(summary["visual_submit_ms"]),
			])
			print("[FISH_SMOOTH_BENCH] " + lines[-1])
	lines.append("Cluster: %s, schools=%d, logical fish=%d, chart depth=%.2fm." % [
		str(hotspot.get("school_id", "none")), int(hotspot.get("school_count", 0)), int(hotspot.get("population", 0)), float(hotspot.get("depth_m", 0.0)),
	])
	Engine.max_fps = 0
	var absolute_output := ProjectSettings.globalize_path(OUTPUT_PATH)
	DirAccess.make_dir_recursive_absolute(absolute_output.get_base_dir())
	var file := FileAccess.open(absolute_output, FileAccess.WRITE)
	file.store_string("\n".join(lines) + "\n")
	print("[FISH_SMOOTH_BENCH] wrote %s" % absolute_output)
	quit(0)


func _sample_condition(renderer: FishSchoolRenderer, sample_seconds: float) -> Dictionary:
	var frame_ms: Array[float] = []
	var draw_calls: Array[float] = []
	var ai_samples: Array[float] = []
	var tick_submit_samples: Array[float] = []
	var visual_submit_samples: Array[float] = []
	var previous_tick := int(renderer.get_motion_timing_snapshot()["movement_tick_count"])
	var previous_usec := Time.get_ticks_usec()
	var start_usec := previous_usec
	while float(Time.get_ticks_usec() - start_usec) / 1000000.0 < sample_seconds:
		await process_frame
		var now_usec := Time.get_ticks_usec()
		frame_ms.append(float(now_usec - previous_usec) / 1000.0)
		previous_usec = now_usec
		draw_calls.append(float(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
		var motion := renderer.get_motion_timing_snapshot()
		var tick_count := int(motion["movement_tick_count"])
		if tick_count != previous_tick:
			ai_samples.append(float(motion["ai_update_ms"]))
			tick_submit_samples.append(float(motion["multimesh_submit_ms"]))
			previous_tick = tick_count
		if bool(motion["smooth_motion_enabled"]):
			visual_submit_samples.append(float(motion["visual_update_ms"]))
	frame_ms.sort()
	return {
		"average_fps": 1000.0 / maxf(_average(frame_ms), 0.001),
		"average_frame_ms": _average(frame_ms),
		"p95_ms": _percentile(frame_ms, 0.95),
		"p99_ms": _percentile(frame_ms, 0.99),
		"worst_ms": frame_ms.back() if not frame_ms.is_empty() else 0.0,
		"average_draw_calls": _average(draw_calls),
		"ai_update_ms": _average(ai_samples),
		"tick_submit_ms": _average(tick_submit_samples),
		"visual_submit_ms": _average(visual_submit_samples),
	}


func _densest_school_cluster(manager: FishResourceManager, radius_m: float) -> Dictionary:
	var schools := manager.get_all_school_snapshots()
	var best: Dictionary = {}
	var best_population := -1
	var best_count := 0
	var radius_squared := radius_m * radius_m
	for center in schools:
		var center_values: Array = center["world_position"]
		var center_x := float(center_values[0])
		var center_z := float(center_values[2])
		var population := 0
		var school_count := 0
		for school in schools:
			var values: Array = school["world_position"]
			var dx := float(values[0]) - center_x
			var dz := float(values[2]) - center_z
			if dx * dx + dz * dz <= radius_squared:
				population += int(school["population"])
				school_count += 1
		if population > best_population:
			best_population = population
			best_count = school_count
			best = center.duplicate(true)
	if not best.is_empty():
		var position_values: Array = best["world_position"]
		var depth := manager.get_bathymetry_manager().get_depth_at_world_position(Vector3(float(position_values[0]), 0.0, float(position_values[2])))
		best["depth_m"] = float(depth.get("depth_m", 0.0))
		best["school_count"] = best_count
		best["population"] = best_population
	return best


func _percentile(values: Array[float], ratio: float) -> float:
	if values.is_empty():
		return 0.0
	var index := clampi(ceili(float(values.size()) * ratio) - 1, 0, values.size() - 1)
	return values[index]


func _average(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for value in values:
		total += value
	return total / float(values.size())


func _average_repeats(repeats: Array[Dictionary]) -> Dictionary:
	var result := {"average_fps": 0.0, "average_frame_ms": 0.0, "p95_ms": 0.0, "p99_ms": 0.0, "worst_ms": 0.0, "average_draw_calls": 0.0, "ai_update_ms": 0.0, "tick_submit_ms": 0.0, "visual_submit_ms": 0.0}
	for repeat in repeats:
		for key in result.keys():
			if key == "worst_ms":
				result[key] = maxf(float(result[key]), float(repeat[key]))
			else:
				result[key] = float(result[key]) + float(repeat[key])
	for key in result.keys():
		if key != "worst_ms":
			result[key] = float(result[key]) / maxf(float(repeats.size()), 1.0)
	return result
