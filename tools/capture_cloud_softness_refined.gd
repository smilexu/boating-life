extends SceneTree
## Repeatable fixed-camera Sunshine Clouds diagnosis and appearance capture.
## Run: godot --path . --script res://tools/capture_cloud_softness_refined.gd

const MAIN_SCENE := "res://scenes/main.tscn"
const OUTPUT_DIR := "res://docs/summer_clouds_refined"

const CANDIDATE := {
	"clouds_detail_power": 0.6,
	"medium_noise_scale": 24000.0,
	"small_noise_scale": 10000.0,
	"curl_noise_strength": 700.0,
	"lighting_density": 0.56,
	"lighting_sharpness": 0.24,
}

var captures: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	root.size = Vector2i(1920, 1080)
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var packed := load(MAIN_SCENE) as PackedScene
	if packed == null:
		push_error("Could not load %s" % MAIN_SCENE)
		quit(1)
		return

	var main := packed.instantiate()
	root.add_child(main)
	await _wait_frames(60)
	var quality := main.get_node("QualityManager") as QualityManager
	var weather := main.get_node("WeatherController") as WeatherController
	var driver := main.get_node("SunshineCloudsDriverGD") as SunshineCloudsDriverGD
	var clouds := driver.clouds_resource
	var motion_root := main.get_node("PlayerBoat/MotionRoot") as Node3D
	var camera_rig := main.get_node("PlayerBoat/FollowCameraRig") as Node3D
	var camera := main.get_node("PlayerBoat/FollowCameraRig/Camera3D") as Camera3D
	var boat := main.get_node("PlayerBoat") as Node3D
	var water := (main.get_node("BathymetryManager") as BathymetryManager).water_material
	if quality == null or weather == null or driver == null or clouds == null or camera == null or water == null:
		push_error("Main scene is missing cloud capture dependencies.")
		quit(1)
		return
	var initial_camera_transform := camera.global_transform
	var initial_camera_fov := camera.fov

	quality.set_quality_for_benchmark(QualityManager.Quality.HIGH)
	weather.transition_seconds = 0.05
	weather.set_weather_by_index(WeatherController.Preset.CLEAR)
	await _wait_seconds(0.3)
	motion_root.set_process(false)
	camera_rig.set_process(false)
	camera.make_current()
	water.set_shader_parameter("freeze_time", true)
	water.set_shader_parameter("WaveTime", 11.0)
	_set_canvas_layers_visible(main, false)

	# A fixed wide view keeps the main cumulus and the smaller flat cloud in frame.
	var boat_position := boat.global_position
	camera.global_position = boat_position + Vector3(72.0, 32.0, -136.0)
	camera.look_at(boat_position + Vector3.UP * 2.0, Vector3.UP)
	camera.fov = 68.0
	var frozen_offsets := {
		"extra_large_scale_clouds_position": clouds.extra_large_scale_clouds_position,
		"large_scale_clouds_position": clouds.large_scale_clouds_position,
		"medium_scale_clouds_position": clouds.medium_scale_clouds_position,
		"detail_clouds_position": clouds.detail_clouds_position,
	}
	driver.set_process(false)
	_apply_cloud_offsets(clouds, frozen_offsets)
	clouds.current_time = 7.5
	clouds.accumulation_decay = 0.72
	var output_path := ProjectSettings.globalize_path(OUTPUT_DIR)
	DirAccess.make_dir_recursive_absolute(output_path)

	var baseline := _snapshot_parameters(clouds)
	# Keep the former production values as an explicit control after the resource is tuned.
	baseline.merge({
		"lighting_density": 0.7,
		"clouds_detail_power": 0.36,
		"medium_noise_scale": 19000.0,
		"small_noise_scale": 6500.0,
		"curl_noise_strength": 1500.0,
		"lighting_sharpness": 0.18,
	}, true)
	_restore_parameters(clouds, baseline)
	await _settle(clouds)
	await _capture_frame("A_clear_before_overview", output_path)
	var fps_before := await _measure_fps(5.0)

	# In this shader the small-detail term is multiplied by pow(1-mediumshape, power).
	# A larger exponent suppresses fine detail inside dense cloud cores while retaining edge breakup.
	_restore_parameters(clouds, baseline)
	clouds.clouds_detail_power = 1.0
	await _settle(clouds)
	await _capture_frame("diagnostic_small_detail_reduced", output_path)

	_restore_parameters(clouds, baseline)
	clouds.curl_noise_strength = 0.0
	await _settle(clouds)
	await _capture_frame("diagnostic_curl_off", output_path)

	_restore_parameters(clouds, baseline)
	clouds.lighting_density = 0.0
	await _settle(clouds)
	await _capture_frame("diagnostic_lighting_off", output_path)

	_restore_parameters(clouds, baseline)
	_apply_candidate(clouds, 0.56)
	await _settle(clouds)
	await _capture_frame("B_clear_after_overview", output_path)
	var fps_after := await _measure_fps(5.0)
	_restore_parameters(clouds, baseline)
	await _settle(clouds)
	var fps_before_repeat := await _measure_fps(5.0)
	_apply_candidate(clouds, 0.56)
	await _settle(clouds)
	var fps_after_repeat := await _measure_fps(5.0)

	# Reuse the accepted density candidate with each existing weather preset.
	weather.set_weather_by_index(WeatherController.Preset.PARTLY_CLOUDY)
	await _wait_seconds(weather.transition_seconds + 0.25)
	_apply_candidate(clouds, 0.56)
	await _settle(clouds)
	await _capture_frame("G_partly_cloudy_after", output_path)
	weather.set_weather_by_index(WeatherController.Preset.OVERCAST)
	await _wait_seconds(weather.transition_seconds + 0.25)
	_apply_candidate(clouds, 0.40)
	await _settle(clouds)
	await _capture_frame("H_overcast_after", output_path)

	# Quality tiers are captured with the same density-field artistry; only the existing
	# QualityManager resolution/step settings vary.
	weather.set_weather_by_index(WeatherController.Preset.CLEAR)
	await _wait_seconds(weather.transition_seconds + 0.25)
	_apply_candidate(clouds, 0.56)
	quality.set_quality_for_benchmark(QualityManager.Quality.HIGH)
	await _settle(clouds)
	await _capture_frame("quality_high_after", output_path)
	quality.set_quality_for_benchmark(QualityManager.Quality.MEDIUM)
	await _settle(clouds)
	await _capture_frame("quality_medium_after", output_path)
	quality.set_quality_for_benchmark(QualityManager.Quality.LOW)
	await _settle(clouds)
	await _capture_frame("quality_low_after", output_path)
	quality.set_quality_for_benchmark(QualityManager.Quality.HIGH)

	# Restore the main scene's initial follow-camera transform (ship remains stationary).
	camera.global_transform = initial_camera_transform
	camera.fov = initial_camera_fov
	camera.make_current()
	await _wait_frames(60)
	await _capture_frame("I_third_person_after", output_path)
	var default_camera_position := camera.global_position
	var target := boat.global_position + Vector3.UP * 0.9
	var default_camera_offset := default_camera_position - target
	var sweep_hashes: Array[Dictionary] = []
	driver.set_process(true)
	for yaw_degrees in [-7.0, 0.0, 7.0]:
		camera.global_position = target + default_camera_offset.rotated(Vector3.UP, deg_to_rad(yaw_degrees))
		camera.look_at(target, Vector3.UP)
		await _wait_frames(60)
		await _capture_frame("camera_motion_yaw_%s" % str(int(yaw_degrees)).replace("-", "m"), output_path)
		sweep_hashes.append({"yaw_degrees": yaw_degrees, "cloud_time": clouds.current_time})

	var report := {
		"engine": Engine.get_version_info(),
		"renderer": RenderingServer.get_video_adapter_name(),
		"processor": OS.get_processor_name(),
		"viewport_px": [root.size.x, root.size.y],
		"quality_for_A_to_diagnostics_and_B": "High",
		"resolution_scale_for_fixed_view": 2,
		"vsync_during_fps_samples": "disabled",
		"fps_cap_during_fps_samples": 0,
		"camera_and_cloud_offsets_frozen_for_fixed_views": true,
		"cloud_dither_time_for_fixed_views": 7.5,
		"wave_phase_frozen_for_fixed_views": true,
		"cloud_parameters_before": baseline,
		"candidate": CANDIDATE,
		"fps_before": fps_before,
		"fps_after": fps_after,
		"fps_before_repeat": fps_before_repeat,
		"fps_after_repeat": fps_after_repeat,
		"camera_stability_sweep": sweep_hashes,
		"captures": captures,
	}
	var file := FileAccess.open(output_path.path_join("diagnostics_report.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  ") + "\n")
	print(JSON.stringify(report, "  "))
	main.queue_free()
	await process_frame
	quit()


