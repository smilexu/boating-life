extends SceneTree
## Separates the near LOD and farplane while preserving water alpha fades.
## Run with: godot --path . --script res://tools/capture_horizon_alpha_mesh_isolation.gd

const MAIN_SCENE := preload("res://scenes/main.tscn")
const OUTPUT_ROOT := "res://docs/horizon_seam/diagnostics/alpha_mesh"

var _rows: Array[Dictionary] = []


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
	var terrain := main.get_node("OresundRegion/TerrainChunks") as Node3D
	var weather := main.get_node("WeatherController") as WeatherController
	quality.set_quality_for_benchmark(QualityManager.Quality.HIGH)
	weather.transition_seconds = 0.0
	weather.set_weather_by_name("Clear")
	for canvas in main.find_children("*", "CanvasLayer", true, false):
		(canvas as CanvasLayer).visible = false
	for path in [
		"MotionRoot", "MotionRoot/VisualRoot", "FollowCameraRig"
	]:
		var node := boat.get_node(path)
		node.set_process(false)
		node.set_physics_process(false)
	var wake := boat.get_node_or_null("MotionRoot/VisualRoot/WakeSystem")
	if wake != null:
		_disable_particles(wake)
	water.set_shader_parameter("freeze_time", true)
	water.set_shader_parameter("water_diagnostic_mode", 12)
	water.set_shader_parameter("enable_horizon_fade", false)
	water.set_shader_parameter("distance_fade_min", 3600.0)
	water.set_shader_parameter("distance_fade_max", 4000.0)
	var third_camera := boat.get_node("FollowCameraRig/Camera3D") as Camera3D
	third_camera.make_current()
	await _wait_frames(20)
	var meshes: Array[MeshInstance3D] = _get_ocean_meshes(ocean)
	await _capture_geometry_set("third", third_camera, ocean, water, meshes, true, true, terrain)
	await _capture_geometry_set("third_no_far", third_camera, ocean, water, meshes, true, false, terrain)
	await _capture_geometry_set("third_no_near", third_camera, ocean, water, meshes, false, true, terrain)
	for far_mesh_name in ["_gen_farplane_transition", "_gen_farplane_mid", "_gen_farplane_far"]:
		await _capture_single_mesh_off("third_without_%s" % far_mesh_name.trim_prefix("_gen_farplane_"),
			third_camera, ocean, water, meshes, far_mesh_name, terrain)
	_set_mesh_visibility(meshes, true)
	water.set_shader_parameter("distance_fade_min", 8000.0)
	water.set_shader_parameter("distance_fade_max", 12000.0)
	await _capture_screenshot("third_fade_8000_12000", third_camera, ocean, water, terrain)
	water.set_shader_parameter("distance_fade_min", 3600.0)
	water.set_shader_parameter("distance_fade_max", 4000.0)

	var wide_camera := Camera3D.new()
	wide_camera.name = "TemporaryHorizonAlphaCamera"
	wide_camera.fov = 70.0
	wide_camera.far = 80000.0
	main.add_child(wide_camera)
	var origin := boat.global_position + Vector3.UP * 300.0
	wide_camera.global_position = origin
	wide_camera.look_at(origin + Vector3(-15000.0, -270.0, 0.0), Vector3.UP)
	wide_camera.make_current()
	await _wait_frames(10)
	await _capture_geometry_set("wide", wide_camera, ocean, water, meshes, true, true, terrain)
	await _capture_geometry_set("wide_no_far", wide_camera, ocean, water, meshes, true, false, terrain)
	await _capture_geometry_set("wide_no_near", wide_camera, ocean, water, meshes, false, true, terrain)
	for far_mesh_name in ["_gen_farplane_transition", "_gen_farplane_mid", "_gen_farplane_far"]:
		await _capture_single_mesh_off("wide_without_%s" % far_mesh_name.trim_prefix("_gen_farplane_"),
			wide_camera, ocean, water, meshes, far_mesh_name, terrain)
	water.set_shader_parameter("distance_fade_min", 42000.0)
	water.set_shader_parameter("distance_fade_max", 58000.0)
	await _capture_screenshot("wide_fade_42000_58000", wide_camera, ocean, water, terrain)

	var report := {
		"renderer": RenderingServer.get_video_adapter_name(),
		"viewport_px": [root.get_viewport().size.x, root.get_viewport().size.y],
		"weather": "Clear", "date": "2026-07-15", "time": "12:00",
		"water_diagnostic_mode": 12,
		"alpha_fade_preserved": true,
		"horizon_fade_enabled": false,
		"original_distance_fade_m": [3600.0, 4000.0],
		"captures": _rows,
	}
	var output := ProjectSettings.globalize_path(OUTPUT_ROOT)
	DirAccess.make_dir_recursive_absolute(output)
	var report_file := FileAccess.open(output.path_join("report.json"), FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "\t") + "\n")
		report_file.close()
	print(JSON.stringify(report, "\t"))
	manager.call("restore_snapshot", snapshot)
	manager.set("autosave_enabled", autosave)
	root.remove_child(main)
	main.queue_free()
	await process_frame
	quit()


