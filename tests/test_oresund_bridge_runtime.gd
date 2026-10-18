extends SceneTree

const MAIN_SCENE := preload("res://scenes/main.tscn")
var _failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var world := MAIN_SCENE.instantiate()
	root.add_child(world)
	await process_frame
	await process_frame
	var bridge := world.get_node_or_null("OresundBridge")
	var boat := world.get_node_or_null("PlayerBoat/MotionRoot")
	_check(bridge != null, "OresundBridge scene is present in the main world")
	_check(boat != null, "player boat is available to the bridge LOD controller")
	if bridge == null or boat == null:
		quit(1)
		return
	var snapshot: Dictionary = bridge.call("get_debug_snapshot")
	_test_coast_transition(world, float(snapshot.get("end_latitude_deg", 0.0)), float(snapshot.get("end_longitude_deg", 0.0)))
	_test_estimated_depth_query(world)
	_check(absf(float(snapshot.get("bridge_length_m", 0.0)) - 7845.0) < 2.0, "projected bridge length matches official 7,845 m")
	_check(int(snapshot.get("pier_count", 0)) == 51, "51 bundled OSM pier footprints load")
	_check(int(snapshot.get("pylon_count", 0)) == 4, "four bundled OSM pylon footprints load")
	_check(absf(float(snapshot.get("malmo_approach_length_m", 0.0)) - 700.0) < 0.1, "Malmö gets a 700 m visual approach without changing the official bridge length")
	_check(absf(float(snapshot.get("malmo_approach_ramp_length_m", 0.0)) - 650.0) < 0.1, "Malmö approach eases down over 650 m before a buried runout")
	_check(int(snapshot.get("malmo_approach_cell_count", 0)) == 2, "Malmö approach is split into streamed LOD cells")
	_check(int(snapshot.get("malmo_approach_support_count", 0)) == 1, "the approach has one terrain-seated shore pier")
	var main_end_underside := float(bridge.call("_underside_height_at_station", float(snapshot.get("bridge_length_m", 7845.0))))
	var approach_start_underside := float(bridge.call("_malmo_approach_underside_height", 0.0))
	var approach_ramp_end_underside := float(bridge.call("_malmo_approach_underside_height", 650.0))
	var approach_terminal_underside := float(bridge.call("_malmo_approach_underside_height", 700.0))
	_check(absf(approach_start_underside - main_end_underside) < 0.001, "approach height joins the existing bridge without a step")
	_check(absf(approach_ramp_end_underside + 9.2 - 15.0636) < 0.01, "upper road level meets the sampled terrain at the ramp end")
	_check(absf(approach_terminal_underside - approach_ramp_end_underside) < 0.001, "buried runout remains level beneath the rising terrain")
	var approach_position: Vector3 = bridge.call("_malmo_approach_position", 250.0)
	boat.global_position = approach_position
	bridge.call("_update_lods")
	await process_frame
	snapshot = bridge.call("get_debug_snapshot")
	_check(int(snapshot.get("malmo_approach_near_cells", 0)) > 0, "near LOD activates around the Malmö approach")
	var approach_cell := bridge.get_node_or_null("BridgeSegments/MalmoVisualApproachCell_00/LOD_近")
	_check(approach_cell != null and approach_cell.find_child("MalmoApproachLowerDeck", true, false) != null, "approach reuses the existing lower and upper deck greybox section")
	var shore_pier := approach_cell.find_child("MalmoApproachShorePier", true, false) as MeshInstance3D if approach_cell != null else null
	var shore_pier_box := shore_pier.mesh as BoxMesh if shore_pier != null else null
	var shore_pier_ground_y := shore_pier.position.y - shore_pier_box.size.y * 0.5 if shore_pier_box != null else INF
	_check(absf(shore_pier_ground_y - 5.8166) < 0.02, "shore pier base matches the sampled rendered terrain height")
	_check(absf(float(snapshot.get("peberholm_approach_length_m", 0.0)) - 1840.0) < 0.1, "Peberholm approach extends 1,840 m into the artificial island")
	_check(absf(float(snapshot.get("peberholm_approach_ramp_length_m", 0.0)) - 1350.0) < 0.1, "Peberholm descent eases over 1,350 m before the grade-level entry")
	_check(int(snapshot.get("peberholm_approach_cell_count", 0)) == 4, "Peberholm approach streams in four spatial LOD cells")
	_check(int(snapshot.get("peberholm_approach_support_count", 0)) == 3, "three terrain-seated piers support the first, progressively lower approach section")
	_check(int(snapshot.get("peberholm_flora_removed_count", 0)) > 0, "the road footprint is cleared of low vegetation")
	var peberholm_start_underside := float(bridge.call("_underside_height_at_station", 0.0))
	var peberholm_approach_start := float(bridge.call("_peberholm_approach_underside_height", 0.0))
	var peberholm_approach_end := float(bridge.call("_peberholm_approach_underside_height", 1350.0))
	var peberholm_terminal := float(bridge.call("_peberholm_approach_underside_height", 1840.0))
	_check(absf(peberholm_approach_start - peberholm_start_underside) < 0.001, "Peberholm approach begins flush with the existing bridge section")
	_check(absf(peberholm_approach_end + 9.2 - 3.1) < 0.01, "Peberholm road reaches the rendered island grade at the end of the descent")
	_check(absf(peberholm_terminal - peberholm_approach_end) < 0.001, "the terminal apron stays level through the ground-entry portal")
	var max_peberholm_slope := 0.0
	var previous_underside := peberholm_approach_start
	for ramp_distance in range(25, 1351, 25):
		var current_underside := float(bridge.call("_peberholm_approach_underside_height", float(ramp_distance)))
		max_peberholm_slope = maxf(max_peberholm_slope, absf(current_underside - previous_underside) / 25.0)
		previous_underside = current_underside
	_check(max_peberholm_slope < 0.02, "the Peberholm vertical curve stays under a 2 percent grade")
	var peberholm_portal_distance := float(snapshot.get("peberholm_approach_length_m", 0.0)) - 40.0
	var peberholm_portal_position: Vector3 = bridge.call("_peberholm_approach_position", peberholm_portal_distance)
	var sampled_entry_ground := _sample_rendered_terrain_height(world.get_node("OresundRegion/TerrainChunks"), peberholm_portal_position)
	_check(absf(sampled_entry_ground - 2.995) < 0.03, "portal apron is placed on the barycentrically sampled rendered terrain")
	_check(absf(float(snapshot.get("peberholm_approach_target_underside_y", -100.0)) + 6.1) < 0.01, "the target road level is configured at +3.1 m above the game sea plane")
	boat.global_position = bridge.call("_peberholm_approach_position", 200.0)
	bridge.call("_update_lods")
	await process_frame
	snapshot = bridge.call("get_debug_snapshot")
	_check(int(snapshot.get("peberholm_approach_near_cells", 0)) > 0, "near LOD activates on the Peberholm approach")
	var peberholm_approach_cell := bridge.get_node_or_null("BridgeSegments/PeberholmVisibleApproachCell_00/LOD_近")
	_check(peberholm_approach_cell != null and peberholm_approach_cell.find_child("PeberholmApproachLowerDeck", true, false) != null and peberholm_approach_cell.find_child("PeberholmApproachRoadDeck", true, false) != null, "Peberholm approach continues the existing two-level greybox section")
	var peberholm_piers: Array[Node] = []
	if peberholm_approach_cell != null:
		for candidate in peberholm_approach_cell.find_children("*", "MeshInstance3D", true, false):
			if str(candidate.name).begins_with("PeberholmApproachShorePier_") and not str(candidate.name).contains("Footing"):
				peberholm_piers.append(candidate)
	var pier_ground_heights := PackedFloat32Array()
	for pier_variant in peberholm_piers:
		var pier := pier_variant as MeshInstance3D
		var pier_box := pier.mesh as BoxMesh if pier != null else null
		if pier_box != null:
			pier_ground_heights.append(pier.position.y - pier_box.size.y * 0.5)
	pier_ground_heights.sort()
	_check(pier_ground_heights.size() == 3 and absf(pier_ground_heights[0] - 1.982) < 0.02 and absf(pier_ground_heights[1] - 2.787) < 0.02 and absf(pier_ground_heights[2] - 2.844) < 0.02, "all three Peberholm pier feet match their sampled shoreline and island elevations")
	boat.global_position = bridge.call("_peberholm_approach_position", 1750.0)
	bridge.call("_update_lods")
	await process_frame
	var entry_cell := bridge.get_node_or_null("BridgeSegments/PeberholmVisibleApproachCell_03/LOD_近")
	_check(entry_cell != null and entry_cell.find_child("PeberholmGroundEntryPortalHeader", true, false) != null and entry_cell.find_child("PeberholmGroundEntryPortalMouth", true, false) != null, "the approach reaches a framed, dark ground-entry portal")
	var entry_wing := entry_cell.find_child("PeberholmGroundEntryRetainingWing", true, false) as MeshInstance3D if entry_cell != null else null
	var entry_wing_box := entry_wing.mesh as BoxMesh if entry_wing != null else null
	var retaining_wall_base_y := entry_wing.position.y - entry_wing_box.size.y * 0.5 if entry_wing_box != null else INF
	_check(entry_wing_box != null and entry_wing_box.size.z >= 179.0 and absf(retaining_wall_base_y - 2.995) < 0.02, "the final 180 m entry trench walls start at rendered island grade")
	var start_lat := float(snapshot.get("start_latitude_deg", 0.0))
	var start_lon := float(snapshot.get("start_longitude_deg", 0.0))
	var end_lat := float(snapshot.get("end_latitude_deg", 0.0))
	var end_lon := float(snapshot.get("end_longitude_deg", 0.0))
	print("Bridge GPS extents: Peberholm %.6f°N, %.6f°E → Lernacken %.6f°N, %.6f°E · length %.1f m · end extension %.1f m each" % [start_lat, start_lon, end_lat, end_lon, float(snapshot.get("bridge_length_m", 0.0)), float(snapshot.get("endpoint_extension_m", 0.0))])
	var endpoint_depth_provider := world.get_node_or_null("NavigationDepthProvider")
	var georeference := world.get_node("BathymetryManager").get("georeference") as GeoReference
	if endpoint_depth_provider != null and georeference != null:
		var malmo_endpoint := georeference.geodetic_to_world(end_lat, end_lon)
		var endpoint_sample: Dictionary = endpoint_depth_provider.call("query_world_position", malmo_endpoint)
		print("Malmö end sample: %s · %.2f m · %s" % [str(endpoint_sample.get("data_state", "unknown")), float(endpoint_sample.get("depth_m", 0.0)), str(endpoint_sample.get("reason", ""))])
		var terrain_root := world.get_node("OresundRegion/TerrainChunks")
		var nearest_terrain := _nearest_terrain_vertex(terrain_root, malmo_endpoint)
		var water_sample: Dictionary = world.get_node("WaveSampler").call("sample_surface", malmo_endpoint, 0.0)
		print("Malmö end vertical references: closest terrain vertex %.1f m away at Y=%.2f m · calm water Y=%.2f m · sampled wave Y=%.2f m" % [float(nearest_terrain.get("distance_m", -1.0)), float(nearest_terrain.get("height_m", -1.0)), float(world.get_node("Ocean").global_position.y), float(water_sample.get("height", -1.0))])
	_check(start_lat > 55.58 and start_lat < 55.60 and start_lon > 12.75 and start_lon < 12.80, "Peberholm endpoint projects to the expected GPS area")
	_check(end_lat > 55.55 and end_lat < 55.58 and end_lon > 12.88 and end_lon < 12.91, "Lernacken endpoint projects to the expected GPS area")
	_test_bridge_teleport_cycle(bridge, boat, world.get_node("NavigationDepthProvider"))
	var gate: Dictionary = bridge.call("get_navigation_gate_snapshot")
	var pylon_separation := float(gate.get("pylon_group_separation_m", 0.0))
	print("Main channel check: tower axes %.1f m apart · clearance %.1f m · vessel height %.1f m · free-span piers %d" % [pylon_separation, float(gate.get("clearance_m", 0.0)), float(gate.get("vessel_height_m", 0.0)), int(gate.get("osm_pier_count_inside_free_span", -1))])
	_check(pylon_separation > 470.0 and pylon_separation < 510.0, "OSM pylon-group separation is consistent with the 490 m main span")
	_check(is_equal_approx(float(gate.get("clearance_m", 0.0)), 57.0), "main navigation span uses 57 m nominal clearance")
	_check(int(gate.get("osm_pier_count_inside_free_span", -1)) == 0, "the 490 m free span remains open between the pylon supports")
	_check(is_equal_approx(float(gate.get("vessel_height_m", -1.0)), 3.834), "gate check reads configured vessel height rather than beam")
	_check(is_equal_approx(float(gate.get("nominal_vertical_clearance_margin_m", -1.0)), 57.0 - 3.834), "configured vessel height fits below the nominal bridge clearance")

	var center: Vector3 = gate.get("center", Vector3.ZERO)
	var depth_provider := world.get_node_or_null("NavigationDepthProvider")
	if depth_provider != null and depth_provider.has_method("query_world_position"):
		var gate_depth: Dictionary = depth_provider.call("query_world_position", center)
		var draft := float(boat.call("get_current_draft_m")) if boat.has_method("get_current_draft_m") else 0.0
		var depth_check: Dictionary = depth_provider.call("evaluate_world_position", center, draft)
		print("Main channel DTM sample: %s · %.2f m · draft %.2f m · %s · %s" % [str(gate_depth.get("data_state", "unknown")), float(gate_depth.get("depth_m", 0.0)), draft, str(gate_depth.get("source", "")), str(gate_depth.get("quality", ""))])
		_check(bool(gate_depth.get("valid", false)), "bathymetry provides a game-reference water sample below the main bridge span")
		_check(str(depth_check.get("status", "")) == NavigationDepthProvider.STATUS_SAFE, "DTM water sample meets configured draft and safety margin")
	else:
		_check(false, "NavigationDepthProvider is available for the bridge crossing check")
	boat.global_position = center
	bridge.call("_update_lods")
	await process_frame
	snapshot = bridge.call("get_debug_snapshot")
	_check(str(snapshot.get("high_span_lod", "")) == "近" and int(snapshot.get("near_cells", 0)) > 0, "near LOD and simplified collision activate at the navigation gate")
	boat.global_position = center + Vector3(0.0, 0.0, 8000.0)
	bridge.call("_update_lods")
	await process_frame
	snapshot = bridge.call("get_debug_snapshot")
	_check(str(snapshot.get("high_span_lod", "")) == "中", "medium LOD activates at regional distance")
	boat.global_position = center + Vector3(0.0, 0.0, 30000.0)
	bridge.call("_update_lods")
	await process_frame
	snapshot = bridge.call("get_debug_snapshot")
	_check(str(snapshot.get("high_span_lod", "")) == "远", "far silhouette LOD activates while retaining the pylons")
	boat.global_position = center + Vector3(0.0, 0.0, 60000.0)
	bridge.call("_update_lods")
	await process_frame
	snapshot = bridge.call("get_debug_snapshot")
	_check(str(snapshot.get("high_span_lod", "")) == "未加载", "bridge high-detail and far geometry unloads outside the streaming radius")
	var exit_code := 1 if _failed else 0
	if not _failed:
		print("ORESUND_BRIDGE_RUNTIME_TEST: PASS")
	world.queue_free()
	await process_frame
	quit(exit_code)


