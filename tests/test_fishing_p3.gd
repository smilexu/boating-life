extends SceneTree

const GEOREFERENCE := preload("res://resources/oresund_georeference.tres")
const WAVE_SETTINGS := preload("res://resources/sea_waves.tres")
const POWERBOAT_MOUNT := preload("res://resources/fishing/rod_mounts/starter_cargo_boat.tres")
const SAILBOAT_MOUNT := preload("res://resources/fishing/rod_mounts/nordic28.tres")

class FishingTestBoat extends Node3D:
	var speed_mps := 0.0
	var cruise_speed_mps := 7.0

	func is_sailing_active() -> bool:
		return false

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var boat_scene := ResourceLoader.load("res://scenes/Boat.tscn") as PackedScene
	_check(boat_scene != null, "Boat scene with the rod system loads")
	_check(POWERBOAT_MOUNT is FishingRodMountProfile and SAILBOAT_MOUNT is FishingRodMountProfile, "both hull-specific rod mount profiles load")
	_check(POWERBOAT_MOUNT.rod_length_m >= 2.1 and POWERBOAT_MOUNT.rod_length_m <= 2.4 and POWERBOAT_MOUNT.guide_count >= 6, "rod dimensions and guide count meet the first-version range")
	var panel := FishingPlayerPanel.new()
	root.add_child(panel)
	_check(panel.find_child("LureSelector", true, false) != null and panel.find_child("TrollingActionButton", true, false) != null, "player trolling panel builds lure and start controls")
	var rig_script := ResourceLoader.load("res://scripts/fishing_rod_rig.gd")
	_check(rig_script != null, "procedural rod rig script loads")
	await _test_rig_geometry()

	var fixture := _create_fixture()
	var fixture_root: Node3D = fixture["root"]
	for _frame in range(4):
		await process_frame
	var manager := fixture["manager"] as FishResourceManager
	var encounter := manager.get_fishing_encounter_system()
	var system := fixture["system"] as FishingRodSystem
	var motion_root := fixture["boat"] as Node3D
	var boat := fixture["test_boat"] as FishingTestBoat
	_check(encounter != null and system.get_encounter_system() == encounter, "P3 controller consumes the manager's P2 encounter instance")
	_check(system.visuals_enabled == false, "headless lifecycle fixture disables only mesh creation")
	var school := _find_matching_school(manager, encounter, boat)
	_check(not school.is_empty(), "P3 fixture finds a real Authority school compatible with a lure")
	if not school.is_empty():
		system.cast_duration_seconds = 0.04
		system.hook_strike_seconds = 0.04
		system.fish_struggle_seconds = 0.04
		system.progressive_retrieval_seconds = 0.20
		system.surface_landing_seconds = 0.04
		system.catch_presentation_seconds = 0.20
		_check(system.start_trolling(), "player P3 start calls the P2 start API")
		await create_timer(0.08).timeout
		_check(system.get_visual_state_name() == "TROLLING", "cast phase transitions into continuous trolling")
		encounter.set_random_seed(7219)
		var hook_result := encounter.debug_force_hook_valid_candidate()
		var pending := encounter.pending_catch
		_check(bool(hook_result.get("accepted", false)) and pending != null, "real P2 hook event enters the visual controller")
		_check(not bool(system.start_debug_simulated_catch("sea_trout", 65.0, 9).get("accepted", false)), "a real pending catch blocks debug simulation")
		var pending_length := pending.body_length_m if pending != null else 0.0
		var profile := manager.get_species_profile(pending.species_id) if pending != null else null
		_check(profile != null and pending_length >= profile.body_length_range_m.x and pending_length <= profile.body_length_range_m.y, "natural catch length is fixed on PendingCatch at hook time")
		_check(system.get_visual_state_name() == "HOOKED", "hook event starts the rod-load state")
		_check(system.get_presentation_phase_name() == "HOOK_STRIKE", "the first automatic phase is Hook Strike")
		var active_catch_id := str(system.get_presentation_snapshot().get("catch_id", ""))
		system._on_catch_cancelled("stale_catch_id", "test")
		_check(str(system.get_presentation_snapshot().get("catch_id", "")) == active_catch_id, "a stale cancellation ID cannot replace the active fight")
		await create_timer(0.05).timeout
		_check(system.get_presentation_phase_name() == "FISH_STRUGGLE", "the second automatic phase is Fish Struggle")
		await create_timer(0.06).timeout
		_check(encounter.state == FishingEncounterSystem.State.RETRIEVING and system.get_visual_state_name() == "REELING", "hook reaction automatically begins P2 retrieval")
		_check(system.get_presentation_phase_name() == "PROGRESSIVE_RETRIEVAL", "the third automatic phase starts with P2 retrieval")
		await create_timer(0.08).timeout
		_check(system.get_presentation_phase_name() == "PROGRESSIVE_RETRIEVAL", "retrieval remains progressive before surface landing")
		await create_timer(0.14).timeout
		_check(encounter.last_catch_result != null, "reel animation requests the P2 authoritative settlement")
		if encounter.last_catch_result != null:
			_check(is_equal_approx(encounter.last_catch_result.length_m, pending_length), "display fish length remains identical to CatchResult length")
		_check(system.get_presentation_phase_name() == "CATCH_PRESENTATION", "settlement enters the final catch presentation phase")
		await create_timer(0.23).timeout
		_check(encounter.state == FishingEncounterSystem.State.TROLLING, "successful catch resumes the trolling loop")
		var previous_catch_id := encounter.last_catch_result.catch_id if encounter.last_catch_result != null else ""
		var second_school := _find_matching_school(manager, encounter, boat)
		if not second_school.is_empty():
			var second_hook := encounter.debug_force_hook_valid_candidate()
			_check(bool(second_hook.get("accepted", false)), "a second valid P2 hook can start a cancelable visual fight")
			if bool(second_hook.get("accepted", false)):
				system.stop_trolling()
				await process_frame
				_check(encounter.state == FishingEncounterSystem.State.IDLE and system.get_visual_state_name() == "IDLE", "stopping during a fight cancels and clears presentation state")
				_check(encounter.last_catch_result != null and encounter.last_catch_result.catch_id == previous_catch_id, "cancelled fight does not create or replace a CatchResult")
		system.stop_trolling()
		_check(encounter.state == FishingEncounterSystem.State.IDLE, "player stop returns the P2 encounter to idle")

	await _finish(fixture_root, panel)


