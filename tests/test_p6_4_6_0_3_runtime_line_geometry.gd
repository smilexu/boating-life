extends SceneTree

const FPS_CASES := [30, 60]
const RIG_CASES := [&"sabiki_rig", &"single_jig"]
const MAX_CAST_SECONDS := 8.0
const MAX_RETRIEVE_SECONDS := 20.0
const MAX_CAST_LINE_LENGTH_ERROR_M := 0.03
const MAX_RETRIEVE_LINE_LENGTH_ERROR_M := 0.05
const SINGLE_JIG_PROFILE: BoatFishingRigProfile = preload("res://resources/boat_fishing/single_jig.tres")
const SABIKI_RIG_PROFILE: BoatFishingRigProfile = preload("res://resources/boat_fishing/sabiki_rig.tres")

var _output: FileAccess
var _failures := 0
var _phase_started_usec := 0
var _capture_label := "after"
var _sample_output_path := ""
var _last_sample_usec_by_case: Dictionary = {}
var _last_axis_by_case: Dictionary = {}
var _last_bait_velocity_by_case: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("capture="):
			_capture_label = argument.trim_prefix("capture=")
	_sample_output_path = "/tmp/p6_4_6_0_7_runtime_%s.ndjson" % _capture_label
	if _is_gpu_runtime():
		# Keep the full production scene and materials, but use a moderate test
		# viewport so the 30/60 FPS timing cases are not dominated by Retina pixels.
		DisplayServer.window_set_size(Vector2i(960, 540))
	_output = FileAccess.open(_sample_output_path, FileAccess.WRITE)
	if _output == null:
		printerr("Unable to open runtime capture output: %s" % _sample_output_path)
		quit(1)
		return

	var main_scene := load("res://scenes/main.tscn") as PackedScene
	_check(main_scene != null, "Main scene is available for runtime geometry capture")
	if main_scene == null:
		quit(1)
		return
	var main := main_scene.instantiate()
	root.add_child(main)
	for _frame in range(30):
		await physics_frame

	var onboard := main.get_node_or_null("PlayerBoat/MotionRoot/VisualRoot/OnboardActivityController") as OnboardActivityController
	var boat_controller := main.get_node_or_null("PlayerBoat/MotionRoot") as BoatController
	var casting := main.get_node_or_null("PlayerBoat/BoatFishingCastingSystem") as BoatFishingCastingSystem
	var activities_button := main.find_child("ActivitiesButton", true, false) as Button
	var boat_fishing_button := main.find_child("OpenBoatFishingActivity", true, false) as Button
	var camera := main.get_node_or_null("PlayerBoat/FollowCameraRig") as BoatFollowCamera
	var line_instance := casting.find_child("BoatFishingLine", true, false) as MeshInstance3D if casting != null else null
	_check(onboard != null and boat_controller != null and casting != null and camera != null and line_instance != null,
		"Main scene exposes the real casting state machine and its generated line mesh")
	if onboard == null or boat_controller == null or casting == null or activities_button == null or boat_fishing_button == null or camera == null or line_instance == null:
		quit(1)
		return

	activities_button.pressed.emit()
	boat_fishing_button.pressed.emit()
	await process_frame
	_check(casting.is_activity_active() and onboard.is_first_person_active(), "Boat Fishing activity starts through the normal HUD path")
	_check(
		_count_nodes_named(casting, "BoatFishingLine") == 1
		and _count_nodes_named(casting, "SabikiBackboneLine") == 1
		and _count_nodes_named(casting, "SabikiMainline") == 0
		and _count_nodes_named(casting, "SabikiBranchLine") == 5,
		"Rendering uses one shared outer mainline, one terminal backbone, five branches, and no legacy duplicate"
	)
	var constrained_route := PackedVector3Array([Vector3.ZERO, Vector3(1.0, -1.0, 0.0)])
	var constrained_path := BoatFishingCastingSystem.calculate_common_main_line_visual_path(PackedVector3Array(), constrained_route, constrained_route, PackedVector2Array(), 0.0, {"taut": false, "slack_ratio": 0.8, "airborne": true, "airborne_reel_constraint": true})
	var constrained_error := 0.0
	for point in constrained_path:
		constrained_error = maxf(constrained_error, absf(point.x + point.y))
	_check(constrained_error <= 0.00001, "Airborne reeled line without spare length has no decorative S-shaped sag")
	_check(_test_common_main_line_ab(casting), "Single Jig and Sabiki produce identical shared-main-line geometry for identical inputs")
	_check(_test_sabiki_motion_axis(casting), "Sabiki terminal axis follows shared tackle motion and returns to gravity at rest")
	_check(_test_sabiki_airborne_pose(casting), "Sabiki airborne pose aligns smoothly and eases across water entry and recovery")
	_check(_test_shared_rod_bend_direction(casting), "Single Jig and Sabiki share the same loaded rod-tip pull direction")

	boat_controller.is_autopilot = false
	boat_controller.speed_mps = 0.0
	var player := onboard.find_child("OnboardActivityPlayer", true, false) as CharacterBody3D
	var head_pivot := onboard.find_child("HeadPivot", true, false) as Node3D
	if player == null or head_pivot == null:
		_check(false, "First-person player fixture exists")
		quit(1)
		return

	var player_position := Vector3(0.53, onboard.profile.deck_height_m, 1.28)
	onboard.set("_player_local_position", player_position)
	player.position = player_position
	onboard.set("_player_local_yaw", -PI * 0.5)
	onboard.set("_look_pitch", -0.34)
	head_pivot.rotation.x = -0.34
	onboard.call("_set_player_transform_from_hull")

	var runtime_fps_cases := [30] if _is_gpu_runtime() else FPS_CASES
	for fps in runtime_fps_cases:
		Engine.max_fps = fps
		for rig_id in RIG_CASES:
			await _run_rig_case(main, onboard, boat_controller, casting, camera, line_instance, rig_id, fps)

	Engine.max_fps = 0
	_output.flush()
	_output.close()
	print("[P6.4.6.0.7][CAPTURE] %s" % _sample_output_path)
	print("[P6.4.6.0.7] failures=%d" % _failures)
	main.queue_free()
	await process_frame
	quit(1 if _failures > 0 else 0)


func _test_common_main_line_ab(casting: BoatFishingCastingSystem) -> bool:
	var original_rig: BoatFishingRigProfile = casting.get("_current_rig")
	var original_bait: Vector3 = casting.get("_bait_world")
	var original_lure_basis: Basis = casting.get("_lure_visual_basis_world")
	var original_boat_velocity: Vector3 = casting.get("_boat_velocity_estimate_world")
	casting.set("_boat_velocity_estimate_world", Vector3.ZERO)
	casting.set("_lure_visual_basis_world", Basis.IDENTITY)
	var desired_connection := Vector3(8.0, 3.5, -6.0)
	var rod_tip := Vector3(2.0, 4.0, -1.0)
	var prefix := PackedVector3Array([
		Vector3(-0.4, 1.2, 0.8),
		Vector3(0.2, 1.8, 0.4),
		Vector3(1.1, 2.7, 0.0),
		rod_tip,
	])
	var route_world := PackedVector3Array([rod_tip, desired_connection])
	var route_local := PackedVector3Array([rod_tip, desired_connection])
	var visual_states: Array[Dictionary] = [
		{"taut": true, "slack_ratio": 0.0, "airborne": false},
		{"taut": false, "slack_ratio": 0.72, "airborne": false},
	]
	var results: Array[PackedVector3Array] = []
	for profile in [SINGLE_JIG_PROFILE, SABIKI_RIG_PROFILE]:
		casting.set("_current_rig", profile)
		var connector_offset: Vector3 = casting.call("_get_tackle_line_connection_offset_world")
		casting.set("_bait_world", desired_connection - connector_offset)
		var resolved_connection: Vector3 = casting.call("_get_tackle_line_connection_world")
		if resolved_connection.distance_to(desired_connection) > 0.00001:
			casting.set("_current_rig", original_rig)
			casting.set("_bait_world", original_bait)
			casting.set("_lure_visual_basis_world", original_lure_basis)
			casting.set("_boat_velocity_estimate_world", original_boat_velocity)
			return false
		for visual_state in visual_states:
			results.append(BoatFishingCastingSystem.calculate_common_main_line_visual_path(
				prefix, route_world, route_local, PackedVector2Array(), 0.0, visual_state
			))
	casting.set("_current_rig", original_rig)
	casting.set("_bait_world", original_bait)
	casting.set("_lure_visual_basis_world", original_lure_basis)
	casting.set("_boat_velocity_estimate_world", original_boat_velocity)
	casting.call("_update_rig_visual_position")
	return (
		results.size() == 4
		and _paths_match(results[0], results[2])
		and _paths_match(results[1], results[3])
	)


func _paths_match(first: PackedVector3Array, second: PackedVector3Array) -> bool:
	if first.size() != second.size():
		return false
	for index in range(first.size()):
		if first[index].distance_to(second[index]) > 0.000001:
			return false
	return true


