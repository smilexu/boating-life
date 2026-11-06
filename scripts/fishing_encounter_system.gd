class_name FishingEncounterSystem
extends Node

signal state_changed(state: String)
signal trolling_started(lure_id: String)
signal trolling_stopped
signal fish_hooked(pending: FishingPendingCatch)
signal retrieval_started(catch_id: String)
signal retrieval_completed(result: FishingCatchResult)
signal catch_succeeded(result: FishingCatchResult)
signal catch_cancelled(catch_id: String, reason: String)
signal sabiki_batch_settled(batch_id: String, results: Array)

const SECONDS_PER_GAME_HOUR := 3600.0
const SECONDS_PER_REAL_HOUR := 3600.0
const BOAT_FISHING_MAX_HORIZONTAL_RANGE_M := 50.0
const BOAT_FISHING_DIAGNOSTIC_QUERY_RADIUS_M := 65.0
const BOAT_FISHING_INITIAL_SCHOOL_SEARCH_RADIUS_M := 15.0
const LURE_PATHS := [
	"res://resources/fishing/lures/surface_lure.tres",
	"res://resources/fishing/lures/shallow_minnow.tres",
	"res://resources/fishing/lures/medium_minnow.tres",
]

enum State { IDLE, TROLLING, HOOKED, RETRIEVING, SETTLED, BOAT_BITE_APPROACH }
const STATE_NAMES := ["IDLE", "TROLLING", "HOOKED", "RETRIEVING", "SETTLED", "BOAT_BITE_APPROACH"]

@export_category("Encounter balance")
@export_range(0.01, 20.0, 0.01) var base_event_rate_per_game_hour := 1.2
@export_range(5.0, 100.0, 1.0) var encounter_radius_m := 28.0
@export_range(1.0, 30.0, 0.5) var lure_trailing_distance_m := 8.0
@export_range(0.05, 1.0, 0.05) var encounter_sampling_interval_real_seconds := 0.25
@export_range(0.0, 5.0, 0.1) var minimum_seabed_clearance_m := 0.8
@export_range(0.0, 20.0, 0.5) var minimum_effective_trolling_speed_mps := 0.25
@export_range(0.0, 3600.0, 30.0) var school_encounter_cooldown_game_seconds := 600.0
@export_range(30.0, 3600.0, 30.0) var maximum_clock_jump_game_seconds := 300.0
@export_range(10.0, 100.0, 1.0) var debug_judgement_window_game_seconds := 60.0
@export_range(-500.0, 500.0, 0.1) var chart_datum_world_y_m := 0.0

@export_category("Boat fishing balance")
@export_range(1.0, 10.0, 0.25) var surface_activity_transition_depth_m := 6.0
@export_range(0.0, 3.0, 0.05) var surface_transition_bite_multiplier := 1.2
@export_range(0.0, 3.0, 0.05) var visible_surface_bite_multiplier := 1.6
@export_range(5.0, 25.0, 0.5) var boat_fishing_near_distance_full_weight_end_m := 20.0
@export_range(20.0, 40.0, 0.5) var boat_fishing_middle_distance_end_m := 35.0
@export_range(0.0, 1.0, 0.05) var single_jig_min_action_weight := 0.55
@export_range(0.0, 1.0, 0.05) var single_jig_max_action_weight := 1.0
@export_range(0.1, 10.0, 0.1) var single_jig_action_reference_speed_mps := 2.5
@export_range(0.0, 1.0, 0.05) var sabiki_min_action_weight := 0.8
@export_range(0.0, 1.0, 0.05) var sabiki_max_action_weight := 1.0
@export_range(0.1, 10.0, 0.1) var sabiki_action_reference_speed_mps := 2.5
@export_range(0.0, 0.5, 0.01) var single_jig_target_min_motion_speed_mps := 0.04
@export_range(1.0, 1.5, 0.01) var boat_fishing_target_boundary_hysteresis := 1.12
@export_range(0.1, 5.0, 0.1) var boat_fishing_target_boundary_grace_seconds := 1.25
@export_range(0.1, 10.0, 0.1) var boat_fishing_target_core_min_reaction_seconds := 2.0
@export_range(0.1, 15.0, 0.1) var boat_fishing_target_core_max_reaction_seconds := 5.0
@export_range(0.1, 20.0, 0.1) var boat_fishing_target_edge_min_reaction_seconds := 5.0
@export_range(0.1, 30.0, 0.1) var boat_fishing_target_edge_max_reaction_seconds := 10.0
@export_range(0.1, 20.0, 0.1) var boat_fishing_ambient_base_event_rate_per_real_hour := 2.0
@export_range(0.1, 20.0, 0.1) var boat_fishing_ambient_max_event_rate_per_tackle_hour := 3.0
@export_range(1.0, 2.0, 0.05) var boat_fishing_ambient_density_factor_cap := 1.25

var state: State = State.IDLE
var selected_lure_id := "surface_lure"
var pending_catch: FishingPendingCatch
var last_catch_result: FishingCatchResult
var last_settlement: Dictionary = {}

var _manager: Node
var _boat: Node3D
var _bathymetry: Node
var _wave_sampler: Node
var _lures_by_id: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _length_rng := RandomNumberGenerator.new()
var _boat_rng := RandomNumberGenerator.new()
var _boat_length_rng := RandomNumberGenerator.new()
var _debug_seed_override := -1
var _next_catch_sequence := 1
var _last_game_time_seconds := 0.0
var _sampling_elapsed_real_seconds := 0.0
var _pending_game_delta_seconds := 0.0
var _hazard_accumulated := 0.0
var _hazard_threshold := 1.0
var _school_cooldown_until: Dictionary = {}
var _settled_catch_ids: Dictionary = {}
var _debug_presentation_paused := false
var _sabiki_hook_catches: Array[FishingPendingCatch] = []
var _sabiki_batch_active := false
var _sabiki_batch_id := ""
var _boat_ambient_hazard_accumulated := 0.0
var _boat_ambient_hazard_threshold := 1.0
var _boat_ambient_event_rate_per_real_hour := 0.0
var _boat_ambient_mode_active := false
var _boat_ambient_last_trigger: Dictionary = {}
var _boat_target_reactions: Dictionary = {}
var _boat_trigger_debug_by_hook: Dictionary = {}
var _boat_target_session_epoch := 0
var _boat_fishing_session_sequence := 1
var _boat_fishing_cast_sequence := 1
var _boat_fishing_session_id := ""
var _boat_fishing_cast_session_id := ""
var _boat_fishing_session_active := false
var _boat_fishing_initial_drop: Dictionary = {}
var _boat_last_ambient_authority_result: Dictionary = {}
var last_sabiki_batch_results: Array[FishingCatchResult] = []


func _ready() -> void:
	set_process(false)


func configure(manager: Node, boat: Node3D, lures: Array[FishingLure] = []) -> void:
	_manager = manager
	_boat = boat
	if _manager != null and _manager.has_method("get_bathymetry_manager"):
		_bathymetry = _manager.call("get_bathymetry_manager")
	if _manager != null and _manager.has_method("get_wave_sampler"):
		_wave_sampler = _manager.call("get_wave_sampler")
	_lures_by_id.clear()
	var configured_lures := lures
	if configured_lures.is_empty():
		for path in LURE_PATHS:
			var lure := ResourceLoader.load(path) as FishingLure
			if lure != null:
				configured_lures.append(lure)
	for lure in configured_lures:
		if lure != null and not lure.lure_id.is_empty():
			_lures_by_id[lure.lure_id] = lure
	if not _lures_by_id.has(selected_lure_id) and not _lures_by_id.is_empty():
		selected_lure_id = str(_lures_by_id.keys()[0])
	_seed_rng()
	_last_game_time_seconds = _game_time_seconds()
	set_process(true)


func _process(_delta: float) -> void:
	_sync_boat_reference()
	var now := _game_time_seconds()
	if _debug_presentation_paused:
		# Keep the real trolling state intact while a local animation preview is
		# running, but do not accrue encounter time, sample schools, or draw RNG.
		_last_game_time_seconds = now
		_sampling_elapsed_real_seconds = 0.0
		_pending_game_delta_seconds = 0.0
		return
	if state != State.TROLLING:
		_last_game_time_seconds = now
		_sampling_elapsed_real_seconds = 0.0
		_pending_game_delta_seconds = 0.0
		return
	var game_delta := now - _last_game_time_seconds
	_last_game_time_seconds = now
	if not is_finite(game_delta) or game_delta <= 0.0:
		return
	if game_delta > maximum_clock_jump_game_seconds:
		# Ignore explicit date/time jumps; normal time acceleration remains integrated.
		_hazard_accumulated = 0.0
		_hazard_threshold = _draw_hazard_threshold()
		_pending_game_delta_seconds = 0.0
		_sampling_elapsed_real_seconds = 0.0
		return
	_pending_game_delta_seconds += game_delta
	_sampling_elapsed_real_seconds += maxf(0.0, _delta)
	if _sampling_elapsed_real_seconds < encounter_sampling_interval_real_seconds:
		return
	_sampling_elapsed_real_seconds = 0.0
	var sampled_game_delta := _pending_game_delta_seconds
	_pending_game_delta_seconds = 0.0
	var diagnostics := evaluate_candidates()
	var event_rate_per_game_hour := float(diagnostics.get("total_event_rate_per_game_hour", 0.0))
	if event_rate_per_game_hour <= 0.0:
		return
	# Exponential-hazard integration is the continuous-time equivalent of
	# P = 1 - exp(-lambda * dt_game), without making odds depend on render FPS.
	_hazard_accumulated += event_rate_per_game_hour * sampled_game_delta / SECONDS_PER_GAME_HOUR
	if _hazard_accumulated >= _hazard_threshold:
		var candidates: Array[Dictionary] = diagnostics.get("valid_candidates", [])
		var candidate := _weighted_candidate(candidates)
		if not candidate.is_empty():
			_create_pending_catch(candidate, now)


func _sync_boat_reference() -> void:
	if _manager == null or not _manager.has_method("get_boat"):
		return
	var current_boat := _manager.call("get_boat") as Node3D
	if current_boat == _boat:
		return
	var was_active := state != State.IDLE
	if not _sabiki_hook_catches.is_empty() or _sabiki_batch_active:
		cancel_sabiki_catches("boat_changed")
	if pending_catch != null:
		_cancel_pending("boat_changed")
	if _boat_fishing_session_active:
		end_boat_fishing_session("boat_changed")
	_boat = current_boat
	state = State.IDLE
	_hazard_accumulated = 0.0
	_sampling_elapsed_real_seconds = 0.0
	_pending_game_delta_seconds = 0.0
	reset_boat_fishing_trigger_state()
	_last_game_time_seconds = _game_time_seconds()
	if was_active:
		state_changed.emit(get_state_name())
		trolling_stopped.emit()


func get_state_name() -> String:
	return STATE_NAMES[clampi(int(state), 0, STATE_NAMES.size() - 1)]


func get_lure_profiles() -> Array[FishingLure]:
	var result: Array[FishingLure] = []
	for lure in _lures_by_id.values():
		result.append(lure)
	result.sort_custom(func(a: FishingLure, b: FishingLure) -> bool: return a.lure_id < b.lure_id)
	return result


func get_selected_lure() -> FishingLure:
	return _lures_by_id.get(selected_lure_id) as FishingLure


func select_lure(lure_id: String) -> bool:
	if state in [State.HOOKED, State.RETRIEVING, State.BOAT_BITE_APPROACH] or not _lures_by_id.has(lure_id):
		return false
	selected_lure_id = lure_id
	_reset_hazard()
	return true


func start_trolling() -> bool:
	# Sabiki hooks are reserved locally while the shared encounter remains IDLE.
	# Do not let a trolling activity overwrite that still-live boat-fishing batch.
	var boat_catch_pending := pending_catch != null and pending_catch.fishing_method == "boat_fishing"
	if _boat == null or not is_instance_valid(_boat) or not _lures_by_id.has(selected_lure_id) or state in [State.HOOKED, State.RETRIEVING, State.BOAT_BITE_APPROACH] or boat_catch_pending or not _sabiki_hook_catches.is_empty() or _sabiki_batch_active or _boat_fishing_session_active:
		return false
	state = State.TROLLING
	_last_game_time_seconds = _game_time_seconds()
	_pending_game_delta_seconds = 0.0
	_sampling_elapsed_real_seconds = 0.0
	_reset_hazard()
	state_changed.emit(get_state_name())
	trolling_started.emit(selected_lure_id)
	return true


