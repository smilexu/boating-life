extends SceneTree
## Captures the night-atmosphere polish with the real renderer.
## Run without --headless: godot --path . --script res://tools/capture_night_atmosphere.gd

const MAIN_SCENE := preload("res://scenes/main.tscn")
const MOON_POSITION := preload("res://scripts/moon_position.gd")
const SOLAR_POSITION := preload("res://scripts/solar_position.gd")
const OUTPUT_ROOT := "res://docs/night_atmosphere_polish/iteration_2026-10-16"
const PREVIOUS_FULL_MOON := "res://docs/lunar_visuals/D_full_moon_stars_reflection.png"
const PREVIOUS_BOAT := "res://docs/lunar_visuals/J_moonlit_boat_third_person.png"
const LATITUDE := 55.7
const LONGITUDE := 12.75

var _report_rows: Array[Dictionary] = []
var _production_camera_transform := Transform3D.IDENTITY


func _initialize() -> void:
	_capture.call_deferred()


func _capture() -> void:
	var manager := root.get_node_or_null("WorldTimeManager")
	if manager == null:
		push_error("WorldTimeManager autoload is not available.")
		quit(1)
		return
	var original_snapshot: Dictionary = manager.call("create_snapshot")
	var original_autosave := bool(manager.get("autosave_enabled"))
	var original_vsync := DisplayServer.window_get_vsync_mode()
	var original_max_fps := Engine.max_fps
	manager.set("autosave_enabled", false)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	var output_path := ProjectSettings.globalize_path(OUTPUT_ROOT)
	DirAccess.make_dir_recursive_absolute(output_path)
	_copy_reference(PREVIOUS_FULL_MOON, output_path.path_join("H_before_full_moon.png"))
	_copy_reference(PREVIOUS_BOAT, output_path.path_join("H_before_boat.png"))

	var main := MAIN_SCENE.instantiate()
	root.add_child(main)
	await _wait_frames(35)
	var quality := main.get_node("QualityManager") as QualityManager
	var boat := main.get_node("PlayerBoat") as Node3D
	var motion_root := boat.get_node("MotionRoot") as Node3D
	var visual_root := boat.get_node("MotionRoot/VisualRoot") as Node3D
	var camera_rig := boat.get_node("FollowCameraRig") as Node3D
	var camera := boat.get_node("FollowCameraRig/Camera3D") as Camera3D
	var weather := main.get_node("WeatherController") as WeatherController
	var controller := main.get_node("DayNightVisualController") as DayNightVisualController
	for canvas in main.find_children("*", "CanvasLayer", true, false):
		(canvas as CanvasLayer).visible = false
	var water := (main.get_node("BathymetryManager") as BathymetryManager).water_material
	if quality == null or camera == null or weather == null or controller == null or water == null:
		push_error("Main scene is missing a required lunar capture system.")
		await _finish(main, manager, original_snapshot, original_autosave, original_vsync, original_max_fps)
		quit(1)
		return
	quality.set_quality_for_benchmark(QualityManager.Quality.HIGH)
	motion_root.set_process(false)
	motion_root.set_physics_process(false)
	visual_root.set_process(false)
	visual_root.set_physics_process(false)
	camera_rig.set_process(false)
	camera_rig.set_physics_process(false)
	var wake := boat.get_node_or_null("MotionRoot/VisualRoot/WakeSystem")
	if wake != null:
		_disable_particles(wake)
	camera.make_current()
	_production_camera_transform = camera.global_transform
	water.set_shader_parameter("freeze_time", true)
	manager.call("pause_time")
	manager.call("set_time_scale", 24.0)
	weather.transition_seconds = 1.0
	weather.set_weather_by_name("Clear")
	await _wait_frames(45)

	var start_date: Dictionary = manager.call("get_calendar_date")
	var twilight_case := _find_twilight_moon_case(start_date)
	var full_case := _find_phase_case(start_date, 1.0)
	var quarter_case := _find_phase_case(start_date, 0.5)
	var new_case := _find_phase_case(start_date, 0.0)
	var deep_new_case := _find_phase_case({"year": 2026, "month": 12, "day": 1}, 0.0)
	print("Selected night samples: ", JSON.stringify({"twilight": twilight_case, "full": full_case, "quarter": quarter_case, "new": new_case, "deep_new": deep_new_case}))

	await _capture_case("A_twilight_moonrise", twilight_case.date, twilight_case.seconds, "Clear", camera, boat, weather, controller, "moon")
	await _capture_case("B_full_moon_clear_night", full_case.date, full_case.seconds, "Clear", camera, boat, weather, controller, "moon")
	await _capture_case("C_half_moon", quarter_case.date, quarter_case.seconds, "Clear", camera, boat, weather, controller, "moon")
	await _capture_case("D_new_moon", new_case.date, new_case.seconds, "Clear", camera, boat, weather, controller, "open_sky")
	await _capture_case("E_deep_night_stars", deep_new_case.date, 23.0 * 3600.0, "Clear", camera, boat, weather, controller, "open_sky")
	await _capture_case("F_moonlit_boat", full_case.date, full_case.seconds, "Clear", camera, boat, weather, controller, "boat_and_moon")
	await _capture_case("G_overcast_moon", full_case.date, full_case.seconds, "Overcast", camera, boat, weather, controller, "moon")
	await _make_comparison(output_path, "H_before_full_moon.png", "B_full_moon_clear_night.png", "H_full_moon_before_after.png")
	await _make_comparison(output_path, "H_before_boat.png", "F_moonlit_boat.png", "H_boat_before_after.png")

	var report := {
		"engine": Engine.get_version_info(),
		"renderer": RenderingServer.get_video_adapter_name(),
		"processor": OS.get_processor_name(),
		"window_size": [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y],
		"quality": "High",
		"vsync": "disabled",
		"water_phase_frozen": true,
		"date_cycle_sampling": "Moon orbit/phase is sampled at Stockholm local noon for each world-calendar date; the lunar hour angle uses the accelerated day-cycle time.",
		"comparison_baselines": [PREVIOUS_FULL_MOON, PREVIOUS_BOAT],
		"visual_changes": {"moon_angular_radius_degrees": 1.235, "moon_core_radiance": 2.58, "moon_halo_strength": 0.16, "stars_brightness": 1.75, "bright_star_cohort_count": 24, "night_palette_darkened": true, "boat_fill_tracks_night_and_moon_phase": true},
		"captures": _report_rows,
	}
	var file := FileAccess.open(output_path.path_join("capture_report.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t") + "\n")
		file.close()
	print(JSON.stringify(report, "\t"))
	await _finish(main, manager, original_snapshot, original_autosave, original_vsync, original_max_fps)
	quit()


