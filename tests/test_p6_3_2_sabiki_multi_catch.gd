extends SceneTree

const MAIN_SCENE := preload("res://scenes/main.tscn")
const SABIKI_RIG: BoatFishingRigProfile = preload("res://resources/boat_fishing/sabiki_rig.tres")
const SINGLE_JIG: BoatFishingRigProfile = preload("res://resources/boat_fishing/single_jig.tres")
const HERRING_PROFILE: FishSpeciesProfile = preload("res://resources/fish_species/herring.tres")
const SEA_TROUT_PROFILE: FishSpeciesProfile = preload("res://resources/fish_species/sea_trout.tres")


class FakeFishingManager extends Node:
	var profiles: Dictionary = {}
	var schools: Dictionary = {}
	var last_query_radius_m := -1.0
	var population_batch_calls := 0
	var game_time_seconds := 0.0

	func get_species_profile(species_id: String) -> FishSpeciesProfile:
		return profiles.get(species_id) as FishSpeciesProfile

	func get_world_seed() -> int:
		return 816230

	func get_world_game_time_seconds() -> float:
		return game_time_seconds

	func set_school(school_id: String, species_id: String, position: Vector3, depth_m: float, population: int, resource_state: String = "available") -> void:
		schools[school_id] = {
			"school_id": school_id,
			"species_id": species_id,
			"world_position": [position.x, position.y, position.z],
			"activity_depth_m": depth_m,
			"population": population,
			"resource_state": resource_state,
		}

	func get_school(school_id: String) -> Dictionary:
		return (schools.get(school_id, {}) as Dictionary).duplicate(true)

	func get_schools_near(world_position: Vector3, radius_m: float, include_unavailable: bool = false) -> Array[Dictionary]:
		last_query_radius_m = radius_m
		var result: Array[Dictionary] = []
		for school_variant in schools.values():
			var school: Dictionary = school_variant
			if not include_unavailable and (int(school.get("population", 0)) <= 0 or str(school.get("resource_state", "available")) != "available"):
				continue
			var position_data: Array = school.get("world_position", [])
			if position_data.size() < 3:
				continue
			var dx := float(position_data[0]) - world_position.x
			var dz := float(position_data[2]) - world_position.z
			if dx * dx + dz * dz <= radius_m * radius_m:
				result.append(school.duplicate(true))
		return result

	func evaluate_ambient_fishing_candidates(context: Dictionary) -> Dictionary:
		if not bool(context.get("action_qualified", false)):
			return {"candidates": [], "reason": "action_requirement_not_met", "environment_quality": 0.0}
		var rig_species: Array = context.get("rig_compatible_species_ids", [])
		var rig_tags: Array = context.get("rig_compatible_lure_tags", [])
		var hook_depth := float(context.get("hook_depth_m", 0.0))
		var candidates: Array[Dictionary] = []
		for species_variant in profiles.keys():
			var species_id := str(species_variant)
			var profile := profiles[species_variant] as FishSpeciesProfile
			if profile == null or not profile.supported_fishing_methods.has("boat_fishing"):
				continue
			var compatible := rig_species.has(species_id)
			if rig_species.is_empty():
				for tag in rig_tags:
					compatible = compatible or profile.compatible_lure_tags.has(str(tag))
			if not compatible:
				continue
			var depth_match := false
			if profile.surface_activity_cycle_enabled:
				depth_match = (hook_depth >= profile.surface_activity_depth_m.x and hook_depth <= profile.surface_activity_depth_m.y) or (hook_depth >= profile.deep_activity_depth_m.x and hook_depth <= profile.deep_activity_depth_m.y)
			elif profile.vertical_layer == "surface":
				depth_match = hook_depth <= profile.preferred_swim_depth_m.y
			else:
				depth_match = hook_depth <= 30.0
			if depth_match:
				candidates.append({"species_id": species_id, "ecological_weight": maxf(profile.spawn_chance, 0.001), "environment_quality": 1.0})
		if candidates.is_empty():
			return {"candidates": [], "reason": "activity_depth_mismatch", "environment_quality": 0.0}
		return {"candidates": candidates, "reason": "ambient_species_available", "environment_quality": 1.0}

	func request_population_changes(changes: Dictionary) -> Dictionary:
		population_batch_calls += 1
		for school_id_variant in changes.keys():
			var school_id := str(school_id_variant)
			var delta := int(changes[school_id_variant])
			var school: Dictionary = schools.get(school_id, {})
			if delta >= 0 or school.is_empty() or str(school.get("resource_state", "available")) != "available" or int(school.get("population", 0)) < -delta:
				return {"accepted": false, "reason": "invalid_or_insufficient_population"}
		var populations: Dictionary = {}
		for school_id_variant in changes.keys():
			var school_id := str(school_id_variant)
			var school: Dictionary = schools[school_id]
			var population := int(school.get("population", 0)) + int(changes[school_id_variant])
			school["population"] = population
			school["resource_state"] = "depleted" if population <= 0 else "available"
			populations[school_id] = population
		return {"accepted": true, "populations": populations}

	func settle_boat_fishing_catch_batch(changes: Dictionary, ambient_ids: Array[String]) -> Dictionary:
		if not ambient_ids.is_empty():
			return {"accepted": false, "reason": "ambient_not_configured_in_legacy_fixture"}
		return request_population_changes(changes)


