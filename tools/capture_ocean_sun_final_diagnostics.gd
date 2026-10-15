extends SceneTree
## Fixed-camera captures after the ocean far-LOD seam repair, plus isolated sun candidates.
## Run: godot --path . --script res://tools/capture_ocean_sun_final_diagnostics.gd

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
	var main := (load(MAIN_SCENE) as PackedScene).instantiate()
	root.add_child(main)
	await _wait_frames(60)

	var quality := main.get_node("QualityManager") as QualityManager
	var ocean := main.get_node("Ocean") as Ocean
	var water := (main.get_node("BathymetryManager") as BathymetryManager).water_material
	var wave_sampler := main.get_node("WaveSampler") as WaveSampler
	var boat := main.get_node("PlayerBoat") as Node3D
	var motion_root := main.get_node("PlayerBoat/MotionRoot") as BoatController
	var visual_root := main.get_node("PlayerBoat/MotionRoot/VisualRoot") as Node3D
	var camera_rig := main.get_node("PlayerBoat/FollowCameraRig") as Node3D
	var camera := main.get_node("PlayerBoat/FollowCameraRig/Camera3D") as Camera3D
	var weather := main.get_node("WeatherController") as WeatherController
	var environment := (main.get_node("WorldEnvironment") as WorldEnvironment).environment
	var sky := environment.sky.sky_material as ShaderMaterial
	var sunlight := main.get_node("Sunlight") as DirectionalLight3D
	quality.set_quality_for_benchmark(QualityManager.Quality.HIGH)
	for canvas in main.find_children("*", "CanvasLayer", true, false):
		(canvas as CanvasLayer).visible = false
	motion_root.set_process(false)
	visual_root.set_process(false)
	camera_rig.set_process(false)
	var azimuth := deg_to_rad(weather.get_sun_azimuth())
	var elevation := deg_to_rad(weather.get_sun_elevation())
	var sun_direction := Vector3(sin(azimuth) * cos(elevation), sin(elevation), -cos(azimuth) * cos(elevation)).normalized()
	var waterward := -Vector3(sun_direction.x, 0.0, sun_direction.z).normalized()
	camera.global_position = boat.global_position + waterward * 62.0 + Vector3.UP * 12.0
	camera.look_at(boat.global_position + Vector3.UP * 1.8, Vector3.UP)
	camera.fov = 48.0
	camera.far = 10000.0
	camera.make_current()
	await _wait_frames(60)

	var out := ProjectSettings.globalize_path(OUTPUT_DIR)
	DirAccess.make_dir_recursive_absolute(out)
	var water_mode := int(water.get_shader_parameter("water_diagnostic_mode"))
	var was_frozen := bool(water.get_shader_parameter("freeze_time"))
	var old_wave_steepnesses: PackedFloat32Array = water.get_shader_parameter("WaveSteepnesses")
	var old_wave_amplitudes: PackedFloat32Array = water.get_shader_parameter("WaveAmplitudes")
	var region := main.get_node("OresundRegion") as Node3D
	var old_region_visible := region.visible
	var mesh_stats := _get_transition_mesh_stats(ocean)
	var sunny_state := _capture_sun_state(weather, sky, sunlight, environment)
	water.set_shader_parameter("water_diagnostic_mode", 0)
	water.set_shader_parameter("freeze_time", false)
	await _capture_timeline("A6_wave_boundary_repair", out)
	await _capture_full("A6_wave_boundary_repair_after_20s", out)

	# A7 keeps the moving Gerstner mesh and WaveSampler but removes material
	# shading. A8 removes wave displacement too; A9 hides geographic terrain.
	water.set_shader_parameter("water_diagnostic_mode", 1)
	await _capture_timeline("A7_constant_color_with_waves", out)
	wave_sampler.set_process(false)
	water.set_shader_parameter("WaveSteepnesses", _zero_array(old_wave_steepnesses.size()))
	water.set_shader_parameter("WaveAmplitudes", _zero_array(old_wave_amplitudes.size()))
	await _wait_frames(24)
	await _capture_full("A8_constant_color_without_waves", out)
	water.set_shader_parameter("WaveSteepnesses", old_wave_steepnesses)
	water.set_shader_parameter("WaveAmplitudes", old_wave_amplitudes)
	wave_sampler.set_process(true)
	await _wait_frames(48)
	region.visible = false
	await _capture_full("A9_constant_color_terrain_hidden", out)
	region.visible = old_region_visible
	water.set_shader_parameter("water_diagnostic_mode", water_mode)

	# Isolate each generated surface group under an unlit, zero-wave output. This
	# identifies whether a residual horizon dash belongs to a specific LOD ring.
	var generated_meshes: Array[MeshInstance3D] = []
	var original_visibility: Array[bool] = []
	for child in ocean.get_children():
		if child is MeshInstance3D:
			generated_meshes.append(child as MeshInstance3D)
			original_visibility.append((child as MeshInstance3D).visible)
	water.set_shader_parameter("water_diagnostic_mode", 1)
	water.set_shader_parameter("WaveSteepnesses", _zero_array(old_wave_steepnesses.size()))
	water.set_shader_parameter("WaveAmplitudes", _zero_array(old_wave_amplitudes.size()))
	wave_sampler.set_process(false)
	for capture_name in ["A11_near_lods_only", "A12_transition_only", "A13_mid_only", "A14_far_only"]:
		for mesh_index in range(generated_meshes.size()):
			var mesh := generated_meshes[mesh_index]
			var keep := false
			match capture_name:
				"A11_near_lods_only":
					keep = mesh.name.begins_with("_gen_nearplane_")
				"A12_transition_only":
					keep = mesh.name == "_gen_farplane_transition"
				"A13_mid_only":
					keep = mesh.name == "_gen_farplane_mid"
				"A14_far_only":
					keep = mesh.name == "_gen_farplane_far"
			mesh.visible = keep
		await _capture_full(capture_name, out)
	for mesh_index in range(generated_meshes.size()):
		generated_meshes[mesh_index].visible = original_visibility[mesh_index]
	wave_sampler.set_process(true)
	water.set_shader_parameter("WaveSteepnesses", old_wave_steepnesses)
	water.set_shader_parameter("WaveAmplitudes", old_wave_amplitudes)
	water.set_shader_parameter("water_diagnostic_mode", water_mode)
	await _wait_frames(24)

	# The same low-detail profile that exposed a large diagonal seam in the
	# pre-fix diagnostic verifies the repaired far transition at the other LOD.
	var old_resolution := ocean.outermost_resolution
	var old_lods := ocean.levels_of_detail
	ocean.outermost_resolution = 8
	ocean.levels_of_detail = 3
	ocean.build_meshes()
	await _wait_frames(60)
	await _capture_full("A10_low_lod_after_repair", out)
	ocean.outermost_resolution = old_resolution
	ocean.levels_of_detail = old_lods
	ocean.build_meshes()
	await _wait_frames(60)

	# Freeze only wave phase for the paired sun/reflection image.
	water.set_shader_parameter("freeze_time", true)
	await _capture_reflection("B12_sunny_sun_and_reflection_final", out, weather, water)
	var original_water_specular := float(water.get_shader_parameter("specular"))
	var original_water_roughness := float(water.get_shader_parameter("water_roughness_near"))
	water.set_shader_parameter("specular", 0.12)
	await _capture_reflection("B7_reflection_lower_specular", out, weather, water)
	water.set_shader_parameter("water_roughness_near", 0.095)
	await _capture_reflection("B8_reflection_lower_specular_softer", out, weather, water)
	water.set_shader_parameter("specular", 0.10)
	water.set_shader_parameter("water_roughness_near", 0.12)
	await _capture_reflection("B9_reflection_soft_candidate", out, weather, water)
	water.set_shader_parameter("specular", 0.08)
	water.set_shader_parameter("water_roughness_near", original_water_roughness)
	await _capture_reflection("B10_reflection_specular_008", out, weather, water)
	water.set_shader_parameter("specular", 0.06)
	await _capture_reflection("B11_reflection_specular_006", out, weather, water)
	water.set_shader_parameter("specular", original_water_specular)
	water.set_shader_parameter("water_roughness_near", original_water_roughness)
	water.set_shader_parameter("freeze_time", was_frozen)
	weather.set_weather_by_index(WeatherController.Preset.PARTLY_CLOUDY)
	await _wait_seconds(weather.transition_seconds + 1.0)
	await _capture_full("B5_partly_cloudy_after", out, weather)
	weather.set_weather_by_index(WeatherController.Preset.OVERCAST)
	await _wait_seconds(weather.transition_seconds + 1.0)
	await _capture_full("B6_overcast_after", out, weather)
	var report := {
		"engine": Engine.get_version_info(),
		"renderer": RenderingServer.get_video_adapter_name(),
		"resolution": [root.size.x, root.size.y],
		"quality": "High",
		"vsync": "disabled",
		"camera_fov": camera.fov,
		"final_weather": weather.current_weather_name,
		"sunny_sun_setup": sunny_state,
		"final_sun_state": _capture_sun_state(weather, sky, sunlight, environment),
		"transition_mesh": mesh_stats,
		"captures": _captures,
	}
	var report_file := FileAccess.open(out.path_join("final_diagnostics.json"), FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "  ") + "\n")
	print(JSON.stringify(report, "  "))
	main.queue_free()
	await process_frame
	quit()