func _test_sabiki_motion_axis(casting: BoatFishingCastingSystem) -> bool:
	var original_velocity: Vector3 = casting.get("_bait_velocity_world")
	var original_boat_velocity: Vector3 = casting.get("_boat_velocity_estimate_world")
	var original_bait_world: Vector3 = casting.get("_bait_world")
	var original_rod_tension: float = casting.get("_rod_tension")
	var original_rig: BoatFishingRigProfile = casting.get("_current_rig")
	var original_state: int = casting.get("_state")
	var original_fight_active: bool = casting.get("_fight_session_active")
	var original_fight_snapshot: Dictionary = casting.get("_fight_snapshot").duplicate(true)
	var original_manual_reeling: bool = casting.get("_manual_reeling")
	casting.set("_current_rig", SABIKI_RIG_PROFILE)
	casting.set("_state", BoatFishingCastingSystem.CastState.CASTING)
	casting.call("_update_rig_visual_selection")
	casting.set("_boat_velocity_estimate_world", Vector3.ZERO)
	casting.set("_fight_session_active", false)
	casting.set("_rod_tension", 0.0)
	casting.set("_bait_velocity_world", Vector3(0.0, 0.0, -8.0))
	var moving_axis: Vector3 = casting.call("_get_sabiki_up_direction_world")
	casting.set("_bait_velocity_world", Vector3.ZERO)
	var resting_axis: Vector3 = casting.call("_get_sabiki_up_direction_world")
	casting.set("_state", BoatFishingCastingSystem.CastState.WAITING)
	casting.set("_bait_world", casting.call("_get_rod_tip_world") - Vector3(4.0, 0.0, 0.0))
	var loaded_bait_world: Vector3 = casting.get("_bait_world")
	casting.set("_manual_reeling", false)
	casting.set("_rod_tension", 0.0)
	casting.call("_update_rig_visual_selection")
	var unloaded_axis: Vector3 = casting.call("_get_sabiki_up_direction_world")
	casting.set("_manual_reeling", true)
	casting.set("_rod_tension", 0.7)
	var loaded_axis: Vector3 = casting.call("_get_sabiki_up_direction_world")
	var neutral_line_eye: Vector3 = loaded_bait_world + casting.call("_get_sabiki_natural_up_direction_world") * SABIKI_RIG_PROFILE.get_line_attachment_height_m()
	var rod_direction: Vector3 = (casting.call("_get_rod_tip_world") - neutral_line_eye).normalized()
	var loaded_hooks: Array[Vector3] = casting.call("get_rig_hook_positions", casting.get("_bait_world"), loaded_axis)
	var loaded_connection: Vector3 = casting.call("_get_tackle_line_connection_world")
	var hook_layout_matches := loaded_hooks.size() == SABIKI_RIG_PROFILE.hook_count
	for hook_index in range(loaded_hooks.size()):
		var height_from_sinker := SABIKI_RIG_PROFILE.bottom_leader_length_m + float(SABIKI_RIG_PROFILE.hook_count - hook_index - 1) * SABIKI_RIG_PROFILE.hook_spacing_m
		hook_layout_matches = hook_layout_matches and loaded_hooks[hook_index].distance_to(loaded_bait_world + loaded_axis * height_from_sinker) <= 0.001
	casting.set("_bait_velocity_world", original_velocity)
	casting.set("_boat_velocity_estimate_world", original_boat_velocity)
	casting.set("_bait_world", original_bait_world)
	casting.set("_rod_tension", original_rod_tension)
	casting.set("_current_rig", original_rig)
	casting.set("_state", original_state)
	casting.set("_fight_session_active", original_fight_active)
	casting.set("_fight_snapshot", original_fight_snapshot)
	casting.set("_manual_reeling", original_manual_reeling)
	casting.call("_update_rig_visual_selection")
	var opposing_motion_alignment := Vector2(moving_axis.x, moving_axis.z).normalized().dot(Vector2(0.0, 1.0))
	return (
		moving_axis.is_finite()
		and resting_axis.is_finite()
		and moving_axis.y > 0.0
		and Vector2(moving_axis.x, moving_axis.z).length() > 0.15
		and opposing_motion_alignment > 0.15
		and resting_axis.distance_to(Vector3.UP) <= 0.001
		and loaded_axis.is_finite()
		and loaded_axis.dot(rod_direction) > unloaded_axis.dot(rod_direction) + 0.04
		and loaded_hooks.size() == SABIKI_RIG_PROFILE.hook_count
		and loaded_connection.distance_to(loaded_bait_world + loaded_axis * SABIKI_RIG_PROFILE.get_line_attachment_height_m()) <= 0.001
		and hook_layout_matches
	)