var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_distance_curve_and_compatibility()
	_test_authority_batch_atomicity()
	var fake_manager := FakeFishingManager.new()
	fake_manager.profiles = {"herring": HERRING_PROFILE, "sea_trout": SEA_TROUT_PROFILE}
	root.add_child(fake_manager)
	var encounter := FishingEncounterSystem.new()
	root.add_child(encounter)
	encounter.configure(fake_manager, null)
	encounter.set_process(false)
	encounter.begin_boat_fishing_session()
	_test_candidate_queries_and_trigger_modes(encounter, fake_manager)
	_test_natural_reservations_and_batches(encounter, fake_manager)
	fake_manager.queue_free()
	encounter.queue_free()
	await process_frame
	await _test_live_boat_fishing_and_f3()
	print("[P6.3.2] failures=%d" % _failures)
	quit(0 if _failures == 0 else 1)


func _test_distance_curve_and_compatibility() -> void:
	for test_point in [
		{"distance": 5.0, "weight": 1.0},
		{"distance": 15.0, "weight": 0.85},
		{"distance": 25.0, "weight": 0.55},
		{"distance": 35.0, "weight": 0.25},
		{"distance": 45.0, "weight": 0.0833333333},
		{"distance": 50.0, "weight": 0.0},
		{"distance": 55.0, "weight": 0.0},
	]:
		var measured := FishingEncounterSystem.boat_fishing_horizontal_distance_weight(float(test_point["distance"]))
		_check(is_equal_approx(measured, float(test_point["weight"])), "horizontal weight at %.0f m is %.3f" % [float(test_point["distance"]), float(test_point["weight"])])
	_check(HERRING_PROFILE.supported_fishing_methods.has("boat_fishing"), "Herring explicitly permits Boat Fishing")
	_check(not HERRING_PROFILE.supported_fishing_methods.has("trolling"), "Herring compatibility change does not add Trolling")
	_check(FishingEncounterSystem.rig_matches_profile(HERRING_PROFILE, SABIKI_RIG), "Sabiki species ID whitelist accepts Herring without lure tags")
	_check(not FishingEncounterSystem.rig_matches_profile(HERRING_PROFILE, SINGLE_JIG), "Single Jig still rejects Herring without a matching lure tag")
	_check(FishingEncounterSystem.rig_matches_profile(SEA_TROUT_PROFILE, SINGLE_JIG), "Single Jig retains existing lure-tag species compatibility")
	_check(not FishingEncounterSystem.rig_matches_profile(SEA_TROUT_PROFILE, SABIKI_RIG), "Sabiki whitelist rejects species outside its configured list")
	_check(is_equal_approx(FishingEncounterSystem.boat_fishing_surface_activity_multiplier("near_surface", 1.5, HERRING_PROFILE), 1.6), "active near-surface schools receive the surface bite multiplier")
	_check(is_equal_approx(FishingEncounterSystem.boat_fishing_surface_activity_multiplier("ascending", 4.0, HERRING_PROFILE), 1.2), "transitional shallow schools receive the lower surface multiplier")
	_check(is_equal_approx(FishingEncounterSystem.boat_fishing_surface_activity_multiplier("deep", 15.0, HERRING_PROFILE), 1.0), "deep schools keep the ordinary bite multiplier")
	_check(FishingEncounterSystem.sabiki_action_weight(0.0) < FishingEncounterSystem.sabiki_action_weight(1.5), "Sabiki movement only gives a gentle action weighting")
	_check(is_equal_approx(FishingEncounterSystem.boat_fishing_action_weight(0.0), 0.55) and is_equal_approx(FishingEncounterSystem.sabiki_action_weight(0.0), 0.8), "Single Jig and Sabiki have independent resting action weights")


