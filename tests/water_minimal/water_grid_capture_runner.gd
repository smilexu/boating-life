extends Node

## F9 saves the current manual repro view and enough state to replay it.
## A replay captures normal shading first. Diagnostics require a second launch
## with --water-grid-confirmed after the normal replay image has been reviewed.

const CAPTURE_DIR := "res://tests/water_minimal/captures"
const REPLAY_SETTLE_FRAMES := 90
const DIAGNOSTIC_MODES := [
	{"name": "mode2", "mode": 2},
	{"name": "mode9", "mode": 9},
	{"name": "mode10", "mode": 10},
	{"name": "mode6", "mode": 6},
]
const CAPTURED_SHADER_PARAMETERS := [
	"water_diagnostic_mode", "enable_depth_color", "shallow_transparency_enabled",
	"freeze_time", "WaveTime", "WaveCount", "WaveSteepnesses", "WaveAmplitudes",
	"WaveDirectionsDegrees", "WaveFrequencies", "WaveSpeeds", "WavePhases",
	"depth_color_strength", "wave_normal_strength", "specular", "metallic",
	"water_roughness_near", "water_roughness_far", "water_specular_near_multiplier",
	"water_specular_far_multiplier", "ripple_scale", "ripple_speed", "ripple_direction",
	"detail_wave_fade_start", "detail_wave_fade_end", "detail_normal_strength_near",
	"detail_normal_strength_far", "shallow_wave_constraint_enabled",
	"shallow_wave_full_depth_m", "shallow_wave_min_amplitude_scale",
	"shallow_wave_safe_depth_ratio", "shallow_wave_max_trough_excursion_m",
	"bathymetry_texture_size", "bathymetry_bounds_east_north",
]
const WAVE_ARRAY_PARAMETERS := [
	"WaveSteepnesses", "WaveAmplitudes", "WaveDirectionsDegrees", "WaveFrequencies",
	"WaveSpeeds", "WavePhases",
]

var _water: ShaderMaterial
var _bathymetry: Node
var _camera: Camera3D
var _camera_rig: Node3D
var _wave_sampler: Node
var _ocean: Node3D
var _boat_motion: Node3D
var _boat_visual: Node3D
var _sunlight: DirectionalLight3D
var _automation_active := false
var _capture_in_progress := false


func _ready() -> void:
	_water = load("res://materials/sea_water_material.tres") as ShaderMaterial
	_bathymetry = get_parent().get_node_or_null("BathymetryManager")
	_camera = get_parent().get_node_or_null("PlayerBoat/FollowCameraRig/Camera3D") as Camera3D
	_camera_rig = get_parent().get_node_or_null("PlayerBoat/FollowCameraRig") as Node3D
	_wave_sampler = get_parent().get_node_or_null("WaveSampler")
	_ocean = get_parent().get_node_or_null("Ocean") as Node3D
	_boat_motion = get_parent().get_node_or_null("PlayerBoat/MotionRoot") as Node3D
	_boat_visual = get_parent().get_node_or_null("PlayerBoat/MotionRoot/VisualRoot") as Node3D
	_sunlight = get_parent().get_node_or_null("Sunlight") as DirectionalLight3D
	if _water == null or _bathymetry == null or _camera == null or _camera_rig == null or _wave_sampler == null or _ocean == null:
		push_error("Water capture runner is missing a required scene node or material.")
		return

	var replay_path := _user_arg_value("--water-grid-replay=")
	if not replay_path.is_empty():
		_automation_active = true
		_run_replay.call_deferred(replay_path)
	elif "--water-grid-capture-now" in OS.get_cmdline_user_args():
		_automation_active = true
		_run_startup_capture.call_deferred()


func _unhandled_key_input(event: InputEvent) -> void:
	if _automation_active or _capture_in_progress:
		return
	if not event is InputEventKey or not event.pressed or event.echo or event.physical_keycode != KEY_F9:
		return
	_capture_in_progress = true
	get_viewport().set_input_as_handled()
	_capture_manual_state.call_deferred()


