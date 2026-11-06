extends SceneTree

const MAIN_SCENE: PackedScene = preload("res://scenes/main.tscn")
const SABIKI_PROFILE: BoatFishingRigProfile = preload("res://resources/boat_fishing/sabiki_rig.tres")
const SINGLE_JIG_PROFILE: BoatFishingRigProfile = preload("res://resources/boat_fishing/single_jig.tres")
const SAMPLE_PATH := "/tmp/p6_4_6_1_3_sabiki_single_line.ndjson"

var _failures := 0
var _samples: FileAccess
var _previous_sample_usec := 0
var _maximum_sabiki_upward_deviation_m := 0.0
var _minimum_sabiki_adjacent_segment_dot := 1.0
var _minimum_sabiki_hook_spacing_ratio := 1.0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_samples = FileAccess.open(SAMPLE_PATH, FileAccess.WRITE)
	_check(_samples != null, "Diagnostic sample file opens")
	_test_profile_path_stations()
	if _samples == null:
		quit(1)
		return

	var main := MAIN_SCENE.instantiate()
	root.add_child(main)
	for _frame in range(30):
		await physics_frame

	var onboard := main.get_node_or_null("PlayerBoat/MotionRoot/VisualRoot/OnboardActivityController") as OnboardActivityController
	var boat := main.get_node_or_null("PlayerBoat/MotionRoot") as BoatController
	var casting := main.get_node_or_null("PlayerBoat/BoatFishingCastingSystem") as BoatFishingCastingSystem
	var activities_button := main.find_child("ActivitiesButton", true, false) as Button
	var fishing_button := main.find_child("OpenBoatFishingActivity", true, false) as Button
	_check(onboard != null and boat != null and casting != null and activities_button != null and fishing_button != null,
		"Production scene exposes the normal activity, casting and boat controllers")
	if onboard == null or boat == null or casting == null or activities_button == null or fishing_button == null:
		_samples.close()
		quit(1)
		return

	activities_button.pressed.emit()
	fishing_button.pressed.emit()
	await process_frame
	_check(casting.is_activity_active() and onboard.is_first_person_active(), "Boat Fishing starts through the production HUD")
	if not casting.is_activity_active():
		_samples.close()
		quit(1)
		return

	boat.is_autopilot = false
	boat.speed_mps = 0.0
	var player := onboard.find_child("OnboardActivityPlayer", true, false) as CharacterBody3D
	var head_pivot := onboard.find_child("HeadPivot", true, false) as Node3D
	if player != null and onboard.profile != null:
		var player_position := Vector3(0.53, onboard.profile.deck_height_m, 1.28)
		onboard.set("_player_local_position", player_position)
		player.position = player_position
		onboard.set("_player_local_yaw", -PI * 0.5)
		onboard.set("_look_pitch", -0.34)
		if head_pivot != null:
			head_pivot.rotation.x = -0.34
		onboard.call("_set_player_transform_from_hull")

	var gpu_runtime := DisplayServer.get_name() != "headless"
	if gpu_runtime:
		# Keep the project viewport's 16:9 canvas scale. A smaller ad-hoc window
		# introduces a mismatched HUD scale and makes the capture unsuitable for
		# visual review.
		DisplayServer.window_set_size(Vector2i(1600, 900))
		await process_frame
		await RenderingServer.frame_post_draw
		await process_frame
	Engine.max_fps = 30 if gpu_runtime else 60
	for profile in [SINGLE_JIG_PROFILE, SABIKI_PROFILE]:
		await _run_normal_cast_and_retrieve(casting, onboard, boat, profile, gpu_runtime)
	_check(_maximum_sabiki_upward_deviation_m <= 0.005, "Sabiki free-line path has no measurable upward arch relative to its A-to-C chord")
	_check(_minimum_sabiki_adjacent_segment_dot > -0.05, "Sabiki free-line samples contain no local direction reversal")
	Engine.max_fps = 0
	_samples.flush()
	_samples.close()
	print("[P6.4.6.1.3] samples=%s failures=%d gpu=%s" % [SAMPLE_PATH, _failures, str(gpu_runtime)])
	main.queue_free()
	await process_frame
	quit(1 if _failures > 0 else 0)


