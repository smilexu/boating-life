extends SceneTree
## Captures fixed-view horizon checks using the final authored ocean and sky settings.
## Run with: godot --path . --script res://tools/capture_horizon_final.gd

const MAIN_SCENE := preload("res://scenes/main.tscn")
const MOON_POSITION_SCRIPT := preload("res://scripts/moon_position.gd")
const OUTPUT_ROOT := "res://docs/horizon_seam/final"

var _captures: Array[Dictionary] = []
var _observation_start_msec := 0


func _initialize() -> void:
	_capture.call_deferred()


func _capture() -> void:
	var manager := root.get_node_or_null("WorldTimeManager")
	if manager == null:
		push_error("WorldTimeManager autoload is unavailable.")
		quit(1)
		return
	var snapshot: Dictionary = manager.call("create_snapshot")
	var autosave := bool(manager.get("autosave_enabled"))
	var main := MAIN_SCENE.instantiate()
	root.add_child(main)
	await _wait_frames(45)
	manager.set("autosave_enabled", false)
	manager.call("pause_time")
	manager.call("set_calendar_date", 2026, 7, 15)
	manager.call("set_day_cycle_time", 12, 0)
	var quality := main.get_node("QualityManager") as QualityManager
	var boat := main.get_node("PlayerBoat") as Node3D
	var ocean := main.get_node("Ocean") as Ocean
	var material := main.get_node("BathymetryManager").get("water_material") as ShaderMaterial
	var environment := (main.get_node("WorldEnvironment") as WorldEnvironment).environment
	var weather := main.get_node("WeatherController") as WeatherController
	var day_night := main.get_node("DayNightVisualController")
	var sky_material := environment.sky.sky_material as ShaderMaterial
	for canvas in main.find_children("*", "CanvasLayer", true, false):
		(canvas as CanvasLayer).visible = false
	quality.set_quality_for_benchmark(QualityManager.Quality.HIGH)
	boat.get_node("MotionRoot").set_process(false)
	boat.get_node("MotionRoot").set_physics_process(false)
	boat.get_node("MotionRoot/VisualRoot").set_process(false)
	boat.get_node("MotionRoot/VisualRoot").set_physics_process(false)
	boat.get_node("FollowCameraRig").set_process(false)
	boat.get_node("FollowCameraRig").set_physics_process(false)
	var wake := boat.get_node_or_null("MotionRoot/VisualRoot/WakeSystem")
	if wake != null:
		_disable_particles(wake)
	material.set_shader_parameter("freeze_time", true)
	material.set_shader_parameter("water_diagnostic_mode", 0)
	weather.transition_seconds = 0.0
	weather.set_weather_by_name("Clear")
	await _wait_frames(25)
	var camera := boat.get_node("FollowCameraRig/Camera3D") as Camera3D
	camera.make_current()
	await _save("01_clear_third_person_after", camera, material, environment, "clear_third_person_frozen")

	# Observe normal Gerstner motion for twenty seconds at an unchanged camera.
	material.set_shader_parameter("freeze_time", false)
	_observation_start_msec = Time.get_ticks_msec()
	for seconds in [5, 10, 15, 20]:
		await _wait_seconds(float(seconds) - float(Time.get_ticks_msec() - _observation_start_msec) / 1000.0)
		await _save("02_clear_third_person_live_t%02d" % seconds, camera, material, environment, "clear_third_person_live")
	material.set_shader_parameter("freeze_time", true)

	var wide_camera := Camera3D.new()
	wide_camera.name = "TemporaryHorizonFinalCamera"
	wide_camera.fov = 70.0
	wide_camera.far = 80000.0
	main.add_child(wide_camera)
	var wide_origin := boat.global_position + Vector3.UP * 300.0
	wide_camera.global_position = wide_origin
	wide_camera.look_at(wide_origin + Vector3(-15000.0, -270.0, 0.0), Vector3.UP)
	wide_camera.make_current()
	await _wait_frames(10)
	await _save("03_clear_wide_after", wide_camera, material, environment, "clear_wide_frozen")
	main.remove_child(wide_camera)
	wide_camera.queue_free()

	# Reuse the same follow camera for low-sun and moonlit checks.
	camera.make_current()
	manager.call("set_calendar_date", 2026, 10, 26)
	manager.call("set_day_cycle_time", 17, 0)
	await _wait_frames(25)
	await _save("04_sunset_after", camera, material, environment, "sunset_third_person")

	var moon_test := _find_visible_bright_moon_case()
	manager.call("set_calendar_date", int(moon_test["year"]), int(moon_test["month"]), int(moon_test["day"]))
	manager.call("set_day_cycle_time", int(moon_test["hour"]), 0)
	await _wait_frames(25)
	var moon_state: Dictionary = day_night.call("get_moon_state")
	await _save("05_moonlit_after", camera, material, environment, "moonlit_third_person")

	var output_path := ProjectSettings.globalize_path(OUTPUT_ROOT)
	DirAccess.make_dir_recursive_absolute(output_path)
	var report := {
		"engine": Engine.get_version_info(),
		"renderer": RenderingServer.get_video_adapter_name(),
		"processor": OS.get_processor_name(),
		"viewport_px": [root.get_viewport().size.x, root.get_viewport().size.y],
		"quality": "High",
		"weather": "Clear",
		"ocean_far_edge_m": ocean.far_edge,
		"camera_far_m": camera.far,
		"distance_fade_m": [material.get_shader_parameter("distance_fade_min"), material.get_shader_parameter("distance_fade_max")],
		"fog_depth_range_m": [environment.fog_depth_begin, environment.fog_depth_end],
		"sky_horizon_blend_altitude": 0.035,
		"moon_test": moon_test,
		"moon_state": moon_state,
		"continuous_water_observation_seconds": float(Time.get_ticks_msec() - _observation_start_msec) / 1000.0,
		"captures": _captures,
	}
	var file := FileAccess.open(output_path.path_join("capture_report.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t") + "\n")
		file.close()
	print(JSON.stringify(report, "\t"))
	manager.call("restore_snapshot", snapshot)
	manager.set("autosave_enabled", autosave)
	root.remove_child(main)
	main.queue_free()
	await process_frame
	quit()


