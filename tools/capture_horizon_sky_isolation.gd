extends SceneTree
## Confirms whether the horizontal seam comes from the sky hemisphere join.
## Run with: godot --path . --script res://tools/capture_horizon_sky_isolation.gd

const MAIN_SCENE := preload("res://scenes/main.tscn")
const OUTPUT_ROOT := "res://docs/horizon_seam/diagnostics"

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
	var terrain := main.get_node("OresundRegion/TerrainChunks") as Node3D
	var world_environment := main.get_node("WorldEnvironment") as WorldEnvironment
	var environment := world_environment.environment
	var day_night := main.get_node("DayNightVisualController")
	var material := (environment.sky.sky_material as ShaderMaterial)
	for canvas in main.find_children("*", "CanvasLayer", true, false):
		(canvas as CanvasLayer).visible = false
	quality.set_quality_for_benchmark(QualityManager.Quality.HIGH)
	boat.get_node("MotionRoot").set_process(false)
	boat.get_node("MotionRoot").set_physics_process(false)
	boat.get_node("MotionRoot/VisualRoot").set_process(false)
	boat.get_node("MotionRoot/VisualRoot").set_physics_process(false)
	boat.get_node("FollowCameraRig").set_process(false)
	boat.get_node("FollowCameraRig").set_physics_process(false)
	ocean.visible = false
	terrain.visible = false
	var camera := boat.get_node("FollowCameraRig/Camera3D") as Camera3D
	camera.make_current()
	await _wait_frames(12)
	day_night.set_process(false)
	var compositor := world_environment.compositor
	var noon_sky_horizon: Vector3 = material.get_shader_parameter("sky_horizon_color")
	var noon_ground_horizon: Vector3 = material.get_shader_parameter("ground_horizon_color")
	await _save("22_sky_only_day_hemisphere_baseline", camera, material, "day_baseline")
	material.set_shader_parameter("ground_horizon_color", noon_sky_horizon)
	await _save("23_sky_only_day_horizons_equal", camera, material, "day_ground_equal_sky")
	material.set_shader_parameter("ground_horizon_color", noon_ground_horizon)
	world_environment.compositor = null
	await _save("24_sky_only_day_cloud_compositor_off", camera, material, "day_compositor_off")
	world_environment.compositor = compositor

	# Night uses the same fixed camera and sky-only view, with only the time inputs changed.
	manager.call("set_calendar_date", 2026, 10, 26)
	manager.call("set_day_cycle_time", 23, 0)
	day_night.set_process(true)
	await _wait_frames(20)
	day_night.set_process(false)
	var night_sky_horizon: Vector3 = material.get_shader_parameter("sky_horizon_color")
	var night_ground_horizon: Vector3 = material.get_shader_parameter("ground_horizon_color")
	await _save("25_sky_only_night_hemisphere_baseline", camera, material, "night_baseline")
	material.set_shader_parameter("ground_horizon_color", night_sky_horizon)
	await _save("26_sky_only_night_horizons_equal", camera, material, "night_ground_equal_sky")
	material.set_shader_parameter("ground_horizon_color", night_ground_horizon)

	var report := {
		"renderer": RenderingServer.get_video_adapter_name(),
		"processor": OS.get_processor_name(),
		"viewport_px": [root.get_viewport().size.x, root.get_viewport().size.y],
		"day_sky_horizon": noon_sky_horizon,
		"day_ground_horizon": noon_ground_horizon,
		"night_sky_horizon": night_sky_horizon,
		"night_ground_horizon": night_ground_horizon,
		"ocean_visible": ocean.visible,
		"terrain_visible": terrain.visible,
		"captures": _captures,
	}
	var output_path := ProjectSettings.globalize_path(OUTPUT_ROOT)
	DirAccess.make_dir_recursive_absolute(output_path)
	var file := FileAccess.open(output_path.path_join("sky_isolation_report.json"), FileAccess.WRITE)
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


func _save(name: String, camera: Camera3D, material: ShaderMaterial, state: String) -> void:
	camera.make_current()
	await _wait_frames(6)
	await RenderingServer.frame_post_draw
	var image := root.get_viewport().get_texture().get_image()
	var output_path := ProjectSettings.globalize_path(OUTPUT_ROOT)
	DirAccess.make_dir_recursive_absolute(output_path)
	var path := output_path.path_join(name + ".png")
	var error := image.save_png(path)
	_captures.append({"name": name, "state": state, "save_error": error, "path": path})
	print("Captured %s (%dx%d, error=%d)" % [name, image.get_width(), image.get_height(), error])


func _wait_frames(count: int) -> void:
	for _index in range(count):
		await process_frame