func stop_trolling() -> void:
	# This shared encounter can also hold a boat-fishing catch. A stale or
	# cross-activity trolling stop must never cancel that owner’s pending fish.
	if (pending_catch != null and pending_catch.fishing_method == "boat_fishing") or not _sabiki_hook_catches.is_empty() or _sabiki_batch_active:
		return
	_debug_presentation_paused = false
	if pending_catch != null:
		_cancel_pending("trolling_stopped")
	state = State.IDLE
	_hazard_accumulated = 0.0
	_pending_game_delta_seconds = 0.0
	_sampling_elapsed_real_seconds = 0.0
	_last_game_time_seconds = _game_time_seconds()
	state_changed.emit(get_state_name())
	trolling_stopped.emit()


func set_debug_presentation_paused(paused: bool) -> void:
	_debug_presentation_paused = paused
	_last_game_time_seconds = _game_time_seconds()
	_sampling_elapsed_real_seconds = 0.0
	_pending_game_delta_seconds = 0.0


func begin_retrieval() -> bool:
	if state != State.HOOKED or pending_catch == null:
		return false
	state = State.RETRIEVING
	state_changed.emit(get_state_name())
	retrieval_started.emit(pending_catch.catch_id)
	return true


func cancel_pending_catch() -> bool:
	if pending_catch != null and pending_catch.fishing_method == "boat_fishing":
		return false
	if pending_catch == null:
		return false
	if _sabiki_batch_active:
		return false
	var was_boat_fishing := pending_catch.fishing_method == "boat_fishing"
	_cancel_pending("cancelled_by_operator")
	state = State.IDLE if was_boat_fishing else State.TROLLING
	state_changed.emit(get_state_name())
	return true


func begin_boat_fishing_session() -> String:
	if state == State.TROLLING or pending_catch != null or _sabiki_batch_active:
		return ""
	if _boat_fishing_session_active:
		end_boat_fishing_session("replaced")
	var world_seed := int(_manager.call("get_world_seed")) if _manager != null and _manager.has_method("get_world_seed") else 0
	_boat_fishing_session_id = "boat_fishing_%d_%06d" % [world_seed, _boat_fishing_session_sequence]
	_boat_fishing_session_sequence += 1
	_boat_fishing_cast_session_id = ""
	_boat_fishing_session_active = true
	_boat_fishing_initial_drop.clear()
	_boat_ambient_hazard_accumulated = 0.0
	_boat_ambient_hazard_threshold = _draw_ambient_hazard_threshold()
	_boat_ambient_event_rate_per_real_hour = 0.0
	_boat_ambient_mode_active = false
	_boat_ambient_last_trigger.clear()
	_boat_last_ambient_authority_result.clear()
	reset_boat_fishing_trigger_state(false)
	return _boat_fishing_session_id


## Called once when each deployed rig first becomes validly submerged. The
## 15 m query is diagnostic only; it never locks this cast to a school.
func begin_boat_fishing_cast_session(first_entry_world_position: Vector3, rig: BoatFishingRigProfile) -> Dictionary:
	if not _boat_fishing_session_active or rig == null:
		return {"accepted": false, "reason": "fishing_session_inactive"}
	_boat_fishing_cast_session_id = "%s_cast_%04d" % [_boat_fishing_session_id, _boat_fishing_cast_sequence]
	_boat_fishing_cast_sequence += 1
	var schools: Array[Dictionary] = []
	if _manager != null and _manager.has_method("get_schools_near"):
		schools = _manager.call("get_schools_near", first_entry_world_position, BOAT_FISHING_INITIAL_SCHOOL_SEARCH_RADIUS_M, true)
	var candidate_ids: Array[String] = []
	for school in schools:
		candidate_ids.append(str(school.get("school_id", "")))
	_boat_fishing_initial_drop = {
		"accepted": true,
		"fishing_session_id": _boat_fishing_session_id,
		"cast_session_id": _boat_fishing_cast_session_id,
		"first_entry_world_position": first_entry_world_position,
		"initial_search_radius_m": BOAT_FISHING_INITIAL_SCHOOL_SEARCH_RADIUS_M,
		"initial_candidate_school_count": candidate_ids.size(),
		"initial_candidate_school_ids": candidate_ids,
		"rig_id": str(rig.rig_id),
	}
	return _boat_fishing_initial_drop.duplicate(true)


func get_boat_fishing_session_snapshot() -> Dictionary:
	var active_ambient_fish := get_boat_fishing_ambient_catch_snapshots()
	return {
		"session_active": _boat_fishing_session_active,
		"fishing_session_id": _boat_fishing_session_id,
		"cast_session_id": _boat_fishing_cast_session_id,
		"first_entry": _boat_fishing_initial_drop.duplicate(true),
		"ambient_hazard_accumulated": _boat_ambient_hazard_accumulated,
		"ambient_hazard_threshold": _boat_ambient_hazard_threshold,
		"ambient_event_rate_per_real_hour": _boat_ambient_event_rate_per_real_hour,
		"ambient_average_wait_seconds": SECONDS_PER_REAL_HOUR / _boat_ambient_event_rate_per_real_hour if _boat_ambient_event_rate_per_real_hour > 0.0 else INF,
		"last_ambient_trigger": _boat_ambient_last_trigger.duplicate(true),
		"last_ambient_authority_result": _boat_last_ambient_authority_result.duplicate(true),
		"active_ambient_fish": active_ambient_fish,
	}


func set_boat_fishing_ambient_authority_result(result: Dictionary) -> void:
	_boat_last_ambient_authority_result = result.duplicate(true)


func end_boat_fishing_session(reason: String = "boat_fishing_ended") -> void:
	if _boat_fishing_session_active and _manager != null and _manager.has_method("release_ambient_fishing_session"):
		_manager.call("release_ambient_fishing_session", _boat_fishing_session_id, reason)
	_boat_fishing_session_active = false
	_boat_fishing_session_id = ""
	_boat_fishing_cast_session_id = ""
	_boat_fishing_initial_drop.clear()
	_boat_last_ambient_authority_result.clear()
	_boat_ambient_last_trigger.clear()
	reset_boat_fishing_trigger_state(true)