func _capture_case(name: String, date: Dictionary, seconds: float, weather_name: String, camera: Camera3D, boat: Node3D, weather: WeatherController, controller: DayNightVisualController, camera_mode: String) -> void:
	var manager := root.get_node("WorldTimeManager")
	manager.call("set_calendar_date", int(date["year"]), int(date["month"]), int(date["day"]))
	manager.call("set_day_cycle_time", int(seconds / 3600.0), int(fposmod(seconds, 3600.0) / 60.0), fposmod(seconds, 60.0))
	weather.set_weather_by_name(weather_name)
	await create_timer(weather.transition_seconds + 0.2).timeout
	await _wait_frames(30)
	if camera_mode == "moon" or camera_mode == "open_sky":
		var moon: Dictionary = controller.get_moon_state()
		var direction: Vector3 = moon.get("direction", Vector3(0.0, 0.15, -1.0))
		if camera_mode == "open_sky" or float(moon.get("elevation_degrees", -90.0)) < 3.0:
			direction = Vector3(0.0, 0.22, -1.0).normalized()
		camera.global_position = boat.global_position + Vector3(0.0, 7.0, 0.0)
		camera.look_at(camera.global_position + direction * 1000.0, Vector3.UP)
		camera.make_current()
	elif camera_mode == "boat_and_moon":
		var moon: Dictionary = controller.get_moon_state()
		var direction: Vector3 = moon.get("direction", Vector3(0.0, 0.15, -1.0))
		var horizontal_moon := Vector3(direction.x, 0.0, direction.z).normalized()
		camera.fov = 70.0
		camera.global_position = boat.global_position - horizontal_moon * 18.0 + Vector3.UP * 5.0
		var boat_direction := (horizontal_moon * 18.0 - Vector3.UP * 5.0).normalized()
		var shared_view_direction := (direction + boat_direction).normalized()
		camera.look_at(camera.global_position + shared_view_direction * 1000.0, Vector3.UP)
		camera.make_current()
	else:
		var camera_rig := camera.get_parent() as Node3D
		camera_rig.set_process(false)
		camera_rig.set_physics_process(false)
		camera.global_transform = _production_camera_transform
		camera.make_current()
	await _wait_frames(20)
	# process_frame fires before draw; wait for the completed render so a capture
	# cannot accidentally reuse the previous case's viewport image.
	await RenderingServer.frame_post_draw
	var solar := controller.get_solar_state()
	var lunar := controller.get_moon_state()
	var scene_root := weather.get_parent()
	var cloud_fill := scene_root.get_node("NightCloudFill") as DirectionalLight3D
	var cloud_driver := scene_root.get_node("SunshineCloudsDriverGD") as SunshineCloudsDriverGD
	var environment := (scene_root.get_node("WorldEnvironment") as WorldEnvironment).environment
	var sky_material := environment.sky.sky_material as ShaderMaterial
	var water_material := weather.water_material
	var image := root.get_texture().get_image()
	var boat_screen_position := camera.unproject_position(boat.global_position + Vector3.UP * 4.0)
	var boat_behind_camera := camera.is_position_behind(boat.global_position + Vector3.UP * 4.0)
	var path := ProjectSettings.globalize_path(OUTPUT_ROOT).path_join(name + ".png")
	var save_error := image.save_png(path)
	_report_rows.append({
		"name": name,
		"weather": weather_name,
		"date": date.duplicate(true),
		"cycle_seconds": seconds,
		"solar_elevation_degrees": solar.get("elevation_degrees", 0.0),
		"solar_azimuth_degrees": solar.get("azimuth_degrees", 0.0),
		"moon_elevation_degrees": lunar.get("elevation_degrees", 0.0),
		"moon_azimuth_degrees": lunar.get("azimuth_degrees", 0.0),
		"moon_phase": lunar.get("phase_name", "Unavailable"),
		"moon_illumination_fraction": lunar.get("illumination_fraction", 0.0),
		"moon_visibility": sky_material.get_shader_parameter("moon_visibility"),
		"moonlight_strength": lunar.get("moonlight_strength", 0.0),
		"cloud_fill_energy": cloud_fill.light_energy,
		"cloud_light_count": cloud_driver.clouds_resource.directional_lights_data.size() / 2,
		"cloud_ambient_color": cloud_driver.clouds_resource.cloud_ambient_color,
		"cloud_ambient_tint": cloud_driver.clouds_resource.cloud_ambient_tint,
		"sun_disk_radius_degrees": sky_material.get_shader_parameter("sun_disk_radius_degrees"),
		"sun_core_radiance": sky_material.get_shader_parameter("sun_core_radiance"),
		"moon_angular_radius_degrees": sky_material.get_shader_parameter("moon_angular_radius_degrees"),
		"moon_core_radiance": sky_material.get_shader_parameter("moon_core_radiance"),
		"sky_top_color": sky_material.get_shader_parameter("sky_top_color"),
		"sky_horizon_color": sky_material.get_shader_parameter("sky_horizon_color"),
		"ground_horizon_color": sky_material.get_shader_parameter("ground_horizon_color"),
		"ambient_light_color": environment.ambient_light_color,
		"ambient_light_energy": environment.ambient_light_energy,
		"moon_light_specular_multiplier": (scene_root.get_node("Moonlight") as DirectionalLight3D).light_specular,
		"night_water_weight": water_material.get_shader_parameter("night_visual_weight"),
		"night_water_emission": water_material.get_shader_parameter("night_surface_lift"),
		"night_water_specular_scale": water_material.get_shader_parameter("night_specular_scale"),
		"night_water_roughness": water_material.get_shader_parameter("night_roughness_target"),
		"star_strength": lunar.get("star_strength", 0.0),
		"boat_fill_strength": lunar.get("boat_fill_strength", 0.0),
		"boat_fill_energy_actual": (boat.get_node("MotionRoot/VisualRoot/BoatSkyFill") as OmniLight3D).light_energy,
		"boat_fill_position_local": (boat.get_node("MotionRoot/VisualRoot/BoatSkyFill") as OmniLight3D).position,
		"width": image.get_width(),
		"height": image.get_height(),
		"save_error": save_error,
		"path": path,
		"camera_mode": camera_mode,
		"boat_screen_position": boat_screen_position if camera_mode == "boat_and_moon" else Vector2(-1.0, -1.0),
		"boat_behind_camera": boat_behind_camera if camera_mode == "boat_and_moon" else false,
	})
	print("Captured %s | moon=%s %.0f%% at %+.1f° | sun %+.1f° | save_error=%d" % [name, str(lunar.get("phase_name", "?")), float(lunar.get("illumination_fraction", 0.0)) * 100.0, float(lunar.get("elevation_degrees", -90.0)), float(solar.get("elevation_degrees", -90.0)), save_error])
	if camera_mode == "boat_and_moon":
		print("BOAT_FRAME screen=%s behind=%s camera_position=%s target=%s" % [boat_screen_position, boat_behind_camera, camera.global_position, camera.global_transform.basis.z])


