extends SceneTree

const MAIN_SCENE := preload("res://scenes/main.tscn")
const OUTPUT_PATH := "res://docs/fish_resources/performance.txt"
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
	var camera_rig := main_root.get_node("PlayerBoat/FollowCameraRig") as Node3D
	var camera := main_root.get_node("PlayerBoat/FollowCameraRig/Camera3D") as Camera3D
	boat.set_physics_process(false)
	boat.set_process(false)
	camera_rig.set_process(false)
	manager.set_process(false)
	var hotspot := _densest_school_cluster(manager, 1200.0)
	if not hotspot.is_empty():
		var position_values: Array = hotspot["center"]["world_position"]
		var school_position := Vector3(float(position_values[0]), 0.0, float(position_values[2]))
		boat.global_position = school_position + Vector3(500.0, 0.0, 500.0)
		camera_rig.global_position = school_position + Vector3(0.0, 10.0, 10.0)
		camera_rig.look_at(Vector3(school_position.x, -2.0, school_position.z), Vector3.UP)
		camera.position = Vector3.ZERO
		camera.rotation = Vector3.ZERO
		camera.fov = 50.0
		camera.make_current()
	else:
		push_warning("No fish school cluster available; measuring the startup camera position.")

	var conditions := [
		{"name": "A_renderer_off", "visible": false, "animation": false, "cap": 360},
		{"name": "B_renderer_on_animation_off", "visible": true, "animation": false, "cap": 360},
		{"name": "C_renderer_on_animation_on", "visible": true, "animation": true, "cap": 360},
		{"name": "D_renderer_on_dense_cap_700", "visible": true, "animation": true, "cap": 700},
	]
	var lines := PackedStringArray()
	lines.append("FishResourceManager / MultiMesh A-B benchmark")
	lines.append("Godot 4.7.2 Forward+ / Metal · M2 Pro · external power connected")
	lines.append("Viewport 1920x1080 · scene main.tscn · camera fixed over densest real resource cluster within 1200m · daylight/weather left at startup")
	lines.append("GPU time is not exposed by this benchmark; frame timing is whole-engine wall time, not GPU-only.")
	lines.append("Warmup %.1fs; sample %.1fs per repeat; %d repeats per condition; local resources frozen during the comparison." % [WARMUP_SECONDS, SAMPLE_SECONDS, REPEAT_COUNT])
	for condition in conditions:
		var repeats: Array[Dictionary] = []
		for repeat_index in range(REPEAT_COUNT):
			renderer.visible = bool(condition["visible"])
			renderer.set_process(bool(condition["visible"]))
			renderer.set_animation_enabled(bool(condition["animation"]))
			renderer.maximum_visible_fish = int(condition["cap"])
			await create_timer(WARMUP_SECONDS).timeout
			var sample := await _sample_condition(renderer, SAMPLE_SECONDS)
			var stats := renderer.get_render_statistics()
			var result := {
				"average_fps": float(sample["average_fps"]),
				"average_frame_ms": float(sample["average_frame_ms"]),
				"p95_ms": float(sample["p95_ms"]),
				"p99_ms": float(sample["p99_ms"]),
				"worst_ms": float(sample["worst_ms"]),
				"average_draw_calls": float(sample["average_draw_calls"]),
				"fish_update_ms": float(stats["last_update_ms"]),
			}
			repeats.append(result)
			lines.append("%s repeat %d: avg_fps=%.2f avg_frame_ms=%.2f p95_ms=%.2f p99_ms=%.2f worst_ms=%.2f avg_draw_calls=%.1f visible_fish=%d fish_triangles=%d batches=%d fish_update_ms=%.3f" % [
			str(condition["name"]),
			repeat_index + 1,
			result["average_fps"], result["average_frame_ms"], result["p95_ms"], result["p99_ms"], result["worst_ms"],
			result["average_draw_calls"], int(stats["visible_fish"]), int(stats["triangles"]), int(stats["multimesh_batches"]), result["fish_update_ms"],
		])
			print("[FISH_BENCH] " + lines[-1])
		var last_stats := renderer.get_render_statistics()
		var summary := _average_repeats(repeats)
		lines.append("%s mean of %d repeats: avg_fps=%.2f avg_frame_ms=%.2f mean_repeat_p95_ms=%.2f mean_repeat_p99_ms=%.2f worst_ms=%.2f avg_draw_calls=%.1f visible_fish=%d fish_triangles=%d batches=%d fish_update_ms=%.3f" % [
			str(condition["name"]), REPEAT_COUNT,
			float(summary["average_fps"]), float(summary["average_frame_ms"]), float(summary["p95_ms"]), float(summary["p99_ms"]), float(summary["worst_ms"]),
			float(summary["average_draw_calls"]), int(last_stats["visible_fish"]), int(last_stats["triangles"]), int(last_stats["multimesh_batches"]), float(summary["fish_update_ms"]),
		])
		print("[FISH_BENCH] " + lines[-1])
	var cluster: Dictionary = hotspot.get("center", {})
	lines.append("Benchmark cluster center: %s; schools=%d; fish_population=%d; nearby_chart_depth_m=%.2f" % [
		str(cluster.get("school_id", "none")), int(hotspot.get("school_count", 0)), int(hotspot.get("population", 0)), float(hotspot.get("depth_m", 0.0))
	])
	lines.append("Dense condition raises the visible-fish cap to 700; actual count is reported per condition and is limited by local resource population and species shares.")
	var absolute_output := ProjectSettings.globalize_path(OUTPUT_PATH)
	DirAccess.make_dir_recursive_absolute(absolute_output.get_base_dir())
	var file := FileAccess.open(absolute_output, FileAccess.WRITE)
	file.store_string("\n".join(lines) + "\n")
	print("[FISH_BENCH] wrote %s" % absolute_output)
	quit(0)