func _capture_manual_state() -> void:
	await RenderingServer.frame_post_draw
	var capture_id := _unique_capture_id()
	var base_path := ProjectSettings.globalize_path(CAPTURE_DIR).path_join(capture_id)
	var image := get_viewport().get_texture().get_image()
	var png_path := base_path + ".png"
	var json_path := base_path + ".json"
	var image_error := image.save_png(png_path)
	if image_error != OK:
		push_error("Could not save manual water capture PNG (error %d): %s" % [image_error, png_path])
		_capture_in_progress = false
		return
	var state := _collect_state()
	state["capture_id"] = capture_id
	state["captured_at_local"] = Time.get_datetime_string_from_system(false, true)
	state["png_file"] = capture_id + ".png"
	var json_file := FileAccess.open(json_path, FileAccess.WRITE)
	if json_file == null:
		push_error("Screenshot saved, but state JSON could not be opened: %s" % json_path)
	else:
		json_file.store_string(JSON.stringify(state, "\t") + "\n")
		json_file.close()
		print("[WaterGridCapture] manual repro saved:\n  PNG: %s\n  JSON: %s" % [png_path, json_path])
	_capture_in_progress = false


func _run_startup_capture() -> void:
	# Optional graphical smoke-check hook; normal interactive use remains F9.
	for _frame in range(REPLAY_SETTLE_FRAMES):
		await get_tree().process_frame
	await _capture_manual_state()
	get_tree().quit(0)


func _collect_state() -> Dictionary:
	var texture := _water.get_shader_parameter("bathymetry_depth_texture") as Texture2D
	var effective_settings: Resource = _wave_sampler.call("get_effective_wave_settings")
	var waves: Array[Dictionary] = []
	if effective_settings != null and effective_settings.get("waves") is Array:
		for wave: Resource in effective_settings.get("waves"):
			waves.append({
				"steepness": wave.get("steepness"),
				"amplitude": wave.get("amplitude"),
				"direction_degrees": wave.get("direction_degrees"),
				"frequency": wave.get("frequency"),
				"speed": wave.get("speed"),
				"phase_degrees": wave.get("phase_degrees"),
			})
	var shader_parameters: Dictionary = {}
	for parameter: String in CAPTURED_SHADER_PARAMETERS:
		shader_parameters[parameter] = _json_safe(_water.get_shader_parameter(parameter))
	var wave_time := float(_wave_sampler.get("wave_time_seconds"))
	return {
		"schema_version": 1,
		"scene": "res://tests/water_minimal/water_minimal.tscn",
		"material": "res://materials/sea_water_material.tres",
		"shader": "res://shaders/sea_water.gdshader",
		"camera": {
			"world_position": _json_safe(_camera.global_position),
			"world_rotation_degrees": _json_safe(_camera.global_rotation_degrees),
			"fov_degrees": _camera.fov,
			"near": _camera.near,
			"far": _camera.far,
		},
		"window_size": _json_safe(get_window().size),
		"viewport_size": _json_safe(get_viewport().get_visible_rect().size),
		"wave_time_seconds": wave_time,
		"base_wave_strength": float(_wave_sampler.get("wave_strength")),
		"effective_wave_strength": float(_wave_sampler.call("get_effective_wave_strength")),
		"wave_settings": waves,
		"wave_parameter_revision": int(_wave_sampler.call("get_wave_parameter_revision")),
		"water_shader_parameters": shader_parameters,
		"bathymetry": {
			"texture_loaded": texture != null,
			"texture_size": _json_safe(Vector2i(texture.get_width(), texture.get_height())) if texture != null else null,
			"texture_path": str(_bathymetry.get("depth_texture_path")),
			"bounds_east_north": shader_parameters.get("bathymetry_bounds_east_north"),
			"depth_color_enabled": bool(shader_parameters.get("enable_depth_color", false)),
			"shallow_transparency_enabled": bool(shader_parameters.get("shallow_transparency_enabled", false)),
			"shallow_wave_constraint_enabled": bool(shader_parameters.get("shallow_wave_constraint_enabled", false)),
		},
		"ocean_mesh": {
			"outermost_resolution": int(_ocean.get("outermost_resolution")),
			"levels_of_detail": int(_ocean.get("levels_of_detail")),
			"unit_size": float(_ocean.get("unit_size")),
			"far_edge": float(_ocean.get("far_edge")),
		},
		"boat_visual_transform": _node_transform_snapshot(_boat_visual),
		"sunlight": _sunlight_snapshot(),
	}