func _test_candidate_queries_and_trigger_modes(encounter: FishingEncounterSystem, fake_manager: FakeFishingManager) -> void:
	var origin := Vector3.ZERO
	fake_manager.set_school("trout_school", "sea_trout", Vector3(25.0, 0.0, 0.0), 12.0, 12)
	var single_diagnostics := encounter.evaluate_boat_fishing_candidates(origin, 12.0, 0.8, SINGLE_JIG)
	_check(is_equal_approx(fake_manager.last_query_radius_m, 50.0), "shared candidate query reaches the full 50 m range")
	_check(int(single_diagnostics.get("candidate_school_count", 0)) == 1, "a Single Jig school at 25 m reaches the candidate evaluator")
	var single_candidate: Dictionary = single_diagnostics.get("candidate_schools", [])[0] if int(single_diagnostics.get("candidate_school_count", 0)) > 0 else {}
	_check(is_equal_approx(float(single_candidate.get("horizontal_weight", 0.0)), 0.55), "Single Jig applies the shared 25 m distance weight")
	_check(float(single_diagnostics.get("ambient_event_rate_per_real_hour", 0.0)) > 0.0 and str(single_diagnostics.get("trigger_mode", "")) == "AMBIENT_ENCOUNTER", "Single Jig outside the 3D school volume can use the Authority-filtered ambient mode")

	fake_manager.set_school("trout_school", "sea_trout", Vector3(45.0, 0.0, 0.0), 12.0, 12)
	var far_single := encounter.evaluate_boat_fishing_candidates(origin, 12.0, 0.8, SINGLE_JIG)
	var far_candidate: Dictionary = far_single.get("candidate_schools", [])[0] if int(far_single.get("candidate_school_count", 0)) > 0 else {}
	_check(int(far_single.get("candidate_school_count", 0)) == 1 and not (far_single.get("ambient_candidates", []) as Array).is_empty() and is_equal_approx(float(far_candidate.get("horizontal_weight", 0.0)), 0.0833333333), "Single Jig at 45 m retains school diagnostics while ambient eligibility stays independent")
	fake_manager.set_school("trout_school", "sea_trout", Vector3(50.0, 0.0, 0.0), 12.0, 12)
	var edge_single := encounter.evaluate_boat_fishing_candidates(origin, 12.0, 0.8, SINGLE_JIG)
	var edge_candidate: Dictionary = edge_single.get("candidate_schools", [])[0] if int(edge_single.get("candidate_school_count", 0)) > 0 else {}
	_check(int(edge_single.get("targeted_candidate_count", 0)) == 0 and is_equal_approx(float(edge_candidate.get("horizontal_weight", -1.0)), 0.0) and str(edge_single.get("trigger_mode", "")) == "AMBIENT_ENCOUNTER", "50 m has zero school-target weight while independent ambient fishing remains available")
	fake_manager.set_school("trout_school", "sea_trout", Vector3(55.0, 0.0, 0.0), 12.0, 12)
	var outside_single := encounter.evaluate_boat_fishing_candidates(origin, 12.0, 0.8, SINGLE_JIG)
	_check(int(outside_single.get("candidate_school_count", 0)) == 0 and str(outside_single.get("trigger_mode", "")) == "AMBIENT_ENCOUNTER", "schools beyond 50 m are filtered while ordinary ambient eligibility remains")

	fake_manager.set_school("herring_school", "herring", Vector3(15.0, 0.0, 0.0), 18.0, 8)
	var sabiki_diagnostics := encounter.evaluate_boat_fishing_candidates(origin, 18.0, 0.1, SABIKI_RIG)
	var sabiki_candidate: Dictionary = sabiki_diagnostics.get("candidate_schools", [])[0] if int(sabiki_diagnostics.get("candidate_school_count", 0)) > 0 else {}
	_check(is_equal_approx(float(sabiki_candidate.get("horizontal_weight", 0.0)), 0.85), "Sabiki applies the same 15 m curve to an individual hook position")
	_check(float(sabiki_diagnostics.get("ambient_event_rate_per_real_hour", 0.0)) > 0.0 and float(sabiki_diagnostics.get("ambient_event_rate_per_real_hour", 0.0)) <= encounter.boat_fishing_ambient_max_event_rate_per_tackle_hour, "Sabiki ambient encounter uses one Authority-filtered tackle rate")
	var wrong_depth := encounter.evaluate_boat_fishing_candidates(origin, 30.0, 0.1, SABIKI_RIG)
	_check(int(wrong_depth.get("valid_candidate_count", 0)) == 0, "50 m horizontal range does not relax vertical water-layer matching")
	var expected_rate := float(sabiki_diagnostics.get("total_event_rate_per_real_hour", 0.0))
	encounter.set("_boat_ambient_hazard_accumulated", 0.0)
	encounter.set("_boat_ambient_hazard_threshold", 100.0)
	var shared_hazard := encounter.advance_boat_fishing_ambient_hazard([sabiki_diagnostics], 0.25)
	_check(is_equal_approx(float(shared_hazard.get("hazard_accumulated", -1.0)), expected_rate * 0.25 / 3600.0), "Sabiki uses one shared tackle hazard integrated in real seconds")


