extends SceneTree
## Measures renderer frame intervals in a fixed production scene before/after
## the continuous day/night visual update. Run with Godot's graphical renderer.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const OUTPUT_PATH := "res://docs/day_night_continuity/performance_after.json"

var _samples: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var manager := root.get_node_or_null("WorldTimeManager")
	if manager == null:
		push_error("WorldTimeManager autoload is not available.")
		quit(1)
		return
	var original_snapshot: Dictionary = manager.call("create_snapshot")
	var original_autosave := bool(manager.get("autosave_enabled"))
	manager.set("autosave_enabled", false)
	var old_vsync := DisplayServer.window_get_vsync_mode()
	var old_max_fps := Engine.max_fps
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	var main := MAIN_SCENE.instantiate()
	root.add_child(main)
	await _wait_frames(25)
	var quality := main.get_node("QualityManager") as QualityManager
	var boat := main.get_node("PlayerBoat")
	var motion_root := boat.get_node("MotionRoot") as Node3D
	var visual_root := boat.get_node("MotionRoot/VisualRoot") as Node3D
	var camera_rig := boat.get_node("FollowCameraRig") as Node3D
	var camera := boat.get_node("FollowCameraRig/Camera3D") as Camera3D
	var water := (main.get_node("BathymetryManager") as BathymetryManager).water_material
	quality.set_quality_for_benchmark(QualityManager.Quality.HIGH)
	motion_root.set_process(false)
	motion_root.set_physics_process(false)
	visual_root.set_process(false)
	visual_root.set_physics_process(false)
	camera_rig.set_process(false)
	camera_rig.set_physics_process(false)
	camera.make_current()
	water.set_shader_parameter("freeze_time", true)
	manager.call("pause_time")
	manager.call("set_time_scale", 24.0)
	var cases := [
		{"name": "summer_noon", "month": 7, "hour": 12},
		{"name": "summer_sunset", "month": 7, "hour": 22},
		{"name": "winter_noon", "month": 12, "hour": 12},
		{"name": "winter_night", "month": 12, "hour": 23},
	]
	for case in cases:
		manager.call("set_calendar_date", 2026, int(case["month"]), 15)
		manager.call("set_day_cycle_time", int(case["hour"]), 0)
		await _wait_frames(90)
		_samples.append(await _measure(str(case["name"]), 240))

	var report := {
		"engine": Engine.get_version_info(),
		"renderer": RenderingServer.get_video_adapter_name(),
		"processor": OS.get_processor_name(),
		"window_size": [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y],
		"quality": "High",
		"weather": "Clear",
		"vsync_during_measurement": "disabled",
		"fps_cap_during_measurement": "unlimited",
		"gpu_time_ms": "not exposed by the runtime Performance monitors used here",
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"cases": _samples,
	}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs/day_night_continuity"))
	var file := FileAccess.open(OUTPUT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t") + "\n")
		file.close()
	print(JSON.stringify(report, "\t"))
	main.queue_free()
	await process_frame
	manager.call("restore_snapshot", original_snapshot)
	manager.set("autosave_enabled", original_autosave)
	DisplayServer.window_set_vsync_mode(old_vsync)
	Engine.max_fps = old_max_fps
	quit()


func _measure(label: String, frame_count: int) -> Dictionary:
	var deltas_ms: Array[float] = []
	var start_usec := Time.get_ticks_usec()
	var last_usec := start_usec
	for _frame in range(frame_count):
		await process_frame
		var now_usec := Time.get_ticks_usec()
		deltas_ms.append(float(now_usec - last_usec) / 1000.0)
		last_usec = now_usec
	var elapsed_seconds := float(last_usec - start_usec) / 1000000.0
	var sorted := deltas_ms.duplicate()
	sorted.sort()
	var total_ms := 0.0
	for delta_ms in deltas_ms:
		total_ms += delta_ms
	return {
		"name": label,
		"frames": frame_count,
		"elapsed_seconds": elapsed_seconds,
		"average_fps": float(frame_count) / maxf(elapsed_seconds, 0.000001),
		"average_frame_time_ms": total_ms / maxf(float(frame_count), 1.0),
		"p95_frame_time_ms": sorted[clampi(roundi(float(sorted.size() - 1) * 0.95), 0, sorted.size() - 1)],
		"draw_calls_last_frame": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
	}


func _wait_frames(count: int) -> void:
	for _frame in range(count):
		await process_frame
