extends SceneTree
## Captures a reproducible sky/environment baseline from the production scene.
## Run: godot --path . --script res://tools/capture_summer_sky_environment.gd

const MAIN_SCENE := "res://scenes/main.tscn"
const OUTPUT_DIR := "res://docs/summer_sky_environment"
const WARMUP_FRAMES := 60
const MEASURE_FRAMES := 180
const FPS_RUNS := 3

var captures: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_capture_baseline")


func _capture_baseline() -> void:
	var packed_scene := load(MAIN_SCENE) as PackedScene
	if packed_scene == null:
		push_error("Could not load %s" % MAIN_SCENE)
		quit(1)
		return

	var main := packed_scene.instantiate()
	root.add_child(main)
	await _wait_frames(15)

	var quality := main.get_node("QualityManager") as QualityManager
	var environment := (main.get_node("WorldEnvironment") as WorldEnvironment).environment
	var material := (main.get_node("BathymetryManager") as BathymetryManager).water_material
	var boat := main.get_node("PlayerBoat")
	var motion_root := boat.get_node("MotionRoot") as Node3D
	var camera_rig := boat.get_node("FollowCameraRig") as Node3D
	var camera := camera_rig.get_node("Camera3D") as Camera3D
	if quality == null or environment == null or material == null or camera == null:
		push_error("Main scene is missing required sky capture nodes.")
		main.queue_free()
		await process_frame
		quit(1)
		return

	quality.set_quality_for_benchmark(QualityManager.Quality.HIGH)
	material.set_shader_parameter("freeze_time", true)
	motion_root.set_process(false)
	await _wait_frames(12)
	camera_rig.set_process(false)
	camera.make_current()
	await _wait_frames(WARMUP_FRAMES)

	var old_vsync := DisplayServer.window_get_vsync_mode()
	var old_max_fps := Engine.max_fps
	var old_fog_enabled := environment.fog_enabled
	var old_fade_min := float(material.get_shader_parameter("distance_fade_min"))
	var old_fade_max := float(material.get_shader_parameter("distance_fade_max"))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	var output_path := ProjectSettings.globalize_path(OUTPUT_DIR)
	DirAccess.make_dir_recursive_absolute(output_path)
	await _save_capture("A_clear_before_third_person", output_path)
	var baseline_fps := await _measure_fps()

	# A diagnostic only: keep camera, weather, sky, light and water fixed, and
	# disable Environment fog to determine whether it creates the horizon band.
	environment.fog_enabled = false
	await _wait_frames(12)
	await _save_capture("diagnostic_clear_fog_off", output_path)
	environment.fog_enabled = old_fog_enabled
	await _wait_frames(12)
	# Diagnostic only: extend the existing water distance fade without touching
	# wave or palette parameters to check whether its horizon transition is visible.
	material.set_shader_parameter("distance_fade_min", 9000.0)
	material.set_shader_parameter("distance_fade_max", 10000.0)
	await _wait_frames(12)
	await _save_capture("diagnostic_clear_extended_water_fade", output_path)
	material.set_shader_parameter("distance_fade_min", old_fade_min)
	material.set_shader_parameter("distance_fade_max", old_fade_max)
	await _wait_frames(12)

	var report := {
		"engine": Engine.get_version_info(),
		"renderer": RenderingServer.get_video_adapter_name(),
		"processor": OS.get_processor_name(),
		"window_px": [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y],
		"viewport_px": [root.size.x, root.size.y],
		"quality": "High",
		"resolution_scale": quality.get_resolution_scale(),
		"vsync_during_measurement": "disabled",
		"max_fps_during_measurement": 0,
		"fog_enabled_in_game": old_fog_enabled,
		"fog_density": environment.fog_density,
		"fog_depth_begin": environment.fog_depth_begin,
		"fog_depth_end": environment.fog_depth_end,
		"water_distance_fade": [old_fade_min, old_fade_max],
		"wave_time_frozen": true,
		"captures": captures,
		"fps_baseline": baseline_fps,
	}
	var report_file := FileAccess.open(output_path.path_join("baseline_report.json"), FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "  ") + "\n")
	print(JSON.stringify(report, "  "))

	material.set_shader_parameter("freeze_time", false)
	material.set_shader_parameter("distance_fade_min", old_fade_min)
	material.set_shader_parameter("distance_fade_max", old_fade_max)
	Engine.max_fps = old_max_fps
	DisplayServer.window_set_vsync_mode(old_vsync)
	main.queue_free()
	await process_frame
	quit()


func _save_capture(capture_name: String, output_path: String) -> void:
	await _wait_frames(5)
	var image := root.get_texture().get_image()
	var file_path := output_path.path_join(capture_name + ".png")
	var error := image.save_png(file_path)
	captures.append({
		"name": capture_name,
		"width": image.get_width(),
		"height": image.get_height(),
		"path": file_path,
		"save_error": error,
	})


func _measure_fps() -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	for run_index in range(FPS_RUNS):
		await _wait_frames(WARMUP_FRAMES)
		var start_us := Time.get_ticks_usec()
		for _frame in range(MEASURE_FRAMES):
			await process_frame
		var elapsed := float(Time.get_ticks_usec() - start_us) / 1000000.0
		results.append({
			"run": run_index + 1,
			"frames": MEASURE_FRAMES,
			"elapsed_seconds": elapsed,
			"average_fps": float(MEASURE_FRAMES) / maxf(elapsed, 0.000001),
			"frame_time_ms": elapsed * 1000.0 / float(MEASURE_FRAMES),
		})
	return results


func _wait_frames(count: int) -> void:
	for _frame in range(count):
		await process_frame