func _run_replay(replay_path: String) -> void:
	var absolute_json_path := replay_path
	if replay_path.begins_with("res://"):
		absolute_json_path = ProjectSettings.globalize_path(replay_path)
	elif replay_path.begins_with("user://"):
		absolute_json_path = ProjectSettings.globalize_path(replay_path)
	if not FileAccess.file_exists(absolute_json_path):
		push_error("Water repro state JSON does not exist: %s" % absolute_json_path)
		get_tree().quit(2)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(absolute_json_path))
	if not parsed is Dictionary or int(parsed.get("schema_version", 0)) != 1:
		push_error("Unsupported or invalid water repro state JSON: %s" % absolute_json_path)
		get_tree().quit(2)
		return
	var state: Dictionary = parsed
	var output_dir := ProjectSettings.globalize_path(CAPTURE_DIR)
	var mkdir_error := DirAccess.make_dir_recursive_absolute(output_dir)
	if mkdir_error != OK:
		push_error("Could not create capture directory: %s (error %d)" % [output_dir, mkdir_error])
		get_tree().quit(2)
		return

	var wanted_window := _vector2i_from_json(state.get("window_size", []))
	if wanted_window.x > 0 and wanted_window.y > 0:
		get_window().size = wanted_window
	for _frame in range(REPLAY_SETTLE_FRAMES):
		await get_tree().process_frame
	var current_texture := _water.get_shader_parameter("bathymetry_depth_texture") as Texture2D
	if not _validate_bathymetry(state, current_texture):
		get_tree().quit(2)
		return

	_restore_ocean(state.get("ocean_mesh", {}))
	# Stop scene motion only after initialization; restore the captured view/state.
	_camera_rig.set_process(false)
	_wave_sampler.set_process(false)
	if _boat_motion != null:
		_boat_motion.set_process(false)
		_boat_motion.set_physics_process(false)
	if _boat_visual != null:
		_boat_visual.set_process(false)
		_boat_visual.set_physics_process(false)
		_restore_node_transform(_boat_visual, state.get("boat_visual_transform", {}))
	_restore_sunlight(state.get("sunlight", {}))
	_restore_shader_parameters(state.get("water_shader_parameters", {}))
	_wave_sampler.set("wave_time_seconds", float(state.get("wave_time_seconds", 0.0)))
	var camera_data: Dictionary = state.get("camera", {})
	_camera.global_position = _vector3_from_json(camera_data.get("world_position", []))
	_camera.global_rotation_degrees = _vector3_from_json(camera_data.get("world_rotation_degrees", []))
	_camera.fov = float(camera_data.get("fov_degrees", _camera.fov))
	_camera.near = float(camera_data.get("near", _camera.near))
	_camera.far = float(camera_data.get("far", _camera.far))
	_camera.make_current()
	for _frame in range(4):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw

	var run_id := _unique_capture_id().replace("water_repro_", "water_replay_")
	var report := {
		"schema_version": 1,
		"replay_state_json": absolute_json_path,
		"manual_grid_confirmation_flag": "--water-grid-confirmed" in OS.get_cmdline_user_args(),
		"replayed_camera": _camera_snapshot(),
		"replayed_shader_parameters": _current_shader_snapshot(),
		"detail_hash": "integer lattice hash",
		"captures": [],
	}
	_water.set_shader_parameter("water_diagnostic_mode", 0)
	await _settle_capture_state()
	await _save_replay_capture(run_id + "_normal", "Restored F9 state with the fixed integer detail hash", report)
	if "--water-grid-confirmed" in OS.get_cmdline_user_args():
		for test_case: Dictionary in DIAGNOSTIC_MODES:
			_water.set_shader_parameter("water_diagnostic_mode", int(test_case["mode"]))
			for _frame in range(4):
				await get_tree().process_frame
			await RenderingServer.frame_post_draw
			await _save_replay_capture(
				run_id + "_" + String(test_case["name"]),
				"Confirmed replay diagnostic mode %d" % int(test_case["mode"]),
				report
			)
	var report_path := output_dir.path_join(run_id + ".json")
	var report_file := FileAccess.open(report_path, FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "\t") + "\n")
		report_file.close()
	print("[WaterGridCapture] replay captures saved to %s" % output_dir)
	get_tree().quit(0)


