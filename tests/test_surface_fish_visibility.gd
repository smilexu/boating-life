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
	}
	var profile_counts := {"needlefish": 0, "herring": 0}
	var roundtrip_checked := {"needlefish": false, "herring": false}
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
	_check(profile_counts["needlefish"] > 0 and profile_counts["herring"] > 0, "needlefish and herring remain in the shared authority")
	for species_id in ["needlefish", "herring"]:
		_check(int(state_counts[species_id]["visual"]) > 0, "%s authority contains visual-layer schools" % species_id)
		_check(int(state_counts[species_id]["logical"]) > 0, "%s authority contains deep logical schools" % species_id)

	var map_schools := manager.get_map_distribution(["needlefish", "herring"])
	var map_has_both_states := false
	var map_states := {"visual": false, "logical": false}
	for school in map_schools:
		if school.has("render_state"):
			map_states[str(school["render_state"])] = true
	map_has_both_states = bool(map_states["visual"]) and bool(map_states["logical"])
	_check(map_has_both_states, "F4 data exposes visual and logical schools from the same resource snapshots")
	var map_layer := scene.get_node("FishResourceMap") as FishResourceMap
	map_layer.set_map_open(true)
	var map_canvas := map_layer.find_child("ResourceDistributionMap", true, false) as FishResourceMapCanvas
	var map_rows: Array = map_canvas.get("_schools") if map_canvas != null else []
	var visible_map_states := {"visual": false, "logical": false}
	for school in map_rows:
		visible_map_states[str(school.get("render_state", "visual"))] = true
	_check(map_layer.is_map_open() and bool(visible_map_states["visual"]) and bool(visible_map_states["logical"]), "opening F4 map shows both marker states")
	map_layer.set_map_open(false)

	var renderer := scene.get_node("FishResourceManager/FishSchoolRenderer") as FishSchoolRenderer
	var bathymetry := manager.get_bathymetry_manager()
	var boat := scene.get_node("PlayerBoat/MotionRoot") as Node3D
	var hud := scene.get_node("PlayerBoat/BoatHUD") as CanvasLayer
	var original_boat_transform := boat.global_transform
	var tried_species := {"needlefish": false, "herring": false}
	for species_id in ["needlefish", "herring"]:
		var school_id := _nearest_visual_school_id(schools, species_id, boat.global_position)
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
		var unchanged := manager.get_school(selected_id)
		_check(unchanged["world_position"] == before_position and int(unchanged["population"]) == before_population, "local observation changes no shared fish position or population")
		var reveal_count := int(bathymetry.water_material.get_shader_parameter("surface_fish_reveal_count"))
		_check(reveal_count > 0 and reveal_count <= 8, "a nearby surface school activates the bounded local water reveal")
		hud.call("_on_fish_observation_camera_pressed")
		_check(renderer.is_observation_active(), "underwater camera remains an explicit manual action")
		hud.call("_on_fish_observation_camera_return_pressed")
		_check(not renderer.is_observation_active(), "manual underwater observation returns to the boat camera")
		boat.global_transform = original_boat_transform
		await process_frame
	_check(tried_species["needlefish"] or tried_species["herring"], "at least one F3 surface-species observation was exercised in the local test region")

	print("[SURFACE_FISH_TEST] schools=%d states=%s map_states=%s" % [schools.size(), state_counts, map_states])
	scene.queue_free()
	await process_frame
	print("[SURFACE_FISH_TEST] failures=%d" % _failures)
	quit(0 if _failures == 0 else 1)


func _nearest_visual_school_id(schools: Array[Dictionary], species_id: String, origin: Vector3) -> String:
	var nearest_id := ""
	var nearest_score := INF
	for school in schools:
		if str(school.get("species_id", "")) != species_id:
			continue
		var depth := float(school.get("activity_depth_m", INF))
		if depth > 6.0:
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
