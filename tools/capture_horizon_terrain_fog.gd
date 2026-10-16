extends SceneTree
## Checks how the current environment fog affects the far terrain silhouette.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const OUTPUT_ROOT := "res://docs/horizon_seam/diagnostics"

var _rows: Array[Dictionary] = []


func _initialize() -> void:
	_capture.call_deferred()


func _capture() -> void:
	var manager := root.get_node_or_null("WorldTimeManager")
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
	var environment := (main.get_node("WorldEnvironment") as WorldEnvironment).environment
	for canvas in main.find_children("*", "CanvasLayer", true, false):
		(canvas as CanvasLayer).visible = false
	quality.set_quality_for_benchmark(QualityManager.Quality.HIGH)
	boat.get_node("MotionRoot").set_process(false)
	boat.get_node("MotionRoot").set_physics_process(false)
	boat.get_node("FollowCameraRig").set_process(false)
	boat.get_node("FollowCameraRig").set_physics_process(false)
	var camera := Camera3D.new()
	camera.fov = 70.0
	camera.far = 80000.0
	main.add_child(camera)
	var origin := boat.global_position + Vector3.UP * 300.0
	camera.global_position = origin
	camera.look_at(origin + Vector3(-15000.0, -270.0, 0.0), Vector3.UP)
	camera.make_current()
	var mat := main.get_node("BathymetryManager").get("water_material") as ShaderMaterial
	mat.set_shader_parameter("freeze_time", true)
	ocean.visible = false
	await _wait_frames(15)
	var chunk_rows: Array[Dictionary] = []
	for chunk in terrain.get_children():
		if chunk is MeshInstance3D:
			var instance := chunk as MeshInstance3D
			var bounds := instance.global_transform * instance.get_aabb()
			var center := bounds.get_center()
			chunk_rows.append({"name": instance.name, "center": center, "distance_to_camera_m": center.distance_to(camera.global_position),
				"bounds": {"position": bounds.position, "size": bounds.size}})
	var fog_begin := environment.fog_depth_begin
	var fog_end := environment.fog_depth_end
	await _save("27_wide_terrain_only_fog_current", camera, terrain, environment, "terrain_only_fog_current")
	environment.fog_enabled = false
	await _save("28_wide_terrain_only_fog_off", camera, terrain, environment, "terrain_only_fog_off")
	environment.fog_enabled = true
	environment.fog_depth_end = 12000.0
	await _save("29_wide_terrain_only_fog_extended", camera, terrain, environment, "terrain_only_fog_end_12000")
	environment.fog_depth_end = fog_end
	environment.fog_depth_begin = fog_begin
	environment.fog_enabled = true
	var output_path := ProjectSettings.globalize_path(OUTPUT_ROOT)
	DirAccess.make_dir_recursive_absolute(output_path)
	var report := {"renderer": RenderingServer.get_video_adapter_name(), "processor": OS.get_processor_name(),
		"camera_position": camera.global_position, "camera_look_direction": -camera.global_basis.z,
		"fog_depth_begin_m": fog_begin, "fog_depth_end_m": fog_end, "terrain_chunks": chunk_rows, "captures": _rows}
	var file := FileAccess.open(output_path.path_join("terrain_fog_report.json"), FileAccess.WRITE)
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


func _save(name: String, camera: Camera3D, terrain: Node3D, environment: Environment, state: String) -> void:
	camera.make_current()
	await _wait_frames(6)
	await RenderingServer.frame_post_draw
	var image := root.get_viewport().get_texture().get_image()
	var output_path := ProjectSettings.globalize_path(OUTPUT_ROOT)
	DirAccess.make_dir_recursive_absolute(output_path)
	var path := output_path.path_join(name + ".png")
	var error := image.save_png(path)
	_rows.append({"name": name, "state": state, "terrain_visible": terrain.visible, "fog_enabled": environment.fog_enabled,
		"fog_depth_end_m": environment.fog_depth_end, "save_error": error, "path": path})
	print("Captured %s (%dx%d, error=%d)" % [name, image.get_width(), image.get_height(), error])


func _wait_frames(count: int) -> void:
	for _index in range(count):
		await process_frame
