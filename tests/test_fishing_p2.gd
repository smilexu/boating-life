extends SceneTree

const GEOREFERENCE := preload("res://resources/oresund_georeference.tres")
const WAVE_SETTINGS := preload("res://resources/sea_waves.tres")
const FISHING_DEBUG_PANEL_SCRIPT := preload("res://scripts/fishing_debug_panel.gd")

class FishingTestBoat extends Node3D:
	var speed_mps := 0.0
	var cruise_speed_mps := 7.0

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var fixture := _create_fixture()
	var fixture_root: Node3D = fixture["root"]
	for _frame in range(4):
		await process_frame
	var manager := fixture["manager"] as FishResourceManager
	var encounter := manager.get_fishing_encounter_system()
	var finder := manager.get_fish_finder_sensor()
	var boat := fixture["boat"] as Node3D
	_check(encounter != null and finder != null, "manager exposes one encounter system and one Fish Finder sensor")
	var fishing_panel := FISHING_DEBUG_PANEL_SCRIPT.new() as ScrollContainer
	fishing_panel.name = "FishingDebugTab"
	root.add_child(fishing_panel)
	fishing_panel.configure(manager)
	_check(fishing_panel.find_child("FishingDebugContent", true, false) != null, "Fishing debug panel builds its localized controls")
	var hud_script_source := FileAccess.get_file_as_string("res://scripts/boat_hud.gd")
	_check(hud_script_source.contains("FISHING_DEBUG_PANEL_SCRIPT.new()") and hud_script_source.contains("set_tab_title(2, tr(\"fishing.debug.tab\"))"), "BoatHUD registers the Fishing panel as an F3 tab")
	_check(manager.get_all_school_snapshots().size() > 0, "Fish Finder and trolling share existing authoritative schools")
	_check(ResourceLoader.load("res://resources/fishing/lures/surface_lure.tres") is FishingLure, "surface lure Resource loads")
	_check(ResourceLoader.load("res://resources/fishing/lures/shallow_minnow.tres") is FishingLure, "shallow minnow Resource loads")
	_check(ResourceLoader.load("res://resources/fishing/lures/medium_minnow.tres") is FishingLure, "medium minnow Resource loads")

	var needlefish := manager.get_species_profile("needlefish")
	var sea_trout := manager.get_species_profile("sea_trout")
	var herring := manager.get_species_profile("herring")
	var stickleback := manager.get_species_profile("three_spined_stickleback")
	var surface_lure := ResourceLoader.load("res://resources/fishing/lures/surface_lure.tres") as FishingLure
	var shallow_lure := ResourceLoader.load("res://resources/fishing/lures/shallow_minnow.tres") as FishingLure
	var medium_lure := ResourceLoader.load("res://resources/fishing/lures/medium_minnow.tres") as FishingLure
	_check(FishingEncounterSystem.lure_matches_profile(needlefish, surface_lure, "trolling"), "needlefish matches the surface lure for trolling")
	_check(not FishingEncounterSystem.lure_matches_profile(sea_trout, surface_lure, "trolling"), "surface lure profile excludes species without its explicit lure tag")
	_check(FishingEncounterSystem.lure_matches_profile(needlefish, shallow_lure, "trolling"), "needlefish matches the shallow minnow for trolling")
	_check(FishingEncounterSystem.lure_matches_profile(sea_trout, shallow_lure, "trolling"), "sea trout matches the shallow minnow for trolling")
	_check(FishingEncounterSystem.lure_matches_profile(sea_trout, medium_lure, "trolling"), "sea trout matches the medium minnow for trolling")
	_check(not FishingEncounterSystem.lure_matches_profile(herring, shallow_lure, "trolling"), "herring is excluded from ordinary trolling")
	_check(not FishingEncounterSystem.lure_matches_profile(stickleback, surface_lure, "trolling"), "stickleback is excluded from ordinary trolling")
	_check(surface_lure.depth_match_weight(0.65, 1.5) > surface_lure.depth_match_weight(1.45, 1.5), "lure depth preference weights the center above the edge")
	_check(is_zero_approx(surface_lure.depth_match_weight(2.0, 1.5)), "lure depth outside the work interval has no match")

	var p_60 := FishingEncounterSystem.event_probability(1.1, 60.0)
	var p_30 := FishingEncounterSystem.event_probability(1.1, 30.0)
	_check(is_equal_approx(p_60, 1.0 - pow(1.0 - p_30, 2.0)), "continuous-time hazard probability composes across different frame partitions")
	_check(is_zero_approx(FishingEncounterSystem.event_probability(1.1, 0.0)), "paused simulation time adds no encounter probability")
	_check(FishingEncounterSystem.speed_efficiency(sea_trout.trolling_speed_optimum_mps, boat.cruise_speed_mps, sea_trout) > 0.99, "species optimum speed produces high trolling efficiency")
	_check(is_zero_approx(FishingEncounterSystem.speed_efficiency(0.0, boat.cruise_speed_mps, sea_trout)), "stationary vessel has no trolling efficiency")
	_check(is_zero_approx(FishingEncounterSystem.speed_efficiency(boat.cruise_speed_mps, boat.cruise_speed_mps, sea_trout)), "vessel cruise cap rejects over-limit trolling")

	var first_translations_resolve := true
	var fishing_translation_keys: Array[String] = []
	var translation_csv := FileAccess.get_file_as_string("res://resources/translations/fish_species.csv")
	for line in translation_csv.split("\n"):
		if line.begins_with("fishing."):
			fishing_translation_keys.append(line.get_slice(",", 0))
	var previous_locale := TranslationServer.get_locale()
	for locale in ["en", "zh_CN"]:
		TranslationServer.set_locale(locale)
		for key in fishing_translation_keys:
			if TranslationServer.translate(key) == key:
				first_translations_resolve = false
	_check(first_translations_resolve and not fishing_translation_keys.is_empty(), "all P2 fishing and lure keys resolve in English and Simplified Chinese")
	TranslationServer.set_locale(previous_locale)

	var original_boat_position := boat.global_position
	boat.global_position += Vector3(100000.0, 0.0, 100000.0)
	boat.set("speed_mps", sea_trout.trolling_speed_optimum_mps)
	encounter.encounter_radius_m = 1.0
	encounter.select_lure(surface_lure.lure_id)
	encounter.start_trolling()
	var empty_diagnostics := encounter.evaluate_candidates()
	var empty_roll := encounter.debug_roll_bite_once()
	_check(int(empty_diagnostics.get("valid_candidate_count", 0)) == 0 and not bool(empty_roll.get("hooked", false)), "no valid nearby Authority school cannot create a catch")
	encounter.stop_trolling()
	encounter.encounter_radius_m = 28.0
	boat.global_position = original_boat_position

	var catch_school := _find_matching_school(manager, encounter, boat)
	_check(not catch_school.is_empty(), "a real trolling-compatible authority school can produce a valid encounter candidate")
	if not catch_school.is_empty():
		_check(encounter.start_trolling(), "trolling starts with the selected lure")
		var diagnostics := encounter.evaluate_candidates()
		_check(int(diagnostics.get("valid_candidate_count", 0)) > 0, "candidate rate is based on a valid school, depth, lure and vessel speed")
		encounter.set_random_seed(12345)
		var hooked := encounter.debug_force_hook_valid_candidate()
		_check(bool(hooked.get("accepted", false)), "debug force-hook uses a real valid school candidate")
		var mirror := FishingEncounterSystem.new()
		mirror.configure(manager, boat)
		mirror.select_lure(encounter.selected_lure_id)
		mirror.start_trolling()
		mirror.set_random_seed(12345)
		var mirrored_hook := mirror.debug_force_hook_valid_candidate()
		var first_pending: Dictionary = hooked.get("pending_catch", {})
		var mirror_pending: Dictionary = mirrored_hook.get("pending_catch", {})
		_check(str(first_pending.get("school_id", "")) == str(mirror_pending.get("school_id", "")), "fixed RNG seed reproduces the selected school")
		var pending: Dictionary = hooked.get("pending_catch", {})
		_check(not pending.is_empty() and str(pending.get("school_id", "")) != "", "hook creates a school-linked PendingCatch")
		var hooked_length := float(pending.get("body_length_m", 0.0))
		_check(hooked_length > 0.0, "natural body length is rolled when the P2 hook event is created")
		var population_before := int(manager.get_school(str(pending.get("school_id", ""))).get("population", 0))
		_check(encounter.begin_retrieval(), "hooked catch enters retrieval separately from hooking")
		var settled := encounter.complete_retrieval(str(pending.get("catch_id", "")))
		_check(bool(settled.get("accepted", false)), "retrieval completion settles through FishResourceManager Authority")
		var catch_result: Dictionary = settled.get("result", {})
		var population_after := int(manager.get_school(str(pending.get("school_id", ""))).get("population", 0))
		_check(population_after == population_before - 1, "one successful catch decrements exactly one authoritative fish")
		var caught_profile := manager.get_species_profile(str(catch_result.get("species_id", "")))
		_check(caught_profile != null and float(catch_result.get("length_m", 0.0)) >= caught_profile.body_length_range_m.x and float(catch_result.get("length_m", 0.0)) <= caught_profile.body_length_range_m.y, "CatchResult length uses the caught species body-length range")
		_check(is_equal_approx(float(catch_result.get("length_m", 0.0)), hooked_length), "settlement preserves the same natural length shown by the display fish")
		var duplicate := encounter.complete_retrieval(str(pending.get("catch_id", "")))
		_check(not bool(duplicate.get("accepted", false)) and int(manager.get_school(str(pending.get("school_id", ""))).get("population", 0)) == population_after, "repeated settlement cannot decrement population twice")
		var stale_school_id := str(pending.get("school_id", ""))
		var stale_species_id := str(pending.get("species_id", ""))
		while int(manager.get_school(stale_school_id).get("population", 0)) > 0:
			manager.request_population_change(stale_school_id, -1)
		var stale_pending := FishingPendingCatch.new()
		stale_pending.catch_id = "stale_validation"
		stale_pending.school_id = stale_school_id
		stale_pending.species_id = stale_species_id
		stale_pending.lure_id = encounter.selected_lure_id
		encounter.pending_catch = stale_pending
		encounter.state = FishingEncounterSystem.State.RETRIEVING
		var exhausted := encounter.complete_retrieval("stale_validation")
		_check(not bool(exhausted.get("accepted", false)), "an exhausted school cannot settle a stale hooked event")
		encounter.stop_trolling()
		mirror.free()

	var finder_school: Dictionary = manager.get_all_school_snapshots()[0]
	var finder_position := _school_position(finder_school)
	var finder_original_boat_position := boat.global_position
	var wave_sampler := manager.get_wave_sampler()
	var wave_time := float(wave_sampler.get("wave_time_seconds"))
	var surface := wave_sampler.sample_physics_surface(Vector3(finder_position.x, 0.0, finder_position.z), wave_time)
	boat.global_position = Vector3(finder_position.x, float(surface.get("height", 0.0)) + 2.0, finder_position.z)
	finder.transducer_offset_local_m = Vector3(0.0, -2.0, 0.0)
	finder.beam_angle_deg = 120.0
	finder.max_slant_range_m = 1000.0
	finder.maximum_water_depth_m = 60.0
	var authority_count_before := manager.get_all_school_snapshots().size()
	var profile_visual_states: Dictionary = {}
	for profile in manager.get_species_profiles():
		profile_visual_states[profile.species_id] = profile.visual_enabled
		profile.visual_enabled = false
	var scan := finder.scan(true)
	_check(bool(scan.get("accepted", false)), "Fish Finder scans using bathymetry, live surface and Authority schools")
	var echoes: Array = scan.get("echoes", [])
	_check(not echoes.is_empty(), "Fish Finder returns at least one real school echo when placed above a school")
	var anonymized := true
	for echo in echoes:
		if echo.has("species_id") or echo.has("bite_probability") or echo.has("school_id"):
			anonymized = false
	_check(anonymized, "Fish Finder echo data does not expose fish identity or catch chance")
	_check(manager.get_all_school_snapshots().size() == authority_count_before, "disabling every species visual does not change authoritative population queries")
	_check(FishFinderSensor.is_within_beam(0.0, 5.0, 42.0, 220.0), "Fish Finder cone accepts targets directly below the transducer")
	_check(not FishFinderSensor.is_within_beam(10.0, 1.0, 42.0, 220.0), "Fish Finder cone rejects targets outside its geometry")
	_check(finder.get_scan_history().size() <= finder.history_capacity, "Fish Finder keeps bounded scan history")
	for profile in manager.get_species_profiles():
		profile.visual_enabled = bool(profile_visual_states.get(profile.species_id, true))
	boat.global_position = finder_original_boat_position

	await _finish(fixture_root, fishing_panel)


