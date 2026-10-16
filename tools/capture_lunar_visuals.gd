extends SceneTree
## Captures the post-change sun, moon, star, cloud, and ship views with the real renderer.
## Run without --headless: godot --path . --script res://tools/capture_lunar_visuals.gd

const MAIN_SCENE := preload("res://scenes/main.tscn")
const MOON_POSITION := preload("res://scripts/moon_position.gd")
const SOLAR_POSITION := preload("res://scripts/solar_position.gd")
const OUTPUT_ROOT := "res://docs/lunar_visuals"
const REFERENCE_SUN := "res://docs/ocean_sun_polish/B0_sun_before_frozen_phase.png"
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
	var reference_path := ProjectSettings.globalize_path(REFERENCE_SUN)
	var copy_path := output_path.path_join("A_sun_before.png")
	if FileAccess.file_exists(REFERENCE_SUN):
		var copy_error := DirAccess.copy_absolute(reference_path, copy_path)
		if copy_error != OK:
			push_warning("Could not copy the historical pre-change sun reference: %s" % error_string(copy_error))

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

	var full_case := _find_phase_case(manager.call("get_calendar_date"), 1.0)
	var quarter_case := _find_phase_case(manager.call("get_calendar_date"), 0.5)
	var new_case := _find_phase_case(manager.call("get_calendar_date"), 0.0)
	print("Selected lunar samples: ", JSON.stringify({"full": full_case, "quarter": quarter_case, "new": new_case}))

	await _capture_case("B_sun_after", {"year": 2026, "month": 7, "day": 15}, 6.0 * 3600.0, "Clear", camera, boat, weather, controller, "sun_with_boat")
	var sunset_for_photos := _find_sunset_seconds({"year": 2026, "month": 7, "day": 15}) - 20.0 * 60.0
	await _capture_case("C_sunset_sun_and_sea", {"year": 2026, "month": 7, "day": 15}, sunset_for_photos, "Clear", camera, boat, weather, controller, "sun")
	await _capture_case("D_full_moon_stars_reflection", full_case.date, full_case.seconds, "Clear", camera, boat, weather, controller, "moon")
	await _capture_case("E_quarter_moon", quarter_case.date, quarter_case.seconds, "Clear", camera, boat, weather, controller, "moon")
	await _capture_case("F_new_moon_stars", new_case.date, new_case.seconds, "Clear", camera, boat, weather, controller, "open_sky")
	await _capture_case("G_partly_cloudy_moon", full_case.date, full_case.seconds, "PartlyCloudy", camera, boat, weather, controller, "moon")
	await _capture_case("H_overcast_deep_night", {"year": 2026, "month": 12, "day": 15}, 2.0 * 3600.0, "Overcast", camera, boat, weather, controller, "open_sky")
	await _capture_case("I_sunset_clouds", {"year": 2026, "month": 7, "day": 15}, sunset_for_photos, "PartlyCloudy", camera, boat, weather, controller, "sun")
	await _capture_case("J_moonlit_boat_third_person", full_case.date, full_case.seconds, "Clear", camera, boat, weather, controller, "boat_and_moon")

	var report := {
		"engine": Engine.get_version_info(),
		"renderer": RenderingServer.get_video_adapter_name(),
		"processor": OS.get_processor_name(),
		"window_size": [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y],
		"quality": "High",
		"vsync": "disabled",
		"water_phase_frozen": true,
		"date_cycle_sampling": "Moon orbit/phase is sampled at Stockholm local noon for each world-calendar date; the lunar hour angle uses the accelerated day-cycle time.",
		"historical_sun_reference": ProjectSettings.globalize_path(REFERENCE_SUN),
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
	if camera_mode == "sun" or camera_mode == "sun_with_boat":
		var sun: Dictionary = controller.get_solar_state()
		var direction: Vector3 = sun.get("direction", Vector3(0.0, 0.15, -1.0))
		var horizontal_sun := Vector3(direction.x, 0.0, direction.z).normalized()
		camera.global_position = boat.global_position - horizontal_sun * 90.0 + Vector3.UP * 18.0
		camera.fov = 48.0
		camera.look_at(boat.global_position + Vector3.UP * 1.8, Vector3.UP)
		camera.make_current()
	elif camera_mode == "moon" or camera_mode == "open_sky":
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
		camera.global_position = boat.global_position - horizontal_moon * 110.0 + Vector3.UP * 8.0
		camera.look_at(boat.global_position + direction * 3000.0, Vector3.UP)
		camera.make_current()
	else:
		var camera_rig := camera.get_parent() as Node3D
		camera_rig.set_process(false)
		camera_rig.set_physics_process(false)
		camera.global_transform = _production_camera_transform
		camera.make_current()
	await _wait_frames(20)
	var solar := controller.get_solar_state()
	var lunar := controller.get_moon_state()
	var scene_root := weather.get_parent()
	var cloud_fill := scene_root.get_node("NightCloudFill") as DirectionalLight3D
	var cloud_driver := scene_root.get_node("SunshineCloudsDriverGD") as SunshineCloudsDriverGD
	var environment := (scene_root.get_node("WorldEnvironment") as WorldEnvironment).environment
	var sky_material := environment.sky.sky_material as ShaderMaterial
	var image := root.get_texture().get_image()
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
		"moonlight_strength": lunar.get("moonlight_strength", 0.0),
		"cloud_fill_energy": cloud_fill.light_energy,
		"cloud_light_count": cloud_driver.clouds_resource.directional_lights_data.size() / 2,
		"cloud_ambient_color": cloud_driver.clouds_resource.cloud_ambient_color,
		"cloud_ambient_tint": cloud_driver.clouds_resource.cloud_ambient_tint,
		"sun_disk_radius_degrees": sky_material.get_shader_parameter("sun_disk_radius_degrees"),
		"sun_core_radiance": sky_material.get_shader_parameter("sun_core_radiance"),
		"moon_angular_radius_degrees": sky_material.get_shader_parameter("moon_angular_radius_degrees"),
		"moon_core_radiance": sky_material.get_shader_parameter("moon_core_radiance"),
		"star_strength": lunar.get("star_strength", 0.0),
		"width": image.get_width(),
		"height": image.get_height(),
		"save_error": save_error,
		"path": path,
		"camera_mode": camera_mode,
	})
	print("Captured %s | moon=%s %.0f%% at %+.1f° | sun %+.1f° | save_error=%d" % [name, str(lunar.get("phase_name", "?")), float(lunar.get("illumination_fraction", 0.0)) * 100.0, float(lunar.get("elevation_degrees", -90.0)), float(solar.get("elevation_degrees", -90.0)), save_error])


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
			var score := phase_error * 4.0 + maxf(0.0, 10.0 - moon_elevation) * 0.003 + maxf(0.0, sun_elevation + 5.0) * 0.006
			var moon_visible_for_photo := target_illumination < 0.1 or moon_elevation > 2.0
			if moon_visible_for_photo and sun_elevation < -3.0 and score < best_score:
				best_score = score
				best = {"date": date, "seconds": seconds, "illumination": float(phase.get("illumination_fraction", 0.0)), "moon_elevation": moon_elevation, "sun_elevation": sun_elevation}
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
