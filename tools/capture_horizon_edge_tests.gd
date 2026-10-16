extends SceneTree
## Isolates the far ocean alpha cutoff from the generated ocean mesh edge.
## Run with: godot --path . --script res://tools/capture_horizon_edge_tests.gd

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
	var material := main.get_node("BathymetryManager").get("water_material") as ShaderMaterial
	var terrain := main.get_node("OresundRegion/TerrainChunks") as Node3D
	var ocean_meshes: Array[MeshInstance3D] = []
	for child in ocean.get_children():
		if child is MeshInstance3D and child.name.begins_with("_gen_"):
			ocean_meshes.append(child as MeshInstance3D)
	var terrain_meshes: Array[MeshInstance3D] = []
	for child in terrain.find_children("*", "MeshInstance3D", true, false):
		terrain_meshes.append(child as MeshInstance3D)
	for canvas in main.find_children("*", "CanvasLayer", true, false):
		(canvas as CanvasLayer).visible = false
	quality.set_quality_for_benchmark(QualityManager.Quality.HIGH)
	boat.get_node("MotionRoot").set_process(false)
	boat.get_node("MotionRoot").set_physics_process(false)
	boat.get_node("MotionRoot/VisualRoot").set_process(false)
	boat.get_node("MotionRoot/VisualRoot").set_physics_process(false)
	boat.get_node("FollowCameraRig").set_process(false)
	boat.get_node("FollowCameraRig").set_physics_process(false)
	var camera := boat.get_node("FollowCameraRig/Camera3D") as Camera3D
	camera.make_current()
	material.set_shader_parameter("freeze_time", true)
	material.set_shader_parameter("water_diagnostic_mode", 1)
	terrain.visible = false
	await _save("39_third_person_alpha_fade_current", camera, ocean, material, "fade_3600_4000")
	material.set_shader_parameter("distance_fade_min", 80000.0)
	material.set_shader_parameter("distance_fade_max", 82000.0)
	await _save("40_third_person_alpha_fade_beyond_mesh", camera, ocean, material, "fade_after_mesh")
	material.set_shader_parameter("water_diagnostic_mode", 0)
	await _save("41_third_person_full_shading_fade_beyond_mesh", camera, ocean, material, "full_fade_after_mesh")
	var original_far_edge := ocean.far_edge
	ocean.far_edge = 1200.0
	ocean.build_farplane()
	await _wait_frames(10)
	await _save("42_third_person_mesh_edge_1200m", camera, ocean, material, "mesh_edge_1200")
	ocean.far_edge = original_far_edge
	ocean.build_farplane()
	ocean_meshes.clear()
	for child in ocean.get_children():
		if child is MeshInstance3D and child.name.begins_with("_gen_"):
			ocean_meshes.append(child as MeshInstance3D)
	material.set_shader_parameter("water_diagnostic_mode", 1)
	_set_meshes_visible(ocean_meshes, false)
	_set_meshes_visible(terrain_meshes, false)
	await _wait_frames(10)
	await _save("44_third_person_true_sky_only", camera, ocean, material, "ocean_and_terrain_meshes_hidden")
	_set_meshes_visible(ocean_meshes, true)
	await _wait_frames(10)
	await _save("45_third_person_water_only", camera, ocean, material, "terrain_meshes_hidden")
	_set_meshes_visible(ocean_meshes, false)
	_set_meshes_visible(terrain_meshes, true)
	await _wait_frames(10)
	await _save("46_third_person_terrain_only", camera, ocean, material, "ocean_meshes_hidden")
	_set_meshes_visible(terrain_meshes, false)
	material.set_shader_parameter("water_diagnostic_mode", 0)
	var wide_camera := Camera3D.new()
	wide_camera.name = "TemporaryHorizonEdgeTestCamera"
	wide_camera.fov = 70.0
	wide_camera.far = 80000.0
	main.add_child(wide_camera)
	var wide_origin := boat.global_position + Vector3.UP * 300.0
	wide_camera.global_position = wide_origin
	wide_camera.look_at(wide_origin + Vector3(-15000.0, -270.0, 0.0), Vector3.UP)
	wide_camera.make_current()
	material.set_shader_parameter("distance_fade_min", 3600.0)
	material.set_shader_parameter("distance_fade_max", 4000.0)
	_set_meshes_visible(ocean_meshes, true)
	_set_meshes_visible(terrain_meshes, true)
	await _save("47_wide_ocean_and_terrain_baseline", wide_camera, ocean, material, "all_geometry_visible")
	_set_meshes_visible(terrain_meshes, false)
	await _save("48_wide_ocean_only", wide_camera, ocean, material, "terrain_meshes_hidden")
	_set_meshes_visible(ocean_meshes, false)
	_set_meshes_visible(terrain_meshes, true)
	await _save("49_wide_terrain_only", wide_camera, ocean, material, "ocean_meshes_hidden")
	_set_meshes_visible(terrain_meshes, false)
	await _save("50_wide_true_sky_only", wide_camera, ocean, material, "ocean_and_terrain_meshes_hidden")
	var report := {
		"renderer": RenderingServer.get_video_adapter_name(),
		"processor": OS.get_processor_name(),
		"viewport_px": [root.get_viewport().size.x, root.get_viewport().size.y],
		"original_fade_m": [3600.0, 4000.0],
		"fade_after_mesh_m": [80000.0, 82000.0],
		"original_far_edge_m": original_far_edge,
		"low_test_far_edge_m": 1200.0,
		"ocean_mesh_count": ocean_meshes.size(),
		"terrain_mesh_count": terrain_meshes.size(),
		"captures": _captures,
	}
	var output_path := ProjectSettings.globalize_path(OUTPUT_ROOT)
	DirAccess.make_dir_recursive_absolute(output_path)
	var file := FileAccess.open(output_path.path_join("edge_test_report.json"), FileAccess.WRITE)
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


func _set_meshes_visible(meshes: Array[MeshInstance3D], should_be_visible: bool) -> void:
	for mesh in meshes:
		mesh.visible = should_be_visible


func _save(name: String, camera: Camera3D, ocean: Ocean, material: ShaderMaterial, state: String) -> void:
	camera.make_current()
	await _wait_frames(6)
	await RenderingServer.frame_post_draw
	var image := root.get_viewport().get_texture().get_image()
	var output_path := ProjectSettings.globalize_path(OUTPUT_ROOT)
	DirAccess.make_dir_recursive_absolute(output_path)
	var path := output_path.path_join(name + ".png")
	var error := image.save_png(path)
	_captures.append({"name": name, "state": state, "ocean_visible": ocean.visible,
		"water_diagnostic_mode": material.get_shader_parameter("water_diagnostic_mode"),
		"distance_fade": [material.get_shader_parameter("distance_fade_min"), material.get_shader_parameter("distance_fade_max")],
		"far_edge": ocean.far_edge, "save_error": error, "path": path})
	print("Captured %s (%dx%d, error=%d)" % [name, image.get_width(), image.get_height(), error])


func _wait_frames(count: int) -> void:
	for _index in range(count):
		await process_frame
