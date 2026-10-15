extends SceneTree
## Fixed-camera diagnostic captures for intermittent ocean lines and sun glow.
## Run: godot --path . --script res://tools/capture_ocean_sun_artifact_diagnostics.gd

const MAIN_SCENE := "res://scenes/main.tscn"
const OUTPUT_DIR := "res://docs/ocean_sun_polish"
const SAMPLE_SECONDS := 20
const SAMPLE_INTERVAL := 1.0
const TILE_SIZE := Vector2i(480, 270)
const TIMELINE_COLUMNS := 4

var _captures: Array[Dictionary] = []


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
	await _wait_frames(60)

	var ocean := main.get_node("Ocean") as Ocean
	var quality := main.get_node("QualityManager") as QualityManager
	var water := (main.get_node("BathymetryManager") as BathymetryManager).water_material
	var wave_sampler := main.get_node("WaveSampler") as WaveSampler
	var boat := main.get_node("PlayerBoat") as Node3D
	var motion_root := main.get_node("PlayerBoat/MotionRoot") as BoatController
	var visual_root := main.get_node("PlayerBoat/MotionRoot/VisualRoot") as Node3D
	var camera_rig := main.get_node("PlayerBoat/FollowCameraRig") as Node3D
	var camera := main.get_node("PlayerBoat/FollowCameraRig/Camera3D") as Camera3D
	var weather := main.get_node("WeatherController") as WeatherController
	var environment := (main.get_node("WorldEnvironment") as WorldEnvironment).environment
	var sky_material := environment.sky.sky_material as ShaderMaterial
	var sunlight := main.get_node("Sunlight") as DirectionalLight3D
	if ocean == null or quality == null or water == null or wave_sampler == null or camera == null:
		push_error("Main scene is missing ocean/sun diagnostic dependencies.")
		quit(1)
		return

	quality.set_quality_for_benchmark(QualityManager.Quality.HIGH)
	for canvas in main.find_children("*", "CanvasLayer", true, false):
		(canvas as CanvasLayer).visible = false
	motion_root.set_process(false)
	visual_root.set_process(false)
	camera_rig.set_process(false)
	var sun_direction := _sun_direction(weather.get_sun_azimuth(), weather.get_sun_elevation())
	var waterward := -Vector3(sun_direction.x, 0.0, sun_direction.z).normalized()
	camera.global_position = boat.global_position + waterward * 62.0 + Vector3.UP * 12.0
	camera.look_at(boat.global_position + Vector3.UP * 1.8, Vector3.UP)
	camera.fov = 48.0
	camera.far = 10000.0
	camera.make_current()

	var output_path := ProjectSettings.globalize_path(OUTPUT_DIR)
	DirAccess.make_dir_recursive_absolute(output_path)
	var original_water_mode := int(water.get_shader_parameter("water_diagnostic_mode"))
	var original_steepnesses: PackedFloat32Array = water.get_shader_parameter("WaveSteepnesses")
	var original_amplitudes: PackedFloat32Array = water.get_shader_parameter("WaveAmplitudes")
	var original_ocean_resolution := ocean.outermost_resolution
	var original_ocean_lods := ocean.levels_of_detail
	var original_sun_core := float(sky_material.get_shader_parameter("sun_core_radiance"))
	var original_sun_halo := float(sky_material.get_shader_parameter("sun_halo_strength"))
	var original_sun_energy := sunlight.light_energy
	var original_sun_color := sunlight.light_color
	var original_glow_enabled := environment.glow_enabled
	var original_glow_intensity := environment.glow_intensity
	var original_glow_threshold := environment.glow_hdr_threshold
	var original_glow_bloom := environment.glow_bloom
	var original_sun_specular := float(water.get_shader_parameter("specular"))

	# A0: full production material, with the animated sea observed continuously for 20 s.
	water.set_shader_parameter("water_diagnostic_mode", 0)
	await _capture_timeline("A0_normal_baseline", water, output_path)
	await _capture_full("A0_normal_baseline_peak", output_path)

	# A1: diffuse only; this removes Fresnel/specular/environment reflection while
	# retaining wave displacement, direct light, and cast shadows.
	water.set_shader_parameter("water_diagnostic_mode", 7)
	await _capture_timeline("A1_specular_disabled", water, output_path)

	# A2: unlit constant-color output; mesh geometry and wave displacement remain.
	water.set_shader_parameter("water_diagnostic_mode", 1)
	await _capture_timeline("A2_constant_color_waves", water, output_path)
	await _capture_full("A2_constant_color_waves_single", output_path)

	# A3: color each production LOD shell and the two far planes independently.
	water.set_shader_parameter("water_diagnostic_mode", 0)
	var original_overrides: Array[Material] = []
	var mesh_nodes: Array[MeshInstance3D] = []
	for child in ocean.get_children():
		if child is MeshInstance3D:
			var mesh_instance := child as MeshInstance3D
			mesh_nodes.append(mesh_instance)
			original_overrides.append(mesh_instance.material_override)
			mesh_instance.material_override = _make_lod_material(mesh_instance.name)
	await _wait_frames(24)
	await _capture_full("A3_lod_shell_visualization", output_path)
	for index in range(mesh_nodes.size()):
		mesh_nodes[index].material_override = original_overrides[index]

	# A4: no Gerstner displacement. The camera, meshes and surface remain unchanged.
	wave_sampler.set_process(false)
	water.set_shader_parameter("WaveSteepnesses", _zero_array(original_steepnesses.size()))
	water.set_shader_parameter("WaveAmplitudes", _zero_array(original_amplitudes.size()))
	water.set_shader_parameter("water_diagnostic_mode", 0)
	await _wait_frames(48)
	await _capture_full("A4_waves_disabled", output_path)

	# A5: production wave field at a deliberately coarser LOD as a diagnostic comparison.
	water.set_shader_parameter("WaveSteepnesses", original_steepnesses)
	water.set_shader_parameter("WaveAmplitudes", original_amplitudes)
	ocean.outermost_resolution = 8
	ocean.levels_of_detail = 3
	ocean.build_meshes()
	await _wait_frames(60)
	await _capture_timeline("A5_coarser_lod", water, output_path)
	ocean.outermost_resolution = original_ocean_resolution
	ocean.levels_of_detail = original_ocean_lods
	ocean.build_meshes()
	wave_sampler.set_process(true)
	await _wait_frames(60)
	
	# Solar baseline and isolation captures. These are made after line diagnosis,
	# with the same sun direction and clear-weather state.
	water.set_shader_parameter("water_diagnostic_mode", original_water_mode)
	await _capture_full("B0_sun_before", output_path)
	environment.glow_enabled = false
	await _wait_frames(24)
	await _capture_full("B1_sun_glow_off", output_path)
	environment.glow_enabled = original_glow_enabled
	await _wait_frames(24)

	var report := {
		"engine": Engine.get_version_info(),
		"renderer": RenderingServer.get_video_adapter_name(),
		"resolution": [root.size.x, root.size.y],
		"quality": "High",
		"vsync": DisplayServer.VSYNC_DISABLED,
		"fps_cap": Engine.max_fps,
		"camera_position": [camera.global_position.x, camera.global_position.y, camera.global_position.z],
		"camera_fov": camera.fov,
		"sun_azimuth": weather.get_sun_azimuth(),
		"sun_elevation": weather.get_sun_elevation(),
		"sun_core_radiance": original_sun_core,
		"sun_halo_strength": original_sun_halo,
		"sun_energy": original_sun_energy,
		"sun_color": [original_sun_color.r, original_sun_color.g, original_sun_color.b],
		"glow": {"enabled": original_glow_enabled, "intensity": original_glow_intensity,
			"threshold": original_glow_threshold, "bloom": original_glow_bloom},
		"water_specular": original_sun_specular,
		"ocean_geometry": {"outermost_resolution": original_ocean_resolution,
			"levels_of_detail": original_ocean_lods, "far_edge": ocean.far_edge,
			"generated_mesh_count": ocean.get_child_count(),
			"region_width": ocean.region_width, "total_width": ocean.total_width},
		"captures": _captures,
	}
	var report_file := FileAccess.open(output_path.path_join("diagnostics_report.json"), FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "  ") + "\n")
	print(JSON.stringify(report, "  "))

	water.set_shader_parameter("water_diagnostic_mode", original_water_mode)
	water.set_shader_parameter("WaveSteepnesses", original_steepnesses)
	water.set_shader_parameter("WaveAmplitudes", original_amplitudes)
	wave_sampler.set_process(true)
	ocean.outermost_resolution = original_ocean_resolution
	ocean.levels_of_detail = original_ocean_lods
	water.set_shader_parameter("specular", original_sun_specular)
	sky_material.set_shader_parameter("sun_core_radiance", original_sun_core)
	sky_material.set_shader_parameter("sun_halo_strength", original_sun_halo)
	sunlight.light_energy = original_sun_energy
	sunlight.light_color = original_sun_color
	environment.glow_enabled = original_glow_enabled
	environment.glow_intensity = original_glow_intensity
	environment.glow_hdr_threshold = original_glow_threshold
	environment.glow_bloom = original_glow_bloom
	main.queue_free()
	await process_frame
	quit()