## Boat fishing uses the same school authority and encounter lifecycle as
## trolling. School targeting uses a species-specific 3D pursuit sphere around
## the current Authority activity center; the school movement ellipsoid remains
## diagnostic only and does not gate pursuit.
func evaluate_boat_fishing_candidates(
	lure_world_position: Vector3,
	lure_depth_m: float,
	lure_relative_speed_mps: float,
	rig: BoatFishingRigProfile,
	include_unavailable_for_diagnostics: bool = false,
	hook_index: int = 0
) -> Dictionary:
	var samples: Array[Dictionary] = []
	var targeted_candidates: Array[Dictionary] = []
	var ambient_candidates: Array[Dictionary] = []
	if _manager == null or rig == null or not _manager.has_method("get_schools_near"):
		return _empty_boat_bite_evaluation(lure_world_position, lure_depth_m, hook_index)
	var query_radius := BOAT_FISHING_DIAGNOSTIC_QUERY_RADIUS_M if include_unavailable_for_diagnostics else BOAT_FISHING_MAX_HORIZONTAL_RANGE_M
	var schools: Array[Dictionary] = _manager.call(
		"get_schools_near",
		lure_world_position,
		query_radius,
		true
	)
	var is_sabiki := rig.rig_type == BoatFishingRigProfile.RigType.SABIKI
	var action_weight := sabiki_action_weight(lure_relative_speed_mps, sabiki_min_action_weight, sabiki_max_action_weight, sabiki_action_reference_speed_mps) if is_sabiki else boat_fishing_action_weight(lure_relative_speed_mps, single_jig_min_action_weight, single_jig_max_action_weight, single_jig_action_reference_speed_mps)
	var action_qualified := is_sabiki or (is_finite(lure_relative_speed_mps) and lure_relative_speed_mps >= single_jig_target_min_motion_speed_mps)
	var target_zone_blocker: Dictionary = {}
	for school in schools:
		var species_id := str(school.get("species_id", ""))
		var school_id := str(school.get("school_id", ""))
		var profile := _manager.call("get_species_profile", species_id) as FishSpeciesProfile
		var population := int(school.get("population", 0))
		var school_position := _school_position(school)
		var horizontal_distance := Vector2(school_position.x - lure_world_position.x, school_position.z - lure_world_position.z).length()
		var target_activity_depth := maxf(0.0, float(school.get("effective_activity_depth_target_m", school.get("activity_depth_target_m", school.get("activity_depth_m", 0.0)))))
		var activity_depth := maxf(0.0, float(school.get("effective_activity_depth_m", target_activity_depth)))
		var activity_state := str(school.get("effective_surface_activity_state", school.get("surface_activity_state", "unknown")))
		var vertical_tolerance := clampf(profile.school_activity_radius_m * 0.7, 1.2, 3.0) if profile != null else 0.0
		var school_center_world := _school_activity_center_world(school_position, lure_world_position, activity_depth, lure_depth_m)
		var vertical_delta := absf(school_center_world.y - lure_world_position.y)
		var depth_weight := 1.0 - smoothstep(vertical_tolerance * 0.35, vertical_tolerance, vertical_delta) if vertical_tolerance > 0.0 else 0.0
		var horizontal_weight := boat_fishing_horizontal_distance_weight(horizontal_distance, boat_fishing_near_distance_full_weight_end_m, boat_fishing_middle_distance_end_m)
		var school_horizontal_radius := maxf(0.5, profile.school_wander_radius_m) if profile != null else 0.0
		var horizontal_normalized := horizontal_distance / school_horizontal_radius if school_horizontal_radius > 0.0 else INF
		var vertical_normalized := vertical_delta / vertical_tolerance if vertical_tolerance > 0.0 else INF
		var normalized_3d_distance := sqrt(horizontal_normalized * horizontal_normalized + vertical_normalized * vertical_normalized) if is_finite(horizontal_normalized) and is_finite(vertical_normalized) else INF
		var inside_school_volume := normalized_3d_distance <= 1.0 and horizontal_distance < BOAT_FISHING_MAX_HORIZONTAL_RANGE_M
		var pursuit_radius := maxf(0.1, profile.boat_fishing_pursuit_radius_m) if profile != null else 0.0
		var pursuit_distance := school_center_world.distance_to(lure_world_position) if profile != null else INF
		var pursuit_distance_ratio := pursuit_distance / pursuit_radius if pursuit_radius > 0.0 else INF
		var inside_pursuit_sphere := pursuit_distance <= pursuit_radius
		var zone := "core" if normalized_3d_distance <= 0.5 else ("edge" if inside_school_volume else "outside")
		var method_match := profile != null and profile.supported_fishing_methods.has("boat_fishing") and rig_matches_profile(profile, rig)
		var reserved_count := _get_reserved_sabiki_count_for_school(species_id, school_id) if is_sabiki else 0
		var population_available := maxi(0, population - reserved_count)
		var available := population_available > 0 and str(school.get("resource_state", "available")) == "available"
		var surface_multiplier := boat_fishing_surface_activity_multiplier(activity_state, activity_depth, profile, surface_activity_transition_depth_m, surface_transition_bite_multiplier, visible_surface_bite_multiplier)
		var bite_willingness := float(school.get("bite_willingness_multiplier", 1.0))
		if not is_finite(bite_willingness):
			bite_willingness = 1.0
		bite_willingness = clampf(bite_willingness, 0.0, 1.0)
		var base_rejection_reason := ""
		if profile == null:
			base_rejection_reason = "unknown_species"
		elif not method_match:
			base_rejection_reason = "method_or_rig_mismatch"
		elif not available:
			base_rejection_reason = "empty_school"
		elif not action_qualified:
			base_rejection_reason = "action_requirement_not_met"
		elif depth_weight <= 0.0:
			base_rejection_reason = "activity_depth_mismatch"
		elif horizontal_distance >= BOAT_FISHING_MAX_HORIZONTAL_RANGE_M:
			base_rejection_reason = "outside_horizontal_range"
		var target_reason := base_rejection_reason
		if target_reason.is_empty() and not inside_pursuit_sphere:
			target_reason = "outside_pursuit_sphere"
		var target_eligible := target_reason.is_empty()
		if inside_pursuit_sphere and target_zone_blocker.is_empty():
			target_zone_blocker = {"school_id": school_id, "species_id": species_id, "reason": base_rejection_reason if not base_rejection_reason.is_empty() else "school_target_zone_priority"}
		var candidate := {
			"school_id": school_id,
			"species_id": species_id,
			"rig_id": str(rig.rig_id),
			"rig_type": rig.rig_type,
			"population": population,
			"reserved_population": reserved_count,
			"available_population": population_available,
			"activity_state": activity_state,
			"activity_depth_target_m": target_activity_depth,
			"activity_depth_m": activity_depth,
			"effective_activity_depth_m": activity_depth,
			"disturbance_level": clampf(float(school.get("disturbance_level", 0.0)), 0.0, 1.0),
			"disturbance_target": clampf(float(school.get("disturbance_target", 0.0)), 0.0, 1.0),
			"disturbance_state": str(school.get("disturbance_state", "CALM")),
			"disturbance_horizontal_distance_m": float(school.get("disturbance_horizontal_distance_m", -1.0)),
			"disturbance_vertical_below_hull_m": float(school.get("disturbance_vertical_below_hull_m", -1.0)),
			"vessel_disturbance": clampf(float(school.get("vessel_disturbance", 0.0)), 0.0, 1.0),
			"bite_willingness_multiplier": bite_willingness,
			"lure_depth_m": maxf(0.0, lure_depth_m),
			"hook_world_position": lure_world_position,
			"horizontal_distance_m": horizontal_distance,
			"school_horizontal_radius_m": school_horizontal_radius,
			"school_center_world_position": school_center_world,
			"pursuit_radius_m": pursuit_radius,
			"pursuit_distance_m": pursuit_distance,
			"pursuit_distance_ratio": pursuit_distance_ratio,
			"inside_pursuit_sphere": inside_pursuit_sphere,
			"pursuit_eligibility": target_eligible,
			"pursuit_rejection_reason": target_reason,
			"horizontal_normalized_distance": horizontal_normalized,
			"horizontal_weight": horizontal_weight,
			"vertical_delta_m": vertical_delta,
			"vertical_tolerance_m": vertical_tolerance,
			"vertical_normalized_distance": vertical_normalized,
			"normalized_3d_distance": normalized_3d_distance,
			"depth_weight": depth_weight,
			"action_weight": action_weight,
			"action_qualified": action_qualified,
			"action_requirement_speed_mps": single_jig_target_min_motion_speed_mps if not is_sabiki else 0.0,
			"surface_activity_multiplier": surface_multiplier,
			"event_rate_per_real_hour": 0.0,
			"school_zone": zone,
			"inside_school_volume": inside_school_volume,
			"method_match": method_match,
			"depth_match": depth_weight > 0.0,
			"available": available,
			"target_eligible": target_eligible,
			"target_zone_blocker": inside_pursuit_sphere,
			"ambient_eligible": false,
			"rejection_reason": "" if target_eligible else (target_reason if not target_reason.is_empty() else base_rejection_reason),
			"target_rejection_reason": target_reason,
			"ambient_rejection_reason": "school_target_zone_priority" if inside_pursuit_sphere else "environment_authority_query_required",
			"hook_index": hook_index,
		}
		samples.append(candidate)
		if target_eligible:
			targeted_candidates.append(candidate)
	var ambient_evaluation: Dictionary = {"candidates": [], "reason": "", "environment_quality": 0.0}
	var ambient_context := _build_boat_ambient_context(lure_world_position, lure_depth_m, lure_relative_speed_mps, rig, hook_index, action_weight, action_qualified)
	var submerged := lure_depth_m >= 0.05
	var ambient_blocked_by_school := not target_zone_blocker.is_empty()
	if targeted_candidates.is_empty() and not ambient_blocked_by_school and submerged and _boat_fishing_session_active and _manager.has_method("evaluate_ambient_fishing_candidates"):
		ambient_evaluation = _manager.call("evaluate_ambient_fishing_candidates", ambient_context)
		for row_variant in ambient_evaluation.get("candidates", []):
			if row_variant is Dictionary:
				var ambient_row: Dictionary = row_variant.duplicate(true)
				ambient_row["hook_index"] = hook_index
				ambient_row["ambient_context"] = ambient_context.duplicate(true)
				ambient_candidates.append(ambient_row)
	var ambient_rate := _ambient_rate_for_candidates(ambient_candidates, float(ambient_evaluation.get("environment_quality", 0.0)))
	var trigger_mode := "SCHOOL_TARGETED" if not targeted_candidates.is_empty() else ("BLOCKED" if ambient_blocked_by_school else ("AMBIENT_ENCOUNTER" if not ambient_candidates.is_empty() else "NONE"))
	var reason := "target_reaction_waiting"
	if targeted_candidates.is_empty():
		if ambient_blocked_by_school:
			reason = str(target_zone_blocker.get("reason", "school_target_zone_blocked"))
		elif not submerged:
			reason = "hook_not_submerged"
		elif not _boat_fishing_session_active:
			reason = "fishing_session_inactive"
		elif ambient_candidates.is_empty():
			reason = str(ambient_evaluation.get("reason", "no_legal_species"))
		else:
			reason = "ambient_random_waiting"
	return {
		"candidate_schools": samples,
		"school_targeted_candidates": targeted_candidates,
		"ambient_candidates": ambient_candidates,
		"ambient_evaluation": ambient_evaluation,
		"ambient_context": ambient_context,
		"ambient_environment_quality": float(ambient_evaluation.get("environment_quality", 0.0)),
		"target_zone_blocker": target_zone_blocker.duplicate(true),
		"ambient_blocked_by_school": ambient_blocked_by_school,
		"valid_candidates": targeted_candidates if not targeted_candidates.is_empty() else ambient_candidates,
		"candidate_school_count": samples.size(),
		"targeted_candidate_count": targeted_candidates.size(),
		"ambient_candidate_count": ambient_candidates.size(),
		"valid_candidate_count": targeted_candidates.size() if not targeted_candidates.is_empty() else ambient_candidates.size(),
		"trigger_mode": trigger_mode,
		"total_event_rate_per_real_hour": ambient_rate if targeted_candidates.is_empty() else 0.0,
		"ambient_event_rate_per_real_hour": ambient_rate,
		"average_wait_seconds": SECONDS_PER_REAL_HOUR / ambient_rate if ambient_rate > 0.0 else INF,
		"lure_world_position": lure_world_position,
		"lure_depth_m": lure_depth_m,
		"lure_relative_speed_mps": lure_relative_speed_mps,
		"action_weight": action_weight,
		"action_qualified": action_qualified,
		"hook_index": hook_index,
		"query_radius_m": query_radius,
		"reason": reason if reason != "" else _boat_candidate_reason(samples, targeted_candidates, action_qualified),
	}


func _empty_boat_bite_evaluation(lure_world_position: Vector3, lure_depth_m: float, hook_index: int) -> Dictionary:
	return {
		"candidate_schools": [],
		"school_targeted_candidates": [],
		"ambient_candidates": [],
		"valid_candidates": [],
		"candidate_school_count": 0,
		"targeted_candidate_count": 0,
		"ambient_candidate_count": 0,
		"valid_candidate_count": 0,
		"trigger_mode": "NONE",
		"total_event_rate_per_real_hour": 0.0,
		"ambient_event_rate_per_real_hour": 0.0,
		"average_wait_seconds": INF,
		"lure_world_position": lure_world_position,
		"lure_depth_m": lure_depth_m,
		"hook_index": hook_index,
		"reason": "no_nearby_schools",
	}


func _boat_candidate_reason(samples: Array[Dictionary], targeted: Array[Dictionary], action_qualified: bool) -> String:
	if not targeted.is_empty():
		return "target_reaction_waiting"
	if samples.is_empty():
		return "no_nearby_schools"
	for reason in ["method_or_rig_mismatch", "empty_school", "activity_depth_mismatch", "action_requirement_not_met", "outside_pursuit_sphere", "outside_horizontal_range", "unknown_species"]:
		for candidate in samples:
			if str(candidate.get("rejection_reason", "")) == reason:
				return reason
	return "action_requirement_not_met" if not action_qualified else "no_valid_candidate"


func _build_boat_ambient_context(hook_position: Vector3, hook_depth: float, relative_speed: float, rig: BoatFishingRigProfile, hook_index: int, action_weight: float, action_qualified: bool) -> Dictionary:
	var water_column := 0.0
	if _bathymetry != null and _bathymetry.has_method("get_depth_at_world_position"):
		var seabed: Dictionary = _bathymetry.call("get_depth_at_world_position", hook_position, false)
		if bool(seabed.get("valid", false)):
			var surface_height := 0.0
			if _wave_sampler != null and is_instance_valid(_wave_sampler) and _wave_sampler.has_method("sample_physics_surface"):
				var sample_time := float(_wave_sampler.call("get_effective_wave_time_seconds")) if _wave_sampler.has_method("get_effective_wave_time_seconds") else 0.0
				var water: Dictionary = _wave_sampler.call("sample_physics_surface", hook_position, sample_time)
				surface_height = float(water.get("height", 0.0))
			water_column = maxf(0.0, float(seabed.get("depth_m", 0.0)) + surface_height)
	var outward_direction := Vector3.ZERO
	if _boat != null and is_instance_valid(_boat):
		outward_direction = Vector3(hook_position.x - _boat.global_position.x, 0.0, hook_position.z - _boat.global_position.z)
	return {
		"hook_world_position": hook_position,
		"hook_depth_m": maxf(0.0, hook_depth),
		"water_column_m": water_column,
		"relative_speed_mps": maxf(0.0, relative_speed) if is_finite(relative_speed) else 0.0,
		"action_weight": action_weight,
		"action_qualified": action_qualified,
		"rig_id": str(rig.rig_id),
		"rig_type": "sabiki" if rig.rig_type == BoatFishingRigProfile.RigType.SABIKI else "single_jig",
		"rig_compatible_species_ids": rig.compatible_species_ids,
		"rig_compatible_lure_tags": rig.compatible_lure_tags,
		"hook_index": hook_index,
		"ambient_spawn_direction": outward_direction,
		"fishing_session_id": _boat_fishing_session_id,
		"cast_session_id": _boat_fishing_cast_session_id,
	}


func _ambient_rate_for_candidates(candidates: Array[Dictionary], environment_quality: float) -> float:
	if candidates.is_empty() or environment_quality <= 0.0:
		return 0.0
	var species_ids: Dictionary = {}
	for candidate in candidates:
		species_ids[str(candidate.get("species_id", ""))] = true
	var density_factor := minf(boat_fishing_ambient_density_factor_cap, 1.0 + 0.10 * log(float(maxi(species_ids.size(), 1))) / log(2.0))
	return minf(boat_fishing_ambient_max_event_rate_per_tackle_hour, boat_fishing_ambient_base_event_rate_per_real_hour * clampf(environment_quality, 0.0, 1.0) * density_factor)


func _school_activity_center_world(school_position: Vector3, hook_position: Vector3, activity_depth_m: float, fallback_hook_depth_m: float) -> Vector3:
	var center_y := hook_position.y + (maxf(0.0, fallback_hook_depth_m) - maxf(0.0, activity_depth_m))
	if _wave_sampler != null and is_instance_valid(_wave_sampler) and _wave_sampler.has_method("sample_physics_surface"):
		var sample_position := Vector3(school_position.x, hook_position.y, school_position.z)
		var sample_time := float(_wave_sampler.call("get_effective_wave_time_seconds")) if _wave_sampler.has_method("get_effective_wave_time_seconds") else float(_wave_sampler.get("wave_time_seconds"))
		var surface: Dictionary = _wave_sampler.call("sample_physics_surface", sample_position, sample_time)
		if bool(surface.get("valid", true)):
			center_y = float(surface.get("height", hook_position.y)) - maxf(0.0, activity_depth_m)
	return Vector3(school_position.x, center_y, school_position.z)