func _capture_timeline(name: String, out: String) -> void:
	var sheet := Image.create(TILE_SIZE.x * TIMELINE_COLUMNS,
		TILE_SIZE.y * int(ceil(float(SAMPLE_SECONDS) / TIMELINE_COLUMNS)), false, Image.FORMAT_RGBA8)
	var scores: Array[float] = []
	var peak := -1.0
	var peak_image: Image
	for index in range(SAMPLE_SECONDS):
		await _wait_seconds(SAMPLE_INTERVAL)
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		if image == null or image.is_empty():
			continue
		var score := _horizon_line_score(image)
		scores.append(score)
		if score > peak:
			peak = score
			peak_image = image.duplicate()
		var tile := image.duplicate()
		tile.convert(Image.FORMAT_RGBA8)
		tile.resize(TILE_SIZE.x, TILE_SIZE.y, Image.INTERPOLATE_BILINEAR)
		var target := Vector2i((index % TIMELINE_COLUMNS) * TILE_SIZE.x,
			(index / TIMELINE_COLUMNS) * TILE_SIZE.y)
		sheet.blit_rect(tile, Rect2i(Vector2i.ZERO, TILE_SIZE), target)
	var timeline_path := out.path_join(name + "_timeline.png")
	var save_error := sheet.save_png(timeline_path)
	_captures.append({"name": name + "_timeline", "path": timeline_path,
		"samples_seconds": SAMPLE_SECONDS, "line_scores": scores,
		"max_horizon_row_contrast": peak, "save_error": save_error})
	if peak_image != null:
		var peak_path := out.path_join(name + "_peak.png")
		_captures.append({"name": name + "_peak", "path": peak_path,
			"save_error": peak_image.save_png(peak_path)})
	print("Captured %s for %d seconds; horizon row contrast %.5f" % [name, SAMPLE_SECONDS, peak])


