extends SceneTree
## Captures the Peberholm approach from two low, boat-height Forward+ views.
## Run with: godot --path . --script res://tools/verify_peberholm_approach_visual.gd

const MAIN_SCENE := preload("res://scenes/main.tscn")
const OUTPUT_DIR := "res://.godot/peberholm_approach_preview"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("This visual check requires the Forward+ renderer; do not run it headless.")
		quit(2)
		return
	var time_manager := root.get_node_or_null("WorldTimeManager")
	var time_snapshot: Dictionary = time_manager.call("create_snapshot") if time_manager != null else {}
	var autosave := bool(time_manager.get("autosave_enabled")) if time_manager != null else false
	var main := MAIN_SCENE.instantiate() as Node3D
	root.add_child(main)
	await _wait_frames(45)
	if time_manager != null:
		time_manager.set("autosave_enabled", false)
		time_manager.call("pause_time")
		time_manager.call("set_calendar_date", 2026, 7, 15)
		time_manager.call("set_day_cycle_time", 12, 0)
	for canvas in main.find_children("*", "CanvasLayer", true, false):
		(canvas as CanvasLayer).visible = false
	var motion := main.get_node("PlayerBoat/MotionRoot") as Node3D
	var camera_rig := main.get_node("PlayerBoat/FollowCameraRig") as Node3D
	var camera := main.get_node("PlayerBoat/FollowCameraRig/Camera3D") as Camera3D
	var bridge := main.get_node("OresundBridge")
	if motion == null or camera_rig == null or camera == null or bridge == null:
		push_error("Main scene is missing the player boat, camera, or OresundBridge.")
		main.queue_free()
		await process_frame
		quit(1)
		return
	motion.set_process(false)
	motion.set_physics_process(false)
	camera_rig.set_process(false)
	camera_rig.set_physics_process(false)
	var output_path := ProjectSettings.globalize_path(OUTPUT_DIR)
	DirAccess.make_dir_recursive_absolute(output_path)
	var preview_camera := Camera3D.new()
	preview_camera.name = "PeberholmApproachVisualCheckCamera"
	preview_camera.far = 10000.0
	preview_camera.fov = 65.0
	main.add_child(preview_camera)
	var bathymetry := main.get_node("BathymetryManager")
	var inward: Vector3 = bridge.call("_peberholm_approach_tangent")
	var right := Vector3.UP.cross(inward).normalized()
	var first_route_point: Vector3 = bridge.call("_peberholm_approach_position", 250.0)
	var first_observation: Vector3 = _find_nearest_water_position(bathymetry, first_route_point, right, 250, 200.0)
	var first_target: Vector3 = bridge.call("_peberholm_approach_position", 950.0)
	first_target.y = float(bridge.call("_peberholm_approach_underside_height", 950.0)) + 9.2
	_set_boat_view(motion, bridge, preview_camera, first_observation, (first_target - first_observation).normalized(), first_target)
	await _wait_frames(60)
	await _save_capture("01_seaward_boat_view", output_path)
	var mid_route: Vector3 = bridge.call("_peberholm_approach_position", 1780.0)
	var second_observation: Vector3 = _find_nearest_water_position(bathymetry, mid_route, right, 1780, 200.0)
	var portal: Vector3 = bridge.call("_peberholm_approach_position", 1800.0)
	var toward_entry := (portal + Vector3.UP * 6.0 - second_observation).normalized()
	toward_entry.y = 0.0
	_set_boat_view(motion, bridge, preview_camera, second_observation, toward_entry.normalized(), portal + Vector3.UP * 6.0)
	await _wait_frames(60)
	await _save_capture("02_island_side_boat_view", output_path)
	var report := {
		"renderer": RenderingServer.get_video_adapter_name(),
		"display_server": DisplayServer.get_name(),
		"viewport_px": [root.get_viewport().size.x, root.get_viewport().size.y],
		"approach_length_m": bridge.call("get_debug_snapshot").get("peberholm_approach_length_m", 0.0),
		"ramp_length_m": bridge.call("get_debug_snapshot").get("peberholm_approach_ramp_length_m", 0.0),
		"captures": [
			output_path.path_join("01_seaward_boat_view.png"),
			output_path.path_join("02_island_side_boat_view.png"),
		],
	}
	var report_file := FileAccess.open(output_path.path_join("visual_report.json"), FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "\t") + "\n")
		report_file.close()
	print(JSON.stringify(report, "\t"))
	if time_manager != null:
		time_manager.call("restore_snapshot", time_snapshot)
		time_manager.set("autosave_enabled", autosave)
	main.queue_free()
	await process_frame
	quit()


func _set_boat_view(motion: Node3D, bridge: Node, camera: Camera3D, position: Vector3, forward: Vector3, target: Vector3) -> void:
	position.y = 0.0
	motion.global_position = position
	motion.global_rotation.y = atan2(-forward.x, -forward.z)
	if motion.get("speed_mps") != null:
		motion.set("speed_mps", 0.0)
	if motion.get("is_motion_paused") != null:
		motion.set("is_motion_paused", true)
	camera.global_position = position - forward.normalized() * 16.0 + Vector3.UP * 6.0
	camera.look_at(target, Vector3.UP)
	camera.make_current()
	bridge.call("_update_lods")


func _find_nearest_water_position(bathymetry: Node, route_point: Vector3, right: Vector3, station_m: float, minimum_offset_m: float) -> Vector3:
	var first_step := maxi(ceili(minimum_offset_m / 25.0), 1)
	for step in range(first_step, 61):
		var offset := float(step) * 25.0
		for side_sign in [-1.0, 1.0]:
			var candidate := route_point + right * float(side_sign) * offset
			if not bool(bathymetry.call("is_land_at_east_north", candidate.x, -candidate.z)):
				print("Peberholm side observation: station≈%d m offset=%.1f m land=false position=%s" % [station_m, offset * float(side_sign), candidate])
				return candidate
	push_warning("No water pixel was found within 1.5 km of the Peberholm approach near station %d m; using the nominal side view." % station_m)
	return route_point + right * 1500.0


func _save_capture(name: String, output_path: String) -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_viewport().get_texture().get_image()
	var path := output_path.path_join(name + ".png")
	var error := image.save_png(path)
	if error != OK:
		push_error("Could not save %s (error %d)." % [path, error])
	print("CAPTURE %s %dx%d error=%d" % [path, image.get_width(), image.get_height(), error])


func _wait_frames(count: int) -> void:
	for _frame in range(count):
		await process_frame
