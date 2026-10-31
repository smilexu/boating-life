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
const NORMAL_SOURCE_MODES := [
	{"name": "mode2", "mode": 2},
	{"name": "N1_gerstner_only", "mode": 15},
	{"name": "N2_detail_only", "mode": 16},
]
const DETAIL_WEIGHT_MODES := [
	{"name": "detail_weight_0", "mode": 17},
	{"name": "detail_weight_05", "mode": 18},
	{"name": "detail_weight_1", "mode": 19},
]
const NOISE_CELL_MODES := [
	{"name": "noise_cell_boundaries", "mode": 20},
]
const FRESNEL_ISOLATION_MODES := [
	{"name": "B_mixed_lighting_gerstner_fresnel", "mode": 22},
	{"name": "C_gerstner_lighting_mixed_fresnel", "mode": 23},
]
const FREQUENCY_LAYER_CASES := [
	{"name": "B_low_frequency_only", "layer": 1},
	{"name": "C_mid_frequency_only", "layer": 2},
	{"name": "D_high_frequency_only", "layer": 3},
	{"name": "E_excluding_low_frequency", "layer": 4},
]
const LOW_FREQUENCY_SCALE_CASES := [
	{"name": "B_candidate_low_scale_two_thirds", "scale": 1},
	{"name": "C_candidate_low_scale_one_half", "scale": 2},
]
const NORMAL_COMPOSITION_CASES := [
	{"name": "B_slope_composition_candidate", "candidate": true},
]
const SLOPE_LIGHT_CASES := [
	{"name": "S_raw_micro_slope", "mode": 24},
	{"name": "L_fixed_lambert", "mode": 25},
]
const CAPTURED_SHADER_PARAMETERS := [
	"water_diagnostic_mode", "enable_depth_color", "shallow_transparency_enabled",
	"freeze_time", "WaveTime", "WaveCount", "WaveSteepnesses", "WaveAmplitudes",
	"WaveDirectionsDegrees", "WaveFrequencies", "WaveSpeeds", "WavePhases",
	"depth_color_strength", "wave_normal_strength", "specular", "metallic",
	"water_roughness_near", "water_roughness_far", "water_specular_near_multiplier",
	"water_specular_far_multiplier", "ripple_scale", "ripple_speed", "ripple_direction",
	"detail_noise_candidate_enabled",
	"detail_integer_hash_enabled",
	"detail_noise_layer_test",
	"detail_noise_low_scale_test",
	"detail_normal_slope_composition_candidate",
	"gerstner_geometry_normal_candidate",
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
	if "--water-grid-no-sun-shadows" in OS.get_cmdline_user_args() and _sunlight != null:
		_sunlight.shadow_enabled = false
	_restore_shader_parameters(state.get("water_shader_parameters", {}))
	var frequency_layer_test := "--water-grid-frequency-layers" in OS.get_cmdline_user_args()
	var low_scale_test := "--water-grid-low-frequency-scale" in OS.get_cmdline_user_args()
	var normal_composition_test := "--water-grid-normal-composition" in OS.get_cmdline_user_args()
	var slope_light_test := "--water-grid-slope-light" in OS.get_cmdline_user_args()
	var hash_compare := _user_arg_value("--water-grid-hash-compare=")
	if not hash_compare.is_empty() and hash_compare not in ["legacy", "fixed"]:
		push_error("Unknown water hash comparison variant: %s (expected legacy or fixed)." % hash_compare)
		get_tree().quit(2)
		return
	var use_candidate_noise := not (frequency_layer_test or low_scale_test or normal_composition_test or slope_light_test or not hash_compare.is_empty()) and "--water-grid-noise-candidate" in OS.get_cmdline_user_args()
	_water.set_shader_parameter("detail_noise_candidate_enabled", use_candidate_noise)
	if not hash_compare.is_empty():
		_water.set_shader_parameter("detail_integer_hash_enabled", hash_compare == "fixed")
	_water.set_shader_parameter("detail_noise_layer_test", 0)
	_water.set_shader_parameter("detail_noise_low_scale_test", 0)
	_water.set_shader_parameter("detail_normal_slope_composition_candidate", false)
	_water.set_shader_parameter("gerstner_geometry_normal_candidate", "--water-grid-gerstner-candidate" in OS.get_cmdline_user_args())
	if slope_light_test:
		_water.set_shader_parameter("gerstner_geometry_normal_candidate", false)
		_water.set_shader_parameter("water_diagnostic_mode", 0)
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
		"detail_noise_variant": "candidate" if use_candidate_noise else "legacy",
		"detail_hash_variant": hash_compare if not hash_compare.is_empty() else "material-default",
		"frequency_layer_test": frequency_layer_test,
		"low_frequency_scale_test": low_scale_test,
		"normal_composition_test": normal_composition_test,
		"slope_light_test": slope_light_test,
		"slope_encoding_range": [-0.25, 0.25],
		"slope_clipping_channel": "blue=1 if either slope component clips",
		"lambert_world_light_direction_before_normalization": [0.7, 0.35, 0.62],
		"slope_light_output_pipeline": "S/L only: unshaded, fog disabled, linear tonemap; glow/SSAO/SSR disabled on a runtime Environment copy",
		"captures": [],
	}
	var fresnel_isolation := "--water-grid-fresnel-isolation" in OS.get_cmdline_user_args()
	if not hash_compare.is_empty():
		_water.set_shader_parameter("water_diagnostic_mode", 0)
		await _settle_capture_state()
		await _save_replay_capture(
			run_id + "_" + ("Fixed" if hash_compare == "fixed" else "Legacy") + "_normal",
			"Normal water render with %s integer value-noise hash" % ("fixed" if hash_compare == "fixed" else "legacy"),
			report
		)
	elif normal_composition_test:
		_water.set_shader_parameter("water_diagnostic_mode", 0)
		await _settle_capture_state()
		await _save_replay_capture(run_id + "_A_legacy_normal_composition", "A: Legacy normal composition", report)
	elif low_scale_test:
		_water.set_shader_parameter("water_diagnostic_mode", 0)
		await _settle_capture_state()
		await _save_replay_capture(run_id + "_A_legacy_low_scale", "A: Legacy low-frequency scale", report)
	elif frequency_layer_test:
		_water.set_shader_parameter("water_diagnostic_mode", 0)
		await _settle_capture_state()
		await _save_replay_capture(run_id + "_A_all_frequency_layers", "A: all Legacy Value Noise FBM layers", report)
	elif fresnel_isolation:
		_water.set_shader_parameter("water_diagnostic_mode", 21)
		for _frame in range(4):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		await _save_replay_capture(run_id + "_A_mixed_light_and_fresnel", "A: mixed normal for lighting and Fresnel", report)
	else:
		var noise_variant := "candidate" if use_candidate_noise else "legacy"
		await _save_replay_capture(
			run_id + "_" + noise_variant,
			"Restored F9 state, normal shader mode, detail noise: %s" % noise_variant,
			report
		)
	if "--water-grid-confirmed" in OS.get_cmdline_user_args():
		var modes_to_capture: Array = DIAGNOSTIC_MODES
		if not hash_compare.is_empty():
			modes_to_capture = [{"name": "S_raw_micro_slope", "mode": 24}]
			_use_unshaded_water_diagnostics()
		elif slope_light_test:
			modes_to_capture = SLOPE_LIGHT_CASES
			_use_unshaded_water_diagnostics()
		elif normal_composition_test:
			modes_to_capture = NORMAL_COMPOSITION_CASES
		elif low_scale_test:
			modes_to_capture = LOW_FREQUENCY_SCALE_CASES
		elif frequency_layer_test:
			modes_to_capture = FREQUENCY_LAYER_CASES
		elif fresnel_isolation:
			modes_to_capture = FRESNEL_ISOLATION_MODES
		elif "--water-grid-detail-weight-sweep" in OS.get_cmdline_user_args():
			modes_to_capture = DETAIL_WEIGHT_MODES
		elif "--water-grid-noise-cells" in OS.get_cmdline_user_args():
			modes_to_capture = NOISE_CELL_MODES
		elif "--water-grid-normal-source" in OS.get_cmdline_user_args():
			modes_to_capture = NORMAL_SOURCE_MODES
		for test_case: Dictionary in modes_to_capture:
			if normal_composition_test:
				_water.set_shader_parameter("water_diagnostic_mode", 0)
				_water.set_shader_parameter("detail_noise_candidate_enabled", false)
				_water.set_shader_parameter("detail_noise_layer_test", 0)
				_water.set_shader_parameter("detail_noise_low_scale_test", 0)
				_water.set_shader_parameter(
					"detail_normal_slope_composition_candidate",
					bool(test_case["candidate"])
				)
			elif low_scale_test:
				_water.set_shader_parameter("water_diagnostic_mode", 0)
				_water.set_shader_parameter("detail_noise_layer_test", 0)
				_water.set_shader_parameter("detail_noise_low_scale_test", int(test_case["scale"]))
			elif frequency_layer_test:
				_water.set_shader_parameter("water_diagnostic_mode", 0)
				_water.set_shader_parameter("detail_noise_layer_test", int(test_case["layer"]))
			else:
				_water.set_shader_parameter("water_diagnostic_mode", int(test_case["mode"]))
			for _frame in range(4):
				await get_tree().process_frame
			await RenderingServer.frame_post_draw
			await _save_replay_capture(
				run_id + "_" + ("Fixed" if hash_compare == "fixed" else "Legacy") + "_S_raw_micro_slope"
				if not hash_compare.is_empty() else run_id + "_%s" % test_case["name"],
				("Slope composition candidate" if bool(test_case["candidate"]) else "Legacy normal composition")
				if normal_composition_test else ("Low frequency spatial scale candidate %d" % int(test_case["scale"]))
				if low_scale_test else ("Frequency layer isolation %d" % int(test_case["layer"]))
				if frequency_layer_test else "Confirmed replay diagnostic mode %d" % int(test_case["mode"]),
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


func _use_unshaded_water_diagnostics() -> void:
	# Diagnostic colors encode data: keep display conversion fixed and remove
	# post effects that could mix channels or spread pixels. Production capture
	# has already been saved with the original environment.
	var world_environment := get_parent().get_node_or_null("WorldEnvironment") as WorldEnvironment
	if world_environment != null and world_environment.environment != null:
		var diagnostic_environment := world_environment.environment.duplicate() as Environment
		diagnostic_environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		diagnostic_environment.glow_enabled = false
		diagnostic_environment.ssao_enabled = false
		diagnostic_environment.ssr_enabled = false
		world_environment.environment = diagnostic_environment
	var saved_uniforms := {}
	for uniform: Dictionary in _water.shader.get_shader_uniform_list():
		var parameter := String(uniform["name"])
		var value: Variant = _water.get_shader_parameter(parameter)
		if value != null:
			saved_uniforms[parameter] = value
	var diagnostic_shader := Shader.new()
	diagnostic_shader.code = _water.shader.code.replace("render_mode ", "render_mode unshaded, fog_disabled, ")
	_water.shader = diagnostic_shader
	for parameter: String in saved_uniforms:
		_water.set_shader_parameter(parameter, saved_uniforms[parameter])


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