func _test_natural_reservations_and_batches(encounter: FishingEncounterSystem, fake_manager: FakeFishingManager) -> void:
	fake_manager.set_school("herring_school", "herring", Vector3(0.0, 0.0, 0.0), 18.0, 2)
	var candidate := {"school_id": "herring_school", "species_id": "herring", "population": 2, "activity_depth_m": 18.0}
	var first := encounter.reserve_sabiki_hook(candidate, SABIKI_RIG, 0)
	var second := encounter.reserve_sabiki_hook(candidate, SABIKI_RIG, 1)
	var third := encounter.reserve_sabiki_hook(candidate, SABIKI_RIG, 2)
	_check(first != null and second != null and third == null, "two available fish reserve two hooks and prevent an over-reserved third hook")
	_check(int(fake_manager.get_school("herring_school").get("population", 0)) == 2, "hook reservations do not consume population before retrieval")
	var first_confirmed := encounter.confirm_sabiki_hook(first.catch_id) if first != null else false
	var second_confirmed := encounter.confirm_sabiki_hook(second.catch_id) if second != null else false
	_check(first_confirmed and second_confirmed, "reserved natural herring can each confirm once")
	var hooked_signals := 0
	var signal_capture := {"batch_results": [], "success_signals": 0}
	encounter.catch_succeeded.connect(func(_result: FishingCatchResult) -> void: signal_capture["success_signals"] = int(signal_capture["success_signals"]) + 1)
	encounter.sabiki_batch_settled.connect(func(_batch_id: String, results: Array) -> void: signal_capture["batch_results"] = results.duplicate())
	var representative := encounter.begin_sabiki_batch_retrieval()
	_check(representative != null and encounter.state == FishingEncounterSystem.State.HOOKED, "batch starts one shared hook and fight timeline")
	if representative != null:
		hooked_signals += 1
	var retrieval_started := encounter.begin_retrieval()
	var settlement := encounter.complete_retrieval(representative.catch_id if representative != null else "") if retrieval_started else {"accepted": false}
	var batch_results: Array = signal_capture["batch_results"]
	_check(bool(settlement.get("accepted", false)) and batch_results.size() == 2, "natural batch retrieval settles both reserved fish together")
	_check(int(signal_capture["success_signals"]) == 1 and hooked_signals == 1, "the shared catch and success signals fire once for the entire batch")
	_check(fake_manager.population_batch_calls == 1 and int(fake_manager.get_school("herring_school").get("population", 0)) == 0, "Authority population is decremented once by the exact batch count")
	var unique_hooks: Dictionary = {}
	var all_natural := true
	for result_variant in batch_results:
		var result := result_variant as FishingCatchResult
		if result == null:
			continue
		unique_hooks[result.hook_index] = true
		all_natural = all_natural and not result.debug_spawned and result.species_id == "herring" and result.batch_count == 2 and result.batch_id == str(settlement.get("batch_id", ""))
	_check(unique_hooks.size() == 2 and all_natural, "each natural fish retains its own hook identity and common batch ID")

	fake_manager.set_school("herring_school", "herring", Vector3.ZERO, 18.0, 1)
	var held := encounter.reserve_sabiki_hook(candidate, SABIKI_RIG, 0)
	var unavailable := encounter.reserve_sabiki_hook(candidate, SABIKI_RIG, 1)
	_check(held != null and unavailable == null, "remaining school quantity limits new reservations")
	var confirmed_before_cancel := held != null and encounter.confirm_sabiki_hook(held.catch_id)
	var population_before_cancel := int(fake_manager.get_school("herring_school").get("population", 0))
	var canceled_ids: Array[String] = []
	var cancel_callback := func(catch_id: String, _reason: String) -> void: canceled_ids.append(catch_id)
	encounter.catch_cancelled.connect(cancel_callback)
	encounter.cancel_sabiki_catches("test_cancel")
	encounter.catch_cancelled.disconnect(cancel_callback)
	_check(confirmed_before_cancel and canceled_ids.has(held.catch_id) and encounter.get_sabiki_hooked_count() == 0 and int(fake_manager.get_school("herring_school").get("population", 0)) == population_before_cancel, "cancellation reports each confirmed reservation, releases it, and leaves population unchanged")

	fake_manager.set_school("herring_school", "herring", Vector3.ZERO, 18.0, 2)
	var mixed_natural := encounter.reserve_sabiki_hook(candidate, SABIKI_RIG, 0)
	var mixed_debug := encounter.reserve_sabiki_hook({"species_id": "herring"}, SABIKI_RIG, 1, true)
	if mixed_natural != null:
		encounter.confirm_sabiki_hook(mixed_natural.catch_id)
	if mixed_debug != null:
		encounter.confirm_sabiki_hook(mixed_debug.catch_id)
	var mixed_representative := encounter.begin_sabiki_batch_retrieval()
	var mixed_started := mixed_representative != null and encounter.begin_retrieval()
	var mixed_settlement := encounter.complete_retrieval(mixed_representative.catch_id if mixed_started else "") if mixed_started else {"accepted": false}
	var mixed_results: Array = mixed_settlement.get("results", [])
	var mixed_debug_count := 0
	for result_variant in mixed_results:
		var result: Dictionary = result_variant
		mixed_debug_count += 1 if bool(result.get("debug_spawned", false)) else 0
	_check(bool(mixed_settlement.get("accepted", false)) and mixed_results.size() == 2 and mixed_debug_count == 1, "a mixed debug and natural batch keeps both results individually marked")
	_check(fake_manager.population_batch_calls == 2 and int(fake_manager.get_school("herring_school").get("population", 0)) == 1, "mixed settlement consumes only its one real natural fish")

	fake_manager.set_school("herring_school", "herring", Vector3.ZERO, 18.0, 0, "depleted")
	var debug_pending: Array[FishingPendingCatch] = []
	for hook_index in range(SABIKI_RIG.hook_count):
		var pending := encounter.reserve_sabiki_hook({"school_id": "", "species_id": "herring"}, SABIKI_RIG, hook_index, true)
		if pending != null:
			debug_pending.append(pending)
	_check(debug_pending.size() == SABIKI_RIG.maximum_catch_count and encounter.reserve_sabiki_hook({"species_id": "herring"}, SABIKI_RIG, 0, true) == null, "debug catches are isolated but still obey rig hook capacity")
	for pending in debug_pending:
		encounter.confirm_sabiki_hook(pending.catch_id)
	var debug_representative := encounter.begin_sabiki_batch_retrieval()
	var debug_started := debug_representative != null and encounter.begin_retrieval()
	var debug_settlement := encounter.complete_retrieval(debug_representative.catch_id if debug_started else "") if debug_started else {"accepted": false}
	var debug_results: Array = debug_settlement.get("results", [])
	var all_debug := debug_results.size() == SABIKI_RIG.maximum_catch_count
	for result_variant in debug_results:
		var result: Dictionary = result_variant
		all_debug = all_debug and bool(result.get("debug_spawned", false))
	_check(bool(debug_settlement.get("accepted", false)) and all_debug, "five debug fish use the same batch settlement without requiring natural schools")
	_check(fake_manager.population_batch_calls == 2, "debug batch settlement makes no natural Authority mutation")


