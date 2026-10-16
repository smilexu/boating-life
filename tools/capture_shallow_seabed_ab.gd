extends SceneTree

## Captures the production scene with matched shallow-seabed / water-transmission
## combinations. This is a visual diagnostic, not a replacement scene.

const CAPTURE_ROOT_DIR := "res://docs/shallow_seabed_visual_diagnostic"
const SCREEN_SIZE := Vector2i(1920, 1080)
const MAX_SETTLE_FRAMES := 1800

var _main: Node3D
var _manager: Node
var _water: ShaderMaterial
var _boat: Node3D
var _camera: Camera3D
var _output_dir := CAPTURE_ROOT_DIR.path_join("before")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var is_after := OS.get_cmdline_user_args().has("--after")
	if is_after:
		_output_dir = CAPTURE_ROOT_DIR.path_join("after")
	DisplayServer.window_set_size(SCREEN_SIZE)
	_main = load("res://scenes/main.tscn").instantiate() as Node3D
	root.add_child(_main)
	await process_frame
	_manager = _main.get_node("ShallowSeabedManager")
	_water = _main.get_node("BathymetryManager").get("water_material") as ShaderMaterial
	_apply_transmission_profile(is_after)
	_boat = _main.get_node("PlayerBoat/MotionRoot") as Node3D
	_boat.set("is_motion_paused", true)
	_water.set_shader_parameter("freeze_time", true)
	var time_manager := root.get_node_or_null("WorldTimeManager")
	if time_manager != null:
		time_manager.set("autosave_enabled", false)
		time_manager.call("pause_time")
		time_manager.call("clear_calendar_override")
		time_manager.call("set_calendar_date", 2026, 7, 15)
		time_manager.call("set_cycle_time", 12, 0, 0.0)
	var weather := _main.get_node("WeatherController")
	weather.call("set_weather_by_index", 0)
	await _prepare_fixed_camera()
	await _wait_for_manager(true)
	_print_scene_measurements()

	# A: no seabed, no transparency.
	await _set_state(false, false)
	await _capture("A_seabed_off_transparency_off.png")
	print("[ShallowSeabedAB] A timing: ", await _measure_scene_timing(240))

	# B: seabed visible, opaque water.
	await _set_state(true, false)
	await _capture("B_seabed_on_transparency_off.png")
	await _capture_nearest_reef("E_reef_closeup_transparency_off.png")
	print("[ShallowSeabedAB] B timing: ", await _measure_scene_timing(240))

	# C: no generated seabed, transmission enabled.
	await _set_state(false, true)
	await _capture("C_seabed_off_transparency_on.png")

	# D: both systems on (the current production combination).
	await _set_state(true, true)
	await _capture("D_seabed_on_transparency_on.png")
	print("[ShallowSeabedAB] D timing: ", await _measure_scene_timing(240))
	await _capture_nearest_reef("F_reef_closeup_transparency_on.png")

	# Paired in-process timing comparison with identical scene and camera. The
	# baseline values reproduce the previous production material settings.
	_water.set_shader_parameter("shallow_min_alpha", 0.30)
	_water.set_shader_parameter("shallow_transmission_strength", 0.90)
	_water.set_shader_parameter("shallow_absorption_per_meter", 0.0)
	print("[ShallowSeabedAB] paired previous-settings timing: ", await _measure_scene_timing(240))
	_water.set_shader_parameter("shallow_min_alpha", 0.62)
	_water.set_shader_parameter("shallow_transmission_strength", 0.60)
	_water.set_shader_parameter("shallow_absorption_per_meter", 0.06)
	print("[ShallowSeabedAB] paired updated-settings timing: ", await _measure_scene_timing(240))

	# Night comparison, holding the same camera and geometry state.
	if time_manager != null:
		time_manager.call("set_calendar_date", 2026, 12, 15)
		time_manager.call("set_cycle_time", 23, 0, 0.0)
	for _frame in range(120):
		await process_frame
	await _set_state(false, false)
	await _capture("G_winter_night_seabed_off_transparency_off.png")
	await _set_state(true, true)
	await _capture("H_winter_night_seabed_on_transparency_on.png")
	print("[ShallowSeabedAB] night full-state timing: ", await _measure_scene_timing(240))
	print("[ShallowSeabedAB] completed; output=", _output_dir)
	quit()


func _apply_transmission_profile(use_after_values: bool) -> void:
	# Explicitly reproduce both profiles in separate captures. These are runtime
	# overrides only; the saved production ShaderMaterial remains unchanged.
	_water.set_shader_parameter("shallow_min_alpha", 0.62 if use_after_values else 0.30)
	_water.set_shader_parameter("shallow_transmission_strength", 0.60 if use_after_values else 0.90)
	_water.set_shader_parameter("shallow_absorption_per_meter", 0.06 if use_after_values else 0.0)
	_water.set_shader_parameter("shallow_transparency_enabled", true)


func _prepare_fixed_camera() -> void:
	for _frame in range(90):
		await process_frame
	var camera_rig := _main.get_node("PlayerBoat/FollowCameraRig")
	camera_rig.set_process(false)
	var source_camera := _main.get_node("PlayerBoat/FollowCameraRig/Camera3D") as Camera3D
	_camera = Camera3D.new()
	_camera.name = "ShallowSeabedABFixedCamera"
	_camera.fov = source_camera.fov
	_camera.near = source_camera.near
	_camera.far = source_camera.far
	_main.add_child(_camera)
	_camera.global_transform = source_camera.global_transform
	_camera.make_current()
	await process_frame