func _test_rig_geometry() -> void:
	var rig := FishingRodRig.new()
	rig.name = "FishingRodRigGeometryTest"
	root.add_child(rig)
	rig.configure(POWERBOAT_MOUNT)
	var hull := Node3D.new()
	hull.name = "VisualDistanceHull"
	root.add_child(hull)
	var visual_distance := rig.get_visual_trailing_distance_from_hull(hull)
	_check(visual_distance > POWERBOAT_MOUNT.line_out_length_m and visual_distance < POWERBOAT_MOUNT.line_out_length_m + POWERBOAT_MOUNT.rod_length_m, "visual lure distance includes rod-tip offset and remains independent of P2's statistical 8 m trailing point")
	hull.queue_free()
	var rod_multimesh := rig.find_child("RodSegments", true, false) as MultiMeshInstance3D
	var guide_multimesh := rig.find_child("LineGuides", true, false) as MultiMeshInstance3D
	var line_multimesh := rig.find_child("TrollingLine", true, false) as MultiMeshInstance3D
	_check(rod_multimesh != null and rod_multimesh.multimesh.instance_count == POWERBOAT_MOUNT.rod_segment_count, "rod uses fixed-count tapered segments")
	_check(guide_multimesh != null and guide_multimesh.multimesh.instance_count == POWERBOAT_MOUNT.guide_count, "line guides use fixed-count instances")
	var initial_tip := rig.get_rod_tip_local()
	rig.set_rod_load(1.0)
	rig.set_line_active(true)
	rig.set_line_points_world(Vector3(0.0, 0.0, 3.0), Vector3(0.0, -0.8, 4.5))
	for _frame in range(8):
		await process_frame
	_check(rig.get_rod_tip_local().y < initial_tip.y - 0.04, "hook load bends the tip gradually while the root stays mounted")
	_check(line_multimesh != null and line_multimesh.visible, "line segments activate through the reel and guides")
	for species_id in ["needlefish", "sea_trout"]:
		var profile := _load_species_profile(species_id)
		_check(profile != null and rig.set_catch_visual(profile, profile.body_length_range_m.x), "%s temporary catch model loads at natural length" % species_id)
		_check(rig.find_child("TemporaryCatchVisual", true, false) != null, "%s catch model gets a temporary visual instance" % species_id)
		if profile != null:
			var orientation := FishSchoolRenderer.basis_for_model_heading(Vector3.FORWARD, profile.model_forward_axis)
			var model_head_axis := Vector3.RIGHT if profile.model_forward_axis == 0 else Vector3.LEFT
			_check((orientation * model_head_axis).dot(Vector3.FORWARD) > 0.99, "%s catch model nose axis faces from stern toward the boat" % species_id)
		await process_frame
		if profile != null:
			rig.clear_catch_visual()
	rig.queue_free()
	await process_frame
	await process_frame