func _test_authority_batch_atomicity() -> void:
	var authority := FishLocalAuthority.new()
	var herring_school := FishSchoolState.new()
	herring_school.school_id = "herring_authority_test"
	herring_school.species_id = "herring"
	herring_school.population = 2
	herring_school.baseline_population = 2
	var trout_school := FishSchoolState.new()
	trout_school.school_id = "trout_authority_test"
	trout_school.species_id = "sea_trout"
	trout_school.population = 1
	trout_school.baseline_population = 1
	authority.set("_schools", {herring_school.school_id: herring_school, trout_school.school_id: trout_school})
	var initial_revision := authority.get_state_revision()
	var rejected := authority.request_population_changes({herring_school.school_id: -1, trout_school.school_id: -2}, 0.0)
	_check(not bool(rejected.get("accepted", false)), "Authority rejects a batch that exceeds one school's available population")
	_check(herring_school.population == 2 and trout_school.population == 1 and authority.get_state_revision() == initial_revision, "failed batch validation leaves all schools and revision unchanged")
	var accepted := authority.request_population_changes({herring_school.school_id: -2}, 0.0)
	_check(bool(accepted.get("accepted", false)) and herring_school.population == 0 and herring_school.resource_state == "depleted", "Authority atomically applies the exact multi-fish resource deduction")
	# FishLocalAuthority is RefCounted; releasing the local reference owns its lifetime.


