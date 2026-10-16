extends SceneTree
## Isolates the generated ocean near LOD meshes from the farplane.
## Run with: godot --path . --script res://tools/capture_horizon_mesh_isolation.gd

const MAIN_SCENE := preload("res://scenes/main.tscn")
const OUTPUT_ROOT := "res://docs/horizon_seam/diagnostics"

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
	var material := main.get_node("BathymetryManager").get("water_material") as ShaderMaterial
	var terrain := main.get_node("OresundRegion/TerrainChunks") as Node3D
	var environment := (main.get_node("WorldEnvironment") as WorldEnvironment).environment
	for canvas in main.find_children("*", "CanvasLayer", true, false):
		(canvas as CanvasLayer).visible = false
	quality.set_quality_for_benchmark(QualityManager.Quality.HIGH)
	boat.get_node("MotionRoot").set_process(false)
	boat.get_node("MotionRoot").set_physics_process(false)
	boat.get_node("MotionRoot/VisualRoot").set_process(false)
	boat.get_node("MotionRoot/VisualRoot").set_physics_process(false)
	boat.get_node("FollowCameraRig").set_process(false)
	boat.get_node("FollowCameraRig").set_physics_process(false)
	var follower := main.get_node("OceanCameraFollower") as CameraFollower3D
	material.set_shader_parameter("freeze_time", true)
	material.set_shader_parameter("water_diagnostic_mode", 1)
	var camera := boat.get_node("FollowCameraRig/Camera3D") as Camera3D
	camera.make_current()
	await _wait_frames(15)
	var camera_position := camera.global_position
	var camera_rotation := camera.global_rotation
	var ocean_children: Array[MeshInstance3D] = []
	for child in ocean.get_children():
		if child is MeshInstance3D and child.name.begins_with("_gen_"):
			ocean_children.append(child as MeshInstance3D)
	var farplane_count := 0
	var nearplane_count := 0
	for child in ocean_children:
		if child.name.begins_with("_gen_farplane"):
			farplane_count += 1
		else:
			nearplane_count += 1

	await _save("13_third_person_flat_baseline", camera, ocean, ocean_children, true, true, terrain)
	_set_mesh_visibility(ocean_children, false, "_gen_farplane")
	await _save("14_third_person_farplane_hidden", camera, ocean, ocean_children, true, false, terrain)
	_restore_mesh_visibility(ocean_children)
	_set_mesh_visibility(ocean_children, false, "_gen_nearplane")
	await _save("15_third_person_near_lods_hidden", camera, ocean, ocean_children, false, true, terrain)
	_restore_mesh_visibility(ocean_children)

	# A low aerial view extends the true geometric horizon and exposes far-field seams.
	var wide_camera := Camera3D.new()
	wide_camera.name = "TemporaryWideHorizonCamera"
	wide_camera.fov = 70.0
	wide_camera.far = 80000.0
	main.add_child(wide_camera)
	var wide_origin := boat.global_position + Vector3.UP * 300.0
	wide_camera.global_position = wide_origin
	wide_camera.look_at(wide_origin + Vector3(-15000.0, -270.0, 0.0), Vector3.UP)
	wide_camera.make_current()
	follower.enable = true
	await _wait_frames(10)
	await _save("16_wide_flat_baseline", wide_camera, ocean, ocean_children, true, true, terrain)
	_set_mesh_visibility(ocean_children, false, "_gen_farplane")
	await _save("17_wide_farplane_hidden", wide_camera, ocean, ocean_children, true, false, terrain)
	_restore_mesh_visibility(ocean_children)
	_set_mesh_visibility(ocean_children, false, "_gen_nearplane")
	await _save("18_wide_near_lods_hidden", wide_camera, ocean, ocean_children, false, true, terrain)
	_restore_mesh_visibility(ocean_children)
	ocean.visible = false
	await _save("19_wide_ocean_hidden", wide_camera, ocean, ocean_children, false, false, terrain)
	ocean.visible = true
	terrain.visible = false
	await _save("20_wide_ocean_and_terrain_hidden", wide_camera, ocean, ocean_children, false, false, terrain)
	terrain.visible = true

	# Rotate the same wide camera around a fixed point. Mesh-axis seams should rotate relative to the horizon.
	wide_camera.look_at(wide_origin + Vector3(-10607.0, -270.0, 10607.0), Vector3.UP)
	follower.enable = true
	await _wait_frames(10)
	await _save("21_wide_rotated_flat_baseline", wide_camera, ocean, ocean_children, true, true, terrain)
	
	var output_path := ProjectSettings.globalize_path(OUTPUT_ROOT)
	DirAccess.make_dir_recursive_absolute(output_path)
	var report := {
		"engine": Engine.get_version_info(),
		"renderer": RenderingServer.get_video_adapter_name(),
		"processor": OS.get_processor_name(),
		"viewport_px": [root.get_viewport().size.x, root.get_viewport().size.y],
		"quality": "High",
		"water_diagnostic_mode": 1,
		"geometry_counts": {"near_lod_meshes": nearplane_count, "farplane_meshes": farplane_count},
		"camera": {"third_person_position": camera_position, "third_person_rotation": camera_rotation,
			"wide_position": wide_camera.global_position, "wide_rotation": wide_camera.global_rotation},
		"captures": _rows,
	}
	var file := FileAccess.open(output_path.path_join("mesh_isolation_report.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t") + "\n")
		file.close()
	print(JSON.stringify(report, "\t"))
	follower.enable = true
	manager.call("restore_snapshot", snapshot)
	manager.set("autosave_enabled", autosave)
	root.remove_child(main)
	main.queue_free()
	await process_frame
	quit()


func _save(name: String, camera: Camera3D, ocean: Ocean, meshes: Array[MeshInstance3D], near_visible: bool, far_visible: bool, terrain: Node3D) -> void:
	camera.make_current()
	await _wait_frames(6)
	await RenderingServer.frame_post_draw
	var image := root.get_viewport().get_texture().get_image()
	var output_path := ProjectSettings.globalize_path(OUTPUT_ROOT)
	DirAccess.make_dir_recursive_absolute(output_path)
	var path := output_path.path_join(name + ".png")
	var error := image.save_png(path)
	_rows.append({"name": name, "near_lods_visible": near_visible, "farplane_visible": far_visible,
		"ocean_visible": ocean.visible, "terrain_visible": terrain.visible, "save_error": error, "path": path})
	print("Captured %s (%dx%d, error=%d)" % [name, image.get_width(), image.get_height(), error])


func _set_mesh_visibility(meshes: Array[MeshInstance3D], visible: bool, prefix: String) -> void:
	for mesh in meshes:
		if mesh.name.begins_with(prefix):
			mesh.visible = visible


func _restore_mesh_visibility(meshes: Array[MeshInstance3D]) -> void:
	for mesh in meshes:
		mesh.visible = true


func _wait_frames(count: int) -> void:
	for _index in range(count):
		await process_frame