func _find_phase_case(start_date: Dictionary, target_illumination: float) -> Dictionary:
	var best_score := INF
	var best := {"date": start_date.duplicate(true), "seconds": 22.0 * 3600.0}
	for day_offset in range(0, 36):
		var date := _shift_date(start_date, day_offset)
		var phase: Dictionary = MOON_POSITION.calculate(date, 12.0 * 3600.0, LATITUDE, LONGITUDE)
		var phase_error := absf(float(phase.get("illumination_fraction", 0.0)) - target_illumination)
		for time_step in range(36, 48):
			var seconds := float(time_step * 1800)
			var moon: Dictionary = MOON_POSITION.calculate(date, seconds, LATITUDE, LONGITUDE)
			var sun: Dictionary = SOLAR_POSITION.calculate(date, seconds, LATITUDE, LONGITUDE)
			var moon_elevation := float(moon.get("elevation_degrees", -90.0))
			var sun_elevation := float(sun.get("elevation_degrees", 90.0))
			var moon_altitude_cost := maxf(0.0, 24.0 - moon_elevation) * (0.012 if target_illumination >= 0.1 else 0.0)
			var dark_sky_cost := maxf(0.0, sun_elevation + 18.0) * 0.018
			var score := phase_error * 4.0 + moon_altitude_cost + dark_sky_cost
			var moon_visible_for_photo := target_illumination < 0.1 or moon_elevation > 2.0
			if moon_visible_for_photo and sun_elevation < -3.0 and score < best_score:
				best_score = score
				best = {"date": date, "seconds": seconds, "illumination": float(phase.get("illumination_fraction", 0.0)), "moon_elevation": moon_elevation, "sun_elevation": sun_elevation}
	return best