func _capture_timeline(name: String, water: ShaderMaterial, output_path: String) -> void:
	var sheet := Image.create(TILE_SIZE.x * TIMELINE_COLUMNS, TILE_SIZE.y * int(ceil(float(SAMPLE_SECONDS) / TIMELINE_COLUMNS)), false, Image.FORMAT_RGBA8)
	var peak_score := -1.0
	var peak_image: Image
	var scores: Array[float] = []
	for sample_index in range(SAMPLE_SECONDS):
		await _wait_seconds(SAMPLE_INTERVAL)
		var frame := root.get_texture().get_image()
		if frame == null or frame.is_empty():
			continue
		var score := _bright_horizontal_line_score(frame)
		scores.append(score)
		if score > peak_score:
			peak_score = score
			peak_image = frame.duplicate()
		var tile := frame.duplicate()
		tile.convert(Image.FORMAT_RGBA8)
		tile.resize(TILE_SIZE.x, TILE_SIZE.y, Image.INTERPOLATE_BILINEAR)
		var destination := Vector2i((sample_index % TIMELINE_COLUMNS) * TILE_SIZE.x, (sample_index / TIMELINE_COLUMNS) * TILE_SIZE.y)
		sheet.blit_rect(tile, Rect2i(Vector2i.ZERO, TILE_SIZE), destination)
	var timeline_path := output_path.path_join(name + "_timeline.png")
	var error := sheet.save_png(timeline_path)
	_captures.append({"name": name + "_timeline", "path": timeline_path, "samples_seconds": SAMPLE_SECONDS, "samples": scores, "max_horizontal_bright_row_fraction": peak_score, "save_error": error})
	if peak_image != null:
		var peak_path := output_path.path_join(name + "_peak.png")
		_captures.append({"name": name + "_peak", "path": peak_path, "save_error": peak_image.save_png(peak_path)})
	print("Captured %s for %d seconds; max bright-row fraction %.4f" % [name, SAMPLE_SECONDS, peak_score])


