extends SceneTree
## Captures the same production third-person view at the requested Stockholm
## dates and cycle times. Run with a graphical Godot renderer, not --headless.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const OUTPUT_DIR := "res://docs/day_night_cycle/screenshots"
const CAPTURE_TIMES := [5, 8, 12, 17, 20, 23, 2]

var _captures: Array[Dictionary] = []


func _initialize() -> void:
	_capture.call_deferred()


func _capture() -> void:
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
	await _wait_frames(20)
	var quality := main.get_node("QualityManager") as QualityManager
	var boat := main.get_node("PlayerBoat")
	var motion_root := boat.get_node("MotionRoot") as Node3D
	var visual_root := boat.get_node("MotionRoot/VisualRoot") as Node3D
	var camera_rig := boat.get_node("FollowCameraRig") as Node3D
	var camera := boat.get_node("FollowCameraRig/Camera3D") as Camera3D
	var water := (main.get_node("BathymetryManager") as BathymetryManager).water_material
	if quality == null or camera == null or water == null:
		push_error("Main scene is missing the production camera or visual systems.")
		main.queue_free()
		await process_frame
		manager.call("restore_snapshot", original_snapshot)
		manager.set("autosave_enabled", original_autosave)
		quit(1)
		return

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
	var output_path := ProjectSettings.globalize_path(OUTPUT_DIR)
	DirAccess.make_dir_recursive_absolute(output_path)
	for date in [{"year": 2026, "month": 7, "day": 15}, {"year": 2026, "month": 12, "day": 15}]:
		for hour in CAPTURE_TIMES:
			manager.call("set_calendar_date", int(date["year"]), int(date["month"]), int(date["day"]))
			manager.call("set_day_cycle_time", hour, 0)
			await _wait_frames(30)
			var controller := main.get_node("DayNightVisualController")
			var solar: Dictionary = controller.call("get_solar_state")
			var name := "%s_%02d00" % ["summer" if int(date["month"]) == 7 else "winter", hour]
			var image := root.get_texture().get_image()
			var file_path := output_path.path_join(name + ".png")
			var save_error := image.save_png(file_path)
			_captures.append({
				"name": name,
				"path": file_path,
				"save_error": save_error,
				"width": image.get_width(),
				"height": image.get_height(),
				"date": date,
				"hour": hour,
				"solar_elevation_degrees": solar.get("elevation_degrees", 0.0),
				"solar_azimuth_degrees": solar.get("azimuth_degrees", 0.0),
				"direct_light_strength": solar.get("direct_light_strength", 0.0),
			})
			print("Captured %s | elevation %.2f° | azimuth %.2f° | save_error=%d" % [name, float(solar.get("elevation_degrees", 0.0)), float(solar.get("azimuth_degrees", 0.0)), save_error])

	var report := {
		"engine": Engine.get_version_info(),
		"renderer": RenderingServer.get_video_adapter_name(),
		"processor": OS.get_processor_name(),
		"window_size": [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y],
		"quality": "High",
		"vsync_during_capture": "disabled",
		"water_phase_frozen": true,
		"captures": _captures,
	}
	var report_file := FileAccess.open(output_path.path_join("capture_report.json"), FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "\t") + "\n")
	print(JSON.stringify(report, "\t"))

	water.set_shader_parameter("freeze_time", false)
	main.queue_free()
	await process_frame
	manager.call("restore_snapshot", original_snapshot)
	manager.set("autosave_enabled", original_autosave)
	DisplayServer.window_set_vsync_mode(old_vsync)
	Engine.max_fps = old_max_fps
	quit()


func _wait_frames(count: int) -> void:
	for _frame in range(count):
		await process_frame