func _test_live_boat_fishing_and_f3() -> void:
	var main := MAIN_SCENE.instantiate()
	root.add_child(main)
	for _frame in range(30):
		await process_frame
	var manager := main.find_child("FishResourceManager", true, false) as FishResourceManager
	var casting := main.find_child("BoatFishingCastingSystem", true, false) as BoatFishingCastingSystem
	var rod_system := main.find_child("FishingRodSystem", true, false) as FishingRodSystem
	var boat_controller := main.find_child("MotionRoot", true, false) as Node3D
	var activities_button := main.find_child("ActivitiesButton", true, false) as Button
	var boat_fishing_button := main.find_child("OpenBoatFishingActivity", true, false) as Button
	var debug_panel := main.find_child("FishingDebugTab", true, false) as Control
	var onboard: OnboardActivityController = casting.get("_onboard") as OnboardActivityController if casting != null else null
	_check(manager != null and casting != null and rod_system != null and boat_controller != null and onboard != null, "Main scene loads the shared Authority, boat-fishing controller, and trolling presentation system")
	_check(debug_panel != null, "F3 Fishing tab is available for Sabiki tests")
	_check(debug_panel != null and debug_panel.find_child("BoatFishingBiteDiagnostics", true, false) is Label, "F3 Fishing tab contains low-frequency natural-bite diagnostics")
	if manager == null or casting == null or rod_system == null or boat_controller == null or onboard == null or activities_button == null or boat_fishing_button == null:
		await _free_main(main)
		return
	activities_button.pressed.emit()
	boat_fishing_button.pressed.emit()
	for _frame in range(2):
		await process_frame
	_check(casting.is_activity_active() and casting.select_rig(&"sabiki_rig"), "Boat Fishing starts with the selectable Sabiki profile")
	var previous_sampling_interval := casting.boat_fishing_sampling_interval_real_seconds
	casting.boat_fishing_sampling_interval_real_seconds = 1000.0
	var encounter := manager.get_fishing_encounter_system()
	var all_population_before := _total_population(manager)
	var batches: Array = []
	encounter.sabiki_batch_settled.connect(func(batch_id: String, results: Array) -> void:
		batches.append({"batch_id": batch_id, "results": results.duplicate()})
	)
	var f3_index := debug_panel.find_child("BoatSabikiTestHookIndex", true, false) as SpinBox
	var f3_selected := debug_panel.find_child("BoatSabikiSpawnTestFishAtHook", true, false) as Button
	var f3_next := debug_panel.find_child("BoatSabikiSpawnTestFishNextEmpty", true, false) as Button
	var f3_fill := debug_panel.find_child("BoatSabikiFillTestHooks", true, false) as Button
	var collect_button := main.find_child("RetrieveSabikiRig", true, false) as Button
	_check(f3_index != null and f3_selected != null and f3_next != null and f3_fill != null and collect_button == null, "F3 exposes hook test controls and the HUD does not add a competing automatic-retrieve button")
	if f3_selected == null or f3_next == null or f3_fill == null:
		await _free_main(main)
		return
	debug_panel.call("_refresh_controls")
	_prepare_landed_sabiki(casting, boat_controller, onboard)
	if f3_index != null:
		f3_index.value = 1.0
	f3_selected.pressed.emit()
	var first_approach := casting.find_child("SabikiHookFish_01", true, false) as Node3D
	_check(first_approach != null and casting.get_sabiki_hooked_count() == 0, "specified F3 hook creates one approaching fish without confirming an early hook")
	f3_selected.pressed.emit()
	_check(str(casting.get_sabiki_hook_states_snapshot()[0].get("status", "")) == "approaching" and casting.get_children().filter(func(node: Node) -> bool: return node.name == "SabikiHookFish_01").size() == 1, "repeated F3 activation cannot duplicate a fish or pending reservation on one hook")
	if first_approach != null:
		var start_position := first_approach.global_position
		await create_timer(0.12).timeout
		_check(first_approach.global_position.distance_to(start_position) > 0.005, "shallow Sabiki test fish visibly swims toward its own hook")
	var reached_one := await _wait_until(func() -> bool: return casting.get_sabiki_hooked_count() == 1, 360)
	_check(reached_one and str(casting.get_sabiki_hook_states_snapshot()[0].get("status", "")) == "hooked", "hook state changes only after the fish reaches Hook 1")
	_check(casting.get_casting_state() == BoatFishingCastingSystem.CastState.SABIKI_HOOKED_WAITING, "one Sabiki fish leaves other hooks waiting instead of auto-retrieving")
	if f3_index != null:
		f3_index.value = 2.0
	f3_selected.pressed.emit()
	if f3_index != null:
		f3_index.value = 3.0
	f3_selected.pressed.emit()
	var reached_three := await _wait_until(func() -> bool: return casting.get_sabiki_hooked_count() == 3, 360)
	_check(reached_three and casting.get_casting_state() == BoatFishingCastingSystem.CastState.SABIKI_HOOKED_WAITING, "three independent hooks can accumulate while the remaining hooks wait")
	var sabiki_fight_snapshot := casting.get_fight_snapshot()
	_check((sabiki_fight_snapshot.get("participants", []) as Array).size() == 3, "each confirmed Sabiki hook owns an independent fight participant")
	var sabiki_geometry_snapshot := casting.get_fight_snapshot(true)
	var sabiki_geometry_participants: Array = sabiki_geometry_snapshot.get("participants", [])
	var all_mouths_at_hooks := sabiki_geometry_participants.size() == 3
	var maximum_sabiki_mouth_error_m := 0.0
	var minimum_sabiki_hull_clearance_m := INF
	for participant_variant in sabiki_geometry_participants:
		var participant_geometry: Dictionary = participant_variant
		var mouth_error := float(participant_geometry.get("mouth_hook_error_m", -1.0))
		maximum_sabiki_mouth_error_m = maxf(maximum_sabiki_mouth_error_m, mouth_error)
		all_mouths_at_hooks = all_mouths_at_hooks and mouth_error >= 0.0 and mouth_error <= 0.01
		var hull_clearance := float(participant_geometry.get("hull_clearance_m", -1.0))
		if hull_clearance >= 0.0:
			minimum_sabiki_hull_clearance_m = minf(minimum_sabiki_hull_clearance_m, hull_clearance)
	print("[P6.4.5][SABIKI_GEOMETRY] three-fish live max mouth-hook error=%.6fm" % maximum_sabiki_mouth_error_m)
	_check(all_mouths_at_hooks, "three live Sabiki fish mouths stay within 1 cm of their own hook tips")
	if is_finite(minimum_sabiki_hull_clearance_m):
		print("[P6.4.5][HULL] three-fish live minimum body clearance=%.4fm" % minimum_sabiki_hull_clearance_m)
		_check(minimum_sabiki_hull_clearance_m >= -0.01, "live Sabiki fish bodies stay outside the hull safety ellipse within 1 cm")
	_check(not encounter.start_trolling() and encounter.get_sabiki_hooked_count() == 3, "trolling cannot replace the locally reserved Sabiki batch")
	encounter.stop_trolling()
	_check(encounter.get_sabiki_hooked_count() == 3 and not encounter.cancel_pending_catch(), "trolling stop and generic catch cancellation cannot clear a boat-owned Sabiki batch")
	var hooked_visual_count := 0
	for hook_state in casting.get_sabiki_hook_states_snapshot():
		if str(hook_state.get("status", "")) == "hooked":
			hooked_visual_count += 1 if casting.find_child("SabikiHookFish_%02d" % (int(hook_state.get("hook_index", 0)) + 1), true, false) != null else 0
	_check(hooked_visual_count == 3 and casting.get_casting_state() == BoatFishingCastingSystem.CastState.SABIKI_HOOKED_WAITING, "three fish remain attached to separate hooks while the player chooses when to reel")
	var original_bait: Vector3 = casting.get("_bait_world")
	var original_line := float(casting.get("_line_paid_out_length_m"))
	var original_sample_interval := casting.boat_fishing_sampling_interval_real_seconds
	casting.set("_bait_world", original_bait + Vector3(10000.0, 0.0, 10000.0))
	casting.boat_fishing_sampling_interval_real_seconds = 0.001
	casting.set("_natural_bite_sample_elapsed", 0.0)
	casting.call("_update_natural_bite_judgement", 0.01)
	var empty_hook_diagnostics := casting.get_natural_bite_diagnostics()
	_check(int(empty_hook_diagnostics.get("empty_hook_count", 0)) == 2, "natural Sabiki evaluation keeps the two empty hooks eligible while the fight session is active")
	casting.set("_bait_world", original_bait)
	casting.set("_line_paid_out_length_m", original_line)
	casting.boat_fishing_sampling_interval_real_seconds = original_sample_interval
	casting.set("_natural_bite_sample_elapsed", 0.0)
	var line_before_reel := float(casting.get_interaction_snapshot().get("line_length_m", 0.0))
	casting.set_manual_reeling(true, true)
	await create_timer(0.18).timeout
	casting.set_manual_reeling(false, true)
	var line_after_reel := float(casting.get_interaction_snapshot().get("line_length_m", 0.0))
	_check(line_after_reel < line_before_reel and casting.get_casting_state() == BoatFishingCastingSystem.CastState.SABIKI_HOOKED_WAITING, "manual left-button reel changes line length without an automatic batch transition")
	var safe_minimum := float(casting.call("_get_fight_minimum_line_length_m"))
	casting.set("_line_paid_out_length_m", safe_minimum)
	casting.set_manual_reeling(true, true)
	casting.call("_advance_boat_fight", 0.016)
	casting.set_manual_reeling(false, true)
	_check(casting.get_casting_state() == BoatFishingCastingSystem.CastState.LANDING, "player reeling the group to the hull-safe boundary starts landing")
	var first_batch_settled := await _wait_until(func() -> bool: return batches.size() >= 1, 240)
	_check(first_batch_settled, "the three-fish group is settled after player-controlled landing")
	if not batches.is_empty():
		_check((batches[0]["results"] as Array).size() == 3, "the first batch contains exactly the three fish accumulated on hooks")
	var batch_hud := main.find_child("BoatFishingHookedCount", true, false) as Label
	_check(batch_hud != null and batch_hud.text.contains("3"), "HUD exposes the completed batch count")
	await _wait_until(func() -> bool: return casting.get_casting_state() == BoatFishingCastingSystem.CastState.READY, 180)
	_check(not onboard.is_movement_locked(), "completed batch restores deck movement")
	_check(_total_population(manager) == all_population_before, "debug batch does not consume natural fish populations")

	_prepare_landed_sabiki(casting, boat_controller, onboard)
	debug_panel.call("_refresh_controls")
	f3_next.pressed.emit()
	f3_fill.pressed.emit()
	var full_rig_hooked := await _wait_until(func() -> bool: return casting.get_sabiki_hooked_count() == SABIKI_RIG.maximum_catch_count, 360)
	_check(full_rig_hooked and casting.get_casting_state() == BoatFishingCastingSystem.CastState.SABIKI_HOOKED_WAITING, "filling all empty hooks leaves a full rig under player control")
	_check(not casting.is_automatic_control_owned() and batches.size() == 1, "a full five-hook rig neither locks controls nor starts automatic retrieval")
	safe_minimum = float(casting.call("_get_fight_minimum_line_length_m"))
	casting.set("_line_paid_out_length_m", safe_minimum)
	casting.set_manual_reeling(true, true)
	casting.call("_advance_boat_fight", 0.016)
	casting.set_manual_reeling(false, true)
	_check(casting.get_casting_state() == BoatFishingCastingSystem.CastState.LANDING, "a full rig enters landing only after the player reels to the hull-safe boundary")
	var full_batch_settled := await _wait_until(func() -> bool: return batches.size() >= 2, 240)
	_check(full_batch_settled, "full five-hook rig completes one shared Authority settlement after landing")
	if batches.size() >= 2:
		var full_results: Array = batches[1]["results"]
		_check(full_results.size() == SABIKI_RIG.maximum_catch_count, "full batch settles exactly the rig's configured maximum fish")
		var all_debug := true
		for result_variant in full_results:
			var result := result_variant as FishingCatchResult
			all_debug = all_debug and result != null and result.debug_spawned and result.rig_id == "sabiki_rig"
		_check(all_debug, "F3 fill results retain debug isolation and the Sabiki rig identity")
	_check(int(casting.get_debug_snapshot()["fishing_audio_event_counts"].get("catch_success", 0)) == 2, "each completed batch plays one success cue, not one per fish")
	_check(_total_population(manager) == all_population_before, "five debug catches leave Authority populations unchanged")
	await _wait_until(func() -> bool: return casting.get_casting_state() == BoatFishingCastingSystem.CastState.READY, 180)
	_check(not onboard.is_movement_locked(), "full-batch completion restores player movement")
	_prepare_landed_sabiki(casting, boat_controller, onboard)
	var pending_approach := casting.debug_spawn_sabiki_fish(0)
	var approach_reservation_count := encounter.get_sabiki_hook_catches().size()
	casting.call("_begin_final_retrieval")
	_check(bool(pending_approach.get("accepted", false)) and approach_reservation_count == 1 and encounter.get_sabiki_hook_catches().is_empty(), "reeling an empty rig cancels an unfinished approach and releases its Authority reservation")
	var empty_retrieval_done := await _wait_until(func() -> bool: return casting.get_casting_state() == BoatFishingCastingSystem.CastState.READY, 180)
	_check(empty_retrieval_done, "empty Sabiki retrieval returns to READY after the approach is cancelled")
	_prepare_landed_sabiki(casting, boat_controller, onboard)
	var exit_catch := casting.debug_spawn_sabiki_fish(0)
	var exit_hooked := await _wait_until(func() -> bool: return casting.get_sabiki_hooked_count() == 1, 360)
	_check(bool(exit_catch.get("accepted", false)) and exit_hooked, "activity-exit cancellation fixture reaches a confirmed boat-fishing hook")
	casting.end_activity()
	_check(encounter.get_sabiki_hook_catches().is_empty() and not bool(casting.get_debug_snapshot().get("fight_session_active", false)) and not onboard.is_movement_locked(), "exiting with a hooked Sabiki fish releases all reservations, participants, and movement locks")
	casting.boat_fishing_sampling_interval_real_seconds = previous_sampling_interval
	await _free_main(main)