static func boat_fishing_action_weight(lure_relative_speed_mps: float, min_weight: float = 0.55, max_weight: float = 1.0, reference_speed_mps: float = 2.5) -> float:
	if not is_finite(lure_relative_speed_mps):
		return clampf(min_weight, 0.0, 1.0)
	var lower := clampf(min_weight, 0.0, 1.0)
	var upper := maxf(lower, clampf(max_weight, 0.0, 1.0))
	return lerpf(lower, upper, clampf(lure_relative_speed_mps / maxf(reference_speed_mps, 0.1), 0.0, 1.0))


static func sabiki_action_weight(tackle_relative_speed_mps: float, min_weight: float = 0.8, max_weight: float = 1.0, reference_speed_mps: float = 2.5) -> float:
	if not is_finite(tackle_relative_speed_mps):
		return clampf(min_weight, 0.0, 1.0)
	var lower := clampf(min_weight, 0.0, 1.0)
	var upper := maxf(lower, clampf(max_weight, 0.0, 1.0))
	return lerpf(lower, upper, clampf(tackle_relative_speed_mps / maxf(reference_speed_mps, 0.1), 0.0, 1.0))


static func boat_fishing_horizontal_distance_weight(distance_m: float, near_distance_full_weight_end_m: float = 20.0, middle_distance_end_m: float = 35.0) -> float:
	if not is_finite(distance_m) or distance_m >= BOAT_FISHING_MAX_HORIZONTAL_RANGE_M:
		return 0.0
	var distance := maxf(distance_m, 0.0)
	if distance <= 10.0:
		return 1.0
	var near_end := clampf(near_distance_full_weight_end_m, 10.0, 25.0)
	var middle_end := clampf(middle_distance_end_m, near_end + 0.1, 45.0)
	if distance <= near_end:
		return lerpf(1.0, 0.70, (distance - 10.0) / maxf(near_end - 10.0, 0.1))
	if distance <= middle_end:
		return lerpf(0.70, 0.25, (distance - near_end) / maxf(middle_end - near_end, 0.1))
	return lerpf(0.25, 0.0, (distance - middle_end) / maxf(BOAT_FISHING_MAX_HORIZONTAL_RANGE_M - middle_end, 0.1))


static func boat_fishing_surface_activity_multiplier(activity_state: String, activity_depth_m: float, profile: FishSpeciesProfile, transition_depth_m: float = 6.0, transition_multiplier: float = 1.2, visible_multiplier: float = 1.6) -> float:
	if profile == null or not profile.surface_activity_cycle_enabled:
		return 1.0
	var depth := maxf(0.0, activity_depth_m)
	var logical_surface_limit := minf(transition_depth_m, profile.logical_depth_threshold_m)
	if profile.is_surface_activity_visually_indicated(activity_state, depth):
		return maxf(1.0, visible_multiplier)
	if activity_state in ["near_surface", "ascending", "descending"] and depth <= logical_surface_limit:
		return maxf(1.0, transition_multiplier)
	return 1.0


static func rig_matches_profile(profile: FishSpeciesProfile, rig: BoatFishingRigProfile) -> bool:
	if profile == null or rig == null:
		return false
	if not rig.compatible_species_ids.is_empty():
		return rig.compatible_species_ids.has(profile.species_id)
	if rig.compatible_lure_tags.is_empty():
		return false
	for tag in rig.compatible_lure_tags:
		if profile.compatible_lure_tags.has(tag):
			return true
	return false


## Boat fishing has two mutually exclusive natural bite modes. A hook inside a
## compatible school's 3D activity volume gets a short deterministic reaction
## window; only hooks outside all such volumes accrue the ambient real-time hazard.
func advance_boat_fishing_trigger_for_hook(diagnostics: Dictionary, delta_real_seconds: float, hook_index: int) -> Dictionary:
	var key := str(hook_index)
	if hook_index < 0 or not is_finite(delta_real_seconds) or delta_real_seconds < 0.0:
		return _store_boat_trigger_debug(key, {"trigger_mode": "NONE", "phase": "inactive", "reason": "invalid_input"})
	if state not in [State.IDLE, State.SETTLED] or pending_catch != null:
		return _store_boat_trigger_debug(key, {"trigger_mode": "NONE", "phase": "inactive", "reason": "encounter_busy"})
	var samples: Array = diagnostics.get("candidate_schools", [])
	var targeted: Array[Dictionary] = _dictionary_array(diagnostics.get("school_targeted_candidates", []))
	var reaction: Dictionary = _boat_target_reactions.get(key, {})
	var target: Dictionary = _select_target_candidate(targeted, str(reaction.get("school_id", "")))
	if not target.is_empty():
		if reaction.is_empty() or str(reaction.get("school_id", "")) != str(target.get("school_id", "")):
			reaction = _create_target_reaction(target, hook_index)
		reaction["outside_seconds"] = 0.0
		reaction["candidate"] = target.duplicate(true)
		var willingness := clampf(float(target.get("bite_willingness_multiplier", 1.0)), 0.0, 1.0)
		reaction["remaining_seconds"] = maxf(0.0, float(reaction.get("remaining_seconds", 0.0)) - delta_real_seconds * willingness)
		_boat_target_reactions[key] = reaction
		var target_snapshot := _target_reaction_snapshot(reaction, hook_index)
		if float(reaction.get("remaining_seconds", 0.0)) <= 0.0:
			_boat_target_reactions.erase(key)
			var triggered := target.duplicate(true)
			triggered["trigger_mode"] = "SCHOOL_TARGETED"
			triggered["reaction_total_seconds"] = float(reaction.get("total_seconds", 0.0))
			triggered["reaction_remaining_seconds"] = 0.0
			target_snapshot.merge({"phase": "triggered", "reason": "target_reaction_complete", "candidate": triggered}, true)
			return _store_boat_trigger_debug(key, target_snapshot)
		target_snapshot["reason"] = "target_reaction_waiting"
		return _store_boat_trigger_debug(key, target_snapshot)

	if not reaction.is_empty():
		var retained := _find_school_candidate(samples, str(reaction.get("school_id", "")))
		if _candidate_can_hold_target(retained):
			reaction["outside_seconds"] = 0.0 if bool(retained.get("target_eligible", false)) else float(reaction.get("outside_seconds", 0.0)) + delta_real_seconds
			reaction["candidate"] = retained.duplicate(true)
			var retained_willingness := clampf(float(retained.get("bite_willingness_multiplier", 1.0)), 0.0, 1.0)
			reaction["remaining_seconds"] = maxf(0.0, float(reaction.get("remaining_seconds", 0.0)) - delta_real_seconds * retained_willingness)
			if float(reaction.get("outside_seconds", 0.0)) <= boat_fishing_target_boundary_grace_seconds:
				_boat_target_reactions[key] = reaction
				var held_snapshot := _target_reaction_snapshot(reaction, hook_index)
				held_snapshot["reason"] = "target_boundary_hold"
				if float(reaction.get("remaining_seconds", 0.0)) <= 0.0:
					_boat_target_reactions.erase(key)
					var held_candidate: Dictionary = retained.duplicate(true)
					held_candidate["trigger_mode"] = "SCHOOL_TARGETED"
					held_candidate["reaction_total_seconds"] = float(reaction.get("total_seconds", 0.0))
					held_candidate["reaction_remaining_seconds"] = 0.0
					held_snapshot.merge({"phase": "triggered", "reason": "target_reaction_complete", "candidate": held_candidate}, true)
					return _store_boat_trigger_debug(key, held_snapshot)
				return _store_boat_trigger_debug(key, held_snapshot)
		_boat_target_reactions.erase(key)
		return _store_boat_trigger_debug(key, {
			"trigger_mode": "NONE",
			"phase": "ineligible",
			"reason": str(diagnostics.get("reason", "no_valid_candidate")),
			"candidate": {},
			"hook_index": hook_index,
		})
	return _store_boat_trigger_debug(key, {"trigger_mode": "NONE", "phase": "ineligible", "reason": str(diagnostics.get("reason", "no_valid_candidate")), "hook_index": hook_index})


## One activity-session hazard is shared by every ambient-eligible empty hook.
## School-targeted or blocked hooks are excluded before this aggregate step.
func advance_boat_fishing_ambient_hazard(evaluations: Array[Dictionary], delta_real_seconds: float) -> Dictionary:
	if not _boat_fishing_session_active or not is_finite(delta_real_seconds) or delta_real_seconds < 0.0:
		return {"trigger_mode": "NONE", "phase": "inactive", "reason": "fishing_session_inactive", "ambient_event_rate_per_real_hour": 0.0}
	var eligible_hooks: Array[Dictionary] = []
	var best_hook_rate := 0.0
	var targeted_or_blocked := false
	for evaluation in evaluations:
		if not evaluation.is_empty() and (not _dictionary_array(evaluation.get("school_targeted_candidates", [])).is_empty() or bool(evaluation.get("ambient_blocked_by_school", false))):
			targeted_or_blocked = true
		if bool(evaluation.get("trigger_locked", false)):
			targeted_or_blocked = true
			continue
		var candidates: Array[Dictionary] = _dictionary_array(evaluation.get("ambient_candidates", []))
		if candidates.is_empty():
			continue
		var quality := maxf(0.0, float(evaluation.get("ambient_environment_quality", 0.0)))
		if quality <= 0.0:
			continue
		eligible_hooks.append({"hook_index": int(evaluation.get("hook_index", -1)), "candidates": candidates, "quality": quality, "context": evaluation.get("ambient_context", {}).duplicate(true)})
		var hook_species_ids: Dictionary = {}
		for candidate in candidates:
			hook_species_ids[str(candidate.get("species_id", ""))] = true
		var density_factor := minf(boat_fishing_ambient_density_factor_cap, 1.0 + 0.10 * log(float(maxi(hook_species_ids.size(), 1))) / log(2.0))
		best_hook_rate = maxf(best_hook_rate, boat_fishing_ambient_base_event_rate_per_real_hour * quality * density_factor)
	if eligible_hooks.is_empty():
		if targeted_or_blocked and (_boat_ambient_mode_active or _boat_ambient_hazard_accumulated > 0.0):
			_reset_boat_ambient_hazard()
		_boat_ambient_mode_active = false
		_boat_ambient_event_rate_per_real_hour = 0.0
		return {
			"trigger_mode": "BLOCKED" if targeted_or_blocked else "NONE",
			"phase": "school_priority" if targeted_or_blocked else "ineligible",
			"reason": "school_target_zone_priority" if targeted_or_blocked else "no_ambient_species_or_submerged_hook",
			"ambient_event_rate_per_real_hour": 0.0,
			"average_wait_seconds": INF,
			"hazard_accumulated": _boat_ambient_hazard_accumulated,
			"hazard_threshold": _boat_ambient_hazard_threshold,
		}
	var ambient_rate := minf(boat_fishing_ambient_max_event_rate_per_tackle_hour, best_hook_rate)
	if ambient_rate <= 0.0:
		_boat_ambient_event_rate_per_real_hour = 0.0
		return {"trigger_mode": "NONE", "phase": "ineligible", "reason": "zero_environment_rate", "ambient_event_rate_per_real_hour": 0.0}
	_boat_ambient_mode_active = true
	_boat_ambient_event_rate_per_real_hour = ambient_rate
	_boat_ambient_hazard_accumulated += ambient_rate * delta_real_seconds / SECONDS_PER_REAL_HOUR
	var average_wait := SECONDS_PER_REAL_HOUR / ambient_rate
	if _boat_ambient_hazard_accumulated < _boat_ambient_hazard_threshold:
		return {
			"trigger_mode": "AMBIENT_ENCOUNTER",
			"phase": "ambient_waiting",
			"reason": "random_not_triggered",
			"ambient_event_rate_per_real_hour": ambient_rate,
			"average_wait_seconds": average_wait,
			"hazard_accumulated": _boat_ambient_hazard_accumulated,
			"hazard_threshold": _boat_ambient_hazard_threshold,
			"eligible_hook_count": eligible_hooks.size(),
			"eligible_species_count": _maximum_hook_species_count(eligible_hooks),
		}
	var hook_scores: Array[Dictionary] = []
	for hook in eligible_hooks:
		var score := 0.0
		for candidate in hook["candidates"]:
			score += maxf(0.0, float(candidate.get("ecological_weight", 0.0)))
		hook_scores.append({"hook": hook, "weight": maxf(score, 0.001)})
	var selected_hook := _weighted_dictionary(hook_scores)
	var selected_context: Dictionary = selected_hook.get("context", {})
	var selected_hook_index := int(selected_hook.get("hook_index", -1))
	_reset_boat_ambient_hazard()
	var trigger := {
		"trigger_mode": "AMBIENT_ENCOUNTER",
		"phase": "triggered",
		"reason": "ambient_hazard_triggered",
		"ambient_event_rate_per_real_hour": ambient_rate,
		"average_wait_seconds": average_wait,
		"eligible_hook_count": eligible_hooks.size(),
		"eligible_species_count": _maximum_hook_species_count(eligible_hooks),
		"hook_index": selected_hook_index,
		"ambient_context": selected_context.duplicate(true),
		"fishing_session_id": _boat_fishing_session_id,
		"cast_session_id": _boat_fishing_cast_session_id,
	}
	_boat_ambient_last_trigger = trigger.duplicate(true)
	return trigger


