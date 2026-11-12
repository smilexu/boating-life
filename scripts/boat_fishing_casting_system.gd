class_name BoatFishingCastingSystem
extends Node3D

## Lightweight P6.2 casting presentation. The rod is hull-local, while the
## bait is integrated in world space and only sampled against the shared waves.

signal state_changed(state_name: String, status_key: String, hint_key: String)
signal feedback_requested(message_key: String)
signal charge_progress_changed(progress: float, visible: bool)
signal interaction_updated(snapshot: Dictionary)

enum CastState { READY, CHARGING, CASTING, WAITING, SABIKI_HOOKED_WAITING, RETRIEVING, BITE_APPROACH, FIGHTING, CATCH_PRESENTATION, LANDING, LINE_BROKEN }

const ROD_BEND_SHADER := preload("res://shaders/boat_fishing_rod_bend.gdshader")
const SINGLE_JIG_PROFILE: BoatFishingRigProfile = preload("res://resources/boat_fishing/single_jig.tres")
const SABIKI_RIG_PROFILE: BoatFishingRigProfile = preload("res://resources/boat_fishing/sabiki_rig.tres")
const ROD_LENGTH_M := 1.78
const ROD_AXIS_LOCAL := Vector3(0.0, 0.26004, -0.9656)
const HANDHELD_FIRST_GUIDE_PROGRESS := 0.50
const HANDHELD_REEL_SCREEN_ANCHOR := Vector2(0.70, 0.74)
const HANDHELD_REEL_SCREEN_ANCHOR_CONFLICT_PADDING_PX := 12.0
const HANDHELD_REEL_SCREEN_BOUNDING_RADIUS_M := 0.14
const CAST_BAIT_RELEASE_OFFSET_SECONDS := 0.19
const RETRIEVE_DURATION_SECONDS := 0.72
const BAIT_WATER_DRAG_FOLLOW := 0.78
const BAIT_WATER_DRAG_RESPONSE := 1.25
const SABIKI_MOTION_AXIS_RESPONSE_SPEED_MPS := 8.0
const SABIKI_MOTION_AXIS_MAX_LEAN := 0.48
# Presentation-only ratio for how much existing rod/line load tilts the whole
# terminal rig toward the rod while gravity still contributes to its orientation.
const BAIT_SINK_ACCELERATION_MPS2 := 2.6
const AIRBORNE_BAIT_GRAVITY_MPS2 := 5.2
const AIRBORNE_BAIT_DAMPING_PER_SECOND := 1.65
const AIRBORNE_BAIT_SURFACE_CLEARANCE_M := 0.025
const AIRBORNE_LINE_VISUAL_SAG_M := 0.18
const SEABED_CLEARANCE_M := 0.22
# Boat-line visual radius is presentation-only and kept slightly thicker than
# the trolling rig's default so it remains readable against both water tones.
const LINE_RADIUS_M := 0.0015
const LINE_SIDES := 5
const LINE_SEGMENTS := 8
const SPOON_LENGTH_M := 0.085
const SPOON_WIDTH_M := 0.024
const SPOON_LINE_EYE_Y_M := 0.050
const SPOON_HOOK_TIP_Y_M := -(SPOON_LENGTH_M * 0.5) - 0.00402
const SABIKI_HOOK_TIP_BRANCH_OFFSET := Vector3(0.00864, -0.00432, 0.0)
const SABIKI_HOOK_TUBE_RADIUS_M := 0.0022
const CHARGE_LIFT_TIME_SECONDS := 0.4
const CHARGE_MIDPOINT_SECONDS := 1.5
const CHARGE_CANCEL_DURATION_SECONDS := 0.24
const CAST_MIN_FLIGHT_TIME_SECONDS := 0.42
const CAST_MAX_FLIGHT_TIME_SECONDS := 1.18
const CAST_ARC_HEIGHT_M := 2.1
const SPLASH_DURATION_SECONDS := 0.55
const SABIKI_WATER_ENTRY_CLEARANCE_M := 0.025
const BOAT_FISHING_AUDIO_OWNER := &"boat_fishing"
const REEL_LINE_DELTA_EPSILON_M := 0.0005
const MAX_AUTOMATIC_LINE_BURST_EXTRA_M := 5.0
const DEFAULT_CAST_MAX_DISTANCE_FROM_GUNWALE_M := 0.72
const DEFAULT_CAST_MIN_OUTWARD_ALIGNMENT := 0.55
const MINIMUM_MANUAL_RETRIEVAL_LINE_M := 0.08
const FIGHT_PRESENTATION_DURATION_SECONDS := 2.6
const FIGHT_VIEW_YAW_HALF_RANGE_DEG := 55.0
const BOAT_FISHING_VIEW_PITCH_MIN_DEG := -65.0
const BOAT_FISHING_VIEW_PITCH_MAX_DEG := 35.0
const FIGHT_PRESENTATION_PITCH_MANUAL_RANGE_DEG := 7.0
const FIGHT_LANDING_MIN_REEL_DURATION_SECONDS := 0.9
const FIGHT_LANDING_ROD_LIFT_DEG := 42.0
const FIGHT_LANDING_RIG_OUTWARD_OFFSET_M := 0.28
const FIGHT_LANDING_FISH_CLEARANCE_M := 0.28
const FIGHT_LANDING_FISH_CLEARANCE_RATIO := 0.14
const FIGHT_LANDING_FISH_THRASH_ROLL_RAD := 0.32
const FIGHT_LANDING_FISH_THRASH_PITCH := 0.14
const FIGHT_HULL_SAFETY_MARGIN_M := 0.28
const SABIKI_FIGHT_LANDING_LINE_BUFFER_M := 0.35
const SABIKI_EMPTY_RETRIEVAL_APPROACH_MARGIN_M := 0.35
const FIGHT_LINE_BROKEN_DURATION_SECONDS := 0.9
const BOAT_FISHING_BITE_CONTACT_RADIUS_M := 0.08
const FIGHT_DEFAULT_DRAG_ADJUST_RATE_PER_SECOND := 0.35
const BOAT_FIGHT_LINE_PROFILE: BoatFishingLineProfile = preload("res://resources/boat_fishing/line_profiles/standard_boat_fishing_line.tres")

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
@export_range(0.05, 1.0, 0.05) var fight_drag_adjustment_per_second := FIGHT_DEFAULT_DRAG_ADJUST_RATE_PER_SECOND

@export_category("Manual handling")
@export_range(0.5, 2.5, 0.05) var manual_reel_speed_mps := 1.25
@export_range(0.5, 5.0, 0.1) var manual_line_release_speed_mps := 2.0
@export_range(0.1, 1.0, 0.05) var line_tension_slack_m := 0.45
@export_range(1.0, 10.0, 0.25) var line_pull_response := 5.0
@export_range(4.0, 18.0, 0.5) var rod_bend_at_full_tension_deg := 10.0
@export_category("Boat fight presentation")
@export_range(2.0, 80.0, 0.5) var rod_visual_reference_load_n := 18.0
@export_range(0.25, 1.5, 0.05) var rod_visual_response_exponent := 0.6
@export_range(20.0, 36.0, 1.0) var rod_visual_max_bend_deg := 34.0
@export_range(0.0, 20.0, 0.5) var rod_visual_burst_impulse_deg := 11.0
@export_range(0.05, 1.0, 0.01) var rod_visual_burst_decay_seconds := 0.28
@export_range(0.0, 5.0, 0.1) var rod_visual_release_recoil_deg := 3.5
@export_range(0.05, 1.0, 0.01) var rod_visual_release_decay_seconds := 0.32
@export_range(0.0, 4.0, 0.1) var rod_visual_micro_vibration_deg := 0.9
@export_range(0.0, 5.0, 0.1) var rod_visual_burst_vibration_deg := 2.0
@export_range(1.0, 18.0, 0.5) var rod_visual_vibration_frequency_hz := 7.5
@export_range(1.0, 30.0, 0.5) var line_visual_reference_load_n := 8.0
@export_range(0.0, 0.04, 0.001) var line_visual_vibration_m := 0.012
@export_range(1.0, 18.0, 0.5) var line_visual_vibration_frequency_hz := 8.5
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
var _cast_target_drift_velocity_world := Vector3.ZERO
var _bait_flight_elapsed := 0.0
var _bait_flight_duration := 0.0
var _bait_flight_started := false
var _bait_has_landed := false
var _cast_tackle_entry_complete := false
var _cast_first_entry_recorded := false
var _bait_airborne_retrieval := false
var _airborne_retrieval_elapsed := 0.0
var _rod_recovery_complete := false
var _rod_back_angle_deg := 0.0
var _rod_bend_angle_deg := 0.0
var _rod_release_start_bend_deg := 0.0
var _splash_elapsed := 0.0
var _bait_world := Vector3.ZERO
var _bait_velocity_world := Vector3.ZERO
var _retrieve_start_world := Vector3.ZERO
var _retrieve_start_paid_length_m := 0.0
var _line_paid_out_length_m := 0.0
var _last_sabiki_endpoint_excess_before_constraint_m := 0.0
var _maximum_sabiki_active_endpoint_excess_m := 0.0
var _sabiki_reachability_constraint_feasible := true
var _main_line_path_snapshot: Dictionary = {}
var _line_path_input_key: Array = []
var _manual_reeling := false
var _manual_reeling_from_ui := false
var _manual_reeling_input_held := false
var _manual_line_release_held := false
var _manual_line_releasing := false
var _line_controls_conflicted := false
var _automatic_control_owned := false
var _rod_tension := 0.0
var _rod_bend_direction_local := Vector2(1.0, 0.0)
var _previous_line_connection_world := Vector3.ZERO
var _has_previous_line_connection := false
var _previous_boat_world := Vector3.ZERO
var _boat_velocity_estimate_world := Vector3.ZERO
var _lure_visual_phase := 0.0
var _lure_visual_intensity := 0.0
var _lure_visual_basis_world := Basis.IDENTITY
var _rod_view_camera_relative_transform := Transform3D.IDENTITY
var _rod_view_camera_pose_captured := false
var _rod_reel_camera_depth_m := 0.0
var _rod_reel_camera_anchor_captured := false
var _landing_reel_anchor_released := false
var _rod_visual_root: Node3D
var _rod_swing: Node3D
var _rod_mesh_instance: MeshInstance3D
var _reel_mount: Node3D
var _reel_visual_root: Node3D
var _reel_spool_visual: MeshInstance3D
var _reel_rotating_assembly: Node3D
var _reel_winding_visual: MultiMeshInstance3D
var _rod_line_guides: Array[MeshInstance3D] = []
var _reel_visual_total_rotation_rad := 0.0
var _last_reel_line_delta_m := 0.0
var _requested_fishing_audio_loops := {"line_out": false, "drag": false, "reel_in": false}
var _requested_fishing_audio_intensities := {"line_out": 0.0, "drag": 0.0, "reel_in": 0.0}
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
var _sabiki_sinker_instance: MeshInstance3D
var _sabiki_hook_nodes: Array[Node3D] = []
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
var _last_pursuit_result_snapshot: Dictionary = {}
var _single_pursuit_end_recorded := false
var _bite_candidate: Dictionary = {}
var _bite_debug_spawned := false
var _bite_elapsed := 0.0
var _bite_duration := 0.0
var _bite_approach_timeout_seconds := 0.0
var _bite_pursuit_speed_mps := 0.0
var _bite_fish_visual: Node3D
var _bite_fish_start_world := Vector3.ZERO
var _bite_fish_mouth_world := Vector3.ZERO
var _bite_fish_heading_world := Vector3.FORWARD
var _bite_fish_side_world := Vector3.ZERO
var _fight_start_bait_world := Vector3.ZERO
var _fight_start_bait_depth_m := 0.0
var _fight_start_horizontal_distance_m := 0.0
var _fight_line_burst_offset_m := 0.0
var _fight_radial_direction := Vector3.FORWARD
var _active_catch_id := ""
var _active_catch_species_id := ""
var _active_catch_body_length_m := 0.0
var _bite_visual_scale := 1.0
var _catch_result_received := false
var _catch_presentation_elapsed := 0.0
var _fight_solver := BoatFishingFightSolver.new()
var _fight_session_active := false
var _fight_session_sequence := 0
var _active_fight_session_id := 0
var _fight_last_real_tick_usec := -1
var _fight_drag_setting := BOAT_FIGHT_LINE_PROFILE.default_drag_setting
var _fight_participants_by_catch_id: Dictionary = {}
var _fight_participant_order: Array[String] = []
var _fight_fish_visuals_by_catch_id: Dictionary = {}
var _fight_fish_visual_elapsed_by_catch_id: Dictionary = {}
var _fight_fish_heading_by_catch_id: Dictionary = {}
var _fight_previous_struggle_state_by_catch_id: Dictionary = {}
var _fight_sabiki_branch_directions_local: Dictionary = {}
var _fight_snapshot: Dictionary = {}
var _fight_landing_elapsed := 0.0
var _fight_landing_surface_crossed: Dictionary = {}
var _line_broken_elapsed := 0.0
var _fight_terminal_motion_this_step := false
var _fight_landing_start_bait_world := Vector3.ZERO
var _fight_landing_target_bait_world := Vector3.ZERO
var _fight_landing_start_paid_line_m := 0.0
var _fight_landing_target_paid_line_m := 0.0
var _fight_landing_reel_duration_seconds := FIGHT_LANDING_MIN_REEL_DURATION_SECONDS
var _fight_landing_start_rod_rotation := Vector3.ZERO
var _fight_landing_target_rod_rotation := Vector3.ZERO
var _fight_rod_burst_impulse_rad := 0.0
var _fight_rod_target_bend_deg := 0.0
var _fight_rod_micro_vibration_deg := 0.0
var _fight_rod_recoil_amplitude_deg := 0.0
var _fight_rod_recoil_elapsed := 0.0
var _fight_visual_elapsed := 0.0
var _fight_previous_base_bend_deg := 0.0
var _fight_drag_feedback_remaining := 0.0
var _fight_drag_feedback_direction := 0
var _fight_max_mouth_hook_error_m := 0.0
var _fight_rod_release_start_deg := 0.0
var _fight_rod_release_elapsed := 0.0
var _fight_rod_release_active := false


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
		_fight_last_real_tick_usec = Time.get_ticks_usec()
	elif what == NOTIFICATION_UNPAUSED:
		# Paused wall-clock time is not part of an active fight simulation step.
		_fight_last_real_tick_usec = Time.get_ticks_usec()


func _exit_tree() -> void:
	_clear_boat_fishing_audio_loops()
	_reset_boat_fight_session(true)
	if is_instance_valid(_encounter):
		if _encounter.pending_catch != null and _encounter.pending_catch.fishing_method == "boat_fishing":
			_encounter.cancel_boat_fishing_catch("boat_fishing_scene_unloaded")
		elif not _encounter.get_sabiki_hook_catches().is_empty():
			_encounter.cancel_sabiki_catches("boat_fishing_scene_unloaded")
		_encounter.end_boat_fishing_session("boat_fishing_scene_unloaded")


func begin_activity() -> bool:
	if _onboard == null or not _onboard.is_activity_active() or _activity_active:
		return _activity_active
	_activity_active = true
	if _onboard != null:
		_onboard.set_fishing_rod_view_pitch_constraint(
			_onboard.is_first_person_active(),
			BOAT_FISHING_VIEW_PITCH_MIN_DEG,
			BOAT_FISHING_VIEW_PITCH_MAX_DEG
		)
	_rod_view_camera_pose_captured = false
	_rod_reel_camera_anchor_captured = false
	_reset_boat_fight_session(true)
	_resolve_encounter()
	if _encounter != null:
		_encounter.begin_boat_fishing_session()
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
	_reset_boat_fight_session(true)
	if _encounter != null and _encounter.pending_catch != null and _encounter.pending_catch.fishing_method == "boat_fishing":
		_encounter.cancel_boat_fishing_catch("boat_fishing_ended")
	if _encounter != null and not _encounter.get_sabiki_hook_catches().is_empty():
		_encounter.cancel_sabiki_catches("boat_fishing_ended")
	if _encounter != null:
		_encounter.end_boat_fishing_session("boat_fishing_ended")
	clear_cast()
	_last_pursuit_result_snapshot.clear()
	_activity_active = false
	_manual_reeling = false
	_manual_reeling_from_ui = false
	_manual_reeling_input_held = false
	_manual_line_release_held = false
	_manual_line_releasing = false
	_line_controls_conflicted = false
	_automatic_control_owned = false
	_clear_boat_fishing_audio_loops()
	if _onboard != null:
		_onboard.set_fishing_rod_view_pitch_constraint(false, BOAT_FISHING_VIEW_PITCH_MIN_DEG, BOAT_FISHING_VIEW_PITCH_MAX_DEG)
	_rod_view_camera_pose_captured = false
	_rod_reel_camera_anchor_captured = false
	set_process(false)
	set_process_unhandled_input(false)
	_rod_visual_root.visible = false
	_emit_state_changed()


func clear_cast() -> void:
	if _onboard != null and _onboard.is_fishing_fight_view_active():
		_onboard.end_fishing_fight_view()
	_reset_boat_fight_session(true)
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
	_cast_first_entry_recorded = false
	_bait_airborne_retrieval = false
	_airborne_retrieval_elapsed = 0.0
	_rod_recovery_complete = false
	_waiting_elapsed = 0.0
	_cast_target_drift_velocity_world = Vector3.ZERO
	_bait_velocity_world = Vector3.ZERO
	_line_paid_out_length_m = 0.0
	_retrieve_start_paid_length_m = 0.0
	_last_sabiki_endpoint_excess_before_constraint_m = 0.0
	_maximum_sabiki_active_endpoint_excess_m = 0.0
	_sabiki_reachability_constraint_feasible = true
	_manual_reeling = false
	_manual_reeling_from_ui = false
	_manual_reeling_input_held = false
	_manual_line_release_held = false
	_manual_line_releasing = false
	_line_controls_conflicted = false
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
		_encounter.reset_boat_fishing_trigger_state()
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
	_cast_first_entry_recorded = false
	_bait_airborne_retrieval = false
	_airborne_retrieval_elapsed = 0.0
	_rod_recovery_complete = false
	_splash_elapsed = 0.0
	_state_elapsed = 0.0
	_waiting_elapsed = 0.0
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
	if active and (not _activity_active or not _is_manual_reel_state() or _automatic_control_owned or _is_menu_open()):
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
	result["last_pursuit_result"] = _last_pursuit_result_snapshot.duplicate(true)
	result["rig_id"] = _current_rig.rig_id if _current_rig != null else &""
	result["state_name"] = get_casting_state_name()
	result["line_length_m"] = _line_paid_out_length_m
	result["activity_active"] = _activity_active
	result["rig_type"] = _current_rig.rig_type if _current_rig != null else -1
	if _encounter != null:
		result["boat_fishing_session"] = _encounter.get_boat_fishing_session_snapshot()
	if _current_rig != null and _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
		var positions := get_hook_attachment_world_positions()
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
			var candidate: Dictionary = hook_state.get("candidate", {})
			hook_depths.append({
				"hook_index": hook_index,
				"depth_m": depth,
				"status": status,
				"school_id": str(candidate.get("school_id", "")),
				"pursuit_radius_m": float(candidate.get("pursuit_radius_m", 0.0)),
				"school_to_hook_distance_m": float(candidate.get("pursuit_distance_m", -1.0)),
				"actual_mouth_to_hook_distance_m": float(hook_state.get("actual_mouth_to_hook_distance_m", -1.0)),
				"approach_elapsed_seconds": float(hook_state.get("approach_elapsed", 0.0)),
				"approach_speed_mps": float(hook_state.get("approach_speed_mps", 0.0)),
			})
		result["hook_depths"] = hook_depths
		result["empty_hook_count"] = empty_count
	else:
		result["bait_depth_m"] = _get_bait_depth_below_surface_m() if _bait_has_landed else -1.0
	if _state == CastState.BITE_APPROACH:
		var active_pursuit: Dictionary = result.get("active_pursuit_approach", {})
		if active_pursuit.is_empty():
			active_pursuit = {
				"state": "approaching",
				"trigger_mode": str(_bite_candidate.get("trigger_mode", "AMBIENT_ENCOUNTER")),
				"school_id": str(_bite_candidate.get("school_id", "")),
				"hook_index": 0,
				"pursuit_radius_m": float(_bite_candidate.get("pursuit_radius_m", 0.0)),
				"school_to_hook_distance_m": float(_bite_candidate.get("pursuit_distance_m", -1.0)),
				"actual_mouth_to_hook_distance_m": _bite_fish_mouth_world.distance_to(_get_single_jig_hook_attachment_world()),
				"speed_mps": _bite_pursuit_speed_mps,
				"elapsed_seconds": _bite_elapsed,
			}
		result["active_pursuit_approach"] = active_pursuit.duplicate(true)
	if _current_rig != null and _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
		var active_pursuits: Array[Dictionary] = []
		for hook_index in range(_sabiki_hook_states.size()):
			var hook_state: Dictionary = _sabiki_hook_states[hook_index]
			if str(hook_state.get("status", "")) not in ["approaching", "hooked"]:
				continue
			var pursuit_candidate: Dictionary = hook_state.get("candidate", {})
			active_pursuits.append({
				"hook_index": hook_index,
				"state": str(hook_state.get("status", "approaching")),
				"species_id": str(hook_state.get("species_id", "")),
				"school_id": str(pursuit_candidate.get("school_id", "")),
				"pursuit_radius_m": float(pursuit_candidate.get("pursuit_radius_m", 0.0)),
				"school_to_hook_distance_m": float(pursuit_candidate.get("pursuit_distance_m", -1.0)),
				"actual_mouth_to_hook_distance_m": float(hook_state.get("actual_mouth_to_hook_distance_m", -1.0)),
				"speed_mps": float(hook_state.get("approach_speed_mps", 0.0)),
				"elapsed_seconds": float(hook_state.get("approach_elapsed", 0.0)),
			})
		result["active_pursuits"] = active_pursuits
	if include_unavailable_for_diagnostics and _activity_active and _bait_has_landed and _is_waiting_line_state() and _encounter != null and _current_rig != null:
		var relative_velocity := _bait_velocity_world - _boat_velocity_estimate_world * BAIT_WATER_DRAG_FOLLOW
		var rows: Array[Dictionary] = []
		var ambient_rows: Array[Dictionary] = []
		var ambient_evaluations: Array[Dictionary] = []
		var ambient_rate := 0.0
		var trigger_states: Array[Dictionary] = []
		var targeted_count := 0
		if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
			var positions := get_hook_attachment_world_positions()
			for hook_index in range(mini(_current_rig.hook_count, positions.size())):
				if hook_index >= _sabiki_hook_states.size() or str(_sabiki_hook_states[hook_index].get("status", "empty")) != "empty":
					if _encounter != null:
						_encounter.clear_boat_fishing_hook_trigger_state(hook_index)
					trigger_states.append({"hook_index": hook_index, "trigger_mode": "NONE", "phase": "occupied", "reason": "hook_not_empty"})
					continue
				var depth := _depth_below_surface_at(positions[hook_index])
				var evaluated := _encounter.evaluate_boat_fishing_candidates(positions[hook_index], depth, relative_velocity.length(), _current_rig, true, hook_index)
				ambient_rate = maxf(ambient_rate, float(evaluated.get("ambient_event_rate_per_real_hour", 0.0)))
				ambient_evaluations.append(evaluated)
				targeted_count += int(evaluated.get("targeted_candidate_count", 0))
				var trigger_state := _encounter.get_boat_fishing_hook_trigger_debug(hook_index)
				trigger_state["hook_index"] = hook_index
				trigger_states.append(trigger_state)
				for candidate_variant in evaluated.get("candidate_schools", []):
					var row: Dictionary = candidate_variant.duplicate(true)
					row["hook_index"] = hook_index
					row["hook_depth_m"] = depth
					rows.append(row)
				for candidate_variant in evaluated.get("ambient_candidates", []):
					var row: Dictionary = candidate_variant.duplicate(true)
					row["ambient_eligible"] = true
					ambient_rows.append(row)
		else:
			var hook_position := _get_single_jig_hook_attachment_world()
			var depth := _depth_below_surface_at(hook_position)
			var evaluated := _encounter.evaluate_boat_fishing_candidates(hook_position, depth, relative_velocity.length(), _current_rig, true, 0)
			ambient_rate = float(evaluated.get("ambient_event_rate_per_real_hour", 0.0))
			ambient_evaluations.append(evaluated)
			targeted_count = int(evaluated.get("targeted_candidate_count", 0))
			rows.assign(evaluated.get("candidate_schools", []))
			for candidate_variant in evaluated.get("ambient_candidates", []):
				var row: Dictionary = candidate_variant.duplicate(true)
				row["ambient_eligible"] = true
				ambient_rows.append(row)
			var trigger_state := _encounter.get_boat_fishing_hook_trigger_debug(0)
			trigger_state["hook_index"] = 0
			trigger_states.append(trigger_state)
		result["ambient_candidates"] = ambient_rows
		result["candidate_schools"] = rows
		result["candidate_school_count"] = rows.size()
		result["total_event_rate_per_real_hour"] = ambient_rate
		result["ambient_event_rate_per_real_hour"] = ambient_rate
		result["average_first_bite_seconds"] = 3600.0 / ambient_rate if ambient_rate > 0.0 else INF
		result["hook_trigger_states"] = trigger_states
		result["trigger_mode"] = _aggregate_boat_trigger_modes(trigger_states)
		if result["trigger_mode"] == "NONE" and ambient_rate > 0.0:
			result["trigger_mode"] = "AMBIENT_ENCOUNTER"
		result["targeted_candidate_count"] = targeted_count
		result["target_reaction_remaining_seconds"] = _minimum_target_reaction_remaining(trigger_states)
		result["reason"] = _preferred_boat_trigger_reason(trigger_states, ambient_rate, rows)
	return result


func _aggregate_boat_trigger_modes(states: Array[Dictionary]) -> String:
	var has_targeted := false
	var has_ambient := false
	for trigger_state in states:
		has_targeted = has_targeted or str(trigger_state.get("trigger_mode", "")) == "SCHOOL_TARGETED"
		has_ambient = has_ambient or str(trigger_state.get("trigger_mode", "")) == "AMBIENT_ENCOUNTER"
	if has_targeted and has_ambient:
		return "MIXED"
	if has_targeted:
		return "SCHOOL_TARGETED"
	if has_ambient:
		return "AMBIENT_ENCOUNTER"
	return "NONE"


func _preferred_boat_trigger_reason(states: Array[Dictionary], ambient_rate: float, rows: Array[Dictionary]) -> String:
	for trigger_state in states:
		var mode := str(trigger_state.get("trigger_mode", ""))
		var phase := str(trigger_state.get("phase", ""))
		if mode == "SCHOOL_TARGETED" and phase in ["target_reaction", "triggered", "target_boundary_hold"]:
			return str(trigger_state.get("reason", "target_reaction_waiting"))
	for trigger_state in states:
		if str(trigger_state.get("phase", "")) == "triggered":
			return str(trigger_state.get("reason", "bite_started"))
	if ambient_rate > 0.0:
		return "random_not_triggered"
	return _natural_bite_rejection_reason(rows)


func get_sabiki_hooked_count() -> int:
	var count := 0
	for hook_state in _sabiki_hook_states:
		if str(hook_state.get("status", "empty")) == "hooked":
			count += 1
	return count


