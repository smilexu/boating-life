extends SceneTree

const GEOREFERENCE := preload("res://resources/oresund_georeference.tres")
const WAVE_SETTINGS := preload("res://resources/sea_waves.tres")
const POWERBOAT_MOUNT := preload("res://resources/fishing/rod_mounts/starter_cargo_boat.tres")
const FISHING_DEBUG_PANEL_SCRIPT := preload("res://scripts/fishing_debug_panel.gd")

class FishingTestBoat extends Node3D:
	var speed_mps := 0.0
	var cruise_speed_mps := 7.0

	func is_sailing_active() -> bool:
		return false

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var fixture := _create_fixture()
	var fixture_root: Node3D = fixture["root"]
	var manager := fixture["manager"] as FishResourceManager
	var system := fixture["system"] as FishingRodSystem
	var boat := fixture["boat"] as FishingTestBoat
	for _frame in range(4):
		await process_frame
	var encounter := manager.get_fishing_encounter_system()
	_check(encounter != null and system.get_encounter_system() == encounter, "simulation uses the existing P2 encounter instance")
	_check(system.visuals_enabled == false, "headless test skips rendering while exercising the shared presentation controller")
	boat.global_position = Vector3(1000000.0, 0.0, 1000000.0)
	boat.speed_mps = 0.0
	var initial_diagnostics := encounter.evaluate_candidates()
	_check(encounter.state == FishingEncounterSystem.State.IDLE and initial_diagnostics.get("valid_candidates", []).is_empty(), "fixture has no usable school candidate and zero boat speed")
	var population_before := _total_population(manager)
	var initial_result := encounter.last_catch_result
	var idle_rng_state := encounter._rng.state

	# Match the main scene's ready order: BoatHUD builds F3 before the later
	# FishResourceManager sibling has loaded its default profile resources.
	var registered_profiles := manager.species_profiles.duplicate()
	manager.species_profiles.clear()
	var panel = FISHING_DEBUG_PANEL_SCRIPT.new()
	root.add_child(panel)
	panel.configure(manager, system)
	await process_frame
	var species_option := panel.find_child("SimulatedCatchSpecies", true, false) as OptionButton
	var simulate_button := panel.find_child("SimulatedCatchStart", true, false) as Button
	_check(species_option != null and species_option.item_count == 1 and species_option.get_item_text(0) != "", "F3 shows a visible unavailable state while fish profiles are still loading")
	_check(species_option.disabled and simulate_button.disabled, "F3 prevents starting a simulation until a species is available")
	manager.species_profiles = registered_profiles
	panel._resolve_systems()
	_check(species_option.item_count == 2, "F3 populates Sea Trout and Needlefish when manager profiles become ready")
	_check(not species_option.disabled and not simulate_button.disabled, "F3 enables species selection and simulation after profile registration")
	_check(str(species_option.get_item_metadata(0)) == "sea_trout" and str(species_option.get_item_metadata(1)) == "needlefish", "F3 species choices use stable species IDs")
	species_option.select(1)
	species_option.item_selected.emit(1)
	_check(is_equal_approx(float((panel.find_child("SimulatedFishLengthCm", true, false) as SpinBox).value), 60.0), "selecting Needlefish applies its debug preview length")
	species_option.select(0)
	species_option.item_selected.emit(0)
	simulate_button.pressed.emit()
	_check(system.presentation_source == FishingRodSystem.PresentationSource.DEBUG_SIMULATION, "F3 Simulate Catch button starts the shared presentation")
	var intensity_spin := panel.find_child("HangingStruggleIntensity", true, false) as SpinBox
	_check(intensity_spin != null and is_equal_approx(intensity_spin.min_value, 0.5) and is_equal_approx(intensity_spin.max_value, 4.0), "F3 exposes the runtime hanging-struggle strength range")
	if intensity_spin != null:
		_check(is_equal_approx(intensity_spin.value, 3.0) and intensity_spin.editable, "F3 starts with 3x intensity and allows edits during simulation")
		intensity_spin.value = 2.4
		_check(is_equal_approx(system.get_hanging_struggle_intensity(), 2.4), "F3 intensity changes are applied immediately to the active simulation")
		intensity_spin.value = 3.0
	(panel.find_child("SimulatedCatchStop", true, false) as Button).pressed.emit()
	_check(system.presentation_source == FishingRodSystem.PresentationSource.NONE, "F3 Stop Simulation button cleans up the preview")
	_check(panel.find_child("SimulatedCatchStart", true, false) is Button, "F3 builds the independent simulated-catch entry point")
	_check(not (panel.find_child("SimulatedCatchStart", true, false) as Button).disabled, "F3 simulation is available with no nearby fish school")
	_check(panel.find_child("AdvancedP2Controls", true, false).visible == false, "manual P2 controls are collapsed under Advanced by default")
	_check(panel.find_child("SimulatedFishLengthCm", true, false) is SpinBox, "F3 exposes a natural body-length preview control")
	var previous_locale := TranslationServer.get_locale()
	for locale in ["en", "zh_CN"]:
		TranslationServer.set_locale(locale)
		for localization_key in ["fishing.debug.section.simulation", "fishing.debug.sim_start", "fishing.debug.sim_pause", "fishing.debug.sim_seek", "fishing.debug.phase_start_format", "fishing.debug.unit.cm", "fishing.debug.visual.simulating", "fishing.debug.hanging_intensity"]:
			_check(TranslationServer.translate(localization_key) != localization_key, "%s localization resolves: %s" % [locale, localization_key])
	TranslationServer.set_locale(previous_locale)

	system.hook_strike_seconds = 0.10
	system.fish_struggle_seconds = 0.20
	system.progressive_retrieval_seconds = 0.30
	system.surface_landing_seconds = 0.40
	system.catch_presentation_seconds = 0.50
	var start := system.start_debug_simulated_catch("sea_trout", 65.0, 92841)
	_check(bool(start.get("accepted", false)), "debug simulation starts at idle with no school and no boat speed")
	_check(encounter.pending_catch == null and encounter.last_catch_result == initial_result, "debug simulation creates no real PendingCatch or CatchResult")
	_check(encounter._rng.state == idle_rng_state, "starting debug simulation leaves the P2 encounter RNG untouched")
	_check(is_equal_approx(float(start.get("length_m", 0.0)), 0.65), "selected body length is passed to the presentation context")
	_check(int(system.get_presentation_snapshot().get("simulation_seed", 0)) == 92841, "animation seed is retained for deterministic replay")
	_check(system.presentation_source == FishingRodSystem.PresentationSource.DEBUG_SIMULATION, "simulated catch has an explicit debug-only source")

	var expected_phases := ["HOOK_STRIKE", "FISH_STRUGGLE", "PROGRESSIVE_RETRIEVAL", "SURFACE_LANDING", "CATCH_PRESENTATION"]
	var expected_remaining := [0.10, 0.20, 0.30, 0.40, 0.50]
	for phase_index in range(expected_phases.size()):
		_check(system.get_debug_simulation_phase_start_seconds(phase_index) >= 0.0, "phase seek time is available for stage %d" % phase_index)
		_check(system.debug_seek_simulation_phase(phase_index), "debug simulation can seek to stage %d" % phase_index)
		var phase_snapshot := system.get_presentation_snapshot()
		_check(str(phase_snapshot.get("phase", "")) == expected_phases[phase_index], "seek reconstructs stage %s" % expected_phases[phase_index])
		_check(absf(float(phase_snapshot.get("phase_remaining_seconds", 0.0)) - expected_remaining[phase_index]) < 0.02, "seek restores the stage's start-time animation state")
		_check(encounter.last_catch_result == initial_result and encounter.pending_catch == null, "stage seek never settles or creates a real catch")

	_check(system.debug_set_simulation_paused(true), "debug playback can pause")
	system.hook_strike_seconds = 10.0
	system.debug_seek_simulation_phase(0)
	system.set_process(false)
	var paused_remaining := float(system.get_presentation_snapshot().get("phase_remaining_seconds", 0.0))
	system._process(0.2)
	_check(is_equal_approx(float(system.get_presentation_snapshot().get("phase_remaining_seconds", 0.0)), paused_remaining), "pause freezes only the presentation timeline")
	_check(system.debug_set_simulation_paused(false), "debug playback can resume")
	system.debug_set_simulation_speed(0.5)
	system._process(0.2)
	var half_speed_remaining := float(system.get_presentation_snapshot().get("phase_remaining_seconds", 0.0))
	_check(is_equal_approx(half_speed_remaining, paused_remaining - 0.1), "half speed advances half as much as the base presentation clock")
	system.debug_set_simulation_speed(2.0)
	system._process(0.2)
	var double_speed_remaining := float(system.get_presentation_snapshot().get("phase_remaining_seconds", 0.0))
	_check(is_equal_approx(double_speed_remaining, half_speed_remaining - 0.4), "double speed advances twice the base presentation clock")
	system.set_process(true)
	_check(system.has_debug_simulation_replay() and system.debug_replay_simulated_catch(), "replay restarts the same species, length and seed")
	_check(system.get_presentation_snapshot().get("species_id", "") == "sea_trout" and int(system.get_presentation_snapshot().get("simulation_seed", 0)) == 92841, "replay preserves the original test identity")
	_check(system.debug_stop_simulated_catch(), "debug playback can stop and clean up")
	_check(system.presentation_source == FishingRodSystem.PresentationSource.NONE and system.visual_state == FishingRodSystem.VisualState.IDLE, "stopping simulation restores idle state and clears presentation")

	# A live troll can remain active while the local presentation runs. Encounter
	# time and RNG are frozen, then continue from the new wall-clock baseline.
	system.cast_duration_seconds = 0.01
	_check(system.start_trolling(), "real trolling can start normally before a preview")
	await create_timer(0.04).timeout
	_check(encounter.state == FishingEncounterSystem.State.TROLLING, "P2 trolling remains active after line deployment")
	encounter._hazard_accumulated = 0.37
	var rng_state_before := encounter._rng.state
	var hazard_before := encounter._hazard_accumulated
	var second_start := system.start_debug_simulated_catch("needlefish", 60.0, 2026)
	_check(bool(second_start.get("accepted", false)) and encounter.state == FishingEncounterSystem.State.TROLLING, "simulation does not cancel existing real trolling")
	await create_timer(0.10).timeout
	_check(encounter._rng.state == rng_state_before and is_equal_approx(encounter._hazard_accumulated, hazard_before), "P2 encounter RNG and accumulated hazard do not advance during preview")
	_check(system.debug_stop_simulated_catch(), "preview can be stopped while real trolling is active")
	_check(encounter.state == FishingEncounterSystem.State.TROLLING and not encounter._debug_presentation_paused, "stopping preview resumes the same real trolling state")
	system.stop_trolling()
	_check(encounter.state == FishingEncounterSystem.State.IDLE, "real trolling can still be stopped through the normal P2 API")

	# Advance each local phase directly with deterministic frame deltas. This is
	# still the production update path, but avoids timing-sensitive test sleeps.
	system.hook_strike_seconds = 0.10
	system.fish_struggle_seconds = 0.10
	system.progressive_retrieval_seconds = 0.10
	system.surface_landing_seconds = 0.10
	system.catch_presentation_seconds = 0.10
	_check(bool(system.start_debug_simulated_catch("sea_trout", 65.0, 77).get("accepted", false)), "full preview playback starts without fishing prerequisites")
	system.set_process(false)
	system._process(0.11)
	_check(system.get_presentation_phase_name() == "FISH_STRUGGLE", "hook strike automatically advances into fish struggle")
	system._process(0.11)
	_check(system.get_presentation_phase_name() == "PROGRESSIVE_RETRIEVAL", "fish struggle automatically advances into retrieval")
	system._process(0.11)
	_check(system.get_presentation_phase_name() == "SURFACE_LANDING", "retrieval automatically advances into surface and landing")
	system._process(0.11)
	_check(system.get_presentation_phase_name() == "CATCH_PRESENTATION", "surface and landing automatically advances to preview presentation")
	system._process(0.11)
	system.set_process(true)
	_check(system.presentation_source == FishingRodSystem.PresentationSource.NONE and system.visual_state == FishingRodSystem.VisualState.IDLE, "all five preview stages advance and clean up automatically")
	_check(encounter.pending_catch == null and encounter.last_catch_result == initial_result, "complete debug preview leaves P2 catch state untouched")
	_check(_total_population(manager) == population_before, "complete debug preview does not consume Authority fish")
	_check(encounter._rng.state == rng_state_before, "debug playback does not draw from the P2 encounter RNG")

	panel.queue_free()
	fixture_root.queue_free()
	await process_frame
	await process_frame
	print("[FISHING_P3_2] failures=%d" % _failures)
	quit(0 if _failures == 0 else 1)


