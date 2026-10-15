extends SceneTree
## Captures before/after sky and environment art from the production scene.
## Run: godot --path . --script res://tools/capture_summer_sky_environment_comparison.gd

const MAIN_SCENE := "res://scenes/main.tscn"
const OUTPUT_DIR := "res://docs/summer_sky_environment"
const FPS_WARMUP_FRAMES := 120
const FPS_SAMPLE_FRAMES := 180
const FPS_RUNS := 3

var captures: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	var main_scene := load(MAIN_SCENE) as PackedScene
	if main_scene == null:
		push_error("Could not load %s" % MAIN_SCENE)
		quit(1)
		return

	var main := main_scene.instantiate()
	root.add_child(main)
	await _wait_frames(20)

	var environment_node := main.get_node("WorldEnvironment") as WorldEnvironment
	var environment := environment_node.environment
	var weather := main.get_node("WeatherController") as WeatherController
	var quality := main.get_node("QualityManager") as QualityManager
	var cloud_driver := main.get_node("SunshineCloudsDriverGD") as SunshineCloudsDriverGD
	var clouds := cloud_driver.clouds_resource
	var sunlight := main.get_node("Sunlight") as DirectionalLight3D
	var water := (main.get_node("BathymetryManager") as BathymetryManager).water_material
	var motion_root := main.get_node("PlayerBoat/MotionRoot") as Node3D
	var camera_rig := main.get_node("PlayerBoat/FollowCameraRig") as Node3D
	var camera := main.get_node("PlayerBoat/FollowCameraRig/Camera3D") as Camera3D
	var sky := environment.sky.sky_material as ProceduralSkyMaterial
	if environment == null or weather == null or quality == null or clouds == null or sunlight == null or water == null or camera == null or sky == null:
		push_error("Main scene is missing required sky comparison nodes.")
		main.queue_free()
		await process_frame
		quit(1)
		return

	quality.set_quality_for_benchmark(QualityManager.Quality.HIGH)
	water.set_shader_parameter("freeze_time", true)
	motion_root.set_process(false)
	await _wait_frames(12)
	camera_rig.set_process(false)
	camera.make_current()
	var default_camera_transform := camera.global_transform
	var default_camera_fov := camera.fov
	weather.transition_seconds = 1.0
	weather.set_weather_by_index(WeatherController.Preset.CLEAR)
	await _wait_frames(90)

	var old_vsync := DisplayServer.window_get_vsync_mode()
	var old_max_fps := Engine.max_fps
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var output_path := ProjectSettings.globalize_path(OUTPUT_DIR)
	DirAccess.make_dir_recursive_absolute(output_path)

	# Reproduce the pre-task values in this same rendered scene for an apples-to-apples
	# FPS and image baseline. This only changes sky/environment/cloud presentation.
	_set_presentation(sky, environment, clouds, sunlight, {
		"sky_top": Color(0.045, 0.20, 0.49),
		"sky_horizon": Color(0.39, 0.61, 0.78),
		"ground_horizon": Color(0.78, 0.85, 0.88),
		"cloud_coverage": 0.54,
		"ambient_color": Color(0.61, 0.75, 0.84),
		"ambient_energy": 0.78,
		"fog_color": Color(0.72, 0.83, 0.88),
		"fog_density": 0.0012,
		"fog_aerial_perspective": 0.18,
		"fog_sun_scatter": 0.12,
		"atmospheric_density": 0.42,
		"extra_large_noise_scale": 285000.0,
		"large_noise_scale": 80000.0,
		"cloud_floor": 900.0,
		"cloud_ceiling": 5400.0,
		"blur_power": 0.9,
		"shadow_blur": 1.6,
		"shadow_opacity": 0.35,
	})
	await _wait_frames(120)
	await _save_capture("A_clear_before_third_person", output_path)
	var fps_before := await _measure_engine_fps()

	# Apply the actual project values after the task changes, still at the same
	# camera, weather, sun direction, wave phase, quality and output resolution.
	_set_presentation(sky, environment, clouds, sunlight, {
		"sky_top": Color(0.055, 0.245, 0.56),
		"sky_horizon": Color(0.40, 0.64, 0.82),
		"ground_horizon": Color(0.62, 0.75, 0.83),
		"cloud_coverage": 0.58,
		"ambient_color": Color(0.64, 0.77, 0.87),
		"ambient_energy": 0.84,
		"fog_color": Color(0.40, 0.58, 0.72),
		"fog_density": 0.0007,
		"fog_aerial_perspective": 0.13,
		"fog_sun_scatter": 0.08,
		"atmospheric_density": 0.22,
		"extra_large_noise_scale": 240000.0,
		"large_noise_scale": 68000.0,
		"cloud_floor": 1200.0,
		"cloud_ceiling": 6400.0,
		"blur_power": 0.75,
		"shadow_blur": 1.8,
		"shadow_opacity": 0.30,
	})
	await _wait_frames(120)
	await _save_capture("B_clear_after_third_person", output_path)
	var fps_after := await _measure_engine_fps()

	# Temporary hue/fade variants help separate atmospheric color from the sea mesh edge.
	var current_fog_color := environment.fog_light_color
	var current_fog_density := environment.fog_density
	environment.fog_light_color = Color(0.30, 0.50, 0.66)
	environment.fog_density = 0.0007
	await _wait_frames(60)
	await _save_capture("diagnostic_clear_deeper_blue_horizon_fog", output_path)
	environment.fog_light_color = current_fog_color
	environment.fog_density = current_fog_density
	var old_fade_min := float(water.get_shader_parameter("distance_fade_min"))
	var old_fade_max := float(water.get_shader_parameter("distance_fade_max"))
	water.set_shader_parameter("distance_fade_min", 25000.0)
	water.set_shader_parameter("distance_fade_max", 30000.0)
	await _wait_frames(60)
	await _save_capture("diagnostic_clear_far_water_fade", output_path)
	water.set_shader_parameter("distance_fade_min", old_fade_min)
	water.set_shader_parameter("distance_fade_max", old_fade_max)

	var boat_position := motion_root.global_position
	var sun_azimuth := deg_to_rad(weather.get_sun_azimuth())
	var sun_horizontal := Vector3(sin(sun_azimuth), 0.0, -cos(sun_azimuth)).normalized()
	camera.global_position = boat_position - sun_horizontal * 90.0 + Vector3.UP * 18.0
	camera.look_at(boat_position + sun_horizontal * 260.0 + Vector3.UP * 12.0, Vector3.UP)
	await _save_capture("C_clear_after_side_sunlight", output_path)

	# A wide horizon view with a slight upward look exposes cloud placement while
	# keeping the game camera, sun and environment untouched.
	camera.global_position = boat_position + Vector3(72.0, 32.0, -136.0)
	camera.look_at(boat_position + Vector3.UP * 2.0, Vector3.UP)
	camera.fov = 68.0
	await _save_capture("D_clear_after_wide_horizon", output_path)

	camera.global_transform = default_camera_transform
	camera.fov = default_camera_fov
	weather.set_weather_by_index(WeatherController.Preset.PARTLY_CLOUDY)
	await _wait_frames(100)
	await _save_capture("E_partly_cloudy_after", output_path)
	weather.set_weather_by_index(WeatherController.Preset.OVERCAST)
	await _wait_frames(100)
	await _save_capture("F_overcast_after", output_path)

	var render_metrics: Dictionary = quality.get_render_metrics()
	var report := {
		"engine": Engine.get_version_info(),
		"renderer": RenderingServer.get_video_adapter_name(),
		"processor": OS.get_processor_name(),
		"window_px": [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y],
		"viewport_px": [root.size.x, root.size.y],
		"quality": "High",
		"resolution_scale": render_metrics.get("resolution_scale", 1.0),
		"vsync_during_fps_samples": "disabled",
		"max_fps_during_fps_samples": 0,
		"wave_phase_frozen": true,
		"sun_direction_unchanged_for_A_to_D": true,
		"captures": captures,
		"fps_before_engine_reported": fps_before,
		"fps_after_engine_reported": fps_after,
		"before_parameters": {
			"sky_top": [0.045, 0.2, 0.49],
			"sky_horizon": [0.39, 0.61, 0.78],
			"ambient_energy": 0.78,
			"fog_density": 0.0012,
			"fog_aerial_perspective": 0.18,
			"fog_sun_scatter": 0.12,
			"cloud_floor_ceiling_m": [900, 5400],
			"cloud_noise_scale_extra_large_large": [285000, 80000],
			"cloud_blur_power": 0.9,
			"shadow_blur_opacity": [1.6, 0.35],
		},
		"after_parameters": {
			"sky_top": [0.055, 0.245, 0.56],
			"sky_horizon": [0.4, 0.64, 0.82],
			"ambient_energy": 0.84,
			"fog_density": 0.0007,
			"fog_aerial_perspective": 0.13,
			"fog_sun_scatter": 0.08,
			"cloud_floor_ceiling_m": [1200, 6400],
			"cloud_noise_scale_extra_large_large": [240000, 68000],
			"cloud_blur_power": 0.75,
			"shadow_blur_opacity": [1.8, 0.3],
		},
	}
	var report_file := FileAccess.open(output_path.path_join("comparison_report.json"), FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "  ") + "\n")
	print(JSON.stringify(report, "  "))

	water.set_shader_parameter("freeze_time", false)
	Engine.max_fps = old_max_fps
	DisplayServer.window_set_vsync_mode(old_vsync)
	main.queue_free()
	await process_frame
	quit()


