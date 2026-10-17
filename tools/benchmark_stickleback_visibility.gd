extends SceneTree

const MAIN_SCENE := preload("res://scenes/main.tscn")
const SPECIES_ID := "three_spined_stickleback"
const REPORT_PATH := "res://docs/fish_resources/stickleback_visibility/performance.txt"
const SAMPLE_SECONDS := 3.0
const WARMUP_SECONDS := 1.5
const REPEATS := 3

var _sample_renderer: FishSchoolRenderer


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_root := MAIN_SCENE.instantiate()
	root.add_child(main_root)
	await process_frame
	await create_timer(1.0).timeout
	var manager := main_root.get_node("FishResourceManager") as FishResourceManager
	var renderer := main_root.get_node("FishResourceManager/FishSchoolRenderer") as FishSchoolRenderer
	_sample_renderer = renderer
	var hud := main_root.get_node("PlayerBoat/BoatHUD")
	var boat := main_root.get_node("PlayerBoat/MotionRoot") as BoatController
	var quality := main_root.get_node("QualityManager") as QualityManager
	quality.set_quality_for_benchmark(QualityManager.Quality.HIGH)
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	boat.speed_mps = 0.0
	boat.is_motion_paused = true
	hud.call("_on_fish_observation_pressed", SPECIES_ID)
	await create_timer(2.0).timeout
	if not renderer.is_observation_active():
		push_error("Could not activate the real stickleback observation camera for benchmark.")
		quit(1)
		return

	var conditions := [
		{"name": "Fish render + AI OFF", "enabled": false},
		{"name": "Fish render + AI ON", "enabled": true},
	]
	var condition_results: Dictionary = {}
	for repeat_index in range(REPEATS):
		for condition in conditions:
			var enabled := bool(condition["enabled"])
			renderer.visible = enabled
			renderer.process_mode = Node.PROCESS_MODE_INHERIT if enabled else Node.PROCESS_MODE_DISABLED
			await create_timer(WARMUP_SECONDS).timeout
			var result := await _sample_condition()
			var name := str(condition["name"])
			if not condition_results.has(name):
				condition_results[name] = []
			condition_results[name].append(result)
			print("[STICKLEBACK_BENCH] repeat=%d condition=%s result=%s" % [repeat_index + 1, name, result])
	renderer.process_mode = Node.PROCESS_MODE_INHERIT
	renderer.visible = true
	var report := _format_report(condition_results, quality.get_quality_name(), DisplayServer.window_get_size())
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(REPORT_PATH.get_base_dir()))
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(report)
		file.close()
	print(report)
	print("[STICKLEBACK_BENCH] report_saved=%s" % ProjectSettings.globalize_path(REPORT_PATH))
	quit(0)