func _apply_candidate(clouds: SunshineCloudsGD, light_density: float) -> void:
	clouds.clouds_detail_power = CANDIDATE.clouds_detail_power
	clouds.medium_noise_scale = CANDIDATE.medium_noise_scale
	clouds.small_noise_scale = CANDIDATE.small_noise_scale
	clouds.curl_noise_strength = CANDIDATE.curl_noise_strength
	clouds.lighting_density = light_density
	clouds.lighting_sharpness = CANDIDATE.lighting_sharpness


func _apply_cloud_offsets(clouds: SunshineCloudsGD, offsets: Dictionary) -> void:
	for key in offsets:
		clouds.set(key, offsets[key])


func _snapshot_parameters(clouds: SunshineCloudsGD) -> Dictionary:
	return {
		"clouds_coverage": clouds.clouds_coverage,
		"clouds_density": clouds.clouds_density,
		"lighting_density": clouds.lighting_density,
		"clouds_detail_power": clouds.clouds_detail_power,
		"extra_large_noise_scale": clouds.extra_large_noise_scale,
		"large_noise_scale": clouds.large_noise_scale,
		"medium_noise_scale": clouds.medium_noise_scale,
		"small_noise_scale": clouds.small_noise_scale,
		"clouds_sharpness": clouds.clouds_sharpness,
		"curl_noise_strength": clouds.curl_noise_strength,
		"lighting_sharpness": clouds.lighting_sharpness,
		"cloud_floor": clouds.cloud_floor,
		"cloud_ceiling": clouds.cloud_ceiling,
		"max_step_count": clouds.max_step_count,
		"max_lighting_steps": clouds.max_lighting_steps,
		"resolution_scale": clouds.resolution_scale,
		"blur_power": clouds.blur_power,
		"blur_quality": clouds.blur_quality,
	}