func _set_presentation(sky: ProceduralSkyMaterial, environment: Environment, clouds: SunshineCloudsGD, sunlight: DirectionalLight3D, values: Dictionary) -> void:
	sky.sky_top_color = values["sky_top"]
	sky.sky_horizon_color = values["sky_horizon"]
	sky.ground_horizon_color = values["ground_horizon"]
	environment.ambient_light_color = values["ambient_color"]
	environment.ambient_light_energy = float(values["ambient_energy"])
	environment.fog_light_color = values["fog_color"]
	environment.fog_density = float(values["fog_density"])
	environment.fog_aerial_perspective = float(values["fog_aerial_perspective"])
	environment.fog_sun_scatter = float(values["fog_sun_scatter"])
	clouds.atmospheric_density = float(values["atmospheric_density"])
	clouds.clouds_coverage = float(values["cloud_coverage"])
	clouds.extra_large_noise_scale = float(values["extra_large_noise_scale"])
	clouds.large_noise_scale = float(values["large_noise_scale"])
	clouds.cloud_floor = float(values["cloud_floor"])
	clouds.cloud_ceiling = float(values["cloud_ceiling"])
	clouds.blur_power = float(values["blur_power"])
	sunlight.shadow_blur = float(values["shadow_blur"])
	sunlight.shadow_opacity = float(values["shadow_opacity"])