func get_sabiki_hook_states_snapshot() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var positions := get_hook_attachment_world_positions()
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
	# Compatibility seam for any old UI caller: retrieval is now the same held
	# manual-reel input used by the left mouse button. It does not start an
	# automatic batch timeline or settle catches.
	if _current_rig == null or _current_rig.rig_type != BoatFishingRigProfile.RigType.SABIKI or get_sabiki_hooked_count() <= 0:
		return false
	return set_manual_reeling(true, true)


func debug_spawn_sabiki_fish(hook_index: int = -1, species_id: String = "herring") -> Dictionary:
	_resolve_encounter()
	if not _activity_active:
		return {"accepted": false, "reason": "boat_fishing_inactive"}
	if _current_rig == null or _current_rig.rig_type != BoatFishingRigProfile.RigType.SABIKI:
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
	var profile := _fish_manager.get_species_profile(species_id) if _fish_manager != null else null
	if profile == null or not profile.supported_fishing_methods.has("boat_fishing") or not FishingEncounterSystem.rig_matches_profile(profile, _current_rig):
		return {"accepted": false, "reason": "method_or_rig_mismatch"}
	var hook_positions := get_hook_attachment_world_positions()
	var hook_position: Vector3 = hook_positions[hook_index] if hook_index < hook_positions.size() else _bait_world
	var candidate := {
		"school_id": "",
		"species_id": species_id,
		"population": 0,
		"activity_depth_m": _depth_below_surface_at(hook_position),
		"lure_depth_m": _depth_below_surface_at(hook_position),
		"event_rate_per_game_hour": 0.0,
	}
	var pending := _encounter.reserve_sabiki_hook(candidate, _current_rig, hook_index, true)
	if pending == null:
		return {"accepted": false, "reason": "catch_already_active"}
	_begin_sabiki_hook_bite(hook_index, pending, candidate, true)
	return {"accepted": true, "hook_index": hook_index, "species_id": species_id}


func debug_fill_sabiki_rig(species_id: String = "herring") -> Dictionary:
	_resolve_encounter()
	if _current_rig == null or _current_rig.rig_type != BoatFishingRigProfile.RigType.SABIKI:
		return {"accepted": false, "reason": "sabiki_rig_required", "spawned_count": 0}
	var profile := _fish_manager.get_species_profile(species_id) if _fish_manager != null else null
	if profile == null or not profile.supported_fishing_methods.has("boat_fishing") or not FishingEncounterSystem.rig_matches_profile(profile, _current_rig):
		return {"accepted": false, "reason": "method_or_rig_mismatch", "spawned_count": 0}
	var spawned := 0
	var failure_reason := "no_empty_hook"
	var catch_limit := mini(_current_rig.hook_count, _current_rig.maximum_catch_count)
	for hook_index in range(catch_limit):
		if str(_sabiki_hook_states[hook_index].get("status", "empty")) != "empty":
			continue
		var result := debug_spawn_sabiki_fish(hook_index, species_id)
		if bool(result.get("accepted", false)):
			spawned += 1
		elif spawned == 0:
			failure_reason = str(result.get("reason", "other"))
	return {"accepted": spawned > 0, "spawned_count": spawned, "species_id": species_id, "reason": "debug_spawned" if spawned > 0 else failure_reason}


func get_hook_depth_range_m() -> Dictionary:
	if not is_cast_active() or not _bait_has_landed or _current_rig.rig_type != BoatFishingRigProfile.RigType.SABIKI:
		return {"valid": false, "shallow_m": 0.0, "deep_m": 0.0}
	var shallow_depth := INF
	var deep_depth := 0.0
	for hook_position in get_hook_attachment_world_positions():
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
	return get_rig_hook_positions()


## Actual hook tips are distinct from Sabiki branch roots returned above.
func get_hook_attachment_world_positions() -> Array[Vector3]:
	if not is_cast_active():
		return []
	if _current_rig.rig_type == BoatFishingRigProfile.RigType.SINGLE_JIG:
		return [_get_single_jig_hook_attachment_world()]
	_update_rig_visual_position()
	var positions: Array[Vector3] = []
	for hook_index in range(_current_rig.hook_count):
		positions.append(_get_sabiki_hook_attachment_world_position(hook_index))
	return positions


func _get_single_jig_hook_attachment_world() -> Vector3:
	return _bait_world + _lure_visual_basis_world * Vector3(0.0, SPOON_HOOK_TIP_Y_M, 0.0)


func _get_pending_catch_body_length_m() -> float:
	return _active_catch_body_length_m


func _get_sabiki_hook_attachment_world_position(hook_index: int) -> Vector3:
	if hook_index < 0 or hook_index >= _sabiki_hook_nodes.size() or _sabiki_rig_root == null:
		var bases := get_hook_world_positions()
		return bases[hook_index] if hook_index >= 0 and hook_index < bases.size() else _bait_world
	var hook_node := _sabiki_hook_nodes[hook_index]
	var branch_length := _current_rig.branch_length_m
	var local_hook_tip := Vector3(-branch_length, 0.0, 0.0) + SABIKI_HOOK_TIP_BRANCH_OFFSET
	return hook_node.global_transform * local_hook_tip


func get_rig_hook_positions() -> Array[Vector3]:
	var positions: Array[Vector3] = []
	if _current_rig.rig_type != BoatFishingRigProfile.RigType.SABIKI or not is_cast_active():
		return positions
	_ensure_fishing_line_path_snapshot()
	var stations: Dictionary = _main_line_path_snapshot.get("stations", {})
	for hook_index in range(_current_rig.hook_count):
		var name := "hook_%d" % (hook_index + 1)
		if stations.has(name):
			positions.append(stations[name]["position"])
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


func on_camera_view_changed(first_person_active: bool) -> void:
	## Release held controls on O without disturbing the cast itself.
	if _onboard != null:
		_onboard.set_fishing_rod_view_pitch_constraint(
			first_person_active and _activity_active,
			BOAT_FISHING_VIEW_PITCH_MIN_DEG,
			BOAT_FISHING_VIEW_PITCH_MAX_DEG
		)
	if _rod_visual_root != null and is_instance_valid(_rod_visual_root):
		_rod_visual_root.visible = _activity_active and first_person_active
	# Rebuild the hand-to-camera relationship after every view transition. The
	# next first-person process frame captures the reel's screen position again.
	_rod_view_camera_pose_captured = false
	_rod_reel_camera_anchor_captured = false
	if not first_person_active:
		_manual_reeling = false
		_manual_reeling_from_ui = false
		_manual_reeling_input_held = false
		_manual_line_release_held = false
		_manual_line_releasing = false
		_line_controls_conflicted = false
		if _state == CastState.CHARGING:
			cancel_charge_smoothly()
	interaction_updated.emit(get_interaction_snapshot())


func get_casting_state() -> int:
	return _state


func get_casting_state_name() -> String:
	return ["READY", "CHARGING", "CASTING", "WAITING", "SABIKI_HOOKED_WAITING", "RETRIEVING", "BITE_APPROACH", "FIGHTING", "CATCH_PRESENTATION", "LANDING", "LINE_BROKEN"][_state]


func is_cast_active() -> bool:
	return _state in [CastState.CASTING, CastState.WAITING, CastState.SABIKI_HOOKED_WAITING, CastState.RETRIEVING, CastState.BITE_APPROACH, CastState.FIGHTING, CastState.CATCH_PRESENTATION, CastState.LANDING]


func is_activity_active() -> bool:
	return _activity_active


func get_bait_depth_below_surface_m() -> float:
	return _get_bait_depth_below_surface_m()


func get_debug_snapshot() -> Dictionary:
	var line_start := _get_rod_tip_world() if _rod_visual_root != null else Vector3.ZERO
	var line_connection := _get_main_line_terminal_world() if _rod_visual_root != null else Vector3.ZERO
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
		"endpoint_chord_m": line_start.distance_to(line_connection) if is_cast_active() else 0.0,
		"maximum_line_length_m": maximum_line_length_m,
		"paid_out_line_length_m": _line_paid_out_length_m,
		"effective_physical_line_length_m": _get_effective_main_line_length_m(),
		"sabiki_endpoint_excess_before_constraint_m": _last_sabiki_endpoint_excess_before_constraint_m,
		"sabiki_max_active_endpoint_excess_m": _maximum_sabiki_active_endpoint_excess_m,
		"sabiki_reachability_constraint_feasible": _sabiki_reachability_constraint_feasible,
		"visual_free_line_geometry_length_m": float(_main_line_path_snapshot.get("free_line_geometry_length_m", 0.0)),
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
		"rod_camera_relative_pose_captured": _rod_view_camera_pose_captured,
		"rod_view_pitch_degrees": rad_to_deg(_onboard.get_camera_pitch()) if _onboard != null else 0.0,
		"line_tension": _rod_tension,
		"automatic_control_owned": _automatic_control_owned,
		"bite_approach_active": _state == CastState.BITE_APPROACH,
		"catch_in_progress": _state in [CastState.SABIKI_HOOKED_WAITING, CastState.FIGHTING, CastState.LANDING, CastState.CATCH_PRESENTATION],
		"catch_result_received": _catch_result_received,
		"active_catch_id": _active_catch_id,
		"debug_spawned_catch": _bite_debug_spawned,
		"fight_session_active": _fight_session_active,
		"fight_session_id": _active_fight_session_id,
		"drag_setting": _fight_drag_setting,
		"fight_snapshot": get_fight_snapshot(),
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
		"line_terminal_world_position": line_connection,
		"hook_world_positions": get_hook_attachment_world_positions(),
		"sabiki_hooks": get_sabiki_hook_states_snapshot(),
		"sabiki_hooked_count": get_sabiki_hooked_count(),
		"sabiki_hook_capacity": _current_rig.maximum_catch_count,
		"sabiki_batch_retrieval_active": _sabiki_batch_retrieval_active,
		"sabiki_batch_result_summary": _sabiki_batch_result_summary.duplicate(true),
		"movement_locked": _onboard.is_movement_locked() if _onboard != null else false,
		"first_person_active": _onboard.is_first_person_active() if _onboard != null else false,
	}


func get_interaction_snapshot() -> Dictionary:
	var tip := (_get_fight_solver_rod_tip_world() if _fight_session_active else _get_rod_tip_world()) if _rod_visual_root != null else Vector3.ZERO
	var line_connection := _get_main_line_terminal_world() if _rod_visual_root != null else Vector3.ZERO
	return {
		"state": get_casting_state_name(),
		"line_active": is_cast_active(),
		"actual_line_length_m": tip.distance_to(line_connection) if is_cast_active() else 0.0,
		"endpoint_chord_m": tip.distance_to(line_connection) if is_cast_active() else 0.0,
		"paid_out_line_length_m": _line_paid_out_length_m if is_cast_active() else 0.0,
		"effective_physical_line_length_m": _get_effective_main_line_length_m() if is_cast_active() else 0.0,
		"line_length_m": _line_paid_out_length_m if is_cast_active() else 0.0,
		"bait_depth_below_surface_m": _get_bait_depth_below_surface_m() if is_cast_active() else 0.0,
		"sinker_depth_below_surface_m": get_sinker_depth_below_surface_m() if is_cast_active() else 0.0,
		"water_depth_m": _get_water_depth_at_bait_m() if is_cast_active() else -1.0,
		"seabed_valid": bool(_sample_seabed(_bait_world).get("valid", false)) if is_cast_active() else false,
		"lure_world_position": _bait_world,
		"sinker_world_position": get_sinker_world_position(),
		"line_terminal_world_position": line_connection,
		"hook_world_positions": get_hook_attachment_world_positions(),
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
		"catch_in_progress": _state in [CastState.SABIKI_HOOKED_WAITING, CastState.FIGHTING, CastState.LANDING, CastState.CATCH_PRESENTATION],
		"bite_approach_active": _state == CastState.BITE_APPROACH,
		"catch_debug_spawned": _bite_debug_spawned,
		"catch_id": _active_catch_id,
		"catch_result_received": _catch_result_received,
		"fight_session_active": _fight_session_active,
		"fight_session_id": _active_fight_session_id,
		"drag_setting": _fight_drag_setting,
		"drag_adjustment_feedback_remaining": _fight_drag_feedback_remaining,
		"drag_adjustment_direction": _fight_drag_feedback_direction,
		"fight_snapshot": get_fight_snapshot(),
	}


func get_fight_snapshot(include_geometry_debug: bool = false) -> Dictionary:
	var result := _fight_snapshot.duplicate(true)
	if include_geometry_debug and _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
		_update_rig_visual_position()
	var participants: Array[Dictionary] = []
	for catch_id in _fight_participant_order:
		var participant := _fight_participants_by_catch_id.get(catch_id) as BoatFishingFightParticipant
		if participant != null:
			var row := participant.get_read_only_snapshot()
			if include_geometry_debug:
				var hook_position := _fight_hook_position_by_catch_id(catch_id)
				var visual := _fight_fish_visuals_by_catch_id.get(catch_id) as Node3D
				var profile := _fish_manager.get_species_profile(str(row.get("species_id", ""))) if _fish_manager != null else null
				var mouth_position := hook_position
				var fish_position := Vector3.ZERO
				var mouth_error := -1.0
				var hull_clearance := -1.0
				if visual != null and is_instance_valid(visual) and profile != null:
					fish_position = visual.global_position
					mouth_position = visual.global_transform * profile.boat_fishing_mouth_anchor_local
					mouth_error = mouth_position.distance_to(hook_position)
					hull_clearance = _get_fight_body_hull_clearance_m(visual, profile, float(row.get("body_length_m", 0.0)))
				row["hook_world_position"] = hook_position
				row["fish_world_position"] = fish_position
				row["mouth_world_position"] = mouth_position
				row["mouth_hook_error_m"] = mouth_error
				row["hull_clearance_m"] = hull_clearance
			participants.append(row)
	result["session_active"] = _fight_session_active
	result["session_id"] = _active_fight_session_id
	result["drag_setting"] = _fight_drag_setting
	result["participant_count"] = participants.size()
	result["participants"] = participants
	result["line_length_m"] = _line_paid_out_length_m
	result["line_break_force_n"] = BOAT_FIGHT_LINE_PROFILE.line_break_force_n
	result["drag_threshold_n"] = BOAT_FIGHT_LINE_PROFILE.get_drag_threshold_n(_fight_drag_setting)
	result["state_name"] = get_casting_state_name()
	result["rod_burst_impulse_rad"] = _fight_rod_burst_impulse_rad
	result["rod_visual_reference_load_n"] = rod_visual_reference_load_n
	result["rod_visual_target_bend_deg"] = _fight_rod_target_bend_deg
	result["rod_visual_actual_bend_deg"] = _rod_bend_angle_deg
	result["rod_tip_vibration_deg"] = _fight_rod_micro_vibration_deg
	result["rod_burst_impulse_deg"] = rad_to_deg(_fight_rod_burst_impulse_rad)
	result["line_visual_slack_ratio"] = _get_fight_line_visual_slack_ratio()
	result["line_visual_tautness"] = 1.0 - float(result["line_visual_slack_ratio"])
	result["drag_adjustment_feedback_remaining"] = _fight_drag_feedback_remaining
	result["drag_adjustment_direction"] = _fight_drag_feedback_direction
	result["mouth_hook_error_max_m"] = _fight_max_mouth_hook_error_m
	return result


func _get_fight_line_visual_slack_ratio() -> float:
	if not _fight_session_active:
		return 1.0
	return calculate_line_visual_slack_ratio(
		float(_fight_snapshot.get("tension_n", 0.0)),
		line_visual_reference_load_n
	)


func _get_fight_body_hull_clearance_m(visual: Node3D, profile: FishSpeciesProfile, body_length_m: float) -> float:
	if _boat_controller == null or not _boat_controller.has_method("get_vessel_length_m") or not _boat_controller.has_method("get_vessel_beam_m"):
		return -1.0
	var forward_local := Vector3.LEFT if profile.model_forward_axis == 1 else Vector3.RIGHT
	var tail_direction := -(visual.global_basis * forward_local).normalized()
	var body_radius := maxf(0.02, body_length_m * 0.08)
	var minimum_clearance := INF
	for sample_index in range(5):
		var fraction := float(sample_index) / 4.0
		var sample_position := visual.global_position.lerp(visual.global_position + tail_direction * body_length_m * 0.92, fraction)
		minimum_clearance = minf(minimum_clearance, _get_hull_ellipse_clearance_m(sample_position) - body_radius)
	return minimum_clearance if is_finite(minimum_clearance) else -1.0


func _get_hull_ellipse_clearance_m(position: Vector3) -> float:
	if _boat_controller == null or not _boat_controller.has_method("get_vessel_length_m") or not _boat_controller.has_method("get_vessel_beam_m"):
		return -1.0
	var local := _boat_controller.to_local(position)
	var half_beam := maxf(0.5, float(_boat_controller.call("get_vessel_beam_m")) * 0.5 + FIGHT_HULL_SAFETY_MARGIN_M)
	var half_length := maxf(1.0, float(_boat_controller.call("get_vessel_length_m")) * 0.5 + FIGHT_HULL_SAFETY_MARGIN_M)
	var normalized_radius := sqrt(local.x * local.x / (half_beam * half_beam) + local.z * local.z / (half_length * half_length))
	return (normalized_radius - 1.0) * minf(half_beam, half_length)


func _unhandled_input(event: InputEvent) -> void:
	if not _activity_active:
		return
	if event.is_action_pressed("boat_fishing_cast", false):
		if not _is_pointer_over_ui() and _onboard != null and _onboard.is_first_person_active():
			if _state == CastState.READY:
				begin_charge()
				get_viewport().set_input_as_handled()
			elif _is_manual_reel_state():
				set_manual_reeling(true)
				get_viewport().set_input_as_handled()
	elif event.is_action_released("boat_fishing_cast"):
		if _state == CastState.CHARGING:
			if _is_pointer_over_ui() or _is_menu_open():
				cancel_charge_smoothly()
			else:
				release_charge()
			get_viewport().set_input_as_handled()
		elif _is_manual_reel_state():
			set_manual_reeling(false)
			get_viewport().set_input_as_handled()


func _input(event: InputEvent) -> void:
	if not _activity_active:
		return
	if _fight_session_active and not _is_menu_open() and not _is_pointer_over_ui() and (event.is_action_pressed("boat_fishing_drag_loosen", false) or event.is_action_pressed("boat_fishing_drag_tighten", false)):
		get_viewport().set_input_as_handled()
		return
	if not InputMap.has_action("boat_fishing_pay_out"):
		return
	if event.is_action_pressed("boat_fishing_pay_out", false):
		# F also opens port services; give it to line payout only during a live
		# water cast without a fight. During a fight the reel solver owns all
		# line motion; F must not act as a second line-length writer.
		if _is_waiting_line_state() or (_fight_session_active and _state == CastState.FIGHTING):
			if not _fight_session_active and not _automatic_control_owned and not _is_pointer_over_ui() and not _is_menu_open():
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
	var first_person_active := _onboard.is_first_person_active()
	if _rod_visual_root != null and is_instance_valid(_rod_visual_root):
		_rod_visual_root.visible = first_person_active
		# Keep one camera-relative hand pose through charge, cast, waiting, and fight.
		# Cast and fight movement stays local to the rod swing pivot.
		if first_person_active:
			_update_rod_hand_anchor()
	var fight_real_delta := _measure_fight_real_delta()
	var feedback_delta := fight_real_delta if _fight_session_active else maxf(delta, 0.0)
	_fight_drag_feedback_remaining = maxf(0.0, _fight_drag_feedback_remaining - feedback_delta)
	var reel_line_length_before := _get_reel_feedback_line_length()
	_update_boat_velocity_estimate(delta)
	if _state == CastState.READY:
		_update_ready_rod_pose()
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
		if _fight_session_active:
			_update_fight_controls(fight_real_delta)
			_advance_boat_fight(fight_real_delta)
		else:
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
		if _is_menu_open() or _has_gui_focus():
			release_held_controls_for_ui()
		elif _is_pointer_over_ui():
			_release_non_ui_line_inputs()
		else:
			_reconcile_physical_line_inputs()
			_sync_manual_line_controls()
			_update_fight_controls(fight_real_delta)
		_advance_boat_fight(fight_real_delta)
	elif _state == CastState.CATCH_PRESENTATION:
		_advance_catch_presentation(delta)
	elif _state == CastState.LANDING:
		_advance_fight_landing(delta)
	elif _state == CastState.LINE_BROKEN:
		_advance_line_broken(delta)
	if first_person_active:
		# Landing/presentation may have adjusted camera pitch after the initial
		# anchor update. Reapply the same-frame view transform before line geometry.
		_update_rod_hand_anchor()
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
	var diagnostic_ambient_candidates: Array[Dictionary] = []
	var hook_depths: Array[Dictionary] = []
	var bite_started := false
	var hook_trigger_states: Array[Dictionary] = []
	var has_targeted_mode := false
	var last_reason := "no_ambient_candidates"
	var targeted_candidate_count := 0
	var ambient_evaluations: Array[Dictionary] = []
	if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
		var hook_positions := get_hook_attachment_world_positions()
		for hook_index in range(mini(_current_rig.hook_count, hook_positions.size())):
			var hook_status := str(_sabiki_hook_states[hook_index].get("status", "empty")) if hook_index < _sabiki_hook_states.size() else "empty"
			var hook_position: Vector3 = hook_positions[hook_index]
			var hook_depth := _depth_below_surface_at(hook_position)
			hook_depths.append({"hook_index": hook_index, "depth_m": hook_depth, "status": hook_status})
			if hook_status != "empty":
				_encounter.clear_boat_fishing_hook_trigger_state(hook_index)
				hook_trigger_states.append({"hook_index": hook_index, "trigger_mode": "NONE", "phase": "occupied", "reason": "hook_not_empty"})
				continue
			var diagnostics := _encounter.evaluate_boat_fishing_candidates(
				hook_position,
				hook_depth,
				relative_velocity.length(),
				_current_rig,
				false,
				hook_index
			)
			targeted_candidate_count += int(diagnostics.get("targeted_candidate_count", 0))
			for candidate_variant in diagnostics.get("candidate_schools", []):
				var row: Dictionary = candidate_variant.duplicate(true)
				row["hook_index"] = hook_index
				row["hook_depth_m"] = hook_depth
				diagnostic_candidates.append(row)
			for candidate_variant in diagnostics.get("ambient_candidates", []):
				var ambient_row: Dictionary = candidate_variant.duplicate(true)
				ambient_row["hook_index"] = hook_index
				ambient_row["ambient_eligible"] = true
				diagnostic_ambient_candidates.append(ambient_row)
			var trigger := _encounter.advance_boat_fishing_trigger_for_hook(diagnostics, elapsed_real_seconds, hook_index)
			trigger["hook_index"] = hook_index
			hook_trigger_states.append(trigger.duplicate(true))
			var trigger_mode := str(trigger.get("trigger_mode", "NONE"))
			has_targeted_mode = has_targeted_mode or trigger_mode == "SCHOOL_TARGETED"
			last_reason = str(trigger.get("reason", diagnostics.get("reason", last_reason)))
			var candidate: Dictionary = trigger.get("candidate", {})
			var hook_locked := false
			if not candidate.is_empty():
				var pending := _encounter.reserve_sabiki_hook(candidate, _current_rig, hook_index, false)
				if pending != null:
					_encounter.clear_boat_fishing_hook_trigger_state(hook_index)
					_begin_sabiki_hook_bite(hook_index, pending, candidate, false, str(candidate.get("trigger_mode", "")) == "SCHOOL_TARGETED")
					bite_started = true
					hook_locked = true
				else:
					trigger["reason"] = "reservation_failed"
					last_reason = "reservation_failed"
					hook_trigger_states[hook_trigger_states.size() - 1] = trigger.duplicate(true)
				hook_locked = true
			elif str(trigger.get("phase", "")) == "target_reaction":
				hook_locked = true
			var ambient_evaluation := diagnostics.duplicate(true)
			ambient_evaluation["trigger_locked"] = hook_locked
			ambient_evaluations.append(ambient_evaluation)
		var ambient_trigger := _encounter.advance_boat_fishing_ambient_hazard(ambient_evaluations, elapsed_real_seconds)
		if str(ambient_trigger.get("phase", "")) == "triggered":
			var ambient_context: Dictionary = ambient_trigger.get("ambient_context", {})
			var ambient_request := _encounter.request_ambient_boat_fishing_catch(ambient_context, _current_rig)
			_encounter.set_boat_fishing_ambient_authority_result(ambient_request)
			if bool(ambient_request.get("accepted", false)):
				var ambient_pending := ambient_request.get("pending") as FishingPendingCatch
				var ambient_candidate: Dictionary = ambient_request.get("candidate", {})
				var ambient_hook_index := int(ambient_trigger.get("hook_index", -1))
				if ambient_pending != null and _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
					_begin_sabiki_hook_bite(ambient_hook_index, ambient_pending, ambient_candidate, false)
					bite_started = true
				elif ambient_pending != null:
					bite_started = _begin_bite_event(ambient_candidate, false, false, ambient_pending)
				if ambient_hook_index >= 0 and ambient_hook_index < hook_trigger_states.size():
					hook_trigger_states[ambient_hook_index] = {"hook_index": ambient_hook_index, "trigger_mode": "AMBIENT_ENCOUNTER", "phase": "reserved", "reason": "ambient_authority_reserved", "ambient_fish_id": ambient_pending.ambient_fish_id if ambient_pending != null else ""}
			else:
				last_reason = str(ambient_request.get("reason", "ambient_authority_rejected"))
				if ambient_trigger.get("hook_index", -1) >= 0 and int(ambient_trigger.get("hook_index", -1)) < hook_trigger_states.size():
					hook_trigger_states[int(ambient_trigger.get("hook_index", -1))] = {"hook_index": int(ambient_trigger.get("hook_index", -1)), "trigger_mode": "AMBIENT_ENCOUNTER", "phase": "rejected", "reason": last_reason}
		var ambient_rate := float(ambient_trigger.get("ambient_event_rate_per_real_hour", 0.0))
		for evaluation in ambient_evaluations:
			if bool(evaluation.get("trigger_locked", false)) or _dictionary_array_for_casting(evaluation.get("ambient_candidates", [])).is_empty():
				continue
			var ambient_hook_index := int(evaluation.get("hook_index", -1))
			if ambient_hook_index >= 0 and ambient_hook_index < hook_trigger_states.size() and str(ambient_trigger.get("phase", "")) == "ambient_waiting":
				hook_trigger_states[ambient_hook_index] = {"hook_index": ambient_hook_index, "trigger_mode": "AMBIENT_ENCOUNTER", "phase": "ambient_waiting", "reason": str(ambient_trigger.get("reason", "random_not_triggered")), "ambient_event_rate_per_real_hour": ambient_rate}
		_last_natural_bite_diagnostics = {
			"rig_id": _current_rig.rig_id,
			"rig_type": _current_rig.rig_type,
			"state_name": get_casting_state_name(),
			"line_length_m": _line_paid_out_length_m,
			"lure_relative_speed_mps": relative_velocity.length(),
			"hook_depths": hook_depths,
			"hook_trigger_states": hook_trigger_states,
			"empty_hook_count": _count_empty_sabiki_hooks(),
			"candidate_schools": diagnostic_candidates,
			"ambient_candidates": diagnostic_ambient_candidates,
			"candidate_school_count": diagnostic_candidates.size(),
			"targeted_candidate_count": targeted_candidate_count,
			"trigger_mode": "MIXED" if has_targeted_mode and ambient_rate > 0.0 else ("SCHOOL_TARGETED" if has_targeted_mode else ("AMBIENT_ENCOUNTER" if ambient_rate > 0.0 else str(ambient_trigger.get("trigger_mode", "NONE")))),
			"total_event_rate_per_real_hour": ambient_rate,
			"ambient_event_rate_per_real_hour": ambient_rate,
			"average_first_bite_seconds": 3600.0 / ambient_rate if ambient_rate > 0.0 else INF,
			"ambient_hazard_accumulated": float(ambient_trigger.get("hazard_accumulated", 0.0)),
			"ambient_hazard_threshold": float(ambient_trigger.get("hazard_threshold", 0.0)),
			"ambient_eligible_hook_count": int(ambient_trigger.get("eligible_hook_count", 0)),
			"ambient_eligible_species_count": int(ambient_trigger.get("eligible_species_count", 0)),
			"target_reaction_remaining_seconds": _minimum_target_reaction_remaining(hook_trigger_states),
			"reason": "bite_started" if bite_started else str(ambient_trigger.get("reason", last_reason)),
			"last_sample_real_delta_seconds": elapsed_real_seconds,
		}
		_last_natural_bite_diagnostics["boat_fishing_session"] = _encounter.get_boat_fishing_session_snapshot()
		return
	if _current_rig.rig_type != BoatFishingRigProfile.RigType.SINGLE_JIG:
		return
	var single_hook_world := _get_single_jig_hook_attachment_world()
	var bait_depth := _depth_below_surface_at(single_hook_world)
	var diagnostics := _encounter.evaluate_boat_fishing_candidates(
		single_hook_world,
		bait_depth,
		relative_velocity.length(),
		_current_rig,
		false,
		0
	)
	for candidate_variant in diagnostics.get("candidate_schools", []):
		diagnostic_candidates.append(candidate_variant.duplicate(true))
	for candidate_variant in diagnostics.get("ambient_candidates", []):
		var ambient_row: Dictionary = candidate_variant.duplicate(true)
		ambient_row["ambient_eligible"] = true
		diagnostic_ambient_candidates.append(ambient_row)
	targeted_candidate_count = int(diagnostics.get("targeted_candidate_count", 0))
	var trigger := _encounter.advance_boat_fishing_trigger_for_hook(diagnostics, elapsed_real_seconds, 0)
	hook_trigger_states.append(trigger.duplicate(true))
	var candidate: Dictionary = trigger.get("candidate", {})
	if not candidate.is_empty():
		bite_started = _begin_bite_event(candidate, false, false)
		if not bite_started:
			trigger["reason"] = "reservation_failed"
	has_targeted_mode = str(trigger.get("trigger_mode", "")) == "SCHOOL_TARGETED"
	var ambient_eval_single := diagnostics.duplicate(true)
	ambient_eval_single["trigger_locked"] = not candidate.is_empty() or str(trigger.get("phase", "")) == "target_reaction"
	var ambient_trigger_single := _encounter.advance_boat_fishing_ambient_hazard([ambient_eval_single], elapsed_real_seconds)
	if str(ambient_trigger_single.get("phase", "")) == "triggered":
		var request := _encounter.request_ambient_boat_fishing_catch(ambient_trigger_single.get("ambient_context", {}), _current_rig)
		_encounter.set_boat_fishing_ambient_authority_result(request)
		if bool(request.get("accepted", false)):
			bite_started = _begin_bite_event(request.get("candidate", {}), false, false, request.get("pending") as FishingPendingCatch)
		else:
			last_reason = str(request.get("reason", "ambient_authority_rejected"))
	elif not _dictionary_array_for_casting(diagnostics.get("ambient_candidates", [])).is_empty() and str(ambient_trigger_single.get("phase", "")) == "ambient_waiting":
		hook_trigger_states[0] = {"hook_index": 0, "trigger_mode": "AMBIENT_ENCOUNTER", "phase": "ambient_waiting", "reason": str(ambient_trigger_single.get("reason", "random_not_triggered")), "ambient_event_rate_per_real_hour": float(ambient_trigger_single.get("ambient_event_rate_per_real_hour", 0.0))}
	var total_event_rate := float(ambient_trigger_single.get("ambient_event_rate_per_real_hour", 0.0))
	_last_natural_bite_diagnostics = {
		"rig_id": _current_rig.rig_id,
		"rig_type": _current_rig.rig_type,
		"state_name": get_casting_state_name(),
		"line_length_m": _line_paid_out_length_m,
		"bait_depth_m": bait_depth,
		"lure_relative_speed_mps": relative_velocity.length(),
		"hook_trigger_states": hook_trigger_states,
		"candidate_schools": diagnostic_candidates,
		"ambient_candidates": diagnostic_ambient_candidates,
		"candidate_school_count": diagnostic_candidates.size(),
		"targeted_candidate_count": targeted_candidate_count,
		"trigger_mode": "SCHOOL_TARGETED" if has_targeted_mode else ("AMBIENT_ENCOUNTER" if total_event_rate > 0.0 else str(ambient_trigger_single.get("trigger_mode", "NONE"))),
		"total_event_rate_per_real_hour": total_event_rate,
		"ambient_event_rate_per_real_hour": total_event_rate,
		"average_first_bite_seconds": 3600.0 / total_event_rate if total_event_rate > 0.0 else INF,
		"target_reaction_remaining_seconds": _minimum_target_reaction_remaining(hook_trigger_states),
		"ambient_hazard_accumulated": float(ambient_trigger_single.get("hazard_accumulated", 0.0)),
		"ambient_hazard_threshold": float(ambient_trigger_single.get("hazard_threshold", 0.0)),
		"ambient_eligible_hook_count": int(ambient_trigger_single.get("eligible_hook_count", 0)),
		"ambient_eligible_species_count": int(ambient_trigger_single.get("eligible_species_count", 0)),
		"reason": "bite_started" if bite_started else str(ambient_trigger_single.get("reason", diagnostics.get("reason", last_reason))),
		"last_sample_real_delta_seconds": elapsed_real_seconds,
	}
	_last_natural_bite_diagnostics["boat_fishing_session"] = _encounter.get_boat_fishing_session_snapshot()


