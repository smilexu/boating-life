extends SceneTree
## Forward+ review for the Øresund Bridge shared PBR materials.
## Run: godot --path . --script res://tools/capture_oresund_bridge_materials.gd

const MAIN_SCENE: PackedScene = preload("res://scenes/main.tscn")
const OUTPUT_DIR := "res://.godot/bridge_material_review"
const CAPTURE_SIZE := Vector2i(1440, 900)

var _metrics: Array[Dictionary] = []
var _conditions: Array[Dictionary] = []


func _initialize() -> void:
	_capture.call_deferred()


func _capture() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Bridge material review needs a graphical Forward+ renderer.")
		quit(2)
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DisplayServer.window_set_size(CAPTURE_SIZE)
	Engine.max_fps = 0
	var time_manager := root.get_node_or_null("WorldTimeManager")
	var time_snapshot: Dictionary = time_manager.call("create_snapshot") if time_manager != null else {}
	var autosave_enabled := bool(time_manager.get("autosave_enabled")) if time_manager != null else false
	if time_manager != null:
		time_manager.set("autosave_enabled", false)
		time_manager.call("pause_time")
		time_manager.call("set_calendar_date", 2026, 7, 15)
		time_manager.call("set_day_cycle_time", 12, 0)

	var main := MAIN_SCENE.instantiate() as Node3D
	root.add_child(main)
	await _wait_frames(50)
	for canvas in main.find_children("*", "CanvasLayer", true, false):
		(canvas as CanvasLayer).visible = false
	var motion := main.get_node("PlayerBoat/MotionRoot") as Node3D
	motion.set_process(false)
	motion.set_physics_process(false)
	if motion.get("is_motion_paused") != null:
		motion.set("is_motion_paused", true)
	var camera_rig := main.get_node("PlayerBoat/FollowCameraRig") as Node3D
	camera_rig.set_process(false)
	camera_rig.set_physics_process(false)
	var boat_camera := main.get_node("PlayerBoat/FollowCameraRig/Camera3D") as Camera3D
	boat_camera.current = false

	var bridge := main.get_node("OresundBridge")
	var pylon_records: Array = bridge.get("_pylon_runtime")
	if pylon_records.is_empty():
		push_error("The bridge did not create any runtime pylons.")
		main.queue_free()
		await process_frame
		quit(1)
		return
	var main_pylon: Dictionary = pylon_records[0]
	var station := float(main_pylon.get("station_m", 3500.0))
	var pylon_position: Vector3 = main_pylon.get("position", Vector3.ZERO)
	var tangent: Vector3 = main_pylon.get("tangent", Vector3.FORWARD)
	var right := Vector3.UP.cross(tangent).normalized()
	motion.global_position = pylon_position + right * 300.0
	bridge.call("_update_lods")

	var camera := Camera3D.new()
	camera.name = "BridgeMaterialReviewCamera"
	camera.far = 20000.0
	camera.fov = 58.0
	main.add_child(camera)
	var target := pylon_position + Vector3.UP * 90.0 + tangent * 75.0
	var camera_position := pylon_position + right * 320.0 + tangent * 100.0 + Vector3.UP * 85.0
	_set_camera(camera, camera_position, target)
	var output_path := ProjectSettings.globalize_path(OUTPUT_DIR)
	DirAccess.make_dir_recursive_absolute(output_path)

	var weather := main.get_node("WeatherController")
	weather.set("transition_seconds", 0.1)
	var water := main.get_node("BathymetryManager").get("water_material") as ShaderMaterial
	if water != null:
		water.set_shader_parameter("freeze_time", true)
	weather.call("set_weather_by_index", 0)
	await _wait_frames(120)
	await _save_capture("01_clear_noon_bridge_tower", output_path)
	_record_condition("clear noon", main, weather)

	weather.call("set_weather_by_index", 2)
	await _wait_frames(180)
	await _save_capture("02_overcast_bridge_tower", output_path)
	_record_condition("overcast noon", main, weather)

	weather.call("set_weather_by_index", 1)
	if time_manager != null:
		time_manager.call("set_day_cycle_time", 20, 30)
	await _wait_frames(180)
	await _save_capture("03_golden_hour_bridge_tower", output_path)
	_record_condition("partly cloudy golden hour", main, weather)

	# Back off for an at-distance sea view, with the same bridge structure visible.
	motion.global_position = pylon_position + right * 4500.0
	bridge.call("_update_lods")
	_set_camera(camera, pylon_position + right * 2500.0 + tangent * 500.0 + Vector3.UP * 690.0, pylon_position + Vector3.UP * 95.0)
	if time_manager != null:
		time_manager.call("set_day_cycle_time", 12, 0)
	weather.call("set_weather_by_index", 0)
	await _wait_frames(180)
	await _save_capture("04_clear_noon_distant_view", output_path)
	_record_condition("clear noon distant LOD", main, weather)
	var deck_station := 1600.0
	var deck_center: Vector3 = bridge.call("_position_at_station", deck_station)
	var deck_tangent: Vector3 = bridge.call("_tangent_at_station", deck_station)
	var deck_right := Vector3.UP.cross(deck_tangent).normalized()
	motion.global_position = deck_center + deck_right * 130.0
	bridge.call("_update_lods")
	_set_camera(camera, deck_center + deck_right * 100.0 + deck_tangent * 45.0 + Vector3.UP * 46.0, deck_center + deck_tangent * 110.0 + Vector3.UP * 38.0)
	await _wait_frames(90)
	await _save_capture("05_near_deck_pbr_detail", output_path)
	_record_condition("clear noon near deck detail", main, weather)

	# Compare the world-noise shader against simple PBR materials on the same
	# already-built bridge instances; this isolates material shader cost.
	motion.global_position = pylon_position + right * 300.0
	bridge.call("_update_lods")
	_set_camera(camera, camera_position, target)
	if time_manager != null:
		time_manager.call("set_day_cycle_time", 12, 0)
	weather.call("set_weather_by_index", 0)
	await _wait_frames(180)
	var material_controls := _create_flat_pbr_controls(bridge)
	for repetition in range(3):
		_apply_material_controls(material_controls, false)
		await _wait_frames(45)
		_metrics.append(await _benchmark("procedural_pbr_shader_%d" % (repetition + 1)))
		_apply_material_controls(material_controls, true)
		await _wait_frames(45)
		_metrics.append(await _benchmark("flat_pbr_material_control_%d" % (repetition + 1)))
	var report := {
		"engine": Engine.get_version_info(),
		"renderer": RenderingServer.get_video_adapter_name(),
		"display_server": DisplayServer.get_name(),
		"viewport_px": [root.get_viewport().size.x, root.get_viewport().size.y],
		"pylon_station_m": station,
		"bridge_node_count": bridge.get_child_count(),
		"conditions": _conditions,
		"benchmark_note": "Alternates procedural vertex-noise PBR and flat StandardMaterial3D on the same bridge nodes and camera. Draw calls/primitives are the stable indicators; frame-rate samples vary with the rest of the rendering scene and are diagnostic only, not a whole-game before/after benchmark.",
		"benchmarks": _metrics,
		"captures": [
			output_path.path_join("01_clear_noon_bridge_tower.png"),
			output_path.path_join("02_overcast_bridge_tower.png"),
			output_path.path_join("03_golden_hour_bridge_tower.png"),
			output_path.path_join("04_clear_noon_distant_view.png"),
			output_path.path_join("05_near_deck_pbr_detail.png"),
		],
	}
	var report_file := FileAccess.open(output_path.path_join("report.json"), FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "\t") + "\n")
		report_file.close()
	print(JSON.stringify(report, "\t"))

	material_controls.clear()
	main.queue_free()
	await process_frame
	if time_manager != null:
		time_manager.call("restore_snapshot", time_snapshot)
		time_manager.set("autosave_enabled", autosave_enabled)
	quit()