func _maximum_hook_species_count(eligible_hooks: Array[Dictionary]) -> int:
	var maximum := 0
	for hook in eligible_hooks:
		var species_ids: Dictionary = {}
		for candidate in hook.get("candidates", []):
			species_ids[str(candidate.get("species_id", ""))] = true
		maximum = maxi(maximum, species_ids.size())
	return maximum


func _weighted_dictionary(rows: Array[Dictionary]) -> Dictionary:
	var total := 0.0
	for row in rows:
		total += maxf(0.0, float(row.get("weight", 0.0)))
	if total <= 0.0:
		return rows[0].get("hook", {}) if not rows.is_empty() else {}
	var roll := _boat_rng.randf() * total
	for row in rows:
		roll -= maxf(0.0, float(row.get("weight", 0.0)))
		if roll <= 0.0:
			return row.get("hook", {})
	return rows.back().get("hook", {})


func _create_target_reaction(candidate: Dictionary, hook_index: int) -> Dictionary:
	# Response time changes continuously with distance inside the one pursuit
	# sphere; no second inner/outer eligibility zone is introduced.
	var distance_ratio := clampf(float(candidate.get("pursuit_distance_ratio", 1.0)), 0.0, 1.0)
	var minimum := lerpf(boat_fishing_target_core_min_reaction_seconds, boat_fishing_target_edge_min_reaction_seconds, distance_ratio)
	var maximum := maxf(minimum, lerpf(boat_fishing_target_core_max_reaction_seconds, boat_fishing_target_edge_max_reaction_seconds, distance_ratio))
	var variation := _stable_target_variation(candidate, hook_index)
	var total_seconds := lerpf(minimum, maximum, variation)
	var approach_seconds := _estimate_existing_bite_approach_seconds(candidate, hook_index)
	var pre_approach_seconds := maxf(0.0, total_seconds - approach_seconds)
	return {
		"school_id": str(candidate.get("school_id", "")),
		"candidate": candidate.duplicate(true),
		"remaining_seconds": pre_approach_seconds,
		"total_seconds": total_seconds,
		"approach_seconds": approach_seconds,
		"outside_seconds": 0.0,
		"hook_index": hook_index,
		"zone": str(candidate.get("school_zone", "edge")),
	}


func _stable_target_variation(candidate: Dictionary, hook_index: int) -> float:
	var stable_seed := str(candidate.get("school_id", "")).hash() ^ ((hook_index + 1) * 73856093) ^ (_boat_target_session_epoch * 19349663)
	return float(absi(stable_seed) % 100000) / 99999.0


func _estimate_existing_bite_approach_seconds(candidate: Dictionary, hook_index: int) -> float:
	var species_id := str(candidate.get("species_id", ""))
	var profile := _manager.call("get_species_profile", species_id) as FishSpeciesProfile if _manager != null and _manager.has_method("get_species_profile") else null
	if profile == null:
		return 0.0
	var center_value: Variant = candidate.get("school_center_world_position", Vector3.ZERO)
	var hook_value: Variant = candidate.get("hook_world_position", Vector3.ZERO)
	var center := center_value as Vector3 if center_value is Vector3 else Vector3.ZERO
	var hook := hook_value as Vector3 if hook_value is Vector3 else Vector3.ZERO
	var core_radius := maxf(0.0, float(candidate.get("school_horizontal_radius_m", profile.school_wander_radius_m)))
	var start_offset := minf(core_radius * 0.2, 1.0)
	var start_distance := maxf(0.0, center.distance_to(hook) - start_offset)
	var speed := maxf(0.1, (profile.movement_speed_min_mps + profile.movement_speed_max_mps) * 0.5)
	return start_distance / speed


func _select_target_candidate(candidates: Array[Dictionary], preferred_school_id: String) -> Dictionary:
	for candidate in candidates:
		if str(candidate.get("school_id", "")) == preferred_school_id and bool(candidate.get("target_eligible", false)):
			return candidate
	var best: Dictionary = {}
	var best_distance := INF
	for candidate in candidates:
		var distance := float(candidate.get("pursuit_distance_m", INF))
		if distance < best_distance:
			best_distance = distance
			best = candidate
	return best


func _find_school_candidate(candidates: Array, school_id: String) -> Dictionary:
	for value in candidates:
		if value is Dictionary and str(value.get("school_id", "")) == school_id:
			return value
	return {}


func _candidate_can_hold_target(candidate: Dictionary) -> bool:
	return not candidate.is_empty() \
		and bool(candidate.get("method_match", false)) \
		and bool(candidate.get("available", false)) \
		and float(candidate.get("depth_weight", 0.0)) > 0.0 \
		and float(candidate.get("pursuit_distance_m", INF)) <= float(candidate.get("pursuit_radius_m", 0.0)) * boat_fishing_target_boundary_hysteresis


func _target_reaction_snapshot(reaction: Dictionary, hook_index: int) -> Dictionary:
	var candidate: Dictionary = reaction.get("candidate", {}).duplicate(true)
	candidate["trigger_mode"] = "SCHOOL_TARGETED"
	candidate["hook_index"] = hook_index
	return {
		"trigger_mode": "SCHOOL_TARGETED",
		"phase": "target_reaction",
		"reason": "target_reaction_waiting",
		"candidate": candidate.duplicate(true),
		"school_id": str(reaction.get("school_id", "")),
		"school_zone": str(reaction.get("zone", "edge")),
		"reaction_total_seconds": float(reaction.get("total_seconds", 0.0)),
		"reaction_remaining_seconds": float(reaction.get("remaining_seconds", 0.0)),
		"pre_approach_seconds": maxf(0.0, float(reaction.get("total_seconds", 0.0)) - float(reaction.get("approach_seconds", 0.0))),
		"visual_approach_estimate_seconds": float(reaction.get("approach_seconds", 0.0)),
		"hook_index": hook_index,
	}


func _dictionary_array(value: Variant) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if value is Array:
		for row in value:
			if row is Dictionary:
				result.append(row)
	return result


func _store_boat_trigger_debug(key: String, snapshot: Dictionary) -> Dictionary:
	_boat_trigger_debug_by_hook[key] = snapshot.duplicate(true)
	return snapshot


func get_boat_fishing_hook_trigger_debug(hook_index: int) -> Dictionary:
	return (_boat_trigger_debug_by_hook.get(str(hook_index), {}) as Dictionary).duplicate(true)


func clear_boat_fishing_hook_trigger_state(hook_index: int) -> void:
	var key := str(hook_index)
	_boat_target_reactions.erase(key)
	_boat_trigger_debug_by_hook.erase(key)


func reserve_sabiki_hook(candidate: Dictionary, rig: BoatFishingRigProfile, hook_index: int, debug_spawned: bool = false) -> FishingPendingCatch:
	if rig == null or rig.rig_type != BoatFishingRigProfile.RigType.SABIKI or hook_index < 0 or hook_index >= rig.hook_count or state not in [State.IDLE, State.SETTLED] or _sabiki_batch_active or pending_catch != null:
		return null
	if _sabiki_hook_catches.size() >= mini(rig.maximum_catch_count, rig.hook_count):
		return null
	var species_id := str(candidate.get("species_id", ""))
	var profile := _manager.call("get_species_profile", species_id) as FishSpeciesProfile if _manager != null else null
	if profile == null or not profile.supported_fishing_methods.has("boat_fishing") or not rig_matches_profile(profile, rig):
		return null
	for existing in _sabiki_hook_catches:
		if existing.hook_index == hook_index:
			return null
	var school_id := "" if debug_spawned else str(candidate.get("school_id", ""))
	if not debug_spawned:
		var school: Dictionary = _manager.call("get_school", school_id)
		if school.is_empty() or str(school.get("species_id", "")) != species_id or str(school.get("resource_state", "available")) != "available":
			return null
		if int(school.get("population", 0)) - _get_reserved_sabiki_count_for_school(species_id, school_id) <= 0:
			return null
	var pending := FishingPendingCatch.new()
	pending.catch_id = "sabiki_catch_%d_%06d" % [int(_manager.call("get_world_seed")), _next_catch_sequence]
	_next_catch_sequence += 1
	pending.species_id = species_id
	pending.school_id = school_id
	pending.source_type = "debug" if debug_spawned else "school"
	pending.lure_id = str(rig.rig_id)
	pending.fishing_method = "boat_fishing"
	pending.debug_spawned = debug_spawned
	pending.rig_id = str(rig.rig_id)
	pending.hook_index = hook_index
	pending.hooked_game_time_seconds = _game_time_seconds()
	pending.body_length_m = _boat_length_rng.randf_range(profile.body_length_range_m.x, profile.body_length_range_m.y)
	_sabiki_hook_catches.append(pending)
	return pending


## Requests a real temporary natural individual from the configured authority.
## The authority owns species/length selection and the ambient reservation.
func request_ambient_boat_fishing_catch(context: Dictionary, rig: BoatFishingRigProfile) -> Dictionary:
	if rig == null or not _boat_fishing_session_active or _manager == null or not _manager.has_method("request_ambient_fish_encounter"):
		return {"accepted": false, "reason": "ambient_session_or_authority_unavailable"}
	var hook_index := int(context.get("hook_index", -1))
	var cast_session_id := str(context.get("cast_session_id", ""))
	if hook_index < 0 or str(context.get("fishing_session_id", "")) != _boat_fishing_session_id or _boat_fishing_cast_session_id.is_empty() or cast_session_id != _boat_fishing_cast_session_id:
		return {"accepted": false, "reason": "ambient_session_or_hook_mismatch"}
	if rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
		if _sabiki_batch_active or pending_catch != null or _sabiki_hook_catches.size() >= mini(rig.maximum_catch_count, rig.hook_count):
			return {"accepted": false, "reason": "encounter_busy_or_rig_full"}
		for existing in _sabiki_hook_catches:
			if existing.hook_index == hook_index:
				return {"accepted": false, "reason": "hook_already_reserved"}
	else:
		if state not in [State.IDLE, State.SETTLED] or pending_catch != null:
			return {"accepted": false, "reason": "encounter_busy"}
	var authority_result: Dictionary = _manager.call("request_ambient_fish_encounter", context)
	_boat_last_ambient_authority_result = authority_result.duplicate(true)
	if not bool(authority_result.get("accepted", false)):
		return {"accepted": false, "reason": str(authority_result.get("reason", "ambient_authority_rejected")), "authority_result": authority_result}
	var fish: Dictionary = authority_result.get("fish", {})
	var species_id := str(fish.get("species_id", ""))
	var ambient_fish_id := str(fish.get("ambient_fish_id", ""))
	var profile := _manager.call("get_species_profile", species_id) as FishSpeciesProfile
	if fish.is_empty() or profile == null or ambient_fish_id.is_empty():
		if not ambient_fish_id.is_empty() and _manager.has_method("release_ambient_fish_encounter"):
			_manager.call("release_ambient_fish_encounter", ambient_fish_id, "invalid_authority_fish_record")
		return {"accepted": false, "reason": "invalid_ambient_authority_record", "authority_result": authority_result}
	var pending := FishingPendingCatch.new()
	pending.catch_id = "boat_ambient_catch_%d_%06d" % [int(_manager.call("get_world_seed")), _next_catch_sequence]
	_next_catch_sequence += 1
	pending.species_id = species_id
	pending.school_id = ""
	pending.source_type = "ambient"
	pending.ambient_fish_id = ambient_fish_id
	pending.lure_id = str(rig.rig_id)
	pending.fishing_method = "boat_fishing"
	pending.rig_id = str(rig.rig_id)
	pending.hook_index = hook_index
	pending.body_length_m = float(fish.get("body_length_m", 0.0))
	pending.hooked_game_time_seconds = _game_time_seconds()
	var candidate := fish.duplicate(true)
	candidate["source_type"] = "ambient"
	candidate["activity_depth_m"] = float(context.get("hook_depth_m", 0.0))
	candidate["lure_depth_m"] = float(context.get("hook_depth_m", 0.0))
	candidate["hook_world_position"] = context.get("hook_world_position", Vector3.ZERO)
	candidate["hook_index"] = hook_index
	candidate["rig_type"] = rig.rig_type
	if rig.rig_type == BoatFishingRigProfile.RigType.SABIKI:
		_sabiki_hook_catches.append(pending)
	else:
		pending_catch = pending
		state = State.BOAT_BITE_APPROACH
		state_changed.emit(get_state_name())
	return {"accepted": true, "pending": pending, "candidate": candidate, "authority_result": authority_result}


