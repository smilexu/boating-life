extends SceneTree
## Captures controlled sun and water-highlight comparisons from the production scene.
## Run: godot --path . --script res://tools/capture_sun_reflection_diagnostics.gd

const MAIN_SCENE := "res://scenes/main.tscn"
const OUTPUT_DIR := "res://docs/sun_reflection"
const SUN_CAMERA_FOV := 20.0
const BASELINE_SUN_ANGLE := 12.0
const FINAL_SUN_ANGLE := 1.4
const BASELINE_WATER_SPECULAR := 0.24
const BASELINE_WATER_ROUGHNESS_NEAR := 0.10
const BASELINE_WATER_ROUGHNESS_FAR := 0.34
const FINAL_WATER_SPECULAR := 0.18
const FINAL_WATER_ROUGHNESS_NEAR := 0.075
const FINAL_WATER_ROUGHNESS_FAR := 0.29

var captures: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	root.size = Vector2i(1920, 1080)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var packed := load(MAIN_SCENE) as PackedScene
	if packed == null:
		push_error("Could not load %s" % MAIN_SCENE)
		quit(1)
		return
	var main := packed.instantiate()
	root.add_child(main)
	await _wait_frames(48)

	var environment := (main.get_node("WorldEnvironment") as WorldEnvironment).environment
	var sky_material := environment.sky.sky_material as ProceduralSkyMaterial
	var quality := main.get_node("QualityManager") as QualityManager
	var water := (main.get_node("BathymetryManager") as BathymetryManager).water_material
	var weather := main.get_node("WeatherController") as WeatherController
	var wave_sampler := main.get_node("WaveSampler") as WaveSampler
	var motion_root := main.get_node("PlayerBoat/MotionRoot") as Node3D
	var camera_rig := main.get_node("PlayerBoat/FollowCameraRig") as Node3D
	var camera := main.get_node("PlayerBoat/FollowCameraRig/Camera3D") as Camera3D
	var boat := main.get_node("PlayerBoat") as Node3D
	var ocean := main.get_node("Ocean") as Node3D
	var region := main.get_node("OresundRegion") as Node3D
	if environment == null or sky_material == null or quality == null or water == null or weather == null or camera == null:
		push_error("Main scene is missing sun-reflection diagnostic dependencies.")
		quit(1)
		return

	quality.set_quality_for_benchmark(QualityManager.Quality.HIGH)
	var original_window_vsync := DisplayServer.window_get_vsync_mode()
	var original_environment := environment.duplicate(true) as Environment
	var original_sun_curve := sky_material.sun_curve
	var original_clouds_enabled := quality.get_clouds_enabled()
	var original_water_mode := int(water.get_shader_parameter("water_diagnostic_mode"))
	var original_sun_energy := (main.get_node("Sunlight") as DirectionalLight3D).light_energy
	var original_sun_azimuth := weather.get_sun_azimuth()
	var original_sun_elevation := weather.get_sun_elevation()
	var original_frame_limit := quality.get_frame_limit_index()
	var original_water_parameters := {
		"material_specular": water.get_shader_parameter("specular"),
		"near_multiplier": water.get_shader_parameter("water_specular_near_multiplier"),
		"far_multiplier": water.get_shader_parameter("water_specular_far_multiplier"),
		"roughness_near": water.get_shader_parameter("water_roughness_near"),
		"roughness_far": water.get_shader_parameter("water_roughness_far"),
		"sun_glitter_intensity": water.get_shader_parameter("sun_glitter_intensity"),
		"wave_normal_strength": water.get_shader_parameter("wave_normal_strength"),
		"detail_normal_strength_near": water.get_shader_parameter("detail_normal_strength_near"),
	}

	motion_root.set_process(false)
	camera_rig.set_process(false)
	wave_sampler.set_process(false)
	water.set_shader_parameter("freeze_time", true)
	water.set_shader_parameter("WaveTime", 11.0)
	_set_canvas_layers_visible(main, false)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var output_path := ProjectSettings.globalize_path(OUTPUT_DIR)
	DirAccess.make_dir_recursive_absolute(output_path)

	# Sun-only view: point the camera along the weather controller's actual sun direction.
	var sun_direction := _sun_direction(original_sun_azimuth, original_sun_elevation)
	camera.global_position = boat.global_position + Vector3(0.0, 180.0, 0.0)
	camera.look_at(camera.global_position + sun_direction * 300.0, Vector3.UP)
	camera.fov = SUN_CAMERA_FOV
	camera.near = 0.1
	camera.far = 2000.0
	camera.make_current()
	ocean.visible = false
	region.visible = false
	boat.visible = false
	quality.set_clouds_enabled(false)
	environment.glow_enabled = true
	environment.fog_enabled = true
	sky_material.sun_angle_max = BASELINE_SUN_ANGLE
	await _wait_frames(90)
	await _capture_frame("sun_A_original_full_environment", output_path)
	environment.glow_enabled = false
	await _wait_frames(24)
	await _capture_frame("sun_diag_glow_off", output_path)
	environment.glow_enabled = true
	environment.fog_enabled = false
	await _wait_frames(24)
	await _capture_frame("sun_diag_fog_off", output_path)
	environment.fog_enabled = false
	environment.glow_enabled = false
	await _wait_frames(24)
	await _capture_frame("sun_diag_glow_and_fog_off", output_path)
	environment.glow_enabled = original_environment.glow_enabled
	environment.fog_enabled = original_environment.fog_enabled
	sky_material.sun_angle_max = FINAL_SUN_ANGLE
	await _wait_frames(36)
	await _capture_frame("sun_B_after_disc_1_4deg", output_path)

	# Ocean view: camera and wave phase remain fixed while contribution modes change.
	ocean.visible = true
	region.visible = true
	boat.visible = true
	quality.set_clouds_enabled(original_clouds_enabled)
	water.set_shader_parameter("specular", BASELINE_WATER_SPECULAR)
	water.set_shader_parameter("water_roughness_near", BASELINE_WATER_ROUGHNESS_NEAR)
	water.set_shader_parameter("water_roughness_far", BASELINE_WATER_ROUGHNESS_FAR)
	# A mirror reflects incoming sun rays toward the opposite horizontal azimuth.
	var waterward := -Vector3(sun_direction.x, 0.0, sun_direction.z).normalized()
	var reflection_camera_position := boat.global_position + waterward * 62.0 + Vector3.UP * 12.0
	camera.global_position = reflection_camera_position
	camera.look_at(boat.global_position + Vector3.UP * 1.8, Vector3.UP)
	camera.fov = 48.0
	camera.far = 10000.0
	water.set_shader_parameter("water_diagnostic_mode", 0)
	await _wait_frames(48)
	await _capture_frame("reflection_C_original_full_shading", output_path)
	var fps_before_first := await _measure_fps(5.0)
	environment.glow_enabled = false
	await _wait_frames(24)
	await _capture_frame("reflection_diag_glow_off", output_path)
	environment.glow_enabled = original_environment.glow_enabled
	water.set_shader_parameter("water_diagnostic_mode", 7)
	await _wait_frames(24)
	await _capture_frame("reflection_diag_diffuse_only", output_path)
	water.set_shader_parameter("water_diagnostic_mode", 8)
	await _wait_frames(24)
	await _capture_frame("reflection_diag_specular_only", output_path)
	water.set_shader_parameter("water_diagnostic_mode", 10)
	await _wait_frames(24)
	await _capture_frame("reflection_diag_specular_flat_normal", output_path)
	water.set_shader_parameter("water_diagnostic_mode", 0)
	environment.ssr_enabled = false
	await _wait_frames(24)
	await _capture_frame("reflection_diag_ssr_off", output_path)
	environment.ssr_enabled = original_environment.ssr_enabled
	water.set_shader_parameter("specular", FINAL_WATER_SPECULAR)
	water.set_shader_parameter("water_roughness_near", FINAL_WATER_ROUGHNESS_NEAR)
	water.set_shader_parameter("water_roughness_far", FINAL_WATER_ROUGHNESS_FAR)
	await _wait_frames(36)
	await _capture_frame("reflection_D_after_tighter_glints", output_path)
	var fps_after_first := await _measure_fps(5.0)
	water.set_shader_parameter("specular", BASELINE_WATER_SPECULAR)
	water.set_shader_parameter("water_roughness_near", BASELINE_WATER_ROUGHNESS_NEAR)
	water.set_shader_parameter("water_roughness_far", BASELINE_WATER_ROUGHNESS_FAR)
	await _wait_frames(36)
	var fps_before_second := await _measure_fps(5.0)
	water.set_shader_parameter("specular", FINAL_WATER_SPECULAR)
	water.set_shader_parameter("water_roughness_near", FINAL_WATER_ROUGHNESS_NEAR)
	water.set_shader_parameter("water_roughness_far", FINAL_WATER_ROUGHNESS_FAR)
	await _wait_frames(36)
	var fps_after_second := await _measure_fps(5.0)
	var fps_before_water := (fps_before_first + fps_before_second) * 0.5
	var fps_after_water := (fps_after_first + fps_after_second) * 0.5

	# E: closer tilted view keeps the ship visibly inside the specular path.
	camera.global_position = boat.global_position + waterward * 30.0 + Vector3.UP * 5.9
	camera.look_at(boat.global_position + Vector3.UP * 1.8, Vector3.UP)
	await _wait_frames(36)
	await _capture_frame("reflection_E_boat_in_sun_path", output_path)

	# F-H: return to a normal stern camera and check all three weather presets.
	camera.global_position = boat.global_position + Vector3(15.0, 4.8, 0.0)
	camera.look_at(boat.global_position + Vector3.UP * 2.2, Vector3.UP)
	camera.fov = 65.0
	await _wait_frames(36)
	await _capture_frame("weather_F_clear_stern_view", output_path)
	weather.set_weather_by_index(WeatherController.Preset.PARTLY_CLOUDY)
	await _wait_seconds(weather.transition_seconds + 0.5)
	_place_camera_on_reflection_path(camera, boat, weather, 62.0)
	await _capture_frame("weather_G_partly_cloudy", output_path)
	weather.set_weather_by_index(WeatherController.Preset.OVERCAST)
	await _wait_seconds(weather.transition_seconds + 0.5)
	_place_camera_on_reflection_path(camera, boat, weather, 62.0)
	await _capture_frame("weather_H_overcast", output_path)

	var report := {
		"renderer": RenderingServer.get_video_adapter_name(),
		"engine": Engine.get_version_info(),
		"viewport_px": [root.size.x, root.size.y],
		"quality": "High",
		"resolution_scale": root.scaling_3d_scale,
		"vsync_during_capture": DisplayServer.VSYNC_DISABLED,
		"fps_cap_during_capture": Engine.max_fps,
		"original_vsync": original_window_vsync,
		"sun": {"azimuth_degrees": original_sun_azimuth, "elevation_degrees": original_sun_elevation,
			"native_sky_disc_degrees_before": BASELINE_SUN_ANGLE, "native_sky_disc_degrees_after": FINAL_SUN_ANGLE,
			"native_sky_disc_curve": original_sun_curve,
			"light_energy": original_sun_energy},
		"environment": {"glow_enabled": original_environment.glow_enabled,
			"glow_intensity": original_environment.glow_intensity, "glow_bloom": original_environment.glow_bloom,
			"fog_enabled": original_environment.fog_enabled, "fog_density": original_environment.fog_density,
			"ssr_enabled": original_environment.ssr_enabled},
		"water": {"specular_before": BASELINE_WATER_SPECULAR,
			"specular_after": FINAL_WATER_SPECULAR,
			"near_multiplier": original_water_parameters["near_multiplier"],
			"far_multiplier": original_water_parameters["far_multiplier"],
			"roughness_near_before": BASELINE_WATER_ROUGHNESS_NEAR,
			"roughness_near_after": FINAL_WATER_ROUGHNESS_NEAR,
			"roughness_far_before": BASELINE_WATER_ROUGHNESS_FAR,
			"roughness_far_after": FINAL_WATER_ROUGHNESS_FAR,
			"sun_glitter_intensity": original_water_parameters["sun_glitter_intensity"],
			"wave_normal_strength": original_water_parameters["wave_normal_strength"],
			"detail_normal_strength_near": original_water_parameters["detail_normal_strength_near"]},
		"fps_average_before_reflection_adjustment": fps_before_water,
		"fps_average_after_reflection_adjustment": fps_after_water,
		"fps_measurements": {"before_first": fps_before_first, "after_first": fps_after_first,
			"before_second": fps_before_second, "after_second": fps_after_second, "seconds_per_sample": 5.0},
		"frame_time_ms_before": 1000.0 / fps_before_water,
		"frame_time_ms_after": 1000.0 / fps_after_water,
		"captures": captures,
	}
	var report_file := FileAccess.open(output_path.path_join("diagnostics_report.json"), FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "  ") + "\n")
	print(JSON.stringify(report, "  "))

	water.set_shader_parameter("water_diagnostic_mode", original_water_mode)
	water.set_shader_parameter("freeze_time", false)
	environment = original_environment
	quality.set_clouds_enabled(original_clouds_enabled)
	quality.set_frame_limit(original_frame_limit)
	main.queue_free()
	await process_frame
	quit()


