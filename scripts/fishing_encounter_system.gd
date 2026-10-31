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

const SECONDS_PER_GAME_HOUR := 3600.0
const LURE_PATHS := [
	"res://resources/fishing/lures/surface_lure.tres",
	"res://resources/fishing/lures/shallow_minnow.tres",
	"res://resources/fishing/lures/medium_minnow.tres",
]

enum State { IDLE, TROLLING, HOOKED, RETRIEVING, SETTLED }
const STATE_NAMES := ["IDLE", "TROLLING", "HOOKED", "RETRIEVING", "SETTLED"]

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
	if pending_catch != null:
		_cancel_pending("boat_changed")
	_boat = current_boat
	state = State.IDLE
	_hazard_accumulated = 0.0
	_sampling_elapsed_real_seconds = 0.0
	_pending_game_delta_seconds = 0.0
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
	if state in [State.HOOKED, State.RETRIEVING] or not _lures_by_id.has(lure_id):
		return false
	selected_lure_id = lure_id
	_reset_hazard()
	return true


func start_trolling() -> bool:
	if _boat == null or not is_instance_valid(_boat) or not _lures_by_id.has(selected_lure_id) or state in [State.HOOKED, State.RETRIEVING]:
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
	if pending_catch == null:
		return false
	_cancel_pending("cancelled_by_operator")
	state = State.TROLLING
	state_changed.emit(get_state_name())
	return true


func complete_retrieval(catch_id: String = "") -> Dictionary:
	if state != State.RETRIEVING or pending_catch == null:
		return {"accepted": false, "reason": "no_retrieval_pending"}
	if not catch_id.is_empty() and catch_id != pending_catch.catch_id:
		return {"accepted": false, "reason": "catch_id_mismatch"}
	if _settled_catch_ids.has(pending_catch.catch_id):
		return {"accepted": false, "reason": "catch_already_settled"}
	var school: Dictionary = _manager.call("get_school", pending_catch.school_id)
	if school.is_empty() or int(school.get("population", 0)) <= 0 or str(school.get("resource_state", "available")) != "available":
		var invalid_id := pending_catch.catch_id
		_cancel_pending("school_unavailable")
		state = State.IDLE
		state_changed.emit(get_state_name())
		return {"accepted": false, "reason": "school_unavailable", "catch_id": invalid_id}
	if str(school.get("species_id", "")) != pending_catch.species_id:
		return {"accepted": false, "reason": "species_mismatch"}
	var profile := _manager.call("get_species_profile", pending_catch.species_id) as FishSpeciesProfile
	if profile == null:
		return {"accepted": false, "reason": "species_profile_unavailable"}
	var population_before := int(school.get("population", 0))
	var mutation: Dictionary = _manager.call("request_population_change", pending_catch.school_id, -1)
	if not bool(mutation.get("accepted", false)):
		var failed_id := pending_catch.catch_id
		_cancel_pending("authority_rejected_settlement")
		state = State.IDLE
		state_changed.emit(get_state_name())
		return {"accepted": false, "reason": "authority_rejected_settlement", "catch_id": failed_id}
	var length_m := pending_catch.body_length_m
	if not is_finite(length_m) or length_m <= 0.0:
		length_m = _length_rng.randf_range(profile.body_length_range_m.x, profile.body_length_range_m.y)
	var result := FishingCatchResult.new()
	result.catch_id = pending_catch.catch_id
	result.species_id = pending_catch.species_id
	result.school_id = pending_catch.school_id
	result.lure_id = pending_catch.lure_id
	result.length_m = length_m
	result.estimated_weight_kg = profile.estimated_weight_coefficient_kg_per_m3 * length_m * length_m * length_m
	result.captured_game_time_seconds = _game_time_seconds()
	result.population_before = population_before
	result.population_after = int(mutation.get("population", maxi(0, population_before - 1)))
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
	pending_catch = null
	catch_cancelled.emit(catch_id, reason)


func _reset_hazard() -> void:
	_hazard_accumulated = 0.0
	_hazard_threshold = _draw_hazard_threshold()


func _draw_hazard_threshold() -> float:
	return -log(clampf(_rng.randf(), 0.000001, 0.999999))


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