func _test_sabiki_airborne_pose(casting: BoatFishingCastingSystem) -> bool:
	var original_state: int = casting.get("_state")
	var original_rig: BoatFishingRigProfile = casting.get("_current_rig")
	var original_bait: Vector3 = casting.get("_bait_world")
	var original_velocity: Vector3 = casting.get("_bait_velocity_world")
	var original_paid_line: float = casting.get("_line_paid_out_length_m")
	var original_flight_started: bool = casting.get("_bait_flight_started")
	var original_has_landed: bool = casting.get("_bait_has_landed")
	var original_flight_elapsed: float = casting.get("_bait_flight_elapsed")
	var original_flight_duration: float = casting.get("_bait_flight_duration")
	var original_manual_reeling: bool = casting.get("_manual_reeling")
	var original_airborne_retrieval: bool = casting.get("_bait_airborne_retrieval")
	var original_fight_active: bool = casting.get("_fight_session_active")
	var original_state_elapsed: float = casting.get("_state_elapsed")
	var rod_tip: Vector3 = casting.call("_get_rod_tip_world")
	var attachment_height := SABIKI_RIG_PROFILE.get_line_attachment_height_m()
	var outward := Vector3(0.24, 0.32, -0.91).normalized()
	casting.set("_current_rig", SABIKI_RIG_PROFILE)
	casting.set("_state", BoatFishingCastingSystem.CastState.CASTING)
	casting.set("_bait_flight_started", true)
	casting.set("_bait_has_landed", false)
	casting.set("_bait_flight_elapsed", 0.09)
	casting.set("_bait_flight_duration", 0.8)
	casting.set("_manual_reeling", false)
	casting.set("_bait_airborne_retrieval", false)
	casting.set("_fight_session_active", false)
	casting.set("_bait_velocity_world", outward * 7.0)
	casting.set("_line_paid_out_length_m", 0.0)
	casting.set("_bait_world", rod_tip + outward * (attachment_height + 3.0))
	var cast_natural_up: Vector3 = casting.call("_get_sabiki_natural_up_direction_world")
	var cast_pose: Dictionary = casting.call("_get_sabiki_airborne_pose", cast_natural_up)
	var cast_axis: Vector3 = casting.call("_get_sabiki_up_direction_world")
	var cast_angle := rad_to_deg(acos(clampf((-cast_axis).dot(outward), -1.0, 1.0)))
	var cast_connection: Vector3 = casting.call("_get_tackle_line_connection_world")
	casting.set("_line_paid_out_length_m", attachment_height + 3.0)
	var cast_connection_with_long_paid_line: Vector3 = casting.call("_get_tackle_line_connection_world")
	var airborne_connection_independent_of_paid_line := cast_connection.distance_to(cast_connection_with_long_paid_line) <= 0.0001
	casting.set("_line_paid_out_length_m", 0.0)
	var expected_cast_span := lerpf(
		attachment_height,
		float(cast_pose.get("attachment_span_m", attachment_height)),
		float(cast_pose.get("alignment_weight", 0.0))
	)
	var cast_span_error := cast_connection.distance_to(casting.get("_bait_world")) - expected_cast_span
	var cast_hooks: Array[Vector3] = casting.call("get_rig_hook_positions", casting.get("_bait_world"), cast_axis)
	var cast_curve: PackedVector3Array = casting.call("_get_sabiki_airborne_backbone_curve", casting.get("_bait_world"))
	var cast_curve_points: Array[Vector3] = []
	cast_curve_points.assign(cast_curve)
	var cast_curve_length := 0.0
	for curve_index in range(cast_curve.size() - 1):
		cast_curve_length += cast_curve[curve_index].distance_to(cast_curve[curve_index + 1])
	var cast_hook_stations_valid := cast_hooks.size() == SABIKI_RIG_PROFILE.hook_count
	for hook_index in range(cast_hooks.size()):
		cast_hook_stations_valid = cast_hook_stations_valid and _nearest_point_on_polyline_distance(cast_hooks[hook_index], cast_curve_points) <= 0.001
	var cast_valid := (
		float(cast_pose.get("alignment_weight", 0.0)) >= 0.8
		and cast_angle <= 20.0
		and airborne_connection_independent_of_paid_line
		and absf(cast_span_error) <= 0.001
		and cast_hook_stations_valid
		and absf(cast_curve_length - attachment_height) <= 0.05
		and cast_curve[0].distance_to(cast_connection) <= 0.001
		and cast_curve[-1].distance_to(casting.get("_bait_world")) <= 0.001
	)

	var sample: Dictionary = casting.call("_sample_water", casting.get("_bait_world"))
	var water_y := float(sample.get("height", casting.get("_bait_world").y))
	var vertical_extent := attachment_height * maxf(cast_natural_up.y, 0.0)
	var partial_bait: Vector3 = casting.get("_bait_world")
	partial_bait.y = water_y - vertical_extent * 0.5
	casting.set("_bait_world", partial_bait)
	casting.set("_bait_has_landed", true)
	var partial_pose: Dictionary = casting.call("_get_sabiki_airborne_pose", cast_natural_up)
	var partial_weight := float(partial_pose.get("alignment_weight", 0.0))
	var partial_valid := partial_weight > 0.2 and partial_weight < 0.8

	var fully_airborne_bait: Vector3 = partial_bait
	fully_airborne_bait.y = water_y + 0.08
	casting.set("_bait_world", fully_airborne_bait)
	casting.set("_line_paid_out_length_m", 1.5)
	casting.set("_state", BoatFishingCastingSystem.CastState.WAITING)
	casting.set("_manual_reeling", true)
	casting.set("_bait_airborne_retrieval", true)
	var retrieval_natural_up: Vector3 = casting.call("_get_sabiki_natural_up_direction_world")
	var retrieval_pose: Dictionary = casting.call("_get_sabiki_airborne_pose", retrieval_natural_up)
	var retrieval_axis: Vector3 = casting.call("_get_sabiki_up_direction_world")
	var retrieval_outward: Vector3 = retrieval_pose.get("outward_direction", Vector3.ZERO)
	var retrieval_angle := rad_to_deg(acos(clampf((-retrieval_axis).dot(retrieval_outward), -1.0, 1.0)))
	var retrieval_connection: Vector3 = casting.call("_get_tackle_line_connection_world")
	var expected_retrieval_span := lerpf(
		attachment_height,
		float(retrieval_pose.get("attachment_span_m", attachment_height)),
		float(retrieval_pose.get("alignment_weight", 0.0))
	)
	var retrieval_span_error := retrieval_connection.distance_to(casting.get("_bait_world")) - expected_retrieval_span
	var retrieval_valid := (
		float(retrieval_pose.get("alignment_weight", 0.0)) >= 0.75
		and retrieval_angle <= 25.0
		and absf(retrieval_span_error) <= 0.001
	)

	var near_rod_bait: Vector3 = casting.call("_get_rod_tip_world") - retrieval_natural_up * attachment_height
	casting.set("_bait_world", near_rod_bait)
	casting.set("_line_paid_out_length_m", BoatFishingCastingSystem.MINIMUM_MANUAL_RETRIEVAL_LINE_M)
	casting.set("_state", BoatFishingCastingSystem.CastState.WAITING)
	casting.set("_manual_reeling", true)
	var stow_pose: Dictionary = casting.call("_get_sabiki_airborne_pose", retrieval_natural_up)
	var stow_connection: Vector3 = casting.call("_get_tackle_line_connection_world")
	var expected_stow_span := lerpf(
		attachment_height,
		float(stow_pose.get("attachment_span_m", attachment_height)),
		float(stow_pose.get("alignment_weight", 0.0))
	)
	var stow_valid := (
		float(stow_pose.get("alignment_weight", 0.0)) >= 0.75
		and str(stow_pose.get("mode", "")) == "retrieval_emergence"
		and absf(stow_connection.distance_to(casting.get("_bait_world")) - expected_stow_span) <= 0.001
	)
	# Reproduce the reported short-line state: the sinker is still visibly away
	# from the rod, while the paid-out length has reached its manual minimum.
	# A short line must not force the terminal rig back to its vertical storage pose.
	var short_line_bait: Vector3 = casting.call("_get_rod_tip_world") - retrieval_natural_up * attachment_height + Vector3(0.30, 0.0, 0.0)
	casting.set("_bait_world", short_line_bait)
	casting.set("_line_paid_out_length_m", 0.08)
	casting.set("_bait_velocity_world", Vector3.ZERO)
	var short_line_pose: Dictionary = casting.call("_get_sabiki_airborne_pose", retrieval_natural_up)
	var short_line_connection: Vector3 = casting.call("_get_tackle_line_connection_world")
	var short_line_valid := (
		str(short_line_pose.get("mode", "")) == "retrieval_emergence"
		and float(short_line_pose.get("alignment_weight", 0.0)) > 0.2
		and short_line_connection.distance_to(casting.call("_get_rod_tip_world")) < 0.5
	)
	print("[P6.4.6.0.7][SHORT_LINE_CASE] mode=%s weight=%.4f tip_to_eye=%.4f bait_to_tip=%.4f" % [str(short_line_pose.get("mode", "")), float(short_line_pose.get("alignment_weight", 0.0)), short_line_connection.distance_to(casting.call("_get_rod_tip_world")), short_line_bait.distance_to(casting.call("_get_rod_tip_world"))])
	casting.set("_manual_reeling", false)
	casting.set("_state", BoatFishingCastingSystem.CastState.RETRIEVING)
	casting.set("_state_elapsed", 0.0)
	var stow_start_pose: Dictionary = casting.call("_get_sabiki_airborne_pose", retrieval_natural_up)
	casting.set("_state_elapsed", BoatFishingCastingSystem.RETRIEVE_DURATION_SECONDS * 0.86)
	var transition_pose: Dictionary = casting.call("_get_sabiki_airborne_pose", retrieval_natural_up)
	var transition_weight := float(transition_pose.get("alignment_weight", 0.0))
	casting.set("_state_elapsed", BoatFishingCastingSystem.RETRIEVE_DURATION_SECONDS)
	var final_stow_pose: Dictionary = casting.call("_get_sabiki_airborne_pose", retrieval_natural_up)
	var transition_valid := (
		float(stow_start_pose.get("alignment_weight", 0.0)) >= 0.75
		and absf(transition_weight - float(stow_start_pose.get("alignment_weight", 0.0))) <= 0.001
		and absf(float(final_stow_pose.get("alignment_weight", 0.0)) - transition_weight) <= 0.001
	)

	# A slow upward recoil points toward the rod, opposite the stable radial
	# direction. It must not replace that valid direction below its confidence threshold.
	var slow_recoil_root: Vector3 = casting.call("_get_rod_tip_world") + Vector3.DOWN * 2.4
	casting.set("_bait_world", slow_recoil_root)
	casting.set("_bait_velocity_world", Vector3.UP * 0.5)
	casting.set("_line_paid_out_length_m", 0.8)
	var slow_recoil_pose: Dictionary = casting.call("_get_sabiki_airborne_pose", retrieval_natural_up)
	var slow_recoil_radial: Vector3 = (slow_recoil_root - casting.call("_get_rod_tip_world")).normalized()
	var slow_recoil_direction_valid := Vector3(slow_recoil_pose.get("outward_direction", Vector3.ZERO)).dot(slow_recoil_radial) >= 0.999

	casting.set("_state", original_state)
	casting.set("_current_rig", original_rig)
	casting.set("_bait_world", original_bait)
	casting.set("_bait_velocity_world", original_velocity)
	casting.set("_line_paid_out_length_m", original_paid_line)
	casting.set("_bait_flight_started", original_flight_started)
	casting.set("_bait_has_landed", original_has_landed)
	casting.set("_bait_flight_elapsed", original_flight_elapsed)
	casting.set("_bait_flight_duration", original_flight_duration)
	casting.set("_manual_reeling", original_manual_reeling)
	casting.set("_bait_airborne_retrieval", original_airborne_retrieval)
	casting.set("_fight_session_active", original_fight_active)
	casting.set("_state_elapsed", original_state_elapsed)
	casting.call("_update_rig_visual_selection")
	return cast_valid and partial_valid and retrieval_valid and stow_valid and short_line_valid and transition_valid and slow_recoil_direction_valid and airborne_connection_independent_of_paid_line