func _dictionary_array_for_casting(value: Variant) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if value is Array:
		for row in value:
			if row is Dictionary:
				result.append(row)
	return result


func _minimum_target_reaction_remaining(states: Array[Dictionary]) -> float:
	var remaining := INF
	for state in states:
		if str(state.get("trigger_mode", "")) == "SCHOOL_TARGETED" and str(state.get("phase", "")) == "target_reaction":
			remaining = minf(remaining, float(state.get("reaction_remaining_seconds", INF)))
	return remaining


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
	for reason in ["method_or_rig_mismatch", "empty_school", "outside_pursuit_sphere", "activity_depth_mismatch"]:
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
	var positions := get_hook_attachment_world_positions()
	if hook_index >= positions.size():
		_encounter.release_sabiki_reservation(pending.catch_id)
		return
	var hook_position: Vector3 = positions[hook_index]
	var hook_depth := _depth_below_surface_at(hook_position)
	var should_approach := should_visualize_bite_approach(hook_depth, shallow_bite_visual_depth_m, force_approach)
	var hook_state: Dictionary = _sabiki_hook_states[hook_index]
	var approach_candidate := candidate.duplicate(true)
	hook_state["status"] = "approaching" if should_approach else "reserved"
	hook_state["pending"] = pending
	hook_state["catch_id"] = pending.catch_id
	hook_state["species_id"] = pending.species_id
	hook_state["debug_spawned"] = debug_spawned
	hook_state["body_length_m"] = pending.body_length_m
	hook_state["approach_elapsed"] = 0.0
	hook_state["pursuit_end_recorded"] = false
	hook_state["surface_crossed"] = false
	hook_state["candidate"] = approach_candidate
	if should_approach:
		var school_start := hook_position - Vector3.FORWARD * 3.2
		if pending.source_type == "ambient":
			var ambient_start: Variant = candidate.get("spawn_world_position", [])
			if ambient_start is Array and ambient_start.size() >= 3:
				school_start = Vector3(float(ambient_start[0]), float(ambient_start[1]), float(ambient_start[2]))
		elif not debug_spawned:
			var has_school_center := candidate.get("school_center_world_position", null) is Vector3
			var school_center := candidate.get("school_center_world_position", Vector3.ZERO) as Vector3
			if _fish_manager != null:
				var school := _fish_manager.get_school(pending.school_id)
				if not school.is_empty():
					school_center = _school_activity_center_world(school, hook_position)
					has_school_center = true
			var profile_for_start := _fish_manager.get_species_profile(pending.species_id) if _fish_manager != null else null
			if has_school_center and school_center.is_finite():
				approach_candidate["pursuit_anchor_world_position"] = school_center
				school_start = school_pursuit_start_world(
					school_center,
					hook_position,
					profile_for_start.school_wander_radius_m if profile_for_start != null else 2.4
				)
		if debug_spawned:
			var boat_forward := -_boat_controller.global_basis.z if _boat_controller != null else Vector3.FORWARD
			boat_forward.y = 0.0
			if boat_forward.length_squared() < 0.001:
				boat_forward = Vector3.FORWARD
			school_start = hook_position - boat_forward.normalized() * 3.2
		var start_surface_y := float(_sample_water(school_start).get("height", hook_position.y))
		var activity_depth := maxf(0.0, float(candidate.get("activity_depth_m", hook_depth)))
		if pending.source_type == "school" and not debug_spawned:
			var school := _fish_manager.get_school(pending.school_id) if _fish_manager != null else {}
			if not school.is_empty():
				activity_depth = maxf(0.0, float(school.get("effective_activity_depth_m", school.get("activity_depth_m", activity_depth))))
		school_start.y = start_surface_y - activity_depth
		var direction_to_hook := hook_position - school_start
		if direction_to_hook.length_squared() < 0.001:
			direction_to_hook = -_boat_controller.global_basis.z if _boat_controller != null else Vector3.FORWARD
		direction_to_hook = direction_to_hook.normalized()
		var profile := _fish_manager.get_species_profile(pending.species_id) if _fish_manager != null else null
		var speed := 0.65
		if profile != null:
			speed = maxf(0.1, (profile.movement_speed_min_mps + profile.movement_speed_max_mps) * 0.5)
		var school_targeted := str(candidate.get("trigger_mode", "")) == "SCHOOL_TARGETED"
		hook_state["candidate"] = approach_candidate
		hook_state["pursuit_anchor_world_position"] = approach_candidate.get("pursuit_anchor_world_position", Vector3.ZERO)
		hook_state["start_world"] = school_start
		hook_state["mouth_world"] = school_start
		hook_state["heading_world"] = direction_to_hook
		hook_state["approach_speed_mps"] = speed
		hook_state["side_world"] = direction_to_hook.cross(Vector3.UP).normalized()
		var estimated_duration := school_start.distance_to(hook_position) / speed
		hook_state["approach_duration"] = estimated_duration if school_targeted else clampf(estimated_duration, 0.8, 3.6)
		hook_state["approach_timeout_seconds"] = maxf(15.0, float(hook_state["approach_duration"]) * 2.0 + 5.0)
		hook_state["actual_mouth_to_hook_distance_m"] = school_start.distance_to(hook_position)
		hook_state["visual"] = _create_sabiki_fish_visual(pending.species_id, pending.body_length_m, direction_to_hook)
		if hook_state["visual"] != null:
			(hook_state["visual"] as Node3D).name = "SabikiHookFish_%02d" % (hook_index + 1)
			_set_fish_visual_pose_at_hook(hook_state["visual"] as Node3D, pending.species_id, pending.body_length_m, school_start, direction_to_hook)
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
		var target := Vector3.ZERO
		if str(hook_state.get("status", "")) == "approaching":
			var elapsed := float(hook_state.get("approach_elapsed", 0.0)) + maxf(delta, 0.0)
			hook_state["approach_elapsed"] = elapsed
			var hook_positions := get_hook_attachment_world_positions()
			var invalid_hook_position := hook_index >= hook_positions.size()
			if not invalid_hook_position:
				target = hook_positions[hook_index]
			var approach_pending := hook_state.get("pending") as FishingPendingCatch
			var candidate: Dictionary = hook_state.get("candidate", {})
			var school_targeted := str(candidate.get("trigger_mode", "")) == "SCHOOL_TARGETED"
			if invalid_hook_position:
				var released_invalid_hook := _clear_sabiki_hook_state(hook_index, true)
				var invalid_mouth: Vector3 = hook_state.get("mouth_world", hook_state.get("start_world", Vector3.ZERO))
				_record_sabiki_pursuit_result(hook_index, hook_state, approach_pending, Vector3(INF, INF, INF), "failed", "hook_invalid", "released" if released_invalid_hook else "not_released", invalid_mouth)
				continue
			if school_targeted:
				var pursuit_anchor: Variant = hook_state.get("pursuit_anchor_world_position", null)
				var pursuit := _school_pursuit_still_valid_at_anchor(candidate, approach_pending, target, pursuit_anchor)
				if not bool(pursuit.get("valid", false)):
					var reason := str(pursuit.get("reason", "pursuit_cancelled"))
					var mouth_at_end: Vector3 = hook_state.get("mouth_world", hook_state.get("start_world", target))
					var released := _clear_sabiki_hook_state(hook_index, true)
					_record_sabiki_pursuit_result(hook_index, hook_state, approach_pending, target, "failed", reason, "released" if released else "not_released", mouth_at_end)
					continue
			var mouth_world: Vector3 = hook_state.get("mouth_world", hook_state.get("start_world", target))
			var speed := maxf(0.0, float(hook_state.get("approach_speed_mps", 0.65)))
			var progress := clampf(elapsed / maxf(0.01, float(hook_state.get("approach_duration", 1.0))), 0.0, 1.0)
			if school_targeted:
				mouth_world = advance_fish_pursuit_world(mouth_world, target, speed, maxf(delta, 0.0))
			else:
				var start: Vector3 = hook_state.get("start_world", mouth_world)
				var side: Vector3 = hook_state.get("side_world", Vector3.RIGHT)
				mouth_world = start.lerp(target, _smoothstep01(progress)) + side * sin(PI * progress) * 0.22 + Vector3.UP * sin(PI * progress) * 0.08
			var distance_to_hook := mouth_world.distance_to(target)
			hook_state["mouth_world"] = mouth_world
			hook_state["actual_mouth_to_hook_distance_m"] = distance_to_hook
			var visual := hook_state.get("visual") as Node3D
			var current_heading: Vector3 = hook_state.get("heading_world", target - mouth_world)
			var desired_heading := target - mouth_world
			var profile := _fish_manager.get_species_profile(str(hook_state.get("species_id", ""))) if _fish_manager != null else null
			var turn_rate := deg_to_rad(profile.boat_fishing_turn_rate_deg_s) if profile != null else deg_to_rad(240.0)
			var heading := turn_pursuit_heading(current_heading, desired_heading, turn_rate, maxf(delta, 0.0))
			hook_state["heading_world"] = heading
			if visual != null and is_instance_valid(visual):
				_set_fish_visual_pose_at_hook(visual, str(hook_state.get("species_id", "herring")), float(hook_state.get("body_length_m", 0.32)), mouth_world, heading, sin(elapsed * 6.0) * 0.045)
			if school_targeted and elapsed > float(hook_state.get("approach_timeout_seconds", 30.0)):
				var released_on_timeout := _clear_sabiki_hook_state(hook_index, true)
				_record_sabiki_pursuit_result(hook_index, hook_state, approach_pending, target, "failed", "approach_timeout", "released" if released_on_timeout else "not_released", mouth_world)
				continue
			_sabiki_hook_states[hook_index] = hook_state
			if (school_targeted and distance_to_hook > BOAT_FISHING_BITE_CONTACT_RADIUS_M) or (not school_targeted and progress < 1.0):
				continue
		var pending := hook_state.get("pending") as FishingPendingCatch
		var was_approaching := str(hook_state.get("status", "")) == "approaching"
		var catch_id := str(hook_state.get("catch_id", ""))
		var pending_was_reserved := _has_sabiki_pending_catch(catch_id)
		var bite_confirmed := pending != null and _encounter != null and _encounter.confirm_sabiki_hook(catch_id)
		if not bite_confirmed:
			var pending_still_reserved := _has_sabiki_pending_catch(catch_id)
			var pending_release_result := "not_released"
			if pending_still_reserved:
				pending_release_result = "released" if _encounter.release_sabiki_reservation(catch_id) else "not_released"
			elif pending_was_reserved:
				pending_release_result = "released_by_authority"
			var mouth_at_end: Vector3 = hook_state.get("mouth_world", hook_state.get("start_world", target))
			if was_approaching:
				_record_sabiki_pursuit_result(hook_index, hook_state, pending, target, "failed", "authority_confirmation_rejected", pending_release_result, mouth_at_end)
			_clear_sabiki_hook_state(hook_index, false)
			continue
		if was_approaching:
			var confirmed_mouth: Vector3 = hook_state.get("mouth_world", target)
			_record_sabiki_pursuit_result(hook_index, hook_state, pending, target, "success", "bite_confirmed", "confirmed", confirmed_mouth)
		hook_state["status"] = "hooked"
		hook_state["pending"] = pending
		hook_state["body_length_m"] = pending.body_length_m
		if hook_state.get("visual") == null:
			var hook_positions := get_hook_attachment_world_positions()
			if hook_index < hook_positions.size():
				var heading := _get_sabiki_rig_up_direction_world()
				var visual := _create_sabiki_fish_visual(pending.species_id, pending.body_length_m, heading)
				if visual != null:
					visual.name = "SabikiHookFish_%02d" % (hook_index + 1)
					_set_fish_visual_pose_at_hook(visual, pending.species_id, pending.body_length_m, hook_positions[hook_index], _get_hull_outward_horizontal(hook_positions[hook_index]))
					hook_state["visual"] = visual
		_sabiki_hook_states[hook_index] = hook_state
		if not _register_fight_participant(pending, hook_state.get("visual") as Node3D):
			_encounter.cancel_sabiki_catches("boat_fight_participant_init_failed")
			_reset_boat_fight_session(true)
			_clear_sabiki_hook_visuals()
			_reset_sabiki_hook_states()
			_set_state(CastState.WAITING)
			return
		_rod_tension = maxf(_rod_tension, 0.18)
		_rod_bend_angle_deg = rod_bend_at_full_tension_deg * _rod_tension
		_set_rod_bend_angle(deg_to_rad(_rod_bend_angle_deg))
		_set_state(CastState.SABIKI_HOOKED_WAITING)
		# The first participant changes the loaded terminal axis immediately. Keep
		# already hooked fish mouths on the same-frame hook geometry before render.
		_update_rig_visual_position()
		_reanchor_sabiki_hooked_fish_visuals_to_hooks()


func _update_sabiki_hooked_fish_visuals(delta: float) -> void:
	if _current_rig.rig_type != BoatFishingRigProfile.RigType.SABIKI or _sabiki_hook_states.is_empty():
		return
	var hook_positions := get_hook_attachment_world_positions()
	for hook_index in range(mini(_sabiki_hook_states.size(), hook_positions.size())):
		var hook_state: Dictionary = _sabiki_hook_states[hook_index]
		if str(hook_state.get("status", "")) != "hooked":
			continue
		var visual := hook_state.get("visual") as Node3D
		if visual == null or not is_instance_valid(visual):
			continue
		var hook_position: Vector3 = hook_positions[hook_index]
		var surface_y := float(_sample_water(hook_position).get("height", hook_position.y))
		var is_out_of_water := hook_position.y >= surface_y
		if is_out_of_water:
			if not bool(hook_state.get("surface_crossed", false)):
				hook_state["surface_crossed"] = true
				if Time.get_ticks_msec() * 0.001 - _last_sabiki_splash_time >= 0.32:
					_last_sabiki_splash_time = Time.get_ticks_msec() * 0.001
					_show_splash_visual(hook_position)
					_play_boat_fishing_one_shot("splash")
		if _fight_session_active or _state == CastState.LANDING:
			_sabiki_hook_states[hook_index] = hook_state
			continue
		if _state == CastState.CATCH_PRESENTATION and _catch_result_received:
			continue
		var elapsed := float(hook_state.get("struggle_elapsed", 0.0)) + maxf(delta, 0.0)
		hook_state["struggle_elapsed"] = elapsed
		_sabiki_hook_states[hook_index] = hook_state
		_set_fish_visual_pose_at_hook(visual, str(hook_state.get("species_id", "herring")), float(hook_state.get("body_length_m", 0.32)), hook_position, _fight_radial_direction, sin(elapsed * 7.0) * 0.055)


func _reanchor_sabiki_hooked_fish_visuals_to_hooks() -> void:
	if _current_rig.rig_type != BoatFishingRigProfile.RigType.SABIKI or _sabiki_hook_states.is_empty():
		return
	var hook_positions := get_hook_attachment_world_positions()
	for hook_index in range(mini(_sabiki_hook_states.size(), hook_positions.size())):
		var hook_state: Dictionary = _sabiki_hook_states[hook_index]
		if str(hook_state.get("status", "")) != "hooked":
			continue
		var visual := hook_state.get("visual") as Node3D
		if visual == null or not is_instance_valid(visual):
			continue
		var profile := _fish_manager.get_species_profile(str(hook_state.get("species_id", ""))) if _fish_manager != null else null
		if profile == null:
			continue
		var fish_basis := visual.global_basis
		visual.global_position = mouth_anchored_fish_origin(
			hook_positions[hook_index],
			fish_basis,
			profile.boat_fishing_mouth_anchor_local
		)


func _reset_sabiki_hook_states() -> void:
	_sabiki_hook_states.clear()
	_fight_sabiki_branch_directions_local.clear()
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


func _clear_sabiki_hook_state(hook_index: int, release_reservation: bool) -> bool:
	if hook_index < 0 or hook_index >= _sabiki_hook_states.size():
		return false
	var hook_state: Dictionary = _sabiki_hook_states[hook_index]
	var visual := hook_state.get("visual") as Node3D
	if visual != null and is_instance_valid(visual):
		visual.queue_free()
	var reservation_released := false
	if release_reservation and _encounter != null:
		var catch_id := str(hook_state.get("catch_id", ""))
		if not catch_id.is_empty():
			reservation_released = _encounter.release_sabiki_reservation(catch_id)
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
	return reservation_released


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


func _set_fish_visual_pose_at_hook(
	fish: Node3D,
	species_id: String,
	body_length_m: float,
	hook_world: Vector3,
	heading: Vector3,
	roll_radians: float = 0.0
) -> void:
	if fish == null or not is_instance_valid(fish):
		return
	var profile := _fish_manager.get_species_profile(species_id) if _fish_manager != null else null
	if profile == null:
		return
	var scale_factor := maxf(0.05, body_length_m / 1.2)
	var direction := heading if heading.is_finite() and heading.length_squared() > 0.001 else _fight_radial_direction
	if direction.length_squared() < 0.001:
		direction = Vector3.FORWARD
	direction = direction.normalized()
	var basis := _boat_fish_basis_for_heading(direction, profile)
	basis = basis.rotated(direction, clampf(roll_radians, -0.5, 0.5))
	var scaled_basis := basis.scaled(Vector3.ONE * scale_factor)
	fish.global_transform = Transform3D(
		scaled_basis,
		mouth_anchored_fish_origin(hook_world, scaled_basis, profile.boat_fishing_mouth_anchor_local)
	)


func _boat_fish_basis_for_heading(direction: Vector3, profile: FishSpeciesProfile) -> Basis:
	var horizontal := Vector3(direction.x, 0.0, direction.z)
	if horizontal.length_squared() < 0.0001:
		horizontal = Vector3(_fight_radial_direction.x, 0.0, _fight_radial_direction.z)
	if horizontal.length_squared() < 0.0001:
		horizontal = Vector3.FORWARD
	horizontal = horizontal.normalized()
	var pitch := clampf(direction.y, -0.65, 0.65)
	var forward := Vector3(horizontal.x, pitch, horizontal.z).normalized()
	var model_x_forward := -forward if profile.model_forward_axis == 1 else forward
	var model_up := Vector3.UP - model_x_forward * model_x_forward.dot(Vector3.UP)
	if model_up.length_squared() < 0.0001:
		model_up = Vector3.RIGHT - model_x_forward * model_x_forward.dot(Vector3.RIGHT)
	model_up = model_up.normalized()
	var model_z := model_x_forward.cross(model_up).normalized()
	return Basis(model_x_forward, model_up, model_z)


func _depth_below_surface_at(position: Vector3) -> float:
	var sample := _sample_water(position)
	return maxf(0.0, float(sample.get("height", position.y)) - position.y)


func _school_activity_center_world(school: Dictionary, reference_position: Vector3) -> Vector3:
	var values: Array = school.get("world_position", [])
	if values.size() < 3:
		return reference_position
	var x := float(values[0])
	var z := float(values[2])
	var activity_depth := maxf(0.0, float(school.get("effective_activity_depth_m", school.get("activity_depth_m", 0.0))))
	var surface := _sample_water(Vector3(x, reference_position.y, z))
	return Vector3(x, float(surface.get("height", reference_position.y)) - activity_depth, z)


func _school_pursuit_still_valid(candidate: Dictionary, pending: FishingPendingCatch, hook_world: Vector3) -> Dictionary:
	return _school_pursuit_still_valid_at_anchor(candidate, pending, hook_world, null)


func _school_pursuit_still_valid_at_anchor(candidate: Dictionary, pending: FishingPendingCatch, hook_world: Vector3, pursuit_anchor_world: Variant) -> Dictionary:
	if str(candidate.get("trigger_mode", "")) != "SCHOOL_TARGETED":
		return {"valid": true, "reason": "not_school_pursuit", "distance_m": -1.0}
	if pending == null:
		return {"valid": false, "reason": "pending_catch_invalid", "distance_m": INF}
	if pending.debug_spawned:
		return {"valid": true, "reason": "debug_pursuit", "distance_m": -1.0}
	if pending.source_type != "school":
		return {"valid": false, "reason": "pending_catch_invalid", "distance_m": INF}
	if not hook_world.is_finite() or pending.catch_id.is_empty() or pending.fishing_method != "boat_fishing":
		return {"valid": false, "reason": "hook_invalid" if not hook_world.is_finite() else "pending_catch_invalid", "distance_m": INF}
	if str(candidate.get("school_id", "")) != pending.school_id or str(candidate.get("species_id", "")) != pending.species_id:
		return {"valid": false, "reason": "pending_catch_invalid", "distance_m": INF}
	if not _is_school_pursuit_pending_active(pending):
		return {"valid": false, "reason": "pending_catch_invalid", "distance_m": INF}
	if _fish_manager == null or not is_instance_valid(_fish_manager):
		return {"valid": false, "reason": "school_unavailable", "distance_m": INF}
	var school := _fish_manager.get_school(pending.school_id)
	if school.is_empty() or str(school.get("species_id", "")) != pending.species_id or int(school.get("population", 0)) <= 0 or str(school.get("resource_state", "available")) != "available":
		return {"valid": false, "reason": "school_unavailable", "distance_m": INF}
	var profile := _fish_manager.get_species_profile(pending.species_id)
	if profile == null:
		return {"valid": false, "reason": "unknown_species", "distance_m": INF}
	var center: Vector3 = _school_activity_center_world(school, hook_world)
	var anchor_value: Variant = pursuit_anchor_world
	if anchor_value == null:
		anchor_value = candidate.get("pursuit_anchor_world_position", null)
	if anchor_value is Vector3 and (anchor_value as Vector3).is_finite():
		center = anchor_value as Vector3
	var distance := center.distance_to(hook_world)
	var radius := maxf(0.1, profile.boat_fishing_pursuit_radius_m)
	if distance > radius:
		return {"valid": false, "reason": "pursuit_range_exited", "distance_m": distance, "center_world_position": center}
	return {
		"valid": true,
		"reason": "pursuit_active",
		"distance_m": distance,
		"center_world_position": center,
		"school_activity_depth_m": maxf(0.0, float(school.get("effective_activity_depth_m", school.get("activity_depth_m", 0.0)))),
		"school_activity_state": str(school.get("effective_surface_activity_state", school.get("surface_activity_state", "unknown"))),
		"activity_depth_is_eligibility_only": true,
	}