func _create_fixture() -> Dictionary:
	var fixture_root := Node3D.new()
	fixture_root.name = "FishingP2TestFixture"
	root.add_child(fixture_root)
	var bathymetry := BathymetryManager.new()
	bathymetry.name = "BathymetryManager"
	bathymetry.georeference = GEOREFERENCE
	fixture_root.add_child(bathymetry)
	var wave_sampler := WaveSampler.new()
	wave_sampler.name = "WaveSampler"
	wave_sampler.wave_settings = WAVE_SETTINGS
	wave_sampler.bathymetry_manager_path = NodePath("../BathymetryManager")
	fixture_root.add_child(wave_sampler)
	var player_boat := Node3D.new()
	player_boat.name = "PlayerBoat"
	fixture_root.add_child(player_boat)
	var boat := FishingTestBoat.new()
	boat.name = "MotionRoot"
	player_boat.add_child(boat)
	var manager := FishResourceManager.new()
	manager.name = "FishResourceManager"
	manager.bathymetry_manager_path = NodePath("../BathymetryManager")
	manager.shallow_seabed_manager_path = NodePath("../ShallowSeabedManager")
	manager.boat_path = NodePath("../PlayerBoat/MotionRoot")
	manager.wave_sampler_path = NodePath("../WaveSampler")
	manager.map_layer_path = NodePath("../FishResourceMap")
	fixture_root.add_child(manager)
	return {"root": fixture_root, "manager": manager, "boat": boat}