func confirm_sabiki_hook(catch_id: String) -> bool:
	for pending in _sabiki_hook_catches:
		if pending.catch_id != catch_id:
			continue
		if pending.hook_confirmed:
			return false
		if pending.source_type == "ambient":
			var confirmed := _manager != null and _manager.has_method("confirm_ambient_fish_encounter") and bool(_manager.call("confirm_ambient_fish_encounter", pending.ambient_fish_id, _boat_fishing_session_id, pending.hook_index))
			if not confirmed:
				release_sabiki_reservation(catch_id)
				return false
		elif pending.source_type == "school" and not pending.debug_spawned:
			var school: Dictionary = _manager.call("get_school", pending.school_id) if _manager != null else {}
			if school.is_empty() or str(school.get("species_id", "")) != pending.species_id or str(school.get("resource_state", "available")) != "available" or int(school.get("population", 0)) < _get_reserved_sabiki_count_for_school(pending.species_id, pending.school_id):
				release_sabiki_reservation(catch_id)
				return false
		pending.hook_confirmed = true
		pending.hooked_game_time_seconds = _game_time_seconds()
		return true
	return false


func release_sabiki_reservation(catch_id: String) -> bool:
	for index in range(_sabiki_hook_catches.size()):
		var pending := _sabiki_hook_catches[index]
		if pending.catch_id == catch_id and not pending.hook_confirmed:
			_sabiki_hook_catches.remove_at(index)
			_release_ambient_pending(pending, "reservation_released")
			return true
	return false


func get_sabiki_hook_catches() -> Array[FishingPendingCatch]:
	return _sabiki_hook_catches.duplicate()


func begin_sabiki_batch_retrieval() -> FishingPendingCatch:
	if _sabiki_batch_active or pending_catch != null or state not in [State.IDLE, State.SETTLED]:
		return null
	var confirmed: Array[FishingPendingCatch] = []
	for catch_record in _sabiki_hook_catches:
		if catch_record.hook_confirmed:
			confirmed.append(catch_record)
	if confirmed.is_empty():
		return null
	_sabiki_hook_catches = confirmed
	pending_catch = confirmed[0]
	_sabiki_batch_active = true
	_sabiki_batch_id = "sabiki_batch_%d_%06d" % [int(_manager.call("get_world_seed")), _next_catch_sequence]
	_next_catch_sequence += 1
	state = State.HOOKED
	state_changed.emit(get_state_name())
	fish_hooked.emit(pending_catch)
	return pending_catch


func cancel_sabiki_catches(reason: String = "sabiki_cancelled") -> bool:
	if _sabiki_hook_catches.is_empty() and not _sabiki_batch_active:
		return false
	var cancellation_ids: Array[String] = []
	if pending_catch != null and not pending_catch.catch_id.is_empty():
		cancellation_ids.append(pending_catch.catch_id)
	for catch_record in _sabiki_hook_catches:
		_release_ambient_pending(catch_record, reason)
		if not catch_record.catch_id.is_empty() and not cancellation_ids.has(catch_record.catch_id):
			cancellation_ids.append(catch_record.catch_id)
	_sabiki_hook_catches.clear()
	_sabiki_batch_active = false
	_sabiki_batch_id = ""
	pending_catch = null
	state = State.IDLE
	reset_boat_fishing_trigger_state()
	state_changed.emit(get_state_name())
	for cancellation_id in cancellation_ids:
		catch_cancelled.emit(cancellation_id, reason)
	return true


func get_sabiki_hooked_count() -> int:
	var count := 0
	for catch_record in _sabiki_hook_catches:
		if catch_record.hook_confirmed:
			count += 1
	return count


func _get_reserved_sabiki_count_for_school(species_id: String, school_id: String) -> int:
	var count := 0
	for catch_record in _sabiki_hook_catches:
		if catch_record.source_type == "school" and not catch_record.debug_spawned and catch_record.species_id == species_id and catch_record.school_id == school_id:
			count += 1
	return count


func _release_ambient_pending(pending: FishingPendingCatch, reason: String) -> void:
	if pending == null or pending.source_type != "ambient" or pending.ambient_fish_id.is_empty():
		return
	if _manager != null and _manager.has_method("release_ambient_fish_encounter"):
		_manager.call("release_ambient_fish_encounter", pending.ambient_fish_id, reason)


func get_boat_fishing_ambient_catch_snapshots() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if _boat_fishing_session_id.is_empty() or _manager == null or not _manager.has_method("get_ambient_fish_session_snapshot"):
		return result
	for record in _manager.call("get_ambient_fish_session_snapshot", _boat_fishing_session_id):
		if record is Dictionary:
			result.append(record.duplicate(true))
	return result


func reset_boat_fishing_trigger_state(clear_ambient_hazard: bool = false) -> void:
	if clear_ambient_hazard:
		_reset_boat_ambient_hazard()
	_boat_target_reactions.clear()
	_boat_trigger_debug_by_hook.clear()
	_boat_target_session_epoch += 1


func _reset_boat_ambient_hazard() -> void:
	_boat_ambient_hazard_accumulated = 0.0
	_boat_ambient_hazard_threshold = _draw_ambient_hazard_threshold()
	_boat_ambient_event_rate_per_real_hour = 0.0
	_boat_ambient_mode_active = false


## Reserves the confirmed school/catch inside this shared encounter before the
## shallow approach animation begins. No population is changed until landing.
func begin_boat_fishing_approach(candidate: Dictionary, debug_spawned: bool = false) -> FishingPendingCatch:
	if state not in [State.IDLE, State.SETTLED] or pending_catch != null:
		return null
	var species_id := str(candidate.get("species_id", ""))
	var profile := _manager.call("get_species_profile", species_id) as FishSpeciesProfile if _manager != null else null
	if profile == null or not profile.supported_fishing_methods.has("boat_fishing"):
		return null
	var school_id := "" if debug_spawned else str(candidate.get("school_id", ""))
	if not debug_spawned:
		var school: Dictionary = _manager.call("get_school", school_id)
		if school.is_empty() or int(school.get("population", 0)) <= 0 or str(school.get("resource_state", "available")) != "available" or str(school.get("species_id", "")) != species_id:
			return null
	var pending := FishingPendingCatch.new()
	pending.catch_id = "boat_catch_%d_%06d" % [int(_manager.call("get_world_seed")), _next_catch_sequence]
	_next_catch_sequence += 1
	pending.species_id = species_id
	pending.school_id = school_id
	pending.source_type = "debug" if debug_spawned else "school"
	pending.lure_id = "single_jig"
	pending.fishing_method = "boat_fishing"
	pending.rig_id = "single_jig"
	pending.hook_index = 0
	pending.debug_spawned = debug_spawned
	pending.hooked_game_time_seconds = _game_time_seconds()
	pending.body_length_m = _boat_length_rng.randf_range(profile.body_length_range_m.x, profile.body_length_range_m.y)
	pending_catch = pending
	state = State.BOAT_BITE_APPROACH
	state_changed.emit(get_state_name())
	return pending


func confirm_boat_fishing_bite() -> bool:
	if state != State.BOAT_BITE_APPROACH or pending_catch == null or pending_catch.fishing_method != "boat_fishing":
		return false
	if pending_catch.source_type == "ambient":
		var confirmed := _manager != null and _manager.has_method("confirm_ambient_fish_encounter") and bool(_manager.call("confirm_ambient_fish_encounter", pending_catch.ambient_fish_id, _boat_fishing_session_id, pending_catch.hook_index))
		if not confirmed:
			_cancel_pending("ambient_fish_unavailable_during_bite")
			state = State.IDLE
			state_changed.emit(get_state_name())
			return false
	elif pending_catch.source_type == "school" and not pending_catch.debug_spawned:
		var school: Dictionary = _manager.call("get_school", pending_catch.school_id) if _manager != null else {}
		if school.is_empty() or int(school.get("population", 0)) <= 0 or str(school.get("resource_state", "available")) != "available" or str(school.get("species_id", "")) != pending_catch.species_id:
			_cancel_pending("school_unavailable_during_bite")
			state = State.IDLE
			state_changed.emit(get_state_name())
			return false
	state = State.HOOKED
	pending_catch.hook_confirmed = true
	# The pending record begins at candidate reservation, but its hooked time is
	# the moment the fish actually reaches the lure after any shallow approach.
	pending_catch.hooked_game_time_seconds = _game_time_seconds()
	if pending_catch.source_type == "school" and not pending_catch.debug_spawned:
		_school_cooldown_until[pending_catch.school_id] = _game_time_seconds() + school_encounter_cooldown_game_seconds
	_hazard_accumulated = 0.0
	state_changed.emit(get_state_name())
	fish_hooked.emit(pending_catch)
	return true


func cancel_boat_fishing_catch(reason: String = "boat_fishing_cancelled") -> bool:
	if _sabiki_batch_active or not _sabiki_hook_catches.is_empty():
		return cancel_sabiki_catches(reason)
	if pending_catch == null or pending_catch.fishing_method != "boat_fishing":
		return false
	_cancel_pending(reason)
	state = State.IDLE
	reset_boat_fishing_trigger_state()
	state_changed.emit(get_state_name())
	return true