func _find_twilight_moon_case(start_date: Dictionary) -> Dictionary:
	var best_score := INF
	var best := {"date": start_date.duplicate(true), "seconds": 19.0 * 3600.0}
	for day_offset in range(0, 40):
		var date := _shift_date(start_date, day_offset)
		var phase: Dictionary = MOON_POSITION.calculate(date, 12.0 * 3600.0, LATITUDE, LONGITUDE)
		var illumination := float(phase.get("illumination_fraction", 0.0))
		if illumination < 0.78:
			continue
		for time_step in range(32, 48):
			var seconds := float(time_step * 1800)
			var moon: Dictionary = MOON_POSITION.calculate(date, seconds, LATITUDE, LONGITUDE)
			var sun: Dictionary = SOLAR_POSITION.calculate(date, seconds, LATITUDE, LONGITUDE)
			var moon_elevation := float(moon.get("elevation_degrees", -90.0))
			var sun_elevation := float(sun.get("elevation_degrees", 90.0))
			if moon_elevation < 3.0 or sun_elevation < -10.0 or sun_elevation > 0.0:
				continue
			var score := absf(sun_elevation + 3.5) + absf(moon_elevation - 9.0) * 0.18 + (1.0 - illumination) * 2.0
			if score < best_score:
				best_score = score
				best = {"date": date, "seconds": seconds, "illumination": illumination, "moon_elevation": moon_elevation, "sun_elevation": sun_elevation}
	return best