func _save_replay_capture(filename: String, note: String, report: Dictionary) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path(CAPTURE_DIR).path_join(filename + ".png")
	var save_error := image.save_png(path)
	if save_error != OK:
		push_error("Could not save replay capture (error %d): %s" % [save_error, path])
		return
	report["captures"].append({
		"file": filename + ".png",
		"size": _json_safe(Vector2i(image.get_width(), image.get_height())),
		"note": note,
		"camera": _camera_snapshot(),
		"shader_parameters": _current_shader_snapshot(),
	})
	print("[WaterGridCapture] replay PNG: %s" % path)


func _settle_capture_state() -> void:
	for _frame in range(4):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw


func _validate_bathymetry(state: Dictionary, texture: Texture2D) -> bool:
	var expected: Dictionary = state.get("bathymetry", {})
	if not bool(expected.get("texture_loaded", false)):
		push_error("Repro capture says its bathymetry texture was not loaded; cannot replay this state.")
		return false
	if texture == null:
		push_error("Current scene did not bind the bathymetry texture; cannot replay this state.")
		return false
	var expected_size := _vector2i_from_json(expected.get("texture_size", []))
	if expected_size != Vector2i(texture.get_width(), texture.get_height()):
		push_error("Bathymetry texture dimensions differ from the repro capture.")
		return false
	if str(expected.get("texture_path", "")) != str(_bathymetry.get("depth_texture_path")):
		push_error("Bathymetry source path differs from the repro capture.")
		return false
	var expected_bounds: Variant = expected.get("bounds_east_north", [])
	var actual_bounds: Variant = _water.get_shader_parameter("bathymetry_bounds_east_north")
	if expected_bounds is Array and expected_bounds.size() >= 4 and actual_bounds is Vector4:
		var actual_values := [actual_bounds.x, actual_bounds.y, actual_bounds.z, actual_bounds.w]
		for index in range(4):
			if absf(float(expected_bounds[index]) - actual_values[index]) > 0.1:
				push_error("Bathymetry world bounds differ from the repro capture.")
				return false
	return true


func _restore_ocean(saved: Dictionary) -> void:
	if saved.is_empty():
		return
	var changed := false
	for property: String in ["outermost_resolution", "levels_of_detail", "unit_size", "far_edge"]:
		if saved.has(property) and not is_equal_approx(float(_ocean.get(property)), float(saved[property])):
			_ocean.set(property, saved[property])
			changed = true
	if changed:
		_ocean.call("build_meshes")


func _restore_shader_parameters(saved: Dictionary) -> void:
	for parameter: String in saved:
		if parameter not in CAPTURED_SHADER_PARAMETERS:
			continue
		if parameter in ["bathymetry_texture_size", "bathymetry_bounds_east_north"]:
			continue
		var value: Variant = saved[parameter]
		if parameter in WAVE_ARRAY_PARAMETERS and value is Array:
			var packed := PackedFloat32Array()
			for number: Variant in value:
				packed.append(float(number))
			value = packed
		elif parameter == "ripple_direction" and value is Array and value.size() >= 2:
			value = Vector2(float(value[0]), float(value[1]))
		_water.set_shader_parameter(parameter, value)


func _restore_node_transform(node: Node3D, data: Dictionary) -> void:
	if node == null or data.is_empty():
		return
	node.global_position = _vector3_from_json(data.get("position", []))
	node.global_rotation_degrees = _vector3_from_json(data.get("rotation_degrees", []))
	var saved_scale := _vector3_from_json(data.get("scale", []))
	if saved_scale != Vector3.ZERO:
		node.scale = saved_scale


