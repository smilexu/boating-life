extends SceneTree

const MAIN_SCENE := preload("res://scenes/main.tscn")
const OUTPUT_DIR := "res://docs/fish_resources"


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))
	var main_root := MAIN_SCENE.instantiate()
	root.add_child(main_root)
	await process_frame
	await process_frame

	var manager := main_root.get_node("FishResourceManager") as FishResourceManager
	var map_layer := main_root.get_node("FishResourceMap") as FishResourceMap
	var map_canvas := map_layer.find_child("ResourceDistributionMap", true, false) as FishResourceMapCanvas
	var map_start_usec := Time.get_ticks_usec()
	map_layer.set_map_open(true)
	while not map_canvas.is_raster_ready():
		await process_frame
	var map_elapsed_ms := float(Time.get_ticks_usec() - map_start_usec) / 1000.0
	await _capture_viewport("f4_resource_map.png")
	print("[FISH_CAPTURE] F4 first-open elapsed_ms=%.2f raster=%s schools=%d" % [map_elapsed_ms, map_canvas.get_raster_build_statistics(), manager.get_map_distribution().size()])
	map_layer.set_map_open(false)

	var boat := main_root.get_node("PlayerBoat/MotionRoot") as Node3D
	var camera_rig := main_root.get_node("PlayerBoat/FollowCameraRig") as Node3D
	var camera := main_root.get_node("PlayerBoat/FollowCameraRig/Camera3D") as Camera3D
	camera_rig.set_process(false)
	var nearby := manager.get_schools_near(boat.global_position, 1200.0)
	var target_school: Dictionary = {}
	var target_distance := INF
	for school in nearby:
		var profile := manager.get_species_profile(str(school["species_id"]))
		if profile == null:
			continue
		var position_values: Array = school["world_position"]
		var delta := Vector2(float(position_values[0]) - boat.global_position.x, float(position_values[2]) - boat.global_position.z)
		if delta.length() < target_distance:
			target_distance = delta.length()
			target_school = school
	if target_school.is_empty():
		push_error("No nearby fish school available for visual capture.")
		quit(1)
		return

	var school_position_values: Array = target_school["world_position"]
	var school_position := Vector3(float(school_position_values[0]), 0.0, float(school_position_values[2]))
	var wave_sampler := main_root.get_node("WaveSampler") as WaveSampler
	var surface_y := float(wave_sampler.sample_surface(school_position, wave_sampler.wave_time_seconds).get("height", 0.0))
	camera_rig.global_position = school_position + Vector3(0.0, 3.0, 3.0)
	camera_rig.look_at(Vector3(school_position.x, surface_y - 1.1, school_position.z), Vector3.UP)
	camera.position = Vector3.ZERO
	camera.rotation = Vector3.ZERO
	camera.fov = 28.0
	camera.make_current()
	await create_timer(1.0).timeout
	await _capture_viewport("fish_school_close_t0.png")
	await create_timer(1.0).timeout
	await _capture_viewport("fish_school_close_t1.png")
	var renderer := main_root.get_node("FishResourceManager/FishSchoolRenderer") as FishSchoolRenderer
	print("[FISH_CAPTURE] target=%s distance_m=%.1f camera=%s renderer=%s" % [str(target_school.get("school_id", "")), target_distance, camera.global_transform, renderer.get_render_statistics()])
	var stickleback_visual := renderer.get_node_or_null("three_spined_sticklebackMultiMesh") as MultiMeshInstance3D
	if stickleback_visual != null and stickleback_visual.multimesh != null and stickleback_visual.multimesh.visible_instance_count > 0:
		var focus_transform := stickleback_visual.global_transform * stickleback_visual.multimesh.get_instance_transform(0)
		camera_rig.global_position = focus_transform.origin + Vector3(0.0, 1.25, 1.4)
		camera_rig.look_at(focus_transform.origin, Vector3.UP)
		camera.fov = 12.0
		camera.make_current()
		await create_timer(0.5).timeout
		await _capture_viewport("fish_swim_close_t0.png")
		await create_timer(0.8).timeout
		await _capture_viewport("fish_swim_close_t1.png")
	quit(0)


func _capture_viewport(file_name: String) -> void:
	await process_frame
	var image := root.get_texture().get_image()
	var output_path := ProjectSettings.globalize_path("%s/%s" % [OUTPUT_DIR, file_name])
	var error := image.save_png(output_path)
	if error != OK:
		push_error("Failed to save capture %s: %s" % [file_name, error])
	else:
		print("[FISH_CAPTURE] saved %s (%dx%d)" % [output_path, image.get_width(), image.get_height()])
