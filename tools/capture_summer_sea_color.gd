extends SceneTree
## Captures reproducible water-color comparisons from the actual main scene.
## Run: godot --path . --script res://tools/capture_summer_sea_color.gd

const MAIN_SCENE := "res://scenes/main.tscn"
const OUTPUT_DIR := "res://docs/summer_sea_color"
const FPS_RUNS := 3
const FPS_WARMUP_FRAMES := 45
const FPS_MEASURE_FRAMES := 180

const BEFORE_PALETTE := {
	"albedo": Color(0.026, 0.47, 0.39, 1.0),
	"albedo_fresnel": Color(0.17, 0.52, 0.49, 1.0),
	"shallow_water_color": Color(0.22, 0.62, 0.48, 1.0),
	"mid_water_color": Color(0.06, 0.42, 0.46, 1.0),
	"blue_water_color": Color(0.04, 0.30, 0.44, 1.0),
}

const AFTER_CLEAR_PALETTE := {
	"albedo": Color(0.14, 0.43, 0.58, 1.0),
	"albedo_fresnel": Color(0.20, 0.50, 0.61, 1.0),
	"shallow_water_color": Color(0.33, 0.57, 0.57, 1.0),
	"mid_water_color": Color(0.19, 0.46, 0.55, 1.0),
	"blue_water_color": Color(0.14, 0.38, 0.54, 1.0),
}

const OLD_NORMALS := {
	"wave_normal_strength": 0.45,
	"detail_normal_strength_near": 0.8,
	"depth_color_strength": 0.6,
}

var _captures: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	var packed_scene := load(MAIN_SCENE) as PackedScene
	if packed_scene == null:
		push_error("Could not load %s" % MAIN_SCENE)
		quit(1)
		return

	var main := packed_scene.instantiate()
	root.add_child(main)
	for _frame in range(12):
		await process_frame

	var material := (main.get_node("BathymetryManager") as BathymetryManager).water_material
	var bathymetry := main.get_node("BathymetryManager") as BathymetryManager
	var weather := main.get_node("WeatherController") as WeatherController
	var quality := main.get_node("QualityManager") as QualityManager
	var boat := main.get_node("PlayerBoat")
	var motion_root := boat.get_node("MotionRoot") as Node3D
	var camera_rig := boat.get_node("FollowCameraRig") as Node3D
	var camera := camera_rig.get_node("Camera3D") as Camera3D
	if material == null or weather == null or bathymetry == null or quality == null or camera == null:
		push_error("Main scene is missing a required water-color capture node.")
		main.queue_free()
		await process_frame
		quit(1)
		return

	# Use the same High / native-resolution conditions for every comparison,
	# without writing the player's persistent quality settings.
	var old_quality := quality.get_quality_index()
	quality.set_quality_for_benchmark(QualityManager.Quality.HIGH)
	for _frame in range(90):
		await process_frame
	
	# Freeze the common Gerstner time and stop navigation/camera drift. These
	# settings are shared by all palette and depth-color captures.
	material.set_shader_parameter("freeze_time", true)
	material.set_shader_parameter("water_diagnostic_mode", 0)
	motion_root.set_process(false)
	for _frame in range(12):
		await process_frame
	camera_rig.set_process(false)
	camera.make_current()
	await _settle_frames(6)

	var old_vsync := DisplayServer.window_get_vsync_mode()
	var old_max_fps := Engine.max_fps
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	var output_path := ProjectSettings.globalize_path(OUTPUT_DIR)
	DirAccess.make_dir_recursive_absolute(output_path)
	var old_depth_enabled := bathymetry.enable_depth_color
	var old_transition_seconds := weather.transition_seconds
	var old_camera_transform := camera.global_transform
	var old_camera_current := camera.current
	var old_depth_strength: float = float(material.get_shader_parameter("depth_color_strength"))
	var old_diagnostic_mode: int = int(material.get_shader_parameter("water_diagnostic_mode"))
	var original_material_values: Dictionary = {}
	for key in AFTER_CLEAR_PALETTE:
		original_material_values[key] = material.get_shader_parameter(key)

	weather.transition_seconds = 0.75
	weather.set_weather_by_index(WeatherController.Preset.CLEAR)
	await _settle_frames(50)
	_apply_palette(material, BEFORE_PALETTE)
	_apply_normals(material)
	material.set_shader_parameter("depth_color_strength", 0.6)
	bathymetry.set_depth_color_enabled(true)
	# Capture the actual old High-profile override separately. The following
	# A1/B pair uses the documented 0.8 normal value on both sides to isolate
	# water-color changes from the quality-profile correction.
	material.set_shader_parameter("detail_normal_strength_near", 2.5)
	await _capture_frame("A0_clear_previous_high_runtime", output_path)
	material.set_shader_parameter("detail_normal_strength_near", 0.8)
	await _capture_frame("A_clear_before_depth_on", output_path)
	var fps_before := await _measure_fps(material, bathymetry, BEFORE_PALETTE)

	_apply_palette(material, AFTER_CLEAR_PALETTE)
	_apply_normals(material)
	material.set_shader_parameter("depth_color_strength", 0.6)
	bathymetry.set_depth_color_enabled(true)
	await _capture_frame("B_clear_after_depth_on", output_path)
	var fps_after := await _measure_fps(material, bathymetry, AFTER_CLEAR_PALETTE)

	bathymetry.set_depth_color_enabled(false)
	await _capture_frame("C_clear_after_depth_off", output_path)
	bathymetry.set_depth_color_enabled(true)
	await _capture_frame("D_clear_after_depth_on", output_path)

	# Check both non-clear palettes after their normal, smooth weather transitions.
	_apply_palette(material, AFTER_CLEAR_PALETTE)
	weather.set_weather_by_index(WeatherController.Preset.PARTLY_CLOUDY)
	await _settle_frames(105)
	await _capture_frame("E_partly_cloudy", output_path)
	weather.set_weather_by_index(WeatherController.Preset.OVERCAST)
	await _settle_frames(105)
	await _capture_frame("F_overcast", output_path)

	# Side-aft view for the existing sunlight reflection. The sun, weather,
	# exposure, water phase, and material remain unchanged; only the camera moves.
	weather.set_weather_by_index(WeatherController.Preset.CLEAR)
	await _settle_frames(105)
	var boat_position := motion_root.global_position
	camera.global_position = boat_position + Vector3(18.0, 8.0, -34.0)
	camera.look_at(boat_position + Vector3.UP * 1.3, Vector3.UP)
	await _capture_frame("G_clear_after_side_reflection", output_path)

	var metrics: Dictionary = quality.get_render_metrics()
	var report := {
		"engine": Engine.get_version_info(),
		"renderer": RenderingServer.get_video_adapter_name(),
		"processor": OS.get_processor_name(),
		"window_px": [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y],
	"viewport_px": [root.size.x, root.size.y],
		"internal_3d_px_estimate": [metrics["internal_3d_px_estimate"].x, metrics["internal_3d_px_estimate"].y],
		"quality": "High",
		"resolution_scale": metrics["resolution_scale"],
		"vsync_during_measurement": DisplayServer.VSYNC_DISABLED,
		"max_fps_during_measurement": 0,
		"wave_time_frozen": true,
		"wave_normal_strength": material.get_shader_parameter("wave_normal_strength"),
		"detail_normal_strength_near": material.get_shader_parameter("detail_normal_strength_near"),
		"depth_color_strength": material.get_shader_parameter("depth_color_strength"),
		"previous_high_profile_detail_normal_strength_near": 2.5,
		"controlled_color_comparison_detail_normal_strength_near": 0.8,
		"palette_before": _serialize_palette(BEFORE_PALETTE),
		"palette_after_clear": _serialize_palette(AFTER_CLEAR_PALETTE),
	"capture_resolution": [root.size.x, root.size.y],
		"captures": _captures,
		"fps_before": fps_before,
		"fps_after": fps_after,
	}
	var report_file := FileAccess.open(output_path.path_join("report.json"), FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "  ") + "\n")
	print(JSON.stringify(report, "  "))

	# Restore runtime state before disposing the test scene.
	_apply_palette(material, original_material_values)
	material.set_shader_parameter("depth_color_strength", old_depth_strength)
	material.set_shader_parameter("water_diagnostic_mode", old_diagnostic_mode)
	material.set_shader_parameter("freeze_time", false)
	bathymetry.set_depth_color_enabled(old_depth_enabled)
	weather.transition_seconds = old_transition_seconds
	camera.global_transform = old_camera_transform
	if old_camera_current:
		camera.make_current()
	Engine.max_fps = old_max_fps
	DisplayServer.window_set_vsync_mode(old_vsync)
	quality.set_quality_for_benchmark(old_quality)
	main.queue_free()
	await process_frame
	quit()