func _save_capture(capture_name: String, output_path: String) -> void:
	await _wait_frames(6)
	var image := root.get_texture().get_image()
	var path := output_path.path_join(capture_name + ".png")
	var error := image.save_png(path)
	captures.append({
		"name": capture_name,
		"width": image.get_width(),
		"height": image.get_height(),
		"path": path,
		"save_error": error,
	})


func _measure_engine_fps() -> Dictionary:
	var samples: Array[int] = []
	var runs: Array[Dictionary] = []
	for run_index in range(FPS_RUNS):
		await _wait_frames(FPS_WARMUP_FRAMES)
		var run_samples: Array[int] = []
		for _frame in range(FPS_SAMPLE_FRAMES):
			await process_frame
			var fps := Engine.get_frames_per_second()
			if fps > 0:
				samples.append(fps)
				run_samples.append(fps)
		runs.append({
			"run": run_index + 1,
			"average_fps": _average_int_array(run_samples),
			"min_fps": _minimum_int_array(run_samples),
			"max_fps": _maximum_int_array(run_samples),
		})
	var total := 0
	var minimum := 2147483647
	var maximum := 0
	for value in samples:
		total += value
		minimum = mini(minimum, value)
		maximum = maxi(maximum, value)
	return {
		"source": "Engine.get_frames_per_second()",
		"sample_count": samples.size(),
		"average_fps": float(total) / maxf(float(samples.size()), 1.0),
		"min_fps": minimum if not samples.is_empty() else 0,
		"max_fps": maximum,
		"average_frame_time_ms": 1000.0 / maxf(float(total) / maxf(float(samples.size()), 1.0), 0.001),
		"runs": runs,
	}


func _average_int_array(values: Array[int]) -> float:
	var total := 0
	for value in values:
		total += value
	return float(total) / maxf(float(values.size()), 1.0)


func _minimum_int_array(values: Array[int]) -> int:
	var result := 2147483647
	for value in values:
		result = mini(result, value)
	return result if result != 2147483647 else 0


func _maximum_int_array(values: Array[int]) -> int:
	var result := 0
	for value in values:
		result = maxi(result, value)
	return result


func _wait_frames(count: int) -> void:
	for _frame in range(count):
		await process_frame