func _test_profile_path_stations() -> void:
	var rod_tip := Vector3(0.0, 2.8, 0.0)
	var sinker := Vector3(0.7, 1.8, 0.15)
	var prefix := PackedVector3Array([Vector3(-0.2, 3.0, 0.0), rod_tip])
	var route := PackedVector3Array([rod_tip, sinker])
	var snapshot := BoatFishingCastingSystem.generate_fishing_line_path(
		prefix,
		route,
		route,
		PackedVector2Array(),
		0.0,
		{
			"taut": false,
			"slack_ratio": 1.0,
			"airborne": false,
			"sabiki_rig": {
				"length_m": SABIKI_PROFILE.get_line_attachment_height_m(),
				"bottom_leader_m": SABIKI_PROFILE.bottom_leader_length_m,
				"hook_spacing_m": SABIKI_PROFILE.hook_spacing_m,
				"hook_count": SABIKI_PROFILE.hook_count,
			},
		}
	)
	var points: PackedVector3Array = snapshot.get("centerline_points", PackedVector3Array())
	var lengths: PackedFloat32Array = snapshot.get("cumulative_lengths", PackedFloat32Array())
	var stations: Dictionary = snapshot.get("stations", {})
	var ordered := ["hook_1", "hook_2", "hook_3", "hook_4", "hook_5"]
	var all_stations_valid := points.size() >= 2 and stations.has("rod_tip") and stations.has("sinker")
	var previous_arc := -INF
	for name in ordered:
		all_stations_valid = all_stations_valid and stations.has(name)
		if not stations.has(name):
			continue
		var station: Dictionary = stations[name]
		var position: Vector3 = station.get("position", Vector3.INF)
		var tangent: Vector3 = station.get("tangent", Vector3.ZERO)
		var arc := float(station.get("arc_length_m", -1.0))
		all_stations_valid = all_stations_valid and position.is_finite() and tangent.is_finite() and absf(tangent.length() - 1.0) < 0.002 and arc > previous_arc
		all_stations_valid = all_stations_valid and _distance_to_polyline(position, points) <= 0.002
		previous_arc = arc
	_check(all_stations_valid, "Sabiki uses one finite A-to-C path with five ordered hook stations on its centerline")
	_check(
		stations.has("line_end") and not stations.has("terminal_eye") and not stations.has("sabiki_top_eye"),
		"Sabiki path has a generic A-to-C end station and no top-eye station or alias"
	)
	if ordered.size() == SABIKI_PROFILE.hook_count and stations.size() >= SABIKI_PROFILE.hook_count:
		var spacing_valid := true
		var expected_spacing := SABIKI_PROFILE.hook_spacing_m
		for index in range(ordered.size() - 1):
			var upper: Dictionary = stations[ordered[index]]
			var lower: Dictionary = stations[ordered[index + 1]]
			spacing_valid = spacing_valid and absf(float(lower["arc_length_m"]) - float(upper["arc_length_m"]) - expected_spacing) < 0.002
		_check(spacing_valid, "Five hook stations preserve RigProfile arc spacing on the generated path")
	var short_chords_valid := true
	for chord_m in [0.05, 0.25, 0.75, 1.25, 1.8, 2.04, 2.06, 2.08]:
		var short_end := rod_tip + Vector3(chord_m, -0.25, 0.0)
		var short_route := PackedVector3Array([rod_tip, short_end])
		var short_snapshot := BoatFishingCastingSystem.generate_fishing_line_path(
			PackedVector3Array([rod_tip]),
			short_route,
			short_route,
			PackedVector2Array(),
			0.0,
			{
				"taut": true,
				"slack_ratio": 0.0,
				"airborne": false,
				"sabiki_rig": {
					"length_m": SABIKI_PROFILE.get_line_attachment_height_m(),
					"bottom_leader_m": SABIKI_PROFILE.bottom_leader_length_m,
					"hook_spacing_m": SABIKI_PROFILE.hook_spacing_m,
					"hook_count": SABIKI_PROFILE.hook_count,
				},
			}
		)
		var short_stations: Dictionary = short_snapshot.get("stations", {})
		var short_points: PackedVector3Array = short_snapshot.get("centerline_points", PackedVector3Array())
		var short_lengths: PackedFloat32Array = short_snapshot.get("cumulative_lengths", PackedFloat32Array())
		var short_rod_s := float(short_stations.get("rod_tip", {}).get("arc_length_m", INF))
		var short_sinker_s := float(short_stations.get("sinker", {}).get("arc_length_m", -INF))
		var required_hook_reach := SABIKI_PROFILE.bottom_leader_length_m + float(SABIKI_PROFILE.hook_count - 1) * SABIKI_PROFILE.hook_spacing_m
		short_chords_valid = short_chords_valid and short_sinker_s - short_rod_s + 0.002 >= required_hook_reach
		short_chords_valid = short_chords_valid and short_lengths.size() == short_points.size() and short_points.size() >= 2
		for hook_index in range(SABIKI_PROFILE.hook_count):
			var station_name := "hook_%d" % (hook_index + 1)
			short_chords_valid = short_chords_valid and short_stations.has(station_name)
			if not short_stations.has(station_name):
				continue
			var hook_s := float(short_stations[station_name].get("arc_length_m", -INF))
			short_chords_valid = short_chords_valid and hook_s >= short_rod_s - 0.002 and hook_s <= short_sinker_s + 0.002
	_check(short_chords_valid, "Short A-to-C spans preserve the full RigProfile hook spacing without clamping stations at the rod tip")