func _prepare_landed_sabiki(casting: BoatFishingCastingSystem, boat: Node3D, onboard: OnboardActivityController) -> void:
	var bait_position := boat.global_position + Vector3(24.0, 0.0, 18.0)
	var water_sample: Dictionary = casting.call("_sample_water", bait_position)
	bait_position.y = float(water_sample.get("height", boat.global_position.y)) - 3.0
	casting.set("_bait_world", bait_position)
	casting.set("_bait_velocity_world", Vector3.ZERO)
	casting.set("_bait_has_landed", true)
	casting.set("_bait_flight_started", true)
	casting.set("_bait_airborne_retrieval", false)
	casting.set("_sabiki_retrieval_taut", false)
	var rod_tip: Vector3 = casting.call("_get_rod_tip_world")
	casting.set("_line_paid_out_length_m", clampf(rod_tip.distance_to(bait_position), 1.0, casting.maximum_line_length_m))
	onboard.set_movement_locked(true)
	var bait_mesh := casting.find_child("BoatFishingBait", true, false) as MeshInstance3D
	if bait_mesh != null:
		bait_mesh.visible = true
	var line_mesh := casting.find_child("BoatFishingLine", true, false) as MeshInstance3D
	if line_mesh != null:
		line_mesh.visible = true
	casting.call("_set_state", BoatFishingCastingSystem.CastState.WAITING)


func _wait_until(predicate: Callable, max_frames: int) -> bool:
	for _frame in range(max_frames):
		if predicate.call():
			return true
		await process_frame
	return bool(predicate.call())


func _total_population(manager: FishResourceManager) -> int:
	var total := 0
	for school in manager.get_all_school_snapshots():
		total += int(school.get("population", 0))
	return total


func _free_main(main: Node) -> void:
	if is_instance_valid(main):
		main.queue_free()
	for _frame in range(2):
		await process_frame


func _check(condition: bool, label: String) -> void:
	if condition:
		print("[P6.3.2][PASS] %s" % label)
	else:
		_failures += 1
		push_error("[P6.3.2][FAIL] %s" % label)
