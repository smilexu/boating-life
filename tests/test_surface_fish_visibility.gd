extends SceneTree

const MAIN_SCENE := preload("res://scenes/main.tscn")

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene := MAIN_SCENE.instantiate()
	root.add_child(scene)
	await process_frame
	var manager := scene.get_node("FishResourceManager") as FishResourceManager
	var schools := manager.get_all_school_snapshots()
	var state_counts := {
		"needlefish": {"visual": 0, "logical": 0},
		"herring": {"visual": 0, "logical": 0},
		"sea_trout": {"visual": 0, "logical": 0},
	}
	var profile_counts := {"needlefish": 0, "herring": 0, "sea_trout": 0}
	var roundtrip_checked := {"needlefish": false, "herring": false, "sea_trout": false}
	for school in schools:
		var species_id := str(school.get("species_id", ""))
		if not state_counts.has(species_id):
			continue
		var state := FishSchoolState.from_dictionary(school)
		if not roundtrip_checked[species_id]:
			_check(state != null, "%s school snapshot deserializes with its surface state" % species_id)
		if state == null:
			continue
		if not roundtrip_checked[species_id]:
			_check(is_equal_approx(state.activity_depth_m, float(school["activity_depth_m"])), "%s activity depth survives snapshot roundtrip" % species_id)
			roundtrip_checked[species_id] = true
		var render_state := manager.get_school_render_state(school)
		state_counts[species_id][render_state] = int(state_counts[species_id][render_state]) + 1
		profile_counts[species_id] += 1
	_check(profile_counts["needlefish"] > 0 and profile_counts["herring"] > 0 and profile_counts["sea_trout"] > 0, "three surface-cycle species use the shared authority")
	for species_id in ["needlefish", "herring", "sea_trout"]:
		_check(int(state_counts[species_id]["visual"]) > 0, "%s authority contains visual-layer schools" % species_id)
		_check(int(state_counts[species_id]["logical"]) > 0, "%s authority contains deep logical schools" % species_id)

	var map_schools := manager.get_map_distribution(["needlefish", "herring", "sea_trout"])
	var map_has_both_states := false
	var map_states := {"visual": false, "logical": false}
	for school in map_schools:
		if school.has("render_state"):
			map_states[str(school["render_state"])] = true
	map_has_both_states = bool(map_states["visual"]) and bool(map_states["logical"])
	_check(map_has_both_states, "map data exposes visual and logical schools from the same resource snapshots")
	var map_layer := scene.get_node("FishResourceMap") as FishResourceMap
	map_layer.set_map_open(true)
	var map_canvas := map_layer.find_child("ResourceDistributionMap", true, false) as FishResourceMapCanvas
	var map_rows: Array = map_canvas.get("_schools") if map_canvas != null else []
	var visible_map_states := {"visual": false, "logical": false}
	for school in map_rows:
		visible_map_states[str(school.get("render_state", "visual"))] = true
	_check(map_layer.is_map_open() and bool(visible_map_states["visual"]) and bool(visible_map_states["logical"]), "opening the full M chart shows both marker states")
	map_layer.set_map_open(false)

	var renderer := scene.get_node("FishResourceManager/FishSchoolRenderer") as FishSchoolRenderer
	var bathymetry := manager.get_bathymetry_manager()
	var boat := scene.get_node("PlayerBoat/MotionRoot") as Node3D
	var hud := scene.get_node("PlayerBoat/BoatHUD") as CanvasLayer
	var original_boat_transform := boat.global_transform
	var tried_species := {"needlefish": false, "herring": false, "sea_trout": false}
	for species_id in ["needlefish", "herring", "sea_trout"]:
		var school_id := _nearest_visual_school_id(schools, species_id, boat.global_position, manager)
		if school_id.is_empty():
			print("[SURFACE_FISH_TEST] skipped F3 %s: no visual school inside the configured search range" % species_id)
			continue
		tried_species[species_id] = true
		hud.call("_on_fish_observation_pressed", species_id)
		var selected_id := str(hud.get("_selected_fish_school_id"))
		var selected := manager.get_school(selected_id)
		_check(not selected.is_empty() and str(selected["species_id"]) == species_id, "F3 selects a %s visual school" % species_id)
		if selected.is_empty():
			continue
		_check(manager.get_school_render_state(selected) == "visual" and float(selected["activity_depth_m"]) <= 6.0, "F3 never selects a deep logical %s school" % species_id)
		var selected_position: Array = selected["world_position"]
		var boat_distance := Vector2(boat.global_position.x - float(selected_position[0]), boat.global_position.z - float(selected_position[2])).length()
		_check(boat_distance >= 17.5 and boat_distance <= 23.5, "F3 stops the boat outside the fish school's disturbance range")
		_check(not renderer.is_observation_active(), "F3 keeps the boat camera until underwater observation is requested")
		var before_position: Array = selected_position.duplicate()
		var before_population := int(selected["population"])
		renderer.call("_update_visible_fish", 0.16)
		var visual_diagnostics := renderer.get_school_visual_debug(selected_id, boat.global_position)
		var nearest_visual_position: Variant = visual_diagnostics.get("visual_nearest_world_position", Vector3(NAN, NAN, NAN))
		_check(
			int(visual_diagnostics.get("visual_instances_bound_to_school", 0)) > 0
			and nearest_visual_position is Vector3
			and is_finite(nearest_visual_position.x)
			and float(visual_diagnostics.get("visual_nearest_anchor_offset_m", -1.0)) >= 0.0,
			"visual-school diagnostics expose the Authority-linked MultiMesh instance position and offset"
		)
		if nearest_visual_position is Vector3 and is_finite(nearest_visual_position.x) and is_finite(nearest_visual_position.y) and is_finite(nearest_visual_position.z):
			var observation_boat_transform := boat.global_transform
			var wave_sampler := manager.get_wave_sampler()
			var fish_xz := Vector3(nearest_visual_position.x, 0.0, nearest_visual_position.z)
			var local_surface: Dictionary = wave_sampler.sample_physics_surface(fish_xz, wave_sampler.wave_time_seconds)
			boat.global_position = Vector3(nearest_visual_position.x, float(local_surface.get("height", 0.0)) + 0.55, nearest_visual_position.z)
			var finder := manager.get_fish_finder_sensor()
			var proximity_scan := finder.scan(true)
			var matched_diagnostic: Dictionary = {}
			for candidate_variant in proximity_scan.get("school_diagnostics", []):
				if str(candidate_variant.get("school_id", "")) == selected_id:
					matched_diagnostic = candidate_variant
					break
			var anchor_values: Array = selected.get("world_position", [])
			var probe_position: Vector3 = proximity_scan.get("probe_world_position", Vector3.ZERO)
			var measured_anchor_distance := Vector2(float(anchor_values[0]) - probe_position.x, float(anchor_values[2]) - probe_position.z).length()
			_check(not matched_diagnostic.is_empty(), "sonar diagnostic retains the visible school's Authority ID near the visually selected fish")
			if not matched_diagnostic.is_empty():
				var school_echo: Dictionary = {}
				for echo_variant in proximity_scan.get("echoes", []):
					if str(echo_variant.get("school_id", "")) == selected_id:
						school_echo = echo_variant
						break
				var spatial_reason := str(matched_diagnostic.get("rejection_reason", ""))
				_check(
					is_equal_approx(float(matched_diagnostic.get("anchor_horizontal_distance_m", -1.0)), measured_anchor_distance)
					and bool(matched_diagnostic.get("hit", false))
					and spatial_reason in ["partial_overlap", "school_volume_detected"]
					and str(school_echo.get("school_id", "")) == selected_id,
					"sonar detects the Authority school's aggregate volume around rendered fish without sampling renderer individuals"
				)
				_check(float(matched_diagnostic.get("overlap_factor", 0.0)) > 0.0 and float(school_echo.get("echo_strength", 0.0)) > 0.0, "real-school beam overlap produces one finite-strength aggregate echo")
				print("[SURFACE_FISH_TEST][SONAR] species=%s school=%s visual_offset=%.2fm anchor_distance=%.2fm target_depth=%.2fm beam_radius=%.2fm school_radius=%.2fm overlap=%.3f echo_strength=%.3f reason=%s" % [species_id, selected_id, float(visual_diagnostics.get("visual_nearest_anchor_offset_m", -1.0)), float(matched_diagnostic.get("anchor_horizontal_distance_m", -1.0)), float(matched_diagnostic.get("target_depth_below_transducer_m", -1.0)), float(matched_diagnostic.get("beam_radius_m", -1.0)), float(matched_diagnostic.get("effective_school_radius_m", -1.0)), float(matched_diagnostic.get("overlap_factor", 0.0)), float(matched_diagnostic.get("final_echo_strength", 0.0)), spatial_reason])
			boat.global_transform = observation_boat_transform
		var unchanged := manager.get_school(selected_id)
		_check(unchanged["world_position"] == before_position and int(unchanged["population"]) == before_population, "local observation changes no shared fish position or population")
		var reveal_count := int(bathymetry.water_material.get_shader_parameter("surface_fish_reveal_count"))
		if reveal_count == 0:
			print("[SURFACE_FISH_TEST] reveal_debug species=%s school=%s depth=%.3f state=%s population=%d candidates=%d boat_distance=%.1f" % [species_id, selected_id, float(selected.get("activity_depth_m", -1.0)), str(selected.get("surface_activity_state", "")), int(selected.get("population", 0)), renderer._surface_reveal_candidates.size(), boat_distance])
		_check(reveal_count > 0 and reveal_count <= 8, "a nearby surface school activates the bounded local water reveal")
		hud.call("_on_fish_observation_camera_pressed")
		_check(renderer.is_observation_active(), "underwater camera remains an explicit manual action")
		hud.call("_on_fish_observation_camera_return_pressed")
		_check(not renderer.is_observation_active(), "manual underwater observation returns to the boat camera")
		boat.global_transform = original_boat_transform
		await process_frame
	_check(tried_species["needlefish"] or tried_species["herring"] or tried_species["sea_trout"], "at least one F3 surface-species observation was exercised in the local test region")

	print("[SURFACE_FISH_TEST] schools=%d states=%s map_states=%s" % [schools.size(), state_counts, map_states])
	scene.queue_free()
	await process_frame
	print("[SURFACE_FISH_TEST] failures=%d" % _failures)
	quit(0 if _failures == 0 else 1)


func _nearest_visual_school_id(schools: Array[Dictionary], species_id: String, origin: Vector3, manager: FishResourceManager) -> String:
	var nearest_id := ""
	var nearest_score := INF
	var profile: FishSpeciesProfile
	for candidate in manager.get_species_profiles():
		if candidate.species_id == species_id:
			profile = candidate
			break
	if profile == null:
		return nearest_id
	for school in schools:
		if str(school.get("species_id", "")) != species_id:
			continue
		var depth := float(school.get("activity_depth_m", INF))
		if depth > profile.logical_depth_threshold_m - 0.4:
			continue
		var position: Array = school.get("world_position", [])
		if position.size() != 3:
			continue
		var distance := Vector2(float(position[0]) - origin.x, float(position[2]) - origin.z).length()
		if distance > 5000.0:
			continue
		var surface_bonus := 0.0 if depth <= 2.0 else 10000.0
		var score := surface_bonus + distance
		if score < nearest_score:
			nearest_score = score
			nearest_id = str(school["school_id"])
	return nearest_id


func _check(condition: bool, label: String) -> void:
	if condition:
		print("[PASS] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] %s" % label)