func _check(condition: bool, description: String) -> void:
	if condition:
		print("[PASS] %s" % description)
	else:
		push_error("[FAIL] %s" % description)
		_failed = true


func _test_coast_transition(world: Node, malmo_end_latitude: float, malmo_end_longitude: float) -> void:
	var transition := world.get_node_or_null("OresundRegion/CoastTransitions")
	_check(transition != null, "prebuilt OSM-matched coastline transitions are installed")
	if transition == null:
		return
	var diagnostics: Dictionary = transition.call("get_diagnostics")
	print("Coast transition: %s · %d matched shoreline edges / %.1f km · %d triangles · unmatched openings left unchanged: %d" % [
		str(diagnostics.get("status", "missing")),
		int(diagnostics.get("matched_coast_edge_count", 0)),
		float(diagnostics.get("matched_coast_length_m", 0.0)) / 1000.0,
		int(diagnostics.get("triangle_count", 0)),
		int(diagnostics.get("unmatched_terrain_open_edge_count", 0)),
	])
	_check(str(diagnostics.get("status", "")) == "loaded", "static coastline transition data loads successfully")
	_check(int(diagnostics.get("matched_coast_edge_count", 0)) > 15000, "transition follows the same land-mask boundary used to clip the terrain")
	_check(float(diagnostics.get("matched_coast_length_m", 0.0)) > 100000.0, "transition covers more than 100 km of matched shoreline")
	_check(float(diagnostics.get("lower_edge_y_m", 0.0)) <= -0.29, "transition mesh extends below mean sea level")
	_check(float(diagnostics.get("max_slope_width_m", INF)) <= 16.001, "transition slope stays within the 16 m width limit")
	_check(int(diagnostics.get("unmatched_terrain_open_edge_count", 0)) > 0, "unmatched crop or data boundaries are not automatically modified")
	var mesh_instance := transition.get_node_or_null("OresundCoastTransitionMesh") as MeshInstance3D
	_check(mesh_instance != null and mesh_instance.mesh != null, "shoreline geometry is a separate static, removable mesh instance")
	var regional_terrain := world.get_node_or_null("OresundRegion") as Node3D
	var georeference := regional_terrain.get("georeference") as GeoReference if regional_terrain != null else null
	var transition_near_malmo_end := false
	if georeference != null and mesh_instance != null and mesh_instance.mesh != null and mesh_instance.mesh.get_surface_count() > 0:
		var endpoint := georeference.geodetic_to_world(malmo_end_latitude, malmo_end_longitude)
		var coast_arrays: Array = mesh_instance.mesh.surface_get_arrays(0)
		var coast_vertices: PackedVector3Array = coast_arrays[Mesh.ARRAY_VERTEX]
		for vertex in coast_vertices:
			if Vector2(vertex.x - endpoint.x, vertex.z - endpoint.z).length() <= 100.0:
				transition_near_malmo_end = true
				break
	_check(transition_near_malmo_end, "Malmö bridge-end shoreline has transition geometry within 100 m")
	var terrain_root := world.get_node_or_null("OresundRegion/TerrainChunks")
	var has_one_sided_terrain := false
	if terrain_root != null and not terrain_root.get_children().is_empty():
		var terrain_instance := terrain_root.get_child(0) as MeshInstance3D
		var terrain_material := terrain_instance.material_override as BaseMaterial3D if terrain_instance != null else null
		has_one_sided_terrain = terrain_material != null and terrain_material.cull_mode == BaseMaterial3D.CULL_BACK
	_check(has_one_sided_terrain, "open land terrain does not render its underside through the sea")
	if mesh_instance == null or mesh_instance.mesh == null or mesh_instance.mesh.get_surface_count() == 0:
		return
	var arrays: Array = mesh_instance.mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var index_variant: Variant = arrays[Mesh.ARRAY_INDEX]
	var indices: PackedInt32Array = index_variant if index_variant is PackedInt32Array else PackedInt32Array()
	var triangles_non_degenerate := true
	var triangle_index_count := vertices.size() if indices.is_empty() else indices.size()
	for triangle_start in range(0, triangle_index_count, 3):
		var first_index := triangle_start if indices.is_empty() else indices[triangle_start]
		var second_index := triangle_start + 1 if indices.is_empty() else indices[triangle_start + 1]
		var third_index := triangle_start + 2 if indices.is_empty() else indices[triangle_start + 2]
		var first := vertices[first_index]
		var second := vertices[second_index]
		var third := vertices[third_index]
		var face_normal := (second - first).cross(third - first)
		if face_normal.length_squared() < 0.000001:
			triangles_non_degenerate = false
			break
	_check(triangles_non_degenerate, "shoreline transition mesh contains no degenerate triangles")
	_check(int(diagnostics.get("winding_error_count", -1)) == 0, "shoreline triangles are consistently wound toward the sea-facing side")
	var normals_face_up := true
	for normal in normals:
		if normal.y < -0.0001:
			normals_face_up = false
			break
	_check(normals_face_up, "shoreline transition lighting normals remain upward-facing")


