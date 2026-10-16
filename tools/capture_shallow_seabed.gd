extends SceneTree

## Captures the production main scene at its real Malmö start position after
## the seabed streaming queue has settled. This does not replace bathymetry.

const OUTPUT_DIR := "res://docs/shallow_seabed"

var _main: Node3D
var _camera: Camera3D


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	_main = load("res://scenes/main.tscn").instantiate() as Node3D
	root.add_child(_main)
	await process_frame
	var boat := _main.get_node("PlayerBoat/MotionRoot") as Node3D
	boat.set("is_motion_paused", true)
	var time_manager := root.get_node_or_null("WorldTimeManager")
	if time_manager != null:
		time_manager.set("autosave_enabled", false)
		time_manager.call("pause_time")
		time_manager.call("set_calendar_date", 2026, 7, 15)
		time_manager.call("set_cycle_time", 12, 0, 0.0)
	var weather := _main.get_node_or_null("WeatherController")
	if weather != null:
		weather.call("set_weather_by_index", 0)
	var manager := _main.get_node("ShallowSeabedManager")
	manager.set("show_statistics", true)
	manager.call("_sync_runtime_options")
	_camera = Camera3D.new()
	_camera.name = "ShallowSeabedCaptureCamera"
	_camera.far = 4000.0
	_camera.fov = 56.0
	_main.add_child(_camera)
	var settled_frames := 0
	for frame in range(1200):
		await process_frame
		var stats: Dictionary = manager.call("get_debug_stats")
		if frame > 120 and int(stats.get("pending_tiles", 1)) == 0:
			settled_frames += 1
			if settled_frames >= 60:
				break
		else:
			settled_frames = 0
	var start_depth: Dictionary = _main.get_node("BathymetryManager").call("get_depth_at_world_position", boat.global_position)
	print("[ShallowSeabedCapture] real start depth: ", start_depth)
	print("[ShallowSeabedCapture] stats: ", manager.call("get_debug_stats"))
	print("[ShallowSeabedCapture] settled third-person timing: ", await _measure_scene_timing(180))
	var default_camera := _main.get_node("PlayerBoat/FollowCameraRig/Camera3D") as Camera3D
	default_camera.make_current()
	await _capture("01_real_start_third_person.png")
	_camera.position = boat.global_position + Vector3(52.0, 62.0, 58.0)
	_camera.look_at(boat.global_position + Vector3(0.0, -1.5, 0.0), Vector3.UP)
	_camera.make_current()
	await _capture("02_real_start_oblique.png")
	_camera.position = boat.global_position + Vector3(0.0, 70.0, 0.0)
	_camera.look_at(boat.global_position + Vector3(0.0, -1.5, 0.0), Vector3(0.0, 0.0, -1.0))
	_camera.make_current()
	await _capture("03_real_start_top_down.png")
	_camera.fov = 68.0
	_camera.position = boat.global_position + Vector3(0.0, 13.0, 17.0)
	_camera.look_at(boat.global_position + Vector3(0.0, -2.0, 0.0), Vector3.UP)
	_camera.make_current()
	await _capture("04_real_start_close_oblique.png")
	_camera.position = boat.global_position + Vector3(0.0, 18.0, 0.0)
	_camera.look_at(boat.global_position + Vector3(0.0, -2.5, 0.0), Vector3(0.0, 0.0, -1.0))
	_camera.make_current()
	await _capture("05_real_start_close_top_down.png")
	var nearest_reef := _find_nearest_reef(manager, boat.global_position, 15.0, 240.0)
	if bool(nearest_reef.get("valid", false)):
		var reef_position: Vector3 = nearest_reef["position"]
		var reef_depth: Dictionary = _main.get_node("BathymetryManager").call("get_depth_at_world_position", reef_position)
		print("[ShallowSeabedCapture] nearest generated reef: %.1f m from boat · depth %s · tile %s" % [float(nearest_reef["distance_m"]), str(reef_depth), str(nearest_reef["tile_key"])])
		_camera.fov = 42.0
		_camera.position = reef_position + Vector3(3.0, 5.5, 4.0)
		_camera.look_at(reef_position + Vector3(0.0, 0.05, 0.0), Vector3.UP)
		_camera.make_current()
		for _frame in range(60):
			await process_frame
		print("[ShallowSeabedCapture] settled reef-view timing: ", await _measure_scene_timing(180))
		await _capture("06_real_seabed_reef_closeup.png")
	else:
		push_warning("No generated reef was found within 240 m of the real start; close-up capture skipped.")
	var bathymetry := _main.get_node("BathymetryManager") as BathymetryManager
	bathymetry.water_material.set_shader_parameter("water_diagnostic_mode", 13)
	await _capture("07_transmission_mask_diagnostic.png")
	bathymetry.water_material.set_shader_parameter("water_diagnostic_mode", 0)
	manager.set("show_lod_debug", true)
	manager.call("_sync_runtime_options")
	await _capture("08_lod_visibility_diagnostic.png")
	manager.set("show_lod_debug", false)
	manager.call("_sync_runtime_options")
	if time_manager != null:
		time_manager.call("set_calendar_date", 2026, 12, 15)
		time_manager.call("set_cycle_time", 23, 0, 0.0)
	weather.call("set_weather_by_index", 0)
	default_camera.make_current()
	for _frame in range(90):
		await process_frame
	print("[ShallowSeabedCapture] winter night seabed stats: ", manager.call("get_debug_stats"))
	await _capture("09_winter_night_seabed.png")
	quit()


func _capture(file_name: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var directory := ProjectSettings.globalize_path(OUTPUT_DIR)
	DirAccess.make_dir_recursive_absolute(directory)
	var image := root.get_texture().get_image()
	var path := OUTPUT_DIR.path_join(file_name)
	var error := image.save_png(ProjectSettings.globalize_path(path))
	print("[ShallowSeabedCapture] ", path, " result=", error, " size=", image.get_size())


func _measure_scene_timing(frame_count: int) -> Dictionary:
	var start_usec := Time.get_ticks_usec()
	for _frame in range(frame_count):
		await process_frame
	var elapsed_seconds := float(Time.get_ticks_usec() - start_usec) / 1000000.0
	var average_fps := float(frame_count) / maxf(elapsed_seconds, 0.000001)
	return {
		"frames": frame_count,
		"elapsed_seconds": elapsed_seconds,
		"average_fps": average_fps,
		"average_frame_ms": elapsed_seconds * 1000.0 / float(frame_count),
	}


func _find_nearest_reef(manager: Node, origin: Vector3, minimum_distance: float, maximum_distance: float) -> Dictionary:
	var loaded_tiles: Dictionary = manager.get("_loaded_tiles")
	var nearest := {"valid": false, "distance_m": maximum_distance}
	for tile_key_variant in loaded_tiles:
		var tile_key: Vector2i = tile_key_variant
		var tile_data: Dictionary = loaded_tiles[tile_key]
		var tile_root := tile_data.get("root") as Node3D
		if not is_instance_valid(tile_root):
			continue
		var bundle: Dictionary = tile_data.get("bundle", {})
		var records_by_variant: Array = bundle.get("rock_records", [])
		for records in records_by_variant:
			for record in records:
				var local_transform: Transform3D = record["transform"]
				var world_position := tile_root.global_transform * local_transform.origin
				var distance := Vector2(world_position.x - origin.x, world_position.z - origin.z).length()
				if distance < minimum_distance or distance >= float(nearest["distance_m"]):
					continue
				nearest = {
					"valid": true,
					"position": world_position,
					"distance_m": distance,
					"tile_key": tile_key,
				}
	return nearest
