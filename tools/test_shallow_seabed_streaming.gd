extends SceneTree

## Moves the paused production boat out of and back into its initial seabed
## region, then compares the reloaded deterministic tile contents.

const MAIN_SCENE := "res://scenes/main.tscn"
const MOVE_DISTANCE_M := 1200.0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
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

	var start_position := boat.global_position
	var start_tile := _get_tile(manager, start_position)
	if not await _wait_until_settled(manager, start_tile, 2400):
		push_error("Initial seabed stream did not settle within the frame limit.")
		quit(1)
		return
	var original_signature := _tile_signature(manager, start_tile)
	if original_signature.is_empty():
		push_error("No generated seabed tile exists at the starting boat position.")
		quit(1)
		return
	print("[SeabedStreaming] initial tile %s signature %s" % [str(start_tile), original_signature])

	var remote_position := start_position + Vector3(0.0, 0.0, -MOVE_DISTANCE_M)
	var remote_tile := _get_tile(manager, remote_position)
	boat.global_position = remote_position
	if not await _wait_until_settled(manager, remote_tile, 3000):
		push_error("Remote seabed stream did not settle within the frame limit.")
		quit(1)
		return
	var after_departure: Dictionary = manager.get("_loaded_tiles")
	if after_departure.has(start_tile):
		push_error("The initial tile was not unloaded after moving beyond unload radius.")
		quit(1)
		return
	print("[SeabedStreaming] departed to %s; initial tile unloaded; stats %s" % [str(remote_tile), str(manager.call("get_debug_stats"))])

	boat.global_position = start_position
	if not await _wait_until_settled(manager, start_tile, 3000):
		push_error("Returning seabed stream did not settle within the frame limit.")
		quit(1)
		return
	var returned_signature := _tile_signature(manager, start_tile)
	if returned_signature != original_signature:
		push_error("Tile content changed after unloading and returning: %s != %s" % [returned_signature, original_signature])
		quit(1)
		return
	print("[SeabedStreaming] returned to %s; deterministic tile signature matches; stats %s" % [str(start_tile), str(manager.call("get_debug_stats"))])
	quit(0)


func _wait_until_settled(manager: Node, expected_tile: Vector2i, max_frames: int) -> bool:
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


func _get_tile(manager: Node, position: Vector3) -> Vector2i:
	var tile_size := float(manager.get("tile_size_m"))
	return Vector2i(floori(position.x / tile_size), floori(-position.z / tile_size))


func _tile_signature(manager: Node, key: Vector2i) -> String:
	var loaded_tiles: Dictionary = manager.get("_loaded_tiles")
	if not loaded_tiles.has(key):
		return ""
	var tile_data: Dictionary = loaded_tiles[key]
	var bundle: Dictionary = tile_data.get("bundle", {})
	var signature := "%d:%d:" % [int(tile_data.get("lod", -1)), int(bundle.get("triangles", -1))]
	for variant_index in range(bundle.get("rock_records", []).size()):
		var records: Array = bundle["rock_records"][variant_index]
		signature += "%d=" % variant_index
		for record in records:
			var rock_transform: Transform3D = record["transform"]
			var position := rock_transform.origin
			signature += "%.4f,%.4f,%.4f;" % [position.x, position.y, position.z]
	return signature