func _test_estimated_depth_query(world: Node) -> void:
	var manager := world.get_node_or_null("BathymetryManager") as BathymetryManager
	var provider := world.get_node_or_null("NavigationDepthProvider") as NavigationDepthProvider
	_check(manager != null and provider != null, "bathymetry and navigation depth services are available")
	if manager == null or provider == null:
		return
	_check(manager.get_estimated_depth_cell_count() == 2935, "source-matched conservative depth estimates load")
	var latitude := 55.35104166663167
	var longitude := 12.442708333324298
	var raw_sample := manager.get_depth_at_geodetic(latitude, longitude)
	var estimated_sample := manager.get_depth_at_geodetic(latitude, longitude, true, true)
	_check(not bool(raw_sample.get("valid", false)), "the selected source interpolation remains Unknown without opt-in")
	_check(bool(estimated_sample.get("valid", false)) and bool(estimated_sample.get("estimated", false)), "explicit estimated query fills a supported water gap")
	var georeference := manager.georeference
	var world_position := georeference.geodetic_to_world(latitude, longitude)
	var evaluation := provider.evaluate_world_position(world_position, 0.5)
	_check(bool(evaluation.get("estimated", false)), "navigation result retains estimated-depth provenance")
	_check(str(evaluation.get("status", "")) != NavigationDepthProvider.STATUS_SAFE, "estimated depth cannot silently qualify as Safe")