func _find_matching_school(manager: FishResourceManager, encounter: FishingEncounterSystem, boat: Node3D) -> Dictionary:
	var schools := manager.get_all_school_snapshots()
	var original_position := boat.global_position
	var original_speed := float(boat.get("speed_mps"))
	var forward := -boat.global_basis.z
	forward.y = 0.0
	forward = forward.normalized()
	for school in schools:
		var profile := manager.get_species_profile(str(school.get("species_id", "")))
		if profile == null or not profile.supported_fishing_methods.has("trolling"):
			continue
		for lure in encounter.get_lure_profiles():
			if not FishingEncounterSystem.lure_matches_profile(profile, lure, "trolling"):
				continue
			if lure.depth_match_weight(float(school.get("activity_depth_m", 0.0))) <= 0.0:
				continue
			var position := _school_position(school)
			boat.global_position = position + forward * encounter.lure_trailing_distance_m
			boat.set("speed_mps", profile.trolling_speed_optimum_mps)
			if encounter.select_lure(lure.lure_id):
				var diagnostics := encounter.evaluate_candidates()
				for candidate in diagnostics.get("valid_candidates", []):
					if str(candidate.get("school_id", "")) == str(school.get("school_id", "")):
						return school
		boat.global_position = original_position
		boat.set("speed_mps", original_speed)
	return {}


func _school_position(school: Dictionary) -> Vector3:
	var value: Array = school.get("world_position", [])
	return Vector3(float(value[0]), float(value[1]), float(value[2])) if value.size() >= 3 else Vector3.ZERO


func _check(condition: bool, label: String) -> void:
	if condition:
		print("[FISHING_P2][PASS] %s" % label)
	else:
		_failures += 1
		push_error("[FISHING_P2][FAIL] %s" % label)


func _finish(fixture_root: Node, fishing_panel: Node) -> void:
	fishing_panel.free()
	fixture_root.free()
	await process_frame
	await process_frame
	print("[FISHING_P2] failures=%d" % _failures)
	quit(0 if _failures == 0 else 1)
