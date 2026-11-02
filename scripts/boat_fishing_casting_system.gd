class_name BoatFishingCastingSystem
extends Node3D

## Lightweight P6.2 casting presentation. The rod is hull-local, while the
## bait is integrated in world space and only sampled against the shared waves.

signal state_changed(state_name: String, status_key: String, hint_key: String)
signal feedback_requested(message_key: String)
signal charge_progress_changed(progress: float, visible: bool)
signal interaction_updated(snapshot: Dictionary)

enum CastState { READY, CHARGING, CASTING, WAITING, SABIKI_HOOKED_WAITING, RETRIEVING, BITE_APPROACH, FIGHTING, CATCH_PRESENTATION }

const ROD_BEND_SHADER := preload("res://shaders/boat_fishing_rod_bend.gdshader")
const SINGLE_JIG_PROFILE: BoatFishingRigProfile = preload("res://resources/boat_fishing/single_jig.tres")
const SABIKI_RIG_PROFILE: BoatFishingRigProfile = preload("res://resources/boat_fishing/sabiki_rig.tres")
const ROD_LENGTH_M := 1.78
const ROD_AXIS_LOCAL := Vector3(0.0, 0.26004, -0.9656)
const HANDHELD_FIRST_GUIDE_PROGRESS := 0.50
const CAST_BAIT_RELEASE_OFFSET_SECONDS := 0.19
const RETRIEVE_DURATION_SECONDS := 0.72
const BAIT_WATER_DRAG_FOLLOW := 0.78
const BAIT_WATER_DRAG_RESPONSE := 1.25
const BAIT_SINK_ACCELERATION_MPS2 := 2.6
const AIRBORNE_BAIT_GRAVITY_MPS2 := 5.2
const AIRBORNE_BAIT_DAMPING_PER_SECOND := 1.65
const AIRBORNE_BAIT_SURFACE_CLEARANCE_M := 0.025
const AIRBORNE_LINE_VISUAL_SAG_M := 0.18
const SEABED_CLEARANCE_M := 0.22
const LINE_RADIUS_M := FishingRodRig.LINE_RADIUS_M
const LINE_SIDES := 5
const LINE_SEGMENTS := 8
const SPOON_LENGTH_M := 0.085
const SPOON_WIDTH_M := 0.024
const SPOON_LINE_EYE_Y_M := 0.050
const SABIKI_HOOK_TUBE_RADIUS_M := 0.0022
const CHARGE_LIFT_TIME_SECONDS := 0.4
const CHARGE_MIDPOINT_SECONDS := 1.5
const CHARGE_CANCEL_DURATION_SECONDS := 0.24
const CAST_MIN_FLIGHT_TIME_SECONDS := 0.42
const CAST_MAX_FLIGHT_TIME_SECONDS := 1.18
const CAST_ARC_HEIGHT_M := 2.1
const SPLASH_DURATION_SECONDS := 0.55
const SABIKI_WATER_ENTRY_CLEARANCE_M := 0.025
const AIRBORNE_RIG_RELAX_DURATION_SECONDS := 0.65
const SABIKI_SLACK_LINE_MAX_SAG_M := 0.34
const BOAT_FISHING_AUDIO_OWNER := &"boat_fishing"
const REEL_LINE_DELTA_EPSILON_M := 0.0005
const MAX_AUTOMATIC_LINE_BURST_EXTRA_M := 5.0
const DEFAULT_CAST_MAX_DISTANCE_FROM_GUNWALE_M := 0.72
const DEFAULT_CAST_MIN_OUTWARD_ALIGNMENT := 0.55
const MINIMUM_MANUAL_RETRIEVAL_LINE_M := 0.08

@export_node_path("Node3D") var onboard_controller_path := NodePath("../MotionRoot/VisualRoot/OnboardActivityController")
@export_node_path("Node") var boat_controller_path := NodePath("../MotionRoot")
@export_node_path("Node") var fishing_audio_system_path := NodePath("../FishingRodSystem")
@export_node_path("Node") var wave_sampler_path := NodePath("../../WaveSampler")
@export_node_path("Node") var bathymetry_manager_path := NodePath("../../BathymetryManager")
@export_range(3.0, 25.0, 0.5) var minimum_cast_distance_m := 3.0
@export_range(5.0, 35.0, 0.5) var maximum_cast_distance_m := 25.0
@export_range(0.45, 1.2, 0.05) var cast_max_distance_from_gunwale_m := DEFAULT_CAST_MAX_DISTANCE_FROM_GUNWALE_M
@export_range(0.25, 0.9, 0.05) var cast_min_outward_alignment := DEFAULT_CAST_MIN_OUTWARD_ALIGNMENT
@export_range(26.0, 120.0, 1.0) var maximum_line_length_m := 100.0
@export_range(1.0, 5.0, 0.1) var cast_charge_full_time := 2.5
@export_range(0.3, 1.0, 0.01) var cast_release_duration := 0.55
@export_range(0.3, 1.2, 0.01) var cast_recovery_duration := 0.65
@export_range(45.0, 80.0, 1.0) var cast_max_back_angle_deg := 65.0
@export_range(12.0, 42.0, 1.0) var cast_full_bend_angle_deg := 30.0

@export_category("Manual handling")
@export_range(0.5, 2.5, 0.05) var manual_reel_speed_mps := 1.25
@export_range(0.5, 5.0, 0.1) var manual_line_release_speed_mps := 2.0
@export_range(0.1, 1.0, 0.05) var line_tension_slack_m := 0.45
@export_range(1.0, 10.0, 0.25) var line_pull_response := 5.0
@export_range(4.0, 18.0, 0.5) var rod_bend_at_full_tension_deg := 10.0
@export_range(0.08, 0.5, 0.01) var rod_aim_degrees_per_mouse_pixel := 0.22
@export_range(0.05, 0.35, 0.01) var terminal_tackle_recovery_margin_m := 0.16
@export_range(0.04, 0.2, 0.01) var cast_aim_preview_interval_seconds := 0.08
@export_category("Single jig encounters")
@export_range(0.2, 1.5, 0.1) var boat_fishing_sampling_interval_real_seconds := 0.5
@export_range(1.0, 10.0, 0.25) var shallow_bite_visual_depth_m := 6.0

var _onboard: OnboardActivityController
var _boat_controller: Node3D
var _wave_sampler: Node
var _bathymetry_manager: Node
var _fishing_audio_system: FishingRodSystem
var _fish_manager: FishResourceManager
var _encounter: FishingEncounterSystem
var _fish_school_renderer: FishSchoolRenderer
var _activity_active := false
var _state := CastState.READY
var _state_elapsed := 0.0
var _charge_elapsed := 0.0
var _charge_input_held := false
var _charge_canceling := false
var _charge_cancel_elapsed := 0.0
var _charge_cancel_start_back_deg := 0.0
var _charge_cancel_start_bend_deg := 0.0
var _waiting_elapsed := 0.0
var _cast_target_world := Vector3.ZERO
var _cast_start_world := Vector3.ZERO
var _bait_flight_elapsed := 0.0
var _bait_flight_duration := 0.0
var _bait_flight_started := false
var _bait_has_landed := false
var _cast_tackle_entry_complete := false
var _bait_airborne_retrieval := false
var _airborne_retrieval_elapsed := 0.0
var _sabiki_retrieval_taut := false
var _rod_recovery_complete := false
var _rod_back_angle_deg := 0.0
var _rod_bend_angle_deg := 0.0
var _rod_release_start_bend_deg := 0.0
var _splash_elapsed := 0.0
var _bait_world := Vector3.ZERO
var _bait_velocity_world := Vector3.ZERO
var _retrieve_start_world := Vector3.ZERO
var _line_paid_out_length_m := 0.0
var _manual_reeling := false
var _manual_reeling_from_ui := false
var _manual_reeling_input_held := false
var _manual_line_release_held := false
var _manual_line_releasing := false
var _line_controls_conflicted := false
var _automatic_control_owned := false
var _rod_aim_active := false
var _rod_aim_yaw_deg := 0.0
var _rod_aim_pitch_deg := 0.0
var _rod_tension := 0.0
var _previous_line_connection_world := Vector3.ZERO
var _has_previous_line_connection := false
var _previous_boat_world := Vector3.ZERO
var _boat_velocity_estimate_world := Vector3.ZERO
var _lure_visual_phase := 0.0
var _lure_visual_intensity := 0.0
var _lure_visual_basis_world := Basis.IDENTITY
var _rod_locked_position := Vector3.ZERO
var _rod_locked_rotation := Vector3.ZERO
var _rod_visual_root: Node3D
var _rod_swing: Node3D
var _rod_mesh_instance: MeshInstance3D
var _reel_mount: Node3D
var _reel_visual_root: Node3D
var _reel_rotating_assembly: Node3D
var _reel_winding_visual: MultiMeshInstance3D
var _rod_line_guides: Array[MeshInstance3D] = []
var _reel_visual_total_rotation_rad := 0.0
var _last_reel_line_delta_m := 0.0
var _requested_fishing_audio_loops := {"line_out": false, "drag": false, "reel_in": false}
var _fishing_audio_event_counts := {"splash": 0, "catch_success": 0}
var _played_success_audio_batches: Dictionary = {}
var _success_audio_batch_order: Array[String] = []
var _line_mesh: ImmediateMesh
var _line_instance: MeshInstance3D
var _line_material: StandardMaterial3D
var _cast_aim_marker: Node3D
var _cast_aim_marker_material: StandardMaterial3D
var _cast_aim_preview_elapsed := 0.0
var _bait_instance: MeshInstance3D
var _bait_material: StandardMaterial3D
var _sabiki_rig_root: Node3D
var _sabiki_mainline_instance: MeshInstance3D
var _sabiki_top_eye: MeshInstance3D
var _sabiki_sinker_instance: MeshInstance3D
var _sabiki_hook_nodes: Array[Node3D] = []
var _sabiki_hook_spacing_applied := -1.0
var _sabiki_hook_states: Array[Dictionary] = []
var _sabiki_batch_retrieval_active := false
var _sabiki_batch_catch_count := 0
var _last_sabiki_splash_time := -INF
var _sabiki_batch_result_summary: Dictionary = {}
var _current_rig: BoatFishingRigProfile = SINGLE_JIG_PROFILE
var _rod_shader_material: ShaderMaterial
var _splash_instance: MeshInstance3D
var _game_menu: Node
var _natural_bite_sample_elapsed := 0.0
var _natural_bite_pending_real_delta := 0.0
var _last_natural_bite_diagnostics: Dictionary = {}
var _bite_candidate: Dictionary = {}
var _bite_debug_spawned := false
var _bite_elapsed := 0.0
var _bite_duration := 0.0
var _bite_fish_visual: Node3D
var _bite_fish_start_world := Vector3.ZERO
var _bite_fish_side_world := Vector3.ZERO
var _fight_start_bait_world := Vector3.ZERO
var _fight_start_bait_depth_m := 0.0
var _fight_start_horizontal_distance_m := 0.0
var _fight_line_burst_offset_m := 0.0
var _fight_radial_direction := Vector3.FORWARD
var _active_catch_id := ""
var _active_catch_species_id := ""
var _bite_visual_scale := 1.0
var _catch_result_received := false
var _catch_presentation_elapsed := 0.0