func _node_transform_snapshot(node: Node3D) -> Dictionary:
	if node == null:
		return {}
	return {
		"position": _json_safe(node.global_position),
		"rotation_degrees": _json_safe(node.global_rotation_degrees),
		"scale": _json_safe(node.global_basis.get_scale()),
	}


func _sunlight_snapshot() -> Dictionary:
	if _sunlight == null:
		return {}
	return {
		"rotation_degrees": _json_safe(_sunlight.global_rotation_degrees),
		"color": _json_safe(_sunlight.light_color),
		"energy": _sunlight.light_energy,
		"shadow_enabled": _sunlight.shadow_enabled,
	}


func _restore_sunlight(data: Dictionary) -> void:
	if _sunlight == null or data.is_empty():
		return
	_sunlight.global_rotation_degrees = _vector3_from_json(data.get("rotation_degrees", []))
	_sunlight.light_color = _color_from_json(data.get("color", []), _sunlight.light_color)
	_sunlight.light_energy = float(data.get("energy", _sunlight.light_energy))
	_sunlight.shadow_enabled = bool(data.get("shadow_enabled", _sunlight.shadow_enabled))


func _camera_snapshot() -> Dictionary:
	return {
		"world_position": _json_safe(_camera.global_position),
		"world_rotation_degrees": _json_safe(_camera.global_rotation_degrees),
		"fov_degrees": _camera.fov,
		"near": _camera.near,
		"far": _camera.far,
	}


func _current_shader_snapshot() -> Dictionary:
	var values: Dictionary = {}
	for parameter: String in CAPTURED_SHADER_PARAMETERS:
		values[parameter] = _json_safe(_water.get_shader_parameter(parameter))
	return values


func _json_safe(value: Variant) -> Variant:
	if value is Vector2:
		return [value.x, value.y]
	if value is Vector2i:
		return [value.x, value.y]
	if value is Vector3:
		return [value.x, value.y, value.z]
	if value is Vector3i:
		return [value.x, value.y, value.z]
	if value is Vector4:
		return [value.x, value.y, value.z, value.w]
	if value is Color:
		return [value.r, value.g, value.b, value.a]
	if value is PackedFloat32Array or value is PackedFloat64Array or value is PackedInt32Array or value is PackedInt64Array:
		var result: Array = []
		for item: Variant in value:
			result.append(item)
		return result
	if value is Array:
		var array_result: Array = []
		for item: Variant in value:
			array_result.append(_json_safe(item))
		return array_result
	if value is Dictionary:
		var dictionary_result: Dictionary = {}
		for key: Variant in value:
			dictionary_result[str(key)] = _json_safe(value[key])
		return dictionary_result
	return value


func _vector2i_from_json(value: Variant) -> Vector2i:
	if value is Array and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return Vector2i.ZERO


func _vector3_from_json(value: Variant) -> Vector3:
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return Vector3.ZERO


func _color_from_json(value: Variant, fallback: Color) -> Color:
	if value is Array and value.size() >= 3:
		return Color(float(value[0]), float(value[1]), float(value[2]), float(value[3]) if value.size() >= 4 else 1.0)
	return fallback


func _unique_capture_id() -> String:
	var date := Time.get_datetime_dict_from_system()
	var subsecond := Time.get_ticks_usec() % 1000000
	var stem := "water_repro_%04d%02d%02d_%02d%02d%02d_%06d" % [
		int(date["year"]), int(date["month"]), int(date["day"]),
		int(date["hour"]), int(date["minute"]), int(date["second"]), subsecond,
	]
	var candidate := stem
	var suffix := 1
	while FileAccess.file_exists(ProjectSettings.globalize_path(CAPTURE_DIR).path_join(candidate + ".png")) or FileAccess.file_exists(ProjectSettings.globalize_path(CAPTURE_DIR).path_join(candidate + ".json")):
		candidate = "%s_%02d" % [stem, suffix]
		suffix += 1
	return candidate


func _user_arg_value(prefix: String) -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(prefix):
			return argument.trim_prefix(prefix)
	return ""