func _test_shared_rod_bend_direction(casting: BoatFishingCastingSystem) -> bool:
	var original_rig: BoatFishingRigProfile = casting.get("_current_rig")
	var original_state: int = casting.get("_state")
	var original_bait: Vector3 = casting.get("_bait_world")
	var original_line_length: float = casting.get("_line_paid_out_length_m")
	var original_tension: float = casting.get("_rod_tension")
	var original_manual_reeling: bool = casting.get("_manual_reeling")
	var original_airborne: bool = casting.get("_bait_airborne_retrieval")
	var original_fight_active: bool = casting.get("_fight_session_active")
	var original_bend_angle: float = casting.get("_rod_bend_angle_deg")
	var original_bend_direction: Vector2 = casting.get("_rod_bend_direction_local")
	var original_aim_pitch: float = casting.get("_rod_aim_pitch_deg")
	var original_aim_yaw: float = casting.get("_rod_aim_yaw_deg")
	var rod_mesh := casting.get("_rod_mesh_instance") as MeshInstance3D
	if rod_mesh == null:
		return false
	var all_rigs_valid := true
	for profile in [SINGLE_JIG_PROFILE, SABIKI_RIG_PROFILE]:
		casting.set("_current_rig", profile)
		casting.set("_state", BoatFishingCastingSystem.CastState.WAITING)
		casting.set("_manual_reeling", true)
		casting.set("_bait_airborne_retrieval", false)
		casting.set("_fight_session_active", false)
		casting.set("_rod_tension", 0.8)
		casting.set("_rod_aim_pitch_deg", 0.0)
		casting.set("_rod_aim_yaw_deg", 0.0)
		casting.set("_rod_bend_angle_deg", 18.0)
		casting.call("_set_rod_bend_angle", deg_to_rad(18.0))
		casting.call("_update_rig_visual_selection")
		var target_pull := Vector3(0.55, -0.68, 0.48).normalized() * 2.0
		var initial_tip: Vector3 = casting.call("_get_rod_tip_world")
		var connector_offset: Vector3 = casting.call("_get_tackle_line_connection_offset_world")
		casting.set("_bait_world", initial_tip + target_pull - connector_offset)
		casting.set("_line_paid_out_length_m", target_pull.length())
		casting.call("_apply_waiting_rod_pose")
		var straight_tip: Vector3 = casting.call("_get_fight_solver_rod_tip_world")
		var bent_tip: Vector3 = casting.call("_get_rod_tip_world")
		var line_direction: Vector3 = (casting.call("_get_tackle_line_connection_world") - bent_tip).normalized()
		var rod_axis := (rod_mesh.global_basis * Vector3.UP).normalized()
		var pull_perpendicular := line_direction - rod_axis * line_direction.dot(rod_axis)
		var local_direction: Vector2 = casting.get("_rod_bend_direction_local")
		var mapped_direction := rod_mesh.global_basis * Vector3(local_direction.x, 0.0, local_direction.y)
		var mapping_alignment := mapped_direction.normalized().dot(pull_perpendicular.normalized()) if mapped_direction.length_squared() > 0.000001 and pull_perpendicular.length_squared() > 0.000001 else -1.0
		var deflection_projection := (bent_tip - straight_tip).dot(pull_perpendicular.normalized()) if pull_perpendicular.length_squared() > 0.000001 else -1.0
		print("[P6.4.6.0.7][ROD_CASE] rig=%s tip=%s connection=%s pull=%s bend_local=%s mapping_dot=%.6f deflection_projection_m=%.6f" % [str(profile.rig_id), str(bent_tip), str(casting.call("_get_tackle_line_connection_world")), str(line_direction), str(local_direction), mapping_alignment, deflection_projection])
		all_rigs_valid = all_rigs_valid and mapping_alignment > 0.97 and deflection_projection > 0.0
	casting.set("_current_rig", original_rig)
	casting.set("_state", original_state)
	casting.set("_bait_world", original_bait)
	casting.set("_line_paid_out_length_m", original_line_length)
	casting.set("_rod_tension", original_tension)
	casting.set("_manual_reeling", original_manual_reeling)
	casting.set("_bait_airborne_retrieval", original_airborne)
	casting.set("_fight_session_active", original_fight_active)
	casting.set("_rod_bend_angle_deg", original_bend_angle)
	casting.set("_rod_bend_direction_local", original_bend_direction)
	casting.set("_rod_aim_pitch_deg", original_aim_pitch)
	casting.set("_rod_aim_yaw_deg", original_aim_yaw)
	casting.call("_set_rod_bend_angle", deg_to_rad(original_bend_angle))
	casting.call("_set_rod_bend_direction", original_bend_direction)
	casting.call("_update_rig_visual_selection")
	return all_rigs_valid