func _test_bridge_teleport_cycle(bridge: Node, boat: Node3D, depth_provider: Node) -> void:
	var gate_station := (float(bridge.call("_high_bridge_start_m")) + float(bridge.call("_high_bridge_end_m"))) * 0.5
	var total_length := float(bridge.get("_total_length_m"))
	var expected_stations := [gate_station, total_length, 0.0]
	var expected_names := ["主桥跨中观察点", "Malmö 桥端观察点", "Peberholm 桥端观察点"]
	for index in range(expected_names.size()):
		bridge.call("_teleport_to_next_test_location")
		var snapshot: Dictionary = bridge.call("get_debug_snapshot")
		_check(str(snapshot.get("last_teleport", "")) == expected_names[index], "Shift+F5 teleport cycle selects the expected bridge location %d" % (index + 1))
		var projection: Dictionary = bridge.call("_project_to_centerline", boat.global_position)
		_check(absf(float(projection.get("station_m", -INF)) - float(expected_stations[index])) < 2.0, "teleport %d is aligned with its bridge station" % (index + 1))
		_check(absf(float(boat.get("speed_mps"))) < 0.001, "teleport %d stops the boat" % (index + 1))
		var sample: Dictionary = depth_provider.call("query_world_position", boat.global_position)
		_check(bool(sample.get("valid", false)) and str(sample.get("data_state", "")) == "water", "teleport %d lands at a water observation point" % (index + 1))
		var target_station := gate_station if index == 0 else (total_length if index == 1 else 0.0)
		var target_position: Vector3 = bridge.call("_position_at_station", target_station)
		var offset_m := Vector2(boat.global_position.x - target_position.x, boat.global_position.z - target_position.z).length()
		if index == 0:
			_check(offset_m < 0.1, "first teleport places the boat directly under the main bridge center")
		else:
			_check(offset_m > 0.0 and offset_m <= 800.0, "endpoint teleport stays near its bridge end and offshore")
		var expected_forward: Vector3 = bridge.call("_tangent_at_station", gate_station) if index == 0 else bridge.call("_horizontal_direction", boat.global_position, target_position)
		var actual_forward := -boat.global_transform.basis.z
		actual_forward.y = 0.0
		_check(actual_forward.normalized().dot(expected_forward) > 0.99, "teleport %d faces the nearby bridge structure" % (index + 1))


