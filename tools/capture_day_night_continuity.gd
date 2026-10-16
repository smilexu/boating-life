extends SceneTree
## Captures stable production-camera comparisons for selected seasonal phases.
## Run with a graphical renderer: godot --path . --script res://tools/capture_day_night_continuity.gd -- --phase before

const MAIN_SCENE := preload("res://scenes/main.tscn")
const SOLAR_POSITION := preload("res://scripts/solar_position.gd")
const OUTPUT_ROOT := "res://docs/day_night_continuity"
const LATITUDE := 55.7
const LONGITUDE := 12.75

var _captures: Array[Dictionary] = []
var _weather_captures: Array[Dictionary] = []
var _phase := "before"


func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--phase="):
			_phase = argument.trim_prefix("--phase=")
	_capture.call_deferred()


func _capture() -> void:
	var manager := root.get_node_or_null("WorldTimeManager")
	if manager == null:
		push_error("WorldTimeManager autoload is not available.")
		quit(1)
		return
	var original_snapshot: Dictionary = manager.call("create_snapshot")
	var original_autosave := bool(manager.get("autosave_enabled"))
	manager.set("autosave_enabled", false)
	var old_vsync := DisplayServer.window_get_vsync_mode()
	var old_max_fps := Engine.max_fps
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	var main := MAIN_SCENE.instantiate()
	root.add_child(main)
	await _wait_frames(25)
	var quality := main.get_node("QualityManager") as QualityManager
	var boat := main.get_node("PlayerBoat")
	var motion_root := boat.get_node("MotionRoot") as Node3D
	var visual_root := boat.get_node("MotionRoot/VisualRoot") as Node3D
	var camera_rig := boat.get_node("FollowCameraRig") as Node3D
	var camera := boat.get_node("FollowCameraRig/Camera3D") as Camera3D
	var weather := main.get_node("WeatherController") as WeatherController
	var water := (main.get_node("BathymetryManager") as BathymetryManager).water_material
	if quality == null or camera == null or water == null or weather == null:
		push_error("Main scene is missing a required capture system.")
		await _finish(main, manager, original_snapshot, original_autosave, old_vsync, old_max_fps)
		quit(1)
		return

	quality.set_quality_for_benchmark(QualityManager.Quality.HIGH)
	weather.set_weather_by_index(WeatherController.Preset.CLEAR)
	motion_root.set_process(false)
	motion_root.set_physics_process(false)
	visual_root.set_process(false)
	visual_root.set_physics_process(false)
	camera_rig.set_process(false)
	camera_rig.set_physics_process(false)
	camera.make_current()
	water.set_shader_parameter("freeze_time", true)
	manager.call("pause_time")
	manager.call("set_time_scale", 24.0)
	var output_path := ProjectSettings.globalize_path(OUTPUT_ROOT.path_join(_phase))
	DirAccess.make_dir_recursive_absolute(output_path)

	for date in [{"year": 2026, "month": 7, "day": 15}, {"year": 2026, "month": 12, "day": 15}]:
		for sample in _samples_for_date(date):
			var seconds := float(sample["seconds"])
			manager.call("set_calendar_date", int(date["year"]), int(date["month"]), int(date["day"]))
			manager.call("set_day_cycle_time", int(seconds / 3600.0), int(fposmod(seconds, 3600.0) / 60.0))
			await _wait_frames(30)
			var controller := main.get_node("DayNightVisualController")
			var solar: Dictionary = controller.call("get_solar_state")
			var time_label := "%02d%02d" % [int(seconds / 3600.0), int(fposmod(seconds, 3600.0) / 60.0)]
			var season := "summer" if int(date["month"]) == 7 else "winter"
			var name := "%s_%s_%s" % [season, str(sample["name"]), time_label]
			var image := root.get_texture().get_image()
			var file_path := output_path.path_join(name + ".png")
			var save_error := image.save_png(file_path)
			_captures.append({
				"name": name,
				"phase": sample["name"],
				"path": file_path,
				"save_error": save_error,
				"width": image.get_width(),
				"height": image.get_height(),
				"date": date,
				"stockholm_time": time_label,
				"solar_elevation_degrees": solar.get("elevation_degrees", 0.0),
				"solar_azimuth_degrees": solar.get("azimuth_degrees", 0.0),
				"direct_light_strength": solar.get("direct_light_strength", 0.0),
				"daylight_strength": solar.get("daylight_strength", 0.0),
				"deep_night_available": float(sample["minimum_elevation"]) <= -18.0,
				"note": sample.get("note", ""),
			})
			print("Captured %s | elevation %+.2f° | azimuth %.2f° | save_error=%d" % [name, float(solar.get("elevation_degrees", 0.0)), float(solar.get("azimuth_degrees", 0.0)), save_error])

	await _capture_weather_regressions(main, manager, weather, output_path)

	var report := {
		"phase": _phase,
		"engine": Engine.get_version_info(),
		"renderer": RenderingServer.get_video_adapter_name(),
		"processor": OS.get_processor_name(),
		"window_size": [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y],
		"quality": "High",
		"weather": "Clear for seasonal phase captures; see weather_regressions for transition captures",
		"vsync_during_capture": "disabled",
		"water_phase_frozen": true,
		"fixed_production_camera": true,
		"captures": _captures,
		"weather_regressions": _weather_captures,
	}
	var report_file := FileAccess.open(output_path.path_join("capture_report.json"), FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "\t") + "\n")
		report_file.close()
	print(JSON.stringify(report, "\t"))
	await _finish(main, manager, original_snapshot, original_autosave, old_vsync, old_max_fps)
	quit()