func _run_rig_case(
	main: Node,
	onboard: OnboardActivityController,
	boat_controller: BoatController,
	casting: BoatFishingCastingSystem,
	camera: BoatFollowCamera,
	line_instance: MeshInstance3D,
	rig_id: StringName,
	fps: int
) -> void:
	casting.clear_cast()
	_check(casting.select_rig(rig_id), "%s rig can be selected for %d FPS runtime capture" % [str(rig_id), fps])
	boat_controller.is_autopilot = false
	boat_controller.speed_mps = 0.0
	casting.set("_boat_velocity_estimate_world", Vector3.ZERO)
	casting.set("_previous_boat_world", boat_controller.global_position)

	var player := onboard.find_child("OnboardActivityPlayer", true, false) as CharacterBody3D
	onboard.set("_player_local_position", Vector3(0.53, onboard.profile.deck_height_m, 1.28))
	player.position = Vector3(0.53, onboard.profile.deck_height_m, 1.28)
	onboard.set("_player_local_yaw", -PI * 0.5)
	onboard.call("_set_player_transform_from_hull")
	_check(casting.begin_charge(), "%s uses the normal READY → CHARGING transition at %d FPS" % [str(rig_id), fps])
	if casting.get_casting_state() != BoatFishingCastingSystem.CastState.CHARGING:
		return

	# Use the normal release validator and cast state. The charge is advanced by
	# the real process loop below; only its starting progress is fixed for repeatability.
	casting.set("_charge_elapsed", 0.12)
	casting.call("_set_charge_pose", 0.12)
	onboard.set("_player_local_yaw", -PI * 0.5 + 0.08)
	onboard.call("_set_player_transform_from_hull")
	_check(casting.release_charge(), "%s reaches CASTING through release_charge() at %d FPS" % [str(rig_id), fps])
	if casting.get_casting_state() != BoatFishingCastingSystem.CastState.CASTING:
		return

	var case_id := "%s_%d_cast" % [str(rig_id), fps]
	var started_usec := Time.get_ticks_usec()
	_phase_started_usec = started_usec
	var cast_image_saved := false
	var cast_launch_image_saved := false
	var cast_midair_image_saved := false
	var cast_water_entry_image_saved := false
	var cast_samples := 0
	var max_cast_kink_deg := 0.0
	var max_cast_connection_error_m := 0.0
	var max_cast_path_excess_m := 0.0
	var max_cast_line_length_error_m := 0.0
	var invalid_cast_path_samples := 0
	var max_cast_backbone_tilt_deg := 0.0
	var max_cast_axis_velocity_alignment := -1.0
	var max_stretched_air_angle_deg := 0.0
	var stretched_air_samples := 0
	var cast_mainline_ends_at_connection := true
	var cast_backbone_matches_anchors := true
	var cast_backbone_matches_hook_stations := true
	var unloaded_axis_to_rod_dot := -1.0
	# Sample an actual release through fixed production cast steps before resuming
	# wall-time playback, so a low GPU FPS cannot skip the whole flight window.
	if _is_gpu_runtime() and rig_id == &"sabiki_rig":
		var original_pause := paused
		paused = true
		for fixed_frame in range(90):
			if casting.get_casting_state() != BoatFishingCastingSystem.CastState.CASTING:
				break
			casting.call("_update_cast_animation", 1.0 / 60.0)
			casting.call("_update_line_and_bait_visuals")
			var fixed_sample := _collect_sample(case_id, casting, line_instance, fps)
			if float(fixed_sample.get("airborne_alignment_weight", 0.0)) >= 0.75 and float(fixed_sample.get("actual_tip_to_connection_m", 0.0)) > 0.35:
				fixed_sample["fixed_simulation_delta"] = 1.0 / 60.0
				_write_sample(fixed_sample)
				stretched_air_samples += 1
				max_stretched_air_angle_deg = maxf(max_stretched_air_angle_deg, float(fixed_sample.get("external_to_backbone_angle_deg", 0.0)))
				await RenderingServer.frame_post_draw
				get_root().get_texture().get_image().save_png(_capture_path("sabiki_fixed_step_flight"))
				break
		paused = original_pause
	while Time.get_ticks_usec() - started_usec < int(MAX_CAST_SECONDS * 1000000.0):
		await process_frame
		if _is_gpu_runtime():
			await RenderingServer.frame_post_draw
		var sample := _collect_sample(case_id, casting, line_instance, fps)
		if not sample.is_empty():
			cast_samples += 1
			max_cast_kink_deg = maxf(max_cast_kink_deg, float(sample.get("external_to_backbone_angle_deg", 0.0)))
			max_cast_connection_error_m = maxf(max_cast_connection_error_m, float(sample.get("mesh_connection_error_m", 0.0)))
			if bool(sample.get("external_path_measurement_valid", false)):
				max_cast_path_excess_m = maxf(max_cast_path_excess_m, float(sample.get("external_path_minus_paid_line_m", 0.0)))
				max_cast_line_length_error_m = maxf(max_cast_line_length_error_m, absf(float(sample.get("external_path_minus_paid_line_m", 0.0))))
			else:
				invalid_cast_path_samples += 1
			max_cast_backbone_tilt_deg = maxf(max_cast_backbone_tilt_deg, float(sample.get("backbone_tilt_from_gravity_deg", 0.0)))
			max_cast_axis_velocity_alignment = maxf(max_cast_axis_velocity_alignment, float(sample.get("backbone_axis_motion_alignment", -1.0)))
			if (
				rig_id == &"sabiki_rig"
				and str(sample.get("airborne_alignment_mode", "")) == "cast_flight"
				and float(sample.get("airborne_alignment_weight", 0.0)) >= 0.75
				and float(sample.get("actual_tip_to_connection_m", 0.0)) > 0.35
			):
				max_stretched_air_angle_deg = maxf(max_stretched_air_angle_deg, float(sample.get("external_to_backbone_angle_deg", 0.0)))
				stretched_air_samples += 1
			if rig_id == &"sabiki_rig":
				cast_mainline_ends_at_connection = cast_mainline_ends_at_connection and bool(sample.get("mainline_ends_at_connection", false))
				cast_backbone_matches_anchors = cast_backbone_matches_anchors and float(sample.get("backbone_start_error_m", INF)) <= 0.005 and float(sample.get("backbone_sinker_error_m", INF)) <= 0.005
				cast_backbone_matches_hook_stations = cast_backbone_matches_hook_stations and bool(sample.get("backbone_matches_hook_stations", false))
			_write_sample(sample)
			if rig_id == &"sabiki_rig" and _is_gpu_runtime():
				var flight_elapsed := float(sample.get("bait_flight_elapsed_seconds", 0.0))
				if not cast_launch_image_saved and flight_elapsed >= 0.035 and flight_elapsed <= 0.16:
					await RenderingServer.frame_post_draw
					get_root().get_texture().get_image().save_png(_capture_path("sabiki_cast_launch"))
					cast_launch_image_saved = true
				var flight_progress := flight_elapsed / maxf(float(sample.get("bait_flight_duration_seconds", 0.01)), 0.01)
				if not cast_midair_image_saved and flight_progress >= 0.38 and flight_progress <= 0.62:
					await RenderingServer.frame_post_draw
					get_root().get_texture().get_image().save_png(_capture_path("sabiki_cast_midair"))
					cast_midair_image_saved = true
				if not cast_water_entry_image_saved and bool(sample.get("bait_has_landed", false)):
					await RenderingServer.frame_post_draw
					get_root().get_texture().get_image().save_png(_capture_path("sabiki_cast_water_entry"))
					cast_water_entry_image_saved = true
			if not cast_image_saved and _is_gpu_runtime() and float(sample.get("elapsed_seconds", 0.0)) >= 0.25:
				await RenderingServer.frame_post_draw
				get_root().get_texture().get_image().save_png(_capture_path(case_id))
				cast_image_saved = true
		if casting.get_casting_state() == BoatFishingCastingSystem.CastState.WAITING:
			break
	_check(casting.get_casting_state() == BoatFishingCastingSystem.CastState.WAITING, "%s completes the normal cast and tackle entry at %d FPS" % [str(rig_id), fps])
	if _is_gpu_runtime():
		await RenderingServer.frame_post_draw
		get_root().get_texture().get_image().save_png(_capture_path("%s_%d_cast_end" % [str(rig_id), fps]))
	if rig_id == &"sabiki_rig":
		_phase_started_usec = Time.get_ticks_usec()
		for _waiting_frame in range(8):
			await process_frame
			var waiting_sample := _collect_sample("%s_%d_waiting" % [str(rig_id), fps], casting, line_instance, fps)
			if not waiting_sample.is_empty():
				unloaded_axis_to_rod_dot = cos(deg_to_rad(float(waiting_sample.get("axis_to_rod_angle_deg", 180.0))))
				_write_sample(waiting_sample)
		if _is_gpu_runtime():
			await RenderingServer.frame_post_draw
			get_root().get_texture().get_image().save_png(_capture_path("%s_%d_waiting" % [str(rig_id), fps]))
	_write_summary({
		"case": case_id,
		"phase": "cast_summary",
		"samples": cast_samples,
		"observed_sample_fps": float(cast_samples) / maxf(float(Time.get_ticks_usec() - started_usec) / 1000000.0, 0.001),
		"max_external_to_backbone_angle_deg": max_cast_kink_deg,
		"max_mesh_connection_error_m": max_cast_connection_error_m,
		"max_external_path_minus_paid_line_m": max_cast_path_excess_m,
		"max_external_paid_length_error_m": max_cast_line_length_error_m,
		"invalid_external_path_samples": invalid_cast_path_samples,
		"max_backbone_tilt_from_gravity_deg": max_cast_backbone_tilt_deg,
		"max_backbone_axis_motion_alignment": max_cast_axis_velocity_alignment,
		"max_stretched_air_mainline_to_backbone_angle_deg": max_stretched_air_angle_deg,
		"stretched_air_alignment_samples": stretched_air_samples,
		"mainline_ends_at_connection": cast_mainline_ends_at_connection,
		"backbone_matches_anchors": cast_backbone_matches_anchors,
		"backbone_matches_hook_stations": cast_backbone_matches_hook_stations,
		"cast_image_saved": cast_image_saved,
		"cast_launch_image_saved": cast_launch_image_saved,
		"cast_midair_image_saved": cast_midair_image_saved,
		"cast_water_entry_image_saved": cast_water_entry_image_saved,
	})
	_check(max_cast_line_length_error_m <= MAX_CAST_LINE_LENGTH_ERROR_M,
		"%s maintains cast paid-line length within %.2f m at %d FPS" % [str(rig_id), MAX_CAST_LINE_LENGTH_ERROR_M, fps])
	if rig_id == &"sabiki_rig":
		_check(stretched_air_samples > 0, "Sabiki produces measurable high-weight airborne pose samples at %d FPS" % fps)
		_check(max_stretched_air_angle_deg <= 25.0,
			"Sabiki airborne mainline and backbone follow the same outward continuation within 25 degrees at %d FPS" % fps)
		_check(max_cast_backbone_tilt_deg > 5.0 and max_cast_axis_velocity_alignment > 0.15,
			"Sabiki terminal rig responds to actual cast motion instead of remaining world-vertical at %d FPS" % fps)
		_check(cast_mainline_ends_at_connection,
			"Sabiki outer mainline ends at the line eye and excludes hook/weight anchors at %d FPS" % fps)
		_check(cast_backbone_matches_anchors,
			"Sabiki backbone mesh starts at the line eye and ends at the sinker at %d FPS" % fps)
		_check(cast_backbone_matches_hook_stations,
			"Sabiki backbone mesh passes through the actual hook stations at %d FPS" % fps)

	if casting.get_casting_state() != BoatFishingCastingSystem.CastState.WAITING:
		return

	var old_reel_speed := casting.manual_reel_speed_mps
	# The reel remains player-controlled; use the configured normal speed so this
	# capture measures the actual retrieval state machine rather than a test impulse.
	casting.manual_reel_speed_mps = old_reel_speed
	_check(casting.set_manual_reeling(true, true), "%s begins manual retrieval through the player-facing reel API at %d FPS" % [str(rig_id), fps])
	var retrieve_case_id := "%s_%d_retrieve" % [str(rig_id), fps]
	var retrieve_started_usec := Time.get_ticks_usec()
	_phase_started_usec = retrieve_started_usec
	var retrieve_samples := 0
	var partial_frame_saved := false
	var retrieval_image_saved := false
	var near_recovery_image_saved := false
	var airborne_retrieval_image_saved := false
	var final_retrieval_image_saved := false
	var max_loaded_axis_to_rod_dot := -1.0
	var max_retrieve_rod_tension := 0.0
	var max_retrieve_kink_deg := 0.0
	var max_airborne_retrieval_alignment_deg := 0.0
	var airborne_retrieval_alignment_samples := 0
	var max_retrieve_connection_error_m := 0.0
	var max_retrieve_path_excess_m := 0.0
	var max_retrieve_line_length_error_m := 0.0
	var max_retrieve_settled_line_length_error_m := 0.0
	var max_slack_path_overrun_m := 0.0
	var invalid_retrieve_path_samples := 0
	var component_capture_grace_until_usec := 0
	var component_capture_grace_samples := 0
	var retrieve_mainline_ends_at_connection := true
	var retrieve_backbone_matches_anchors := true
	var retrieve_backbone_matches_hook_stations := true
	while Time.get_ticks_usec() - retrieve_started_usec < int(MAX_RETRIEVE_SECONDS * 1000000.0):
		await process_frame
		if _is_gpu_runtime():
			await RenderingServer.frame_post_draw
		var sample := _collect_sample(retrieve_case_id, casting, line_instance, fps)
		if not sample.is_empty():
			var post_capture_grace := Time.get_ticks_usec() < component_capture_grace_until_usec
			sample["component_capture_grace"] = post_capture_grace
			if post_capture_grace:
				component_capture_grace_samples += 1
			retrieve_samples += 1
			# Component isolation briefly pauses the casting process so the GPU can
			# capture individual meshes. Those stale frames are useful evidence for
			# component ownership, but are not live retrieval geometry and must not
			# participate in state-machine continuity assertions.
			if not post_capture_grace:
				var current_angle := float(sample.get("external_to_backbone_angle_deg", 0.0))
				if float(sample.get("actual_tip_to_connection_m", 0.0)) > 0.25:
					max_retrieve_kink_deg = maxf(max_retrieve_kink_deg, current_angle)
				if (
					float(sample.get("airborne_alignment_weight", 0.0)) >= 0.65
					and float(sample.get("actual_tip_to_connection_m", 0.0)) > 0.45
				):
					max_airborne_retrieval_alignment_deg = maxf(max_airborne_retrieval_alignment_deg, current_angle)
					airborne_retrieval_alignment_samples += 1
				if bool(sample.get("external_path_measurement_valid", false)):
					max_retrieve_connection_error_m = maxf(max_retrieve_connection_error_m, float(sample.get("mesh_connection_error_m", 0.0)))
					var path_delta := float(sample.get("external_path_minus_paid_line_m", 0.0))
					if bool(sample.get("main_line_taut", false)):
						max_retrieve_path_excess_m = maxf(max_retrieve_path_excess_m, path_delta)
						var line_length_error := absf(path_delta)
						max_retrieve_line_length_error_m = maxf(max_retrieve_line_length_error_m, line_length_error)
						if float(sample.get("elapsed_seconds", 0.0)) >= 0.4:
							max_retrieve_settled_line_length_error_m = maxf(max_retrieve_settled_line_length_error_m, line_length_error)
					else:
						max_slack_path_overrun_m = maxf(max_slack_path_overrun_m, path_delta)
				elif bool(sample.get("main_line_taut", false)):
					invalid_retrieve_path_samples += 1
				if rig_id == &"sabiki_rig":
					if bool(sample.get("external_path_measurement_valid", false)):
						retrieve_mainline_ends_at_connection = retrieve_mainline_ends_at_connection and bool(sample.get("mainline_ends_at_connection", false))
					retrieve_backbone_matches_anchors = retrieve_backbone_matches_anchors and float(sample.get("backbone_start_error_m", INF)) <= 0.005 and float(sample.get("backbone_sinker_error_m", INF)) <= 0.005
					retrieve_backbone_matches_hook_stations = retrieve_backbone_matches_hook_stations and bool(sample.get("backbone_matches_hook_stations", false))
					var sample_tension := float(sample.get("rod_tension_visual", 0.0))
					max_retrieve_rod_tension = maxf(max_retrieve_rod_tension, sample_tension)
					if bool(sample.get("main_line_taut", false)) and sample_tension >= 0.4:
						max_loaded_axis_to_rod_dot = maxf(
							max_loaded_axis_to_rod_dot,
							cos(deg_to_rad(float(sample.get("axis_to_rod_angle_deg", 180.0))))
						)
			_write_sample(sample)
			if not retrieval_image_saved and _is_gpu_runtime() and float(sample.get("elapsed_seconds", 0.0)) >= 0.25:
				await RenderingServer.frame_post_draw
				get_root().get_texture().get_image().save_png(_capture_path("%s_retrieve_underwater" % retrieve_case_id))
				retrieval_image_saved = true
			if not near_recovery_image_saved and _is_gpu_runtime() and float(sample.get("paid_line_length_m", INF)) <= 1.25:
				await RenderingServer.frame_post_draw
				get_root().get_texture().get_image().save_png(_capture_path("%s_near_recovery" % retrieve_case_id))
				near_recovery_image_saved = true
			if (
				not airborne_retrieval_image_saved
				and _is_gpu_runtime()
				and float(sample.get("sinker_height_above_surface_m", -INF)) >= 0.025
				and int(sample.get("hook_above_surface_count", 0)) == SABIKI_RIG_PROFILE.hook_count
			):
				await RenderingServer.frame_post_draw
				get_root().get_texture().get_image().save_png(_capture_path("sabiki_fully_airborne_retrieval"))
				airborne_retrieval_image_saved = true
				if rig_id == &"sabiki_rig":
					await _capture_sabiki_component_views(retrieve_case_id + "_fully_airborne", casting, line_instance)
			if (
				not final_retrieval_image_saved
				and _is_gpu_runtime()
				and casting.get_casting_state() == BoatFishingCastingSystem.CastState.RETRIEVING
				and float(casting.get("_state_elapsed")) >= 0.56
			):
				await RenderingServer.frame_post_draw
				get_root().get_texture().get_image().save_png(_capture_path("%s_final_retrieval" % retrieve_case_id))
				final_retrieval_image_saved = true
			if not partial_frame_saved and _is_gpu_runtime() and bool(sample.get("partial_tackle_emergence", false)):
				await RenderingServer.frame_post_draw
				get_root().get_texture().get_image().save_png(_capture_path("%s_partial" % retrieve_case_id))
				partial_frame_saved = true
				if rig_id == &"sabiki_rig":
					await _capture_sabiki_component_views(retrieve_case_id, casting, line_instance)
					component_capture_grace_until_usec = Time.get_ticks_usec() + 500000
		if casting.get_casting_state() == BoatFishingCastingSystem.CastState.READY:
			break
	_check(casting.get_casting_state() == BoatFishingCastingSystem.CastState.READY, "%s completes normal manual reel and final retrieval at %d FPS" % [str(rig_id), fps])
	casting.set_manual_reeling(false, true)
	if rig_id == &"sabiki_rig":
		var terminal_visual := casting.find_child("SabikiRigVisual", true, false) as Node3D
		_check(not line_instance.visible and terminal_visual != null and not terminal_visual.visible, "Completed recovery hides mainline and the complete terminal rig")
		if _is_gpu_runtime():
			await RenderingServer.frame_post_draw
			get_root().get_texture().get_image().save_png(_capture_path("sabiki_recovered"))
		var recast_started := casting.begin_charge()
		casting.set("_charge_elapsed", 0.12)
		casting.call("_set_charge_pose", 0.12)
		recast_started = casting.release_charge() and recast_started
		for recast_step in range(24):
			if casting.get_casting_state() == BoatFishingCastingSystem.CastState.CASTING:
				casting.call("_update_cast_animation", 1.0 / 60.0)
				casting.call("_update_line_and_bait_visuals")
		_check(recast_started and line_instance.visible and terminal_visual.visible, "A second normal Sabiki cast restores mainline and terminal visibility")
		if _is_gpu_runtime():
			var saved_pause := paused
			paused = true
			await RenderingServer.frame_post_draw
			get_root().get_texture().get_image().save_png(_capture_path("sabiki_recast"))
			paused = saved_pause
		casting.clear_cast()
	_write_summary({
		"case": retrieve_case_id,
		"phase": "retrieve_summary",
		"samples": retrieve_samples,
		"observed_sample_fps": float(retrieve_samples) / maxf(float(Time.get_ticks_usec() - retrieve_started_usec) / 1000000.0, 0.001),
		"max_external_to_backbone_angle_deg": max_retrieve_kink_deg,
		"max_airborne_retrieval_external_to_backbone_angle_deg": max_airborne_retrieval_alignment_deg,
		"airborne_retrieval_alignment_samples": airborne_retrieval_alignment_samples,
		"max_mesh_connection_error_m": max_retrieve_connection_error_m,
		"max_external_path_minus_paid_line_m": max_retrieve_path_excess_m,
		"max_external_paid_length_error_m": max_retrieve_line_length_error_m,
		"max_external_paid_length_error_after_400ms_m": max_retrieve_settled_line_length_error_m,
		"max_slack_path_overrun_m": max_slack_path_overrun_m,
		"invalid_external_path_samples": invalid_retrieve_path_samples,
		"component_capture_grace_samples": component_capture_grace_samples,
		"mainline_ends_at_connection": retrieve_mainline_ends_at_connection,
		"backbone_matches_anchors": retrieve_backbone_matches_anchors,
		"backbone_matches_hook_stations": retrieve_backbone_matches_hook_stations,
		"maximum_retrieve_rod_tension": max_retrieve_rod_tension,
		"maximum_loaded_axis_to_rod_dot": max_loaded_axis_to_rod_dot,
		"partial_frame_saved": partial_frame_saved,
		"retrieval_image_saved": retrieval_image_saved,
		"airborne_retrieval_image_saved": airborne_retrieval_image_saved,
		"final_retrieval_image_saved": final_retrieval_image_saved,
	})
	_check(max_retrieve_settled_line_length_error_m <= MAX_RETRIEVE_LINE_LENGTH_ERROR_M,
		"%s maintains settled retrieved main-line path within %.2f m of paid length at %d FPS" % [str(rig_id), MAX_RETRIEVE_LINE_LENGTH_ERROR_M, fps])
	if rig_id == &"sabiki_rig":
		_check(retrieve_mainline_ends_at_connection,
			"Sabiki outer mainline remains isolated from hook/weight anchors during retrieval at %d FPS" % fps)
		_check(retrieve_backbone_matches_anchors,
			"Sabiki backbone remains attached to the line eye and sinker during retrieval at %d FPS" % fps)
		_check(retrieve_backbone_matches_hook_stations,
			"Sabiki backbone remains aligned with all actual hook stations during retrieval at %d FPS" % fps)
		_check(max_retrieve_rod_tension >= 0.4 and max_loaded_axis_to_rod_dot > unloaded_axis_to_rod_dot + 0.04,
			"Sabiki terminal geometry responds toward the rod under actual taut retrieval load at %d FPS" % fps)
	if casting.get_casting_state() != BoatFishingCastingSystem.CastState.READY:
		casting.clear_cast()