func complete_retrieval(catch_id: String = "") -> Dictionary:
	if state != State.RETRIEVING or pending_catch == null:
		return {"accepted": false, "reason": "no_retrieval_pending"}
	if not catch_id.is_empty() and catch_id != pending_catch.catch_id:
		return {"accepted": false, "reason": "catch_id_mismatch"}
	if _sabiki_batch_active:
		return _complete_sabiki_batch_retrieval()
	if _settled_catch_ids.has(pending_catch.catch_id):
		return {"accepted": false, "reason": "catch_already_settled"}
	var catch_record := pending_catch
	var debug_spawned := catch_record.debug_spawned
	var is_school_catch := catch_record.source_type == "school" and not debug_spawned
	var is_ambient_catch := catch_record.source_type == "ambient" and not debug_spawned
	var school: Dictionary = _manager.call("get_school", catch_record.school_id) if is_school_catch else {}
	var ambient_record: Dictionary = {}
	if is_ambient_catch and _manager != null and _manager.has_method("get_ambient_fish_encounter"):
		ambient_record = _manager.call("get_ambient_fish_encounter", catch_record.ambient_fish_id)
	if is_school_catch and (school.is_empty() or int(school.get("population", 0)) <= 0 or str(school.get("resource_state", "available")) != "available"):
		var invalid_id := pending_catch.catch_id
		_cancel_pending("school_unavailable")
		state = State.IDLE
		state_changed.emit(get_state_name())
		return {"accepted": false, "reason": "school_unavailable", "catch_id": invalid_id}
	if is_school_catch and str(school.get("species_id", "")) != catch_record.species_id:
		return {"accepted": false, "reason": "species_mismatch"}
	if is_ambient_catch and (ambient_record.is_empty() or str(ambient_record.get("lifecycle_state", "")) != "hooked" or str(ambient_record.get("species_id", "")) != catch_record.species_id):
		_cancel_pending("ambient_fish_unavailable_at_settlement")
		state = State.IDLE
		state_changed.emit(get_state_name())
		return {"accepted": false, "reason": "ambient_fish_unavailable", "catch_id": catch_record.catch_id}
	var profile := _manager.call("get_species_profile", catch_record.species_id) as FishSpeciesProfile
	if profile == null:
		return {"accepted": false, "reason": "species_profile_unavailable"}
	var population_before := int(school.get("population", 0)) if is_school_catch else 0
	var population_after := population_before
	if is_school_catch:
		var mutation: Dictionary = _manager.call("request_population_change", catch_record.school_id, -1)
		if not bool(mutation.get("accepted", false)):
			var failed_id := catch_record.catch_id
			_cancel_pending("authority_rejected_settlement")
			state = State.IDLE
			state_changed.emit(get_state_name())
			return {"accepted": false, "reason": "authority_rejected_settlement", "catch_id": failed_id}
		population_after = int(mutation.get("population", maxi(0, population_before - 1)))
	elif is_ambient_catch:
		var mutation: Dictionary = _manager.call("settle_ambient_fish_encounter", catch_record.ambient_fish_id) if _manager.has_method("settle_ambient_fish_encounter") else {"accepted": false, "reason": "ambient_settlement_unavailable"}
		if not bool(mutation.get("accepted", false)):
			_cancel_pending("ambient_authority_rejected_settlement")
			state = State.IDLE
			state_changed.emit(get_state_name())
			return {"accepted": false, "reason": "ambient_authority_rejected_settlement", "authority_result": mutation}
		ambient_record = mutation.get("fish", ambient_record)
	var length_m := catch_record.body_length_m
	if not is_finite(length_m) or length_m <= 0.0:
		length_m = _length_rng.randf_range(profile.body_length_range_m.x, profile.body_length_range_m.y)
	var result := FishingCatchResult.new()
	result.catch_id = catch_record.catch_id
	result.rig_id = catch_record.rig_id
	result.hook_index = catch_record.hook_index
	result.species_id = catch_record.species_id
	result.school_id = catch_record.school_id
	result.source_type = catch_record.source_type
	result.ambient_fish_id = catch_record.ambient_fish_id
	result.lure_id = catch_record.lure_id
	result.fishing_method = catch_record.fishing_method
	result.length_m = length_m
	result.estimated_weight_kg = profile.estimated_weight_coefficient_kg_per_m3 * length_m * length_m * length_m
	result.captured_game_time_seconds = _game_time_seconds()
	result.population_before = population_before
	result.population_after = population_after
	result.debug_spawned = debug_spawned
	_settled_catch_ids[result.catch_id] = true
	_trim_settled_ids()
	last_catch_result = result
	last_settlement = {"accepted": true, "result": result.to_dictionary()}
	pending_catch = null
	state = State.SETTLED
	state_changed.emit(get_state_name())
	retrieval_completed.emit(result)
	catch_succeeded.emit(result)
	return {"accepted": true, "result": result.to_dictionary()}


func _complete_sabiki_batch_retrieval() -> Dictionary:
	var catches: Array[FishingPendingCatch] = []
	for catch_record in _sabiki_hook_catches:
		if catch_record.hook_confirmed:
			catches.append(catch_record)
	if catches.is_empty() or pending_catch == null or catches[0].catch_id != pending_catch.catch_id:
		return {"accepted": false, "reason": "sabiki_batch_empty_or_mismatched"}
	var profiles_by_species: Dictionary = {}
	for catch_record in catches:
		if profiles_by_species.has(catch_record.species_id):
			continue
		var profile := _manager.call("get_species_profile", catch_record.species_id) as FishSpeciesProfile if _manager != null else null
		if profile == null:
			var invalid_profile_batch_id := _sabiki_batch_id
			cancel_sabiki_catches("species_profile_unavailable_at_settlement")
			return {"accepted": false, "reason": "species_profile_unavailable", "batch_id": invalid_profile_batch_id}
		profiles_by_species[catch_record.species_id] = profile
	var changes: Dictionary = {}
	var school_counts: Dictionary = {}
	var ambient_ids: Array[String] = []
	for catch_record in catches:
		if catch_record.debug_spawned or catch_record.source_type == "debug":
			continue
		if catch_record.source_type == "ambient":
			if catch_record.ambient_fish_id.is_empty() or ambient_ids.has(catch_record.ambient_fish_id):
				cancel_sabiki_catches("invalid_ambient_batch_member")
				return {"accepted": false, "reason": "invalid_ambient_batch_member", "batch_id": _sabiki_batch_id}
			ambient_ids.append(catch_record.ambient_fish_id)
			continue
		var school: Dictionary = _manager.call("get_school", catch_record.school_id) if _manager != null else {}
		if school.is_empty() or str(school.get("species_id", "")) != catch_record.species_id or str(school.get("resource_state", "available")) != "available":
			cancel_sabiki_catches("school_unavailable_at_settlement")
			return {"accepted": false, "reason": "school_unavailable", "batch_id": _sabiki_batch_id}
		changes[catch_record.school_id] = int(changes.get(catch_record.school_id, 0)) - 1
		school_counts[catch_record.school_id] = int(school_counts.get(catch_record.school_id, 0)) + 1
	var population_after_by_school: Dictionary = {}
	if not changes.is_empty() or not ambient_ids.is_empty():
		var mutation: Dictionary = _manager.call("settle_boat_fishing_catch_batch", changes, ambient_ids) if _manager != null and _manager.has_method("settle_boat_fishing_catch_batch") else {"accepted": false, "reason": "batch_authority_unavailable"}
		if not bool(mutation.get("accepted", false)):
			var failed_batch_id := _sabiki_batch_id
			cancel_sabiki_catches("authority_rejected_batch_settlement")
			return {"accepted": false, "reason": "authority_rejected_settlement", "batch_id": failed_batch_id}
		population_after_by_school = mutation.get("populations", {})
	var remaining_before_by_school: Dictionary = {}
	for school_id in school_counts:
		remaining_before_by_school[school_id] = int(population_after_by_school.get(school_id, 0)) + int(school_counts[school_id])
	var results: Array[FishingCatchResult] = []
	for catch_record in catches:
		var profile := profiles_by_species[catch_record.species_id] as FishSpeciesProfile
		var length_m := catch_record.body_length_m
		if not is_finite(length_m) or length_m <= 0.0:
			length_m = _boat_length_rng.randf_range(profile.body_length_range_m.x, profile.body_length_range_m.y)
		var result := FishingCatchResult.new()
		result.catch_id = catch_record.catch_id
		result.batch_id = _sabiki_batch_id
		result.batch_count = catches.size()
		result.rig_id = catch_record.rig_id
		result.hook_index = catch_record.hook_index
		result.species_id = catch_record.species_id
		result.school_id = catch_record.school_id
		result.source_type = catch_record.source_type
		result.ambient_fish_id = catch_record.ambient_fish_id
		result.lure_id = catch_record.lure_id
		result.fishing_method = "boat_fishing"
		result.length_m = length_m
		result.estimated_weight_kg = profile.estimated_weight_coefficient_kg_per_m3 * length_m * length_m * length_m
		result.captured_game_time_seconds = _game_time_seconds()
		result.debug_spawned = catch_record.debug_spawned
		if catch_record.source_type == "school" and not catch_record.debug_spawned:
			var before := int(remaining_before_by_school.get(catch_record.school_id, 0))
			result.population_before = before
			result.population_after = before - 1
			remaining_before_by_school[catch_record.school_id] = before - 1
			_school_cooldown_until[catch_record.school_id] = _game_time_seconds() + school_encounter_cooldown_game_seconds
		_settled_catch_ids[result.catch_id] = true
		results.append(result)
	_trim_settled_ids()
	var representative := results[0]
	last_sabiki_batch_results = results.duplicate()
	last_catch_result = representative
	last_settlement = {"accepted": true, "batch_id": _sabiki_batch_id, "results": results.map(func(item: FishingCatchResult) -> Dictionary: return item.to_dictionary())}
	var settled_batch_id := _sabiki_batch_id
	_sabiki_hook_catches.clear()
	_sabiki_batch_active = false
	_sabiki_batch_id = ""
	pending_catch = null
	state = State.SETTLED
	state_changed.emit(get_state_name())
	retrieval_completed.emit(representative)
	catch_succeeded.emit(representative)
	sabiki_batch_settled.emit(settled_batch_id, results)
	return {"accepted": true, "batch_id": settled_batch_id, "results": last_settlement["results"]}


func evaluate_candidates() -> Dictionary:
	var lure := get_selected_lure()
	var boat_speed := _boat_speed_mps()
	var cruise_cap := _boat_cruise_speed_cap_mps()
	var speed_efficiency_by_species: Dictionary = {}
	var samples: Array[Dictionary] = []
	var valid_candidates: Array[Dictionary] = []
	var total_rate := 0.0
	var lure_context := _lure_context(lure)
	if lure == null or _manager == null or _boat == null:
		return _diagnostics_base(lure, boat_speed, cruise_cap, lure_context, samples, valid_candidates, 0.0, speed_efficiency_by_species)
	var lure_position: Vector3 = lure_context.get("lure_world_position", Vector3.ZERO)
	var query_radius := encounter_radius_m
	for species_profile in _manager.call("get_species_profiles"):
		query_radius = maxf(query_radius, encounter_radius_m + species_profile.school_activity_radius_m)
	var schools: Array[Dictionary] = _manager.call("get_schools_near", lure_position, query_radius)
	var now := _game_time_seconds()
	for school in schools:
		var species_id := str(school.get("species_id", ""))
		var profile := _manager.call("get_species_profile", species_id) as FishSpeciesProfile
		var population := int(school.get("population", 0))
		var school_position := _school_position(school)
		var distance := Vector2(school_position.x - lure_position.x, school_position.z - lure_position.z).length()
		var activity_depth := maxf(0.0, float(school.get("activity_depth_m", 0.0)))
		var method_match := profile != null and lure_matches_profile(profile, lure, "trolling")
		var depth_weight := lure.depth_match_weight(activity_depth, float(lure_context.get("effective_lure_max_depth_m", -1.0))) if lure != null else 0.0
		var speed_weight := speed_efficiency(boat_speed, cruise_cap, profile, minimum_effective_trolling_speed_mps) if profile != null else 0.0
		speed_efficiency_by_species[species_id] = maxf(float(speed_efficiency_by_species.get(species_id, 0.0)), speed_weight)
		var cooldown_until := float(_school_cooldown_until.get(str(school.get("school_id", "")), -INF))
		var school_encounter_radius := encounter_radius_m + profile.school_activity_radius_m if profile != null else encounter_radius_m
		var distance_weight := pow(clampf(1.0 - distance / school_encounter_radius, 0.0, 1.0), 2.0)
		var population_weight := minf(sqrt(float(maxi(population, 0))), 3.0)
		var event_rate := 0.0
		var rejection_reason := ""
		if profile == null:
			rejection_reason = "unknown_species"
		elif population <= 0 or str(school.get("resource_state", "available")) != "available":
			rejection_reason = "empty_school"
		elif not method_match:
			rejection_reason = "method_or_lure_mismatch"
		elif depth_weight <= 0.0:
			rejection_reason = "activity_depth_mismatch"
		elif speed_weight <= 0.0:
			rejection_reason = "boat_speed_outside_trolling_window"
		elif now < cooldown_until:
			rejection_reason = "school_cooldown"
		else:
			event_rate = base_event_rate_per_game_hour * profile.relative_bite_tendency * population_weight * distance_weight * depth_weight * speed_weight
			if event_rate <= 0.0:
				rejection_reason = "zero_event_rate"
		var candidate := {
			"school_id": str(school.get("school_id", "")),
			"species_id": species_id,
			"population": population,
			"activity_depth_m": activity_depth,
			"distance_m": distance,
			"lure_match": method_match,
			"depth_weight": depth_weight,
			"speed_efficiency": speed_weight,
			"event_rate_per_game_hour": event_rate,
			"rejection_reason": rejection_reason,
		}
		samples.append(candidate)
		if event_rate > 0.0:
			valid_candidates.append(candidate)
			total_rate += event_rate
	return _diagnostics_base(lure, boat_speed, cruise_cap, lure_context, samples, valid_candidates, total_rate, speed_efficiency_by_species)