func _run_normal_cast_and_retrieve(
	casting: BoatFishingCastingSystem,
	onboard: OnboardActivityController,
	boat: BoatController,
	profile: BoatFishingRigProfile,
	gpu_runtime: bool
) -> void:
	casting.clear_cast()
	_check(casting.select_rig(profile.rig_id), "%s can be selected in READY" % str(profile.rig_id))
	boat.is_autopilot = false
	boat.speed_mps = 0.0
	casting.set("_boat_velocity_estimate_world", Vector3.ZERO)
	casting.set("_previous_boat_world", boat.global_position)
	if onboard.profile != null:
		var player_position := Vector3(0.53, onboard.profile.deck_height_m, 1.28)
		onboard.set("_player_local_position", player_position)
		onboard.set("_player_local_yaw", -PI * 0.5)
		onboard.call("_set_player_transform_from_hull")
	_check(casting.begin_charge(), "%s enters CHARGING through the production API" % str(profile.rig_id))
	if casting.get_casting_state() != BoatFishingCastingSystem.CastState.CHARGING:
		return
	casting.set("_charge_elapsed", 0.12)
	casting.call("_set_charge_pose", 0.12)
	if onboard.profile != null:
		onboard.set("_player_local_yaw", -PI * 0.5 + 0.08)
		onboard.call("_set_player_transform_from_hull")
	_check(casting.release_charge(), "%s enters CASTING through release_charge()" % str(profile.rig_id))
	if casting.get_casting_state() != BoatFishingCastingSystem.CastState.CASTING:
		return

	var line_instance := casting.find_child("BoatFishingLine", true, false) as MeshInstance3D
	_check(line_instance != null, "%s uses the single shared free-line Mesh" % str(profile.rig_id))
	if line_instance == null:
		return
	var is_sabiki := profile.rig_type == BoatFishingRigProfile.RigType.SABIKI
	if is_sabiki:
		_check(_count_named(casting, "BoatFishingLine") == 1, "Sabiki renders exactly one free-line Mesh")
		_check(_count_named(casting, "SabikiRodSideEye") == 0, "Sabiki has no top-eye visual node")
		_check(_count_named(casting, "SabikiBackboneLine") == 0, "Sabiki has no second backbone Mesh")
		_check(_count_named(casting, "SabikiBranchLine") == profile.hook_count, "Sabiki keeps one branch per configured hook")

	var start_usec := Time.get_ticks_usec()
	var frames := 0
	var reached_waiting := false
	var capture_cast := false
	while Time.get_ticks_usec() - start_usec < 10_000_000:
		await process_frame
		frames += 1
		if casting.get_casting_state() == BoatFishingCastingSystem.CastState.CASTING:
			var sample := _capture_sample("cast", casting, profile, frames)
			if not sample.is_empty():
				_write_sample(sample)
				if bool(casting.get("_bait_flight_started")):
					var debug := casting.get_debug_snapshot()
					var chord := float(debug.get("endpoint_chord_m", INF))
					var allowed := float(debug.get("effective_physical_line_length_m", -1.0))
					_check(chord <= allowed + 0.002, "%s cast endpoint remains within paid plus fixed rig length" % str(profile.rig_id))
			if gpu_runtime and not capture_cast and float(casting.get("_bait_flight_elapsed")) > 0.25:
				await _save_frame("sabiki_airborne_cast" if is_sabiki else "single_jig_airborne_cast")
				capture_cast = true
		if casting.get_casting_state() == BoatFishingCastingSystem.CastState.WAITING:
			reached_waiting = true
			break
	_check(reached_waiting, "%s reaches WAITING in the real cast state machine" % str(profile.rig_id))
	if not reached_waiting:
		casting.clear_cast()
		return

	var waiting_sample := _capture_sample("waiting", casting, profile, frames)
	_write_sample(waiting_sample)
	if gpu_runtime:
		await _save_frame("sabiki_waiting" if is_sabiki else "single_jig_waiting")
	var waiting_debug := casting.get_debug_snapshot()
	_check(
		float(waiting_debug.get("endpoint_chord_m", INF)) <= float(waiting_debug.get("effective_physical_line_length_m", -1.0)) + 0.002,
		"WAITING sinker respects the A-to-C total physical reach"
	)
	if is_sabiki:
		var path: Dictionary = casting.get("_main_line_path_snapshot")
		var points: PackedVector3Array = path.get("centerline_points", PackedVector3Array())
		var hook_roots: Array = casting.call("get_rig_hook_positions")
		var station_match := hook_roots.size() == profile.hook_count
		for index in range(hook_roots.size()):
			station_match = station_match and _distance_to_polyline(hook_roots[index], points) <= 0.002
		_check(station_match, "Visible Sabiki hook roots are sampled from the same rendered line path")
		_check(_count_named(casting, "SabikiRodSideEye") == 0 and _count_named(casting, "SabikiBackboneLine") == 0,
			"WAITING retains no hidden top-eye or second line component")

	var initial_paid := float(casting.get("_line_paid_out_length_m"))
	var captured_fully_above := false
	if initial_paid > 0.8 and casting.set_manual_reeling(true, true):
		var reel_start := Time.get_ticks_usec()
		while Time.get_ticks_usec() - reel_start < 4_000_000 and float(casting.get("_line_paid_out_length_m")) > initial_paid * 0.55:
			await process_frame
		var halfway_sample := _capture_sample("manual_reel", casting, profile, frames)
		_write_sample(halfway_sample)
		if gpu_runtime:
			await _save_frame("sabiki_manual_reel" if is_sabiki else "single_jig_manual_reel")
		casting.set_manual_reeling(false, true)
		var release_samples := 0
		for _frame in range(4):
			await process_frame
			var released := _capture_sample("reel_released", casting, profile, frames)
			if not released.is_empty():
				_write_sample(released)
				release_samples += 1
		_check(release_samples > 0, "%s release phase is sampled after manual reeling stops" % str(profile.rig_id))
		if gpu_runtime:
			await _save_frame("sabiki_reel_released" if is_sabiki else "single_jig_reel_released")
		casting.set_manual_reeling(true, true)
		var retrieve_start := Time.get_ticks_usec()
		while Time.get_ticks_usec() - retrieve_start < 12_000_000:
			await process_frame
			var sample := _capture_sample("retrieve", casting, profile, frames)
			if not sample.is_empty():
				_write_sample(sample)
			if is_sabiki and not captured_fully_above and casting.call("_is_tackle_fully_above_surface", 0.0):
				_write_sample(_capture_sample("all_rig_above_surface", casting, profile, frames))
				if gpu_runtime:
					await _save_frame("sabiki_all_rig_above_surface")
				captured_fully_above = true
			if casting.get_casting_state() in [BoatFishingCastingSystem.CastState.RETRIEVING, BoatFishingCastingSystem.CastState.READY]:
				if gpu_runtime:
					await _save_frame("sabiki_final_retrieval" if is_sabiki else "single_jig_final_retrieval")
				break
		casting.set_manual_reeling(false, true)
		_check(casting.get_casting_state() in [BoatFishingCastingSystem.CastState.RETRIEVING, BoatFishingCastingSystem.CastState.READY],
			"%s reaches the final retrieval handoff" % str(profile.rig_id))
		if casting.get_casting_state() == BoatFishingCastingSystem.CastState.RETRIEVING:
			var handoff_paid := float(casting.get("_line_paid_out_length_m"))
			var retrieve_begin_usec := Time.get_ticks_usec()
			while Time.get_ticks_usec() - retrieve_begin_usec < 5_000_000 and casting.get_casting_state() == BoatFishingCastingSystem.CastState.RETRIEVING:
				await process_frame
				var sample := _capture_sample("retrieving", casting, profile, frames)
				if not sample.is_empty():
					_write_sample(sample)
				if is_sabiki and not captured_fully_above and casting.call("_is_tackle_fully_above_surface", 0.0):
					_write_sample(_capture_sample("all_rig_above_surface", casting, profile, frames))
					if gpu_runtime:
						await _save_frame("sabiki_all_rig_above_surface")
					captured_fully_above = true
			_check(casting.get_casting_state() == BoatFishingCastingSystem.CastState.READY,
					"%s final display retrieval completes to READY" % str(profile.rig_id))
			_check(float(casting.get("_line_paid_out_length_m")) <= 0.001, "Presentation handoff finishes at zero paid line without deriving it from C")
			_check(handoff_paid >= 0.0, "Final retrieval enters with a defined paid-line value")
			_check(not line_instance.visible, "Free-line Mesh hides after final retrieval")
	else:
		casting.set_manual_reeling(false, true)
	_check(initial_paid > 0.0, "%s keeps a positive paid line after the real cast" % str(profile.rig_id))
	if is_sabiki:
		_check(captured_fully_above, "Sabiki reaches a fully emerged hook-and-sinker state before final retrieval")
		_check(_minimum_sabiki_hook_spacing_ratio >= 0.85,
			"Sabiki hooks retain evenly scaled local spacing across short-line cast, reel, release, and retrieval samples")

	if casting.get_casting_state() == BoatFishingCastingSystem.CastState.READY:
		_check(casting.select_rig(profile.rig_id), "%s remains selectable after retrieval" % str(profile.rig_id))
		_check(casting.begin_charge(), "%s can begin another cast after retrieval" % str(profile.rig_id))
		casting.cancel_charge_immediately()
	casting.clear_cast()


