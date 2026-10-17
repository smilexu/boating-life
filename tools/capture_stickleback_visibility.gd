extends SceneTree

const MAIN_SCENE := preload("res://scenes/main.tscn")
const OUTPUT_DIR := "res://docs/fish_resources/stickleback_visibility"
const MOTION_DIR := "res://docs/fish_resources/stickleback_visibility/motion_frames"
const STICKLEBACK_ID := "three_spined_stickleback"


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))
	# Keep visual QA independent of the player's saved world clock. The capture
	# process disables persistence, then uses WorldTimeManager's admin controls.
	var world_time := root.get_node_or_null("WorldTimeManager")
	if world_time == null:
		push_error("WorldTimeManager autoload was not found for the visual capture.")
		quit(1)
		return
	world_time.autosave_enabled = false
	if not world_time.set_calendar_date(2026, 7, 15) or not world_time.set_day_cycle_time(12, 0, 0.0):
		push_error("Could not set the controlled summer-noon capture time.")
		quit(1)
		return
	world_time.pause_time()
	print("[STICKLEBACK_CAPTURE] visual_time date=%s cycle=%s paused=%s autosave=%s" % [world_time.get_calendar_date(), world_time.get_cycle_time_dictionary(), world_time.state.paused, world_time.autosave_enabled])
	var main_root := MAIN_SCENE.instantiate()
	root.add_child(main_root)
	await process_frame
	await create_timer(1.0).timeout

	var hud := main_root.get_node("PlayerBoat/BoatHUD") as Node
	var boat := main_root.get_node("PlayerBoat/MotionRoot") as BoatController
	var camera_rig := main_root.get_node("PlayerBoat/FollowCameraRig") as Node3D
	var boat_camera := main_root.get_node("PlayerBoat/FollowCameraRig/Camera3D") as Camera3D
	var manager := main_root.get_node("FishResourceManager") as FishResourceManager
	var renderer := main_root.get_node("FishResourceManager/FishSchoolRenderer") as FishSchoolRenderer
	var profile := manager.get_species_profile(STICKLEBACK_ID)
	if profile == null:
		push_error("Stickleback profile is not loaded.")
		quit(1)
		return

	# Use the same F3 route players use. This only repositions the inspection boat;
	# the authority school anchor and its shared resource state remain untouched.
	hud.call("_on_fish_observation_pressed", STICKLEBACK_ID)
	await create_timer(2.0).timeout
	var selected_school_id := str(hud.get("_selected_fish_school_id"))
	var school := manager.get_school(selected_school_id)
	if school.is_empty():
		push_error("F3 did not select a real stickleback school.")
		quit(1)
		return

	var position_data: Array = school.get("world_position", [])
	var school_anchor := Vector3(float(position_data[0]), 0.0, float(position_data[2]))
	var selected_school_surface := (main_root.get_node("WaveSampler") as WaveSampler).sample_surface(school_anchor, (main_root.get_node("WaveSampler") as WaveSampler).wave_time_seconds)
	var surface_y := float(selected_school_surface.get("height", 0.0))
	var stats := renderer.get_school_visual_debug(selected_school_id)
	var visual_target_y := surface_y - float(stats.get("depth_from_surface_m", 0.9))
	var visual_target := Vector3(school_anchor.x, visual_target_y, school_anchor.z)
	print("[STICKLEBACK_CAPTURE] school=%s anchor=%s depth=%.2fm population=%d visual=%d mean_length=%.1fcm clearance=%.2fm boat_distance=%.1fm habitat=%s" % [
		selected_school_id,
		school_anchor,
		float(stats.get("bathymetry_depth_m", 0.0)),
		int(stats.get("school_population", 0)),
		int(stats.get("visible_fish", 0)),
		float(stats.get("average_visual_length_m", 0.0)) * 100.0,
		float(stats.get("seabed_clearance_m", 0.0)),
		Vector2(boat.global_position.x - school_anchor.x, boat.global_position.z - school_anchor.z).length(),
		str(stats.get("habitat_region", "unknown")),
	])

	# Restore the normal follow camera and let it settle after F3 has moved the boat.
	renderer.end_observation()
	camera_rig.set_process(true)
	await create_timer(1.0).timeout
	await _save_viewport("01_stickleback_from_boat.png")

	# The F3 observation camera follows actual visual instances at ecological depth.
	if not renderer.begin_observation(selected_school_id):
		push_error("F3 underwater observation camera did not activate.")
		quit(1)
		return
	await create_timer(1.0).timeout
	await _save_viewport("02_stickleback_underwater_observation.png")
	await create_timer(0.65).timeout
	await _save_viewport("03_stickleback_underwater_motion.png")

	# Capture the undisturbed school from above and from a close, shallow angle
	# before moving the test boat close enough to trigger the flee response.
	renderer.end_observation()
	camera_rig.set_process(false)
	boat_camera.global_position = Vector3(visual_target.x, surface_y + 4.0, visual_target.z + 0.5)
	boat_camera.look_at(visual_target, Vector3.FORWARD)
	boat_camera.fov = 42.0
	boat_camera.make_current()
	await create_timer(0.75).timeout
	await _save_viewport("04_stickleback_top_down.png")
	boat_camera.global_position = visual_target + Vector3(1.8, 2.4, 1.8)
	boat_camera.look_at(visual_target, Vector3.UP)
	boat_camera.fov = 55.0
	boat_camera.make_current()
	await create_timer(0.75).timeout
	await _save_viewport("05_stickleback_near_surface_oblique.png")
	if not renderer.begin_observation(selected_school_id):
		push_error("Could not restore the real school observer after the camera checks.")
		quit(1)
		return

	await _capture_motion_segment("normal", 30)
	var away_direction := Vector2(boat.global_position.x - school_anchor.x, boat.global_position.z - school_anchor.z).normalized()
	if away_direction.length_squared() < 0.001:
		away_direction = Vector2.RIGHT
	boat.global_position = Vector3(school_anchor.x + away_direction.x * 12.0, boat.global_position.y, school_anchor.z + away_direction.y * 12.0)
	boat.speed_mps = 0.0
	boat.is_autopilot = false
	await create_timer(0.7).timeout
	print("[STICKLEBACK_CAPTURE] flee_test=%s" % renderer.get_school_visual_debug(selected_school_id).get("behavior_counts", {}))
	await _capture_motion_segment("boat_approach_flee", 30)

	quit(0)


func _capture_motion_segment(segment_name: String, frame_count: int) -> void:
	var segment_dir := "%s/%s" % [MOTION_DIR, segment_name]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(segment_dir))
	for frame_index in range(frame_count):
		await create_timer(0.1).timeout
		await _save_to_directory(segment_dir, "frame_%04d.png" % frame_index)
	print("[STICKLEBACK_CAPTURE] captured %d %s motion frames at 10 fps" % [frame_count, segment_name])


func _save_viewport(file_name: String) -> void:
	await _save_to_directory(OUTPUT_DIR, file_name)


func _save_to_directory(directory: String, file_name: String) -> void:
	await process_frame
	var image := root.get_texture().get_image()
	var output_path := ProjectSettings.globalize_path("%s/%s" % [directory, file_name])
	var error := image.save_png(output_path)
	if error != OK:
		push_error("Failed to save %s: %s" % [output_path, error])
	else:
		print("[STICKLEBACK_CAPTURE] saved %s (%dx%d)" % [output_path, image.get_width(), image.get_height()])