func _is_school_pursuit_pending_active(pending: FishingPendingCatch) -> bool:
	if _encounter == null or not is_instance_valid(_encounter):
		return false
	if _current_rig != null and _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
		for active_pending in _encounter.get_sabiki_hook_catches():
			if active_pending.catch_id == pending.catch_id and active_pending.school_id == pending.school_id and not active_pending.hook_confirmed:
				return true
		return false
	var active_pending := _encounter.pending_catch
	return active_pending != null and active_pending.catch_id == pending.catch_id and active_pending.school_id == pending.school_id and not active_pending.hook_confirmed


func _has_sabiki_pending_catch(catch_id: String) -> bool:
	if _encounter == null or catch_id.is_empty():
		return false
	for pending in _encounter.get_sabiki_hook_catches():
		if pending.catch_id == catch_id:
			return true
	return false


func _record_pursuit_result(
	candidate: Dictionary,
	pending: FishingPendingCatch,
	hook_index: int,
	hook_world: Vector3,
	fish_mouth_world: Vector3,
	result: String,
	end_reason: String,
	pending_release_result: String,
	elapsed_seconds: float,
	catch_id_override: String = ""
) -> void:
	var catch_id := catch_id_override
	if catch_id.is_empty() and pending != null:
		catch_id = pending.catch_id
	var school_id := str(candidate.get("school_id", pending.school_id if pending != null else ""))
	var species_id := str(candidate.get("species_id", pending.species_id if pending != null else ""))
	var school: Dictionary = _fish_manager.get_school(school_id) if _fish_manager != null and not school_id.is_empty() else {}
	var school_depth := float(candidate.get("effective_activity_depth_m", candidate.get("activity_depth_m", -1.0)))
	var school_state := str(candidate.get("effective_surface_activity_state", candidate.get("surface_activity_state", "unknown")))
	if not school.is_empty():
		school_depth = float(school.get("effective_activity_depth_m", school.get("activity_depth_m", school_depth)))
		school_state = str(school.get("effective_surface_activity_state", school.get("surface_activity_state", school_state)))
	var profile := _fish_manager.get_species_profile(species_id) if _fish_manager != null and not species_id.is_empty() else null
	var pursuit_radius := float(candidate.get("pursuit_radius_m", profile.boat_fishing_pursuit_radius_m if profile != null else 0.0))
	var anchor: Variant = candidate.get("pursuit_anchor_world_position", candidate.get("school_center_world_position", null))
	if not anchor is Vector3 and not school.is_empty() and hook_world.is_finite():
		anchor = _school_activity_center_world(school, hook_world)
	var hook_to_school_distance := -1.0
	if hook_world.is_finite() and anchor is Vector3 and (anchor as Vector3).is_finite():
		hook_to_school_distance = hook_world.distance_to(anchor as Vector3)
	var hook_depth := _depth_below_surface_at(hook_world) if hook_world.is_finite() else -1.0
	_last_pursuit_result_snapshot = {
		"species_id": species_id,
		"school_id": school_id,
		"catch_id": catch_id,
		"hook_index": hook_index,
		"trigger_mode": str(candidate.get("trigger_mode", "AMBIENT_ENCOUNTER")),
		"result": result,
		"end_reason": end_reason,
		"elapsed_seconds": maxf(0.0, elapsed_seconds),
		"fish_mouth_to_hook_distance_m": fish_mouth_world.distance_to(hook_world) if fish_mouth_world.is_finite() and hook_world.is_finite() else -1.0,
		"hook_depth_m": hook_depth,
		"school_activity_depth_m": school_depth,
		"school_activity_state": school_state,
		"pursuit_radius_m": pursuit_radius,
		"hook_to_school_distance_m": hook_to_school_distance,
		"pending_release_result": pending_release_result,
		"line_paid_out_length_m": _line_paid_out_length_m,
	}


func _record_single_pursuit_result(result: String, end_reason: String, pending_release_result: String, pending: FishingPendingCatch = null) -> void:
	if _single_pursuit_end_recorded or _state != CastState.BITE_APPROACH:
		return
	_single_pursuit_end_recorded = true
	var hook_world := _get_single_jig_hook_attachment_world()
	var pending_to_record := pending
	if pending_to_record == null and _encounter != null:
		var active_pending := _encounter.pending_catch
		if active_pending != null and active_pending.catch_id == _active_catch_id:
			pending_to_record = active_pending
	_record_pursuit_result(
		_bite_candidate,
		pending_to_record,
		0,
		hook_world,
		_bite_fish_mouth_world,
		result,
		end_reason,
		pending_release_result,
		_bite_elapsed,
		_active_catch_id
	)


func _record_sabiki_pursuit_result(
	hook_index: int,
	hook_state: Dictionary,
	pending: FishingPendingCatch,
	hook_world: Vector3,
	result: String,
	end_reason: String,
	pending_release_result: String,
	fish_mouth_world: Vector3
) -> void:
	if bool(hook_state.get("pursuit_end_recorded", false)):
		return
	hook_state["pursuit_end_recorded"] = true
	var candidate: Dictionary = hook_state.get("candidate", {})
	_record_pursuit_result(
		candidate,
		pending,
		hook_index,
		hook_world,
		fish_mouth_world,
		result,
		end_reason,
		pending_release_result,
		float(hook_state.get("approach_elapsed", 0.0)),
		str(hook_state.get("catch_id", ""))
	)


func _is_waiting_line_state() -> bool:
	return _state in [CastState.WAITING, CastState.SABIKI_HOOKED_WAITING]


func _is_manual_reel_state() -> bool:
	return _is_waiting_line_state() or (_fight_session_active and _state == CastState.FIGHTING)


func _has_gui_focus() -> bool:
	if get_viewport() == null:
		return false
	return is_instance_valid(get_viewport().gui_get_focus_owner())


func _begin_bite_event(candidate: Dictionary, debug_spawned: bool, force_approach: bool, reserved_pending: FishingPendingCatch = null) -> bool:
	if _encounter == null or candidate.is_empty():
		return false
	var pending := reserved_pending if reserved_pending != null else _encounter.begin_boat_fishing_approach(candidate, debug_spawned)
	if pending == null:
		return false
	debug_spawned = pending.debug_spawned
	_bite_candidate = candidate.duplicate(true)
	_bite_debug_spawned = debug_spawned
	_active_catch_id = pending.catch_id
	_active_catch_species_id = pending.species_id
	_active_catch_body_length_m = pending.body_length_m
	_bite_elapsed = 0.0
	_single_pursuit_end_recorded = false
	_bite_fish_visual = null
	var species := _fish_manager.get_species_profile(pending.species_id) if _fish_manager != null else null
	var depth_m := _get_bait_depth_below_surface_m()
	var school_targeted := str(candidate.get("trigger_mode", "")) == "SCHOOL_TARGETED"
	var should_approach := should_visualize_bite_approach(depth_m, shallow_bite_visual_depth_m, force_approach or school_targeted)
	var school_start := _bait_world
	if pending.source_type == "ambient":
		var ambient_start: Variant = candidate.get("spawn_world_position", [])
		if ambient_start is Array and ambient_start.size() >= 3:
			school_start = Vector3(float(ambient_start[0]), float(ambient_start[1]), float(ambient_start[2]))
	elif school_targeted and not debug_spawned:
		var has_school_center := candidate.get("school_center_world_position", null) is Vector3
		var school_center := candidate.get("school_center_world_position", Vector3.ZERO) as Vector3
		if _fish_manager != null:
			var school := _fish_manager.get_school(pending.school_id)
			if not school.is_empty():
				school_center = _school_activity_center_world(school, _bait_world)
				has_school_center = true
		if has_school_center and school_center.is_finite():
			_bite_candidate["pursuit_anchor_world_position"] = school_center
			school_start = school_pursuit_start_world(
				school_center,
				_bait_world,
				species.school_wander_radius_m if species != null else 2.4
			)
	if should_approach:
		if debug_spawned:
			var boat_forward := -_boat_controller.global_basis.z if _boat_controller != null else Vector3.FORWARD
			boat_forward.y = 0.0
			if boat_forward.length_squared() < 0.001:
				boat_forward = Vector3.FORWARD
			school_start = _bait_world - boat_forward.normalized() * 3.2
		var fish_depth := float(candidate.get("activity_depth_m", depth_m))
		if pending.source_type != "ambient":
			var start_surface := float(_sample_water(school_start).get("height", _bait_world.y))
			school_start.y = start_surface - fish_depth
		_bite_fish_start_world = school_start
		_bite_fish_mouth_world = school_start
		var to_bait := _bait_world - school_start
		if to_bait.length_squared() < 0.001:
			to_bait = Vector3.FORWARD
		_bite_fish_heading_world = to_bait.normalized()
		_bite_fish_side_world = _bite_fish_heading_world.cross(Vector3.UP).normalized()
		_bite_pursuit_speed_mps = 1.0
		if species != null:
			_bite_pursuit_speed_mps = maxf(0.1, (species.movement_speed_min_mps + species.movement_speed_max_mps) * 0.5)
		var estimated_duration := _bite_fish_mouth_world.distance_to(_bait_world) / _bite_pursuit_speed_mps
		_bite_duration = estimated_duration if school_targeted else clampf(estimated_duration, 1.0, 4.5)
		_bite_approach_timeout_seconds = maxf(15.0, _bite_duration * 2.0 + 5.0)
		_bite_fish_visual = _create_transient_fish_visual(pending.species_id, pending.body_length_m, _bite_fish_heading_world)
		if _bite_fish_visual != null:
			_set_fish_visual_pose_at_hook(_bite_fish_visual, pending.species_id, pending.body_length_m, _bite_fish_start_world, _bite_fish_heading_world)
	else:
		_bite_duration = 0.0
		_bite_approach_timeout_seconds = 0.0
		_bite_pursuit_speed_mps = 0.0
		_bite_fish_start_world = _bait_world
		_bite_fish_mouth_world = _bait_world
	set_automatic_control_owned(true)
	_manual_reeling = false
	_manual_line_releasing = false
	_manual_reeling_input_held = false
	_manual_line_release_held = false
	_set_boat_fishing_audio_loop("reel_in", false)
	_set_boat_fishing_audio_loop("line_out", false)
	_set_boat_fishing_audio_loop("drag", false)
	if should_approach:
		_set_state(CastState.BITE_APPROACH)
	else:
		_confirm_boat_bite()
	return true


func _advance_bite_approach(delta: float) -> void:
	var elapsed_delta := maxf(0.0, delta)
	_bite_elapsed += elapsed_delta
	var hook_world := _get_single_jig_hook_attachment_world()
	var school_targeted := str(_bite_candidate.get("trigger_mode", "")) == "SCHOOL_TARGETED"
	var pending := _encounter.pending_catch if _encounter != null else null
	if school_targeted:
		var pursuit := _school_pursuit_still_valid(_bite_candidate, pending, hook_world)
		if not bool(pursuit.get("valid", false)):
			_cancel_school_bite_approach(str(pursuit.get("reason", "pursuit_cancelled")))
			return
	var progress := clampf(_bite_elapsed / maxf(0.01, _bite_duration), 0.0, 1.0)
	if school_targeted:
		_bite_fish_mouth_world = advance_fish_pursuit_world(_bite_fish_mouth_world, hook_world, _bite_pursuit_speed_mps, elapsed_delta)
	else:
		var travel := hook_world - _bite_fish_start_world
		var lateral := _bite_fish_side_world * sin(PI * progress) * minf(0.65, travel.length() * 0.08)
		var vertical := Vector3.UP * sin(PI * progress) * 0.16
		_bite_fish_mouth_world = _bite_fish_start_world.lerp(hook_world, _smoothstep01(progress)) + lateral + vertical
	var distance_to_hook := _bite_fish_mouth_world.distance_to(hook_world)
	var species := _fish_manager.get_species_profile(_active_catch_species_id) if _fish_manager != null else null
	var turn_rate := deg_to_rad(species.boat_fishing_turn_rate_deg_s) if species != null else deg_to_rad(240.0)
	_bite_fish_heading_world = turn_pursuit_heading(_bite_fish_heading_world, hook_world - _bite_fish_mouth_world, turn_rate, elapsed_delta)
	if _bite_fish_visual != null and is_instance_valid(_bite_fish_visual):
		_set_fish_visual_pose_at_hook(_bite_fish_visual, _active_catch_species_id, _get_pending_catch_body_length_m(), _bite_fish_mouth_world, _bite_fish_heading_world, sin(_bite_elapsed * 5.5) * 0.035)
	_last_natural_bite_diagnostics["active_pursuit_approach"] = {
		"state": "approaching",
		"trigger_mode": str(_bite_candidate.get("trigger_mode", "AMBIENT_ENCOUNTER")),
		"school_id": str(_bite_candidate.get("school_id", "")),
		"hook_index": 0,
		"pursuit_radius_m": float(_bite_candidate.get("pursuit_radius_m", 0.0)),
		"school_to_hook_distance_m": float(_bite_candidate.get("pursuit_distance_m", -1.0)),
		"species_id": _active_catch_species_id,
		"start_distance_to_hook_m": _bite_fish_start_world.distance_to(hook_world),
		"actual_mouth_to_hook_distance_m": distance_to_hook,
		"elapsed_seconds": _bite_elapsed,
		"estimated_duration_seconds": _bite_duration,
		"timeout_seconds": _bite_approach_timeout_seconds,
		"speed_mps": _bite_pursuit_speed_mps,
		"contact_radius_m": BOAT_FISHING_BITE_CONTACT_RADIUS_M,
		"reservation_state": "reserved",
	}
	if school_targeted and _bite_elapsed > _bite_approach_timeout_seconds:
		_cancel_school_bite_approach("approach_timeout")
		return
	if (school_targeted and distance_to_hook <= BOAT_FISHING_BITE_CONTACT_RADIUS_M) or (not school_targeted and progress >= 1.0):
		_last_natural_bite_diagnostics["active_pursuit_approach"]["state"] = "contact"
		_last_natural_bite_diagnostics["active_pursuit_approach"]["reservation_state"] = "contact_confirming"
		_confirm_boat_bite()


func _cancel_school_bite_approach(reason: String) -> void:
	_last_natural_bite_diagnostics["last_pursuit_failure_reason"] = reason
	_last_natural_bite_diagnostics["active_pursuit_approach"] = {"state": "cancelled", "reason": reason}
	var pending_before := _encounter.pending_catch if _encounter != null else null
	var cancelled := pending_before != null and _encounter.cancel_boat_fishing_catch(reason)
	if not _single_pursuit_end_recorded:
		var release_result := "released" if cancelled else "not_released"
		_record_single_pursuit_result("failed", reason, release_result, pending_before)
		if _bite_fish_visual != null and is_instance_valid(_bite_fish_visual):
			_bite_fish_visual.queue_free()
		_bite_fish_visual = null
		set_automatic_control_owned(false)
		_bite_candidate.clear()
		_active_catch_id = ""
		_set_state(CastState.WAITING)


func _confirm_boat_bite() -> void:
	var pending_before := _encounter.pending_catch if _encounter != null else null
	if _encounter == null or not _encounter.confirm_boat_fishing_bite():
		if _state == CastState.BITE_APPROACH and not _single_pursuit_end_recorded:
			var was_reserved := pending_before != null and pending_before.catch_id == _active_catch_id
			var still_reserved := _encounter != null and _encounter.pending_catch != null and _encounter.pending_catch.catch_id == _active_catch_id
			_record_single_pursuit_result(
				"failed",
				"authority_confirmation_rejected",
				"released_by_authority" if was_reserved and not still_reserved else "not_released",
				pending_before
			)
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
	if _state == CastState.BITE_APPROACH:
		_record_single_pursuit_result("success", "bite_confirmed", "confirmed", pending)
	var active_pursuit: Dictionary = _last_natural_bite_diagnostics.get("active_pursuit_approach", {})
	if not active_pursuit.is_empty():
		active_pursuit["state"] = "hooked"
		active_pursuit["reservation_state"] = "confirmed"
		active_pursuit["actual_mouth_to_hook_distance_m"] = _bite_fish_mouth_world.distance_to(_get_single_jig_hook_attachment_world())
		_last_natural_bite_diagnostics["active_pursuit_approach"] = active_pursuit
	_active_catch_id = pending.catch_id
	_active_catch_species_id = pending.species_id
	_active_catch_body_length_m = pending.body_length_m
	_fight_start_bait_world = _bait_world
	_fight_start_bait_depth_m = _get_bait_depth_below_surface_m()
	_fight_line_burst_offset_m = 0.0
	var fight_connection := _get_main_line_terminal_world()
	var horizontal := Vector3(fight_connection.x - _get_fight_solver_rod_tip_world().x, 0.0, fight_connection.z - _get_fight_solver_rod_tip_world().z)
	_fight_start_horizontal_distance_m = horizontal.length()
	_fight_radial_direction = horizontal.normalized() if horizontal.length_squared() > 0.001 else -_boat_controller.global_basis.z.normalized() if _boat_controller != null else Vector3.FORWARD
	if _bite_fish_visual == null:
		_bite_fish_visual = _create_transient_fish_visual(pending.species_id, pending.body_length_m, _fight_radial_direction)
	var single_hook_position := _get_single_jig_hook_attachment_world()
	if _bite_fish_visual != null:
		_set_fish_visual_pose_at_hook(_bite_fish_visual, pending.species_id, pending.body_length_m, single_hook_position, _fight_radial_direction)
	if not _register_fight_participant(pending, _bite_fish_visual):
		_encounter.cancel_boat_fishing_catch("boat_fight_participant_init_failed")
		_reset_boat_fight_session(true)
		_active_catch_id = ""
		_active_catch_species_id = ""
		_set_state(CastState.WAITING)
		return
	set_automatic_control_owned(false)
	_rod_tension = 0.0
	_rod_bend_angle_deg = rod_bend_at_full_tension_deg * _rod_tension
	_set_rod_bend_angle(deg_to_rad(_rod_bend_angle_deg))
	_catch_result_received = false
	_catch_presentation_elapsed = 0.0
	_set_state(CastState.FIGHTING)


func _register_fight_participant(pending: FishingPendingCatch, fish_visual: Node3D) -> bool:
	if pending == null or pending.catch_id.is_empty() or not pending.hook_confirmed:
		return false
	if _fight_participants_by_catch_id.has(pending.catch_id):
		return true
	if _fight_participant_order.size() >= BoatFishingFightSolver.MAX_FISH_PARTICIPANTS:
		return false
	if not _fight_session_active:
		_fight_session_sequence += 1
		_active_fight_session_id = _fight_session_sequence
		_fight_solver.reset_session()
		_fight_drag_setting = clampf(BOAT_FIGHT_LINE_PROFILE.default_drag_setting, 0.0, 1.0)
		_fight_session_active = true
		_fight_last_real_tick_usec = Time.get_ticks_usec()
		_fight_snapshot = _fight_solver.get_read_only_snapshot()
	var species := _fish_manager.get_species_profile(pending.species_id) if _fish_manager != null else null
	var reference_length := -1.0
	if species != null:
		reference_length = (species.body_length_range_m.x + species.body_length_range_m.y) * 0.5
	var profile := BoatFishingFightProfileCatalog.load_profile(pending.species_id, reference_length)
	if profile == null:
		return false
	var fish_position := _fight_hook_position_for_pending(pending)
	var participant := BoatFishingFightParticipant.new()
	if not participant.initialize_from_pending_catch(pending, profile, -1, _get_hull_outward_horizontal(fish_position)):
		return false
	_fight_participants_by_catch_id[pending.catch_id] = participant
	_fight_participant_order.append(pending.catch_id)
	_fight_fish_visuals_by_catch_id[pending.catch_id] = fish_visual
	_fight_fish_visual_elapsed_by_catch_id[pending.catch_id] = 0.0
	_fight_fish_heading_by_catch_id[pending.catch_id] = -_get_hull_outward_horizontal(fish_position)
	_fight_previous_struggle_state_by_catch_id[pending.catch_id] = "steady"
	if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
		_fight_sabiki_branch_directions_local[pending.hook_index] = Vector3.LEFT
	if _active_catch_id.is_empty():
		_active_catch_id = pending.catch_id
		_active_catch_species_id = pending.species_id
		_bite_debug_spawned = pending.debug_spawned
	return true


func _fight_hook_position_for_pending(pending: FishingPendingCatch) -> Vector3:
	if pending != null and _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
		return _get_sabiki_hook_attachment_world_position(pending.hook_index)
	return _get_single_jig_hook_attachment_world()


func _measure_fight_real_delta() -> float:
	if not _fight_session_active:
		_fight_last_real_tick_usec = -1
		return 0.0
	var now_usec := Time.get_ticks_usec()
	if _fight_last_real_tick_usec < 0:
		_fight_last_real_tick_usec = now_usec
		return 0.0
	var elapsed_usec := maxi(0, now_usec - _fight_last_real_tick_usec)
	_fight_last_real_tick_usec = now_usec
	return float(elapsed_usec) / 1000000.0


static func calculate_rod_visual_bend_angle_deg(
	tension_n: float,
	reference_load_n: float,
	maximum_bend_deg: float,
	response_exponent: float
) -> float:
	if not is_finite(tension_n) or not is_finite(reference_load_n) or not is_finite(maximum_bend_deg) or not is_finite(response_exponent):
		return 0.0
	var reference := maxf(reference_load_n, 0.001)
	var load_fraction := clampf(maxf(tension_n, 0.0) / reference, 0.0, 1.0)
	return clampf(maximum_bend_deg, 0.0, 60.0) * pow(load_fraction, clampf(response_exponent, 0.05, 3.0))


static func calculate_line_visual_slack_ratio(tension_n: float, reference_load_n: float, response_exponent: float = 0.7) -> float:
	if not is_finite(tension_n) or not is_finite(reference_load_n) or not is_finite(response_exponent):
		return 1.0
	var load_fraction := clampf(maxf(tension_n, 0.0) / maxf(reference_load_n, 0.001), 0.0, 1.0)
	return clampf(1.0 - pow(load_fraction, clampf(response_exponent, 0.05, 3.0)), 0.0, 1.0)


static func calculate_bend_direction_local(line_direction_world: Vector3, rod_mesh_basis: Basis) -> Vector2:
	if not is_finite(line_direction_world.x) or not is_finite(line_direction_world.y) or not is_finite(line_direction_world.z):
		return Vector2.RIGHT
	if absf(rod_mesh_basis.determinant()) < 0.000001:
		return Vector2.RIGHT
	var local_direction := rod_mesh_basis.inverse() * line_direction_world
	local_direction.y = 0.0
	if local_direction.length_squared() < 0.0001:
		return Vector2.RIGHT
	local_direction = local_direction.normalized()
	return Vector2(local_direction.x, local_direction.z)


static func calculate_drag_setting_after_input(
	current_setting: float,
	loosen_pressed: bool,
	tighten_pressed: bool,
	delta_real_seconds: float,
	adjustment_rate_per_second: float
) -> float:
	var safe_current := clampf(current_setting, 0.0, 1.0) if is_finite(current_setting) else 0.3
	if loosen_pressed == tighten_pressed or not is_finite(delta_real_seconds) or delta_real_seconds <= 0.0:
		return safe_current
	var step := maxf(0.0, adjustment_rate_per_second) * delta_real_seconds if is_finite(adjustment_rate_per_second) else 0.0
	return clampf(safe_current + (step if tighten_pressed else -step), 0.0, 1.0)


func _update_fight_controls(delta: float) -> void:
	if not _fight_session_active or delta <= 0.0 or not is_finite(delta):
		return
	if _is_menu_open() or _is_pointer_over_ui() or _has_gui_focus():
		return
	var loosen := InputMap.has_action("boat_fishing_drag_loosen") and Input.is_action_pressed("boat_fishing_drag_loosen")
	var tighten := InputMap.has_action("boat_fishing_drag_tighten") and Input.is_action_pressed("boat_fishing_drag_tighten")
	if loosen == tighten:
		return
	var previous_setting := _fight_drag_setting
	_fight_drag_setting = calculate_drag_setting_after_input(
		_fight_drag_setting,
		loosen,
		tighten,
		delta,
		fight_drag_adjustment_per_second
	)
	if is_equal_approx(previous_setting, _fight_drag_setting):
		return
	_fight_drag_feedback_direction = 1 if tighten else -1
	_fight_drag_feedback_remaining = 1.25
	if not _fight_snapshot.is_empty():
		_fight_snapshot["drag_setting"] = _fight_drag_setting
		_fight_snapshot["drag_threshold_n"] = BOAT_FIGHT_LINE_PROFILE.get_drag_threshold_n(_fight_drag_setting)
	interaction_updated.emit(get_interaction_snapshot())