func _capture_sample(phase: String, casting: BoatFishingCastingSystem, profile: BoatFishingRigProfile, frame: int) -> Dictionary:
	if not casting.is_cast_active() or not bool(casting.get("_bait_flight_started")):
		return {}
	casting.call("_update_line_and_bait_visuals")
	var debug := casting.get_debug_snapshot()
	var rod_tip: Vector3 = casting.call("_get_rod_tip_world")
	var sinker: Vector3 = casting.get("_bait_world")
	var terminal: Vector3 = casting.call("_get_main_line_terminal_world")
	var points: PackedVector3Array = (casting.get("_main_line_path_snapshot") as Dictionary).get("centerline_points", PackedVector3Array())
	var path_length := _path_length(points)
	var hook_roots: Array = casting.call("get_rig_hook_positions") if profile.rig_type == BoatFishingRigProfile.RigType.SABIKI else []
	var hook_tips: Array = casting.call("get_hook_attachment_world_positions") if profile.rig_type == BoatFishingRigProfile.RigType.SABIKI else []
	var visual_state: Dictionary = casting.call("_get_main_line_visual_state")
	var timestamp_usec := Time.get_ticks_usec()
	var sample_delta_usec := timestamp_usec - _previous_sample_usec if _previous_sample_usec > 0 else 0
	_previous_sample_usec = timestamp_usec
	var surface_clearances := PackedFloat32Array()
	for position in [sinker] + hook_tips:
		surface_clearances.append(position.y - float(casting.call("_sample_water", position).get("height", position.y)))
	var stations: Dictionary = (casting.get("_main_line_path_snapshot") as Dictionary).get("stations", {})
	var chord_shape := _get_free_line_shape_metrics(points, stations, rod_tip, sinker)
	if profile.rig_type == BoatFishingRigProfile.RigType.SABIKI:
		_maximum_sabiki_upward_deviation_m = maxf(_maximum_sabiki_upward_deviation_m, float(chord_shape["max_upward_m"]))
		_minimum_sabiki_adjacent_segment_dot = minf(_minimum_sabiki_adjacent_segment_dot, float(chord_shape["min_adjacent_dot"]))
	var hook_material_distances := PackedFloat32Array()
	var hook_geometry_distances := PackedFloat32Array()
	for hook_index in range(hook_roots.size()):
		var station_name := "hook_%d" % (hook_index + 1)
		var station: Dictionary = stations.get(station_name, {})
		hook_material_distances.append(float(station.get("profile_material_distance_from_sinker_m", 0.0)))
		hook_geometry_distances.append(
			float(stations.get("sinker", {}).get("arc_length_m", 0.0))
			- float(station.get("arc_length_m", 0.0))
		)
	if profile.rig_type == BoatFishingRigProfile.RigType.SABIKI and hook_geometry_distances.size() == profile.hook_count and profile.hook_spacing_m > 0.0001:
		for hook_index in range(hook_geometry_distances.size() - 1):
			var interval_m := float(hook_geometry_distances[hook_index]) - float(hook_geometry_distances[hook_index + 1])
			_minimum_sabiki_hook_spacing_ratio = minf(
				_minimum_sabiki_hook_spacing_ratio,
				interval_m / profile.hook_spacing_m
			)
	var sample := {
		"phase": phase,
		"rig_id": profile.rig_id,
		"frame": frame,
		"timestamp_usec": timestamp_usec,
		"sample_delta_seconds": float(sample_delta_usec) / 1_000_000.0,
		"estimated_sample_fps": 1_000_000.0 / float(sample_delta_usec) if sample_delta_usec > 0 else 0.0,
		"state": casting.get_casting_state_name(),
		"rod_tip_world": rod_tip,
		"sinker_world": sinker,
		"paid_line_length_m": float(casting.get("_line_paid_out_length_m")),
		"rig_length_m": profile.get_line_attachment_height_m() if profile.rig_type == BoatFishingRigProfile.RigType.SABIKI else 0.0,
		"effective_length_m": float(debug.get("effective_physical_line_length_m", 0.0)),
		"endpoint_chord_m": rod_tip.distance_to(terminal),
		"endpoint_excess_m": maxf(0.0, rod_tip.distance_to(terminal) - float(debug.get("effective_physical_line_length_m", 0.0))),
		"constraint_max_excess_m": float(debug.get("sabiki_max_active_endpoint_excess_m", 0.0)),
		"constraint_feasible": bool(debug.get("sabiki_reachability_constraint_feasible", true)),
		"manual_reeling": bool(debug.get("manual_reeling", false)),
		"manual_line_releasing": bool(debug.get("manual_line_releasing", false)),
		"tension": float(debug.get("line_tension", 0.0)),
		"line_taut": bool(visual_state.get("taut", false)),
		"line_slack_ratio": float(visual_state.get("slack_ratio", 0.0)),
		"visual_path_length_m": path_length,
		"free_line_geometry_length_m": float((casting.get("_main_line_path_snapshot") as Dictionary).get("free_line_geometry_length_m", 0.0)),
		"line_max_upward_deviation_m": float(chord_shape["max_upward_m"]),
		"line_max_downward_deviation_m": float(chord_shape["max_downward_m"]),
		"line_max_lateral_deviation_m": float(chord_shape["max_lateral_m"]),
		"line_min_adjacent_segment_dot": float(chord_shape["min_adjacent_dot"]),
		"hook_roots_world": hook_roots,
		"hook_tips_world": hook_tips,
		"hook_profile_material_distances_from_sinker_m": hook_material_distances,
		"hook_geometry_distances_from_sinker_m": hook_geometry_distances,
		"rig_visual_station_scale": float((casting.get("_main_line_path_snapshot") as Dictionary).get("rig_visual_station_scale", 1.0)),
		"sinker_and_hook_surface_clearances_m": surface_clearances,
		"all_rig_points_above_surface": bool(casting.call("_is_tackle_fully_above_surface", 0.0)) if profile.rig_type == BoatFishingRigProfile.RigType.SABIKI else false,
		"root_to_line_errors_m": hook_roots.map(func(position: Vector3) -> float: return _distance_to_polyline(position, points)),
	}
	return sample


