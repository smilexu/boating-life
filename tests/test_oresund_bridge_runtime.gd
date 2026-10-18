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
	_check(absf(float(snapshot.get("bridge_length_m", 0.0)) - 7845.0) < 2.0, "projected bridge length matches official 7,845 m")
	_check(int(snapshot.get("pier_count", 0)) == 51, "51 bundled OSM pier footprints load")
	_check(int(snapshot.get("pylon_count", 0)) == 4, "four bundled OSM pylon footprints load")
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
	if _failed:
		quit(1)
	else:
		print("ORESUND_BRIDGE_RUNTIME_TEST: PASS")
	quit(0 if not _failed else 1)


func _check(condition: bool, description: String) -> void:
	if condition:
		print("[PASS] %s" % description)
	else:
		push_error("[FAIL] %s" % description)
		_failed = true


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