func _set_state(seabed_on: bool, transparency_on: bool) -> void:
	_water.set_shader_parameter("shallow_transparency_enabled", transparency_on)
	_manager.set("system_enabled", seabed_on)
	_manager.call("_sync_runtime_options")
	await _wait_for_manager(seabed_on)


func _wait_for_manager(expect_seabed: bool) -> void:
	var stable_frames := 0
	for frame in range(MAX_SETTLE_FRAMES):
		await process_frame
		var stats: Dictionary = _manager.call("get_debug_stats")
		var pending := int(stats.get("pending_tiles", 1))
		var loaded := int(stats.get("loaded_chunks", 0))
		var expected_state := loaded > 0 if expect_seabed else loaded == 0
		if pending == 0 and expected_state:
			stable_frames += 1
			if stable_frames >= 45:
				return
		else:
			stable_frames = 0
	push_error("Shallow seabed mode did not settle within %d frames (enabled=%s)." % [MAX_SETTLE_FRAMES, str(expect_seabed)])


func _print_scene_measurements() -> void:
	var bathymetry := _main.get_node("BathymetryManager")
	var depth: Dictionary = bathymetry.call("get_depth_at_world_position", _boat.global_position)
	var ground: Dictionary = _manager.call("_sample_ground", _boat.global_position.x, -_boat.global_position.z)
	var water_height: float = float(_main.get_node("Ocean").global_position.y)
	var wave: Dictionary = _main.get_node("WaveSampler").call("sample_surface", _boat.global_position, 0.0)
	var seabed_height := float(ground.get("height_m", NAN)) if bool(ground.get("valid", false)) else NAN
	print("[ShallowSeabedAB] depth_at_boat=", depth)
	print("[ShallowSeabedAB] water_plane_y=%.3f wave_height=%.3f seabed_y=%.3f clearance_at_mean=%.3f" % [
		water_height, float(wave.get("height", water_height)), seabed_height, water_height - seabed_height
	])
	print("[ShallowSeabedAB] transmission alpha=%s strength=%s absorption=%s LAT_offset=%s bottom_padding=%s" % [
		str(_water.get_shader_parameter("shallow_min_alpha")),
		str(_water.get_shader_parameter("shallow_transmission_strength")),
		str(_water.get_shader_parameter("shallow_absorption_per_meter")),
		str(_water.get_shader_parameter("shallow_surface_above_lat_m")),
		str(_water.get_shader_parameter("shallow_bottom_depth_padding")),
	])
	var quality_manager := _main.get_node("QualityManager")
	print("[ShallowSeabedAB] render size=", root.get_viewport().get_visible_rect().size,
		" quality=", quality_manager.call("get_quality_name"),
		" 3d_scale=", quality_manager.call("get_resolution_scale"))


func _capture_nearest_reef(file_name: String) -> void:
	var reef: Dictionary = _find_nearest_reef(_boat.global_position, 15.0, 240.0)
	if not bool(reef.get("valid", false)):
		push_warning("No generated production reef found for close-up capture.")
		return
	var position: Vector3 = reef["position"]
	var saved_transform := _camera.global_transform
	var saved_fov := _camera.fov
	_camera.fov = 42.0
	_camera.global_position = position + Vector3(3.0, 5.5, 4.0)
	_camera.look_at(position + Vector3(0.0, 0.05, 0.0), Vector3.UP)
	for _frame in range(8):
		await process_frame
	print("[ShallowSeabedAB] close-up reef=", reef)
	await _capture(file_name)
	_camera.global_transform = saved_transform
	_camera.fov = saved_fov
	_camera.make_current()
	for _frame in range(8):
		await process_frame


func _find_nearest_reef(origin: Vector3, minimum_distance: float, maximum_distance: float) -> Dictionary:
	var loaded_tiles: Dictionary = _manager.get("_loaded_tiles")
	var nearest := {"valid": false, "distance_m": maximum_distance}
	for tile_key_variant in loaded_tiles:
		var tile_data: Dictionary = loaded_tiles[tile_key_variant]
		var tile_root := tile_data.get("root") as Node3D
		if not is_instance_valid(tile_root):
			continue
		for records in tile_data.get("bundle", {}).get("rock_records", []):
			for record in records:
				var local_transform: Transform3D = record["transform"]
				var world_position: Vector3 = tile_root.global_transform * local_transform.origin
				var distance := Vector2(world_position.x - origin.x, world_position.z - origin.z).length()
				if distance < minimum_distance or distance >= float(nearest["distance_m"]):
					continue
				nearest = {"valid": true, "position": world_position, "distance_m": distance, "tile": tile_key_variant}
	return nearest


func _capture(file_name: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var directory := ProjectSettings.globalize_path(_output_dir)
	DirAccess.make_dir_recursive_absolute(directory)
	var image := root.get_texture().get_image()
	var path := _output_dir.path_join(file_name)
	var error := image.save_png(ProjectSettings.globalize_path(path))
	print("[ShallowSeabedAB] saved %s result=%s size=%s" % [path, str(error), str(image.get_size())])


func _measure_scene_timing(frame_count: int) -> Dictionary:
	for _warmup_frame in range(90):
		await process_frame
	var start_usec := Time.get_ticks_usec()
	for _frame in range(frame_count):
		await process_frame
	var elapsed := float(Time.get_ticks_usec() - start_usec) / 1000000.0
	return {
		"frames": frame_count,
		"elapsed_seconds": elapsed,
		"average_fps": float(frame_count) / maxf(elapsed, 0.000001),
		"average_frame_ms": elapsed * 1000.0 / float(frame_count),
	}