func _horizon_line_score(image: Image) -> float:
	var left := int(float(image.get_width()) * 0.04)
	var right := int(float(image.get_width()) * 0.96)
	var best := 0.0
	for y in range(int(float(image.get_height()) * 0.32), int(float(image.get_height()) * 0.48)):
		var row_sum := 0.0
		var neighbour_sum := 0.0
		var count := 0
		for x in range(left, right, 4):
			row_sum += _luminance(image.get_pixel(x, y))
			neighbour_sum += 0.5 * (_luminance(image.get_pixel(x, y - 2)) + _luminance(image.get_pixel(x, y + 2)))
			count += 1
		if count > 0:
			best = maxf(best, absf(row_sum - neighbour_sum) / float(count))
	return best


func _luminance(color: Color) -> float:
	return color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722


func _get_transition_mesh_stats(ocean: Ocean) -> Dictionary:
	var instance := ocean.get_node_or_null("_gen_farplane_transition") as MeshInstance3D
	if instance == null or instance.mesh == null:
		return {"present": false}
	var arrays := instance.mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	return {"present": true, "vertex_count": vertices.size(),
		"triangle_count": indices.size() / 3, "index_count": indices.size()}


func _capture_full(name: String, out: String, weather: WeatherController = null) -> void:
	await _wait_frames(12)
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var image_path := out.path_join(name + ".png")
	var save_error := image.save_png(image_path)
	var capture := {"name": name, "path": image_path,
		"width": image.get_width(), "height": image.get_height(), "save_error": save_error}
	if weather != null:
		capture["weather"] = weather.current_weather_name
		capture["sun_elevation"] = weather.get_sun_elevation()
		capture["cloud_coverage"] = weather.get_cloud_coverage()
	_captures.append(capture)


func _capture_reflection(name: String, out: String, weather: WeatherController, water: ShaderMaterial) -> void:
	await _capture_full(name, out, weather)
	_captures.back()["water_specular"] = water.get_shader_parameter("specular")
	_captures.back()["water_roughness_near"] = water.get_shader_parameter("water_roughness_near")


func _wait_frames(count: int) -> void:
	for _index in range(count):
		await process_frame


func _wait_seconds(seconds: float) -> void:
	await create_timer(seconds, false, true, false).timeout


func _zero_array(count: int) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	values.resize(count)
	values.fill(0.0)
	return values


func _color_array(color: Color) -> Array[float]:
	return [color.r, color.g, color.b]


func _vector3_array(value: Variant) -> Array[float]:
	var vector := Vector3(value)
	return [vector.x, vector.y, vector.z]


func _capture_sun_state(
	weather: WeatherController,
	sky: ShaderMaterial,
	sunlight: DirectionalLight3D,
	environment: Environment
) -> Dictionary:
	return {
		"weather": weather.current_weather_name,
		"sun_azimuth": weather.get_sun_azimuth(),
		"sun_elevation": weather.get_sun_elevation(),
		"sunlight_energy": sunlight.light_energy,
		"sunlight_color": _color_array(sunlight.light_color),
		"disk_color": _vector3_array(Vector3(sky.get_shader_parameter("sun_disk_color"))),
		"radius_degrees": sky.get_shader_parameter("sun_disk_radius_degrees"),
		"edge_softness_degrees": sky.get_shader_parameter("sun_edge_softness_degrees"),
		"core_radiance": sky.get_shader_parameter("sun_core_radiance"),
		"halo_strength": sky.get_shader_parameter("sun_halo_strength"),
		"halo_radius_degrees": sky.get_shader_parameter("sun_halo_radius_degrees"),
		"glow_threshold": environment.glow_hdr_threshold,
		"glow_intensity": environment.glow_intensity,
	}