func _sample_condition(renderer: FishSchoolRenderer, sample_seconds: float) -> Dictionary:
	var intervals_ms: Array[float] = []
	var draw_calls: Array[float] = []
	var previous_usec := Time.get_ticks_usec()
	var start_usec := previous_usec
	while float(Time.get_ticks_usec() - start_usec) / 1000000.0 < sample_seconds:
		await process_frame
		var now_usec := Time.get_ticks_usec()
		var elapsed_ms := float(now_usec - previous_usec) / 1000.0
		previous_usec = now_usec
		intervals_ms.append(elapsed_ms)
		draw_calls.append(float(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
	intervals_ms.sort()
	draw_calls.sort()
	var sum_ms := 0.0
	for value in intervals_ms:
		sum_ms += value
	var average_ms := sum_ms / maxf(float(intervals_ms.size()), 1.0)
	return {
		"average_fps": 1000.0 / maxf(average_ms, 0.001),
		"average_frame_ms": average_ms,
		"p95_ms": _percentile(intervals_ms, 0.95),
		"p99_ms": _percentile(intervals_ms, 0.99),
		"worst_ms": intervals_ms.back() if not intervals_ms.is_empty() else 0.0,
		"average_draw_calls": _average(draw_calls),
	}


func _densest_school_cluster(manager: FishResourceManager, radius_m: float) -> Dictionary:
	var schools := manager.get_all_school_snapshots()
	var best: Dictionary = {}
	var best_population := -1
	var best_school_count := 0
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
			best_school_count = school_count
			best = {"center": center, "population": population, "school_count": school_count}
	var position_values: Array = best.get("center", {}).get("world_position", [0.0, 0.0, 0.0])
	if not best.is_empty():
		var depth := manager.get_bathymetry_manager().get_depth_at_world_position(Vector3(float(position_values[0]), 0.0, float(position_values[2])))
		best["depth_m"] = float(depth.get("depth_m", 0.0))
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
	var result := {
		"average_fps": 0.0,
		"average_frame_ms": 0.0,
		"p95_ms": 0.0,
		"p99_ms": 0.0,
		"worst_ms": 0.0,
		"average_draw_calls": 0.0,
		"fish_update_ms": 0.0,
	}
	for repeat in repeats:
		for key in result.keys():
			if key == "worst_ms":
				result[key] = maxf(float(result[key]), float(repeat[key]))
			else:
				result[key] += float(repeat[key])
	for key in result.keys():
		if key != "worst_ms":
			result[key] = float(result[key]) / maxf(float(repeats.size()), 1.0)
	return result
