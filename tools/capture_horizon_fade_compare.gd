extends SceneTree
## Compares the existing water cutoff with wider far-distance transitions.
## Run with: godot --path . --script res://tools/capture_horizon_fade_compare.gd

const MAIN_SCENE := preload("res://scenes/main.tscn")
const OUTPUT_ROOT := "res://docs/horizon_seam/diagnostics/fade_compare_v2"
const TESTS := [[3600.0, 4000.0], [12000.0, 24000.0], [42000.0, 58000.0]]

var _captures: Array[Dictionary] = []


func _initialize() -> void:
	_capture.call_deferred()


func _capture() -> void:
	var manager := root.get_node_or_null("WorldTimeManager")
	if manager == null:
		push_error("WorldTimeManager autoload is unavailable.")
		quit(1)
		return
	var snapshot: Dictionary = manager.call("create_snapshot")
	var autosave := bool(manager.get("autosave_enabled"))
	var main := MAIN_SCENE.instantiate()
	root.add_child(main)
	await _wait_frames(45)
	manager.set("autosave_enabled", false)
	manager.call("pause_time")
	manager.call("set_calendar_date", 2026, 7, 15)
	manager.call("set_day_cycle_time", 12, 0)
	var quality := main.get_node("QualityManager") as QualityManager
	var boat := main.get_node("PlayerBoat") as Node3D
	var ocean := main.get_node("Ocean") as Ocean
	var water := main.get_node("BathymetryManager").get("water_material") as ShaderMaterial
	var environment := (main.get_node("WorldEnvironment") as WorldEnvironment).environment
	var weather := main.get_node("WeatherController") as WeatherController
	quality.set_quality_for_benchmark(QualityManager.Quality.HIGH)
	weather.transition_seconds = 0.0
	weather.set_weather_by_name("Clear")
	for canvas in main.find_children("*", "CanvasLayer", true, false):
		(canvas as CanvasLayer).visible = false
	boat.get_node("MotionRoot").set_process(false)
	boat.get_node("MotionRoot").set_physics_process(false)
	boat.get_node("MotionRoot/VisualRoot").set_process(false)
	boat.get_node("MotionRoot/VisualRoot").set_physics_process(false)
	boat.get_node("FollowCameraRig").set_process(false)
	boat.get_node("FollowCameraRig").set_physics_process(false)
	var wake := boat.get_node_or_null("MotionRoot/VisualRoot/WakeSystem")
	if wake != null:
		_disable_particles(wake)
	water.set_shader_parameter("freeze_time", true)
	var third_camera := boat.get_node("FollowCameraRig/Camera3D") as Camera3D
	third_camera.make_current()
	await _wait_frames(20)
	for fade in TESTS:
		water.set_shader_parameter("distance_fade_min", fade[0])
		water.set_shader_parameter("distance_fade_max", fade[1])
		var fade_name := "%d_%d" % [roundi(fade[0]), roundi(fade[1])]
		water.set_shader_parameter("water_diagnostic_mode", 12)
		await _save("third_alpha_" + fade_name, third_camera, water, fade)
		water.set_shader_parameter("water_diagnostic_mode", 0)
		await _save("third_full_" + fade_name, third_camera, water, fade)

	var wide_camera := Camera3D.new()
	wide_camera.name = "TemporaryHorizonFadeCompareCamera"
	wide_camera.fov = 70.0
	wide_camera.far = 80000.0
	main.add_child(wide_camera)
	var wide_origin := boat.global_position + Vector3.UP * 300.0
	wide_camera.global_position = wide_origin
	wide_camera.look_at(wide_origin + Vector3(-15000.0, -270.0, 0.0), Vector3.UP)
	wide_camera.make_current()
	await _wait_frames(10)
	for fade in TESTS:
		water.set_shader_parameter("distance_fade_min", fade[0])
		water.set_shader_parameter("distance_fade_max", fade[1])
		var fade_name := "%d_%d" % [roundi(fade[0]), roundi(fade[1])]
		water.set_shader_parameter("water_diagnostic_mode", 12)
		await _save("wide_alpha_" + fade_name, wide_camera, water, fade)
		water.set_shader_parameter("water_diagnostic_mode", 0)
		await _save("wide_full_" + fade_name, wide_camera, water, fade)

	# The main follow camera clips at 80 km while the ocean mesh currently stops
	# at 60 km. Compare matching those limits with a fade that completes inside.
	ocean.far_edge = 80000.0
	ocean.build_farplane()
	await _wait_frames(12)
	water.set_shader_parameter("distance_fade_min", 42000.0)
	water.set_shader_parameter("distance_fade_max", 58000.0)
	water.set_shader_parameter("water_diagnostic_mode", 0)
	await _save("third_full_far_edge_80000", third_camera, water, [42000.0, 58000.0])
	await _save("wide_full_far_edge_80000", wide_camera, water, [42000.0, 58000.0])

	var output_path := ProjectSettings.globalize_path(OUTPUT_ROOT)
	DirAccess.make_dir_recursive_absolute(output_path)
	var report := {"renderer": RenderingServer.get_video_adapter_name(), "processor": OS.get_processor_name(),
		"viewport_px": [root.get_viewport().size.x, root.get_viewport().size.y], "quality": "High", "weather": "Clear",
		"environment_fog_depth_end_m": environment.fog_depth_end, "captures": _captures}
	var file := FileAccess.open(output_path.path_join("report.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t") + "\n")
		file.close()
	print(JSON.stringify(report, "\t"))
	manager.call("restore_snapshot", snapshot)
	manager.set("autosave_enabled", autosave)
	root.remove_child(main)
	main.queue_free()
	await process_frame
	quit()


func _save(name: String, camera: Camera3D, water: ShaderMaterial, fade: Array) -> void:
	camera.make_current()
	await _wait_frames(6)
	await RenderingServer.frame_post_draw
	var image := root.get_viewport().get_texture().get_image()
	var directory := ProjectSettings.globalize_path(OUTPUT_ROOT)
	DirAccess.make_dir_recursive_absolute(directory)
	var path := directory.path_join(name + ".png")
	var error := image.save_png(path)
	_captures.append({"name": name, "path": path, "fade_min_m": fade[0], "fade_max_m": fade[1],
		"water_shader_mode": int(water.get_shader_parameter("water_diagnostic_mode")), "wave_frozen": true,
		"save_error": error, "fps": Engine.get_frames_per_second()})
	print("Captured %s (%dx%d, error=%d, fps=%d)" % [name, image.get_width(), image.get_height(), error, Engine.get_frames_per_second()])


func _disable_particles(node: Node) -> void:
	if node is GPUParticles3D:
		(node as GPUParticles3D).emitting = false
	for child in node.get_children():
		_disable_particles(child)


func _wait_frames(count: int) -> void:
	for _index in range(count):
		await process_frame
