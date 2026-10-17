extends SceneTree

## Exercises the live production manager's seagrass generation, streaming return,
## and layout hash without depending on a visible window.

const MAIN_SCENE := "res://scenes/main.tscn"
const MOVE_DISTANCE_M := 1200.0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if not _validate_generated_meshes():
		quit(1)
		return
	var main := load(MAIN_SCENE).instantiate() as Node3D
	root.add_child(main)
	await process_frame
	var manager := main.get_node("ShallowSeabedManager") as Node
	var boat := main.get_node("PlayerBoat/MotionRoot") as Node3D
	boat.set("is_motion_paused", true)
	var time_manager := root.get_node_or_null("WorldTimeManager")
	if time_manager != null:
		time_manager.set("autosave_enabled", false)
		time_manager.call("pause_time")
	var camera := Camera3D.new()
	camera.position = boat.global_position + Vector3(0.0, 24.0, 2.0)
	main.add_child(camera)
	camera.look_at(boat.global_position + Vector3(0.0, -1.0, -3.0), Vector3.FORWARD)
	camera.make_current()
	manager.set("show_statistics", true)
	manager.call("_sync_runtime_options")
	manager.call("_refresh_seagrass_stream", true)
	var start_position := boat.global_position
	var start_tile := _tile_for(manager, start_position)
	if not await _wait_for_tile(manager, start_tile, 2400):
		push_error("Production tile stream did not settle with seagrass within the frame limit.")
		quit(1)
		return
	var initial_stats: Dictionary = manager.call("get_debug_stats")
	if int(initial_stats.get("eelgrass_instances", 0)) < 250:
		push_error("Malmö start view produced too few eelgrass instances: %d" % int(initial_stats.get("eelgrass_instances", 0)))
		quit(1)
		return
	var initial_signature := _tile_signature(manager, start_tile)
	print("[ShallowSeagrass] initial tile %s · %s" % [str(start_tile), str(initial_stats)])
	var start_root := _tile_root(manager, start_tile)
	if start_root == null or start_root.get_node_or_null("Seagrass") == null:
		push_error("Expected a MultiMesh seagrass root on the current seabed tile.")
		quit(1)
		return
	for east_offset in [6.0, 12.0, 18.0]:
		var moving_position := start_position + Vector3(east_offset, 0.0, 0.0)
		boat.global_position = moving_position
		camera.global_position = moving_position + Vector3(0.0, 24.0, 2.0)
		camera.look_at(moving_position + Vector3(0.0, -1.0, -3.0), Vector3.FORWARD)
		for _frame in range(28):
			await process_frame
	var moving_tile := _tile_for(manager, boat.global_position)
	if not await _wait_for_tile(manager, moving_tile, 2400):
		push_error("The active camera movement left the seagrass build queue unsettled.")
		quit(1)
		return
	boat.global_position = start_position
	camera.global_position = start_position + Vector3(0.0, 24.0, 2.0)
	camera.look_at(start_position + Vector3(0.0, -1.0, -3.0), Vector3.FORWARD)
	if not await _wait_for_tile(manager, start_tile, 2400):
		push_error("Returning the camera to the original focus did not settle the seagrass stream.")
		quit(1)
		return
	if initial_signature != _tile_signature(manager, start_tile):
		push_error("Camera movement changed the deterministic seagrass layout.")
		quit(1)
		return
	var remote_position := start_position + Vector3(0.0, 0.0, -MOVE_DISTANCE_M)
	var remote_tile := _tile_for(manager, remote_position)
	boat.global_position = remote_position
	camera.global_position = remote_position + Vector3(0.0, 24.0, 2.0)
	camera.look_at(remote_position + Vector3(0.0, -1.0, -3.0), Vector3.FORWARD)
	if not await _wait_for_tile(manager, remote_tile, 3200):
		push_error("Remote tile stream did not settle.")
		quit(1)
		return
	var loaded: Dictionary = manager.get("_loaded_tiles")
	if loaded.has(start_tile):
		push_error("Start tile was not unloaded after travelling beyond the streaming range.")
		quit(1)
		return
	var cache: Dictionary = manager.get("_mesh_cache")
	cache.clear()
	var cache_lru: Array = manager.get("_mesh_cache_lru")
	cache_lru.clear()
	boat.global_position = start_position
	camera.global_position = start_position + Vector3(0.0, 24.0, 2.0)
	camera.look_at(start_position + Vector3(0.0, -1.0, -3.0), Vector3.FORWARD)
	if not await _wait_for_tile(manager, start_tile, 3200):
		push_error("Returning to the real Malmö seabed tile did not settle.")
		quit(1)
		return
	var returned_signature := _tile_signature(manager, start_tile)
	if initial_signature != returned_signature:
		push_error("Seagrass layout hash changed after tile regeneration: %s != %s" % [initial_signature, returned_signature])
		quit(1)
		return
	print("[ShallowSeagrass] return layout signature matched: %s · %s" % [returned_signature, str(manager.call("get_debug_stats"))])
	quit(0)