func _collect_sample(
	case_id: String,
	casting: BoatFishingCastingSystem,
	line_instance: MeshInstance3D,
	fps: int
) -> Dictionary:
	if not casting.is_cast_active() or not line_instance.visible or not (line_instance.mesh is ImmediateMesh):
		return {}
	var snapshot := casting.get_debug_snapshot()
	var rod_tip: Vector3 = snapshot.get("rod_tip_world_position", Vector3.ZERO)
	var connection: Vector3 = snapshot.get("line_connection_world_position", Vector3.ZERO)
	var sinker: Vector3 = snapshot.get("sinker_world_position", Vector3.ZERO)
	var rig_root := casting.find_child("SabikiRigVisual", true, false) as Node3D
	var backbone_instance := casting.find_child("SabikiBackboneLine", true, false) as MeshInstance3D
	var backbone_axis := rig_root.global_basis.y.normalized() if rig_root != null else Vector3.UP
	var bait_velocity: Vector3 = casting.get("_bait_velocity_world")
	var now_usec := Time.get_ticks_usec()
	var previous_usec := int(_last_sample_usec_by_case.get(case_id, 0))
	var sample_dt := float(now_usec - previous_usec) / 1000000.0 if previous_usec > 0 else 0.0
	var previous_axis: Vector3 = _last_axis_by_case.get(case_id, backbone_axis)
	var previous_bait_velocity: Vector3 = _last_bait_velocity_by_case.get(case_id, bait_velocity)
	var axis_step_deg := rad_to_deg(acos(clampf(previous_axis.normalized().dot(backbone_axis), -1.0, 1.0))) if previous_usec > 0 else 0.0
	var bait_acceleration := (bait_velocity - previous_bait_velocity) / sample_dt if sample_dt > 0.00001 else Vector3.ZERO
	_last_sample_usec_by_case[case_id] = now_usec
	_last_axis_by_case[case_id] = backbone_axis
	_last_bait_velocity_by_case[case_id] = bait_velocity
	var horizontal_velocity := Vector3(bait_velocity.x, 0.0, bait_velocity.z)
	var axis_horizontal := Vector3(backbone_axis.x, 0.0, backbone_axis.z)
	var axis_motion_alignment := axis_horizontal.normalized().dot(-horizontal_velocity.normalized()) if axis_horizontal.length_squared() > 0.0001 and horizontal_velocity.length_squared() > 0.0025 and casting.get_casting_state() == BoatFishingCastingSystem.CastState.CASTING else -1.0
	var centerline := _read_actual_mesh_centerline(line_instance)
	if centerline.size() < 2:
		return {}
	var backbone_centerline: Array[Vector3] = []
	if backbone_instance != null and backbone_instance.visible:
		backbone_centerline = _read_actual_mesh_centerline(backbone_instance)
	var connection_index := centerline.size() - 1
	var rod_tip_index := _find_nearest_point_index(centerline, rod_tip)
	var connection_error := centerline[-1].distance_to(connection)
	if connection_error > 0.01:
		connection_index = -1
	var angle_deg := -1.0
	var incoming_direction := Vector3.ZERO
	var outgoing_direction := Vector3.ZERO
	if connection_index > 0 and connection_index == centerline.size() - 1 and backbone_centerline.size() > 1:
		incoming_direction = (centerline[connection_index] - centerline[connection_index - 1]).normalized()
		outgoing_direction = (backbone_centerline[1] - backbone_centerline[0]).normalized()
		angle_deg = rad_to_deg(acos(clampf(incoming_direction.dot(outgoing_direction), -1.0, 1.0)))
	var external_path_length := 0.0
	if rod_tip_index >= 0 and connection_index > rod_tip_index:
		for point_index in range(rod_tip_index, connection_index):
			external_path_length += centerline[point_index].distance_to(centerline[point_index + 1])
	var backbone_start_error := backbone_centerline[0].distance_to(connection) if not backbone_centerline.is_empty() else INF
	var backbone_sinker_error := backbone_centerline[-1].distance_to(sinker) if not backbone_centerline.is_empty() else INF
	var expected_mainline_length := float(snapshot.get("paid_out_line_length_m", 0.0))
	var mainline_ends_at_connection := connection_error <= 0.01 or (
		expected_mainline_length <= 0.005 and rod_tip.distance_to(connection) <= 0.01
	)
	var water_data := _get_water_heights(casting)
	var natural_up: Vector3 = casting.call("_get_sabiki_natural_up_direction_world")
	var airborne_pose: Dictionary = casting.call("_get_sabiki_airborne_pose", natural_up) if casting.get("_current_rig").rig_type == BoatFishingRigProfile.RigType.SABIKI else {}
	var above_count := int(water_data.get("above_hook_count", 0))
	var below_count := int(water_data.get("below_hook_count", 0))
	var elapsed_seconds := float(Time.get_ticks_usec() - _phase_started_usec) / 1000000.0
	var paid_line_length := float(snapshot.get("paid_out_line_length_m", 0.0))
	var hook_positions: Array[Vector3] = casting.call("get_hook_attachment_world_positions")
	var current_rig: BoatFishingRigProfile = casting.get("_current_rig")
	var top_eye := casting.find_child("SabikiRodSideEye", true, false) as Node3D
	var boat_velocity: Vector3 = casting.get("_boat_velocity_estimate_world")
	var toward_rod := (rod_tip - connection).normalized()
	var toward_rod_from_sinker := (rod_tip - sinker).normalized()
	var fight_snapshot: Dictionary = snapshot.get("fight_snapshot", {})
	var expected_hook_stations: Array[Vector3] = casting.call("get_rig_hook_positions", sinker, backbone_axis)
	var max_hook_station_error := 0.0
	var backbone_matches_hook_stations := backbone_centerline.size() >= 2
	if backbone_matches_hook_stations:
		for hook_position in expected_hook_stations:
			var station_error := _nearest_point_on_polyline_distance(hook_position, backbone_centerline)
			max_hook_station_error = maxf(max_hook_station_error, station_error)
			backbone_matches_hook_stations = backbone_matches_hook_stations and station_error <= 0.01
	var fresh_rod_tip: Vector3 = casting.call("_get_rod_tip_world")
	var fresh_bait: Vector3 = casting.get("_bait_world")
	var fresh_airborne_pose: Dictionary = casting.call("_get_sabiki_airborne_pose", natural_up) if casting.get("_current_rig").rig_type == BoatFishingRigProfile.RigType.SABIKI else {}
	var computed_up: Vector3 = casting.call("_get_sabiki_up_direction_world") if casting.get("_current_rig").rig_type == BoatFishingRigProfile.RigType.SABIKI else Vector3.UP
	return {
		"case": case_id,
		"fps_target": fps,
		"elapsed_seconds": elapsed_seconds,
		"bait_flight_elapsed_seconds": float(casting.get("_bait_flight_elapsed")),
		"bait_flight_duration_seconds": float(casting.get("_bait_flight_duration")),
		"bait_has_landed": bool(casting.get("_bait_has_landed")),
		"cast_tackle_entry_complete": bool(casting.get("_cast_tackle_entry_complete")),
		"airborne_alignment_mode": str(airborne_pose.get("mode", "single_jig")),
		"airborne_alignment_weight": float(airborne_pose.get("alignment_weight", 0.0)),
		"airborne_emergence_weight": float(airborne_pose.get("emergence_weight", 0.0)),
		"airborne_stow_progress": float(airborne_pose.get("stow_progress", 0.0)),
		"airborne_mainline_length_m": float(airborne_pose.get("mainline_length_m", 0.0)),
		"airborne_line_direction_confidence": float(airborne_pose.get("line_direction_confidence", 0.0)),
		"airborne_motion_direction_confidence": float(airborne_pose.get("motion_direction_confidence", 0.0)),
		"airborne_target_outward_direction": airborne_pose.get("outward_direction", Vector3.ZERO),
		"fresh_airborne_pose_up_direction": fresh_airborne_pose.get("up_direction", Vector3.ZERO),
		"computed_rig_up_direction": computed_up,
		"computed_rig_axis_error_deg": rad_to_deg(acos(clampf(computed_up.normalized().dot(backbone_axis), -1.0, 1.0))) if computed_up.length_squared() > 0.5 else -1.0,
		"pose_root_outward_actual": (fresh_bait - fresh_rod_tip).normalized() if fresh_bait.distance_to(fresh_rod_tip) > 0.0001 else Vector3.ZERO,
		"snapshot_rod_tip_error_m": fresh_rod_tip.distance_to(rod_tip),
		"snapshot_bait_error_m": fresh_bait.distance_to(sinker),
		"sample_dt_real_seconds": sample_dt,
		"actual_sample_fps": 1.0 / sample_dt if sample_dt > 0.00001 else 0.0,
		"frame": Engine.get_process_frames(),
		"state": casting.get_casting_state_name(),
		"state_elapsed_seconds": float(casting.get("_state_elapsed")),
		"paid_line_length_m": paid_line_length,
		"actual_tip_to_connection_m": rod_tip.distance_to(connection),
		"external_mesh_path_length_m": external_path_length,
		"external_path_minus_paid_line_m": external_path_length - paid_line_length,
		"external_path_measurement_valid": rod_tip_index >= 0 and connection_index > rod_tip_index,
		"rod_tip_mesh_error_m": _nearest_point_distance(centerline, rod_tip),
		"main_line_taut": bool(casting.call("_get_main_line_visual_state").get("taut", false)),
		"slack_ratio": float(casting.call("_get_main_line_visual_state").get("slack_ratio", 1.0)),
		"line_tension": float(snapshot.get("line_tension", 0.0)),
		"rod_tension_visual": float(casting.get("_rod_tension")),
		"fight_tension_n": float(fight_snapshot.get("tension_n", 0.0)),
		"fight_tension_ratio": float(fight_snapshot.get("tension_ratio", 0.0)),
		"fight_line_rate_mps": float(fight_snapshot.get("line_rate_mps", 0.0)),
		"fight_drag_paying_out": bool(fight_snapshot.get("drag_paying_out", false)),
		"manual_reeling": bool(snapshot.get("manual_reeling", false)),
		"manual_line_releasing": bool(snapshot.get("manual_line_releasing", false)),
		"rod_tip_world": rod_tip,
		"line_connection_world": connection,
		"external_mainline_world_points": centerline,
		"external_mesh_numeric_points": centerline.map(func(p: Vector3) -> Array: return [p.x, p.y, p.z]),
		"sinker_world": sinker,
		"rig_line_eye_chord_m": sinker.distance_to(connection),
		"rig_profile_arc_length_m": current_rig.get_line_attachment_height_m() if current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI else 0.0,
		"rig_line_eye_chord_shortfall_m": maxf(0.0, current_rig.get_line_attachment_height_m() - sinker.distance_to(connection)) if current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI else 0.0,
		"sabiki_top_eye_world": top_eye.global_position if top_eye != null else Vector3.ZERO,
		"sabiki_backbone_world_points": backbone_centerline,
		"backbone_mesh_numeric_points": backbone_centerline.map(func(p: Vector3) -> Array: return [p.x, p.y, p.z]),
		"sabiki_backbone_visible": backbone_instance.visible if backbone_instance != null else false,
		"backbone_start_error_m": backbone_start_error,
		"backbone_sinker_error_m": backbone_sinker_error,
		"backbone_matches_hook_stations": backbone_matches_hook_stations,
		"max_hook_station_error_m": max_hook_station_error,
		"mainline_ends_at_connection": mainline_ends_at_connection,
		"hook_attachment_world_positions": hook_positions,
		"backbone_axis_world": backbone_axis,
		"toward_rod_world": toward_rod,
		"toward_rod_from_sinker_world": toward_rod_from_sinker,
		"axis_to_rod_angle_deg": rad_to_deg(acos(clampf(backbone_axis.dot(toward_rod), -1.0, 1.0))),
		"backbone_axis_step_deg": axis_step_deg,
		"backbone_tilt_from_gravity_deg": rad_to_deg(acos(clampf(backbone_axis.dot(Vector3.UP), -1.0, 1.0))),
		"backbone_axis_motion_alignment": axis_motion_alignment,
		"incoming_external_tangent": incoming_direction,
		"outgoing_backbone_tangent": outgoing_direction,
		"mainline_outward_dir": incoming_direction,
		"rig_downward_dir": outgoing_direction,
		"external_to_backbone_angle_deg": angle_deg,
		"mesh_connection_error_m": connection_error,
		"centerline_vertex_count": centerline.size(),
		"backbone_centerline_vertex_count": backbone_centerline.size(),
		"backbone_axis_alignment_dot": outgoing_direction.dot(-backbone_axis) if outgoing_direction.length_squared() > 0.5 else -1.0,
		"sinker_height_above_surface_m": float(water_data.get("sinker_height_above_surface_m", 0.0)),
		"hook_above_surface_count": above_count,
		"hook_below_surface_count": below_count,
		"partial_tackle_emergence": above_count > 0 and below_count > 0 and float(water_data.get("sinker_height_above_surface_m", 0.0)) < 0.0,
		"rig_root_world": rig_root.global_position if rig_root != null else Vector3.ZERO,
		"rig_root_basis_y": backbone_axis,
		"bait_velocity_world": snapshot.get("lure_velocity_world_mps", Vector3.ZERO),
		"bait_velocity_private_world": bait_velocity,
		"bait_acceleration_world_mps2": bait_acceleration,
		"boat_velocity_estimate_world_mps": boat_velocity,
		"water_current_sampled": false,
		"backbone_orientation_input": "gravity_boat_flow_and_cast_motion" if casting.get_casting_state() == BoatFishingCastingSystem.CastState.CASTING else "gravity_boat_flow_plus_top_eye_line_load",
		"hook_surface_clearances_m": water_data.get("hook_surface_clearances_m", []),
		"external_mainline_path_length_m": _measure_polyline_length(centerline),
	}