func _capture_geometry_set(prefix: String, camera: Camera3D, ocean: Ocean, water: ShaderMaterial, meshes: Array[MeshInstance3D], near_visible: bool, far_visible: bool, terrain: Node3D) -> void:
	for mesh in meshes:
		mesh.visible = (mesh.name.begins_with("_gen_farplane")) == far_visible
		if mesh.name.begins_with("_gen_nearplane"):
			mesh.visible = near_visible
	await _capture_screenshot(prefix, camera, ocean, water, terrain)
	_set_mesh_visibility(meshes, true)


func _set_mesh_visibility(meshes: Array[MeshInstance3D], visible: bool) -> void:
	for mesh in meshes:
		mesh.visible = visible


func _capture_single_mesh_off(name: String, camera: Camera3D, ocean: Ocean, water: ShaderMaterial,
		meshes: Array[MeshInstance3D], mesh_name: String, terrain: Node3D) -> void:
	_set_mesh_visibility(meshes, true)
	for mesh in meshes:
		if mesh.name == mesh_name:
			mesh.visible = false
	await _capture_screenshot(name, camera, ocean, water, terrain)
	_set_mesh_visibility(meshes, true)


func _get_ocean_meshes(ocean: Ocean) -> Array[MeshInstance3D]:
	var meshes: Array[MeshInstance3D] = []
	for child in ocean.get_children():
		if child is MeshInstance3D and child.name.begins_with("_gen_"):
			meshes.append(child as MeshInstance3D)
	return meshes


func _capture_screenshot(name: String, camera: Camera3D, ocean: Ocean, water: ShaderMaterial, terrain: Node3D) -> void:
	camera.make_current()
	await _wait_frames(6)
	await RenderingServer.frame_post_draw
	var image := root.get_viewport().get_texture().get_image()
	var output := ProjectSettings.globalize_path(OUTPUT_ROOT)
	DirAccess.make_dir_recursive_absolute(output)
	var path := output.path_join(name + ".png")
	var error := image.save_png(path)
	_rows.append({"name": name, "path": path, "ocean_visible": ocean.visible,
		"terrain_visible": terrain.visible, "water_diagnostic_mode": 12,
		"distance_fade": [water.get_shader_parameter("distance_fade_min"), water.get_shader_parameter("distance_fade_max")], "save_error": error})
	print("Captured %s (%dx%d, error=%d)" % [name, image.get_width(), image.get_height(), error])


func _disable_particles(node: Node) -> void:
	if node is GPUParticles3D:
		(node as GPUParticles3D).emitting = false
	for child in node.get_children():
		_disable_particles(child)


func _wait_frames(count: int) -> void:
	for _index in range(count):
		await process_frame