func _sample_rendered_terrain_height(terrain_root: Node, point: Vector3) -> float:
	var best_height := -INF
	for child in terrain_root.get_children():
		var instance := child as MeshInstance3D
		if instance == null or instance.mesh == null:
			continue
		for surface in range(instance.mesh.get_surface_count()):
			var arrays := instance.mesh.surface_get_arrays(surface)
			var vertices := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
			var index_variant: Variant = arrays[Mesh.ARRAY_INDEX]
			var triangle_index_count := vertices.size() if not index_variant is PackedInt32Array else (index_variant as PackedInt32Array).size()
			for index in range(0, triangle_index_count, 3):
				var a_index := index if not index_variant is PackedInt32Array else int((index_variant as PackedInt32Array)[index])
				var b_index := index + 1 if not index_variant is PackedInt32Array else int((index_variant as PackedInt32Array)[index + 1])
				var c_index := index + 2 if not index_variant is PackedInt32Array else int((index_variant as PackedInt32Array)[index + 2])
				var a := instance.to_global(vertices[a_index])
				var b := instance.to_global(vertices[b_index])
				var c := instance.to_global(vertices[c_index])
				var weights := _barycentric_xz(Vector2(point.x, point.z), Vector2(a.x, a.z), Vector2(b.x, b.z), Vector2(c.x, c.z))
				if weights.x >= -0.00001 and weights.y >= -0.00001 and weights.z >= -0.00001:
					best_height = maxf(best_height, a.y * weights.x + b.y * weights.y + c.y * weights.z)
	return best_height


func _barycentric_xz(point: Vector2, a: Vector2, b: Vector2, c: Vector2) -> Vector3:
	var denominator := (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
	if absf(denominator) < 0.000001:
		return Vector3(-1.0, -1.0, -1.0)
	var weight_a := ((b.y - c.y) * (point.x - c.x) + (c.x - b.x) * (point.y - c.y)) / denominator
	var weight_b := ((c.y - a.y) * (point.x - c.x) + (a.x - c.x) * (point.y - c.y)) / denominator
	return Vector3(weight_a, weight_b, 1.0 - weight_a - weight_b)


func _nearest_terrain_vertex(terrain_root: Node, position: Vector3) -> Dictionary:
	var best_distance := INF
	var best_height := 0.0
	for child in terrain_root.get_children():
		var mesh_instance := child as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null or mesh_instance.mesh.get_surface_count() == 0:
			continue
		var arrays: Array = mesh_instance.mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for vertex in vertices:
			var distance := Vector2(vertex.x - position.x, vertex.z - position.z).length()
			if distance < best_distance:
				best_distance = distance
				best_height = vertex.y
	return {"distance_m": best_distance, "height_m": best_height}