func _find_sunset_seconds(date: Dictionary) -> float:
	var previous: Dictionary = SOLAR_POSITION.calculate(date, 0.0, LATITUDE, LONGITUDE)
	for minute in range(1, 1441):
		var seconds := float(minute * 60)
		var current: Dictionary = SOLAR_POSITION.calculate(date, fposmod(seconds, 86400.0), LATITUDE, LONGITUDE)
		if float(previous.get("elevation_degrees", 0.0)) >= -0.5 and float(current.get("elevation_degrees", 0.0)) < -0.5:
			return fposmod(seconds, 86400.0)
		previous = current
	return 21.5 * 3600.0


func _shift_date(source: Dictionary, offset: int) -> Dictionary:
	var result := source.duplicate(true)
	for _step in range(offset):
		result["day"] = int(result["day"]) + 1
		var year := int(result["year"])
		var month := int(result["month"])
		var month_days := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
		if month == 2 and (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)):
			month_days[1] = 29
		if int(result["day"]) > int(month_days[month - 1]):
			result["day"] = 1
			result["month"] = month + 1
			if int(result["month"]) > 12:
				result["month"] = 1
				result["year"] = year + 1
	return result


func _copy_reference(source_resource_path: String, destination: String) -> void:
	if not FileAccess.file_exists(source_resource_path):
		push_warning("Could not find previous visual baseline: %s" % source_resource_path)
		return
	var error := DirAccess.copy_absolute(ProjectSettings.globalize_path(source_resource_path), destination)
	if error != OK:
		push_warning("Could not copy previous visual baseline %s: %s" % [source_resource_path, error_string(error)])


func _make_comparison(output_path: String, before_name: String, after_name: String, comparison_name: String) -> void:
	var before := Image.new()
	var after := Image.new()
	var before_error := before.load(output_path.path_join(before_name))
	var after_error := after.load(output_path.path_join(after_name))
	if before_error != OK or after_error != OK:
		push_warning("Could not assemble %s (before=%s after=%s)." % [comparison_name, error_string(before_error), error_string(after_error)])
		return
	if before.get_size() != after.get_size():
		push_warning("Comparison image sizes differ for %s." % comparison_name)
		return
	before.convert(Image.FORMAT_RGBA8)
	after.convert(Image.FORMAT_RGBA8)
	var comparison := Image.create(before.get_width() * 2, before.get_height(), false, Image.FORMAT_RGBA8)
	comparison.blit_rect(before, Rect2i(Vector2i.ZERO, before.get_size()), Vector2i.ZERO)
	comparison.blit_rect(after, Rect2i(Vector2i.ZERO, after.get_size()), Vector2i(before.get_width(), 0))
	var error := comparison.save_png(output_path.path_join(comparison_name))
	if error != OK:
		push_warning("Could not save comparison %s: %s" % [comparison_name, error_string(error)])


func _wait_frames(count: int) -> void:
	for _frame in range(count):
		await process_frame


func _disable_particles(node: Node) -> void:
	if node is GPUParticles3D:
		(node as GPUParticles3D).emitting = false
	for child in node.get_children():
		_disable_particles(child)


func _finish(main: Node, manager: Node, snapshot: Dictionary, autosave: bool, vsync: int, max_fps: int) -> void:
	main.queue_free()
	await process_frame
	manager.call("restore_snapshot", snapshot)
	manager.set("autosave_enabled", autosave)
	DisplayServer.window_set_vsync_mode(vsync)
	Engine.max_fps = max_fps