func _load_species_profile(species_id: String) -> FishSpeciesProfile:
	return ResourceLoader.load("res://resources/fish_species/%s.tres" % species_id) as FishSpeciesProfile


func _create_fixture() -> Dictionary:
	var fixture_root := Node3D.new()
	fixture_root.name = "FishingP3TestFixture"
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
	var motion_root := FishingTestBoat.new()
	motion_root.name = "MotionRoot"
	motion_root.position = Vector3(0.0, 0.0, 0.0)
	fixture_root.add_child(motion_root)
	var visual_root := Node3D.new()
	visual_root.name = "VisualRoot"
	motion_root.add_child(visual_root)
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
	system.sailboat_mount_profile = SAILBOAT_MOUNT
	fixture_root.add_child(system)
	return {"root": fixture_root, "manager": manager, "system": system, "boat": motion_root, "test_boat": motion_root}


func _find_matching_school(manager: FishResourceManager, encounter: FishingEncounterSystem, boat: FishingTestBoat) -> Dictionary:
	var aft := Vector3.BACK
	for school in manager.get_all_school_snapshots():
		var school_position := _school_position(school)
		var profile := manager.get_species_profile(str(school.get("species_id", "")))
		if profile == null or not profile.supported_fishing_methods.has("trolling"):
			continue
		for lure in encounter.get_lure_profiles():
			if not FishingEncounterSystem.lure_matches_profile(profile, lure, "trolling"):
				continue
			if lure.depth_match_weight(float(school.get("activity_depth_m", 0.0))) <= 0.0:
				continue
			encounter.select_lure(lure.lure_id)
			boat.global_position = school_position - aft * encounter.lure_trailing_distance_m
			boat.speed_mps = profile.trolling_speed_optimum_mps
			for candidate in encounter.evaluate_candidates().get("valid_candidates", []):
				if str(candidate.get("school_id", "")) == str(school.get("school_id", "")):
					return school
	return {}


func _school_position(school: Dictionary) -> Vector3:
	var values: Array = school.get("world_position", [])
	return Vector3(float(values[0]), float(values[1]), float(values[2])) if values.size() >= 3 else Vector3.ZERO


func _check(condition: bool, label: String) -> void:
	if condition:
		print("[FISHING_P3][PASS] %s" % label)
	else:
		_failures += 1
		push_error("[FISHING_P3][FAIL] %s" % label)


func _finish(fixture_root: Node, panel: Node) -> void:
	panel.free()
	fixture_root.free()
	await process_frame
	await process_frame
	print("[FISHING_P3] failures=%d" % _failures)
	quit(0 if _failures == 0 else 1)