func _capture_weather_regressions(main: Node, manager: Node, weather: WeatherController, output_path: String) -> void:
	var regression_path := output_path.path_join("weather_regressions")
	DirAccess.make_dir_recursive_absolute(regression_path)
	var samples := [
		{"weather": "PartlyCloudy", "hour": 20, "minute": 37, "name": "summer_partly_cloudy_golden_hour"},
		{"weather": "Overcast", "hour": 20, "minute": 37, "name": "summer_overcast_golden_hour"},
		{"weather": "Overcast", "hour": 22, "minute": 53, "name": "summer_overcast_blue_hour"},
	]
	for sample in samples:
		manager.call("set_calendar_date", 2026, 7, 15)
		manager.call("set_day_cycle_time", int(sample["hour"]), int(sample["minute"]))
		weather.set_weather_by_name(str(sample["weather"]))
		await create_timer(weather.transition_seconds + 0.25).timeout
		await _wait_frames(8)
		var controller := main.get_node("DayNightVisualController")
		var solar: Dictionary = controller.call("get_solar_state")
		var image := root.get_texture().get_image()
		var file_path := regression_path.path_join(str(sample["name"]) + ".png")
		var save_error := image.save_png(file_path)
		_weather_captures.append({
			"name": sample["name"],
			"weather": sample["weather"],
			"date": "2026-07-15",
			"stockholm_time": "%02d:%02d" % [int(sample["hour"]), int(sample["minute"])],
			"solar_elevation_degrees": solar.get("elevation_degrees", 0.0),
			"path": file_path,
			"save_error": save_error,
		})
		print("Captured weather regression %s (%s) | save_error=%d" % [sample["name"], sample["weather"], save_error])


func _samples_for_date(date: Dictionary) -> Array[Dictionary]:
	var minimum_elevation := 90.0
	var maximum_elevation := -90.0
	var minimum_seconds := 0.0
	var maximum_seconds := 0.0
	for minute in range(1440):
		var seconds := float(minute * 60)
		var solar: Dictionary = SOLAR_POSITION.calculate(date, seconds, LATITUDE, LONGITUDE)
		var elevation := float(solar["elevation_degrees"])
		if elevation < minimum_elevation:
			minimum_elevation = elevation
			minimum_seconds = seconds
		if elevation > maximum_elevation:
			maximum_elevation = elevation
			maximum_seconds = seconds

	var afternoon_target := maxf(2.0, maximum_elevation * 0.62)
	var golden_target := minf(7.0, maxf(1.0, maximum_elevation * 0.42))
	var samples: Array[Dictionary] = [
		_sample("pre_dawn", _find_crossing(date, -12.0, true), minimum_elevation),
		_sample("sunrise", _find_crossing(date, -0.5, true), minimum_elevation),
		_sample("noon", maximum_seconds, minimum_elevation, "Daily maximum solar elevation"),
		_sample("afternoon", _find_crossing(date, afternoon_target, false), minimum_elevation, "Descending solar elevation near 62% of the daily maximum"),
		_sample("golden_hour", _find_crossing(date, golden_target, false), minimum_elevation, "Descending low sun; target is adapted to the season"),
		_sample("sunset", _find_crossing(date, -0.5, false), minimum_elevation),
		_sample("blue_hour", _find_crossing(date, -7.0, false), minimum_elevation),
		_sample("deep_night", minimum_seconds, minimum_elevation, "Deep astronomical night is unavailable in July if the sun never reaches -18 degrees"),
	]
	return samples


func _find_crossing(date: Dictionary, target_elevation: float, rising: bool) -> float:
	var previous_elevation := float(SOLAR_POSITION.calculate(date, 0.0, LATITUDE, LONGITUDE)["elevation_degrees"])
	for minute in range(1, 1441):
		var seconds := float(minute * 60)
		var solar: Dictionary = SOLAR_POSITION.calculate(date, fposmod(seconds, 86400.0), LATITUDE, LONGITUDE)
		var elevation := float(solar["elevation_degrees"])
		if (rising and previous_elevation < target_elevation and elevation >= target_elevation) or (not rising and previous_elevation >= target_elevation and elevation < target_elevation):
			return fposmod(seconds, 86400.0)
		previous_elevation = elevation
	# If the seasonal path does not cross a target, use the closest actual solar
	# elevation rather than inventing a fixed sunset or sunrise clock time.
	var closest_seconds := 0.0
	var closest_difference := INF
	for minute in range(1440):
		var seconds := float(minute * 60)
		var elevation := float(SOLAR_POSITION.calculate(date, seconds, LATITUDE, LONGITUDE)["elevation_degrees"])
		var difference := absf(elevation - target_elevation)
		if difference < closest_difference:
			closest_difference = difference
			closest_seconds = seconds
	return closest_seconds


func _sample(label: String, seconds: float, minimum_elevation: float, note := "") -> Dictionary:
	return {"name": label, "seconds": seconds, "minimum_elevation": minimum_elevation, "note": note}


func _finish(main: Node, manager: Node, snapshot: Dictionary, autosave: bool, vsync: int, max_fps: int) -> void:
	if main != null and is_instance_valid(main):
		main.queue_free()
		await process_frame
	manager.call("restore_snapshot", snapshot)
	manager.set("autosave_enabled", autosave)
	DisplayServer.window_set_vsync_mode(vsync)
	Engine.max_fps = max_fps


func _wait_frames(count: int) -> void:
	for _frame in range(count):
		await process_frame
