extends SceneTree
## Fixed-view renderer benchmark for ocean geometry and the sunny environment.
## Run: godot --path . --script res://tools/measure_ocean_sun_performance.gd

const MAIN_SCENE := "res://scenes/main.tscn"
const OUTPUT_PATH := "res://docs/ocean_sun_polish/performance_baseline.json"
const WARMUP_FRAMES := 120
const SAMPLE_FRAMES := 600


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var output_path := OUTPUT_PATH
	var user_args := OS.get_cmdline_user_args()
	if not user_args.is_empty():
		output_path = user_args[0]
	root.size = Vector2i(1920, 1080)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	var packed := load(MAIN_SCENE) as PackedScene
	if packed == null:
		push_error("Could not load %s" % MAIN_SCENE)
		quit(1)
		return
	var main := packed.instantiate()
	root.add_child(main)
	await _wait_frames(60)

	var quality := main.get_node("QualityManager") as QualityManager
	var boat := main.get_node("PlayerBoat") as Node3D
	var motion_root := main.get_node("PlayerBoat/MotionRoot") as BoatController
	var visual_root := main.get_node("PlayerBoat/MotionRoot/VisualRoot") as Node3D
	var camera_rig := main.get_node("PlayerBoat/FollowCameraRig") as Node3D
	var camera := main.get_node("PlayerBoat/FollowCameraRig/Camera3D") as Camera3D
	var weather := main.get_node("WeatherController") as WeatherController
	var ocean := main.get_node("Ocean") as Ocean
	var water := (main.get_node("BathymetryManager") as BathymetryManager).water_material
	quality.set_quality_for_benchmark(QualityManager.Quality.HIGH)
	# QualityManager may restore the player's persisted 30/60 FPS limiter when
	# the scene enters the tree. Reassert an uncapped benchmark after that setup.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	for canvas in main.find_children("*", "CanvasLayer", true, false):
		(canvas as CanvasLayer).visible = false
	motion_root.set_process(false)
	visual_root.set_process(false)
	camera_rig.set_process(false)
	var azimuth := deg_to_rad(weather.get_sun_azimuth())
	var elevation := deg_to_rad(weather.get_sun_elevation())
	var sun_direction := Vector3(sin(azimuth) * cos(elevation), sin(elevation), -cos(azimuth) * cos(elevation)).normalized()
	var waterward := -Vector3(sun_direction.x, 0.0, sun_direction.z).normalized()
	camera.global_position = boat.global_position + waterward * 62.0 + Vector3.UP * 12.0
	camera.look_at(boat.global_position + Vector3.UP * 1.8, Vector3.UP)
	camera.fov = 48.0
	camera.far = 10000.0
	camera.make_current()
	await _wait_frames(WARMUP_FRAMES)

	var frame_seconds: Array[float] = []
	var previous_usec := Time.get_ticks_usec()
	for _frame in range(SAMPLE_FRAMES):
		await process_frame
		var current_usec := Time.get_ticks_usec()
		var duration := float(current_usec - previous_usec) / 1_000_000.0
		previous_usec = current_usec
		if duration > 0.0 and duration < 1.0:
			frame_seconds.append(duration)
	frame_seconds.sort()
	var sum_seconds := 0.0
	for duration in frame_seconds:
		sum_seconds += duration
	var mean_seconds := sum_seconds / float(maxi(1, frame_seconds.size()))
	var report := {
		"engine": Engine.get_version_info(),
		"renderer": RenderingServer.get_video_adapter_name(),
		"resolution": [root.size.x, root.size.y],
		"quality": "High",
		"vsync": "disabled",
		"fps_cap": Engine.max_fps,
		"vsync_mode": DisplayServer.window_get_vsync_mode(),
		"camera_fov": camera.fov,
		"sun_azimuth": weather.get_sun_azimuth(),
		"sun_elevation": weather.get_sun_elevation(),
		"ocean_lods": ocean.levels_of_detail,
		"ocean_resolution": ocean.outermost_resolution,
		"water_diagnostic_mode": water.get_shader_parameter("water_diagnostic_mode"),
		"sample_count": frame_seconds.size(),
		"average_fps_from_frame_intervals": 1.0 / mean_seconds if mean_seconds > 0.0 else 0.0,
		"mean_frame_ms": mean_seconds * 1000.0,
		"median_frame_ms": frame_seconds[frame_seconds.size() / 2] * 1000.0 if not frame_seconds.is_empty() else 0.0,
		"p95_frame_ms": frame_seconds[int(float(frame_seconds.size() - 1) * 0.95)] * 1000.0 if not frame_seconds.is_empty() else 0.0,
		"engine_reported_fps_last_frame": Engine.get_frames_per_second(),
		"frame_interval_samples_ms": _to_milliseconds(frame_seconds),
	}
	var output_file := FileAccess.open(output_path, FileAccess.WRITE)
	if output_file != null:
		output_file.store_string(JSON.stringify(report, "  ") + "\n")
	print(JSON.stringify(report, "  "))
	main.queue_free()
	await process_frame
	quit()


func _wait_frames(count: int) -> void:
	for _index in range(count):
		await process_frame


func _to_milliseconds(seconds: Array[float]) -> Array[float]:
	var result: Array[float] = []
	for duration in seconds:
		result.append(duration * 1000.0)
	return result