func _sun_direction(azimuth_degrees: float, elevation_degrees: float) -> Vector3:
	var azimuth := deg_to_rad(azimuth_degrees)
	var elevation := deg_to_rad(elevation_degrees)
	return Vector3(sin(azimuth) * cos(elevation), sin(elevation), -cos(azimuth) * cos(elevation)).normalized()


func _set_canvas_layers_visible(node: Node, visible: bool) -> void:
	for child in node.get_children():
		if child is CanvasLayer:
			(child as CanvasLayer).visible = visible
		_set_canvas_layers_visible(child, visible)


func _place_camera_on_reflection_path(camera: Camera3D, boat: Node3D, weather: WeatherController, distance: float) -> void:
	var sun_direction := _sun_direction(weather.get_sun_azimuth(), weather.get_sun_elevation())
	var waterward := -Vector3(sun_direction.x, 0.0, sun_direction.z).normalized()
	var height := tan(deg_to_rad(weather.get_sun_elevation())) * distance
	camera.global_position = boat.global_position + waterward * distance + Vector3.UP * height
	camera.look_at(boat.global_position + Vector3.UP * 1.8, Vector3.UP)
	camera.fov = 48.0


func _capture_frame(capture_name: String, output_path: String) -> void:
	await _wait_frames(12)
	var image := root.get_texture().get_image()
	var file_path := output_path.path_join(capture_name + ".png")
	var error := image.save_png(file_path)
	captures.append({"name": capture_name, "path": file_path, "width": image.get_width(), "height": image.get_height(), "save_error": error})


func _measure_fps(seconds: float) -> float:
	var frame_count := 0
	var started_at := Time.get_ticks_usec()
	while float(Time.get_ticks_usec() - started_at) / 1000000.0 < seconds:
		await process_frame
		frame_count += 1
	var elapsed := float(Time.get_ticks_usec() - started_at) / 1000000.0
	return float(frame_count) / maxf(elapsed, 0.001)


func _wait_frames(count: int) -> void:
	for _index in range(count):
		await process_frame


func _wait_seconds(seconds: float) -> void:
	await create_timer(seconds).timeout