func _bright_horizontal_line_score(image: Image) -> float:
	var best := 0.0
	var left := int(float(image.get_width()) * 0.04)
	var right := int(float(image.get_width()) * 0.96)
	var first_row := int(float(image.get_height()) * 0.34)
	var last_row := int(float(image.get_height()) * 0.82)
	for y in range(first_row, last_row):
		var bright := 0
		var total := 0
		for x in range(left, right, 2):
			var color := image.get_pixel(x, y)
			if color.r > 0.72 and color.g > 0.76 and color.b > 0.78:
				bright += 1
			total += 1
		best = maxf(best, float(bright) / float(maxi(1, total)))
	return best


func _make_lod_material(mesh_name: String) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	if mesh_name.ends_with("_far"):
		material.albedo_color = Color(1.0, 0.10, 0.12)
	elif mesh_name.ends_with("_mid"):
		material.albedo_color = Color(1.0, 0.68, 0.08)
	else:
		var parts := mesh_name.split("_")
		var shell := 0
		if parts.size() >= 5:
			shell = maxi(abs(int(parts[3])), abs(int(parts[4])))
		match shell:
			0:
				material.albedo_color = Color(0.10, 0.86, 0.24)
			1:
				material.albedo_color = Color(0.12, 0.55, 0.95)
			2:
				material.albedo_color = Color(0.65, 0.20, 0.95)
			_:
				material.albedo_color = Color(0.96, 0.22, 0.55)
	return material


func _zero_array(count: int) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	values.resize(count)
	values.fill(0.0)
	return values


func _capture_full(name: String, output_path: String) -> void:
	await _wait_frames(12)
	var image := root.get_texture().get_image()
	var file_path := output_path.path_join(name + ".png")
	var error := image.save_png(file_path)
	_captures.append({"name": name, "path": file_path, "width": image.get_width(), "height": image.get_height(), "save_error": error})


func _wait_frames(count: int) -> void:
	for _index in range(count):
		await process_frame


func _wait_seconds(seconds: float) -> void:
	await create_timer(seconds, false, true, false).timeout


func _sun_direction(azimuth_degrees: float, elevation_degrees: float) -> Vector3:
	var azimuth := deg_to_rad(azimuth_degrees)
	var elevation := deg_to_rad(elevation_degrees)
	return Vector3(sin(azimuth) * cos(elevation), sin(elevation), -cos(azimuth) * cos(elevation)).normalized()