func _nearest_point_on_polyline_distance(point: Vector3, polyline: Array[Vector3]) -> float:
	var nearest_distance := INF
	for segment_index in range(polyline.size() - 1):
		var start := polyline[segment_index]
		var end := polyline[segment_index + 1]
		var segment := end - start
		var segment_length_sq := segment.length_squared()
		var t := clampf((point - start).dot(segment) / segment_length_sq, 0.0, 1.0) if segment_length_sq > 0.000001 else 0.0
		nearest_distance = minf(nearest_distance, point.distance_to(start + segment * t))
	return nearest_distance


func _capture_sabiki_component_views(
	case_id: String,
	casting: BoatFishingCastingSystem,
	line_instance: MeshInstance3D
) -> void:
	var rig_root := casting.find_child("SabikiRigVisual", true, false) as Node3D
	var backbone := casting.find_child("SabikiBackboneLine", true, false) as MeshInstance3D
	if rig_root == null or backbone == null:
		return
	var was_paused := paused
	paused = true
	var frozen_sample := _collect_sample(case_id, casting, line_instance, Engine.max_fps)
	frozen_sample["capture_kind"] = "frozen_components"
	_write_sample(frozen_sample)
	await RenderingServer.frame_post_draw
	get_root().get_texture().get_image().save_png(_capture_path("%s_frozen_full" % case_id))
	var marker := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.025
	sphere.height = 0.05
	marker.mesh = sphere
	var marker_material := StandardMaterial3D.new()
	marker_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	marker_material.albedo_color = Color.MAGENTA
	marker.material_override = marker_material
	casting.add_child(marker)
	marker.global_position = casting.call("_get_tackle_line_connection_world")
	await RenderingServer.frame_post_draw
	get_root().get_texture().get_image().save_png(_capture_path("%s_top_eye_marked" % case_id))
	marker.free()
	var rig_was_visible := rig_root.visible
	var line_was_visible := line_instance.visible
	var casting_was_processing := casting.is_processing()
	var casting_was_physics_processing := casting.is_physics_processing()
	casting.set_process(false)
	casting.set_physics_process(false)
	rig_root.visible = false
	await RenderingServer.frame_post_draw
	get_root().get_texture().get_image().save_png(_capture_path("%s_mainline_only" % case_id))
	rig_root.visible = rig_was_visible
	line_instance.visible = false
	await RenderingServer.frame_post_draw
	get_root().get_texture().get_image().save_png(_capture_path("%s_terminal_rig_only" % case_id))
	line_instance.visible = line_was_visible
	var child_visibility: Array[bool] = []
	for child in rig_root.get_children():
		child_visibility.append(child.visible if child is Node3D else true)
		if child != backbone and child is Node3D:
			child.visible = false
	await RenderingServer.frame_post_draw
	get_root().get_texture().get_image().save_png(_capture_path("%s_mainline_and_backbone" % case_id))
	for child_index in range(mini(rig_root.get_child_count(), child_visibility.size())):
		var child := rig_root.get_child(child_index)
		if child is Node3D:
			child.visible = child_visibility[child_index]
	rig_root.visible = rig_was_visible
	line_instance.visible = line_was_visible
	paused = was_paused
	casting.set_process(casting_was_processing)
	casting.set_physics_process(casting_was_physics_processing)