func _advance_boat_fight(delta: float) -> void:
	if not _fight_session_active or _fight_participant_order.is_empty() or delta <= 0.0 or not is_finite(delta):
		return
	var fish_snapshots: Array[Dictionary] = []
	for catch_id in _fight_participant_order:
		var participant := _fight_participants_by_catch_id.get(catch_id) as BoatFishingFightParticipant
		if participant == null:
			continue
		var hook_position := _fight_hook_position_by_catch_id(catch_id)
		fish_snapshots.append(participant.advance(delta, _get_hull_outward_horizontal(hook_position)))
	if fish_snapshots.is_empty():
		return
	var rod_tip := _get_fight_solver_rod_tip_world()
	var line_direction := _get_main_line_terminal_world() - rod_tip
	if line_direction.length_squared() < 0.000001:
		line_direction = _fight_radial_direction
	if line_direction.length_squared() < 0.000001:
		line_direction = Vector3.FORWARD
	line_direction = line_direction.normalized()
	var safe_minimum_line_m := _get_fight_minimum_line_length_m()
	var line_before := _line_paid_out_length_m
	var fixed_rig_length_m := _get_fixed_rig_line_length_m()
	var solved := _fight_solver.solve_step(
		delta,
		line_before + fixed_rig_length_m,
		safe_minimum_line_m + fixed_rig_length_m,
		maximum_line_length_m + fixed_rig_length_m,
		_manual_reeling,
		_fight_drag_setting,
		fish_snapshots,
		line_direction
	)
	var line_delta_m := float(solved.get("line_delta_m", 0.0))
	# This is the single fight-session write to the authoritative line length.
	_line_paid_out_length_m = clampf(line_before + line_delta_m, safe_minimum_line_m, maximum_line_length_m)
	_apply_fight_terminal_line_position(line_delta_m, safe_minimum_line_m, delta)
	_fight_snapshot = solved.duplicate(true)
	_fight_snapshot["line_length_m"] = _line_paid_out_length_m
	_fight_snapshot["line_minimum_m"] = safe_minimum_line_m
	_fight_snapshot["paid_line_length_m"] = _line_paid_out_length_m
	_fight_snapshot["effective_physical_line_length_m"] = _get_effective_main_line_length_m()
	_fight_snapshot["solver_current_line_length_m"] = line_before + fixed_rig_length_m
	_fight_snapshot["solver_minimum_line_length_m"] = safe_minimum_line_m + fixed_rig_length_m
	_fight_snapshot["solver_maximum_line_length_m"] = maximum_line_length_m + fixed_rig_length_m
	_fight_snapshot["mainline_outward_direction_world"] = line_direction
	_fight_snapshot["drag_setting"] = _fight_drag_setting
	_fight_snapshot["drag_threshold_n"] = BOAT_FIGHT_LINE_PROFILE.get_drag_threshold_n(_fight_drag_setting)
	_fight_visual_elapsed += delta
	var tension_n := maxf(0.0, float(solved.get("tension_n", 0.0)))
	var target_tension_ratio := clampf(float(solved.get("tension_ratio", 0.0)), 0.0, 1.0)
	var rise_tau := 0.10 if target_tension_ratio > _rod_tension else 0.24
	_rod_tension = lerpf(_rod_tension, target_tension_ratio, 1.0 - exp(-delta / rise_tau))
	var base_bend_deg := calculate_rod_visual_bend_angle_deg(
		tension_n,
		rod_visual_reference_load_n,
		rod_visual_max_bend_deg,
		rod_visual_response_exponent
	)
	if base_bend_deg < _fight_previous_base_bend_deg - 2.5:
		_fight_rod_recoil_amplitude_deg = minf(
			rod_visual_release_recoil_deg,
			_fight_previous_base_bend_deg - base_bend_deg
		)
		_fight_rod_recoil_elapsed = 0.0
	_fight_previous_base_bend_deg = base_bend_deg
	_fight_rod_burst_impulse_rad *= exp(-delta / maxf(rod_visual_burst_decay_seconds, 0.01))
	for snapshot in fish_snapshots:
		var catch_id := str(snapshot.get("catch_id", ""))
		var struggle_state := str(snapshot.get("struggle_state", "steady"))
		var previous_state := str(_fight_previous_struggle_state_by_catch_id.get(catch_id, "steady"))
		if struggle_state == "burst" and previous_state != "burst":
			_fight_rod_burst_impulse_rad = maxf(_fight_rod_burst_impulse_rad, deg_to_rad(rod_visual_burst_impulse_deg))
		_fight_previous_struggle_state_by_catch_id[catch_id] = struggle_state
	var burst_strength := 0.0
	var vibration_phase_total := 0.0
	for snapshot in fish_snapshots:
		var catch_id := str(snapshot.get("catch_id", ""))
		var phase := float(posmod(catch_id.hash(), 10000)) / 10000.0 * TAU
		var struggle_state := str(snapshot.get("struggle_state", "steady"))
		if struggle_state == "burst":
			burst_strength += 1.0
		var participant_wave := sin(_fight_visual_elapsed * TAU * rod_visual_vibration_frequency_hz + phase)
		vibration_phase_total += participant_wave * (1.7 if struggle_state == "burst" else 1.0)
	var participant_count := maxi(fish_snapshots.size(), 1)
	var tension_visual_load := clampf(tension_n / maxf(rod_visual_reference_load_n, 0.001), 0.0, 1.0)
	var line_out_fraction := clampf(float(solved.get("line_out_rate_mps", 0.0)) / maxf(BOAT_FIGHT_LINE_PROFILE.max_line_out_speed_mps, 0.1), 0.0, 1.0)
	var movement_level := maxf(tension_visual_load, line_out_fraction * 0.55)
	var deterministic_wave := vibration_phase_total / sqrt(float(participant_count))
	var micro_amplitude := rod_visual_micro_vibration_deg * movement_level
	var burst_vibration := rod_visual_burst_vibration_deg * clampf(burst_strength, 0.0, 1.0)
	_fight_rod_micro_vibration_deg = deterministic_wave * (micro_amplitude + burst_vibration)
	_fight_rod_recoil_elapsed += delta
	var recoil := -_fight_rod_recoil_amplitude_deg * cos(TAU * 2.4 * _fight_rod_recoil_elapsed) * exp(-_fight_rod_recoil_elapsed / maxf(rod_visual_release_decay_seconds, 0.01))
	var raw_visual_target := base_bend_deg + rad_to_deg(_fight_rod_burst_impulse_rad) + _fight_rod_micro_vibration_deg + recoil
	var positive_bend_limit_deg := minf(
		rod_visual_max_bend_deg + rod_visual_burst_impulse_deg + rod_visual_burst_vibration_deg,
		rad_to_deg(0.8)
	)
	_fight_rod_target_bend_deg = clampf(raw_visual_target, -rod_visual_release_recoil_deg, positive_bend_limit_deg)
	var visual_tau := 0.07 if _fight_rod_target_bend_deg > _rod_bend_angle_deg else 0.15
	_rod_bend_angle_deg = lerpf(_rod_bend_angle_deg, _fight_rod_target_bend_deg, 1.0 - exp(-delta / visual_tau))
	_update_rod_bend_direction_from_visual_line()
	_set_rod_bend_angle(deg_to_rad(_rod_bend_angle_deg))
	_apply_fight_participant_motion(delta, fish_snapshots)
	if bool(solved.get("snapped", false)):
		_break_boat_fight(str(solved.get("break_reason", "line_overload")))
		return
	_update_fight_surface_camera_focus(delta)
	var landing_line_buffer_m := (
		SABIKI_FIGHT_LANDING_LINE_BUFFER_M
		if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI
		else 0.025
	)
	if _line_paid_out_length_m <= safe_minimum_line_m + landing_line_buffer_m and (_manual_reeling or line_delta_m < -0.0001):
		_begin_fight_landing()


func _update_fight_surface_camera_focus(delta: float) -> void:
	if _onboard == null or not _fight_session_active:
		return
	var focus_positions: Array[Vector3] = []
	for catch_id in _fight_participant_order:
		var participant := _fight_participants_by_catch_id.get(catch_id) as BoatFishingFightParticipant
		var visual := _fight_fish_visuals_by_catch_id.get(catch_id) as Node3D
		if participant == null or visual == null or not is_instance_valid(visual):
			continue
		var hook_position := _fight_hook_position_by_catch_id(catch_id)
		var surface_y := float(_sample_water(hook_position).get("height", hook_position.y))
		var body_length_m := maxf(0.0, float(participant.get_read_only_snapshot().get("body_length_m", 0.0)))
		# Begin framing as the hooked mouth reaches the surface so the view can
		# follow the breach instead of reacting only after the fish has emerged.
		if hook_position.y < surface_y - maxf(0.06, body_length_m * 0.08):
			continue
		focus_positions.append(visual.global_position)
		focus_positions.append(hook_position)
	_onboard.set_fishing_presentation_tracking(not focus_positions.is_empty())
	if not focus_positions.is_empty():
		_onboard.update_fishing_presentation_focus(focus_positions, delta)


func _fight_hook_position_by_catch_id(catch_id: String) -> Vector3:
	var participant := _fight_participants_by_catch_id.get(catch_id) as BoatFishingFightParticipant
	if participant == null:
		return _bait_world
	return _fight_hook_position_for_index(int(participant.get_read_only_snapshot().get("hook_index", -1)))


func _fight_hook_position_for_index(hook_index: int) -> Vector3:
	if _current_rig.rig_type != BoatFishingRigProfile.RigType.SABIKI:
		return _get_single_jig_hook_attachment_world()
	_update_rig_visual_position()
	return _get_sabiki_hook_attachment_world_position(hook_index)


func _apply_fight_terminal_line_position(line_delta_m: float, minimum_line_m: float, delta: float) -> void:
	var previous := _bait_world
	var rod_tip := _get_fight_solver_rod_tip_world()
	var connection_offset := _get_main_line_terminal_offset_world()
	var current_connection := _get_main_line_terminal_world()
	var direction := current_connection - rod_tip
	if direction.length_squared() < 0.000001:
		direction = _fight_radial_direction
	if direction.length_squared() < 0.000001:
		direction = Vector3.DOWN
	direction = direction.normalized()
	var target_connection: Vector3
	var effective_line_length_m := _get_effective_main_line_length_m()
	if _line_paid_out_length_m <= minimum_line_m + 0.01:
		target_connection = _get_fight_safe_hull_edge_target_world()
	else:
		target_connection = rod_tip + direction * effective_line_length_m
	target_connection = _constrain_fight_connection_to_terminal_water_column(target_connection, rod_tip, effective_line_length_m, connection_offset)
	_bait_world = target_connection - connection_offset
	_bait_velocity_world = (_bait_world - previous) / maxf(delta, 0.0001)
	if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
		var endpoint_excess := maxf(0.0, rod_tip.distance_to(_bait_world) - effective_line_length_m)
		_last_sabiki_endpoint_excess_before_constraint_m = endpoint_excess
		_maximum_sabiki_active_endpoint_excess_m = maxf(_maximum_sabiki_active_endpoint_excess_m, endpoint_excess)
		_sabiki_reachability_constraint_feasible = endpoint_excess <= 0.0001
	_fight_terminal_motion_this_step = absf(line_delta_m) > 0.0001
	var line_direction := target_connection - rod_tip
	if line_direction.length_squared() > 0.000001:
		_fight_radial_direction = line_direction.normalized()
	_update_rig_visual_position()


func _get_fight_solver_rod_tip_world() -> Vector3:
	if _rod_swing == null:
		return global_position
	# Physics uses the straight rod axis. Shader bend and burst feedback are
	# presentation-only and must not alter line length, payout, or solver input.
	return _rod_swing.to_global(ROD_AXIS_LOCAL * ROD_LENGTH_M)


func _constrain_fight_connection_to_terminal_water_column(
	connection: Vector3,
	rod_tip: Vector3,
	line_length_m: float,
	connection_offset: Vector3
) -> Vector3:
	var terminal := connection - connection_offset
	var surface_y := float(_sample_water(terminal).get("height", terminal.y)) - 0.025
	var bottom := _sample_seabed(terminal)
	var floor_y := float(bottom.get("bottom_world_y", terminal.y - 1000.0)) + SEABED_CLEARANCE_M if bool(bottom.get("valid", false)) else terminal.y - 1000.0
	var clamped_y := clampf(terminal.y, floor_y, surface_y)
	if not is_equal_approx(clamped_y, terminal.y):
		var connection_y := clamped_y + connection_offset.y
		var vertical_delta := clampf(connection_y - rod_tip.y, -line_length_m * 0.999, line_length_m * 0.999)
		var horizontal_length := sqrt(maxf(0.0, line_length_m * line_length_m - vertical_delta * vertical_delta))
		var horizontal := Vector3(connection.x - rod_tip.x, 0.0, connection.z - rod_tip.z)
		if horizontal.length_squared() < 0.000001:
			horizontal = Vector3(_fight_radial_direction.x, 0.0, _fight_radial_direction.z)
		horizontal = horizontal.normalized() if horizontal.length_squared() > 0.000001 else Vector3.FORWARD
		connection = Vector3(rod_tip.x, rod_tip.y + vertical_delta, rod_tip.z) + horizontal * horizontal_length
	return connection


func _apply_fight_participant_motion(delta: float, fish_snapshots: Array[Dictionary]) -> void:
	_update_rig_visual_position()
	for snapshot in fish_snapshots:
		var catch_id := str(snapshot.get("catch_id", ""))
		var hook_index := int(snapshot.get("hook_index", -1))
		var swim_direction: Vector3 = snapshot.get("swim_direction", Vector3.ZERO)
		var speed := maxf(0.0, float(snapshot.get("swim_speed_mps", 0.0)))
		var hook_position: Vector3
		if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
			_advance_sabiki_branch_for_fish(hook_index, swim_direction, speed, delta)
			_update_rig_visual_position()
			hook_position = _get_sabiki_hook_attachment_world_position(hook_index)
		else:
			_advance_single_jig_tackle_for_fish(swim_direction, speed, delta)
			hook_position = _get_single_jig_hook_attachment_world()
		var visual := _fight_fish_visuals_by_catch_id.get(catch_id) as Node3D
		if visual == null or not is_instance_valid(visual):
			continue
		var profile := _fish_manager.get_species_profile(str(snapshot.get("species_id", ""))) if _fish_manager != null else null
		var visual_elapsed := float(_fight_fish_visual_elapsed_by_catch_id.get(catch_id, 0.0)) + delta
		_fight_fish_visual_elapsed_by_catch_id[catch_id] = visual_elapsed
		var frequency := profile.tail_frequency_hz if profile != null else 2.0
		var struggle_state := str(snapshot.get("struggle_state", "steady"))
		var intensity := 0.12 if struggle_state == "steady" else 0.34 if struggle_state == "burst" else 0.20
		var phase := visual_elapsed * TAU * frequency
		var target_heading := swim_direction if swim_direction.length_squared() > 0.0001 else -_get_hull_outward_horizontal(hook_position)
		var previous_heading: Vector3 = _fight_fish_heading_by_catch_id.get(catch_id, -_get_hull_outward_horizontal(hook_position))
		var turn_rate := profile.boat_fishing_turn_rate_deg_s if profile != null else 300.0
		var heading := _advance_fight_fish_heading(catch_id, previous_heading, target_heading, hook_position, float(snapshot.get("body_length_m", 0.3)), profile, turn_rate, delta)
		_set_fish_visual_pose_at_hook(
			visual,
			str(snapshot.get("species_id", "")),
			float(snapshot.get("body_length_m", 0.3)),
			hook_position,
			heading,
			sin(phase) * intensity
		)
		var mouth_world := visual.global_transform * (profile.boat_fishing_mouth_anchor_local if profile != null else Vector3.ZERO)
		var error_m := mouth_world.distance_to(hook_position)
		_fight_max_mouth_hook_error_m = maxf(_fight_max_mouth_hook_error_m, error_m)


func _advance_single_jig_tackle_for_fish(direction: Vector3, speed: float, delta: float) -> void:
	if speed <= 0.0 or delta <= 0.0:
		return
	var rod_tip := _get_fight_solver_rod_tip_world()
	var previous_connection := _get_main_line_terminal_world()
	var safe_direction := _remove_inward_hull_swim(direction, previous_connection)
	var connection := advance_tethered_hook_world(
		rod_tip,
		previous_connection,
		safe_direction,
		speed,
		delta,
		_line_paid_out_length_m
	)
	connection = _constrain_fight_connection_to_terminal_water_column(
		connection,
		rod_tip,
		_line_paid_out_length_m,
		_get_main_line_terminal_offset_world()
	)
	connection = _constrain_fight_connection_to_line_and_hull(
		connection,
		rod_tip,
		_line_paid_out_length_m,
		_get_main_line_terminal_offset_world()
	)
	_bait_world = connection - _get_main_line_terminal_offset_world()
	_bait_velocity_world = (_bait_world - (previous_connection - _get_main_line_terminal_offset_world())) / maxf(delta, 0.0001)
	var final_radial := connection - rod_tip
	if final_radial.length_squared() > 0.000001:
		_fight_radial_direction = final_radial.normalized()
	_fight_terminal_motion_this_step = false


func _constrain_fight_connection_to_line_and_hull(
	connection: Vector3,
	rod_tip: Vector3,
	line_length_m: float,
	connection_offset: Vector3
) -> Vector3:
	var radius := maxf(0.0, line_length_m)
	var radial := connection - rod_tip
	if radial.length_squared() < 0.000001:
		radial = _fight_radial_direction if _fight_radial_direction.length_squared() > 0.000001 else Vector3.FORWARD
	var constrained := rod_tip + radial.normalized() * radius
	if _get_hull_ellipse_clearance_m(constrained - connection_offset) >= 0.0:
		return constrained
	var safe_edge := _get_fight_safe_hull_edge_target_world() + connection_offset
	var safe_radial := safe_edge - rod_tip
	if safe_radial.length_squared() < 0.000001:
		safe_radial = _fight_radial_direction
	constrained = rod_tip + safe_radial.normalized() * radius
	return constrained


func _advance_sabiki_branch_for_fish(hook_index: int, direction: Vector3, speed: float, delta: float) -> void:
	if hook_index < 0 or hook_index >= _sabiki_hook_nodes.size() or speed <= 0.0 or delta <= 0.0:
		return
	var root_basis := _sabiki_rig_root.global_basis.orthonormalized()
	var local_direction: Vector3 = _fight_sabiki_branch_directions_local.get(hook_index, Vector3.LEFT)
	var world_branch_direction := (root_basis * local_direction).normalized()
	var safe_swim_direction := _remove_inward_hull_swim(direction, _get_sabiki_hook_attachment_world_position(hook_index))
	var next_world_direction := advance_bounded_branch_direction_world(
		world_branch_direction,
		safe_swim_direction,
		speed,
		delta,
		_current_rig.branch_length_m,
		(root_basis * Vector3.LEFT).normalized(),
		deg_to_rad(52.0)
	)
	_fight_sabiki_branch_directions_local[hook_index] = (root_basis.inverse() * next_world_direction).normalized()


func _remove_inward_hull_swim(direction: Vector3, position: Vector3) -> Vector3:
	var outward := _get_hull_outward_horizontal(position)
	return remove_inward_swim_direction(direction, outward)


static func remove_inward_swim_direction(direction: Vector3, hull_outward_horizontal: Vector3) -> Vector3:
	if not direction.is_finite() or not hull_outward_horizontal.is_finite() or direction.length_squared() < 0.000001:
		return Vector3.ZERO
	var safe_direction := direction.normalized()
	var outward := Vector3(hull_outward_horizontal.x, 0.0, hull_outward_horizontal.z)
	if outward.length_squared() > 0.000001:
		outward = outward.normalized()
		if safe_direction.dot(outward) < 0.0:
			safe_direction -= outward * safe_direction.dot(outward)
	return safe_direction.normalized() if safe_direction.length_squared() > 0.000001 else Vector3.ZERO


func _advance_fight_fish_heading(
	catch_id: String,
	current_heading: Vector3,
	target_heading: Vector3,
	hook_world: Vector3,
	body_length_m: float,
	profile: FishSpeciesProfile,
	turn_rate_deg_s: float,
	delta: float
) -> Vector3:
	var outward := _get_hull_outward_horizontal(hook_world)
	var target := target_heading.normalized() if target_heading.is_finite() and target_heading.length_squared() > 0.0001 else -outward
	if not _fight_fish_pose_clears_hull(hook_world, target, body_length_m, profile):
		target = -outward
	var current := current_heading.normalized() if current_heading.is_finite() and current_heading.length_squared() > 0.0001 else target
	var step_angle := deg_to_rad(maxf(turn_rate_deg_s, 30.0)) * maxf(delta, 0.0)
	for _attempt in range(7):
		var candidate := advance_heading_toward(current, target, step_angle)
		if _fight_fish_pose_clears_hull(hook_world, candidate, body_length_m, profile):
			_fight_fish_heading_by_catch_id[catch_id] = candidate
			return candidate
		step_angle *= 0.5
	_fight_fish_heading_by_catch_id[catch_id] = current
	return current


func _fight_fish_pose_clears_hull(hook_world: Vector3, heading: Vector3, body_length_m: float, profile: FishSpeciesProfile) -> bool:
	if profile == null or _boat_controller == null or not _boat_controller.has_method("get_vessel_length_m") or not _boat_controller.has_method("get_vessel_beam_m"):
		return true
	var safe_length := maxf(0.05, body_length_m)
	var basis := _boat_fish_basis_for_heading(heading, profile)
	var scale_factor := maxf(0.05, safe_length / 1.2)
	var scaled_basis := basis.scaled(Vector3.ONE * scale_factor)
	var origin := mouth_anchored_fish_origin(hook_world, scaled_basis, profile.boat_fishing_mouth_anchor_local)
	var forward_local := Vector3.LEFT if profile.model_forward_axis == 1 else Vector3.RIGHT
	var tail_direction := -(basis * forward_local).normalized()
	var radius := safe_length * 0.08
	for sample_index in range(6):
		var fraction := float(sample_index) / 5.0
		var sample_position := origin.lerp(origin + tail_direction * safe_length * 0.92, fraction)
		if _get_hull_ellipse_clearance_m(sample_position) < radius:
			return false
	return true


static func advance_heading_toward(current_heading: Vector3, target_heading: Vector3, maximum_turn_radians: float) -> Vector3:
	if not current_heading.is_finite() or not target_heading.is_finite() or current_heading.length_squared() < 0.000001 or target_heading.length_squared() < 0.000001:
		return target_heading.normalized() if target_heading.is_finite() and target_heading.length_squared() > 0.000001 else Vector3.FORWARD
	var current := current_heading.normalized()
	var target := target_heading.normalized()
	var angle := current.angle_to(target)
	if angle <= maxf(0.0, maximum_turn_radians) or angle <= 0.0001:
		return target
	var axis := current.cross(target)
	if axis.length_squared() < 0.000001:
		axis = current.cross(Vector3.UP)
		if axis.length_squared() < 0.000001:
			axis = current.cross(Vector3.RIGHT)
	return current.rotated(axis.normalized(), minf(angle, maxf(0.0, maximum_turn_radians))).normalized()


func _get_hull_outward_horizontal(position: Vector3) -> Vector3:
	if _boat_controller == null or not _boat_controller.has_method("get_vessel_length_m") or not _boat_controller.has_method("get_vessel_beam_m"):
		var fallback := position - (_boat_controller.global_position if _boat_controller != null else Vector3.ZERO)
		fallback.y = 0.0
		if fallback.length_squared() < 0.0001:
			fallback = _fight_radial_direction
		fallback.y = 0.0
		return fallback.normalized() if fallback.length_squared() > 0.0001 else Vector3.FORWARD
	var local := _boat_controller.to_local(position)
	var half_beam := maxf(0.5, float(_boat_controller.call("get_vessel_beam_m")) * 0.5 + FIGHT_HULL_SAFETY_MARGIN_M)
	var half_length := maxf(1.0, float(_boat_controller.call("get_vessel_length_m")) * 0.5 + FIGHT_HULL_SAFETY_MARGIN_M)
	var local_outward := Vector3(local.x / (half_beam * half_beam), 0.0, local.z / (half_length * half_length))
	var outward := _boat_controller.global_basis * local_outward
	outward.y = 0.0
	if outward.length_squared() < 0.0001:
		outward = position - _boat_controller.global_position
		outward.y = 0.0
	return outward.normalized() if outward.length_squared() > 0.0001 else Vector3.FORWARD


func _project_fight_position_outside_hull(position: Vector3, extra_margin_m: float = 0.0) -> Vector3:
	if _boat_controller == null or not _boat_controller.has_method("get_vessel_length_m") or not _boat_controller.has_method("get_vessel_beam_m"):
		return position
	var local := _boat_controller.to_local(position)
	var half_beam := maxf(0.5, float(_boat_controller.call("get_vessel_beam_m")) * 0.5 + FIGHT_HULL_SAFETY_MARGIN_M + extra_margin_m)
	var half_length := maxf(1.0, float(_boat_controller.call("get_vessel_length_m")) * 0.5 + FIGHT_HULL_SAFETY_MARGIN_M + extra_margin_m)
	var ellipse := local.x * local.x / (half_beam * half_beam) + local.z * local.z / (half_length * half_length)
	if ellipse >= 1.0:
		return position
	if ellipse < 0.000001:
		var outward := _boat_controller.global_basis.inverse() * _get_hull_outward_horizontal(position)
		local.x = outward.x
		local.z = outward.z
		ellipse = local.x * local.x / (half_beam * half_beam) + local.z * local.z / (half_length * half_length)
		if ellipse < 0.000001:
			local.x = 1.0
			ellipse = 1.0 / (half_beam * half_beam)
	var scale := 1.001 / sqrt(ellipse)
	local.x *= scale
	local.z *= scale
	return _boat_controller.to_global(local)


func _get_fight_minimum_line_length_m() -> float:
	var minimum_endpoint_distance := float(_get_fight_safe_hull_edge_data().get("distance_m", MINIMUM_MANUAL_RETRIEVAL_LINE_M))
	return maxf(MINIMUM_MANUAL_RETRIEVAL_LINE_M, minimum_endpoint_distance - _get_fixed_rig_line_length_m())


func _get_fight_safe_hull_edge_target_world() -> Vector3:
	var edge_data := _get_fight_safe_hull_edge_data()
	return edge_data.get("position", _bait_world)


func _get_fight_safe_hull_edge_data() -> Dictionary:
	var tip := _get_fight_solver_rod_tip_world()
	if _boat_controller == null or not _boat_controller.has_method("get_vessel_length_m") or not _boat_controller.has_method("get_vessel_beam_m"):
		return {"position": _get_main_line_terminal_world(), "distance_m": MINIMUM_MANUAL_RETRIEVAL_LINE_M}
	var local_tip := _boat_controller.to_local(tip)
	var local_connection := _boat_controller.to_local(_get_main_line_terminal_world())
	var half_beam := maxf(0.5, float(_boat_controller.call("get_vessel_beam_m")) * 0.5 + FIGHT_HULL_SAFETY_MARGIN_M)
	var half_length := maxf(1.0, float(_boat_controller.call("get_vessel_length_m")) * 0.5 + FIGHT_HULL_SAFETY_MARGIN_M)
	var start_value := local_tip.x * local_tip.x / (half_beam * half_beam) + local_tip.z * local_tip.z / (half_length * half_length)
	if start_value >= 1.0:
		# The handheld rod tip can extend beyond the conservative hull ellipse.
		# In that case use the nearest point on the ellipse plus a small water-side
		# margin, rather than pretending the fish is already at the current bait.
		var radial := Vector2(local_tip.x, local_tip.z)
		if radial.length_squared() < 0.000001:
			radial = Vector2(1.0, 0.0)
		var boundary_scale := 1.0 / sqrt(maxf(start_value, 0.000001))
		var boundary := radial * boundary_scale
		var outward := radial.normalized()
		var edge_local := Vector3(boundary.x + outward.x * 0.24, local_tip.y, boundary.y + outward.y * 0.24)
		var edge := _boat_controller.to_global(edge_local)
		var surface_y := float(_sample_water(edge).get("height", edge.y))
		var target := Vector3(edge.x, surface_y - 0.08, edge.z)
		return {"position": target, "distance_m": tip.distance_to(target)}
	var delta := Vector2(local_connection.x - local_tip.x, local_connection.z - local_tip.z)
	if delta.length_squared() < 0.000001:
		var fallback := _boat_controller.global_basis.inverse() * _get_hull_outward_horizontal(_bait_world)
		delta = Vector2(fallback.x, fallback.z)
	if delta.length_squared() < 0.000001:
		delta = Vector2(1.0, 0.0)
	delta = delta.normalized()
	var p := Vector2(local_tip.x, local_tip.z)
	var a := delta.x * delta.x / (half_beam * half_beam) + delta.y * delta.y / (half_length * half_length)
	var b := 2.0 * (p.x * delta.x / (half_beam * half_beam) + p.y * delta.y / (half_length * half_length))
	var c := start_value - 1.0
	var discriminant := maxf(0.0, b * b - 4.0 * a * c)
	var exit_distance := (-b + sqrt(discriminant)) / maxf(2.0 * a, 0.000001)
	var edge_local := Vector3(local_tip.x + delta.x * (exit_distance + 0.24), local_tip.y, local_tip.z + delta.y * (exit_distance + 0.24))
	var edge := _boat_controller.to_global(edge_local)
	var surface_y := float(_sample_water(edge).get("height", edge.y))
	var target := Vector3(edge.x, surface_y - 0.08, edge.z)
	return {"position": target, "distance_m": tip.distance_to(target)}