func _find_visible_bright_moon_case() -> Dictionary:
	var best: Dictionary = {}
	var best_score := -INF
	for month in range(1, 13):
		for day in [5, 12, 19, 26]:
			if month == 2 and day == 26:
				continue
			for hour in range(18, 24):
				var state: Dictionary = MOON_POSITION_SCRIPT.calculate({"year": 2026, "month": month, "day": day}, hour * 3600.0, 55.7, 12.75)
				var elevation := float(state["elevation_degrees"])
				var illumination := float(state["illumination_fraction"])
				if elevation >= 12.0 and illumination >= 0.58:
					var score := elevation * illumination
					if score > best_score:
						best_score = score
						best = {"year": 2026, "month": month, "day": day, "hour": hour,
						"elevation_degrees": elevation, "illumination_fraction": illumination,
						"phase_name": state["phase_name"]}
	return best


func _save(name: String, camera: Camera3D, material: ShaderMaterial, environment: Environment, state: String) -> void:
	camera.make_current()
	await _wait_frames(6)
	await RenderingServer.frame_post_draw
	var image := root.get_viewport().get_texture().get_image()
	var output_path := ProjectSettings.globalize_path(OUTPUT_ROOT)
	DirAccess.make_dir_recursive_absolute(output_path)
	var path := output_path.path_join(name + ".png")
	var error := image.save_png(path)
	_captures.append({"name": name, "state": state, "camera_position": camera.global_position,
		"camera_rotation": camera.global_rotation, "distance_fade_m": [material.get_shader_parameter("distance_fade_min"), material.get_shader_parameter("distance_fade_max")],
		"fog_depth_end_m": environment.fog_depth_end, "wave_frozen": bool(material.get_shader_parameter("freeze_time")),
		"save_error": error, "path": path})
	print("Captured %s (%dx%d, error=%d)" % [name, image.get_width(), image.get_height(), error])


func _disable_particles(node: Node) -> void:
	if node is GPUParticles3D:
		(node as GPUParticles3D).emitting = false
	for child in node.get_children():
		_disable_particles(child)


func _wait_seconds(seconds: float) -> void:
	var end_msec := Time.get_ticks_msec() + roundi(maxf(seconds, 0.0) * 1000.0)
	while Time.get_ticks_msec() < end_msec:
		await create_timer(0.5).timeout


func _wait_frames(count: int) -> void:
	for _index in range(count):
		await process_frame