func _validate_generated_meshes() -> bool:
	for far_lod in [false, true]:
		for variant_index in range(4):
			var data: Dictionary = ShallowSeagrassGenerator.create_eelgrass_variant(variant_index, far_lod)
			var mesh := data.get("mesh") as ArrayMesh
			if mesh == null or mesh.get_surface_count() != 1:
				push_error("Eelgrass variant %d (far=%s) did not produce one mesh surface." % [variant_index, str(far_lod)])
				return false
			var arrays: Array = mesh.surface_get_arrays(0)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var triangle_count := indices.size() / 3
			if vertices.is_empty() or normals.size() != vertices.size() or triangle_count <= 0:
				push_error("Eelgrass variant %d (far=%s) has invalid vertex, normal, or index data." % [variant_index, str(far_lod)])
				return false
			if float(vertices.size()) >= float(triangle_count) * 1.5:
				push_error("Eelgrass ribbon vertices are not shared between segments as expected.")
				return false
			for normal in normals:
				if absf(normal.length() - 1.0) > 0.02:
					push_error("Eelgrass mesh contains a non-unit blade normal.")
					return false
			var legacy_vertex_estimate := triangle_count * 2
			var reduction_percent := 100.0 * (1.0 - float(vertices.size()) / float(legacy_vertex_estimate))
			print("[ShallowSeagrassMesh] variant %d far=%s · %d vertices / %d triangles · %.1f%% fewer duplicate vertices" % [variant_index, str(far_lod), vertices.size(), triangle_count, reduction_percent])
	return true


func _wait_for_tile(manager: Node, expected_tile: Vector2i, max_frames: int) -> bool:
	var stable_frames := 0
	for _frame in range(max_frames):
		await process_frame
		var center_tile: Vector2i = manager.get("_last_center_tile")
		var stats: Dictionary = manager.call("get_debug_stats")
		if center_tile == expected_tile and int(stats.get("pending_tiles", 1)) == 0:
			stable_frames += 1
			if stable_frames >= 8:
				return true
		else:
			stable_frames = 0
	return false


func _tile_for(manager: Node, position: Vector3) -> Vector2i:
	var tile_size := float(manager.get("tile_size_m"))
	return Vector2i(floori(position.x / tile_size), floori(-position.z / tile_size))


func _tile_root(manager: Node, key: Vector2i) -> Node3D:
	var loaded: Dictionary = manager.get("_loaded_tiles")
	if not loaded.has(key):
		return null
	return loaded[key].get("root") as Node3D


func _tile_signature(manager: Node, key: Vector2i) -> String:
	var loaded: Dictionary = manager.get("_loaded_tiles")
	if not loaded.has(key):
		return ""
	var tile_data: Dictionary = loaded[key]
	var payload: Dictionary = tile_data.get("bundle", {}).get("seagrass_payload", {})
	return "%d:%d:%s:%d:%d" % [
		int(payload.get("layout_version", -1)),
		int(payload.get("seed", -1)),
		String(payload.get("layout_signature", "")),
		int(payload.get("eelgrass_instances", -1)),
		int(payload.get("algae_instances", -1)),
	]