func _read_actual_mesh_centerline(line_instance: MeshInstance3D) -> Array[Vector3]:
	var result: Array[Vector3] = []
	var immediate := line_instance.mesh as ImmediateMesh
	if immediate.get_surface_count() <= 0:
		return result
	var arrays := immediate.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var vertices_per_segment := BoatFishingCastingSystem.LINE_SIDES * 6
	if vertices_per_segment <= 0 or vertices.size() % vertices_per_segment != 0:
		return result
	var segment_count := vertices.size() / vertices_per_segment
	for segment_index in range(segment_count):
		var start_sum := Vector3.ZERO
		var end_sum := Vector3.ZERO
		for side_index in range(BoatFishingCastingSystem.LINE_SIDES):
			var base := segment_index * vertices_per_segment + side_index * 6
			start_sum += vertices[base] + vertices[base + 3] + vertices[base + 5]
			end_sum += vertices[base + 1] + vertices[base + 2] + vertices[base + 4]
		var divisor := float(BoatFishingCastingSystem.LINE_SIDES * 3)
		var start_world := line_instance.to_global(start_sum / divisor)
		var end_world := line_instance.to_global(end_sum / divisor)
		if result.is_empty() or result[-1].distance_to(start_world) > 0.0001:
			result.append(start_world)
		if result[-1].distance_to(end_world) > 0.0001:
			result.append(end_world)
	return result


func _find_nearest_point_index(points: Array[Vector3], target: Vector3) -> int:
	var best_index := -1
	var best_distance := INF
	for index in range(points.size()):
		var distance := points[index].distance_to(target)
		if distance < best_distance:
			best_distance = distance
			best_index = index
	return best_index if best_distance <= 0.05 else -1


func _nearest_point_distance(points: Array[Vector3], target: Vector3) -> float:
	var best_distance := INF
	for point in points:
		best_distance = minf(best_distance, point.distance_to(target))
	return best_distance


func _count_nodes_named(parent: Node, target_name: String) -> int:
	var count := 0
	for node in parent.find_children("*", "Node", true, false):
		if node.name == target_name:
			count += 1
	return count


func _measure_polyline_length(points: Array[Vector3]) -> float:
	var total := 0.0
	for index in range(points.size() - 1):
		total += points[index].distance_to(points[index + 1])
	return total


func _get_water_heights(casting: BoatFishingCastingSystem) -> Dictionary:
	var sinker: Vector3 = casting.call("get_sinker_world_position")
	var sinker_surface := float(casting.call("_sample_water", sinker).get("height", sinker.y))
	var above_count := 0
	var below_count := 0
	var hook_surface_clearances: Array[float] = []
	for hook_position in casting.call("get_hook_attachment_world_positions"):
		var surface_y := float(casting.call("_sample_water", hook_position).get("height", hook_position.y))
		hook_surface_clearances.append(hook_position.y - surface_y)
		if hook_position.y >= surface_y:
			above_count += 1
		else:
			below_count += 1
	return {
		"sinker_height_above_surface_m": sinker.y - sinker_surface,
		"above_hook_count": above_count,
		"below_hook_count": below_count,
		"hook_surface_clearances_m": hook_surface_clearances,
	}


func _capture_path(name: String) -> String:
	return "/tmp/p6_4_6_0_7_%s_%s.png" % [_capture_label, name]


func _write_sample(sample: Dictionary) -> void:
	_output.store_line(JSON.stringify(sample))


func _write_summary(summary: Dictionary) -> void:
	_output.store_line(JSON.stringify(summary))
	print("[P6.4.6.0.7][SUMMARY] %s" % JSON.stringify(summary))


func _is_gpu_runtime() -> bool:
	return DisplayServer.get_name() != "headless"


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[P6.4.6.0.7][PASS] %s" % message)
	else:
		_failures += 1
		printerr("[P6.4.6.0.7][FAIL] %s" % message)