func _set_camera(camera: Camera3D, position: Vector3, target: Vector3) -> void:
	camera.global_position = position
	camera.look_at(target, Vector3.UP)
	camera.make_current()


func _create_flat_pbr_controls(bridge: Node) -> Array[Dictionary]:
	var controls: Array[Dictionary] = []
	var by_source: Dictionary = {}
	for instance in bridge.find_children("*", "GeometryInstance3D", true, false):
		var geometry := instance as GeometryInstance3D
		var shader_material := geometry.material_override as ShaderMaterial
		if shader_material == null:
			continue
		if not by_source.has(shader_material.get_instance_id()):
			var material := StandardMaterial3D.new()
			material.albedo_color = shader_material.get_shader_parameter("base_color")
			material.metallic = float(shader_material.get_shader_parameter("metallic"))
			material.roughness = float(shader_material.get_shader_parameter("base_roughness"))
			material.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
			by_source[shader_material.get_instance_id()] = material
		controls.append({
			"geometry": geometry,
			"shader_material": shader_material,
			"flat_material": by_source[shader_material.get_instance_id()],
		})
	return controls


func _apply_material_controls(controls: Array[Dictionary], use_flat_materials: bool) -> void:
	for control in controls:
		var geometry := control["geometry"] as GeometryInstance3D
		geometry.material_override = control["flat_material"] if use_flat_materials else control["shader_material"]


func _benchmark(name: String) -> Dictionary:
	var frames := 150
	var start_usec := Time.get_ticks_usec()
	for _frame in range(frames):
		await process_frame
	var elapsed_seconds := float(Time.get_ticks_usec() - start_usec) / 1000000.0
	return {
		"name": name,
		"frames": frames,
		"elapsed_seconds": elapsed_seconds,
		"average_fps": float(frames) / maxf(elapsed_seconds, 0.001),
		"draw_calls_last_frame": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"rendered_primitives_last_frame": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
	}


func _record_condition(name: String, main: Node, weather: Node) -> void:
	var day_night := main.get_node("DayNightVisualController")
	var solar: Dictionary = day_night.call("get_solar_state")
	_conditions.append({
		"name": name,
		"weather": str(weather.get("current_weather_name")),
		"sun_elevation_degrees": float(solar.get("elevation_degrees", 0.0)),
		"sun_azimuth_degrees": float(solar.get("azimuth_degrees", 0.0)),
	})


func _save_capture(name: String, output_path: String) -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_viewport().get_texture().get_image()
	var file_path := output_path.path_join(name + ".png")
	var error := image.save_png(file_path)
	if error != OK:
		push_error("Could not save %s (error %d)." % [file_path, error])
	print("CAPTURE %s %dx%d error=%d" % [file_path, image.get_width(), image.get_height(), error])


func _wait_frames(count: int) -> void:
	for _frame in range(count):
		await process_frame