func get_diagnostics() -> Dictionary:
	var result := evaluate_candidates()
	result["state"] = get_state_name()
	result["pending_catch"] = pending_catch.to_dictionary() if pending_catch != null else {}
	result["last_catch_result"] = last_catch_result.to_dictionary() if last_catch_result != null else {}
	result["last_settlement"] = last_settlement.duplicate(true)
	result["lure_id"] = selected_lure_id
	return result


func debug_roll_bite_once() -> Dictionary:
	if state != State.TROLLING or pending_catch != null:
		return {"accepted": false, "reason": "not_ready_to_judge"}
	var diagnostics := evaluate_candidates()
	var rate := float(diagnostics.get("total_event_rate_per_game_hour", 0.0))
	var probability := event_probability(rate, debug_judgement_window_game_seconds)
	if rate <= 0.0 or _rng.randf() >= probability:
		return {"accepted": true, "hooked": false, "probability": probability, "event_rate_per_game_hour": rate}
	var candidate := _weighted_candidate(diagnostics.get("valid_candidates", []))
	var pending := _create_pending_catch(candidate, _game_time_seconds())
	return {"accepted": pending != null, "hooked": pending != null, "probability": probability, "pending_catch": pending.to_dictionary() if pending != null else {}}


func debug_force_hook_valid_candidate() -> Dictionary:
	if state != State.TROLLING or pending_catch != null:
		return {"accepted": false, "reason": "not_ready_to_hook"}
	var diagnostics := evaluate_candidates()
	var candidates: Array[Dictionary] = diagnostics.get("valid_candidates", [])
	var candidate := _weighted_candidate(candidates)
	if candidate.is_empty():
		return {"accepted": false, "reason": "no_valid_school_candidate"}
	var pending := _create_pending_catch(candidate, _game_time_seconds())
	return {"accepted": pending != null, "pending_catch": pending.to_dictionary() if pending != null else {}}


func set_random_seed(seed: int) -> void:
	_debug_seed_override = seed
	_seed_rng()
	_reset_hazard()


static func event_probability(lambda_per_game_hour: float, delta_game_seconds: float) -> float:
	if not is_finite(lambda_per_game_hour) or not is_finite(delta_game_seconds):
		return 0.0
	return clampf(1.0 - exp(-maxf(0.0, lambda_per_game_hour) * maxf(0.0, delta_game_seconds) / SECONDS_PER_GAME_HOUR), 0.0, 1.0)


static func speed_efficiency(speed_mps: float, vessel_cruise_cap_mps: float, profile: FishSpeciesProfile, minimum_speed_mps: float = 0.25) -> float:
	if profile == null or not is_finite(speed_mps) or not is_finite(vessel_cruise_cap_mps):
		return 0.0
	if speed_mps < minimum_speed_mps or vessel_cruise_cap_mps <= 0.0 or speed_mps >= vessel_cruise_cap_mps:
		return 0.0
	var offset := (speed_mps - profile.trolling_speed_optimum_mps) / maxf(profile.trolling_speed_falloff_mps, 0.1)
	return exp(-0.5 * offset * offset)


static func lure_matches_profile(profile: FishSpeciesProfile, lure: FishingLure, method: String) -> bool:
	if profile == null or lure == null or not profile.supported_fishing_methods.has(method):
		return false
	for tag in lure.lure_tags:
		if profile.compatible_lure_tags.has(tag):
			return true
	return false


func _lure_context(lure: FishingLure) -> Dictionary:
	if lure == null or _boat == null or _bathymetry == null or _wave_sampler == null:
		return {"valid": false, "effective_lure_max_depth_m": -1.0, "reason": "sensor_dependencies_unavailable"}
	var forward := -_boat.global_basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		forward = Vector3.FORWARD
	forward = forward.normalized()
	var lure_position := _boat.global_position - forward * lure_trailing_distance_m
	var bathymetry: Dictionary = _bathymetry.call("get_depth_at_world_position", lure_position)
	if not bool(bathymetry.get("valid", false)):
		return {"valid": false, "lure_world_position": lure_position, "effective_lure_max_depth_m": -1.0, "reason": "bathymetry_unavailable"}
	var wave_time := float(_wave_sampler.get("wave_time_seconds"))
	var wave: Dictionary = _wave_sampler.call("sample_physics_surface", lure_position, wave_time)
	var surface_y := float(wave.get("height", chart_datum_world_y_m))
	var chart_depth := float(bathymetry.get("depth_m", 0.0))
	var water_column_below_surface := maxf(0.0, chart_depth + surface_y - chart_datum_world_y_m)
	var effective_max := minf(lure.work_depth_range_m.y, water_column_below_surface - minimum_seabed_clearance_m)
	return {
		"valid": effective_max >= lure.work_depth_range_m.x,
		"lure_world_position": lure_position,
		"chart_depth_lat_m": chart_depth,
		"surface_height_world_y_m": surface_y,
		"water_column_below_surface_m": water_column_below_surface,
		"effective_lure_min_depth_m": lure.work_depth_range_m.x,
		"effective_lure_max_depth_m": effective_max,
		"reason": "ok" if effective_max >= lure.work_depth_range_m.x else "not_enough_water_column",
	}


func _diagnostics_base(lure: FishingLure, speed: float, cruise_cap: float, lure_context: Dictionary, samples: Array[Dictionary], valid_candidates: Array[Dictionary], total_rate: float, speed_efficiency_by_species: Dictionary) -> Dictionary:
	return {
		"lure_id": lure.lure_id if lure != null else "",
		"lure_work_depth_range_m": lure.work_depth_range_m if lure != null else Vector2.ZERO,
		"boat_speed_mps": speed,
		"vessel_cruise_cap_mps": cruise_cap,
		"speed_efficiency_by_species": speed_efficiency_by_species,
		"lure_context": lure_context,
		"candidate_schools": samples,
		"valid_candidates": valid_candidates,
		"candidate_school_count": samples.size(),
		"valid_candidate_count": valid_candidates.size(),
		"total_event_rate_per_game_hour": total_rate,
		"probability_per_game_minute": event_probability(total_rate, 60.0),
	}


func _weighted_candidate(candidates: Array[Dictionary]) -> Dictionary:
	var total := 0.0
	for candidate in candidates:
		total += float(candidate.get("event_rate_per_game_hour", 0.0))
	if total <= 0.0:
		return {}
	var selection := _rng.randf() * total
	for candidate in candidates:
		selection -= float(candidate.get("event_rate_per_game_hour", 0.0))
		if selection <= 0.0:
			return candidate
	return candidates.back()


func _weighted_boat_candidate(candidates_variant: Variant) -> Dictionary:
	if not candidates_variant is Array:
		return {}
	var candidates: Array = candidates_variant
	var total := 0.0
	for candidate_variant in candidates:
		if candidate_variant is Dictionary:
			total += float(candidate_variant.get("event_rate_per_real_hour", candidate_variant.get("event_rate_per_game_hour", 0.0)))
	if total <= 0.0:
		return {}
	var selection := _boat_rng.randf() * total
	for candidate_variant in candidates:
		if not candidate_variant is Dictionary:
			continue
		selection -= float(candidate_variant.get("event_rate_per_real_hour", candidate_variant.get("event_rate_per_game_hour", 0.0)))
		if selection <= 0.0:
			return candidate_variant
	return candidates.back() if candidates.back() is Dictionary else {}


func _create_pending_catch(candidate: Dictionary, now: float) -> FishingPendingCatch:
	if candidate.is_empty():
		return null
	var pending := FishingPendingCatch.new()
	pending.catch_id = "catch_%d_%06d" % [int(_manager.call("get_world_seed")), _next_catch_sequence]
	_next_catch_sequence += 1
	pending.species_id = str(candidate.get("species_id", ""))
	pending.school_id = str(candidate.get("school_id", ""))
	pending.lure_id = selected_lure_id
	pending.hooked_game_time_seconds = now
	var species_profile := _manager.call("get_species_profile", pending.species_id) as FishSpeciesProfile
	if species_profile == null:
		return null
	pending.body_length_m = _length_rng.randf_range(species_profile.body_length_range_m.x, species_profile.body_length_range_m.y)
	pending_catch = pending
	state = State.HOOKED
	_school_cooldown_until[pending.school_id] = now + school_encounter_cooldown_game_seconds
	_hazard_accumulated = 0.0
	_hazard_threshold = _draw_hazard_threshold()
	state_changed.emit(get_state_name())
	fish_hooked.emit(pending)
	return pending


func _cancel_pending(reason: String) -> void:
	var catch_id := pending_catch.catch_id if pending_catch != null else ""
	_release_ambient_pending(pending_catch, reason)
	pending_catch = null
	catch_cancelled.emit(catch_id, reason)


func _reset_hazard() -> void:
	_hazard_accumulated = 0.0
	_hazard_threshold = _draw_hazard_threshold()


func _draw_hazard_threshold() -> float:
	return -log(clampf(_rng.randf(), 0.000001, 0.999999))


func _draw_ambient_hazard_threshold() -> float:
	return -log(clampf(_boat_rng.randf(), 0.000001, 0.999999))


func _seed_rng() -> void:
	var world_seed := int(_manager.call("get_world_seed")) if _manager != null and _manager.has_method("get_world_seed") else 20261016
	var encounter_seed := _debug_seed_override if _debug_seed_override >= 0 else (world_seed ^ 1597463007)
	_rng.seed = encounter_seed
	if _rng.seed == 0:
		_rng.seed = 1
	# Separate stream keeps the bite/candidate random sequence unchanged by the
	# body-length roll required for the P3 display fish.
	_length_rng.seed = (_debug_seed_override if _debug_seed_override >= 0 else world_seed) ^ 0x5A17E
	if _length_rng.seed == 0:
		_length_rng.seed = 1
	# Keep boat bites on deterministic independent streams so P2 trolling rolls
	# and body-size results are unchanged by the new activity.
	_boat_rng.seed = encounter_seed ^ 0x6B6F6174
	_boat_length_rng.seed = (_debug_seed_override if _debug_seed_override >= 0 else world_seed) ^ 0xB04F15
	if _boat_rng.seed == 0:
		_boat_rng.seed = 1
	if _boat_length_rng.seed == 0:
		_boat_length_rng.seed = 1


func _game_time_seconds() -> float:
	return maxf(0.0, float(_manager.call("get_world_game_time_seconds"))) if _manager != null and _manager.has_method("get_world_game_time_seconds") else 0.0


func _boat_speed_mps() -> float:
	if _boat == null:
		return 0.0
	var value: Variant = _boat.get("speed_mps")
	return maxf(0.0, float(value)) if value != null and is_finite(float(value)) else 0.0


func _boat_cruise_speed_cap_mps() -> float:
	if _boat == null:
		return 0.0
	var value: Variant = _boat.get("cruise_speed_mps")
	return maxf(0.0, float(value)) if value != null and is_finite(float(value)) else 0.0


func _school_position(school: Dictionary) -> Vector3:
	var value: Variant = school.get("world_position", [])
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return Vector3.ZERO


func _trim_settled_ids() -> void:
	if _settled_catch_ids.size() <= 512:
		return
	var keys := _settled_catch_ids.keys()
	for index in range(keys.size() - 512):
		_settled_catch_ids.erase(keys[index])