func _restore_parameters(clouds: SunshineCloudsGD, values: Dictionary) -> void:
	for key in values:
		clouds.set(key, values[key])


func _settle(clouds: SunshineCloudsGD) -> void:
	clouds.ignore_accumilation = true
	await _wait_frames(1)
	clouds.ignore_accumilation = false
	await _wait_frames(90)


func _set_canvas_layers_visible(node: Node, visible: bool) -> void:
	for child in node.get_children():
		if child is CanvasLayer:
			(child as CanvasLayer).visible = visible
		_set_canvas_layers_visible(child, visible)


func _capture_frame(capture_name: String, output_path: String) -> void:
	await process_frame
	var image := root.get_texture().get_image()
	var path := output_path.path_join(capture_name + ".png")
	var error := image.save_png(path)
	captures.append({"name": capture_name, "width": image.get_width(), "height": image.get_height(), "save_error": error})


func _measure_fps(seconds: float) -> Dictionary:
	var frames := 0
	var start := Time.get_ticks_usec()
	while float(Time.get_ticks_usec() - start) / 1000000.0 < seconds:
		await process_frame
		frames += 1
	var elapsed := float(Time.get_ticks_usec() - start) / 1000000.0
	return {"frames": frames, "seconds": elapsed, "fps": float(frames) / maxf(elapsed, 0.001), "frame_time_ms": elapsed * 1000.0 / maxf(float(frames), 1.0)}


func _wait_frames(count: int) -> void:
	for _index in range(count):
		await process_frame


func _wait_seconds(seconds: float) -> void:
	await create_timer(seconds).timeout