func _create_fixture() -> Dictionary:
	var fixture_root := Node3D.new()
	fixture_root.name = "FishingP3_2TestFixture"
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
	var boat := FishingTestBoat.new()
	boat.name = "MotionRoot"
	boat.position = Vector3(1000000.0, 0.0, 1000000.0)
	fixture_root.add_child(boat)
	var visual_root := Node3D.new()
	visual_root.name = "VisualRoot"
	boat.add_child(visual_root)
	var sailboat := Node3D.new()
	sailboat.name = "SailingBoat8m"
	fixture_root.add_child(sailboat)
	var sail_visual_root := Node3D.new()
	sail_visual_root.name = "VisualRoot"
	sailboat.add_child(sail_visual_root)
	var manager := FishResourceManager.new()
	manager.name = "FishResourceManager"
	manager.bathymetry_manager_path = NodePath("../BathymetryManager")
	manager.boat_path = NodePath("../MotionRoot")
	manager.wave_sampler_path = NodePath("../WaveSampler")
	manager.map_layer_path = NodePath("../FishResourceMap")
	fixture_root.add_child(manager)
	var system := FishingRodSystem.new()
	system.name = "FishingRodSystem"
	system.visuals_enabled = false
	system.boat_controller_path = NodePath("../MotionRoot")
	system.fish_manager_path = NodePath("../FishResourceManager")
	system.wave_sampler_path = NodePath("../WaveSampler")
	system.powerboat_visual_root_path = NodePath("../MotionRoot/VisualRoot")
	system.sailboat_visual_root_path = NodePath("../SailingBoat8m/VisualRoot")
	system.powerboat_mount_profile = POWERBOAT_MOUNT
	system.sailboat_mount_profile = POWERBOAT_MOUNT
	fixture_root.add_child(system)
	return {"root": fixture_root, "manager": manager, "system": system, "boat": boat}


func _total_population(manager: FishResourceManager) -> int:
	var total := 0
	for school in manager.get_all_school_snapshots():
		total += int(school.get("population", 0))
	return total


func _check(condition: bool, label: String) -> void:
	if condition:
		print("[FISHING_P3_2][PASS] %s" % label)
	else:
		_failures += 1
		push_error("[FISHING_P3_2][FAIL] %s" % label)