func _sample_condition() -> Dictionary:
	var frame_ms: Array[float] = []
	var draw_calls: Array[float] = []
	var primitives: Array[float] = []
	var ai_ms: Array[float] = []
	var submit_ms: Array[float] = []
	var visible_fish := 0
	var triangles := 0
	var elapsed := 0.0
	var previous_usec := Time.get_ticks_usec()
	while elapsed < SAMPLE_SECONDS:
		await process_frame
		var now_usec := Time.get_ticks_usec()
		var step_ms := float(now_usec - previous_usec) / 1000.0
		previous_usec = now_usec
		elapsed += step_ms / 1000.0
		frame_ms.append(step_ms)
		draw_calls.append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		primitives.append(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
		var stats := _sample_renderer.get_render_statistics() if _sample_renderer != null else {}
		visible_fish = int(stats.get("visible_fish", visible_fish))
		triangles = int(stats.get("triangles", triangles))
		if _sample_renderer.process_mode == Node.PROCESS_MODE_DISABLED:
			ai_ms.append(0.0)
			submit_ms.append(0.0)
		else:
			ai_ms.append(float(stats.get("ai_update_ms", 0.0)))
			submit_ms.append(float(stats.get("multimesh_submit_ms", 0.0)))
	return {
		"frames": frame_ms.size(),
		"avg_fps": 1000.0 / _mean(frame_ms),
		"avg_frame_ms": _mean(frame_ms),
		"p95_frame_ms": _percentile(frame_ms, 0.95),
		"p99_frame_ms": _percentile(frame_ms, 0.99),
		"worst_frame_ms": _maximum(frame_ms),
		"avg_draw_calls": _mean(draw_calls),
		"avg_primitives": _mean(primitives),
		"visible_fish": visible_fish,
		"fish_triangles": triangles,
		"avg_ai_update_ms": _mean(ai_ms),
		"avg_multimesh_submit_ms": _mean(submit_ms),
	}


func _format_report(results: Dictionary, quality_name: String, viewport_size: Vector2i) -> String:
	var lines := PackedStringArray()
	lines.append("Stickleback local rendering cost benchmark")
	lines.append("Date: %s" % Time.get_datetime_string_from_system(true))
	lines.append("Device: Apple M2 Pro · Godot 4.7.2 · Forward+ / Metal 3.2")
	lines.append("Resolution: %dx%d · Quality: %s · repeats: %d × %.1fs measured (%.1fs warmup)" % [viewport_size.x, viewport_size.y, quality_name, REPEATS, SAMPLE_SECONDS, WARMUP_SECONDS])
	lines.append("Method: same main scene, F3 safe observation placement, same stopped boat/camera and weather; renderer and its AI processing disabled/enabled; VSync disabled and Engine.max_fps=0. GPU time is unavailable from the current public project instrumentation.")
	lines.append("Frame-time samples include the full frame; draw calls/primitives are Performance monitors. Fish AI / MultiMesh timings come from FishSchoolRenderer's own microsecond timers.")
	for name in ["Fish render + AI OFF", "Fish render + AI ON"]:
		var entries: Array = results.get(name, [])
		var aggregate: Dictionary = _aggregate(entries)
		lines.append("%s: avg %.1f FPS, %.2f ms/frame, P95 %.2f ms, P99 %.2f ms, worst %.2f ms; draw calls %.1f; primitives %.0f; visible fish %d; fish triangles %d; AI %.3f ms/tick; MultiMesh submit %.3f ms/update" % [name, float(aggregate.get("avg_fps", 0.0)), float(aggregate.get("avg_frame_ms", 0.0)), float(aggregate.get("p95_frame_ms", 0.0)), float(aggregate.get("p99_frame_ms", 0.0)), float(aggregate.get("worst_frame_ms", 0.0)), float(aggregate.get("avg_draw_calls", 0.0)), float(aggregate.get("avg_primitives", 0.0)), int(aggregate.get("visible_fish", 0)), int(aggregate.get("fish_triangles", 0)), float(aggregate.get("avg_ai_update_ms", 0.0)), float(aggregate.get("avg_multimesh_submit_ms", 0.0))])
	return "\n".join(lines) + "\n"


func _aggregate(entries: Array) -> Dictionary:
	var keys := ["avg_fps", "avg_frame_ms", "p95_frame_ms", "p99_frame_ms", "worst_frame_ms", "avg_draw_calls", "avg_primitives", "visible_fish", "fish_triangles", "avg_ai_update_ms", "avg_multimesh_submit_ms"]
	var output: Dictionary = {}
	for key in keys:
		var total := 0.0
		for entry in entries:
			total += float(entry.get(key, 0.0))
		output[key] = total / float(maxi(1, entries.size()))
	return output


func _mean(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for value in values:
		total += value
	return total / float(values.size())


func _percentile(values: Array[float], fraction: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[clampi(ceili(float(sorted.size()) * fraction) - 1, 0, sorted.size() - 1)]


func _maximum(values: Array[float]) -> float:
	var result := 0.0
	for value in values:
		result = maxf(result, value)
	return result