func _get_free_line_shape_metrics(
	points: PackedVector3Array,
	stations: Dictionary,
	start: Vector3,
	end: Vector3
) -> Dictionary:
	var result := {
		"max_upward_m": 0.0,
		"max_downward_m": 0.0,
		"max_lateral_m": 0.0,
		"min_adjacent_dot": 1.0,
	}
	if points.size() < 2 or not stations.has("rod_tip") or not stations.has("line_end"):
		return result
	var first_index := clampi(int(stations["rod_tip"].get("index", 0)), 0, points.size() - 1)
	var last_index := clampi(int(stations["line_end"].get("index", points.size() - 1)), first_index, points.size() - 1)
	var chord := end - start
	var chord_squared := chord.length_squared()
	for index in range(first_index, last_index + 1):
		var t := clampf((points[index] - start).dot(chord) / maxf(chord_squared, 0.000001), 0.0, 1.0)
		var deviation := points[index] - start.lerp(end, t)
		var vertical := deviation.dot(Vector3.UP)
		result["max_upward_m"] = maxf(float(result["max_upward_m"]), vertical)
		result["max_downward_m"] = maxf(float(result["max_downward_m"]), -vertical)
		var lateral := deviation - Vector3.UP * vertical
		result["max_lateral_m"] = maxf(float(result["max_lateral_m"]), lateral.length())
		if index > first_index:
			var previous_segment := (points[index] - points[index - 1]).normalized()
			if index < last_index:
				var next_segment := (points[index + 1] - points[index]).normalized()
				result["min_adjacent_dot"] = minf(float(result["min_adjacent_dot"]), previous_segment.dot(next_segment))
	return result


func _distance_to_polyline(position: Vector3, points: PackedVector3Array) -> float:
	var nearest := INF
	for index in range(points.size() - 1):
		var segment := points[index + 1] - points[index]
		var t := clampf((position - points[index]).dot(segment) / maxf(segment.length_squared(), 0.000001), 0.0, 1.0)
		nearest = minf(nearest, position.distance_to(points[index].lerp(points[index + 1], t)))
	return nearest


func _path_length(points: PackedVector3Array) -> float:
	var total := 0.0
	for index in range(points.size() - 1):
		total += points[index].distance_to(points[index + 1])
	return total


func _count_named(parent: Node, node_name: String) -> int:
	var count := 0
	if parent.name == node_name:
		count += 1
	for child in parent.get_children():
		count += _count_named(child, node_name)
	return count


func _write_sample(sample: Dictionary) -> void:
	if _samples == null or sample.is_empty():
		return
	_samples.store_line(JSON.stringify(sample))


func _save_frame(name: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var directory := "res://reports/p6_4_6_1_3/after"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	image.save_png(ProjectSettings.globalize_path(directory.path_join("%s.png" % name)))


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		printerr("FAIL: %s" % message)
	else:
		print("PASS: %s" % message)