func _apply_palette(material: ShaderMaterial, palette: Dictionary) -> void:
	for key in palette:
		material.set_shader_parameter(str(key), palette[key])


func _serialize_palette(palette: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for key in palette:
		var color: Color = palette[key]
		result[str(key)] = [color.r, color.g, color.b, color.a]
	return result


func _apply_normals(material: ShaderMaterial) -> void:
	for key in OLD_NORMALS:
		material.set_shader_parameter(key, OLD_NORMALS[key])


func _capture_frame(capture_name: String, output_path: String) -> void:
	await _settle_frames(5)
	var image := root.get_texture().get_image()
	var path := output_path.path_join(capture_name + ".png")
	var error := image.save_png(path)
	_captures.append({
		"name": capture_name,
		"width": image.get_width(),
		"height": image.get_height(),
		"path": path,
		"save_error": error,
	})


func _measure_fps(material: ShaderMaterial, bathymetry: BathymetryManager, palette: Dictionary) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	for run_index in range(FPS_RUNS):
		_apply_palette(material, palette)
		material.set_shader_parameter("water_diagnostic_mode", 0)
		bathymetry.set_depth_color_enabled(true)
		for _frame in range(FPS_WARMUP_FRAMES):
			await process_frame
		var start_us := Time.get_ticks_usec()
		for _frame in range(FPS_MEASURE_FRAMES):
			await process_frame
		var elapsed := float(Time.get_ticks_usec() - start_us) / 1000000.0
		results.append({
			"run": run_index + 1,
			"frames": FPS_MEASURE_FRAMES,
			"elapsed_seconds": elapsed,
			"average_fps": float(FPS_MEASURE_FRAMES) / maxf(elapsed, 0.000001),
			"frame_time_ms": elapsed * 1000.0 / float(FPS_MEASURE_FRAMES),
		})
	return results


func _settle_frames(count: int) -> void:
	for _frame in range(count):
		await process_frame