func _begin_fight_landing() -> void:
	if not _fight_session_active or _encounter == null or _state == CastState.LANDING:
		return
	_clear_manual_line_controls()
	if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
		_cancel_sabiki_approach_reservations()
		var pending := _encounter.begin_sabiki_batch_retrieval()
		if pending == null:
			_handle_fight_settlement_failure("sabiki_batch_start_failed")
			return
		_sabiki_batch_retrieval_active = true
		_sabiki_batch_catch_count = get_sabiki_hooked_count()
		_active_catch_id = pending.catch_id
		_active_catch_species_id = pending.species_id
		_bite_debug_spawned = pending.debug_spawned
	else:
		var pending := _encounter.pending_catch
		if pending == null or pending.fishing_method != "boat_fishing":
			_handle_fight_settlement_failure("single_catch_missing_at_landing")
			return
		_active_catch_id = pending.catch_id
		_active_catch_species_id = pending.species_id
		_bite_debug_spawned = pending.debug_spawned
	if not _encounter.begin_retrieval():
		_handle_fight_settlement_failure("retrieval_transition_rejected")
		return
	set_automatic_control_owned(true)
	if _onboard != null:
		_onboard.set_movement_locked(true)
	_fight_landing_elapsed = 0.0
	_fight_landing_surface_crossed.clear()
	_fight_landing_start_bait_world = _bait_world
	_fight_landing_start_paid_line_m = maxf(0.0, _line_paid_out_length_m)
	# Fight-view alignment cancels the old waiting-aim pose. Start the automatic
	# landing lift from that same neutral pose so switching to presentation mode
	# does not reveal a stale rod angle for one frame.
	_fight_landing_start_rod_rotation = Vector3.ZERO
	if _rod_swing != null:
		_rod_swing.rotation = _fight_landing_start_rod_rotation
	_fight_landing_target_rod_rotation = Vector3(
		maxf(_fight_landing_start_rod_rotation.x, deg_to_rad(FIGHT_LANDING_ROD_LIFT_DEG)),
		_fight_landing_start_rod_rotation.y,
		0.0
	)
	var display_target := _calculate_fight_landing_display_target()
	_fight_landing_target_bait_world = display_target.get("bait_world", _bait_world)
	_fight_landing_target_paid_line_m = float(display_target.get("paid_line_m", 0.0))
	_fight_landing_target_paid_line_m = minf(_fight_landing_start_paid_line_m, _fight_landing_target_paid_line_m)
	_fight_landing_reel_duration_seconds = maxf(
		FIGHT_LANDING_MIN_REEL_DURATION_SECONDS,
		(_fight_landing_start_paid_line_m - _fight_landing_target_paid_line_m) / maxf(manual_reel_speed_mps, 0.1)
	)
	for catch_id in _fight_participant_order:
		_fight_landing_surface_crossed[catch_id] = false
	_fight_session_active = false
	_begin_fight_rod_release()
	_set_boat_fishing_audio_loop("line_out", false)
	_set_boat_fishing_audio_loop("reel_in", false)
	_set_boat_fishing_audio_loop("drag", false)
	_set_state(CastState.LANDING)


func _calculate_fight_landing_display_target() -> Dictionary:
	if _rod_swing == null:
		return {"bait_world": _bait_world, "paid_line_m": _line_paid_out_length_m}
	var previous_rod_rotation := _rod_swing.rotation
	var previous_bend_deg := _rod_bend_angle_deg
	_rod_swing.rotation = _fight_landing_target_rod_rotation
	_rod_bend_angle_deg = 0.0
	var rod_tip := _get_rod_tip_world()
	var outward := _get_hull_outward_horizontal(rod_tip)
	if outward.length_squared() < 0.0001:
		outward = Vector3.FORWARD
	var presentation_offset_m := minf(
		FIGHT_LANDING_RIG_OUTWARD_OFFSET_M,
		maxf(0.01, _fight_landing_start_paid_line_m * 0.5)
	)
	var rig_up := _get_sabiki_natural_up_direction_world()
	var target_bait: Vector3
	if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
		target_bait = rod_tip + outward * presentation_offset_m - rig_up * _current_rig.get_line_attachment_height_m()
	else:
		var line_eye_target := rod_tip + outward * presentation_offset_m
		target_bait = line_eye_target - _get_main_line_terminal_offset_world()

	var maximum_body_length_m := 0.0
	for catch_id in _fight_participant_order:
		var participant := _fight_participants_by_catch_id.get(catch_id) as BoatFishingFightParticipant
		if participant != null:
			maximum_body_length_m = maxf(maximum_body_length_m, float(participant.get_read_only_snapshot().get("body_length_m", 0.0)))
	target_bait = _project_fight_position_outside_hull(target_bait, maximum_body_length_m * 0.08)

	var required_raise_m := 0.0
	for catch_id in _fight_participant_order:
		var participant := _fight_participants_by_catch_id.get(catch_id) as BoatFishingFightParticipant
		if participant == null:
			continue
		var snapshot := participant.get_read_only_snapshot()
		var body_length_m := maxf(0.0, float(snapshot.get("body_length_m", 0.0)))
		var hook_position := target_bait
		if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
			var hook_index := int(snapshot.get("hook_index", -1))
			if hook_index < 0 or hook_index >= _current_rig.hook_count:
				continue
			var distance_from_sinker_m := _current_rig.bottom_leader_length_m + float(_current_rig.hook_count - hook_index - 1) * _current_rig.hook_spacing_m
			hook_position += rig_up * distance_from_sinker_m
		else:
			hook_position += _lure_visual_basis_world * Vector3(0.0, SPOON_HOOK_TIP_Y_M, 0.0)
		var surface_y := float(_sample_water(hook_position).get("height", hook_position.y))
		var clearance_m := maxf(FIGHT_LANDING_FISH_CLEARANCE_M, body_length_m * FIGHT_LANDING_FISH_CLEARANCE_RATIO)
		required_raise_m = maxf(required_raise_m, surface_y + clearance_m - hook_position.y)
	target_bait.y += maxf(0.0, required_raise_m)

	var terminal_world := target_bait + _get_main_line_terminal_offset_world()
	var paid_line_m := maxf(0.0, rod_tip.distance_to(terminal_world) - _get_fixed_rig_line_length_m())
	_rod_swing.rotation = previous_rod_rotation
	_rod_bend_angle_deg = previous_bend_deg
	return {"bait_world": target_bait, "paid_line_m": paid_line_m}


func _advance_fight_landing(delta: float) -> void:
	_fight_landing_elapsed += maxf(0.0, delta)
	var progress := clampf(_fight_landing_elapsed / maxf(_fight_landing_reel_duration_seconds, 0.01), 0.0, 1.0)
	var eased_progress := _smoothstep01(progress)
	if _rod_swing != null:
		_rod_swing.rotation = _fight_landing_start_rod_rotation.lerp(_fight_landing_target_rod_rotation, eased_progress)
	_advance_fight_rod_release(delta)
	var previous_bait := _bait_world
	_bait_world = _fight_landing_start_bait_world.lerp(_fight_landing_target_bait_world, eased_progress)
	_line_paid_out_length_m = lerpf(_fight_landing_start_paid_line_m, _fight_landing_target_paid_line_m, eased_progress)
	_bait_velocity_world = (_bait_world - previous_bait) / maxf(delta, 0.0001)
	_update_rig_visual_position()
	_fight_snapshot["line_length_m"] = _line_paid_out_length_m
	_fight_snapshot["line_rate_mps"] = -(_fight_landing_start_paid_line_m - _fight_landing_target_paid_line_m) / maxf(_fight_landing_reel_duration_seconds, 0.01)
	_fight_snapshot["reel_in_rate_mps"] = -float(_fight_snapshot["line_rate_mps"])
	_fight_snapshot["line_out_rate_mps"] = 0.0
	_fight_snapshot["drag_paying_out"] = false
	var ordered_ids := _fight_participant_order.duplicate()
	ordered_ids.sort_custom(func(a: String, b: String) -> bool:
		var participant_a := _fight_participants_by_catch_id.get(a) as BoatFishingFightParticipant
		var participant_b := _fight_participants_by_catch_id.get(b) as BoatFishingFightParticipant
		var hook_a := int(participant_a.get_read_only_snapshot().get("hook_index", 0)) if participant_a != null else 0
		var hook_b := int(participant_b.get_read_only_snapshot().get("hook_index", 0)) if participant_b != null else 0
		return hook_a < hook_b
	)
	var hook_positions := get_hook_attachment_world_positions()
	var presentation_focus_points: Array[Vector3] = []
	for catch_id_variant in ordered_ids:
		var catch_id := str(catch_id_variant)
		var participant := _fight_participants_by_catch_id.get(catch_id) as BoatFishingFightParticipant
		if participant == null:
			continue
		var fish_snapshot := participant.get_read_only_snapshot()
		var hook_index := int(fish_snapshot.get("hook_index", -1))
		if hook_index < 0 or hook_index >= hook_positions.size():
			continue
		var hook_position: Vector3 = hook_positions[hook_index]
		var visual := _fight_fish_visuals_by_catch_id.get(catch_id) as Node3D
		if visual != null and is_instance_valid(visual):
			var species_id := str(fish_snapshot.get("species_id", ""))
			var body_length_m := float(fish_snapshot.get("body_length_m", 0.3))
			var profile := _fish_manager.get_species_profile(species_id) if _fish_manager != null else null
			var target_heading := -_get_hull_outward_horizontal(hook_position)
			var previous_heading: Vector3 = _fight_fish_heading_by_catch_id.get(catch_id, target_heading)
			var turn_rate := profile.boat_fishing_turn_rate_deg_s if profile != null else 300.0
			var landing_heading := _advance_fight_fish_heading(catch_id, previous_heading, target_heading, hook_position, body_length_m, profile, turn_rate, delta)
			var tail_frequency_hz := profile.tail_frequency_hz if profile != null else 2.0
			var thrash_phase := _fight_landing_elapsed * TAU * clampf(tail_frequency_hz, 1.5, 4.0) + float(hook_index) * 0.91
			landing_heading = (landing_heading + Vector3.UP * sin(thrash_phase) * FIGHT_LANDING_FISH_THRASH_PITCH).normalized()
			_set_fish_visual_pose_at_hook(
				visual,
				species_id,
				body_length_m,
				hook_position,
				landing_heading,
				sin(thrash_phase * 1.37) * FIGHT_LANDING_FISH_THRASH_ROLL_RAD
			)
			presentation_focus_points.append(visual.global_position)
		else:
			presentation_focus_points.append(hook_position)
		var surface_y := float(_sample_water(hook_position).get("height", hook_position.y))
		if hook_position.y >= surface_y and not bool(_fight_landing_surface_crossed.get(catch_id, false)):
			_fight_landing_surface_crossed[catch_id] = true
			if Time.get_ticks_msec() * 0.001 - _last_sabiki_splash_time >= 0.32:
				_last_sabiki_splash_time = Time.get_ticks_msec() * 0.001
				_show_splash_visual(hook_position)
				_play_boat_fishing_one_shot("splash")
	if _onboard != null:
		_onboard.update_fishing_presentation_focus(presentation_focus_points, delta)
	if progress >= 1.0:
		_complete_fight_landing()


func _complete_fight_landing() -> void:
	if _encounter == null or _state != CastState.LANDING:
		return
	var was_batch := _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI
	var result := _encounter.complete_retrieval(_active_catch_id)
	if not bool(result.get("accepted", false)):
		_handle_fight_settlement_failure(str(result.get("reason", "settlement_rejected")))
		return
	if not was_batch:
		_reset_boat_fight_session(true)


func _handle_fight_settlement_failure(reason: String) -> void:
	_reset_boat_fight_session(true)
	set_automatic_control_owned(false)
	if _encounter != null:
		if _encounter.pending_catch != null and _encounter.pending_catch.fishing_method == "boat_fishing":
			_encounter.cancel_boat_fishing_catch(reason)
		elif not _encounter.get_sabiki_hook_catches().is_empty():
			_encounter.cancel_sabiki_catches(reason)
	if _bite_fish_visual != null and is_instance_valid(_bite_fish_visual):
		_bite_fish_visual.queue_free()
	_bite_fish_visual = null
	_clear_sabiki_hook_visuals()
	_reset_sabiki_hook_states()
	_active_catch_id = ""
	_active_catch_species_id = ""
	_catch_result_received = false
	_sabiki_batch_retrieval_active = false
	_sabiki_batch_catch_count = 0
	_clear_boat_fishing_audio_loops()
	_rod_tension = 0.0
	_rod_bend_angle_deg = 0.0
	_set_rod_bend_angle(0.0)
	if _activity_active:
		_set_state(CastState.WAITING if _bait_has_landed else CastState.READY)


func _break_boat_fight(reason: String) -> void:
	if not _fight_session_active:
		return
	_begin_fight_rod_release()
	_fight_session_active = false
	_clear_manual_line_controls()
	set_automatic_control_owned(false)
	_set_boat_fishing_audio_loop("line_out", false)
	_set_boat_fishing_audio_loop("reel_in", false)
	_set_boat_fishing_audio_loop("drag", false)
	var catch_id := _active_catch_id
	_active_catch_id = ""
	_fight_participants_by_catch_id.clear()
	_fight_participant_order.clear()
	_fight_fish_visuals_by_catch_id.clear()
	_fight_fish_heading_by_catch_id.clear()
	_fight_landing_surface_crossed.clear()
	_fight_solver.reset_session()
	_fight_drag_setting = clampf(BOAT_FIGHT_LINE_PROFILE.default_drag_setting, 0.0, 1.0)
	_fight_snapshot = {}
	_active_fight_session_id = 0
	_fight_last_real_tick_usec = -1
	if _encounter != null:
		if _encounter.pending_catch != null and _encounter.pending_catch.fishing_method == "boat_fishing":
			_encounter.cancel_boat_fishing_catch("boat_fishing_line_snapped")
		elif not _encounter.get_sabiki_hook_catches().is_empty():
			_encounter.cancel_sabiki_catches("boat_fishing_line_snapped")
	if _bite_fish_visual != null and is_instance_valid(_bite_fish_visual):
		_bite_fish_visual.queue_free()
	_bite_fish_visual = null
	_clear_sabiki_hook_visuals()
	_reset_sabiki_hook_states()
	_sabiki_batch_retrieval_active = false
	_sabiki_batch_catch_count = 0
	_catch_result_received = false
	_rod_tension = 0.0
	_rod_bend_angle_deg = 0.0
	_set_rod_bend_angle(0.0)
	_bait_has_landed = false
	_bait_instance.visible = false
	_line_instance.visible = false
	if _sabiki_rig_root != null:
		_sabiki_rig_root.visible = false
	_line_paid_out_length_m = 0.0
	_line_broken_elapsed = 0.0
	feedback_requested.emit("hud.boat_fishing.line_snapped")
	_set_state(CastState.LINE_BROKEN)
	interaction_updated.emit(get_interaction_snapshot())


func _advance_line_broken(delta: float) -> void:
	_line_broken_elapsed += maxf(0.0, delta)
	_advance_fight_rod_release(delta)
	if _line_broken_elapsed >= FIGHT_LINE_BROKEN_DURATION_SECONDS:
		clear_cast()


func _begin_fight_rod_release() -> void:
	_fight_rod_release_start_deg = _rod_bend_angle_deg
	_fight_rod_release_elapsed = 0.0
	_fight_rod_release_active = absf(_fight_rod_release_start_deg) > 0.05


func _advance_fight_rod_release(delta: float) -> void:
	if not _fight_rod_release_active:
		return
	_fight_rod_release_elapsed += maxf(0.0, delta)
	var damped := exp(-_fight_rod_release_elapsed / 0.24)
	var recoil_deg := -minf(3.5, absf(_fight_rod_release_start_deg) * 0.18) * sin(TAU * 2.8 * _fight_rod_release_elapsed) * damped
	_rod_bend_angle_deg = _fight_rod_release_start_deg * damped + recoil_deg
	_set_rod_bend_angle(deg_to_rad(_rod_bend_angle_deg))
	if _fight_rod_release_elapsed >= 0.9 or absf(_rod_bend_angle_deg) <= 0.03:
		_rod_bend_angle_deg = 0.0
		_fight_rod_release_active = false
		_set_rod_bend_angle(0.0)


func _reset_boat_fight_session(keep_visuals: bool = false) -> void:
	_fight_session_active = false
	_fight_participants_by_catch_id.clear()
	_fight_participant_order.clear()
	_fight_fish_visuals_by_catch_id.clear()
	_fight_fish_visual_elapsed_by_catch_id.clear()
	_fight_fish_heading_by_catch_id.clear()
	_fight_previous_struggle_state_by_catch_id.clear()
	if not keep_visuals:
		_fight_sabiki_branch_directions_local.clear()
	_fight_snapshot = {}
	_fight_landing_elapsed = 0.0
	_fight_landing_surface_crossed.clear()
	_fight_terminal_motion_this_step = false
	_fight_landing_start_bait_world = Vector3.ZERO
	_fight_landing_target_bait_world = Vector3.ZERO
	_fight_landing_start_paid_line_m = 0.0
	_fight_landing_target_paid_line_m = 0.0
	_fight_landing_reel_duration_seconds = FIGHT_LANDING_MIN_REEL_DURATION_SECONDS
	_fight_landing_start_rod_rotation = Vector3.ZERO
	_fight_landing_target_rod_rotation = Vector3.ZERO
	_fight_rod_burst_impulse_rad = 0.0
	_fight_rod_target_bend_deg = 0.0
	_fight_rod_micro_vibration_deg = 0.0
	_fight_rod_recoil_amplitude_deg = 0.0
	_fight_rod_recoil_elapsed = 0.0
	_fight_visual_elapsed = 0.0
	_fight_previous_base_bend_deg = 0.0
	_fight_rod_release_start_deg = 0.0
	_fight_rod_release_elapsed = 0.0
	_fight_rod_release_active = false
	_fight_drag_feedback_remaining = 0.0
	_fight_drag_feedback_direction = 0
	_fight_max_mouth_hook_error_m = 0.0
	_fight_solver.reset_session()
	_fight_drag_setting = clampf(BOAT_FIGHT_LINE_PROFILE.default_drag_setting, 0.0, 1.0)
	_active_fight_session_id = 0
	_fight_last_real_tick_usec = -1


func _advance_catch_presentation(delta: float) -> void:
	_catch_presentation_elapsed += maxf(delta, 0.0)
	_advance_fight_rod_release(delta)
	var presentation_focus_points := _animate_catch_presentation_fish()
	if _onboard != null:
		_onboard.update_fishing_presentation_focus(presentation_focus_points, delta)
	if _catch_result_received and _catch_presentation_elapsed >= FIGHT_PRESENTATION_DURATION_SECONDS:
		clear_cast()


func _animate_catch_presentation_fish() -> Array[Vector3]:
	var presentation_focus_points: Array[Vector3] = []
	if _bite_fish_visual != null and is_instance_valid(_bite_fish_visual):
		var hook_world := _get_single_jig_hook_attachment_world()
		var profile := _fish_manager.get_species_profile(_active_catch_species_id) if _fish_manager != null else null
		var tail_frequency_hz := profile.tail_frequency_hz if profile != null else 2.0
		var phase := _catch_presentation_elapsed * TAU * clampf(tail_frequency_hz, 1.5, 4.0)
		var heading := -_get_hull_outward_horizontal(hook_world)
		heading = (heading + Vector3.UP * sin(phase) * FIGHT_LANDING_FISH_THRASH_PITCH).normalized()
		_set_fish_visual_pose_at_hook(
			_bite_fish_visual,
			_active_catch_species_id,
			_active_catch_body_length_m,
			hook_world,
			heading,
			sin(phase * 1.37) * FIGHT_LANDING_FISH_THRASH_ROLL_RAD
		)
		presentation_focus_points.append(_bite_fish_visual.global_position)
	if _current_rig.rig_type != BoatFishingRigProfile.RigType.SABIKI:
		return presentation_focus_points
	var hook_positions := get_hook_attachment_world_positions()
	for hook_state_variant in _sabiki_hook_states:
		var hook_state: Dictionary = hook_state_variant
		if str(hook_state.get("status", "")) != "hooked":
			continue
		var hook_index := int(hook_state.get("hook_index", -1))
		if hook_index < 0 or hook_index >= hook_positions.size():
			continue
		var visual := hook_state.get("visual") as Node3D
		if visual == null or not is_instance_valid(visual):
			continue
		var species_id := str(hook_state.get("species_id", "herring"))
		var body_length_m := float(hook_state.get("body_length_m", 0.32))
		var profile := _fish_manager.get_species_profile(species_id) if _fish_manager != null else null
		var tail_frequency_hz := profile.tail_frequency_hz if profile != null else 2.0
		var phase := _catch_presentation_elapsed * TAU * clampf(tail_frequency_hz, 1.5, 4.0) + float(hook_index) * 0.91
		var hook_world: Vector3 = hook_positions[hook_index]
		var heading := -_get_hull_outward_horizontal(hook_world)
		heading = (heading + Vector3.UP * sin(phase) * FIGHT_LANDING_FISH_THRASH_PITCH).normalized()
		_set_fish_visual_pose_at_hook(
			visual,
			species_id,
			body_length_m,
			hook_world,
			heading,
			sin(phase * 1.37) * FIGHT_LANDING_FISH_THRASH_ROLL_RAD
		)
		presentation_focus_points.append(visual.global_position)
	return presentation_focus_points


func _on_authority_catch_succeeded(result: FishingCatchResult) -> void:
	if result == null or result.catch_id != _active_catch_id or result.fishing_method != "boat_fishing":
		return
	if _sabiki_batch_retrieval_active or result.rig_id == str(SABIKI_RIG_PROFILE.rig_id):
		return
	_catch_result_received = true
	_catch_presentation_elapsed = 0.0
	_reset_boat_fight_session(true)
	_begin_fight_rod_release()
	_set_boat_fishing_audio_loop("line_out", false)
	_set_boat_fishing_audio_loop("reel_in", false)
	_set_boat_fishing_audio_loop("drag", false)
	report_catch_succeeded(result.catch_id)
	if _bite_fish_visual != null and is_instance_valid(_bite_fish_visual):
		var hook_world := _get_single_jig_hook_attachment_world()
		_set_fish_visual_pose_at_hook(_bite_fish_visual, result.species_id, _active_catch_body_length_m, hook_world, -_get_hull_outward_horizontal(hook_world))
		_show_splash_visual(hook_world)
	_set_state(CastState.CATCH_PRESENTATION)


func _on_authority_catch_cancelled(catch_id: String, reason: String) -> void:
	if catch_id.is_empty() or _catch_result_received:
		return
	if _current_rig != null and _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
		for hook_index in range(_sabiki_hook_states.size()):
			var hook_state: Dictionary = _sabiki_hook_states[hook_index]
			if str(hook_state.get("status", "")) != "approaching" or str(hook_state.get("catch_id", "")) != catch_id:
				continue
			var hook_positions := get_hook_attachment_world_positions()
			var hook_world: Vector3 = hook_positions[hook_index] if hook_index < hook_positions.size() else Vector3.ZERO
			var pending := hook_state.get("pending") as FishingPendingCatch
			var mouth_world: Vector3 = hook_state.get("mouth_world", hook_state.get("start_world", hook_world))
			_record_sabiki_pursuit_result(hook_index, hook_state, pending, hook_world, "failed", reason, "released_by_authority", mouth_world)
			_clear_sabiki_hook_state(hook_index, false)
			interaction_updated.emit(get_interaction_snapshot())
			return
	if catch_id != _active_catch_id:
		return
	if _state == CastState.BITE_APPROACH:
		_record_single_pursuit_result("failed", reason, "released_by_authority")
	if _bite_fish_visual != null and is_instance_valid(_bite_fish_visual):
		_bite_fish_visual.queue_free()
	_bite_fish_visual = null
	_reset_boat_fight_session(true)
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
	if _activity_active and _state in [CastState.BITE_APPROACH, CastState.FIGHTING, CastState.LANDING, CastState.SABIKI_HOOKED_WAITING]:
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
	_catch_presentation_elapsed = 0.0
	_sabiki_batch_retrieval_active = false
	_reset_boat_fight_session(true)
	_begin_fight_rod_release()
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


static func mouth_anchored_fish_origin(hook_world: Vector3, scaled_fish_basis: Basis, mouth_anchor_local: Vector3) -> Vector3:
	return hook_world - scaled_fish_basis * mouth_anchor_local


## Places the pursuing fish within the school's core while keeping most of the
## school-to-hook distance for real, speed-limited swimming.
static func school_pursuit_start_world(school_center: Vector3, hook_world: Vector3, school_core_radius_m: float) -> Vector3:
	if not school_center.is_finite() or not hook_world.is_finite() or not is_finite(school_core_radius_m):
		return school_center
	var to_hook := hook_world - school_center
	var distance := to_hook.length()
	if distance <= 0.001:
		return school_center
	var offset := minf(minf(maxf(0.0, school_core_radius_m) * 0.2, 1.0), distance * 0.2)
	return school_center + to_hook / distance * offset


## Moves the fish mouth toward a moving hook without tweening or exceeding its
## species pursuit speed.
static func advance_fish_pursuit_world(current_mouth_world: Vector3, hook_world: Vector3, speed_mps: float, dt_real: float) -> Vector3:
	if not current_mouth_world.is_finite() or not hook_world.is_finite() or not is_finite(speed_mps) or not is_finite(dt_real):
		return current_mouth_world
	return current_mouth_world.move_toward(hook_world, maxf(0.0, speed_mps) * maxf(0.0, dt_real))


static func turn_pursuit_heading(current_heading: Vector3, target_heading: Vector3, turn_rate_radians_per_second: float, dt_real: float) -> Vector3:
	var current := current_heading.normalized() if current_heading.is_finite() and current_heading.length_squared() > 0.0001 else Vector3.FORWARD
	var target := target_heading.normalized() if target_heading.is_finite() and target_heading.length_squared() > 0.0001 else current
	var blend := clampf(maxf(0.0, turn_rate_radians_per_second) * maxf(0.0, dt_real), 0.0, 1.0)
	var heading := current.slerp(target, blend)
	return heading.normalized() if heading.length_squared() > 0.0001 else target


func _world_game_time_seconds() -> float:
	return maxf(0.0, float(_fish_manager.call("get_world_game_time_seconds"))) if _fish_manager != null and _fish_manager.has_method("get_world_game_time_seconds") else 0.0