func _ready() -> void:
	_onboard = get_node_or_null(onboard_controller_path) as OnboardActivityController
	_boat_controller = get_node_or_null(boat_controller_path) as Node3D
	_fishing_audio_system = get_node_or_null(fishing_audio_system_path) as FishingRodSystem
	if _fishing_audio_system == null:
		_fishing_audio_system = get_tree().root.find_child("FishingRodSystem", true, false) as FishingRodSystem
	_wave_sampler = get_node_or_null(wave_sampler_path)
	_bathymetry_manager = get_node_or_null(bathymetry_manager_path)
	_game_menu = get_tree().root.find_child("GameMenu", true, false)
	_resolve_encounter()
	_build_visuals()
	set_process(false)
	set_process_unhandled_input(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		release_held_controls_for_ui()


func begin_activity() -> bool:
	if _onboard == null or not _onboard.is_activity_active() or _activity_active:
		return _activity_active
	_activity_active = true
	_resolve_encounter()
	_state = CastState.READY
	_current_rig = SINGLE_JIG_PROFILE
	_reset_sabiki_hook_states()
	_state_elapsed = 0.0
	_previous_boat_world = _boat_controller.global_position if _boat_controller != null else Vector3.ZERO
	_boat_velocity_estimate_world = Vector3.ZERO
	_rod_visual_root.visible = _onboard.is_first_person_active()
	_update_rig_visual_selection()
	# Place the handheld view model immediately. Waiting for the next _process
	# frame leaves the rod at the hull origin for one frame, which can put the
	# reel behind or below the first-person camera during activity transitions.
	_update_ready_rod_pose()
	set_process(true)
	set_process_unhandled_input(true)
	_emit_state_changed()
	return true


func end_activity() -> void:
	if not _activity_active:
		return
	cancel_charge_immediately()
	if _encounter != null and _encounter.pending_catch != null and _encounter.pending_catch.fishing_method == "boat_fishing":
		_encounter.cancel_boat_fishing_catch("boat_fishing_ended")
	if _encounter != null and not _encounter.get_sabiki_hook_catches().is_empty():
		_encounter.cancel_sabiki_catches("boat_fishing_ended")
	clear_cast()
	_activity_active = false
	_manual_reeling = false
	_manual_reeling_from_ui = false
	_manual_reeling_input_held = false
	_manual_line_release_held = false
	_manual_line_releasing = false
	_line_controls_conflicted = false
	_rod_aim_active = false
	_automatic_control_owned = false
	_clear_boat_fishing_audio_loops()
	set_process(false)
	set_process_unhandled_input(false)
	_rod_visual_root.visible = false
	_emit_state_changed()


func clear_cast() -> void:
	if _bite_fish_visual != null and is_instance_valid(_bite_fish_visual):
		_bite_fish_visual.queue_free()
	_bite_fish_visual = null
	if _encounter != null and _encounter.pending_catch != null and _encounter.pending_catch.fishing_method == "boat_fishing" and not _catch_result_received:
		_encounter.cancel_boat_fishing_catch("boat_fishing_cast_cleared")
	if _encounter != null and not _encounter.get_sabiki_hook_catches().is_empty():
		_encounter.cancel_sabiki_catches("boat_fishing_cast_cleared")
	_clear_sabiki_hook_visuals()
	_reset_sabiki_hook_states()
	if _onboard != null and _onboard.is_movement_locked():
		_onboard.set_movement_locked(false)
	_state = CastState.READY
	_state_elapsed = 0.0
	_charge_elapsed = 0.0
	_charge_input_held = false
	_charge_canceling = false
	_bait_flight_elapsed = 0.0
	_bait_flight_duration = 0.0
	_bait_flight_started = false
	_bait_has_landed = false
	_cast_tackle_entry_complete = false
	_bait_airborne_retrieval = false
	_airborne_retrieval_elapsed = 0.0
	_sabiki_retrieval_taut = false
	_rod_recovery_complete = false
	_waiting_elapsed = 0.0
	_bait_velocity_world = Vector3.ZERO
	_line_paid_out_length_m = 0.0
	_manual_reeling = false
	_manual_reeling_from_ui = false
	_manual_reeling_input_held = false
	_manual_line_release_held = false
	_manual_line_releasing = false
	_line_controls_conflicted = false
	_rod_aim_active = false
	_rod_tension = 0.0
	_automatic_control_owned = false
	_bite_candidate.clear()
	_bite_debug_spawned = false
	_bite_elapsed = 0.0
	_bite_duration = 0.0
	_active_catch_id = ""
	_active_catch_species_id = ""
	_catch_result_received = false
	_catch_presentation_elapsed = 0.0
	_sabiki_batch_retrieval_active = false
	_sabiki_batch_catch_count = 0
	_sabiki_batch_result_summary.clear()
	_natural_bite_sample_elapsed = 0.0
	_natural_bite_pending_real_delta = 0.0
	_last_natural_bite_diagnostics.clear()
	if _encounter != null:
		_encounter.reset_boat_fishing_hazard()
	_rod_aim_yaw_deg = 0.0
	_rod_aim_pitch_deg = 0.0
	_has_previous_line_connection = false
	_line_instance.visible = false
	_bait_instance.visible = false
	if _cast_aim_marker != null:
		_cast_aim_marker.visible = false
	if _sabiki_rig_root != null:
		_sabiki_rig_root.visible = false
	_splash_instance.visible = false
	_rod_back_angle_deg = 0.0
	_rod_bend_angle_deg = 0.0
	_set_rod_bend_angle(0.0)
	_rod_swing.rotation = Vector3.ZERO
	charge_progress_changed.emit(0.0, false)
	_emit_state_changed()


func begin_charge() -> bool:
	if not _activity_active or _state != CastState.READY or _onboard == null or not _onboard.is_first_person_active():
		return false
	if _is_pointer_over_ui() or _is_menu_open():
		return false
	_update_ready_rod_pose()
	var camera := _onboard.get_activity_camera()
	if camera == null or not camera.current:
		feedback_requested.emit("hud.boat_fishing.cast_first_person")
		return false
	_charge_elapsed = 0.0
	_charge_input_held = true
	_charge_canceling = false
	_set_charge_pose(0.0)
	_set_state(CastState.CHARGING)
	charge_progress_changed.emit(0.0, true)
	return true


func release_charge() -> bool:
	if _state != CastState.CHARGING or not _charge_input_held or _charge_canceling:
		return false
	_charge_input_held = false
	if _is_pointer_over_ui() or _is_menu_open() or _onboard == null or not _onboard.is_first_person_active():
		cancel_charge_smoothly()
		return false
	var charge_ratio := get_charge_progress()
	var cast_distance := _get_cast_distance_for_charge(charge_ratio)
	var camera := _onboard.get_activity_camera()
	if camera == null or not camera.current:
		feedback_requested.emit("hud.boat_fishing.cast_first_person")
		cancel_charge_smoothly()
		return false
	var aim_result := _evaluate_cast_aim(camera, cast_distance)
	if not bool(aim_result.get("valid", false)):
		feedback_requested.emit(str(aim_result.get("reason_key", "hud.boat_fishing.cast_invalid_aim")))
		cancel_charge_smoothly()
		return false
	var target: Vector3 = aim_result["position"]
	_cast_target_world = target
	_cast_start_world = Vector3.ZERO
	_bait_flight_elapsed = 0.0
	_bait_flight_duration = lerpf(CAST_MIN_FLIGHT_TIME_SECONDS, CAST_MAX_FLIGHT_TIME_SECONDS, charge_ratio)
	_bait_flight_started = false
	_bait_has_landed = false
	_cast_tackle_entry_complete = false
	_bait_airborne_retrieval = false
	_airborne_retrieval_elapsed = 0.0
	_sabiki_retrieval_taut = false
	_rod_recovery_complete = false
	_splash_elapsed = 0.0
	_state_elapsed = 0.0
	_waiting_elapsed = 0.0
	_rod_locked_position = _rod_visual_root.position
	_rod_locked_rotation = _rod_visual_root.rotation
	_rod_release_start_bend_deg = _rod_bend_angle_deg
	_onboard.set_movement_locked(true)
	charge_progress_changed.emit(charge_ratio, false)
	_set_state(CastState.CASTING)
	return true


func request_cast() -> bool:
	# Compatibility entry point for tools/tests that need a minimum-strength cast.
	if not begin_charge():
		return false
	_charge_elapsed = minf(0.12, cast_charge_full_time)
	_set_charge_pose(_charge_elapsed)
	return release_charge()


func cancel_charge_smoothly() -> void:
	if _state != CastState.CHARGING or _charge_canceling:
		return
	_charge_input_held = false
	_charge_canceling = true
	_charge_cancel_elapsed = 0.0
	_charge_cancel_start_back_deg = _rod_back_angle_deg
	_charge_cancel_start_bend_deg = _rod_bend_angle_deg
	charge_progress_changed.emit(0.0, true)


func cancel_charge_immediately() -> void:
	if _state != CastState.CHARGING:
		_charge_input_held = false
		_charge_canceling = false
		return
	_charge_input_held = false
	_charge_canceling = false
	_charge_elapsed = 0.0
	_rod_back_angle_deg = 0.0
	_rod_bend_angle_deg = 0.0
	_set_rod_bend_angle(0.0)
	_rod_swing.rotation = Vector3.ZERO
	charge_progress_changed.emit(0.0, false)
	_set_state(CastState.READY)


func get_charge_progress() -> float:
	return clampf(_charge_elapsed / maxf(cast_charge_full_time, 0.01), 0.0, 1.0)


func get_cast_distance_for_charge(charge_ratio: float) -> float:
	return _get_cast_distance_for_charge(charge_ratio)


func set_manual_reeling(active: bool, from_ui: bool = false) -> bool:
	if from_ui:
		_manual_reeling_from_ui = active
	else:
		_manual_reeling_input_held = active
	if active and (not _activity_active or not _is_waiting_line_state() or _automatic_control_owned or _is_menu_open()):
		if from_ui:
			_manual_reeling_from_ui = false
		else:
			_manual_reeling_input_held = false
		_sync_manual_line_controls()
		return false
	_sync_manual_line_controls()
	return true


func select_rig(rig_id: StringName) -> bool:
	if not _activity_active or _state != CastState.READY or _line_paid_out_length_m > 0.01:
		return false
	for rig in [SINGLE_JIG_PROFILE, SABIKI_RIG_PROFILE]:
		if rig.rig_id == rig_id:
			_current_rig = rig
			_reset_sabiki_hook_states()
			_update_rig_visual_selection()
			interaction_updated.emit(get_interaction_snapshot())
			return true
	return false


func get_available_rigs() -> Array[Dictionary]:
	return [
		{"rig_id": SINGLE_JIG_PROFILE.rig_id, "display_name_key": SINGLE_JIG_PROFILE.display_name_key},
		{"rig_id": SABIKI_RIG_PROFILE.rig_id, "display_name_key": SABIKI_RIG_PROFILE.display_name_key},
	]


func get_rig_snapshot() -> Dictionary:
	return {
		"rig_id": _current_rig.rig_id,
		"display_name_key": _current_rig.display_name_key,
		"rig_type": _current_rig.rig_type,
		"hook_count": _current_rig.hook_count,
		"maximum_catch_count": _current_rig.maximum_catch_count,
		"hook_spacing_m": _current_rig.hook_spacing_m,
		"effective_height_m": _current_rig.get_effective_height_m(),
		"line_attachment_height_m": _current_rig.get_line_attachment_height_m(),
		"top_leader_length_m": _current_rig.top_leader_length_m,
		"bottom_leader_length_m": _current_rig.bottom_leader_length_m,
		"branch_length_m": _current_rig.branch_length_m,
		"sink_speed_mps": _current_rig.sink_speed_mps,
		"compatible_species_ids": _current_rig.compatible_species_ids.duplicate(),
	}


func get_natural_bite_diagnostics(include_unavailable_for_diagnostics: bool = false) -> Dictionary:
	var result := _last_natural_bite_diagnostics.duplicate(true)
	result["rig_id"] = _current_rig.rig_id if _current_rig != null else &""
	result["state_name"] = get_casting_state_name()
	result["line_length_m"] = _line_paid_out_length_m
	result["activity_active"] = _activity_active
	result["rig_type"] = _current_rig.rig_type if _current_rig != null else -1
	if _current_rig != null and _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
		var positions := get_hook_world_positions()
		var hook_depths: Array[Dictionary] = []
		var empty_count := 0
		for hook_index in range(_current_rig.hook_count):
			var hook_state: Dictionary = _sabiki_hook_states[hook_index] if hook_index < _sabiki_hook_states.size() else {}
			var status := str(hook_state.get("status", "empty"))
			var depth := -1.0
			if hook_index < positions.size():
				depth = _depth_below_surface_at(positions[hook_index])
			if status == "empty":
				empty_count += 1
			hook_depths.append({"hook_index": hook_index, "depth_m": depth, "status": status})
		result["hook_depths"] = hook_depths
		result["empty_hook_count"] = empty_count
	else:
		result["bait_depth_m"] = _get_bait_depth_below_surface_m() if _bait_has_landed else -1.0
	if include_unavailable_for_diagnostics and _activity_active and _bait_has_landed and _is_waiting_line_state() and _encounter != null and _current_rig != null:
		var relative_velocity := _bait_velocity_world - _boat_velocity_estimate_world * BAIT_WATER_DRAG_FOLLOW
		var rows: Array[Dictionary] = []
		var total_rate := 0.0
		if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
			var positions := get_hook_world_positions()
			for hook_index in range(mini(_current_rig.hook_count, positions.size())):
				if hook_index >= _sabiki_hook_states.size() or str(_sabiki_hook_states[hook_index].get("status", "empty")) != "empty":
					continue
				var depth := _depth_below_surface_at(positions[hook_index])
				var evaluated := _encounter.evaluate_boat_fishing_candidates(positions[hook_index], depth, relative_velocity.length(), _current_rig, true)
				total_rate += float(evaluated.get("total_event_rate_per_real_hour", 0.0))
				for candidate_variant in evaluated.get("candidate_schools", []):
					var row: Dictionary = candidate_variant.duplicate(true)
					row["hook_index"] = hook_index
					row["hook_depth_m"] = depth
					rows.append(row)
		else:
			var depth := _get_bait_depth_below_surface_m()
			var evaluated := _encounter.evaluate_boat_fishing_candidates(_bait_world, depth, relative_velocity.length(), _current_rig, true)
			total_rate = float(evaluated.get("total_event_rate_per_real_hour", 0.0))
			rows.assign(evaluated.get("candidate_schools", []))
		result["candidate_schools"] = rows
		result["candidate_school_count"] = rows.size()
		result["total_event_rate_per_real_hour"] = total_rate
		result["average_first_bite_seconds"] = 3600.0 / total_rate if total_rate > 0.0 else INF
		result["reason"] = "random_not_triggered" if total_rate > 0.0 else _natural_bite_rejection_reason(rows)
	return result


func get_sabiki_hooked_count() -> int:
	var count := 0
	for hook_state in _sabiki_hook_states:
		if str(hook_state.get("status", "empty")) == "hooked":
			count += 1
	return count


func get_sabiki_hook_states_snapshot() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var positions := get_hook_world_positions()
	for hook_index in range(_current_rig.hook_count):
		var hook_state: Dictionary = _sabiki_hook_states[hook_index] if hook_index < _sabiki_hook_states.size() else {}
		var position: Vector3 = positions[hook_index] if hook_index < positions.size() else Vector3.ZERO
		var surface_y := float(_sample_water(position).get("height", position.y))
		result.append({
			"hook_index": hook_index,
			"world_position": position,
			"depth_m": maxf(0.0, surface_y - position.y),
			"status": str(hook_state.get("status", "empty")),
			"species_id": str(hook_state.get("species_id", "")),
			"debug_spawned": bool(hook_state.get("debug_spawned", false)),
		})
	return result


func request_sabiki_retrieval() -> bool:
	if not _activity_active or _current_rig.rig_type != BoatFishingRigProfile.RigType.SABIKI or not _is_waiting_line_state() or _automatic_control_owned:
		return false
	if get_sabiki_hooked_count() <= 0 or _encounter == null:
		return false
	_cancel_sabiki_approach_reservations()
	var catches := _encounter.get_sabiki_hook_catches()
	var representative: FishingPendingCatch
	for catch_record in catches:
		if catch_record.hook_confirmed:
			representative = catch_record
			break
	if representative == null:
		return false
	_sabiki_batch_retrieval_active = true
	_sabiki_batch_catch_count = get_sabiki_hooked_count()
	_active_catch_id = representative.catch_id
	_active_catch_species_id = representative.species_id
	_bite_debug_spawned = representative.debug_spawned
	_bite_candidate.clear()
	_fight_start_bait_world = _bait_world
	_fight_start_bait_depth_m = _get_bait_depth_below_surface_m()
	_fight_line_burst_offset_m = 0.0
	var horizontal := Vector3(_bait_world.x - _get_rod_tip_world().x, 0.0, _bait_world.z - _get_rod_tip_world().z)
	_fight_start_horizontal_distance_m = horizontal.length()
	_fight_radial_direction = horizontal.normalized() if horizontal.length_squared() > 0.001 else -_boat_controller.global_basis.z.normalized() if _boat_controller != null else Vector3.FORWARD
	_rod_tension = clampf(0.55 + 0.06 * float(_sabiki_batch_catch_count), 0.0, 0.9)
	_rod_bend_angle_deg = rod_bend_at_full_tension_deg * _rod_tension
	_set_rod_bend_angle(deg_to_rad(_rod_bend_angle_deg))
	_sabiki_retrieval_taut = true
	set_automatic_control_owned(true)
	_manual_reeling = false
	_manual_reeling_from_ui = false
	_manual_reeling_input_held = false
	_manual_line_release_held = false
	_manual_line_releasing = false
	_rod_aim_active = false
	_set_boat_fishing_audio_loop("line_out", false)
	_set_boat_fishing_audio_loop("reel_in", false)
	_set_boat_fishing_audio_loop("drag", false)
	_set_state(CastState.FIGHTING)
	var pending := _encounter.begin_sabiki_batch_retrieval()
	if pending == null:
		_sabiki_batch_retrieval_active = false
		set_automatic_control_owned(false)
		_set_state(CastState.SABIKI_HOOKED_WAITING)
		return false
	_active_catch_id = pending.catch_id
	_active_catch_species_id = pending.species_id
	return true


func debug_spawn_sabiki_fish(hook_index: int = -1) -> Dictionary:
	_resolve_encounter()
	if not _activity_active:
		return {"accepted": false, "reason": "boat_fishing_inactive"}
	if _current_rig.rig_type != BoatFishingRigProfile.RigType.SABIKI:
		return {"accepted": false, "reason": "sabiki_rig_required"}
	if _state not in [CastState.WAITING, CastState.SABIKI_HOOKED_WAITING] or not _bait_has_landed:
		return {"accepted": false, "reason": "tackle_not_in_water"}
	if _automatic_control_owned or _encounter == null:
		return {"accepted": false, "reason": "catch_already_active"}
	if hook_index < 0:
		hook_index = _find_empty_sabiki_hook()
	if hook_index < 0 or hook_index >= _current_rig.hook_count:
		return {"accepted": false, "reason": "no_empty_hook"}
	if hook_index >= _sabiki_hook_states.size() or str(_sabiki_hook_states[hook_index].get("status", "empty")) != "empty":
		return {"accepted": false, "reason": "hook_not_empty"}
	var profile := _fish_manager.get_species_profile("herring") if _fish_manager != null else null
	if profile == null or not profile.supported_fishing_methods.has("boat_fishing") or not FishingEncounterSystem.rig_matches_profile(profile, _current_rig):
		return {"accepted": false, "reason": "method_or_rig_mismatch"}
	var hook_positions := get_hook_world_positions()
	var hook_position: Vector3 = hook_positions[hook_index] if hook_index < hook_positions.size() else _bait_world
	var candidate := {
		"school_id": "",
		"species_id": "herring",
		"population": 0,
		"activity_depth_m": _depth_below_surface_at(hook_position),
		"lure_depth_m": _depth_below_surface_at(hook_position),
		"event_rate_per_game_hour": 0.0,
	}
	var pending := _encounter.reserve_sabiki_hook(candidate, _current_rig, hook_index, true)
	if pending == null:
		return {"accepted": false, "reason": "catch_already_active"}
	_begin_sabiki_hook_bite(hook_index, pending, candidate, true)
	return {"accepted": true, "hook_index": hook_index, "species_id": "herring"}


func debug_fill_sabiki_rig() -> Dictionary:
	_resolve_encounter()
	if _current_rig.rig_type != BoatFishingRigProfile.RigType.SABIKI:
		return {"accepted": false, "reason": "sabiki_rig_required", "spawned_count": 0}
	var spawned := 0
	var catch_limit := mini(_current_rig.hook_count, _current_rig.maximum_catch_count)
	for hook_index in range(catch_limit):
		if str(_sabiki_hook_states[hook_index].get("status", "empty")) != "empty":
			continue
		var result := debug_spawn_sabiki_fish(hook_index)
		if bool(result.get("accepted", false)):
			spawned += 1
	return {"accepted": spawned > 0, "spawned_count": spawned}


func get_hook_depth_range_m() -> Dictionary:
	if not is_cast_active() or not _bait_has_landed or _current_rig.rig_type != BoatFishingRigProfile.RigType.SABIKI:
		return {"valid": false, "shallow_m": 0.0, "deep_m": 0.0}
	var shallow_depth := INF
	var deep_depth := 0.0
	for hook_position in get_hook_world_positions():
		var surface_y := float(_sample_water(hook_position).get("height", hook_position.y))
		var depth := maxf(0.0, surface_y - hook_position.y)
		shallow_depth = minf(shallow_depth, depth)
		deep_depth = maxf(deep_depth, depth)
	return {
		"valid": true,
		"shallow_m": 0.0 if is_inf(shallow_depth) else shallow_depth,
		"deep_m": deep_depth,
	}


func get_hook_world_positions() -> Array[Vector3]:
	if not is_cast_active():
		return []
	if _current_rig.rig_type == BoatFishingRigProfile.RigType.SINGLE_JIG:
		return [_bait_world]
	return get_rig_hook_positions(_bait_world, _get_sabiki_up_direction_world())


func get_rig_hook_positions(sinker_world_position: Vector3, rig_up_direction: Vector3) -> Array[Vector3]:
	## Structural order is stable: returned entries are Hook 1 (rod side) through Hook 5 (sinker side).
	var positions: Array[Vector3] = []
	if _current_rig.rig_type != BoatFishingRigProfile.RigType.SABIKI:
		return positions
	var up_direction := rig_up_direction.normalized()
	if up_direction.length_squared() < 0.5:
		up_direction = Vector3.UP
	for hook_index in range(_current_rig.hook_count):
		var height_from_sinker := _current_rig.bottom_leader_length_m + float(_current_rig.hook_count - hook_index - 1) * _current_rig.hook_spacing_m
		positions.append(sinker_world_position + up_direction * height_from_sinker)
	return positions


func get_sinker_world_position() -> Vector3:
	return _bait_world


func get_sinker_depth_below_surface_m() -> float:
	return _get_bait_depth_below_surface_m()


func release_held_controls_for_ui() -> void:
	_manual_reeling = false
	_manual_reeling_from_ui = false
	_manual_reeling_input_held = false
	_manual_line_release_held = false
	_manual_line_releasing = false
	_line_controls_conflicted = false
	_rod_aim_active = false
	if _state == CastState.CHARGING:
		cancel_charge_smoothly()
	interaction_updated.emit(get_interaction_snapshot())


func set_automatic_control_owned(owned: bool) -> void:
	## P6.3 handoff seam. This only reserves/relinquishes input ownership; it
	## does not create or advance an automatic fight state.
	_automatic_control_owned = owned
	if owned:
		_manual_reeling = false
		_manual_reeling_from_ui = false
		_manual_reeling_input_held = false
		_manual_line_release_held = false
		_manual_line_releasing = false
		_line_controls_conflicted = false
		_rod_aim_active = false
		charge_progress_changed.emit(0.0, false)
	interaction_updated.emit(get_interaction_snapshot())
	if not owned:
		_set_boat_fishing_audio_loop("drag", false)


func is_automatic_control_owned() -> bool:
	return _automatic_control_owned


## Integration point for a real P6.3 authority settlement event. Call once per
## successful catch batch; current P6.2 casting does not create catch results.
func report_catch_succeeded(catch_batch_id: String) -> bool:
	if not _activity_active or catch_batch_id.is_empty() or _played_success_audio_batches.has(catch_batch_id):
		return false
	_played_success_audio_batches[catch_batch_id] = true
	_success_audio_batch_order.append(catch_batch_id)
	if _success_audio_batch_order.size() > 128:
		_played_success_audio_batches.erase(_success_audio_batch_order.pop_front())
	_play_boat_fishing_one_shot("catch_success")
	return true


func can_adjust_waiting_rod() -> bool:
	return _activity_active and _is_waiting_line_state() and not _automatic_control_owned


func begin_rod_aim() -> bool:
	if not can_adjust_waiting_rod() or _onboard == null or not _onboard.is_first_person_active():
		return false
	if _is_pointer_over_ui() or _is_menu_open():
		return false
	_rod_aim_active = true
	return true


func apply_rod_aim_mouse_motion(relative: Vector2) -> void:
	if not _rod_aim_active or not can_adjust_waiting_rod():
		return
	var next_yaw_deg := clampf(
		_rod_aim_yaw_deg - relative.x * rod_aim_degrees_per_mouse_pixel,
		-60.0,
		60.0
	)
	var next_pitch_deg := clampf(
		_rod_aim_pitch_deg - relative.y * rod_aim_degrees_per_mouse_pixel,
		0.0,
		75.0
	)
	var previous_rotation := _rod_swing.rotation
	_rod_swing.rotation = Vector3(deg_to_rad(next_pitch_deg), deg_to_rad(next_yaw_deg), 0.0)
	var candidate_tip := _get_rod_tip_world()
	_rod_swing.rotation = previous_rotation
	if _path_is_blocked(_rod_visual_root.global_position, candidate_tip):
		return
	_rod_aim_yaw_deg = next_yaw_deg
	_rod_aim_pitch_deg = next_pitch_deg
	_apply_waiting_rod_pose()


func end_rod_aim() -> void:
	_rod_aim_active = false


func on_camera_view_changed(first_person_active: bool) -> void:
	## Release held controls on O without disturbing the cast itself.
	if not first_person_active:
		_manual_reeling = false
		_manual_reeling_from_ui = false
		_manual_reeling_input_held = false
		_manual_line_release_held = false
		_manual_line_releasing = false
		_line_controls_conflicted = false
		_rod_aim_active = false
		if _state == CastState.CHARGING:
			cancel_charge_smoothly()
	interaction_updated.emit(get_interaction_snapshot())


func get_casting_state() -> int:
	return _state


func get_casting_state_name() -> String:
	return ["READY", "CHARGING", "CASTING", "WAITING", "SABIKI_HOOKED_WAITING", "RETRIEVING", "BITE_APPROACH", "FIGHTING", "CATCH_PRESENTATION"][_state]


func is_cast_active() -> bool:
	return _state in [CastState.CASTING, CastState.WAITING, CastState.SABIKI_HOOKED_WAITING, CastState.RETRIEVING, CastState.BITE_APPROACH, CastState.FIGHTING, CastState.CATCH_PRESENTATION]


func is_activity_active() -> bool:
	return _activity_active


func get_bait_depth_below_surface_m() -> float:
	return _get_bait_depth_below_surface_m()


func get_debug_snapshot() -> Dictionary:
	var line_start := _get_rod_tip_world() if _rod_visual_root != null else Vector3.ZERO
	var line_connection := _get_tackle_line_connection_world() if _rod_visual_root != null else Vector3.ZERO
	var cast_delta := _cast_target_world - _cast_start_world
	return {
		"activity_active": _activity_active,
		"state": get_casting_state_name(),
		"line_active": is_cast_active(),
		"charge_progress": get_charge_progress(),
		"charge_elapsed_seconds": _charge_elapsed,
		"charge_full_time_seconds": cast_charge_full_time,
		"cast_distance_m": Vector2(cast_delta.x, cast_delta.z).length() if _bait_flight_started else 0.0,
		"bait_flying": _bait_flight_started and not _bait_has_landed,
		"bait_landed": _bait_has_landed,
		"cast_target_world_position": _cast_target_world,
		"rod_back_angle_deg": _rod_back_angle_deg,
		"rod_bend_angle_deg": _rod_bend_angle_deg,
		"actual_line_length_m": line_start.distance_to(line_connection) if is_cast_active() else 0.0,
		"maximum_line_length_m": maximum_line_length_m,
		"paid_out_line_length_m": _line_paid_out_length_m,
		"line_length_m": _line_paid_out_length_m,
		"bait_depth_below_surface_m": _get_bait_depth_below_surface_m(),
		"sinker_depth_below_surface_m": get_sinker_depth_below_surface_m(),
		"water_depth_m": _get_water_depth_at_bait_m(),
		"seabed_valid": bool(_sample_seabed(_bait_world).get("valid", false)),
		"lure_world_position": _bait_world,
		"lure_velocity_world_mps": _bait_velocity_world,
		"manual_reeling": _manual_reeling,
		"manual_line_releasing": _manual_line_releasing,
		"line_controls_conflicted": _line_controls_conflicted,
		"rod_aim_active": _rod_aim_active,
		"rod_aim_yaw_deg": _rod_aim_yaw_deg,
		"rod_aim_pitch_deg": _rod_aim_pitch_deg,
		"line_tension": _rod_tension,
		"automatic_control_owned": _automatic_control_owned,
		"bite_approach_active": _state == CastState.BITE_APPROACH,
		"catch_in_progress": _state in [CastState.FIGHTING, CastState.CATCH_PRESENTATION],
		"catch_result_received": _catch_result_received,
		"active_catch_id": _active_catch_id,
		"debug_spawned_catch": _bite_debug_spawned,
		"encounter_state": _encounter.get_state_name() if _encounter != null else "unavailable",
		"reel_visual_rotation_rad": _reel_visual_total_rotation_rad,
		"reel_line_delta_m": _last_reel_line_delta_m,
		"reel_spin_speed_rad_s": _reel_rotating_assembly.get_meta("spin_speed_rad_s", 0.0) if _reel_rotating_assembly != null else 0.0,
		"fishing_audio_loops": _requested_fishing_audio_loops.duplicate(true),
		"fishing_audio_event_counts": _fishing_audio_event_counts.duplicate(true),
		"rig": get_rig_snapshot(),
		"hook_depth_range": get_hook_depth_range_m(),
		"bait_world_position": _bait_world,
		"sinker_world_position": get_sinker_world_position(),
		"rod_tip_world_position": line_start,
		"line_connection_world_position": line_connection,
		"hook_world_positions": get_hook_world_positions(),
		"sabiki_hooks": get_sabiki_hook_states_snapshot(),
		"sabiki_hooked_count": get_sabiki_hooked_count(),
		"sabiki_hook_capacity": _current_rig.maximum_catch_count,
		"sabiki_batch_retrieval_active": _sabiki_batch_retrieval_active,
		"sabiki_batch_result_summary": _sabiki_batch_result_summary.duplicate(true),
		"movement_locked": _onboard.is_movement_locked() if _onboard != null else false,
		"first_person_active": _onboard.is_first_person_active() if _onboard != null else false,
	}


func get_interaction_snapshot() -> Dictionary:
	var tip := _get_rod_tip_world() if _rod_visual_root != null else Vector3.ZERO
	var line_connection := _get_tackle_line_connection_world() if _rod_visual_root != null else Vector3.ZERO
	return {
		"state": get_casting_state_name(),
		"line_active": is_cast_active(),
		"actual_line_length_m": tip.distance_to(line_connection) if is_cast_active() else 0.0,
		"paid_out_line_length_m": _line_paid_out_length_m if is_cast_active() else 0.0,
		"line_length_m": _line_paid_out_length_m if is_cast_active() else 0.0,
		"bait_depth_below_surface_m": _get_bait_depth_below_surface_m() if is_cast_active() else 0.0,
		"sinker_depth_below_surface_m": get_sinker_depth_below_surface_m() if is_cast_active() else 0.0,
		"water_depth_m": _get_water_depth_at_bait_m() if is_cast_active() else -1.0,
		"seabed_valid": bool(_sample_seabed(_bait_world).get("valid", false)) if is_cast_active() else false,
		"lure_world_position": _bait_world,
		"sinker_world_position": get_sinker_world_position(),
		"line_connection_world_position": line_connection,
		"hook_world_positions": get_hook_world_positions(),
		"lure_velocity_world_mps": _bait_velocity_world,
		"manual_reeling": _manual_reeling,
		"manual_line_releasing": _manual_line_releasing,
		"line_tension": _rod_tension,
		"rig": get_rig_snapshot(),
		"hook_depth_range": get_hook_depth_range_m(),
		"sabiki_hooks": get_sabiki_hook_states_snapshot(),
		"sabiki_hooked_count": get_sabiki_hooked_count(),
		"sabiki_hook_capacity": _current_rig.maximum_catch_count,
		"sabiki_batch_retrieval_active": _sabiki_batch_retrieval_active,
		"sabiki_batch_result_summary": _sabiki_batch_result_summary.duplicate(true),
		"catch_in_progress": _state in [CastState.FIGHTING, CastState.CATCH_PRESENTATION],
		"bite_approach_active": _state == CastState.BITE_APPROACH,
		"catch_debug_spawned": _bite_debug_spawned,
		"catch_id": _active_catch_id,
		"catch_result_received": _catch_result_received,
	}


func _unhandled_input(event: InputEvent) -> void:
	if not _activity_active:
		return
	if event.is_action_pressed("boat_fishing_cast", false):
		if not _is_pointer_over_ui() and _onboard != null and _onboard.is_first_person_active():
			if _state == CastState.READY:
				begin_charge()
				get_viewport().set_input_as_handled()
			elif _is_waiting_line_state():
				set_manual_reeling(true)
				get_viewport().set_input_as_handled()
	elif event.is_action_released("boat_fishing_cast"):
		if _state == CastState.CHARGING:
			if _is_pointer_over_ui() or _is_menu_open():
				cancel_charge_smoothly()
			else:
				release_charge()
			get_viewport().set_input_as_handled()
		elif _is_waiting_line_state():
			set_manual_reeling(false)
			get_viewport().set_input_as_handled()


func _input(event: InputEvent) -> void:
	if not _activity_active or not InputMap.has_action("boat_fishing_pay_out"):
		return
	if event.is_action_pressed("boat_fishing_pay_out", false):
		# F also opens port services; give it to line payout only during a live
		# water cast, leaving the port shortcut available in READY/other states.
		if _is_waiting_line_state():
			if not _automatic_control_owned and not _is_pointer_over_ui() and not _is_menu_open():
				_manual_line_release_held = true
				_sync_manual_line_controls()
			get_viewport().set_input_as_handled()
	elif event.is_action_released("boat_fishing_pay_out"):
		if _manual_line_release_held:
			_manual_line_release_held = false
			_sync_manual_line_controls()
			get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not _activity_active:
		return
	if not is_instance_valid(_onboard):
		cancel_charge_immediately()
		return
	var reel_line_length_before := _get_reel_feedback_line_length()
	_update_boat_velocity_estimate(delta)
	if _state == CastState.READY:
		_update_ready_rod_pose()
		_rod_visual_root.visible = _onboard.is_first_person_active()
	elif _state == CastState.CHARGING:
		if not _charge_canceling and (
			not is_instance_valid(_onboard)
			or not _onboard.is_first_person_active()
			or _is_menu_open()
			or _is_pointer_over_ui()
		):
			cancel_charge_smoothly()
		_update_charge_animation(delta)
	elif _state == CastState.CASTING:
		_update_cast_animation(delta)
	elif _is_waiting_line_state():
		if _is_menu_open():
			release_held_controls_for_ui()
		elif _is_pointer_over_ui():
			_release_non_ui_line_inputs()
		_reconcile_physical_line_inputs()
		_sync_manual_line_controls()
		_update_waiting_bait(delta)
		if _is_waiting_line_state():
			_advance_sabiki_hook_approaches(delta)
		if _is_waiting_line_state():
			_update_natural_bite_judgement(delta)
	elif _state == CastState.RETRIEVING:
		_update_retrieve_animation(delta)
	elif _state == CastState.BITE_APPROACH:
		_advance_bite_approach(delta)
	elif _state == CastState.FIGHTING:
		_advance_auto_fight(delta)
	elif _state == CastState.CATCH_PRESENTATION:
		_advance_catch_presentation(delta)
	_update_cast_aim_marker(delta)
	_update_rod_line_guides()
	_update_line_and_bait_visuals()
	_update_sabiki_hooked_fish_visuals(delta)
	_update_splash(delta)
	var reel_line_length_after := _get_reel_feedback_line_length()
	_update_reel_visual_and_audio(reel_line_length_before, reel_line_length_after, delta)


func _resolve_encounter() -> void:
	if _fish_manager == null or not is_instance_valid(_fish_manager):
		_fish_manager = get_tree().root.find_child("FishResourceManager", true, false) as FishResourceManager
	if _fish_manager == null:
		return
	_fish_school_renderer = _fish_manager.get_node_or_null("FishSchoolRenderer") as FishSchoolRenderer
	var resolved := _fish_manager.get_fishing_encounter_system()
	if resolved == _encounter:
		return
	if _encounter != null and is_instance_valid(_encounter):
		if _encounter.catch_succeeded.is_connected(_on_authority_catch_succeeded):
			_encounter.catch_succeeded.disconnect(_on_authority_catch_succeeded)
		if _encounter.catch_cancelled.is_connected(_on_authority_catch_cancelled):
			_encounter.catch_cancelled.disconnect(_on_authority_catch_cancelled)
		if _encounter.sabiki_batch_settled.is_connected(_on_sabiki_batch_settled):
			_encounter.sabiki_batch_settled.disconnect(_on_sabiki_batch_settled)
	_encounter = resolved
	if _encounter != null:
		_encounter.catch_succeeded.connect(_on_authority_catch_succeeded)
		_encounter.catch_cancelled.connect(_on_authority_catch_cancelled)
		_encounter.sabiki_batch_settled.connect(_on_sabiki_batch_settled)


func debug_spawn_test_fish(species_id: String) -> Dictionary:
	_resolve_encounter()
	if not _activity_active:
		return {"accepted": false, "reason": "boat_fishing_inactive"}
	if _current_rig == null or _current_rig.rig_type != BoatFishingRigProfile.RigType.SINGLE_JIG:
		return {"accepted": false, "reason": "single_jig_required"}
	if _state != CastState.WAITING or not _bait_has_landed:
		return {"accepted": false, "reason": "lure_not_in_water"}
	if _automatic_control_owned or _encounter == null or _encounter.pending_catch != null:
		return {"accepted": false, "reason": "catch_already_active"}
	var profile := _fish_manager.get_species_profile(species_id) if _fish_manager != null else null
	if profile == null or not profile.supported_fishing_methods.has("boat_fishing") or not FishingEncounterSystem.rig_matches_profile(profile, _current_rig):
		return {"accepted": false, "reason": "method_or_rig_mismatch"}
	var candidate := {
		"school_id": "",
		"species_id": species_id,
		"population": 0,
		"activity_depth_m": _get_bait_depth_below_surface_m(),
		"lure_depth_m": _get_bait_depth_below_surface_m(),
		"event_rate_per_game_hour": 0.0,
	}
	if not _begin_bite_event(candidate, true, true):
		return {"accepted": false, "reason": "catch_already_active"}
	return {"accepted": true, "reason": "test_bite_approaching", "species_id": species_id}


func _update_natural_bite_judgement(delta: float) -> void:
	if not _bait_has_landed or _current_rig == null or _encounter == null:
		return
	var real_delta := maxf(0.0, delta)
	if not is_finite(real_delta):
		return
	_natural_bite_pending_real_delta += real_delta
	_natural_bite_sample_elapsed += real_delta
	if _natural_bite_sample_elapsed < boat_fishing_sampling_interval_real_seconds:
		return
	_natural_bite_sample_elapsed = fmod(_natural_bite_sample_elapsed, boat_fishing_sampling_interval_real_seconds)
	var elapsed_real_seconds := _natural_bite_pending_real_delta
	_natural_bite_pending_real_delta = 0.0
	var relative_velocity := _bait_velocity_world - _boat_velocity_estimate_world * BAIT_WATER_DRAG_FOLLOW
	var diagnostic_candidates: Array[Dictionary] = []
	var hook_depths: Array[Dictionary] = []
	var total_event_rate := 0.0
	var bite_started := false
	if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
		var hook_positions := get_hook_world_positions()
		for hook_index in range(mini(_current_rig.hook_count, hook_positions.size())):
			var hook_status := str(_sabiki_hook_states[hook_index].get("status", "empty")) if hook_index < _sabiki_hook_states.size() else "empty"
			var hook_position: Vector3 = hook_positions[hook_index]
			var hook_depth := _depth_below_surface_at(hook_position)
			hook_depths.append({"hook_index": hook_index, "depth_m": hook_depth, "status": hook_status})
			if hook_status != "empty":
				continue
			var diagnostics := _encounter.evaluate_boat_fishing_candidates(
				hook_position,
				hook_depth,
				relative_velocity.length(),
				_current_rig
			)
			total_event_rate += float(diagnostics.get("total_event_rate_per_real_hour", 0.0))
			for candidate_variant in diagnostics.get("candidate_schools", []):
				var row: Dictionary = candidate_variant.duplicate(true)
				row["hook_index"] = hook_index
				row["hook_depth_m"] = hook_depth
				diagnostic_candidates.append(row)
			var candidate := _encounter.advance_boat_fishing_hazard_for_hook(diagnostics, elapsed_real_seconds, hook_index)
			if candidate.is_empty():
				continue
			var pending := _encounter.reserve_sabiki_hook(candidate, _current_rig, hook_index, false)
			if pending != null:
				_begin_sabiki_hook_bite(hook_index, pending, candidate, false)
				bite_started = true
		_last_natural_bite_diagnostics = {
			"rig_id": _current_rig.rig_id,
			"rig_type": _current_rig.rig_type,
			"state_name": get_casting_state_name(),
			"line_length_m": _line_paid_out_length_m,
			"lure_relative_speed_mps": relative_velocity.length(),
			"hook_depths": hook_depths,
			"empty_hook_count": _count_empty_sabiki_hooks(),
			"candidate_schools": diagnostic_candidates,
			"candidate_school_count": diagnostic_candidates.size(),
			"total_event_rate_per_real_hour": total_event_rate,
			"average_first_bite_seconds": 3600.0 / total_event_rate if total_event_rate > 0.0 else INF,
			"reason": "bite_started" if bite_started else (_natural_bite_no_event_reason(total_event_rate, relative_velocity.length()) if total_event_rate > 0.0 else _natural_bite_rejection_reason(diagnostic_candidates)),
			"last_sample_real_delta_seconds": elapsed_real_seconds,
		}
		return
	if _current_rig.rig_type != BoatFishingRigProfile.RigType.SINGLE_JIG:
		return
	var bait_depth := _get_bait_depth_below_surface_m()
	var diagnostics := _encounter.evaluate_boat_fishing_candidates(
		_bait_world,
		bait_depth,
		relative_velocity.length(),
		_current_rig
	)
	for candidate_variant in diagnostics.get("candidate_schools", []):
		diagnostic_candidates.append(candidate_variant.duplicate(true))
	total_event_rate = float(diagnostics.get("total_event_rate_per_real_hour", 0.0))
	var candidate := _encounter.advance_boat_fishing_hazard(diagnostics, elapsed_real_seconds)
	if not candidate.is_empty():
		_begin_bite_event(candidate, false, false)
		bite_started = true
	_last_natural_bite_diagnostics = {
		"rig_id": _current_rig.rig_id,
		"rig_type": _current_rig.rig_type,
		"state_name": get_casting_state_name(),
		"line_length_m": _line_paid_out_length_m,
		"bait_depth_m": bait_depth,
		"lure_relative_speed_mps": relative_velocity.length(),
		"candidate_schools": diagnostic_candidates,
		"candidate_school_count": diagnostic_candidates.size(),
		"total_event_rate_per_real_hour": total_event_rate,
		"average_first_bite_seconds": 3600.0 / total_event_rate if total_event_rate > 0.0 else INF,
		"reason": "bite_started" if bite_started else (_natural_bite_no_event_reason(total_event_rate, relative_velocity.length()) if total_event_rate > 0.0 else _natural_bite_rejection_reason(diagnostic_candidates)),
		"last_sample_real_delta_seconds": elapsed_real_seconds,
	}


func _count_empty_sabiki_hooks() -> int:
	var count := 0
	for hook_state in _sabiki_hook_states:
		if str(hook_state.get("status", "empty")) == "empty":
			count += 1
	return count


func _natural_bite_rejection_reason(candidates: Array[Dictionary]) -> String:
	if candidates.is_empty():
		return "no_nearby_schools"
	var reasons: Dictionary = {}
	for candidate in candidates:
		var reason := str(candidate.get("rejection_reason", ""))
		if not reason.is_empty():
			reasons[reason] = true
	for reason in ["method_or_rig_mismatch", "empty_school", "lure_outside_school", "activity_depth_mismatch"]:
		if reasons.has(reason):
			return reason
	if reasons.has("zero_event_rate"):
		return "action_weight_low"
	return "no_valid_candidate"


func _natural_bite_no_event_reason(total_event_rate: float, relative_speed_mps: float) -> String:
	if total_event_rate <= 0.0:
		return "no_valid_candidate"
	if _current_rig != null and _current_rig.rig_type == BoatFishingRigProfile.RigType.SINGLE_JIG:
		var action_weight := FishingEncounterSystem.boat_fishing_action_weight(
			relative_speed_mps,
			_encounter.single_jig_min_action_weight,
			_encounter.single_jig_max_action_weight,
			_encounter.single_jig_action_reference_speed_mps
		) if _encounter != null else 1.0
		if action_weight <= 0.60:
			return "action_weight_low"
	return "random_not_triggered"


func _begin_sabiki_hook_bite(hook_index: int, pending: FishingPendingCatch, candidate: Dictionary, debug_spawned: bool, force_approach: bool = false) -> void:
	if pending == null or hook_index < 0 or hook_index >= _sabiki_hook_states.size():
		return
	var positions := get_hook_world_positions()
	if hook_index >= positions.size():
		_encounter.release_sabiki_reservation(pending.catch_id)
		return
	var hook_position: Vector3 = positions[hook_index]
	var hook_depth := _depth_below_surface_at(hook_position)
	var should_approach := should_visualize_bite_approach(hook_depth, shallow_bite_visual_depth_m, force_approach)
	var hook_state: Dictionary = _sabiki_hook_states[hook_index]
	hook_state["status"] = "approaching" if should_approach else "reserved"
	hook_state["pending"] = pending
	hook_state["catch_id"] = pending.catch_id
	hook_state["species_id"] = pending.species_id
	hook_state["debug_spawned"] = debug_spawned
	hook_state["body_length_m"] = pending.body_length_m
	hook_state["approach_elapsed"] = 0.0
	hook_state["surface_crossed"] = false
	if should_approach:
		var school_start := hook_position - Vector3.FORWARD * 3.2
		if not debug_spawned and _fish_manager != null:
			var school: Dictionary = _fish_manager.get_school(pending.school_id)
			var values: Array = school.get("world_position", [])
			if values.size() >= 3:
				var anchor := Vector3(float(values[0]), hook_position.y, float(values[2]))
				var direction := Vector3(hook_position.x - anchor.x, 0.0, hook_position.z - anchor.z)
				if direction.length_squared() > 0.001:
					direction = direction.normalized()
					school_start = hook_position - direction * clampf(Vector2(hook_position.x - anchor.x, hook_position.z - anchor.z).length(), 2.8, 5.0)
		var direction_to_hook := hook_position - school_start
		direction_to_hook.y = 0.0
		if direction_to_hook.length_squared() < 0.001:
			direction_to_hook = -_boat_controller.global_basis.z if _boat_controller != null else Vector3.FORWARD
		direction_to_hook = direction_to_hook.normalized()
		var surface_y := float(_sample_water(school_start).get("height", hook_position.y))
		var activity_depth := maxf(0.0, float(candidate.get("activity_depth_m", hook_depth)))
		school_start.y = surface_y - activity_depth
		var profile := _fish_manager.get_species_profile(pending.species_id) if _fish_manager != null else null
		var speed := 0.65
		if profile != null:
			speed = maxf(0.25, (profile.movement_speed_min_mps + profile.movement_speed_max_mps) * 0.5)
		hook_state["start_world"] = school_start
		hook_state["side_world"] = direction_to_hook.cross(Vector3.UP).normalized()
		hook_state["approach_duration"] = clampf(school_start.distance_to(hook_position) / speed, 0.8, 3.6)
		hook_state["visual"] = _create_sabiki_fish_visual(pending.species_id, pending.body_length_m, direction_to_hook)
		if hook_state["visual"] != null:
			(hook_state["visual"] as Node3D).name = "SabikiHookFish_%02d" % (hook_index + 1)
			(hook_state["visual"] as Node3D).global_position = school_start
	else:
		hook_state["status"] = "reserved"
		hook_state["approach_duration"] = 0.0
	_sabiki_hook_states[hook_index] = hook_state
	interaction_updated.emit(get_interaction_snapshot())


func _advance_sabiki_hook_approaches(delta: float) -> void:
	if _current_rig.rig_type != BoatFishingRigProfile.RigType.SABIKI:
		return
	for hook_index in range(_sabiki_hook_states.size()):
		var hook_state: Dictionary = _sabiki_hook_states[hook_index]
		if str(hook_state.get("status", "empty")) not in ["approaching", "reserved"]:
			continue
		if str(hook_state.get("status", "")) == "approaching":
			var elapsed := float(hook_state.get("approach_elapsed", 0.0)) + maxf(delta, 0.0)
			hook_state["approach_elapsed"] = elapsed
			var duration := maxf(0.01, float(hook_state.get("approach_duration", 1.0)))
			var progress := clampf(elapsed / duration, 0.0, 1.0)
			var hook_positions := get_hook_world_positions()
			if hook_index < hook_positions.size():
				var start: Vector3 = hook_state.get("start_world", hook_positions[hook_index])
				var target: Vector3 = hook_positions[hook_index]
				var side: Vector3 = hook_state.get("side_world", Vector3.RIGHT)
				var eased := _smoothstep01(progress)
				var visual := hook_state.get("visual") as Node3D
				if visual != null and is_instance_valid(visual):
					visual.global_position = start.lerp(target, eased) + side * sin(PI * progress) * 0.22 + Vector3.UP * sin(PI * progress) * 0.08
					_set_sabiki_fish_heading(visual, str(hook_state.get("species_id", "herring")), float(hook_state.get("body_length_m", 0.32)), target - visual.global_position, sin(elapsed * 6.0) * 0.045)
			if progress < 1.0:
				_sabiki_hook_states[hook_index] = hook_state
				continue
		var pending := hook_state.get("pending") as FishingPendingCatch
		if pending == null or _encounter == null or not _encounter.confirm_sabiki_hook(str(hook_state.get("catch_id", ""))):
			_clear_sabiki_hook_state(hook_index, true)
			continue
		hook_state["status"] = "hooked"
		hook_state["pending"] = pending
		hook_state["body_length_m"] = pending.body_length_m
		if hook_state.get("visual") == null:
			var hook_positions := get_hook_world_positions()
			if hook_index < hook_positions.size():
				var heading := _get_sabiki_up_direction_world()
				var visual := _create_sabiki_fish_visual(pending.species_id, pending.body_length_m, heading)
				if visual != null:
					visual.name = "SabikiHookFish_%02d" % (hook_index + 1)
					visual.global_position = hook_positions[hook_index] + Vector3.RIGHT * 0.16
					hook_state["visual"] = visual
		_sabiki_hook_states[hook_index] = hook_state
		_rod_tension = maxf(_rod_tension, 0.18)
		_rod_bend_angle_deg = rod_bend_at_full_tension_deg * _rod_tension
		_set_rod_bend_angle(deg_to_rad(_rod_bend_angle_deg))
		if get_sabiki_hooked_count() >= _current_rig.maximum_catch_count:
			request_sabiki_retrieval()
			return
		_set_state(CastState.SABIKI_HOOKED_WAITING)


func _update_sabiki_hooked_fish_visuals(delta: float) -> void:
	if _current_rig.rig_type != BoatFishingRigProfile.RigType.SABIKI or _sabiki_hook_states.is_empty():
		return
	var hook_positions := get_hook_world_positions()
	for hook_index in range(mini(_sabiki_hook_states.size(), hook_positions.size())):
		var hook_state: Dictionary = _sabiki_hook_states[hook_index]
		if str(hook_state.get("status", "")) != "hooked":
			continue
		var visual := hook_state.get("visual") as Node3D
		if visual == null or not is_instance_valid(visual):
			continue
		var hook_position: Vector3 = hook_positions[hook_index]
		var side := _rod_swing.global_basis.x
		side.y = 0.0
		if side.length_squared() < 0.001:
			side = Vector3.RIGHT
		side = side.normalized()
		var surface_y := float(_sample_water(hook_position).get("height", hook_position.y))
		var is_out_of_water := hook_position.y >= surface_y
		var fish_position := hook_position + side * 0.16 + Vector3.UP * 0.05
		if is_out_of_water:
			fish_position.y = maxf(fish_position.y, surface_y + 0.08)
			if not bool(hook_state.get("surface_crossed", false)):
				hook_state["surface_crossed"] = true
				if Time.get_ticks_msec() * 0.001 - _last_sabiki_splash_time >= 0.32:
					_last_sabiki_splash_time = Time.get_ticks_msec() * 0.001
					_show_splash_visual(fish_position)
					_play_boat_fishing_one_shot("splash")
		else:
			fish_position.y = minf(fish_position.y, surface_y - 0.025)
		visual.global_position = visual.global_position.lerp(fish_position, 1.0 - exp(-maxf(delta, 0.0) * 14.0))
		var elapsed := float(hook_state.get("struggle_elapsed", 0.0)) + maxf(delta, 0.0)
		hook_state["struggle_elapsed"] = elapsed
		_sabiki_hook_states[hook_index] = hook_state
		_set_sabiki_fish_heading(visual, str(hook_state.get("species_id", "herring")), float(hook_state.get("body_length_m", 0.32)), _fight_radial_direction, sin(elapsed * 7.0) * 0.055)


func _reset_sabiki_hook_states() -> void:
	_sabiki_hook_states.clear()
	if _current_rig == null or _current_rig.rig_type != BoatFishingRigProfile.RigType.SABIKI:
		return
	for hook_index in range(_current_rig.hook_count):
		_sabiki_hook_states.append({
			"hook_index": hook_index,
			"status": "empty",
			"species_id": "",
			"body_length_m": 0.0,
			"debug_spawned": false,
			"pending": null,
			"visual": null,
			"surface_crossed": false,
		})


func _find_empty_sabiki_hook() -> int:
	for hook_index in range(_sabiki_hook_states.size()):
		if str(_sabiki_hook_states[hook_index].get("status", "empty")) == "empty":
			return hook_index
	return -1


func _clear_sabiki_hook_visuals() -> void:
	for hook_state in _sabiki_hook_states:
		var visual := hook_state.get("visual") as Node3D
		if visual != null and is_instance_valid(visual):
			visual.queue_free()


func _clear_sabiki_hook_state(hook_index: int, release_reservation: bool) -> void:
	if hook_index < 0 or hook_index >= _sabiki_hook_states.size():
		return
	var hook_state: Dictionary = _sabiki_hook_states[hook_index]
	var visual := hook_state.get("visual") as Node3D
	if visual != null and is_instance_valid(visual):
		visual.queue_free()
	if release_reservation and _encounter != null:
		var catch_id := str(hook_state.get("catch_id", ""))
		if not catch_id.is_empty():
			_encounter.release_sabiki_reservation(catch_id)
	_sabiki_hook_states[hook_index] = {
		"hook_index": hook_index,
		"status": "empty",
		"species_id": "",
		"body_length_m": 0.0,
		"debug_spawned": false,
		"pending": null,
		"visual": null,
		"surface_crossed": false,
	}


func _cancel_sabiki_approach_reservations() -> void:
	for hook_index in range(_sabiki_hook_states.size()):
		var status := str(_sabiki_hook_states[hook_index].get("status", "empty"))
		if status in ["approaching", "reserved"]:
			_clear_sabiki_hook_state(hook_index, true)


func _create_sabiki_fish_visual(species_id: String, body_length_m: float, heading: Vector3) -> Node3D:
	var profile := _fish_manager.get_species_profile(species_id) if _fish_manager != null else null
	if profile == null or profile.model_path.is_empty():
		return null
	var packed := ResourceLoader.load(profile.model_path) as PackedScene
	if packed == null:
		return null
	var fish := packed.instantiate() as Node3D
	if fish == null:
		return null
	fish.name = "SabikiHookFish_%02d" % (_sabiki_hook_states.size() + 1)
	add_child(fish)
	for mesh_node in fish.find_children("*", "MeshInstance3D", true, false):
		(mesh_node as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var direction := heading.normalized() if heading.length_squared() > 0.001 else Vector3.FORWARD
	var scale_factor := maxf(0.05, body_length_m / 1.2)
	fish.global_basis = FishSchoolRenderer.basis_for_model_heading(direction, profile.model_forward_axis).scaled(Vector3.ONE * scale_factor)
	return fish


func _set_sabiki_fish_heading(fish: Node3D, species_id: String, body_length_m: float, heading: Vector3, roll_radians: float) -> void:
	if fish == null or not is_instance_valid(fish):
		return
	var profile := _fish_manager.get_species_profile(species_id) if _fish_manager != null else null
	if profile == null:
		return
	var direction := heading.normalized() if heading.length_squared() > 0.001 else Vector3.FORWARD
	var basis := FishSchoolRenderer.basis_for_model_heading(direction, profile.model_forward_axis)
	basis = basis.rotated(direction, roll_radians)
	fish.global_basis = basis.scaled(Vector3.ONE * maxf(0.05, body_length_m / 1.2))


func _depth_below_surface_at(position: Vector3) -> float:
	var sample := _sample_water(position)
	return maxf(0.0, float(sample.get("height", position.y)) - position.y)


func _is_waiting_line_state() -> bool:
	return _state in [CastState.WAITING, CastState.SABIKI_HOOKED_WAITING]


func _begin_bite_event(candidate: Dictionary, debug_spawned: bool, force_approach: bool) -> bool:
	if _encounter == null or candidate.is_empty():
		return false
	var pending := _encounter.begin_boat_fishing_approach(candidate, debug_spawned)
	if pending == null:
		return false
	_bite_candidate = candidate.duplicate(true)
	_bite_debug_spawned = debug_spawned
	_active_catch_id = pending.catch_id
	_active_catch_species_id = pending.species_id
	_bite_elapsed = 0.0
	_bite_fish_visual = null
	var species := _fish_manager.get_species_profile(pending.species_id) if _fish_manager != null else null
	var depth_m := _get_bait_depth_below_surface_m()
	var should_approach := should_visualize_bite_approach(depth_m, shallow_bite_visual_depth_m, force_approach)
	var school_start := _bait_world
	if not debug_spawned:
		var school: Dictionary = _fish_manager.get_school(pending.school_id) if _fish_manager != null else {}
		var values: Array = school.get("world_position", [])
		if values.size() >= 3:
			school_start = Vector3(float(values[0]), 0.0, float(values[2]))
	if should_approach:
		var to_bait := Vector3(_bait_world.x - school_start.x, 0.0, _bait_world.z - school_start.z)
		if to_bait.length_squared() < 0.01:
			var seed_angle := float(absi(pending.school_id.hash() if not debug_spawned else pending.catch_id.hash()) % 6283) / 1000.0
			to_bait = Vector3(cos(seed_angle), 0.0, sin(seed_angle))
		to_bait = to_bait.normalized()
		var start_distance := clampf(Vector2(_bait_world.x - school_start.x, _bait_world.z - school_start.z).length(), 2.8, 5.5)
		if debug_spawned:
			var boat_forward := -_boat_controller.global_basis.z if _boat_controller != null else Vector3.FORWARD
			boat_forward.y = 0.0
			to_bait = boat_forward.normalized() if boat_forward.length_squared() > 0.001 else Vector3.FORWARD
			start_distance = 3.2
		_bite_fish_start_world = _bait_world - to_bait * start_distance
		var start_surface := float(_sample_water(_bite_fish_start_world).get("height", _bait_world.y))
		var fish_depth := float(candidate.get("activity_depth_m", depth_m))
		_bite_fish_start_world.y = start_surface - fish_depth
		_bite_fish_side_world = to_bait.cross(Vector3.UP).normalized()
		var movement_speed := 1.0
		if species != null:
			movement_speed = maxf(0.25, (species.movement_speed_min_mps + species.movement_speed_max_mps) * 0.5)
		_bite_duration = clampf(start_distance / movement_speed, 1.0, 4.5)
		_bite_fish_visual = _create_transient_fish_visual(pending.species_id, pending.body_length_m, to_bait)
		if _bite_fish_visual != null:
			_bite_fish_visual.global_position = _bite_fish_start_world
	else:
		_bite_duration = 0.0
		_bite_fish_start_world = _bait_world
	set_automatic_control_owned(true)
	_manual_reeling = false
	_manual_line_releasing = false
	_manual_reeling_input_held = false
	_manual_line_release_held = false
	_rod_aim_active = false
	_set_boat_fishing_audio_loop("reel_in", false)
	_set_boat_fishing_audio_loop("line_out", false)
	_set_boat_fishing_audio_loop("drag", false)
	if should_approach:
		_set_state(CastState.BITE_APPROACH)
	else:
		_confirm_boat_bite()
	return true


func _advance_bite_approach(delta: float) -> void:
	_bite_elapsed += maxf(0.0, delta)
	var progress := clampf(_bite_elapsed / maxf(_bite_duration, 0.01), 0.0, 1.0)
	var eased := _smoothstep01(progress)
	if _bite_fish_visual != null and is_instance_valid(_bite_fish_visual):
		var travel := _bait_world - _bite_fish_start_world
		var lateral := _bite_fish_side_world * sin(PI * progress) * minf(0.65, travel.length() * 0.08)
		var vertical := Vector3.UP * sin(PI * progress) * 0.16
		_bite_fish_visual.global_position = _bite_fish_start_world.lerp(_bait_world, eased) + lateral + vertical
		_set_transient_fish_heading(_bite_fish_visual, _bait_world - _bite_fish_visual.global_position, sin(_bite_elapsed * 5.5) * 0.035)
	if progress >= 1.0:
		_confirm_boat_bite()


func _confirm_boat_bite() -> void:
	if _encounter == null or not _encounter.confirm_boat_fishing_bite():
		if _bite_fish_visual != null and is_instance_valid(_bite_fish_visual):
			_bite_fish_visual.queue_free()
		_bite_fish_visual = null
		set_automatic_control_owned(false)
		_rod_tension = 0.0
		_rod_bend_angle_deg = 0.0
		_set_rod_bend_angle(0.0)
		_bite_candidate.clear()
		_bite_debug_spawned = false
		_active_catch_id = ""
		_active_catch_species_id = ""
		_set_state(CastState.WAITING)
		return
	var pending := _encounter.pending_catch
	if pending == null:
		return
	_active_catch_id = pending.catch_id
	_active_catch_species_id = pending.species_id
	_fight_start_bait_world = _bait_world
	_fight_start_bait_depth_m = _get_bait_depth_below_surface_m()
	_fight_line_burst_offset_m = 0.0
	var horizontal := Vector3(_bait_world.x - _get_rod_tip_world().x, 0.0, _bait_world.z - _get_rod_tip_world().z)
	_fight_start_horizontal_distance_m = horizontal.length()
	_fight_radial_direction = horizontal.normalized() if horizontal.length_squared() > 0.001 else -_boat_controller.global_basis.z.normalized() if _boat_controller != null else Vector3.FORWARD
	if _bite_fish_visual == null:
		_bite_fish_visual = _create_transient_fish_visual(pending.species_id, pending.body_length_m, _fight_radial_direction)
	if _bite_fish_visual != null:
		_bite_fish_visual.global_position = _bait_world + Vector3.UP * 0.20
	_rod_tension = 0.92
	_rod_bend_angle_deg = rod_bend_at_full_tension_deg * _rod_tension
	_set_rod_bend_angle(deg_to_rad(_rod_bend_angle_deg))
	_catch_result_received = false
	_catch_presentation_elapsed = 0.0
	_set_state(CastState.FIGHTING)


func _advance_auto_fight(delta: float) -> void:
	if _fishing_audio_system == null or _encounter == null:
		if _encounter != null:
			_encounter.cancel_boat_fishing_catch("fight_controller_unavailable")
		set_automatic_control_owned(false)
		_rod_tension = 0.0
		_rod_bend_angle_deg = 0.0
		_set_rod_bend_angle(0.0)
		_set_state(CastState.WAITING)
		return
	var snapshot := _fishing_audio_system.get_presentation_snapshot()
	if str(snapshot.get("catch_id", "")) != _active_catch_id or str(snapshot.get("source", "")) != "REAL_CATCH":
		return
	var phase := str(snapshot.get("phase", "NONE"))
	var phase_elapsed := float(snapshot.get("phase_elapsed_seconds", 0.0))
	var line_out_reference := maxf(0.1, float(snapshot.get("line_out_reference_m", 9.0)))
	var near_boat_reference := maxf(0.1, float(snapshot.get("near_boat_line_reference_m", 2.7)))
	var load_target := float(snapshot.get("rod_load_ratio", 0.72))
	_rod_tension = move_toward(_rod_tension, clampf(maxf(load_target, 0.32), 0.0, 1.0), maxf(delta, 0.0) * 1.8)
	_rod_bend_angle_deg = rod_bend_at_full_tension_deg * _rod_tension
	_set_rod_bend_angle(deg_to_rad(_rod_bend_angle_deg))
	var retrieval_progress := 0.0
	var phase_duration := 0.0
	var expected_p3_line_distance := line_out_reference
	if phase == "PROGRESSIVE_RETRIEVAL":
		phase_duration = maxf(_fishing_audio_system.progressive_retrieval_seconds, 0.01)
		retrieval_progress = clampf(phase_elapsed / phase_duration, 0.0, 1.0)
		expected_p3_line_distance = lerpf(line_out_reference, near_boat_reference, retrieval_progress)
	elif phase == "SURFACE_LANDING":
		phase_duration = maxf(_fishing_audio_system.surface_landing_seconds, 0.01)
		retrieval_progress = clampf(phase_elapsed / phase_duration, 0.0, 1.0)
		expected_p3_line_distance = near_boat_reference
	elif phase == "CATCH_PRESENTATION":
		if _catch_result_received:
			_set_state(CastState.CATCH_PRESENTATION)
			_advance_catch_presentation(delta)
		return
	_fight_line_burst_offset_m = move_toward(
		_fight_line_burst_offset_m,
		get_automatic_line_burst_offset_m(str(snapshot.get("line_state", "")), float(snapshot.get("line_distance_m", expected_p3_line_distance)), expected_p3_line_distance),
		maxf(delta, 0.0) * 8.0
	)
	if phase == "PROGRESSIVE_RETRIEVAL":
		_update_auto_retrieval_position(retrieval_progress, lerpf(_fight_start_bait_depth_m, 1.1, retrieval_progress), lerpf(_fight_start_horizontal_distance_m, 2.3, retrieval_progress))
	elif phase == "SURFACE_LANDING":
		_update_auto_retrieval_position(1.0, lerpf(1.1, 0.12, retrieval_progress), lerpf(2.3, 1.55, retrieval_progress))
	else:
		_update_auto_retrieval_position(0.0, _fight_start_bait_depth_m, _fight_start_horizontal_distance_m)
	_update_bite_fish_pose(delta, phase, retrieval_progress)


func _update_auto_retrieval_position(_progress: float, target_depth_m: float, horizontal_distance_m: float) -> void:
	var tip := _get_rod_tip_world()
	var xz_direction := Vector2(_fight_radial_direction.x, _fight_radial_direction.z)
	if xz_direction.length_squared() < 0.001:
		xz_direction = Vector2(0.0, -1.0)
	xz_direction = xz_direction.normalized()
	var target_xz := Vector2(tip.x, tip.z) + xz_direction * maxf(0.25, horizontal_distance_m + _fight_line_burst_offset_m)
	var target := Vector3(target_xz.x, tip.y, target_xz.y)
	var surface_y := float(_sample_water(target).get("height", tip.y))
	target.y = surface_y - maxf(0.08, target_depth_m)
	_bait_world = target
	_bait_velocity_world = Vector3.ZERO
	_clamp_bait_to_water_column()
	_line_paid_out_length_m = clampf(tip.distance_to(_bait_world), 0.55, maximum_line_length_m)
	_rod_tension = maxf(_rod_tension, 0.65)


func _update_bite_fish_pose(delta: float, phase: String, retrieval_progress: float) -> void:
	if _bite_fish_visual == null or not is_instance_valid(_bite_fish_visual):
		return
	var target := _bait_world + Vector3.UP * 0.18
	if phase == "SURFACE_LANDING":
		var surface_y := float(_sample_water(_bait_world).get("height", _bait_world.y))
		target.y = maxf(target.y, surface_y + 0.10)
		target.x += sin(Time.get_ticks_msec() * 0.004) * 0.08
	_bite_fish_visual.global_position = _bite_fish_visual.global_position.lerp(target, 1.0 - exp(-maxf(delta, 0.0) * 4.0))
	_set_transient_fish_heading(_bite_fish_visual, _get_rod_tip_world() - _bite_fish_visual.global_position, sin(Time.get_ticks_msec() * 0.006) * 0.06 * (0.4 + retrieval_progress))


func _advance_catch_presentation(delta: float) -> void:
	_catch_presentation_elapsed += maxf(delta, 0.0)
	if _bite_fish_visual != null and is_instance_valid(_bite_fish_visual):
		_set_transient_fish_heading(_bite_fish_visual, _get_rod_tip_world() - _bite_fish_visual.global_position, sin(_catch_presentation_elapsed * 7.0) * 0.08)
	if _catch_result_received and _fishing_audio_system != null:
		var snapshot := _fishing_audio_system.get_presentation_snapshot()
		if str(snapshot.get("source", "")) == "NONE" or str(snapshot.get("phase", "NONE")) == "NONE":
			clear_cast()


func _on_authority_catch_succeeded(result: FishingCatchResult) -> void:
	if result == null or result.catch_id != _active_catch_id or result.fishing_method != "boat_fishing":
		return
	if _sabiki_batch_retrieval_active or result.rig_id == str(SABIKI_RIG_PROFILE.rig_id):
		return
	_catch_result_received = true
	_set_boat_fishing_audio_loop("line_out", false)
	_set_boat_fishing_audio_loop("reel_in", false)
	_set_boat_fishing_audio_loop("drag", false)
	report_catch_succeeded(result.catch_id)
	if _bite_fish_visual != null and is_instance_valid(_bite_fish_visual):
		var surface_y := float(_sample_water(_bite_fish_visual.global_position).get("height", _bite_fish_visual.global_position.y))
		_bite_fish_visual.global_position.y = maxf(_bite_fish_visual.global_position.y, surface_y + 0.08)
		_show_splash_visual(_bite_fish_visual.global_position)
	_set_state(CastState.CATCH_PRESENTATION)


func _on_authority_catch_cancelled(catch_id: String, _reason: String) -> void:
	if catch_id.is_empty() or catch_id != _active_catch_id or _catch_result_received:
		return
	if _bite_fish_visual != null and is_instance_valid(_bite_fish_visual):
		_bite_fish_visual.queue_free()
	_bite_fish_visual = null
	_bite_candidate.clear()
	_active_catch_id = ""
	set_automatic_control_owned(false)
	_rod_tension = 0.0
	_rod_bend_angle_deg = 0.0
	_set_rod_bend_angle(0.0)
	_bite_debug_spawned = false
	_catch_result_received = false
	if _sabiki_batch_retrieval_active:
		_clear_sabiki_hook_visuals()
		_reset_sabiki_hook_states()
		_sabiki_batch_retrieval_active = false
		_sabiki_batch_catch_count = 0
	if _activity_active and _state in [CastState.BITE_APPROACH, CastState.FIGHTING]:
		_set_state(CastState.WAITING)


func _on_sabiki_batch_settled(batch_id: String, results: Array) -> void:
	if not _sabiki_batch_retrieval_active or batch_id.is_empty() or results.is_empty():
		return
	var species_counts: Dictionary = {}
	var total_weight_kg := 0.0
	for result_variant in results:
		var result := result_variant as FishingCatchResult
		if result == null:
			continue
		species_counts[result.species_id] = int(species_counts.get(result.species_id, 0)) + 1
		total_weight_kg += result.estimated_weight_kg
	_sabiki_batch_result_summary = {
		"batch_id": batch_id,
		"catch_count": results.size(),
		"species_counts": species_counts,
		"total_weight_kg": total_weight_kg,
	}
	_catch_result_received = true
	_set_boat_fishing_audio_loop("line_out", false)
	_set_boat_fishing_audio_loop("reel_in", false)
	_set_boat_fishing_audio_loop("drag", false)
	report_catch_succeeded(batch_id)
	_set_state(CastState.CATCH_PRESENTATION)
	interaction_updated.emit(get_interaction_snapshot())


func _create_transient_fish_visual(species_id: String, body_length_m: float, heading: Vector3) -> Node3D:
	var profile := _fish_manager.get_species_profile(species_id) if _fish_manager != null else null
	if profile == null or profile.model_path.is_empty():
		return null
	var packed := ResourceLoader.load(profile.model_path) as PackedScene
	if packed == null:
		return null
	var fish := packed.instantiate() as Node3D
	if fish == null:
		return null
	fish.name = "TemporaryBoatCatchFish"
	add_child(fish)
	var meshes: Array[Node] = fish.find_children("*", "MeshInstance3D", true, false)
	for mesh_node in meshes:
		(mesh_node as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var scale_factor := maxf(0.05, body_length_m / 1.2)
	_bite_visual_scale = scale_factor
	fish.global_basis = FishSchoolRenderer.basis_for_model_heading(heading, profile.model_forward_axis).scaled(Vector3.ONE * scale_factor)
	return fish


func _set_transient_fish_heading(fish: Node3D, heading: Vector3, roll_radians: float) -> void:
	if fish == null or not is_instance_valid(fish):
		return
	var profile := _fish_manager.get_species_profile(_active_catch_species_id) if _fish_manager != null and not _active_catch_species_id.is_empty() else null
	if profile == null:
		return
	var direction := heading
	if direction.length_squared() < 0.001:
		direction = Vector3.FORWARD
	var basis := FishSchoolRenderer.basis_for_model_heading(direction, profile.model_forward_axis)
	basis = basis.rotated(direction.normalized(), roll_radians)
	fish.global_basis = basis.scaled(Vector3.ONE * _bite_visual_scale)


func _world_game_time_seconds() -> float:
	return maxf(0.0, float(_fish_manager.call("get_world_game_time_seconds"))) if _fish_manager != null and _fish_manager.has_method("get_world_game_time_seconds") else 0.0


func _smoothstep01(value: float) -> float:
	var t := clampf(value, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func _update_ready_rod_pose() -> void:
	if _onboard == null or _rod_visual_root == null:
		return
	var player_position := _onboard.get_player_local_position()
	var player_yaw := _onboard.get_player_local_yaw()
	var heading := Basis(Vector3.UP, player_yaw)
	_rod_visual_root.position = player_position + heading * Vector3(0.31, 1.13, -0.02)
	_rod_visual_root.rotation = Vector3(
		clampf(_onboard.get_camera_pitch() * 0.18, -0.18, 0.12),
		player_yaw,
		0.0
	)
	_rod_swing.rotation = Vector3.ZERO
	_rod_back_angle_deg = 0.0
	_rod_bend_angle_deg = 0.0
	_set_rod_bend_angle(0.0)


func _update_charge_animation(delta: float) -> void:
	if _charge_canceling:
		_charge_cancel_elapsed += delta
		var return_progress := clampf(_charge_cancel_elapsed / CHARGE_CANCEL_DURATION_SECONDS, 0.0, 1.0)
		var remaining := 1.0 - _ease_out(return_progress)
		_update_ready_rod_pose()
		_rod_back_angle_deg = _charge_cancel_start_back_deg * remaining
		_rod_bend_angle_deg = _charge_cancel_start_bend_deg * remaining
		_apply_rod_pose()
		charge_progress_changed.emit(get_charge_progress() * remaining, true)
		if return_progress >= 1.0:
			_charge_elapsed = 0.0
			_charge_canceling = false
			_rod_back_angle_deg = 0.0
			_rod_bend_angle_deg = 0.0
			_apply_rod_pose()
			charge_progress_changed.emit(0.0, false)
			_set_state(CastState.READY)
		return
	_update_ready_rod_pose()
	if _charge_input_held:
		_charge_elapsed = minf(cast_charge_full_time, _charge_elapsed + maxf(delta, 0.0))
	var pose := _charge_pose_for_elapsed(_charge_elapsed)
	_rod_back_angle_deg = float(pose["back_angle_deg"])
	_rod_bend_angle_deg = float(pose["bend_angle_deg"])
	_apply_rod_pose()
	charge_progress_changed.emit(get_charge_progress(), true)


func _charge_pose_for_elapsed(elapsed_seconds: float) -> Dictionary:
	var elapsed := clampf(elapsed_seconds, 0.0, maxf(cast_charge_full_time, 0.01))
	var lift_end := minf(CHARGE_LIFT_TIME_SECONDS, cast_charge_full_time * 0.16)
	var middle_end := minf(CHARGE_MIDPOINT_SECONDS, cast_charge_full_time * 0.6)
	if elapsed <= lift_end:
		var t := _ease_in_out(elapsed / maxf(lift_end, 0.01))
		return {
			"back_angle_deg": lerpf(0.0, 25.0, t),
			"bend_angle_deg": lerpf(0.0, 6.0, t),
		}
	if elapsed <= middle_end:
		var t := _ease_in_out((elapsed - lift_end) / maxf(middle_end - lift_end, 0.01))
		return {
			"back_angle_deg": lerpf(25.0, 47.0, t),
			"bend_angle_deg": lerpf(6.0, 17.0, t),
		}
	var t := _ease_in_out((elapsed - middle_end) / maxf(cast_charge_full_time - middle_end, 0.01))
	return {
		"back_angle_deg": lerpf(47.0, cast_max_back_angle_deg, t),
		"bend_angle_deg": lerpf(17.0, cast_full_bend_angle_deg, t),
	}


func _set_charge_pose(elapsed_seconds: float) -> void:
	var pose := _charge_pose_for_elapsed(elapsed_seconds)
	_rod_back_angle_deg = float(pose["back_angle_deg"])
	_rod_bend_angle_deg = float(pose["bend_angle_deg"])
	_apply_rod_pose()


func _apply_rod_pose() -> void:
	if _rod_swing != null:
		_rod_swing.rotation.x = deg_to_rad(_rod_back_angle_deg)
	_set_rod_bend_angle(deg_to_rad(_rod_bend_angle_deg))


func _set_rod_bend_angle(angle_radians: float) -> void:
	if _rod_shader_material != null:
		_rod_shader_material.set_shader_parameter("bend_angle", angle_radians)


func _update_cast_animation(delta: float) -> void:
	_state_elapsed += delta
	var release_progress := clampf(_state_elapsed / maxf(cast_release_duration, 0.01), 0.0, 1.0)
	if _state_elapsed <= cast_release_duration:
		_rod_swing.rotation.x = deg_to_rad(lerpf(_rod_back_angle_deg, -16.0, _ease_out(release_progress)))
		_rod_bend_angle_deg = lerpf(_rod_release_start_bend_deg, 0.0, _ease_out(release_progress))
		_set_rod_bend_angle(deg_to_rad(_rod_bend_angle_deg))
	else:
		var recovery_elapsed := _state_elapsed - cast_release_duration
		var recovery_progress := clampf(recovery_elapsed / maxf(cast_recovery_duration, 0.01), 0.0, 1.0)
		var damping := exp(-5.0 * recovery_elapsed)
		var recovery_angle := -16.0 * damping * cos(13.0 * recovery_elapsed)
		_rod_swing.rotation.x = deg_to_rad(lerpf(recovery_angle, 0.0, _ease_in_out(recovery_progress)))
		_rod_bend_angle_deg = 0.0
		_set_rod_bend_angle(0.0)
	_rod_visual_root.position = _rod_locked_position
	_rod_visual_root.rotation = _rod_locked_rotation
	if not _bait_flight_started and _state_elapsed >= CAST_BAIT_RELEASE_OFFSET_SECONDS:
		_start_bait_flight()
	if _bait_flight_started and not _cast_tackle_entry_complete:
		_update_bait_flight(delta)
	_rod_recovery_complete = _state_elapsed >= cast_release_duration + cast_recovery_duration
	if _cast_tackle_entry_complete and _rod_recovery_complete:
		_state_elapsed = 0.0
		_waiting_elapsed = 0.0
		_rod_swing.rotation = Vector3.ZERO
		_rod_back_angle_deg = 0.0
		_rod_bend_angle_deg = 0.0
		_set_rod_bend_angle(0.0)
		_rod_aim_yaw_deg = 0.0
		_rod_aim_pitch_deg = 0.0
		var line_connection := _get_tackle_line_connection_world()
		_line_paid_out_length_m = clampf(_get_rod_tip_world().distance_to(line_connection), 0.55, maximum_line_length_m)
		_previous_line_connection_world = line_connection
		_has_previous_line_connection = true
		_set_state(CastState.WAITING)


func _start_bait_flight() -> void:
	if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
		_reset_sabiki_hook_states()
	_bait_flight_started = true
	_bait_flight_elapsed = 0.0
	_cast_tackle_entry_complete = false
	_bait_has_landed = false
	_bait_airborne_retrieval = false
	_airborne_retrieval_elapsed = 0.0
	_sabiki_retrieval_taut = false
	var rod_tip := _get_rod_tip_world()
	if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
		var initial_guess := rod_tip - Vector3.UP * _current_rig.get_line_attachment_height_m()
		_bait_world = rod_tip - _get_sabiki_up_direction_for_sinker(initial_guess) * _current_rig.get_line_attachment_height_m()
	else:
		_bait_world = rod_tip - _lure_visual_basis_world * Vector3.UP * SPOON_LINE_EYE_Y_M
	_cast_start_world = _bait_world
	_bait_instance.visible = true
	_line_instance.visible = true
	_bait_velocity_world = _boat_velocity_estimate_world * 0.12


func _update_bait_flight(delta: float) -> void:
	if _bait_has_landed:
		_advance_cast_tackle_water_entry(delta)
		return
	_bait_flight_elapsed += delta
	var progress := clampf(_bait_flight_elapsed / maxf(_bait_flight_duration, 0.01), 0.0, 1.0)
	var target_world := _cast_target_world + _bait_velocity_world * minf(_bait_flight_elapsed, 0.45)
	_bait_world = _cast_start_world.lerp(target_world, progress)
	_bait_world.y += sin(PI * progress) * CAST_ARC_HEIGHT_M * maxf(0.38, sqrt(_get_cast_range_ratio()))
	if progress >= 1.0:
		var water_sample := _sample_water(target_world)
		_bait_world = target_world
		_bait_world.y = float(water_sample.get("height", _cast_target_world.y)) + 0.018
		_clamp_bait_to_water_column()
		_bait_has_landed = true
		if _current_rig.rig_type == BoatFishingRigProfile.RigType.SINGLE_JIG:
			_cast_tackle_entry_complete = true
		_splash_elapsed = 0.0
		_splash_instance.position = to_local(_bait_world)
		_splash_instance.scale = Vector3.ONE * 0.28
		_splash_instance.visible = true
		_previous_boat_world = _boat_controller.global_position if _boat_controller != null else Vector3.ZERO


func _advance_cast_tackle_water_entry(delta: float) -> void:
	if _current_rig.rig_type != BoatFishingRigProfile.RigType.SABIKI or delta <= 0.0:
		_cast_tackle_entry_complete = true
		return
	var boat_flow := Vector3(_boat_velocity_estimate_world.x, 0.0, _boat_velocity_estimate_world.z)
	var horizontal_velocity := Vector3(_bait_velocity_world.x, 0.0, _bait_velocity_world.z)
	var response := 1.0 - exp(-BAIT_WATER_DRAG_RESPONSE * delta)
	horizontal_velocity = horizontal_velocity.lerp(boat_flow * BAIT_WATER_DRAG_FOLLOW, response)
	_bait_velocity_world.x = horizontal_velocity.x
	_bait_velocity_world.z = horizontal_velocity.z
	_bait_velocity_world.y = move_toward(
		_bait_velocity_world.y,
		-_current_rig.sink_speed_mps,
		BAIT_SINK_ACCELERATION_MPS2 * delta
	)
	_bait_world += _bait_velocity_world * delta
	_clamp_bait_to_water_column()
	if _is_tackle_fully_submerged() or _sinker_is_resting_on_seabed():
		_cast_tackle_entry_complete = true
		_bait_velocity_world.y = minf(_bait_velocity_world.y, 0.0)


func _sinker_is_resting_on_seabed() -> bool:
	var seabed := _sample_seabed(_bait_world)
	if not bool(seabed.get("valid", false)):
		return false
	var resting_y := float(seabed["bottom_world_y"]) + SEABED_CLEARANCE_M
	return _bait_world.y <= resting_y + 0.015


func _update_splash(delta: float) -> void:
	if not _splash_instance.visible:
		return
	_splash_elapsed += delta
	var progress := clampf(_splash_elapsed / SPLASH_DURATION_SECONDS, 0.0, 1.0)
	_splash_instance.scale = Vector3.ONE * lerpf(0.28, 1.35, _ease_out(progress))
	if _splash_instance.material_override is StandardMaterial3D:
		var material := _splash_instance.material_override as StandardMaterial3D
		var splash_color := Color(0.55, 0.83, 0.88, 1.0 - progress)
		material.albedo_color = splash_color
		material.emission = Color(0.12, 0.31, 0.36, 1.0 - progress)
	if progress >= 1.0:
		_splash_instance.visible = false


func _update_cast_aim_marker(delta: float) -> void:
	if _cast_aim_marker == null:
		return
	var can_preview := (
		_activity_active
		and _state in [CastState.READY, CastState.CHARGING]
		and _onboard != null
		and _onboard.is_first_person_active()
		and not _is_menu_open()
		and not _is_pointer_over_ui()
	)
	if not can_preview:
		_cast_aim_marker.visible = false
		_cast_aim_preview_elapsed = 0.0
		return
	_cast_aim_preview_elapsed += maxf(delta, 0.0)
	if _cast_aim_marker.visible and _cast_aim_preview_elapsed < cast_aim_preview_interval_seconds:
		return
	_cast_aim_preview_elapsed = 0.0
	var camera := _onboard.get_activity_camera()
	if camera == null or not camera.current:
		_cast_aim_marker.visible = false
		return
	var charge_ratio := get_charge_progress() if _state == CastState.CHARGING else 0.0
	var cast_distance := _get_cast_distance_for_charge(charge_ratio)
	var aim_result := _evaluate_cast_aim(camera, cast_distance)
	var marker_position: Vector3
	if aim_result.has("position"):
		marker_position = aim_result["position"]
	else:
		marker_position = _get_aim_preview_fallback_position(camera, cast_distance)
	var surface_sample := _sample_water(marker_position)
	marker_position.y = float(surface_sample.get("height", marker_position.y)) + 0.12
	var distance := camera.global_position.distance_to(marker_position)
	var marker_scale := clampf(0.70 + distance * 0.024, 0.70, 1.35)
	_cast_aim_marker.global_transform = Transform3D(
		Basis.IDENTITY.scaled(Vector3.ONE * marker_scale),
		marker_position
	)
	var is_valid := bool(aim_result.get("valid", false))
	var marker_color := Color(0.18, 0.96, 0.43, 0.96) if is_valid else Color(1.0, 0.24, 0.20, 0.96)
	_cast_aim_marker_material.albedo_color = marker_color
	_cast_aim_marker_material.emission = marker_color.darkened(0.48)
	_cast_aim_marker.visible = true


func _update_waiting_bait(delta: float) -> void:
	_waiting_elapsed += delta
	if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI and _manual_reeling:
		_sabiki_retrieval_taut = true
	if _bait_airborne_retrieval:
		_airborne_retrieval_elapsed += maxf(delta, 0.0)
	_apply_waiting_rod_pose()
	var boat_velocity := _boat_velocity_estimate_world
	var horizontal_velocity := Vector3(_bait_velocity_world.x, 0.0, _bait_velocity_world.z)
	var target_velocity := Vector3(boat_velocity.x, 0.0, boat_velocity.z) * BAIT_WATER_DRAG_FOLLOW
	var response := 1.0 - exp(-BAIT_WATER_DRAG_RESPONSE * delta)
	horizontal_velocity = horizontal_velocity.lerp(target_velocity, response)
	_bait_velocity_world.x = horizontal_velocity.x
	_bait_velocity_world.z = horizontal_velocity.z
	if _bait_airborne_retrieval:
		# Once the tackle clears the surface it behaves like a small suspended
		# weight. Keep its momentum, let gravity swing it, and damp the motion.
		_bait_velocity_world.y -= AIRBORNE_BAIT_GRAVITY_MPS2 * delta
		_bait_velocity_world *= exp(-AIRBORNE_BAIT_DAMPING_PER_SECOND * delta)
	else:
		var vertical_velocity_target := -_current_rig.sink_speed_mps
		if _manual_reeling:
			# Active retrieval counters passive sinking; rod-tip tension supplies the
			# upward motion as the line is shortened.
			vertical_velocity_target = 0.0
		_bait_velocity_world.y = move_toward(
			_bait_velocity_world.y,
			vertical_velocity_target,
			BAIT_SINK_ACCELERATION_MPS2 * delta
		)
	_bait_world += _bait_velocity_world * delta
	var line_connection := _get_tackle_line_connection_world()
	var tip_delta := Vector3.ZERO
	if _has_previous_line_connection and delta > 0.0001:
		tip_delta = line_connection - _previous_line_connection_world
	_previous_line_connection_world = line_connection
	_has_previous_line_connection = true
	if _manual_reeling:
		_line_paid_out_length_m = maxf(
			MINIMUM_MANUAL_RETRIEVAL_LINE_M,
			_line_paid_out_length_m - manual_reel_speed_mps * delta
		)
	elif _manual_line_releasing:
		_line_paid_out_length_m = minf(maximum_line_length_m, _line_paid_out_length_m + manual_line_release_speed_mps * delta)
	# In WAITING the paid-out length is an explicit player-controlled quantity.
	# Do not silently let line out to match bait drift or hull movement; only the
	# F payout control changes it here. Automatic fight line bursts are handled
	# by the separate fight authority path.
	var rod_tip := _get_rod_tip_world()
	line_connection = _get_tackle_line_connection_world()
	var line_distance := rod_tip.distance_to(line_connection)
	var tension_target := clampf(
		(line_distance - _line_paid_out_length_m + line_tension_slack_m * 0.5) / maxf(line_tension_slack_m, 0.01),
		0.0,
		1.0
	)
	if _bait_airborne_retrieval:
		# A bare lure has much less load than a fish; keep the rod from holding
		# the underwater fight bend after the lure clears the water.
		tension_target = minf(tension_target, 0.32)
	_rod_tension = lerpf(_rod_tension, tension_target, 1.0 - exp(-7.0 * delta))
	if _rod_tension > 0.12 and tip_delta.length_squared() > 0.0:
		_bait_world += tip_delta.limit_length(0.22) * _rod_tension * 0.32
	line_connection = _get_tackle_line_connection_world()
	line_distance = rod_tip.distance_to(line_connection)
	var line_excess := line_distance - _line_paid_out_length_m
	if line_excess > 0.001:
		var toward_rod := (rod_tip - line_connection).normalized()
		var pull_amount := minf(line_excess, line_pull_response * _rod_tension * delta)
		_bait_world += toward_rod * pull_amount
		if _bait_airborne_retrieval and delta > 0.0001:
			# Retain a little of the reel's pull as tangential motion so the tackle
			# swings instead of sliding along the previous straight line angle.
			_bait_velocity_world = (_bait_velocity_world + toward_rod * pull_amount / delta * 0.42).limit_length(3.0)
		var outward_speed := _bait_velocity_world.dot(-toward_rod)
		if outward_speed > 0.0:
			_bait_velocity_world += toward_rod * outward_speed * _rod_tension
	_clamp_bait_to_water_column(_manual_reeling or _bait_airborne_retrieval)
	if _bait_airborne_retrieval:
		_keep_airborne_tackle_above_surface()
	elif _manual_reeling:
		if _is_tackle_fully_above_surface(AIRBORNE_BAIT_SURFACE_CLEARANCE_M):
			_bait_airborne_retrieval = true
			_airborne_retrieval_elapsed = 0.0
			# Preserve the upward release and add a small sideways impulse so the
			# line relaxes into a short pendulum swing instead of keeping its cast angle.
			_bait_velocity_world.y = maxf(_bait_velocity_world.y, 0.45)
			var rod_right := _rod_swing.global_basis.x
			rod_right.y = 0.0
			if rod_right.length_squared() > 0.001:
				_bait_velocity_world += rod_right.normalized() * 0.28
	line_connection = _get_tackle_line_connection_world()
	if _manual_reeling and line_connection.distance_to(rod_tip) <= terminal_tackle_recovery_margin_m:
		if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI and get_sabiki_hooked_count() > 0:
			request_sabiki_retrieval()
		else:
			_begin_final_retrieval()
	_update_rig_visual_position()


func _keep_airborne_tackle_above_surface() -> void:
	var surface_y := float(_sample_water(_bait_world).get("height", _bait_world.y))
	var minimum_y := surface_y + AIRBORNE_BAIT_SURFACE_CLEARANCE_M
	if _bait_world.y >= minimum_y:
		return
	_bait_world.y = minimum_y
	if _bait_velocity_world.y < 0.0:
		# A light, damped contact keeps the retrieved lure skimming above the
		# moving surface without snapping its horizontal swing away.
		_bait_velocity_world.y = -_bait_velocity_world.y * 0.12
	_bait_velocity_world.x *= 0.82
	_bait_velocity_world.z *= 0.82


func _apply_waiting_rod_pose() -> void:
	if _rod_swing == null:
		return
	_rod_swing.rotation = Vector3(deg_to_rad(_rod_aim_pitch_deg), deg_to_rad(_rod_aim_yaw_deg), 0.0)
	var bend_target := _rod_tension * rod_bend_at_full_tension_deg
	var delta := maxf(get_process_delta_time(), 0.0)
	_rod_bend_angle_deg = lerpf(_rod_bend_angle_deg, bend_target, 1.0 - exp(-4.5 * delta))
	_set_rod_bend_angle(deg_to_rad(_rod_bend_angle_deg))
	_rod_back_angle_deg = _rod_aim_pitch_deg


func _begin_final_retrieval() -> void:
	if _state != CastState.WAITING:
		return
	_manual_reeling = false
	_manual_reeling_from_ui = false
	_manual_reeling_input_held = false
	_manual_line_release_held = false
	_manual_line_releasing = false
	_line_controls_conflicted = false
	_rod_aim_active = false
	_retrieve_start_world = _bait_world
	_state_elapsed = 0.0
	_set_state(CastState.RETRIEVING)


func _update_retrieve_animation(delta: float) -> void:
	_state_elapsed += delta
	if _bait_airborne_retrieval:
		_airborne_retrieval_elapsed += maxf(delta, 0.0)
	var progress := clampf(_state_elapsed / RETRIEVE_DURATION_SECONDS, 0.0, 1.0)
	var retrieval_target := _get_tackle_retrieval_target_world()
	_bait_world = _retrieve_start_world.lerp(retrieval_target, _ease_in_out(progress))
	# Keep the reel's visual line length tied to the tackle's actual final travel.
	_line_paid_out_length_m = _get_rod_tip_world().distance_to(_get_tackle_line_connection_world())
	_rod_swing.rotation.z = sin(progress * PI * 5.0) * 0.045 * (1.0 - progress)
	if progress >= 1.0:
		_rod_swing.rotation = Vector3.ZERO
		_bait_instance.visible = false
		if _sabiki_rig_root != null:
			_sabiki_rig_root.visible = false
		_line_instance.visible = false
		_bait_velocity_world = Vector3.ZERO
		_line_paid_out_length_m = 0.0
		_rod_tension = 0.0
		_sabiki_retrieval_taut = false
		_rod_aim_yaw_deg = 0.0
		_rod_aim_pitch_deg = 0.0
		_has_previous_line_connection = false
		_onboard.set_movement_locked(false)
		_set_state(CastState.READY)


func _evaluate_cast_aim(camera: Camera3D, cast_distance_m: float) -> Dictionary:
	if camera == null or not camera.current:
		return {"valid": false, "reason_key": "hud.boat_fishing.cast_first_person"}
	var target_result := _calculate_water_target(
		camera.global_position,
		-camera.global_basis.z.normalized(),
		cast_distance_m
	)
	if not target_result.has("position"):
		target_result["position"] = _get_aim_preview_fallback_position(camera, cast_distance_m)
	if not bool(target_result.get("valid", false)):
		return target_result
	var target: Vector3 = target_result["position"]
	var rod_tip := _get_rod_tip_world()
	var launch_check := validate_cast_launch_position(
		_onboard.get_player_local_position(),
		_onboard.to_local(rod_tip),
		_onboard.to_local(target),
		_onboard.profile.walkable_polygon_xz if _onboard.profile != null else PackedVector2Array(),
		cast_max_distance_from_gunwale_m,
		cast_min_outward_alignment
	)
	if not bool(launch_check.get("valid", false)):
		target_result["valid"] = false
		target_result["reason_key"] = str(launch_check.get("reason_key", "hud.boat_fishing.cast_near_gunwale"))
		return target_result
	if _path_is_blocked(rod_tip, target):
		target_result["valid"] = false
		target_result["reason_key"] = "hud.boat_fishing.cast_blocked"
		return target_result
	if not _target_is_water(target):
		target_result["valid"] = false
		target_result["reason_key"] = "hud.boat_fishing.cast_not_water"
	return target_result


func _get_aim_preview_fallback_position(camera: Camera3D, cast_distance_m: float) -> Vector3:
	var direction := -camera.global_basis.z.normalized()
	var horizontal := Vector2(direction.x, direction.z)
	if horizontal.length_squared() < 0.0025:
		horizontal = Vector2(-camera.global_basis.z.x, -camera.global_basis.z.z)
	if horizontal.length_squared() < 0.0025:
		horizontal = Vector2(0.0, -1.0)
	horizontal = horizontal.normalized()
	var marker_distance := clampf(cast_distance_m, 1.0, maxf(maximum_cast_distance_m, 1.0))
	var point := Vector3(
		camera.global_position.x + horizontal.x * marker_distance,
		camera.global_position.y,
		camera.global_position.z + horizontal.y * marker_distance
	)
	var water_sample := _sample_water(point)
	point.y = float(water_sample.get("height", point.y)) + 0.12
	return point


func _calculate_water_target(origin: Vector3, direction: Vector3, desired_horizontal_range_m: float = -1.0) -> Dictionary:
	if direction.y >= -0.035:
		return {"valid": false, "reason_key": "hud.boat_fishing.cast_aim_down"}
	if _wave_sampler == null or not _wave_sampler.has_method("sample_physics_surface"):
		return {"valid": false, "reason_key": "hud.boat_fishing.cast_surface_unavailable"}
	var time_seconds := float(_wave_sampler.call("get_effective_wave_time_seconds")) if _wave_sampler.has_method("get_effective_wave_time_seconds") else 0.0
	var horizontal_direction := Vector2(direction.x, direction.z)
	if horizontal_direction.length_squared() < 0.0025:
		return {"valid": false, "reason_key": "hud.boat_fishing.cast_aim_down"}
	horizontal_direction = horizontal_direction.normalized()
	var horizontal_range := desired_horizontal_range_m
	var distance_along_ray := 0.0
	if horizontal_range < 0.0:
		var initial_sample := _sample_water(origin, time_seconds)
		distance_along_ray = (float(initial_sample.get("height", origin.y)) - origin.y) / direction.y
		if distance_along_ray <= 0.0:
			return {"valid": false, "reason_key": "hud.boat_fishing.cast_aim_down"}
		horizontal_range = distance_along_ray * horizontal_direction.length()
	var target := Vector3(
		origin.x + horizontal_direction.x * horizontal_range,
		origin.y,
		origin.z + horizontal_direction.y * horizontal_range
	)
	var sample := _sample_water(target, time_seconds)
	target.y = float(sample.get("height", target.y)) + 0.018
	if horizontal_range < minimum_cast_distance_m:
		return {"valid": false, "reason_key": "hud.boat_fishing.cast_too_close", "position": target}
	if horizontal_range > maximum_cast_distance_m:
		return {"valid": false, "reason_key": "hud.boat_fishing.cast_too_far", "position": target}
	if desired_horizontal_range_m < 0.0 and distance_along_ray > maximum_cast_distance_m + 8.0:
		return {"valid": false, "reason_key": "hud.boat_fishing.cast_too_far", "position": target}
	return {"valid": true, "position": target, "horizontal_range_m": horizontal_range}


func _path_is_blocked(origin: Vector3, target: Vector3) -> bool:
	var world := get_world_3d()
	if world == null:
		return false
	var query := PhysicsRayQueryParameters3D.create(origin, target)
	query.collision_mask = 0xFFFFFFFF ^ OnboardActivityController.PLAYER_COLLISION_LAYER
	query.collide_with_areas = false
	var excluded: Array[RID] = []
	if _onboard != null:
		var player := _onboard.find_child("OnboardActivityPlayer", true, false) as CollisionObject3D
		if player != null:
			excluded.append(player.get_rid())
	query.exclude = excluded
	return not world.direct_space_state.intersect_ray(query).is_empty()


func _target_is_water(target: Vector3) -> bool:
	if _bathymetry_manager == null or not bool(_bathymetry_manager.get("data_available")):
		return true
	if not _bathymetry_manager.has_method("get_depth_at_world_position"):
		return true
	var sample: Dictionary = _bathymetry_manager.call("get_depth_at_world_position", target, false)
	return bool(sample.get("valid", false)) and float(sample.get("depth_m", 0.0)) > 0.0


func _sample_water(position: Vector3, time_seconds: float = -1.0) -> Dictionary:
	if _wave_sampler == null:
		return {"height": position.y}
	if time_seconds < 0.0:
		time_seconds = float(_wave_sampler.call("get_effective_wave_time_seconds")) if _wave_sampler.has_method("get_effective_wave_time_seconds") else 0.0
	return _wave_sampler.call("sample_physics_surface", position, time_seconds) as Dictionary


func _get_bait_depth_below_surface_m() -> float:
	if not _bait_flight_started:
		return 0.0
	var water_sample := _sample_water(_bait_world)
	return maxf(0.0, float(water_sample.get("height", _bait_world.y)) - _bait_world.y)


func _get_water_depth_at_bait_m() -> float:
	var seabed := _sample_seabed(_bait_world)
	if not bool(seabed.get("valid", false)):
		return -1.0
	var surface := _sample_water(_bait_world)
	return maxf(0.0, float(surface.get("height", 0.0)) + float(seabed.get("depth_m", 0.0)))


func _sample_seabed(position: Vector3) -> Dictionary:
	if _bathymetry_manager == null or not _bathymetry_manager.has_method("get_depth_at_world_position"):
		return {"valid": false, "reason": "bathymetry_unavailable"}
	if not bool(_bathymetry_manager.get("data_available")):
		return {"valid": false, "reason": "bathymetry_unavailable"}
	var sample: Dictionary = _bathymetry_manager.call("get_depth_at_world_position", position, false)
	if not bool(sample.get("valid", false)) or float(sample.get("depth_m", -1.0)) < 0.0:
		return {"valid": false, "reason": str(sample.get("reason", "bottom_invalid"))}
	return {
		"valid": true,
		"depth_m": float(sample["depth_m"]),
		"bottom_world_y": -float(sample["depth_m"]),
		"vertical_datum": str(sample.get("vertical_datum", "LAT")),
		"source": str(sample.get("source", "")),
	}


func _clamp_bait_to_water_column(allow_above_surface: bool = false) -> void:
	var surface_sample := _sample_water(_bait_world)
	var surface_y := float(surface_sample.get("height", 0.0))
	if not allow_above_surface and _bait_world.y > surface_y + 0.018:
		_bait_world.y = surface_y + 0.018
		_bait_velocity_world.y = minf(0.0, _bait_velocity_world.y)
	var seabed := _sample_seabed(_bait_world)
	if not bool(seabed.get("valid", false)):
		return
	var bottom_y := float(seabed["bottom_world_y"])
	var minimum_y := bottom_y + SEABED_CLEARANCE_M
	if minimum_y > surface_y:
		minimum_y = surface_y
	if _bait_world.y < minimum_y:
		_bait_world.y = minimum_y
		_bait_velocity_world.y = maxf(0.0, _bait_velocity_world.y)


func _sync_manual_line_controls() -> void:
	var wants_reel := _manual_reeling_input_held or _manual_reeling_from_ui
	var wants_release := _manual_line_release_held
	if wants_reel and wants_release:
		_line_controls_conflicted = true
	if _line_controls_conflicted:
		_manual_reeling = false
		_manual_line_releasing = false
		if not wants_reel and not wants_release:
			_line_controls_conflicted = false
		interaction_updated.emit(get_interaction_snapshot())
		return
	var input_valid := _activity_active and _is_waiting_line_state() and not _automatic_control_owned
	_manual_reeling = wants_reel and input_valid
	_manual_line_releasing = wants_release and input_valid
	interaction_updated.emit(get_interaction_snapshot())


func _get_reel_feedback_line_length() -> float:
	match _state:
		CastState.WAITING, CastState.SABIKI_HOOKED_WAITING, CastState.BITE_APPROACH, CastState.FIGHTING, CastState.CATCH_PRESENTATION:
			return maxf(0.0, _line_paid_out_length_m)
		CastState.CASTING, CastState.RETRIEVING:
			if not _bait_flight_started or not is_cast_active():
				return 0.0
			return _get_rod_tip_world().distance_to(_get_tackle_line_connection_world())
		_:
			return 0.0


func _update_reel_visual_and_audio(line_length_before_m: float, line_length_after_m: float, delta: float) -> void:
	var line_delta_m := line_length_after_m - line_length_before_m
	var waiting_without_line_control := (
		_is_waiting_line_state()
		and not _manual_reeling
		and not _manual_line_releasing
		and not _automatic_control_owned
	)
	if waiting_without_line_control:
		# Waiting is mechanically idle unless paid-out line actually changes under
		# player or Authority control. Ignore state-transition and sampling noise.
		line_delta_m = 0.0
	_last_reel_line_delta_m = line_delta_m
	var line_rate_mps := line_delta_m / maxf(delta, 0.0001)
	var state_allows_reel_motion := (
		(_state == CastState.CASTING and _bait_flight_started and not _bait_has_landed)
		or (_is_waiting_line_state() and (_manual_reeling or _manual_line_releasing or _automatic_control_owned))
		or (_state in [CastState.BITE_APPROACH, CastState.FIGHTING, CastState.CATCH_PRESENTATION] and _automatic_control_owned)
		or (_state == CastState.RETRIEVING)
	)
	var reel_speed_rad_s := 0.0
	if state_allows_reel_motion and absf(line_delta_m) >= REEL_LINE_DELTA_EPSILON_M:
		# The same trolling drum assembly is used here. Signed measured line
		# movement drives the drum in either direction; the visual never owns line state.
		reel_speed_rad_s = get_reel_visual_speed_rad_s(line_rate_mps, line_length_after_m)
		if _reel_rotating_assembly != null and absf(reel_speed_rad_s) > 0.01:
			var angular_delta := FishingRodRig.REEL_ROTATION_SIGN * reel_speed_rad_s * maxf(delta, 0.0)
			_reel_rotating_assembly.rotate_object_local(Vector3.UP, angular_delta)
			_reel_visual_total_rotation_rad += angular_delta
	if _reel_rotating_assembly != null:
		_reel_rotating_assembly.set_meta("spin_speed_rad_s", reel_speed_rad_s)
		_reel_rotating_assembly.set_meta("line_out_rate_mps", maxf(line_rate_mps, 0.0))
	FishingRodRig.set_reel_winding_line_length_on_visual(_reel_winding_visual, line_length_after_m)

	var targets := get_boat_fishing_audio_targets(
		_state, line_delta_m, _manual_reeling, _manual_line_releasing,
		_automatic_control_owned, _bait_flight_started, _bait_has_landed
	)
	for key_variant in targets.keys():
		_set_boat_fishing_audio_loop(str(key_variant), bool(targets[key_variant]))


static func get_boat_fishing_audio_targets(state: int, line_delta_m: float, manual_reeling: bool, manual_releasing: bool, automatic_owned: bool, bait_flying: bool, bait_landed: bool) -> Dictionary:
	var moving_in := line_delta_m < -REEL_LINE_DELTA_EPSILON_M
	var moving_out := line_delta_m > REEL_LINE_DELTA_EPSILON_M
	var waiting := state in [CastState.WAITING, CastState.SABIKI_HOOKED_WAITING]
	var auto_fight := state in [CastState.BITE_APPROACH, CastState.FIGHTING, CastState.CATCH_PRESENTATION]
	var retrieval_active := state == CastState.RETRIEVING
	return {
		"line_out": (state == CastState.CASTING and bait_flying and not bait_landed and moving_out) or (waiting and manual_releasing and moving_out),
		"reel_in": moving_in and ((waiting and (manual_reeling or automatic_owned)) or retrieval_active or auto_fight),
		"drag": automatic_owned and (waiting or retrieval_active or auto_fight) and moving_out,
	}


## Returns a line path in hull-local space. A direct span crossing the walkable
## deck footprint rises to a fairlead point above the gunwale. This changes
## only the visible path; lure position, line length, and tension stay intact.
static func get_hull_clearance_line_route(
	start_local: Vector3,
	end_local: Vector3,
	deck_polygon_xz: PackedVector2Array,
	deck_height_m: float,
	clearance_above_deck_m: float = 1.35,
	boundary_margin_m: float = 0.65
) -> Array[Vector3]:
	var route: Array[Vector3] = [start_local]
	if deck_polygon_xz.size() < 3:
		route.append(end_local)
		return route
	var start_xz := Vector2(start_local.x, start_local.z)
	var end_xz := Vector2(end_local.x, end_local.z)
	var intersections := _get_segment_polygon_intersections(start_xz, end_xz, deck_polygon_xz)
	if intersections.is_empty():
		if Geometry2D.is_point_in_polygon(start_xz, deck_polygon_xz) and Geometry2D.is_point_in_polygon(end_xz, deck_polygon_xz):
			var raised_midpoint := start_local.lerp(end_local, 0.5)
			raised_midpoint.y = maxf(raised_midpoint.y, deck_height_m + clearance_above_deck_m)
			route.append(raised_midpoint)
		route.append(end_local)
		return route
	var horizontal_direction := end_xz - start_xz
	for intersection_index in range(intersections.size()):
		var crossing_t := intersections[intersection_index]
		var crossing_xz := start_xz.lerp(end_xz, crossing_t)
		var before_t := maxf(0.0, crossing_t - 0.001)
		var after_t := minf(1.0, crossing_t + 0.001)
		var before_inside := Geometry2D.is_point_in_polygon(start_xz + horizontal_direction * before_t, deck_polygon_xz)
		var after_inside := Geometry2D.is_point_in_polygon(start_xz + horizontal_direction * after_t, deck_polygon_xz)
		var boundary_point := start_local.lerp(end_local, crossing_t)
		boundary_point.y = maxf(boundary_point.y, deck_height_m + clearance_above_deck_m)
		var outward_normal := _get_polygon_outward_normal_at_point(crossing_xz, deck_polygon_xz)
		var outboard_point := boundary_point
		outboard_point.x += outward_normal.x * boundary_margin_m
		outboard_point.z += outward_normal.y * boundary_margin_m
		if before_inside and not after_inside:
			route.append(boundary_point)
			route.append(outboard_point)
		elif not before_inside and after_inside:
			route.append(outboard_point)
			route.append(boundary_point)
	route.append(end_local)
	return route


static func _get_polygon_outward_normal_at_point(point: Vector2, polygon: PackedVector2Array) -> Vector2:
	if polygon.size() < 3:
		return Vector2.ZERO
	var signed_area := 0.0
	for index in range(polygon.size()):
		var current := polygon[index]
		var next := polygon[(index + 1) % polygon.size()]
		signed_area += current.x * next.y - next.x * current.y
	var orientation := 1.0 if signed_area >= 0.0 else -1.0
	var nearest_distance_squared := INF
	var normal_sum := Vector2.ZERO
	for index in range(polygon.size()):
		var edge_start := polygon[index]
		var edge := polygon[(index + 1) % polygon.size()] - edge_start
		if edge.length_squared() <= 0.000001:
			continue
		var edge_t := clampf((point - edge_start).dot(edge) / edge.length_squared(), 0.0, 1.0)
		var closest_point := edge_start + edge * edge_t
		var distance_squared := point.distance_squared_to(closest_point)
		var edge_outward := Vector2(edge.y, -edge.x) * orientation
		if distance_squared < nearest_distance_squared - 0.0001:
			nearest_distance_squared = distance_squared
			normal_sum = edge_outward.normalized()
		elif absf(distance_squared - nearest_distance_squared) <= 0.0001:
			normal_sum += edge_outward.normalized()
	return normal_sum.normalized()


static func validate_cast_launch_position(
	player_local_position: Vector3,
	rod_tip_local_position: Vector3,
	target_local_position: Vector3,
	deck_polygon_xz: PackedVector2Array,
	maximum_player_distance_m: float = DEFAULT_CAST_MAX_DISTANCE_FROM_GUNWALE_M,
	minimum_outward_alignment: float = DEFAULT_CAST_MIN_OUTWARD_ALIGNMENT
) -> Dictionary:
	if deck_polygon_xz.size() < 3:
		return {"valid": false, "reason_key": "hud.boat_fishing.cast_near_gunwale"}
	var player_xz := Vector2(player_local_position.x, player_local_position.z)
	if not Geometry2D.is_point_in_polygon(player_xz, deck_polygon_xz):
		return {"valid": false, "reason_key": "hud.boat_fishing.cast_near_gunwale"}
	var closest_boundary := Vector2.ZERO
	var nearest_distance_squared := INF
	for edge_index in range(deck_polygon_xz.size()):
		var edge_start := deck_polygon_xz[edge_index]
		var edge_end := deck_polygon_xz[(edge_index + 1) % deck_polygon_xz.size()]
		var candidate := Geometry2D.get_closest_point_to_segment(player_xz, edge_start, edge_end)
		var distance_squared := player_xz.distance_squared_to(candidate)
		if distance_squared < nearest_distance_squared:
			nearest_distance_squared = distance_squared
			closest_boundary = candidate
	var rail_distance_m := sqrt(nearest_distance_squared)
	if rail_distance_m > maxf(0.0, maximum_player_distance_m):
		return {"valid": false, "reason_key": "hud.boat_fishing.cast_near_gunwale", "rail_distance_m": rail_distance_m}
	var outward_normal := _get_polygon_outward_normal_at_point(closest_boundary, deck_polygon_xz)
	var rod_tip_xz := Vector2(rod_tip_local_position.x, rod_tip_local_position.z)
	var target_xz := Vector2(target_local_position.x, target_local_position.z)
	if (
		outward_normal.length_squared() < 0.5
		or Geometry2D.is_point_in_polygon(target_xz, deck_polygon_xz)
		or rod_tip_xz.distance_squared_to(target_xz) < 0.0001
	):
		return {"valid": false, "reason_key": "hud.boat_fishing.cast_aim_outside", "rail_distance_m": rail_distance_m}
	var cast_direction := (target_xz - rod_tip_xz).normalized()
	var outward_alignment := cast_direction.dot(outward_normal)
	if outward_alignment < clampf(minimum_outward_alignment, 0.0, 1.0):
		return {
			"valid": false,
			"reason_key": "hud.boat_fishing.cast_aim_outside",
			"rail_distance_m": rail_distance_m,
			"outward_alignment": outward_alignment,
		}
	return {
		"valid": true,
		"rail_distance_m": rail_distance_m,
		"outward_alignment": outward_alignment,
		"outward_normal": outward_normal,
	}


static func _get_segment_polygon_intersections(start: Vector2, finish: Vector2, polygon: PackedVector2Array) -> Array[float]:
	var result: Array[float] = []
	var ray := finish - start
	if ray.length_squared() <= 0.000001:
		return result
	for edge_index in range(polygon.size()):
		var edge_start := polygon[edge_index]
		var edge := polygon[(edge_index + 1) % polygon.size()] - edge_start
		var denominator := ray.cross(edge)
		if absf(denominator) <= 0.000001:
			continue
		var offset := edge_start - start
		var ray_t := offset.cross(edge) / denominator
		var edge_t := offset.cross(ray) / denominator
		if ray_t <= 0.0001 or ray_t >= 0.9999 or edge_t < -0.0001 or edge_t > 1.0001:
			continue
		var duplicate := false
		for existing_t in result:
			if absf(existing_t - ray_t) <= 0.001:
				duplicate = true
				break
		if not duplicate:
			result.append(ray_t)
	result.sort()
	return result


static func should_visualize_bite_approach(lure_depth_m: float, shallow_limit_m: float = 6.0, force_approach: bool = false) -> bool:
	return force_approach or (is_finite(lure_depth_m) and lure_depth_m >= 0.0 and lure_depth_m < shallow_limit_m)


static func get_automatic_line_burst_offset_m(line_state: String, line_distance_m: float, expected_line_distance_m: float) -> float:
	if line_state != "BACKING_OUT" or not is_finite(line_distance_m) or not is_finite(expected_line_distance_m):
		return 0.0
	return clampf(line_distance_m - expected_line_distance_m, 0.0, MAX_AUTOMATIC_LINE_BURST_EXTRA_M)


static func get_reel_visual_speed_rad_s(line_rate_mps: float, line_length_m: float = 0.0) -> float:
	if not is_finite(line_rate_mps):
		return 0.0
	var spool_radius := FishingRodRig.get_reel_spool_outer_radius_m(line_length_m)
	return -line_rate_mps / maxf(spool_radius, 0.001)


func _set_boat_fishing_audio_loop(key: String, active: bool) -> void:
	if bool(_requested_fishing_audio_loops.get(key, false)) == active:
		return
	_requested_fishing_audio_loops[key] = active
	if is_instance_valid(_fishing_audio_system):
		_fishing_audio_system.set_external_fishing_audio_loop(BOAT_FISHING_AUDIO_OWNER, key, active)


func _clear_boat_fishing_audio_loops() -> void:
	for key_variant in _requested_fishing_audio_loops.keys():
		_set_boat_fishing_audio_loop(str(key_variant), false)
	if is_instance_valid(_fishing_audio_system):
		_fishing_audio_system.clear_external_fishing_audio_loops(BOAT_FISHING_AUDIO_OWNER)


func _play_boat_fishing_one_shot(key: String) -> void:
	_fishing_audio_event_counts[key] = int(_fishing_audio_event_counts.get(key, 0)) + 1
	if is_instance_valid(_fishing_audio_system):
		_fishing_audio_system.play_shared_fishing_one_shot(key)


func _clear_manual_line_controls() -> void:
	_manual_reeling = false
	_manual_reeling_from_ui = false
	_manual_reeling_input_held = false
	_manual_line_release_held = false
	_manual_line_releasing = false
	_line_controls_conflicted = false


func _release_non_ui_line_inputs() -> void:
	_manual_reeling_input_held = false
	_manual_line_release_held = false
	_rod_aim_active = false
	_sync_manual_line_controls()


func _reconcile_physical_line_inputs() -> void:
	# If a mouse/key release event was consumed during a camera or UI transition,
	# do not leave a manual reel request latched in the fishing state.
	if _manual_reeling_input_held and InputMap.has_action("boat_fishing_cast") and not Input.is_action_pressed("boat_fishing_cast"):
		_manual_reeling_input_held = false
	if _manual_line_release_held and InputMap.has_action("boat_fishing_pay_out") and not Input.is_action_pressed("boat_fishing_pay_out"):
		_manual_line_release_held = false


func _update_boat_velocity_estimate(delta: float) -> void:
	if _boat_controller == null or delta <= 0.0001:
		return
	var current_position := _boat_controller.global_position
	if _previous_boat_world != Vector3.ZERO:
		_boat_velocity_estimate_world = (current_position - _previous_boat_world) / delta
		_boat_velocity_estimate_world.y = 0.0
		_boat_velocity_estimate_world = _boat_velocity_estimate_world.limit_length(18.0)
	_previous_boat_world = current_position


func _get_rod_tip_world() -> Vector3:
	if _rod_swing == null:
		return global_position
	var bend_radians := deg_to_rad(_rod_bend_angle_deg)
	var curved_tip := Vector3.ZERO
	if absf(bend_radians) > 0.0001:
		curved_tip.x = ROD_LENGTH_M * (1.0 - cos(bend_radians)) / bend_radians
		curved_tip.y = -ROD_LENGTH_M * 0.5 + ROD_LENGTH_M * sin(bend_radians) / bend_radians
	else:
		curved_tip.y = ROD_LENGTH_M * 0.5
	var rod_basis := Basis(Quaternion(Vector3.UP, ROD_AXIS_LOCAL))
	var mesh_transform := Transform3D(rod_basis, ROD_AXIS_LOCAL * ROD_LENGTH_M * 0.5)
	return _rod_swing.to_global(mesh_transform * curved_tip)


func _update_line_and_bait_visuals() -> void:
	if not is_cast_active() or not _bait_flight_started:
		return
	_update_single_jig_visual(maxf(get_process_delta_time(), 0.0))
	var line_should_be_taut := _should_render_fishing_line_taut()
	var start := _get_rod_tip_world()
	var end := _get_tackle_line_connection_world()
	_update_rod_line_guides()
	var world_points: Array[Vector3] = [_get_reel_line_exit_world()]
	world_points.append(_get_reel_line_guide_world())
	for guide in _rod_line_guides:
		if is_instance_valid(guide):
			world_points.append(guide.global_position)
	world_points.append(start)
	var deck_polygon := PackedVector2Array()
	var deck_height := 0.0
	var tail_route_local: Array[Vector3] = []
	if _onboard != null:
		tail_route_local.append(_onboard.to_local(start))
		tail_route_local.append(_onboard.to_local(end))
	else:
		tail_route_local.append(start)
		tail_route_local.append(end)
	if not line_should_be_taut and _onboard != null and _onboard.profile != null:
		deck_polygon = _onboard.profile.walkable_polygon_xz
		deck_height = _onboard.profile.deck_height_m
		tail_route_local = get_hull_clearance_line_route(
			tail_route_local[0], tail_route_local[1], deck_polygon, deck_height
		)
	var route_world: Array[Vector3] = []
	for route_point in tail_route_local:
		route_world.append(_onboard.to_global(route_point) if _onboard != null else route_point)
	var span_segments := maxi(2, int(ceil(float(LINE_SEGMENTS) / float(maxi(1, route_world.size() - 1)))))
	for span_index in range(route_world.size() - 1):
		var span_start := route_world[span_index]
		var span_end := route_world[span_index + 1]
		var span_delta := span_end - span_start
		var midpoint_local := (tail_route_local[span_index] + tail_route_local[span_index + 1]) * 0.5
		var midpoint_over_deck := not deck_polygon.is_empty() and Geometry2D.is_point_in_polygon(Vector2(midpoint_local.x, midpoint_local.z), deck_polygon)
		var clearance_height := deck_height + 1.34
		var span_kept_clear := not deck_polygon.is_empty() and tail_route_local[span_index].y >= clearance_height and tail_route_local[span_index + 1].y >= clearance_height
		var over_deck := midpoint_over_deck or span_kept_clear
		var terminal_span := span_index == route_world.size() - 2
		var sway_axis := span_delta.cross(Vector3.DOWN).normalized()
		if sway_axis.length_squared() < 0.001:
			sway_axis = Vector3.RIGHT
		var previous_route_point := route_world[maxi(span_index - 1, 0)]
		var arrival_direction := (span_start - previous_route_point).normalized()
		if arrival_direction.length_squared() < 0.001:
			arrival_direction = span_delta.normalized()
		for point_index in range(1, span_segments + 1):
			var t := float(point_index) / float(span_segments)
			var sag := Vector3.ZERO
			var terminal_curve_clear := not midpoint_over_deck or span_kept_clear
			if terminal_span and not line_should_be_taut and _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI and terminal_curve_clear:
				var hanging_point := _get_slack_sabiki_line_point(
					span_start, span_end, arrival_direction, t
				)
				if _bait_airborne_retrieval:
					var relaxation := exp(-2.6 * maxf(_airborne_retrieval_elapsed, 0.0))
					var sway_amount := clampf(Vector2(_bait_velocity_world.x, _bait_velocity_world.z).length() * 0.035, 0.0, 0.065) * relaxation
					hanging_point += sway_axis * sin(_airborne_retrieval_elapsed * 7.0) * sway_amount * pow(sin(t * PI), 2.0)
				world_points.append(hanging_point)
				continue
			if not over_deck and not line_should_be_taut:
				sag = Vector3.DOWN * minf(span_delta.length() * 0.018, 0.62) * (1.0 - _rod_tension * 0.9) * sin(t * PI)
				if terminal_span and _bait_airborne_retrieval:
					# A retrieved lure is no longer pulling a wet, loaded line. Keep a
					# visible hanging curve and let its side-to-side motion follow the
					# tackle's remaining inertia instead of preserving the taut cast angle.
					var air_sag := minf(AIRBORNE_LINE_VISUAL_SAG_M, span_delta.length() * 0.16)
					var relaxation := exp(-2.6 * maxf(_airborne_retrieval_elapsed, 0.0))
					var sway_amount := clampf(Vector2(_bait_velocity_world.x, _bait_velocity_world.z).length() * 0.035, 0.0, 0.065) * relaxation
					var sway := sway_axis * sin(_airborne_retrieval_elapsed * 7.0) * sway_amount * sin(t * PI)
					sag = Vector3.DOWN * air_sag * sin(t * PI) + sway
			world_points.append(span_start.lerp(span_end, t) + sag)
	var points := PackedVector3Array()
	for point in world_points:
		points.append(to_local(point))
	_line_mesh.clear_surfaces()
	_line_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, _line_material)
	for point_index in range(points.size() - 1):
		var segment_direction := (points[point_index + 1] - points[point_index]).normalized()
		var side := segment_direction.cross(Vector3.UP)
		if side.length_squared() < 0.001:
			side = segment_direction.cross(Vector3.RIGHT)
		side = side.normalized() * LINE_RADIUS_M
		var other := segment_direction.cross(side).normalized() * LINE_RADIUS_M
		var a := points[point_index]
		var b := points[point_index + 1]
		for side_index in range(LINE_SIDES):
			var angle_a := TAU * float(side_index) / float(LINE_SIDES)
			var angle_b := TAU * float(side_index + 1) / float(LINE_SIDES)
			var offset_a := side * cos(angle_a) + other * sin(angle_a)
			var offset_b := side * cos(angle_b) + other * sin(angle_b)
			_line_mesh.surface_add_vertex(a + offset_a)
			_line_mesh.surface_add_vertex(b + offset_a)
			_line_mesh.surface_add_vertex(b + offset_b)
			_line_mesh.surface_add_vertex(a + offset_a)
			_line_mesh.surface_add_vertex(b + offset_b)
			_line_mesh.surface_add_vertex(a + offset_b)
	_line_mesh.surface_end()
	_line_instance.visible = true
	_bait_instance.global_position = _bait_world
	_bait_instance.global_basis = _lure_visual_basis_world
	_bait_instance.visible = _current_rig.rig_type == BoatFishingRigProfile.RigType.SINGLE_JIG
	_update_rig_visual_position()


func _get_slack_sabiki_line_point(
	span_start: Vector3,
	span_end: Vector3,
	arrival_direction: Vector3,
	progress: float
) -> Vector3:
	var t := clampf(progress, 0.0, 1.0)
	var inverse_t := 1.0 - t
	var span_length := span_start.distance_to(span_end)
	var handle_length := minf(span_length * 0.32, 0.45)
	var start_direction := arrival_direction.normalized()
	if start_direction.length_squared() < 0.001:
		start_direction = (span_end - span_start).normalized()
	var rig_down := -_get_sabiki_up_direction_world().normalized()
	if rig_down.length_squared() < 0.5:
		rig_down = Vector3.DOWN
	var control_start := span_start + start_direction * handle_length
	var control_end := span_end - rig_down * handle_length
	var point := (
		span_start * (inverse_t * inverse_t * inverse_t)
		+ control_start * (3.0 * inverse_t * inverse_t * t)
		+ control_end * (3.0 * inverse_t * t * t)
		+ span_end * (t * t * t)
	)
	# The zero-slope endpoint envelope makes the fairlead curve droop while
	# preserving a tangent that continues smoothly into the hanging Sabiki rig.
	var sag_limit := SABIKI_SLACK_LINE_MAX_SAG_M if _bait_airborne_retrieval else 0.14
	var sag_fraction := 0.24 if _bait_airborne_retrieval else 0.12
	var sag_depth := minf(sag_limit, span_length * sag_fraction)
	return point + Vector3.DOWN * sag_depth * pow(sin(PI * t), 2.0)


func _update_rig_visual_selection() -> void:
	if _sabiki_rig_root == null:
		return
	var rig_height := _current_rig.get_line_attachment_height_m()
	if not is_equal_approx(rig_height, _sabiki_hook_spacing_applied):
		_sabiki_hook_spacing_applied = rig_height
		var mainline_mesh := CylinderMesh.new()
		mainline_mesh.top_radius = 0.0024
		mainline_mesh.bottom_radius = 0.0024
		mainline_mesh.height = maxf(rig_height, 0.04)
		mainline_mesh.radial_segments = 6
		_sabiki_mainline_instance.mesh = mainline_mesh
	_sabiki_mainline_instance.position.y = rig_height * 0.5
	if _sabiki_top_eye != null:
		_sabiki_top_eye.position.y = rig_height
	for index in range(_sabiki_hook_nodes.size()):
		var hook := _sabiki_hook_nodes[index]
		hook.visible = index < _current_rig.hook_count
		if hook.visible:
			var hook_height := _current_rig.bottom_leader_length_m + float(_current_rig.hook_count - index - 1) * _current_rig.hook_spacing_m
			hook.position = Vector3(0.0, hook_height, 0.0)
	_update_rig_visual_position()


func _update_rig_visual_position() -> void:
	if _sabiki_rig_root == null:
		return
	var sabiki_active := _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI
	_sabiki_rig_root.global_position = _bait_world
	_sabiki_rig_root.global_basis = Basis(Quaternion(Vector3.UP, _get_sabiki_up_direction_world()))
	if sabiki_active and is_cast_active():
		var hook_positions := get_hook_world_positions()
		for hook_index in range(mini(hook_positions.size(), _sabiki_hook_nodes.size())):
			_sabiki_hook_nodes[hook_index].position = _sabiki_rig_root.to_local(hook_positions[hook_index])
	_sabiki_rig_root.visible = sabiki_active and is_cast_active() and _bait_flight_started


func _should_keep_sabiki_tackle_aligned() -> bool:
	# Sabiki is one tackle attached to the same continuous line as a single jig.
	# Keep its mainline on the rod-to-sinker tether axis while any part is still
	# wet; rotating it toward world-up as soon as CASTING ends creates a visible
	# hinge where the external line meets the multi-hook rig. Only relax it after
	# the complete rig has cleared the water during retrieval.
	return not _bait_airborne_retrieval


func _should_render_fishing_line_taut() -> bool:
	# Once the complete tackle has cleared the water, neither stale manual-reel
	# state nor the Sabiki retrieval flag may keep the line visually stretched.
	if _bait_airborne_retrieval:
		return false
	return (
		_state == CastState.CASTING
		or _is_waiting_line_state() and _manual_reeling
		or _state in [CastState.WAITING, CastState.SABIKI_HOOKED_WAITING, CastState.RETRIEVING, CastState.FIGHTING] and _sabiki_retrieval_taut
		or _state == CastState.RETRIEVING
	)


func _get_sabiki_up_direction_world() -> Vector3:
	var natural_up := _get_sabiki_up_direction_for_sinker(_bait_world)
	var toward_rod := _get_rod_tip_world() - _bait_world
	if toward_rod.length_squared() < 0.0001:
		return natural_up
	var tether_up := toward_rod.normalized()
	if _should_keep_sabiki_tackle_aligned():
		return tether_up
	var relax_progress := clampf(_airborne_retrieval_elapsed / AIRBORNE_RIG_RELAX_DURATION_SECONDS, 0.0, 1.0)
	return tether_up.slerp(natural_up, _smoothstep01(relax_progress)).normalized()


func _get_tackle_water_sample_points() -> Array[Vector3]:
	var points: Array[Vector3] = [_bait_world]
	if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
		points.append_array(get_hook_world_positions())
		points.append(_get_tackle_line_connection_world())
	return points


func _is_tackle_fully_submerged() -> bool:
	for point in _get_tackle_water_sample_points():
		var surface_y := float(_sample_water(point).get("height", point.y))
		if point.y >= surface_y - SABIKI_WATER_ENTRY_CLEARANCE_M:
			return false
	return true


func _is_tackle_fully_above_surface(clearance_m: float) -> bool:
	for point in _get_tackle_water_sample_points():
		var surface_y := float(_sample_water(point).get("height", point.y))
		if point.y < surface_y + clearance_m:
			return false
	return true


func _get_sabiki_up_direction_for_sinker(sinker_world_position: Vector3) -> Vector3:
	var lean := Vector3.ZERO
	var boat_flow := Vector3(_boat_velocity_estimate_world.x, 0.0, _boat_velocity_estimate_world.z)
	if boat_flow.length_squared() > 0.01:
		lean += boat_flow.normalized() * clampf(boat_flow.length() / 18.0 * 0.22, 0.0, 0.22)
	var toward_rod := _get_rod_tip_world() - sinker_world_position
	var rod_horizontal := Vector3(toward_rod.x, 0.0, toward_rod.z)
	if rod_horizontal.length_squared() > 0.01:
		lean += rod_horizontal.normalized() * clampf(_rod_tension, 0.0, 1.0) * 0.28
	return (Vector3.UP + lean).normalized()


func _get_tackle_line_connection_world() -> Vector3:
	if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
		return _bait_world + _get_sabiki_up_direction_world() * _current_rig.get_line_attachment_height_m()
	return _bait_world + _lure_visual_basis_world * Vector3.UP * SPOON_LINE_EYE_Y_M


func _get_tackle_retrieval_target_world() -> Vector3:
	var rod_tip := _get_rod_tip_world()
	if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
		return rod_tip - _get_sabiki_up_direction_world() * _current_rig.get_line_attachment_height_m()
	return rod_tip - _lure_visual_basis_world * Vector3.UP * SPOON_LINE_EYE_Y_M


func _update_single_jig_visual(delta: float) -> void:
	var relative_velocity := _bait_velocity_world - _boat_velocity_estimate_world * BAIT_WATER_DRAG_FOLLOW
	var target_intensity := clampf(relative_velocity.length() / 2.2, 0.0, 1.0)
	if _manual_reeling or _manual_line_releasing:
		target_intensity = maxf(target_intensity, 0.48)
	_lure_visual_intensity = move_toward(_lure_visual_intensity, target_intensity, delta * 1.8)
	_lure_visual_phase += delta * lerpf(1.4, 7.0, _lure_visual_intensity)
	var phase := _lure_visual_phase
	var visual_rotation := Vector3(
		sin(phase) * 0.34 * _lure_visual_intensity,
		sin(phase * 0.41) * 0.12 * _lure_visual_intensity,
		cos(phase * 0.78) * 0.46 * _lure_visual_intensity
	)
	_lure_visual_basis_world = Basis.from_euler(visual_rotation)


func _is_pointer_over_ui() -> bool:
	var viewport := get_viewport()
	if viewport == null:
		return false
	return viewport.gui_get_hovered_control() != null


func _is_menu_open() -> bool:
	return is_instance_valid(_game_menu) and _game_menu.has_method("is_menu_open") and bool(_game_menu.call("is_menu_open"))


func _get_cast_distance_for_charge(charge_ratio: float) -> float:
	var ratio := clampf(charge_ratio, 0.0, 1.0)
	var eased_ratio := pow(ratio, 0.78)
	return lerpf(minimum_cast_distance_m, maximum_cast_distance_m, eased_ratio)


func _get_cast_range_ratio() -> float:
	var range_span := maxf(maximum_cast_distance_m - minimum_cast_distance_m, 0.01)
	return clampf((_get_cast_distance_for_charge(get_charge_progress()) - minimum_cast_distance_m) / range_span, 0.0, 1.0)


func _set_state(next_state: CastState) -> void:
	_state = next_state
	_state_elapsed = 0.0
	if next_state == CastState.WAITING:
		_natural_bite_sample_elapsed = 0.0
		_natural_bite_pending_real_delta = 0.0
		if _encounter != null:
			_encounter.reset_boat_fishing_hazard()
	_emit_state_changed()


func _emit_state_changed() -> void:
	var state_name := get_casting_state_name()
	var status_key := "hud.boat_fishing.state_ready"
	var hint_key := "hud.boat_fishing.hint_ready"
	match _state:
		CastState.CHARGING:
			status_key = "hud.boat_fishing.state_charging"
			hint_key = "hud.boat_fishing.hint_charging"
		CastState.CASTING:
			status_key = "hud.boat_fishing.state_casting"
			hint_key = "hud.boat_fishing.hint_casting"
		CastState.WAITING:
			status_key = "hud.boat_fishing.state_waiting"
			hint_key = "hud.boat_fishing.hint_waiting"
		CastState.SABIKI_HOOKED_WAITING:
			status_key = "hud.boat_fishing.state_sabiki_hooked_waiting"
			hint_key = "hud.boat_fishing.hint_sabiki_hooked_waiting"
		CastState.RETRIEVING:
			status_key = "hud.boat_fishing.state_retrieving"
			hint_key = "hud.boat_fishing.hint_retrieving"
		CastState.BITE_APPROACH:
			status_key = "hud.boat_fishing.state_bite_approach"
			hint_key = "hud.boat_fishing.hint_bite_approach"
		CastState.FIGHTING:
			status_key = "hud.boat_fishing.state_fighting"
			hint_key = "hud.boat_fishing.hint_fighting"
		CastState.CATCH_PRESENTATION:
			status_key = "hud.boat_fishing.state_landed"
			hint_key = "hud.boat_fishing.hint_landed"
		_:
			if not _activity_active:
				status_key = "hud.boat_fishing.preparing"
	state_changed.emit(state_name, status_key, hint_key)
	interaction_updated.emit(get_interaction_snapshot())


func _show_splash_visual(world_position: Vector3) -> void:
	if _splash_instance == null:
		return
	_splash_elapsed = 0.0
	_splash_instance.global_position = world_position
	_splash_instance.scale = Vector3.ONE * 0.28
	_splash_instance.visible = true


func _build_visuals() -> void:
	_rod_visual_root = Node3D.new()
	_rod_visual_root.name = "BoatFishingRodVisual"
	_rod_visual_root.visible = false
	if _onboard != null:
		_onboard.add_child(_rod_visual_root)
	else:
		add_child(_rod_visual_root)
	_rod_swing = Node3D.new()
	_rod_swing.name = "RodSwing"
	_rod_visual_root.add_child(_rod_swing)
	var rod_mesh := CylinderMesh.new()
	rod_mesh.top_radius = 0.0035
	rod_mesh.bottom_radius = 0.012
	rod_mesh.height = ROD_LENGTH_M
	rod_mesh.radial_segments = 8
	rod_mesh.rings = 36
	_rod_mesh_instance = MeshInstance3D.new()
	_rod_mesh_instance.name = "FirstPersonFishingRod"
	_rod_mesh_instance.mesh = rod_mesh
	var rod_basis := Basis(Quaternion(Vector3.UP, ROD_AXIS_LOCAL))
	_rod_mesh_instance.transform = Transform3D(rod_basis, ROD_AXIS_LOCAL * ROD_LENGTH_M * 0.5)
	_rod_shader_material = ShaderMaterial.new()
	_rod_shader_material.shader = ROD_BEND_SHADER
	_rod_shader_material.set_shader_parameter("bend_angle", 0.0)
	_rod_shader_material.set_shader_parameter("rod_length", ROD_LENGTH_M)
	_rod_shader_material.set_shader_parameter("rod_color", Color(0.07, 0.10, 0.12))
	_rod_mesh_instance.material_override = _rod_shader_material
	_rod_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rod_swing.add_child(_rod_mesh_instance)
	_reel_mount = Node3D.new()
	_reel_mount.name = "ReelMount"
	var rod_axis := ROD_AXIS_LOCAL.normalized()
	var screen_left := Vector3.LEFT
	var mount_up := rod_axis.cross(screen_left).normalized()
	_reel_mount.transform = Transform3D(
		Basis(screen_left, mount_up, rod_axis).orthonormalized(),
		# Move the drum 0.20 m down the rod toward the hand from its previous
		# mount, while restoring the original camera-relative rod rest pose.
		rod_axis * 0.06 + screen_left * 0.02 + Vector3(0.0, -0.02, 0.0)
	)
	_rod_swing.add_child(_reel_mount)
	var reel_body_material := _make_material(Color(0.12, 0.15, 0.16), 0.58)
	var reel_moving_material := _make_material(Color(0.43, 0.50, 0.51), 0.84)
	reel_body_material.roughness = 0.30
	reel_moving_material.roughness = 0.25
	# The shared reel defaults to the fixed trolling rod's handle side. The
	# handheld mount is mirrored so the crank projects to screen-left from the
	# player's first-person view without changing its winding axis or direction.
	var reel_parts := FishingRodRig.create_reel_assembly(reel_body_material, reel_moving_material, -1.0)
	_reel_visual_root = reel_parts["root"] as Node3D
	_reel_visual_root.name = "HandheldFishingReel"
	_reel_visual_root.scale = Vector3.ONE * 0.82
	# The shared trolling seat is broad for a fixed mount. Narrow only the
	# handheld seat so it follows the rod instead of reading as a crossbar.
	var handheld_reel_seat := _reel_visual_root.get_node_or_null("ReelSeat") as MeshInstance3D
	if handheld_reel_seat != null:
		var handheld_seat_mesh := BoxMesh.new()
		handheld_seat_mesh.size = Vector3(0.028, 0.014, 0.12)
		handheld_reel_seat.mesh = handheld_seat_mesh
		handheld_reel_seat.position = Vector3(0.0, 0.014, 0.18)
	_reel_rotating_assembly = _reel_visual_root.get_node_or_null("ReelSpinningAssembly") as Node3D
	_reel_winding_visual = reel_parts["winding_visual"] as MultiMeshInstance3D
	FishingRodRig.set_reel_winding_line_length_on_visual(_reel_winding_visual, 0.0)
	_reel_mount.add_child(_reel_visual_root)
	_build_handheld_rod_guides()
	_line_mesh = ImmediateMesh.new()
	_line_instance = MeshInstance3D.new()
	_line_instance.name = "BoatFishingLine"
	_line_instance.mesh = _line_mesh
	_line_material = _make_material(Color(0.77, 0.86, 0.84, 0.95), 0.0)
	_line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_line_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_line_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Keep depth testing enabled so the hull hides line segments behind the boat.
	# The line stays late-rendered but does not write depth; above-water segments
	# remain legible while segments behind the water surface are naturally hidden.
	_line_material.no_depth_test = false
	_line_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	_line_material.render_priority = 20
	_line_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_line_instance.visible = false
	add_child(_line_instance)
	_bait_instance = MeshInstance3D.new()
	_bait_instance.name = "BoatFishingBait"
	_bait_instance.mesh = _build_spoon_mesh()
	_bait_material = _make_material(Color(0.69, 0.78, 0.79), 0.88)
	_bait_material.roughness = 0.19
	_bait_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_bait_instance.material_override = _bait_material
	_bait_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_bait_instance.visible = false
	add_child(_bait_instance)
	var spoon_accent := MeshInstance3D.new()
	spoon_accent.name = "SpoonBlueGreenAccent"
	var accent_mesh := BoxMesh.new()
	accent_mesh.size = Vector3(0.003, 0.052, 0.0018)
	spoon_accent.mesh = accent_mesh
	spoon_accent.position = Vector3(0.0055, 0.0, 0.008)
	spoon_accent.material_override = _make_material(Color(0.10, 0.39, 0.40), 0.68)
	spoon_accent.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_bait_instance.add_child(spoon_accent)
	var spoon_eye := MeshInstance3D.new()
	spoon_eye.name = "SpoonLineEye"
	var spoon_eye_mesh := TorusMesh.new()
	spoon_eye_mesh.inner_radius = 0.0024
	spoon_eye_mesh.outer_radius = 0.0042
	spoon_eye_mesh.rings = 5
	spoon_eye_mesh.ring_segments = 8
	spoon_eye.mesh = spoon_eye_mesh
	spoon_eye.position.y = SPOON_LINE_EYE_Y_M
	spoon_eye.material_override = _make_material(Color(0.83, 0.89, 0.87), 0.82)
	spoon_eye.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_bait_instance.add_child(spoon_eye)
	var treble_root := Node3D.new()
	treble_root.name = "SpoonTrebleHook"
	treble_root.position.y = -SPOON_LENGTH_M * 0.5
	_bait_instance.add_child(treble_root)
	_build_treble_hook(treble_root, 0.67, _make_material(Color(0.54, 0.62, 0.62), 0.72))
	_build_sabiki_visuals()
	var splash_mesh := TorusMesh.new()
	splash_mesh.inner_radius = 0.12
	splash_mesh.outer_radius = 0.17
	splash_mesh.rings = 8
	splash_mesh.ring_segments = 16
	_splash_instance = MeshInstance3D.new()
	_splash_instance.name = "BoatFishingSplash"
	_splash_instance.mesh = splash_mesh
	var splash_material := StandardMaterial3D.new()
	splash_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	splash_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	splash_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	splash_material.albedo_color = Color(0.55, 0.83, 0.88, 1.0)
	splash_material.emission_enabled = true
	splash_material.emission = Color(0.12, 0.31, 0.36)
	_splash_instance.material_override = splash_material
	_splash_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_splash_instance.visible = false
	add_child(_splash_instance)
	_build_cast_aim_marker()
	_update_rig_visual_selection()
	_update_rod_line_guides()


func _build_cast_aim_marker() -> void:
	_cast_aim_marker = Node3D.new()
	_cast_aim_marker.name = "BoatFishingCastAimMarker"
	_cast_aim_marker.top_level = true
	_cast_aim_marker.visible = false
	add_child(_cast_aim_marker)
	var marker_mesh := TorusMesh.new()
	marker_mesh.inner_radius = 0.185
	marker_mesh.outer_radius = 0.215
	marker_mesh.rings = 5
	marker_mesh.ring_segments = 20
	var ring := MeshInstance3D.new()
	ring.name = "AimValidityRing"
	ring.mesh = marker_mesh
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_cast_aim_marker.add_child(ring)
	var center_mesh := SphereMesh.new()
	center_mesh.radius = 0.025
	center_mesh.height = 0.05
	center_mesh.radial_segments = 8
	center_mesh.rings = 4
	var center_dot := MeshInstance3D.new()
	center_dot.name = "AimValidityCenter"
	center_dot.mesh = center_mesh
	center_dot.position.y = 0.018
	center_dot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_cast_aim_marker.add_child(center_dot)
	_cast_aim_marker_material = StandardMaterial3D.new()
	_cast_aim_marker_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_cast_aim_marker_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_cast_aim_marker_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_cast_aim_marker_material.no_depth_test = false
	_cast_aim_marker_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	_cast_aim_marker_material.render_priority = 10
	_cast_aim_marker_material.emission_enabled = true
	ring.material_override = _cast_aim_marker_material
	center_dot.material_override = _cast_aim_marker_material


func _build_handheld_rod_guides() -> void:
	var guide_mesh := TorusMesh.new()
	guide_mesh.outer_radius = 0.014
	guide_mesh.inner_radius = 0.011
	guide_mesh.ring_segments = 10
	guide_mesh.rings = 4
	var guide_material := _make_material(Color(0.52, 0.60, 0.60), 0.78)
	guide_material.roughness = 0.28
	for guide_index in range(6):
		var progress := lerpf(HANDHELD_FIRST_GUIDE_PROGRESS, 0.97, float(guide_index) / 5.0)
		var rod_radius := lerpf(0.012, 0.0035, progress)
		var guide := MeshInstance3D.new()
		guide.name = "FirstPersonRodGuide_%02d" % guide_index
		var sized_guide_mesh := guide_mesh.duplicate() as TorusMesh
		sized_guide_mesh.outer_radius = rod_radius + 0.0030
		sized_guide_mesh.inner_radius = rod_radius + 0.00035
		guide.mesh = sized_guide_mesh
		guide.material_override = guide_material
		guide.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_rod_swing.add_child(guide)
		_rod_line_guides.append(guide)


func _rod_centerline_point_local(progress: float) -> Vector3:
	var t := clampf(progress, 0.0, 1.0)
	var bend_radians := deg_to_rad(_rod_bend_angle_deg)
	var angle := bend_radians * t
	var center_x := 0.0
	var center_y := -ROD_LENGTH_M * 0.5 + ROD_LENGTH_M * t
	if absf(bend_radians) > 0.0001:
		center_x = ROD_LENGTH_M * (1.0 - cos(angle)) / bend_radians
		center_y = -ROD_LENGTH_M * 0.5 + ROD_LENGTH_M * sin(angle) / bend_radians
	var rod_basis := Basis(Quaternion(Vector3.UP, ROD_AXIS_LOCAL))
	var rod_mesh_transform := Transform3D(rod_basis, ROD_AXIS_LOCAL * ROD_LENGTH_M * 0.5)
	return rod_mesh_transform * Vector3(center_x, center_y, 0.0)


func _update_rod_line_guides() -> void:
	if _rod_swing == null or _rod_line_guides.is_empty():
		return
	for guide_index in range(_rod_line_guides.size()):
		var progress := lerpf(HANDHELD_FIRST_GUIDE_PROGRESS, 0.97, float(guide_index) / float(maxi(_rod_line_guides.size() - 1, 1)))
		var before := _rod_centerline_point_local(maxf(progress - 0.006, 0.0))
		var after := _rod_centerline_point_local(minf(progress + 0.006, 1.0))
		var tangent := (after - before).normalized()
		var side := tangent.cross(Vector3.RIGHT)
		if side.length_squared() < 0.001:
			side = tangent.cross(Vector3.FORWARD)
		side = side.normalized()
		var normal := side.cross(tangent).normalized()
		var guide := _rod_line_guides[guide_index]
		guide.transform = Transform3D(Basis(side, tangent, normal), _rod_centerline_point_local(progress))


func _get_reel_line_exit_world() -> Vector3:
	if _reel_visual_root == null:
		return _get_rod_tip_world()
	return _reel_visual_root.to_global(FishingRodRig.get_reel_line_exit_local(_get_reel_feedback_line_length()))


func _get_reel_line_guide_world() -> Vector3:
	if _reel_visual_root == null:
		return _get_rod_tip_world()
	return _reel_visual_root.to_global(FishingRodRig.get_reel_line_guide_local())


func _build_sabiki_visuals() -> void:
	_sabiki_rig_root = Node3D.new()
	_sabiki_rig_root.name = "SabikiRigVisual"
	_sabiki_rig_root.visible = false
	add_child(_sabiki_rig_root)
	_sabiki_mainline_instance = MeshInstance3D.new()
	_sabiki_mainline_instance.name = "SabikiMainline"
	_sabiki_mainline_instance.material_override = _line_material
	_sabiki_mainline_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_sabiki_rig_root.add_child(_sabiki_mainline_instance)
	_sabiki_top_eye = MeshInstance3D.new()
	_sabiki_top_eye.name = "SabikiRodSideEye"
	var top_eye_mesh := TorusMesh.new()
	top_eye_mesh.inner_radius = 0.003
	top_eye_mesh.outer_radius = 0.0055
	top_eye_mesh.rings = 5
	top_eye_mesh.ring_segments = 8
	_sabiki_top_eye.mesh = top_eye_mesh
	_sabiki_top_eye.material_override = _make_material(Color(0.81, 0.87, 0.85), 0.76)
	_sabiki_top_eye.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_sabiki_rig_root.add_child(_sabiki_top_eye)
	var bead_material := _make_material(Color(0.95, 0.78, 0.31), 0.14)
	var feather_materials := [
		_make_material(Color(0.92, 0.90, 0.75), 0.05),
		_make_material(Color(0.23, 0.55, 0.54), 0.12),
		_make_material(Color(0.73, 0.31, 0.26), 0.04),
	]
	var hook_material := _make_material(Color(0.67, 0.74, 0.73), 0.82)
	for index in range(5):
		var hook_node := Node3D.new()
		hook_node.name = "SabikiHook_%d" % (index + 1)
		hook_node.visible = false
		var branch := MeshInstance3D.new()
		branch.name = "SabikiBranchLine"
		var branch_mesh := CylinderMesh.new()
		branch_mesh.top_radius = 0.0017
		branch_mesh.bottom_radius = 0.0017
		branch_mesh.height = SABIKI_RIG_PROFILE.branch_length_m
		branch_mesh.radial_segments = 5
		branch.mesh = branch_mesh
		branch.position.x = -SABIKI_RIG_PROFILE.branch_length_m * 0.5
		branch.rotation.z = PI * 0.5
		branch.material_override = _line_material
		branch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		hook_node.add_child(branch)
		var bead := MeshInstance3D.new()
		var bead_mesh := SphereMesh.new()
		bead_mesh.radius = 0.016
		bead_mesh.height = 0.032
		bead_mesh.radial_segments = 7
		bead_mesh.rings = 3
		bead.mesh = bead_mesh
		bead.material_override = bead_material
		bead.position = Vector3(-SABIKI_RIG_PROFILE.branch_length_m * 0.72, 0.0, 0.006)
		bead.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		hook_node.add_child(bead)
		for feather_index in range(feather_materials.size()):
			var feather := MeshInstance3D.new()
			feather.name = "SabikiFlashFeather_%d" % (feather_index + 1)
			var feather_mesh := CylinderMesh.new()
			feather_mesh.top_radius = 0.0008
			feather_mesh.bottom_radius = 0.0032
			feather_mesh.height = 0.055
			feather_mesh.radial_segments = 5
			feather.mesh = feather_mesh
			feather.position = Vector3(-SABIKI_RIG_PROFILE.branch_length_m * 0.72, 0.0, 0.012)
			feather.rotation.z = [-0.42, 0.0, 0.42][feather_index]
			feather.material_override = feather_materials[feather_index]
			feather.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			hook_node.add_child(feather)
		var small_hook := Node3D.new()
		small_hook.name = "SabikiSmallHook"
		small_hook.position.x = -SABIKI_RIG_PROFILE.branch_length_m
		hook_node.add_child(small_hook)
		_build_open_j_hook(small_hook, 0.72, hook_material)
		_sabiki_rig_root.add_child(hook_node)
		_sabiki_hook_nodes.append(hook_node)
	_sabiki_sinker_instance = MeshInstance3D.new()
	_sabiki_sinker_instance.name = "SabikiLeadWeight"
	var sinker_mesh := CapsuleMesh.new()
	sinker_mesh.radius = 0.044
	sinker_mesh.height = 0.15
	sinker_mesh.radial_segments = 8
	sinker_mesh.rings = 4
	_sabiki_sinker_instance.mesh = sinker_mesh
	_sabiki_sinker_instance.material_override = _make_material(Color(0.25, 0.31, 0.32), 0.62)
	_sabiki_sinker_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_sabiki_rig_root.add_child(_sabiki_sinker_instance)
	var sinker_eye := MeshInstance3D.new()
	sinker_eye.name = "SabikiSinkerTopEye"
	var sinker_eye_mesh := TorusMesh.new()
	sinker_eye_mesh.inner_radius = 0.0024
	sinker_eye_mesh.outer_radius = 0.004
	sinker_eye_mesh.rings = 5
	sinker_eye_mesh.ring_segments = 8
	sinker_eye.mesh = sinker_eye_mesh
	sinker_eye.position.y = 0.071
	sinker_eye.material_override = _make_material(Color(0.74, 0.81, 0.80), 0.75)
	sinker_eye.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_sabiki_rig_root.add_child(sinker_eye)


func _build_spoon_mesh() -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var longitudinal_segments := 8
	var width_segments := 3
	var vertex_count := 0
	for back_face in [false, true]:
		var base_index := vertex_count
		for row in range(longitudinal_segments + 1):
			var u := float(row) / float(longitudinal_segments)
			for column in range(width_segments + 1):
				var v := float(column) / float(width_segments)
				surface.add_vertex(_spoon_surface_point(u, v, -1.0 if back_face else 1.0))
				vertex_count += 1
		for row in range(longitudinal_segments):
			for column in range(width_segments):
				var a := base_index + row * (width_segments + 1) + column
				var b := a + 1
				var c := a + width_segments + 1
				var d := c + 1
				if back_face:
					surface.add_index(a)
					surface.add_index(d)
					surface.add_index(b)
					surface.add_index(a)
					surface.add_index(c)
					surface.add_index(d)
				else:
					surface.add_index(a)
					surface.add_index(b)
					surface.add_index(d)
					surface.add_index(a)
					surface.add_index(d)
					surface.add_index(c)
	surface.generate_normals()
	return surface.commit()


func _spoon_surface_point(u: float, across: float, face_sign: float) -> Vector3:
	var normalized_across := across * 2.0 - 1.0
	var curved_crown := sin(u * PI) * (0.0065 - 0.0022 * absf(normalized_across))
	var edge_roll := normalized_across * normalized_across * 0.0015
	return Vector3(
		normalized_across * SPOON_WIDTH_M * 0.5,
		(u - 0.5) * SPOON_LENGTH_M,
		curved_crown + edge_roll + face_sign * 0.0012
	)


func _build_open_j_hook(parent: Node3D, scale_value: float, material: Material) -> void:
	var points := [
		Vector3.ZERO,
		Vector3(0.0, -0.024, 0.0),
		Vector3(0.010, -0.036, 0.0),
		Vector3(0.023, -0.030, 0.0),
		Vector3(0.020, -0.015, 0.0),
		Vector3(0.012, -0.006, 0.0),
	]
	for index in range(points.size() - 1):
		_add_cylinder_segment(parent, "HookCurve_%d" % index, points[index] * scale_value, points[index + 1] * scale_value, SABIKI_HOOK_TUBE_RADIUS_M * scale_value, material, 5)
	var point_tip := MeshInstance3D.new()
	point_tip.name = "HookPoint"
	var point_mesh := CylinderMesh.new()
	point_mesh.top_radius = 0.0001
	point_mesh.bottom_radius = SABIKI_HOOK_TUBE_RADIUS_M * scale_value
	point_mesh.height = 0.008 * scale_value
	point_mesh.radial_segments = 5
	point_tip.mesh = point_mesh
	point_tip.position = points[points.size() - 1] * scale_value
	point_tip.rotation.x = -0.25
	point_tip.material_override = material
	point_tip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(point_tip)


func _build_treble_hook(parent: Node3D, scale_value: float, material: Material) -> void:
	for tine_index in range(3):
		var tine_root := Node3D.new()
		tine_root.name = "TrebleTine_%d" % (tine_index + 1)
		tine_root.rotation.y = TAU * float(tine_index) / 3.0
		parent.add_child(tine_root)
		_build_open_j_hook(tine_root, scale_value, material)


func _add_cylinder_segment(parent: Node3D, node_name: String, start: Vector3, finish: Vector3, radius: float, material: Material, sides: int) -> MeshInstance3D:
	var segment := MeshInstance3D.new()
	segment.name = node_name
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = maxf(start.distance_to(finish), 0.001)
	mesh.radial_segments = sides
	segment.mesh = mesh
	segment.position = (start + finish) * 0.5
	segment.basis = Basis(Quaternion(Vector3.UP, (finish - start).normalized()))
	segment.material_override = material
	segment.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(segment)
	return segment


func _make_material(color: Color, metallic: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = metallic
	material.roughness = 0.42
	return material


func _ease_out(value: float) -> float:
	var t := clampf(value, 0.0, 1.0)
	return 1.0 - pow(1.0 - t, 3.0)


func _ease_in_out(value: float) -> float:
	var t := clampf(value, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func _smoothstep(edge0: float, edge1: float, value: float) -> float:
	if is_equal_approx(edge0, edge1):
		return 1.0 if value >= edge1 else 0.0
	var t := clampf((value - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