func _smoothstep01(value: float) -> float:
	var t := clampf(value, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## Advances a hook on the fixed-length sphere around the straight rod tip.
## The participant's force still controls payout in the solver; this visual
## tangential motion can never write to the authoritative line length.
static func advance_tethered_hook_world(
	rod_tip_world: Vector3,
	current_hook_world: Vector3,
	swim_direction_world: Vector3,
	swim_speed_mps: float,
	dt_real: float,
	line_length_m: float
) -> Vector3:
	if not rod_tip_world.is_finite() or not current_hook_world.is_finite() or not swim_direction_world.is_finite():
		return current_hook_world
	if not is_finite(swim_speed_mps) or not is_finite(dt_real) or not is_finite(line_length_m):
		return current_hook_world
	var radius := maxf(0.0, line_length_m)
	var radial := current_hook_world - rod_tip_world
	if radial.length_squared() < 0.000001 or radius <= 0.0001:
		return rod_tip_world + radial.normalized() * radius if radial.length_squared() > 0.000001 else current_hook_world
	radial = radial.normalized()
	var tangent := swim_direction_world - radial * swim_direction_world.dot(radial)
	if tangent.length_squared() < 0.000001 or swim_speed_mps <= 0.0 or dt_real <= 0.0:
		return rod_tip_world + radial * radius
	var moved := radial * radius + tangent.normalized() * swim_speed_mps * dt_real
	return rod_tip_world + moved.normalized() * radius


## Pivots a Sabiki branch around its mainline root within a fixed angular cone.
static func advance_bounded_branch_direction_world(
	current_direction_world: Vector3,
	swim_direction_world: Vector3,
	swim_speed_mps: float,
	dt_real: float,
	branch_length_m: float,
	rest_direction_world: Vector3,
	maximum_swing_radians: float
) -> Vector3:
	var current := current_direction_world.normalized() if current_direction_world.length_squared() > 0.000001 else rest_direction_world.normalized()
	var rest := rest_direction_world.normalized() if rest_direction_world.length_squared() > 0.000001 else Vector3.LEFT
	if not current.is_finite() or not swim_direction_world.is_finite() or not is_finite(swim_speed_mps) or not is_finite(dt_real):
		return rest
	var tangent := swim_direction_world - current * swim_direction_world.dot(current)
	if tangent.length_squared() < 0.000001 or swim_speed_mps <= 0.0 or dt_real <= 0.0:
		return current
	var length := maxf(0.04, branch_length_m)
	var moved := (current + tangent.normalized() * (swim_speed_mps * dt_real / length)).normalized()
	var angle := acos(clampf(rest.dot(moved), -1.0, 1.0))
	var maximum_angle := clampf(maximum_swing_radians, 0.0, PI)
	if angle > maximum_angle and angle > 0.0001:
		moved = rest.slerp(moved, maximum_angle / angle).normalized()
	return moved


func _update_ready_rod_pose() -> void:
	if _onboard == null or _rod_visual_root == null:
		return
	_update_rod_hand_anchor()
	_rod_swing.rotation = Vector3.ZERO
	_rod_back_angle_deg = 0.0
	_rod_bend_angle_deg = 0.0
	_set_rod_bend_angle(0.0)


func _update_rod_hand_anchor() -> void:
	if _onboard == null or _rod_visual_root == null or not _onboard.is_first_person_active():
		return
	var camera := _onboard.get_activity_camera()
	if camera == null:
		return
	camera.force_update_transform()
	if not _rod_view_camera_pose_captured:
		# Re-enter first person from the established hand pose. RodSwing can then
		# animate around the reel's captured screen anchor.
		if _rod_swing != null:
			_rod_swing.position = Vector3.ZERO
		var player_position := _onboard.get_player_local_position()
		var player_yaw := _onboard.get_player_local_yaw()
		_rod_visual_root.transform = Transform3D(
			Basis.from_euler(Vector3(clampf(_onboard.get_camera_pitch() * 0.18, -0.18, 0.12), player_yaw, 0.0)),
			player_position + Basis(Vector3.UP, player_yaw) * Vector3(0.31, 1.13, -0.02)
		)
		_onboard.force_update_transform()
		_rod_visual_root.force_update_transform()
		camera.force_update_transform()
		var relative_transform := camera.global_transform.affine_inverse() * _rod_visual_root.global_transform
		_rod_view_camera_relative_transform = Transform3D(
			relative_transform.basis.orthonormalized(),
			relative_transform.origin
		)
		_rod_view_camera_pose_captured = true
		if _reel_spool_visual != null and is_instance_valid(_reel_spool_visual):
			_rod_swing.force_update_transform()
			_reel_spool_visual.force_update_transform()
			var current_spool_camera_position := camera.global_transform.affine_inverse() * _reel_spool_visual.global_position
			_rod_reel_camera_depth_m = maxf(-current_spool_camera_position.z, camera.near + 0.05)
			_rod_reel_camera_anchor_captured = true
	_onboard.force_update_transform()
	camera.force_update_transform()
	var target_global_transform := camera.global_transform * _rod_view_camera_relative_transform
	var target_local_transform := _onboard.global_transform.affine_inverse() * target_global_transform
	_rod_visual_root.transform = Transform3D(
		target_local_transform.basis.orthonormalized(),
		target_local_transform.origin
	)
	_apply_rod_reel_screen_anchor(camera)


func _apply_rod_reel_screen_anchor(camera: Camera3D = null) -> void:
	if (
		not _rod_reel_camera_anchor_captured
		or _rod_visual_root == null
		or _rod_swing == null
		or _reel_spool_visual == null
		or not is_instance_valid(_reel_spool_visual)
	):
		return
	var active_camera := camera
	if active_camera == null and _onboard != null:
		active_camera = _onboard.get_activity_camera()
	if active_camera == null:
		return
	var fish_presentation_active := _state in [CastState.LANDING, CastState.CATCH_PRESENTATION]
	if not fish_presentation_active:
		_landing_reel_anchor_released = false
	elif _landing_reel_anchor_released:
		return
	active_camera.force_update_transform()
	_rod_visual_root.force_update_transform()
	_rod_swing.force_update_transform()
	_reel_spool_visual.force_update_transform()
	var viewport_rect := active_camera.get_viewport().get_visible_rect()
	var target_screen_position := viewport_rect.position + viewport_rect.size * HANDHELD_REEL_SCREEN_ANCHOR
	var target_spool_world := active_camera.project_position(target_screen_position, _rod_reel_camera_depth_m)
	if fish_presentation_active and _landing_reel_anchor_conflicts_with_fish(active_camera, target_spool_world):
		# Keep the landing animation's natural rod pivot whenever a fish occupies
		# the reel's screen area. Once released, stay released through presentation
		# so the reel cannot pop back over a thrashing fish mid-shot.
		_landing_reel_anchor_released = true
		_rod_swing.position = Vector3.ZERO
		_rod_swing.force_update_transform()
		return
	var target_spool_in_root := _rod_visual_root.to_local(target_spool_world)
	var spool_in_swing := _rod_swing.to_local(_reel_spool_visual.global_position)
	# Moving the swing pivot around the spool keeps the reel at its exact camera-
	# relative position while the rod, reel mount, and guides rotate as one rig.
	# The rod tip remains the transformed tip of that same animated rig.
	_rod_swing.position = target_spool_in_root - _rod_swing.transform.basis * spool_in_swing
	_rod_swing.force_update_transform()


func _landing_reel_anchor_conflicts_with_fish(camera: Camera3D, reel_world: Vector3) -> bool:
	for catch_id in _fight_participant_order:
		var participant := _fight_participants_by_catch_id.get(catch_id) as BoatFishingFightParticipant
		var visual := _fight_fish_visuals_by_catch_id.get(catch_id) as Node3D
		if participant == null or visual == null or not is_instance_valid(visual):
			continue
		var snapshot := participant.get_read_only_snapshot()
		if _landing_reel_overlaps_fish(camera, reel_world, visual, float(snapshot.get("body_length_m", 0.3))):
			return true
	if _bite_fish_visual != null and is_instance_valid(_bite_fish_visual):
		if _landing_reel_overlaps_fish(camera, reel_world, _bite_fish_visual, _active_catch_body_length_m):
			return true
	for hook_state_variant in _sabiki_hook_states:
		var hook_state: Dictionary = hook_state_variant
		if str(hook_state.get("status", "")) != "hooked":
			continue
		var visual := hook_state.get("visual") as Node3D
		if visual == null or not is_instance_valid(visual):
			continue
		if _landing_reel_overlaps_fish(camera, reel_world, visual, float(hook_state.get("body_length_m", 0.3))):
			return true
	return false


func _landing_reel_overlaps_fish(camera: Camera3D, reel_world: Vector3, fish: Node3D, fish_body_length_m: float) -> bool:
	if not fish.is_visible_in_tree() or camera.is_position_behind(reel_world) or camera.is_position_behind(fish.global_position):
		return false
	var reel_screen := camera.unproject_position(reel_world)
	var fish_screen := camera.unproject_position(fish.global_position)
	var reel_radius_px := _projected_world_radius_pixels(camera, reel_world, HANDHELD_REEL_SCREEN_BOUNDING_RADIUS_M)
	var fish_radius_m := maxf(0.18, maxf(0.0, fish_body_length_m) * 0.60)
	var fish_radius_px := _projected_world_radius_pixels(camera, fish.global_position, fish_radius_m)
	return reel_screen.distance_to(fish_screen) <= reel_radius_px + fish_radius_px + HANDHELD_REEL_SCREEN_ANCHOR_CONFLICT_PADDING_PX


func _projected_world_radius_pixels(camera: Camera3D, world_position: Vector3, radius_m: float) -> float:
	var center := camera.unproject_position(world_position)
	var camera_right := camera.global_basis.x.normalized()
	var camera_up := camera.global_basis.y.normalized()
	var right_edge := camera.unproject_position(world_position + camera_right * radius_m)
	var up_edge := camera.unproject_position(world_position + camera_up * radius_m)
	return maxf(center.distance_to(right_edge), center.distance_to(up_edge))


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


func _set_rod_bend_direction(direction_local: Vector2) -> void:
	if _rod_shader_material == null:
		return
	var safe_direction := direction_local.normalized() if direction_local.length_squared() > 0.0001 else Vector2.RIGHT
	_rod_shader_material.set_shader_parameter("bend_direction_local", Vector3(safe_direction.x, 0.0, safe_direction.y))


func _update_rod_bend_direction_from_visual_line() -> void:
	if _rod_mesh_instance == null or not is_instance_valid(_rod_mesh_instance):
		return
	# The Solver deliberately keeps its straight rod reference. Presentation must
	# use the deformed tip because the rendered mainline also starts there.
	var line_pull_world := _get_main_line_terminal_world() - _get_rod_tip_world()
	if line_pull_world.length_squared() <= 0.000001:
		return
	var mesh_basis := _rod_mesh_instance.global_basis
	if absf(mesh_basis.determinant()) < 0.000001:
		return
	_rod_bend_direction_local = calculate_bend_direction_local(line_pull_world, mesh_basis)
	_set_rod_bend_direction(_rod_bend_direction_local)


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
	_apply_rod_reel_screen_anchor()
	if not _bait_flight_started and _state_elapsed >= CAST_BAIT_RELEASE_OFFSET_SECONDS:
		_start_bait_flight()
	if _bait_flight_started and not _cast_tackle_entry_complete:
		_update_bait_flight(delta)
	_rod_recovery_complete = _state_elapsed >= cast_release_duration + cast_recovery_duration
	var minimum_paid_line_m := 0.0
	if _cast_tackle_entry_complete and _rod_recovery_complete:
		_state_elapsed = 0.0
		_waiting_elapsed = 0.0
		_rod_swing.rotation = Vector3.ZERO
		_rod_back_angle_deg = 0.0
		_rod_bend_angle_deg = 0.0
		_set_rod_bend_angle(0.0)
		_apply_rod_reel_screen_anchor()
		minimum_paid_line_m = 0.55
		var line_connection := _get_main_line_terminal_world()
		_previous_line_connection_world = line_connection
		_has_previous_line_connection = true
		_set_state(CastState.WAITING)
	if _bait_flight_started:
		# The Sabiki's fixed rig length is part of endpoint reach, not reel payout.
		var endpoint_distance := _get_rod_tip_world().distance_to(_get_main_line_terminal_world())
		_line_paid_out_length_m = clampf(
			maxf(0.0, endpoint_distance - _get_fixed_rig_line_length_m()),
			minimum_paid_line_m,
			maximum_line_length_m
		)
		_constrain_sabiki_terminal_to_active_length()


func _start_bait_flight() -> void:
	if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
		_reset_sabiki_hook_states()
	_bait_flight_started = true
	_bait_flight_elapsed = 0.0
	_cast_tackle_entry_complete = false
	_bait_has_landed = false
	_bait_airborne_retrieval = false
	_airborne_retrieval_elapsed = 0.0
	var rod_tip := _get_rod_tip_world()
	if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
		_bait_world = rod_tip - _get_sabiki_natural_up_direction_world() * _current_rig.get_line_attachment_height_m()
	else:
		_bait_world = rod_tip - _lure_visual_basis_world * Vector3.UP * SPOON_LINE_EYE_Y_M
	_cast_start_world = _bait_world
	_bait_instance.visible = true
	_line_instance.visible = true
	_cast_target_drift_velocity_world = _boat_velocity_estimate_world * 0.12
	_bait_velocity_world = _cast_target_drift_velocity_world


func _update_bait_flight(delta: float) -> void:
	if _bait_has_landed:
		_advance_cast_tackle_water_entry(delta)
		return
	if delta <= 0.0:
		return
	var previous_bait_world := _bait_world
	_bait_flight_elapsed += delta
	var progress := clampf(_bait_flight_elapsed / maxf(_bait_flight_duration, 0.01), 0.0, 1.0)
	var target_world := _cast_target_world + _cast_target_drift_velocity_world * minf(_bait_flight_elapsed, 0.45)
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
		_record_boat_fishing_first_entry()
		_splash_elapsed = 0.0
		_splash_instance.position = to_local(_bait_world)
		_splash_instance.scale = Vector3.ONE * 0.28
		_splash_instance.visible = true
		_previous_boat_world = _boat_controller.global_position if _boat_controller != null else Vector3.ZERO
	if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
		_bait_velocity_world = (_bait_world - previous_bait_world) / maxf(delta, 0.0001)


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
		_record_boat_fishing_first_entry()


func _record_boat_fishing_first_entry() -> void:
	if _cast_first_entry_recorded or _encounter == null or _current_rig == null:
		return
	var entry_position := _get_single_jig_hook_attachment_world()
	if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
		var hook_positions := get_hook_attachment_world_positions()
		if not hook_positions.is_empty():
			entry_position = Vector3.ZERO
			for hook_position in hook_positions:
				entry_position += hook_position
			entry_position /= float(hook_positions.size())
	_encounter.begin_boat_fishing_cast_session(entry_position, _current_rig)
	_cast_first_entry_recorded = true


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
	if _bait_airborne_retrieval:
		_airborne_retrieval_elapsed += maxf(delta, 0.0)
	_apply_waiting_rod_pose()
	if (
		_manual_reeling
		and _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI
		and get_sabiki_hooked_count() == 0
	):
		var recovery_margin_m := maxf(terminal_tackle_recovery_margin_m, SABIKI_EMPTY_RETRIEVAL_APPROACH_MARGIN_M)
		var next_paid_line_length_m := maxf(
			MINIMUM_MANUAL_RETRIEVAL_LINE_M,
			_line_paid_out_length_m - manual_reel_speed_mps * maxf(delta, 0.0)
		)
		if next_paid_line_length_m <= recovery_margin_m:
			# Transition before this frame's tackle inertia advances while the last
			# few centimetres are reeled. At low render rates one delta can move the
			# airborne rig much farther than the recovery margin.
			_begin_final_retrieval()
			return
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
	var line_connection := _get_main_line_terminal_world()
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
	line_connection = _get_main_line_terminal_world()
	var line_distance := rod_tip.distance_to(line_connection)
	var effective_line_length_m := _get_effective_main_line_length_m()
	var tension_target := clampf(
		(line_distance - effective_line_length_m + line_tension_slack_m * 0.5) / maxf(line_tension_slack_m, 0.01),
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
	line_connection = _get_main_line_terminal_world()
	line_distance = rod_tip.distance_to(line_connection)
	effective_line_length_m = _get_effective_main_line_length_m()
	var line_excess := line_distance - effective_line_length_m
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
	_constrain_sabiki_terminal_to_active_length()
	line_connection = _get_main_line_terminal_world()
	var recovery_margin_m := terminal_tackle_recovery_margin_m
	if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI and get_sabiki_hooked_count() == 0:
		recovery_margin_m = maxf(recovery_margin_m, SABIKI_EMPTY_RETRIEVAL_APPROACH_MARGIN_M)
	if _manual_reeling and (_line_paid_out_length_m <= recovery_margin_m if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI and get_sabiki_hooked_count() == 0 else line_connection.distance_to(rod_tip) <= recovery_margin_m):
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
	_rod_swing.rotation = Vector3.ZERO
	var bend_target := _rod_tension * rod_bend_at_full_tension_deg
	var delta := maxf(get_process_delta_time(), 0.0)
	_rod_bend_angle_deg = lerpf(_rod_bend_angle_deg, bend_target, 1.0 - exp(-4.5 * delta))
	_set_rod_bend_angle(deg_to_rad(_rod_bend_angle_deg))
	_update_rod_bend_direction_from_visual_line()
	_rod_back_angle_deg = 0.0


func _begin_final_retrieval() -> void:
	if _state != CastState.WAITING:
		return
	if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
		# A player may reel an empty rig in while a fish is still approaching one
		# of its hooks. That pending bite is not a landed fish; release its local
		# Authority reservation and visual before the tackle leaves the water.
		_cancel_sabiki_approach_reservations()
	_manual_reeling = false
	_manual_reeling_from_ui = false
	_manual_reeling_input_held = false
	_manual_line_release_held = false
	_manual_line_releasing = false
	_line_controls_conflicted = false
	_retrieve_start_world = _bait_world
	_retrieve_start_paid_length_m = _line_paid_out_length_m
	_state_elapsed = 0.0
	_set_state(CastState.RETRIEVING)


func _update_retrieve_animation(delta: float) -> void:
	_state_elapsed += delta
	if _bait_airborne_retrieval:
		_airborne_retrieval_elapsed += maxf(delta, 0.0)
	var progress := clampf(_state_elapsed / RETRIEVE_DURATION_SECONDS, 0.0, 1.0)
	var retrieval_target := _get_retrieval_target_bait_world()
	_bait_world = _retrieve_start_world.lerp(retrieval_target, _ease_in_out(progress))
	# The presentation phase consumes the saved reel payout by animation progress;
	# sinker position and visual path never feed back into the physical line value.
	_line_paid_out_length_m = lerpf(_retrieve_start_paid_length_m, 0.0, _ease_in_out(progress))
	_rod_swing.rotation.z = sin(progress * PI * 5.0) * 0.045 * (1.0 - progress)
	if progress >= 1.0:
		_rod_swing.rotation = Vector3.ZERO
		_bait_instance.visible = false
		if _sabiki_rig_root != null:
			_sabiki_rig_root.visible = false
		_line_instance.visible = false
		_bait_velocity_world = Vector3.ZERO
		_line_paid_out_length_m = 0.0
		_retrieve_start_paid_length_m = 0.0
		_rod_tension = 0.0
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


func _constrain_sabiki_terminal_to_active_length() -> bool:
	if _current_rig.rig_type != BoatFishingRigProfile.RigType.SABIKI or not _state in [CastState.CASTING, CastState.WAITING, CastState.SABIKI_HOOKED_WAITING, CastState.BITE_APPROACH]:
		return true
	var rod_tip := _get_rod_tip_world()
	var radius := _get_effective_main_line_length_m()
	var radial := _bait_world - rod_tip
	var endpoint_excess := maxf(0.0, radial.length() - radius)
	_last_sabiki_endpoint_excess_before_constraint_m = endpoint_excess
	_maximum_sabiki_active_endpoint_excess_m = maxf(_maximum_sabiki_active_endpoint_excess_m, endpoint_excess)
	if endpoint_excess <= 0.00001:
		_sabiki_reachability_constraint_feasible = true
		return true
	var water := _sample_water(_bait_world)
	var surface_y := float(water.get("height", _bait_world.y)) + 0.018
	var minimum_y := -1000000.0
	var seabed := _sample_seabed(_bait_world)
	if bool(seabed.get("valid", false)):
		minimum_y = float(seabed["bottom_world_y"]) + SEABED_CLEARANCE_M
	var allow_above_surface := (_state == CastState.CASTING and not _bait_has_landed) or _bait_airborne_retrieval
	var maximum_y := 1000000.0 if allow_above_surface else surface_y
	if minimum_y > maximum_y:
		_sabiki_reachability_constraint_feasible = false
		return false
	var target_y := clampf(_bait_world.y, minimum_y, maximum_y)
	var vertical_delta := target_y - rod_tip.y
	if absf(vertical_delta) > radius:
		# The allowed water column and the endpoint reach sphere do not intersect.
		# Keep the closest environmentally valid position and expose the conflict.
		_bait_world = Vector3(rod_tip.x, target_y, rod_tip.z)
		_sabiki_reachability_constraint_feasible = false
		return false
	var horizontal := Vector3(_bait_world.x - rod_tip.x, 0.0, _bait_world.z - rod_tip.z)
	var maximum_horizontal := sqrt(maxf(0.0, radius * radius - vertical_delta * vertical_delta))
	if horizontal.length() > maximum_horizontal:
		var direction := horizontal.normalized() if horizontal.length_squared() > 0.000001 else Vector3.FORWARD
		horizontal = direction * maximum_horizontal
	_bait_world = Vector3(rod_tip.x + horizontal.x, target_y, rod_tip.z + horizontal.z)
	var outward := (_bait_world - rod_tip).normalized()
	var outward_speed := _bait_velocity_world.dot(outward)
	if outward_speed > 0.0:
		_bait_velocity_world -= outward * outward_speed
	_sabiki_reachability_constraint_feasible = true
	return true


func _sync_manual_line_controls() -> void:
	var wants_reel := _manual_reeling_input_held or _manual_reeling_from_ui
	var wants_release := _manual_line_release_held and not _fight_session_active
	if wants_reel and wants_release:
		_line_controls_conflicted = true
	if _line_controls_conflicted:
		_manual_reeling = false
		_manual_line_releasing = false
		if not wants_reel and not wants_release:
			_line_controls_conflicted = false
		interaction_updated.emit(get_interaction_snapshot())
		return
	var input_valid := _activity_active and _is_manual_reel_state() and not _automatic_control_owned
	_manual_reeling = wants_reel and input_valid
	_manual_line_releasing = wants_release and input_valid
	interaction_updated.emit(get_interaction_snapshot())


func _get_reel_feedback_line_length() -> float:
	match _state:
		CastState.CASTING, CastState.RETRIEVING:
			if not _bait_flight_started or not is_cast_active():
				return 0.0
			if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
				return maxf(0.0, _line_paid_out_length_m)
			# Preserve the Single Jig reel visualization's previous endpoint-based
			# measurement. Sabiki instead exposes only its player-paid outer length.
			return _get_rod_tip_world().distance_to(_get_main_line_terminal_world())
		CastState.WAITING, CastState.SABIKI_HOOKED_WAITING, CastState.BITE_APPROACH, CastState.FIGHTING, CastState.CATCH_PRESENTATION, CastState.LANDING:
			return maxf(0.0, _line_paid_out_length_m)
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
		or (_state in [CastState.BITE_APPROACH, CastState.FIGHTING, CastState.LANDING, CastState.CATCH_PRESENTATION] and _automatic_control_owned)
		or (_fight_session_active and _state in [CastState.SABIKI_HOOKED_WAITING, CastState.FIGHTING] and absf(line_delta_m) >= REEL_LINE_DELTA_EPSILON_M)
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
		_automatic_control_owned or _fight_session_active, _bait_flight_started, _bait_has_landed
	)
	var audio_line_rate := float(_fight_snapshot.get("line_rate_mps", line_rate_mps)) if _fight_session_active else line_rate_mps
	var audio_speed_reference := maxf(BOAT_FIGHT_LINE_PROFILE.reel_in_speed_mps, BOAT_FIGHT_LINE_PROFILE.max_line_out_speed_mps)
	for key_variant in targets.keys():
		var key := str(key_variant)
		var active := bool(targets[key_variant])
		var intensity := clampf(absf(audio_line_rate) / maxf(audio_speed_reference, 0.1), 0.08, 1.0) if active else 0.0
		_set_boat_fishing_audio_loop(key, active, intensity)


static func get_boat_fishing_audio_targets(state: int, line_delta_m: float, manual_reeling: bool, manual_releasing: bool, automatic_owned: bool, bait_flying: bool, bait_landed: bool) -> Dictionary:
	var moving_in := line_delta_m < -REEL_LINE_DELTA_EPSILON_M
	var moving_out := line_delta_m > REEL_LINE_DELTA_EPSILON_M
	var waiting := state in [CastState.WAITING, CastState.SABIKI_HOOKED_WAITING]
	var auto_fight := state in [CastState.BITE_APPROACH, CastState.FIGHTING, CastState.CATCH_PRESENTATION]
	var retrieval_active := state == CastState.RETRIEVING
	var fight_landing := state == CastState.LANDING
	return {
		"line_out": (state == CastState.CASTING and bait_flying and not bait_landed and moving_out) or (waiting and manual_releasing and moving_out),
		"reel_in": moving_in and ((waiting and (manual_reeling or automatic_owned)) or retrieval_active or auto_fight or fight_landing),
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


func _set_boat_fishing_audio_loop(key: String, active: bool, intensity: float = 1.0) -> void:
	var safe_intensity := clampf(intensity, 0.0, 1.0) if active and is_finite(intensity) else 0.0
	var previous_active := bool(_requested_fishing_audio_loops.get(key, false))
	var previous_intensity := float(_requested_fishing_audio_intensities.get(key, 0.0))
	if previous_active == active and absf(previous_intensity - safe_intensity) < 0.02:
		return
	_requested_fishing_audio_loops[key] = active
	_requested_fishing_audio_intensities[key] = safe_intensity
	if is_instance_valid(_fishing_audio_system):
		_fishing_audio_system.set_external_fishing_audio_loop(BOAT_FISHING_AUDIO_OWNER, key, active, safe_intensity)


func _clear_boat_fishing_audio_loops() -> void:
	for key_variant in _requested_fishing_audio_loops.keys():
		_set_boat_fishing_audio_loop(str(key_variant), false)
	_requested_fishing_audio_intensities = {"line_out": 0.0, "drag": 0.0, "reel_in": 0.0}
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
	var directional_tip := Vector3(
		_rod_bend_direction_local.x * curved_tip.x,
		curved_tip.y,
		_rod_bend_direction_local.y * curved_tip.x
	)
	return _rod_swing.to_global(mesh_transform * directional_tip)


func _line_tackle_above_surface(terminal_position: Vector3) -> bool:
	# Endpoint-only geometry input avoids a path -> hook getter -> path cycle.
	for point in [_bait_world, terminal_position]:
		if point.y < float(_sample_water(point).get("height", point.y)):
			return false
	return true


func _ensure_fishing_line_path_snapshot() -> void:
	var line_visual_state := _get_main_line_visual_state()
	line_visual_state["airborne_elapsed_seconds"] = _airborne_retrieval_elapsed
	line_visual_state["bait_velocity_world"] = _bait_velocity_world
	line_visual_state["fight_session_active"] = _fight_session_active
	line_visual_state["fight_tension_n"] = float(_fight_snapshot.get("tension_n", 0.0))
	line_visual_state["line_out_rate_mps"] = float(_fight_snapshot.get("line_out_rate_mps", 0.0))
	line_visual_state["line_visual_reference_load_n"] = line_visual_reference_load_n
	line_visual_state["max_line_out_speed_mps"] = BOAT_FIGHT_LINE_PROFILE.max_line_out_speed_mps
	line_visual_state["fight_visual_elapsed_seconds"] = _fight_visual_elapsed
	line_visual_state["line_visual_vibration_frequency_hz"] = line_visual_vibration_frequency_hz
	line_visual_state["line_visual_vibration_m"] = line_visual_vibration_m
	var start := _get_rod_tip_world()
	var end := _get_main_line_terminal_world()
	var effective_length := _get_effective_main_line_length_m()
	line_visual_state["airborne_reel_constraint"] = (_manual_reeling or _state == CastState.RETRIEVING) and not _fight_session_active and effective_length <= start.distance_to(end) + 0.01 and (_bait_airborne_retrieval or _line_tackle_above_surface(end))
	if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
		line_visual_state["sabiki_rig"] = {
			"length_m": _current_rig.get_line_attachment_height_m(),
			"bottom_leader_m": _current_rig.bottom_leader_length_m,
			"hook_spacing_m": _current_rig.hook_spacing_m,
			"hook_count": _current_rig.hook_count,
		}
	_update_rod_line_guides()
	var prefix_world := PackedVector3Array([_get_reel_line_exit_world(), _get_reel_line_guide_world()])
	for guide in _rod_line_guides:
		if is_instance_valid(guide):
			prefix_world.append(guide.global_position)
	prefix_world.append(start)
	var deck_polygon := PackedVector2Array()
	var deck_height := 0.0
	var tail_route_local: Array[Vector3] = []
	if _onboard != null:
		tail_route_local.append(_onboard.to_local(start))
		tail_route_local.append(_onboard.to_local(end))
	else:
		tail_route_local.append(start)
		tail_route_local.append(end)
	# Sabiki is one free A-to-C span. Hull clearance remains a soft visual concern;
	# inserting mandatory gunwale waypoints would recreate a third path constraint.
	if _current_rig.rig_type == BoatFishingRigProfile.RigType.SINGLE_JIG and not bool(line_visual_state.get("taut", false)) and _onboard != null and _onboard.profile != null:
		deck_polygon = _onboard.profile.walkable_polygon_xz
		deck_height = _onboard.profile.deck_height_m
		tail_route_local = get_hull_clearance_line_route(
			tail_route_local[0], tail_route_local[1], deck_polygon, deck_height
		)
	var route_world := PackedVector3Array()
	var route_local := PackedVector3Array()
	for route_point in tail_route_local:
		route_world.append(_onboard.to_global(route_point) if _onboard != null else route_point)
		route_local.append(route_point)
	var key: Array = [start, end, _bait_world, _current_rig, _current_rig.hook_count, _current_rig.hook_spacing_m, _current_rig.top_leader_length_m, _current_rig.bottom_leader_length_m, _onboard.global_transform if _onboard != null else Transform3D.IDENTITY, _state, _line_paid_out_length_m, _rod_tension, _bait_velocity_world, _airborne_retrieval_elapsed, _fight_visual_elapsed, line_visual_state]
	if key == _line_path_input_key and not _main_line_path_snapshot.is_empty():
		return
	_line_path_input_key = key.duplicate(true)
	_main_line_path_snapshot = generate_fishing_line_path(
		prefix_world,
		route_world,
		route_local,
		deck_polygon,
		deck_height,
		line_visual_state
	)
	_main_line_path_snapshot["generated_frame"] = Engine.get_process_frames()
	_main_line_path_snapshot["authority_paid_length_m"] = _line_paid_out_length_m
	_main_line_path_snapshot["rig_config_length_m"] = _current_rig.get_line_attachment_height_m() if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI else 0.0
	_main_line_path_snapshot["endpoint_chord_m"] = start.distance_to(end)


func _update_line_and_bait_visuals() -> void:
	if not is_cast_active() or not _bait_flight_started:
		return
	_update_single_jig_visual(maxf(get_process_delta_time(), 0.0))
	_ensure_fishing_line_path_snapshot()
	_render_complete_line_path(_line_mesh, self)
	_line_instance.visible = true
	_bait_instance.global_position = _bait_world
	_bait_instance.global_basis = _lure_visual_basis_world
	_bait_instance.visible = _current_rig.rig_type == BoatFishingRigProfile.RigType.SINGLE_JIG
	_update_rig_visual_position()
	_reanchor_sabiki_hooked_fish_visuals_to_hooks()
	_reanchor_single_jig_fight_fish_visual_to_hook()


func _reanchor_single_jig_fight_fish_visual_to_hook() -> void:
	if (
		_current_rig.rig_type != BoatFishingRigProfile.RigType.SINGLE_JIG
		or _state not in [CastState.FIGHTING, CastState.LANDING, CastState.CATCH_PRESENTATION]
		or _bite_fish_visual == null
		or not is_instance_valid(_bite_fish_visual)
	):
		return
	var profile := _fish_manager.get_species_profile(_active_catch_species_id) if _fish_manager != null else null
	if profile == null:
		return
	# The lure basis is updated immediately above. Re-anchor after that update so
	# the displayed fish mouth uses the same frame's moving hook tip.
	var fish_basis := _bite_fish_visual.global_basis
	var hook_world := _get_single_jig_hook_attachment_world()
	_bite_fish_visual.global_position = mouth_anchored_fish_origin(
		hook_world,
		fish_basis,
		profile.boat_fishing_mouth_anchor_local
	)


func _render_complete_line_path(mesh: ImmediateMesh, owner: Node3D) -> void:
	if mesh == null or owner == null or _main_line_path_snapshot.is_empty():
		return
	var points: PackedVector3Array = _main_line_path_snapshot["centerline_points"]
	var tangents: PackedVector3Array = _main_line_path_snapshot["tangents"]
	var sides: PackedVector3Array = _main_line_path_snapshot["sides"]
	var local_points := PackedVector3Array()
	var local_tangents := PackedVector3Array()
	var local_sides := PackedVector3Array()
	var inverse := owner.global_basis.inverse()
	for index in range(points.size()):
		local_points.append(owner.to_local(points[index]))
		local_tangents.append((inverse * tangents[index]).normalized())
		local_sides.append((inverse * sides[index]).normalized())
	_rebuild_line_tube_mesh(mesh, local_points, local_tangents, local_sides)


static func generate_fishing_line_path(
	prefix_world: PackedVector3Array,
	route_world: PackedVector3Array,
	route_local: PackedVector3Array,
	deck_polygon: PackedVector2Array,
	deck_height_m: float,
	visual_state: Dictionary
) -> Dictionary:
	var points := PackedVector3Array()
	for prefix_point in prefix_world:
		if prefix_point.is_finite() and (points.is_empty() or points[-1].distance_to(prefix_point) > 0.0001):
			points.append(prefix_point)
	if route_world.is_empty():
		return _finalize_line_path(points, route_world)
	if points.is_empty() or points[-1].distance_to(route_world[0]) > 0.0001:
		points.append(route_world[0])
	var taut := bool(visual_state.get("taut", false))
	var slack_ratio := clampf(float(visual_state.get("slack_ratio", 1.0)), 0.0, 1.0)
	var airborne := bool(visual_state.get("airborne", false))
	var airborne_elapsed := maxf(0.0, float(visual_state.get("airborne_elapsed_seconds", 0.0)))
	var bait_velocity: Vector3 = visual_state.get("bait_velocity_world", Vector3.ZERO)
	var fight_session_active := bool(visual_state.get("fight_session_active", false))
	var fight_tension_n := maxf(0.0, float(visual_state.get("fight_tension_n", 0.0)))
	var line_out_rate_mps := maxf(0.0, float(visual_state.get("line_out_rate_mps", 0.0)))
	var reference_load_n := maxf(0.001, float(visual_state.get("line_visual_reference_load_n", 1.0)))
	var max_line_out_speed_mps := maxf(0.1, float(visual_state.get("max_line_out_speed_mps", 1.0)))
	var fight_visual_elapsed := float(visual_state.get("fight_visual_elapsed_seconds", 0.0))
	var vibration_frequency_hz := maxf(0.0, float(visual_state.get("line_visual_vibration_frequency_hz", 0.0)))
	var vibration_amplitude_m := maxf(0.0, float(visual_state.get("line_visual_vibration_m", 0.0)))
	var sabiki_rig: Dictionary = visual_state.get("sabiki_rig", {})
	var span_count := maxi(0, route_world.size() - 1)
	if span_count == 0:
		return _finalize_line_path(points, route_world)
	var sabiki_visual_sag := 0.0
	if not sabiki_rig.is_empty() and span_count == 1:
		var chord_length := route_world[0].distance_to(route_world[1])
		var rig_length := maxf(0.0, float(sabiki_rig.get("length_m", 0.0)))
		if chord_length < rig_length:
			sabiki_visual_sag = 0.55 * sqrt(maxf(0.0, rig_length * rig_length - chord_length * chord_length))
	var segments_per_span := maxi(2, int(ceil(float(LINE_SEGMENTS) / float(span_count))))
	for span_index in range(span_count):
		var span_start := route_world[span_index]
		var span_end := route_world[span_index + 1]
		var span_delta := span_end - span_start
		var span_length := span_delta.length()
		var local_start := route_local[span_index] if route_local.size() == route_world.size() else span_start
		var local_end := route_local[span_index + 1] if route_local.size() == route_world.size() else span_end
		var midpoint_local := (local_start + local_end) * 0.5
		var midpoint_over_deck := not deck_polygon.is_empty() and Geometry2D.is_point_in_polygon(Vector2(midpoint_local.x, midpoint_local.z), deck_polygon)
		var over_deck := false
		if sabiki_rig.is_empty():
			var clearance_height := deck_height_m + 1.34
			var span_kept_clear := not deck_polygon.is_empty() and local_start.y >= clearance_height and local_end.y >= clearance_height
			over_deck = midpoint_over_deck or span_kept_clear
		var terminal_span := span_index == span_count - 1
		var sag_allowed := not over_deck and not taut and not bool(visual_state.get("airborne_reel_constraint", false))
		var sag := calculate_main_line_visual_sag_depth(span_length, slack_ratio, airborne) if sag_allowed else 0.0
		if not sabiki_rig.is_empty():
			sag = maxf(sag, sabiki_visual_sag)
		var sag_offset := Vector3.DOWN * sag
		var sway_axis := span_delta.cross(Vector3.DOWN).normalized()
		if sway_axis.length_squared() < 0.001:
			sway_axis = Vector3.RIGHT
		for point_index in range(1, segments_per_span + 1):
			var t := float(point_index) / float(segments_per_span)
			var line_point := _line_path_span(span_start, span_end, span_delta, span_delta, sag_offset, t)
			var envelope := pow(sin(PI * t), 2.0)
			if sag_allowed and airborne and terminal_span and not over_deck:
				var relaxation := exp(-2.6 * airborne_elapsed)
				var sway_scale := 0.012 if not sabiki_rig.is_empty() else 0.035
				var sway_limit := 0.025 if not sabiki_rig.is_empty() else 0.065
				var sway_amount := clampf(Vector2(bait_velocity.x, bait_velocity.z).length() * sway_scale, 0.0, sway_limit) * relaxation
				line_point += sway_axis * sin(airborne_elapsed * 7.0) * sway_amount * envelope
			if fight_session_active and terminal_span and not over_deck:
				var strength := maxf(clampf(fight_tension_n / reference_load_n, 0.0, 1.0), clampf(line_out_rate_mps / max_line_out_speed_mps, 0.0, 1.0) * 0.65)
				line_point += sway_axis * sin(fight_visual_elapsed * TAU * vibration_frequency_hz + span_index * 1.37 + t * 2.4) * vibration_amplitude_m * strength * envelope
			if points.is_empty() or points[-1].distance_to(line_point) > 0.0001:
				points.append(line_point)
	var result := _finalize_line_path(points, route_world)
	if not sabiki_rig.is_empty():
		var stations: Dictionary = result["stations"]
		var rod_station: Dictionary = stations.get("rod_tip", {})
		var end_station: Dictionary = stations.get("line_end", {})
		if rod_station.is_empty() or end_station.is_empty():
			result["valid"] = false
			return result
		var rod_s := float(rod_station["arc_length_m"])
		var end_s := float(end_station["arc_length_m"])
		var hook_count := maxi(0, int(sabiki_rig.get("hook_count", 0)))
		var bottom_leader := maxf(0.0, float(sabiki_rig.get("bottom_leader_m", 0.0)))
		var hook_spacing := maxf(0.0, float(sabiki_rig.get("hook_spacing_m", 0.0)))
		var rig_length := maxf(0.0, float(sabiki_rig.get("length_m", 0.0)))
		var hook_span_length := bottom_leader + float(maxi(0, hook_count - 1)) * hook_spacing
		var station_scale_length := maxf(rig_length, hook_span_length)
		var available_geometry_length := maxf(0.0, end_s - rod_s)
		var rig_visual_station_scale := 1.0
		if station_scale_length > 0.0001:
			rig_visual_station_scale = minf(1.0, available_geometry_length / station_scale_length)
		var hook_stations: Array[Dictionary] = []
		for hook_index in range(hook_count):
			var profile_material_distance := bottom_leader + float(hook_count - hook_index - 1) * hook_spacing
			var visual_path_distance := profile_material_distance * rig_visual_station_scale
			var wanted_s := end_s - visual_path_distance
			var station := _line_path_station_at_distance(result, wanted_s)
			station["profile_material_distance_from_sinker_m"] = profile_material_distance
			station["visual_path_distance_from_sinker_m"] = visual_path_distance
			stations["hook_%d" % (hook_index + 1)] = station
			hook_stations.append(station)
		stations["sinker"] = end_station
		result["stations"] = stations
		result["rig_config_length_m"] = rig_length
		result["rig_visual_station_scale"] = rig_visual_station_scale
		result["rig_hook_station_count"] = hook_stations.size()
		result["free_line_geometry_length_m"] = end_s - rod_s
	return result


static func _line_path_station(snapshot: Dictionary, index: int) -> Dictionary:
	return {"index": index, "position": snapshot["centerline_points"][index], "arc_length_m": snapshot["cumulative_lengths"][index], "tangent": snapshot["tangents"][index], "side": snapshot["sides"][index]}


static func _line_path_station_at_distance(snapshot: Dictionary, distance: float) -> Dictionary:
	var points: PackedVector3Array = snapshot["centerline_points"]
	var lengths: PackedFloat32Array = snapshot["cumulative_lengths"]
	for index in range(1, points.size()):
		if distance <= lengths[index]:
			var t := clampf((distance - lengths[index - 1]) / maxf(lengths[index] - lengths[index - 1], 0.000001), 0.0, 1.0)
			var tangent: Vector3 = snapshot["tangents"][index - 1].lerp(snapshot["tangents"][index], t).normalized()
			var side: Vector3 = snapshot["sides"][index - 1].lerp(snapshot["sides"][index], t)
			side = calculate_line_tube_side_direction(tangent, side)
			return {"index": index - 1, "fraction": t, "position": points[index - 1].lerp(points[index], t), "arc_length_m": distance, "tangent": tangent, "side": side}
	return _line_path_station(snapshot, points.size() - 1)


static func _line_path_span(a: Vector3, b: Vector3, incoming: Vector3, outgoing: Vector3, offset: Vector3, t: float) -> Vector3:
	var t2 := t * t
	var t3 := t2 * t
	if incoming == b - a and outgoing == b - a:
		return a.lerp(b, t) + offset * pow(sin(PI * t), 2.0)
	return a + (b - a) * (-2.0 * t3 + 3.0 * t2) + incoming * (t3 - 2.0 * t2 + t) + outgoing * (t3 - t2) + offset * pow(sin(PI * t), 2.0)


static func _finalize_line_path(points: PackedVector3Array, route: PackedVector3Array) -> Dictionary:
	var lengths := PackedFloat32Array()
	var tangents := PackedVector3Array()
	var sides := PackedVector3Array()
	var previous_side := Vector3.ZERO
	for index in range(points.size()):
		lengths.append(0.0 if index == 0 else lengths[-1] + points[index - 1].distance_to(points[index]))
		var direction := points[mini(index + 1, points.size() - 1)] - points[maxi(0, index - 1)]
		if direction.length_squared() < 0.000001:
			direction = tangents[-1] if not tangents.is_empty() else Vector3.DOWN
		direction = direction.normalized()
		tangents.append(direction)
		previous_side = calculate_line_tube_side_direction(direction, previous_side)
		sides.append(previous_side)
	var stations := {}
	if not route.is_empty() and not points.is_empty():
		for name in ["rod_tip", "line_end"]:
			var target: Vector3 = route[0] if name == "rod_tip" else route[-1]
			var closest := 0
			for index in range(points.size()):
				if points[index].distance_squared_to(target) < points[closest].distance_squared_to(target):
					closest = index
			stations[name] = _line_path_station_from_arrays(points, lengths, tangents, sides, closest)
	var free_length := 0.0
	if stations.has("rod_tip") and stations.has("line_end"):
		free_length = float(stations["line_end"]["arc_length_m"]) - float(stations["rod_tip"]["arc_length_m"])
	return {
		"free_line_geometry_length_m": free_length,
		"centerline_points": points,
		"cumulative_lengths": lengths,
		"tangents": tangents,
		"sides": sides,
		"stations": stations,
		"generated": true,
		"valid": points.size() >= 2,
		"endpoints_coincident": points.size() < 2 or points[0].distance_to(points[-1]) < 0.0001,
	}


static func _line_path_station_from_arrays(
	points: PackedVector3Array,
	lengths: PackedFloat32Array,
	tangents: PackedVector3Array,
	sides: PackedVector3Array,
	index: int
) -> Dictionary:
	return {
		"index": index,
		"position": points[index],
		"arc_length_m": lengths[index],
		"tangent": tangents[index],
		"side": sides[index],
	}


static func calculate_main_line_visual_sag_depth(
	span_length_m: float,
	slack_ratio: float,
	airborne: bool
) -> float:
	if not is_finite(span_length_m) or not is_finite(slack_ratio):
		return 0.0
	var span_length := maxf(0.0, span_length_m)
	var safe_slack := clampf(slack_ratio, 0.0, 1.0)
	var natural_sag := minf(span_length * 0.018, 0.62)
	if airborne:
		natural_sag = minf(AIRBORNE_LINE_VISUAL_SAG_M, span_length * 0.16)
	return natural_sag * safe_slack




static func calculate_line_tube_side_direction(segment_direction: Vector3, previous_side_direction: Vector3) -> Vector3:
	if not segment_direction.is_finite() or segment_direction.length_squared() < 0.000001:
		return Vector3.RIGHT
	var direction := segment_direction.normalized()
	var side := Vector3.ZERO
	if previous_side_direction.is_finite() and previous_side_direction.length_squared() > 0.000001:
		var previous := previous_side_direction.normalized()
		side = previous - direction * previous.dot(direction)
	if side.length_squared() < 0.000001:
		side = direction.cross(Vector3.UP)
	if side.length_squared() < 0.000001:
		side = direction.cross(Vector3.RIGHT)
	return side.normalized() if side.length_squared() > 0.000001 else Vector3.FORWARD


func _rebuild_line_tube_mesh(mesh: ImmediateMesh, points: PackedVector3Array, tangents: PackedVector3Array = PackedVector3Array(), sides: PackedVector3Array = PackedVector3Array()) -> void:
	if mesh == null:
		return
	mesh.clear_surfaces()
	if points.size() < 2:
		return
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, _line_material)
	var previous_side_direction := Vector3.ZERO
	for point_index in range(points.size() - 1):
		var segment_direction := (points[point_index + 1] - points[point_index]).normalized()
		var side_direction := calculate_line_tube_side_direction(segment_direction, previous_side_direction)
		previous_side_direction = side_direction
		var side := side_direction * LINE_RADIUS_M
		var other := segment_direction.cross(side_direction).normalized() * LINE_RADIUS_M
		var a := points[point_index]
		var b := points[point_index + 1]
		for side_index in range(LINE_SIDES):
			var angle_a := TAU * float(side_index) / float(LINE_SIDES)
			var angle_b := TAU * float(side_index + 1) / float(LINE_SIDES)
			var offset_a := side * cos(angle_a) + other * sin(angle_a)
			var offset_b := side * cos(angle_b) + other * sin(angle_b)
			var end_offset_a := offset_a
			var end_offset_b := offset_b
			if sides.size() == points.size() and tangents.size() == points.size():
				var side_a := sides[point_index] * LINE_RADIUS_M
				var other_a := tangents[point_index].cross(sides[point_index]).normalized() * LINE_RADIUS_M
				var side_b := sides[point_index + 1] * LINE_RADIUS_M
				var other_b := tangents[point_index + 1].cross(sides[point_index + 1]).normalized() * LINE_RADIUS_M
				offset_a = side_a * cos(angle_a) + other_a * sin(angle_a)
				offset_b = side_a * cos(angle_b) + other_a * sin(angle_b)
				end_offset_a = side_b * cos(angle_a) + other_b * sin(angle_a)
				end_offset_b = side_b * cos(angle_b) + other_b * sin(angle_b)
			mesh.surface_add_vertex(a + offset_a)
			mesh.surface_add_vertex(b + end_offset_a)
			mesh.surface_add_vertex(b + end_offset_b)
			mesh.surface_add_vertex(a + offset_a)
			mesh.surface_add_vertex(b + end_offset_b)
			mesh.surface_add_vertex(a + offset_b)
	mesh.surface_end()


func _update_rig_visual_selection() -> void:
	if _sabiki_rig_root == null:
		return
	for index in range(_sabiki_hook_nodes.size()):
		_sabiki_hook_nodes[index].visible = index < _current_rig.hook_count
	_update_rig_visual_position()


func _update_rig_visual_position() -> Vector3:
	if _sabiki_rig_root == null:
		return Vector3.UP
	var sabiki_active := _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI
	var rig_up_direction := _get_sabiki_rig_up_direction_world()
	_sabiki_rig_root.global_position = _bait_world
	_sabiki_rig_root.global_basis = Basis(Quaternion(Vector3.UP, rig_up_direction))
	if sabiki_active and is_cast_active():
		var stations: Dictionary = _main_line_path_snapshot.get("stations", {})
		var root_inverse := _sabiki_rig_root.global_basis.inverse()
		for hook_index in range(mini(_current_rig.hook_count, _sabiki_hook_nodes.size())):
			var station_name := "hook_%d" % (hook_index + 1)
			if not stations.has(station_name):
				continue
			var station: Dictionary = stations[station_name]
			var hook_node := _sabiki_hook_nodes[hook_index]
			hook_node.position = _sabiki_rig_root.to_local(station["position"])
			var default_branch_world: Vector3 = station.get("side", Vector3.RIGHT)
			var default_branch_local: Vector3 = (root_inverse * default_branch_world).normalized()
			var branch_direction: Vector3 = _fight_sabiki_branch_directions_local.get(hook_index, default_branch_local)
			branch_direction = branch_direction.normalized() if branch_direction.length_squared() > 0.0001 else default_branch_local
			hook_node.basis = Basis(Quaternion(Vector3.LEFT, branch_direction))
	_sabiki_rig_root.visible = sabiki_active and is_cast_active() and _bait_flight_started
	return rig_up_direction


func _get_main_line_visual_state() -> Dictionary:
	var slack_ratio := 1.0 - clampf(_rod_tension, 0.0, 1.0) * 0.9
	if _fight_session_active:
		slack_ratio = _get_fight_line_visual_slack_ratio()
	var forced_taut := (
		_state == CastState.CASTING
		or (_is_waiting_line_state() and _manual_reeling and not _fight_session_active)
		or _state == CastState.RETRIEVING
	)
	var airborne := _bait_airborne_retrieval
	# Landing and catch presentation are automatic reel-in phases. Once the fight
	# solver stops, do not reuse its stale slack ratio for the short display line.
	var presentation_reel := _state in [CastState.LANDING, CastState.CATCH_PRESENTATION]
	var taut := presentation_reel or (not airborne and (forced_taut or slack_ratio <= 0.001))
	if taut:
		slack_ratio = 0.0
	return {"taut": taut, "slack_ratio": clampf(slack_ratio, 0.0, 1.0), "airborne": airborne}


func _get_sabiki_rig_up_direction_world() -> Vector3:
	if _current_rig.rig_type != BoatFishingRigProfile.RigType.SABIKI or not is_cast_active():
		return _get_sabiki_natural_up_direction_world()
	_ensure_fishing_line_path_snapshot()
	var station: Dictionary = _main_line_path_snapshot.get("stations", {}).get("sinker", {})
	var tangent: Vector3 = station.get("tangent", Vector3.ZERO)
	if tangent.length_squared() > 0.0001 and tangent.is_finite():
		return -tangent.normalized()
	var toward_rod := _get_rod_tip_world() - _bait_world
	return toward_rod.normalized() if toward_rod.length_squared() > 0.0001 else Vector3.UP


func _get_tackle_water_sample_points() -> Array[Vector3]:
	var points: Array[Vector3] = [_bait_world]
	if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
		points.append_array(get_hook_attachment_world_positions())
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


func _get_sabiki_natural_up_direction_world() -> Vector3:
	var boat_flow := Vector3(_boat_velocity_estimate_world.x, 0.0, _boat_velocity_estimate_world.z)
	if boat_flow.length_squared() > 0.01:
		boat_flow = boat_flow.normalized() * clampf(boat_flow.length() / 18.0 * 0.22, 0.0, 0.22)
	var relative_motion := Vector3(
		_bait_velocity_world.x - _boat_velocity_estimate_world.x * BAIT_WATER_DRAG_FOLLOW,
		0.0,
		_bait_velocity_world.z - _boat_velocity_estimate_world.z * BAIT_WATER_DRAG_FOLLOW
	)
	var motion_lean := Vector3.ZERO
	if _state == CastState.CASTING and relative_motion.length_squared() > 0.0025:
		var response := clampf(relative_motion.length() / SABIKI_MOTION_AXIS_RESPONSE_SPEED_MPS, 0.0, SABIKI_MOTION_AXIS_MAX_LEAN)
		motion_lean = -relative_motion.normalized() * response
	return (Vector3.UP + boat_flow + motion_lean).normalized()


func _get_main_line_terminal_offset_world() -> Vector3:
	if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
		return Vector3.ZERO
	return _lure_visual_basis_world * Vector3.UP * SPOON_LINE_EYE_Y_M


func _get_fixed_rig_line_length_m() -> float:
	return _current_rig.get_line_attachment_height_m() if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI else 0.0


func _get_effective_main_line_length_m() -> float:
	return maxf(0.0, _line_paid_out_length_m) + _get_fixed_rig_line_length_m()


func _get_main_line_terminal_world() -> Vector3:
	return _bait_world + _get_main_line_terminal_offset_world()


func _get_retrieval_target_bait_world() -> Vector3:
	if _current_rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
		return _get_rod_tip_world() - _get_sabiki_natural_up_direction_world() * _current_rig.get_line_attachment_height_m()
	return _get_rod_tip_world() - _get_main_line_terminal_offset_world()


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
	_sync_fishing_fight_view_state(next_state)
	if next_state == CastState.WAITING:
		_natural_bite_sample_elapsed = 0.0
		_natural_bite_pending_real_delta = 0.0
		if _encounter != null:
			_encounter.reset_boat_fishing_trigger_state()
	_emit_state_changed()


func _sync_fishing_fight_view_state(state: CastState) -> void:
	if _onboard == null:
		return
	var fight_view_state := state in [
		CastState.SABIKI_HOOKED_WAITING,
		CastState.FIGHTING,
		CastState.LANDING,
		CastState.CATCH_PRESENTATION,
	]
	if fight_view_state:
		if not _onboard.is_fishing_fight_view_active():
			_onboard.begin_fishing_fight_view(
				FIGHT_VIEW_YAW_HALF_RANGE_DEG,
				BOAT_FISHING_VIEW_PITCH_MIN_DEG,
				BOAT_FISHING_VIEW_PITCH_MAX_DEG,
				FIGHT_PRESENTATION_PITCH_MANUAL_RANGE_DEG
			)
		_onboard.set_fishing_presentation_tracking(state in [CastState.LANDING, CastState.CATCH_PRESENTATION])
	elif _onboard.is_fishing_fight_view_active():
		_onboard.end_fishing_fight_view()


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
		CastState.LANDING:
			status_key = "hud.boat_fishing.state_landing"
			hint_key = "hud.boat_fishing.hint_landing"
		CastState.LINE_BROKEN:
			status_key = "hud.boat_fishing.state_line_snapped"
			hint_key = "hud.boat_fishing.hint_line_snapped"
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
	_rod_shader_material.set_shader_parameter("bend_direction_local", Vector3.RIGHT)
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
	_reel_spool_visual = reel_parts["spool"] as MeshInstance3D
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
	return rod_mesh_transform * Vector3(
		_rod_bend_direction_local.x * center_x,
		center_y,
		_rod_bend_direction_local.y * center_x
	)


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
