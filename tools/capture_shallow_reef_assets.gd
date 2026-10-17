extends SceneTree

## Captures the production GLB reef clusters and compares them with reef rendering
## disabled at the same camera transform.

const MAIN_SCENE := "res://scenes/main.tscn"
const OUTPUT_DIR := "res://docs/shallow_reef_scale_tuning/after"
const BASELINE_CAMERA_PATH := "res://docs/shallow_reef_scale_tuning/before/camera_transforms.json"
const TEST_DATE := Vector3i(2026, 7, 15)

var _main: Node3D
var _camera: Camera3D
var _manager: Node


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	_main = load(MAIN_SCENE).instantiate() as Node3D
	root.add_child(_main)
	await process_frame
	var boat := _main.get_node("PlayerBoat/MotionRoot") as Node3D
	boat.set("is_motion_paused", true)
	var time_manager := root.get_node_or_null("WorldTimeManager")
	if time_manager != null:
		time_manager.set("autosave_enabled", false)
		time_manager.call("pause_time")
		time_manager.call("set_calendar_date", TEST_DATE.x, TEST_DATE.y, TEST_DATE.z)
		time_manager.call("set_cycle_time", 12, 0, 0.0)
	var weather := _main.get_node_or_null("WeatherController")
	if weather != null:
		weather.call("set_weather_by_index", 0)
	_manager = _main.get_node("ShallowSeabedManager")
	_manager.set("show_statistics", true)
	_manager.set("enable_reefs", true)
	_manager.call("_sync_runtime_options")
	_camera = Camera3D.new()
	_camera.name = "ShallowReefAssetCaptureCamera"
	_camera.far = 1000.0
	_camera.fov = 48.0
	_main.add_child(_camera)
	if not await _wait_for_stream(1500):
		push_error("Seabed tiles did not finish streaming before capture.")
		quit(1)
		return
	var nearest := _find_nearest_reef(_manager, boat.global_position, 8.0, 240.0)
	if not bool(nearest.get("valid", false)):
		push_error("No generated GLB reef found near the real Malmö start position.")
		quit(1)
		return
	var reef_position: Vector3 = nearest["position"]
	print("[ShallowReefCapture] nearest GLB reef %.1f m from boat · %s · stats %s" % [float(nearest["distance_m"]), str(nearest["asset_id"]), str(_manager.call("get_debug_stats"))])
	_set_close_camera(reef_position)
	if not _apply_baseline_camera("close"):
		_save_baseline_camera("close")
	await _settle_frames(45)
	var comparison_camera_transform := _camera.global_transform
	await _capture("01_glb_reef_cluster_closeup.png")
	_set_wide_camera(reef_position)
	if not _apply_baseline_camera("wide"):
		_save_baseline_camera("wide")
	await _settle_frames(30)
	await _capture("02_glb_reef_cluster_wide.png")
	_camera.global_transform = comparison_camera_transform
	_camera.fov = 48.0
	await _settle_frames(45)
	var glb_timing := await _measure_scene_timing(240)
	print("[ShallowReefCapture] GLB timing: ", glb_timing)

	_manager.set("enable_reefs", false)
	_manager.call("_sync_runtime_options")
	_camera.global_transform = comparison_camera_transform
	_camera.fov = 48.0
	await _settle_frames(45)
	await _capture("03_reefs_off_same_camera.png")
	var reefs_off_timing := await _measure_scene_timing(240)
	print("[ShallowReefCapture] reefs-off timing: ", reefs_off_timing)

	_manager.set("enable_reefs", true)
	_manager.call("_sync_runtime_options")
	_camera.global_transform = comparison_camera_transform
	await _settle_frames(45)
	await _capture("04_glb_cluster_restored.png")
	var report := _make_performance_report(glb_timing, reefs_off_timing)
	_write_text("performance_comparison.txt", report)

	var default_camera := _main.get_node("PlayerBoat/FollowCameraRig/Camera3D") as Camera3D
	default_camera.make_current()
	await _settle_frames(15)
	await _capture("05_glb_boat_stern_day.png")
	if time_manager != null:
		time_manager.call("set_cycle_time", 19, 30, 0.0)
		await _settle_frames(90)
		await _capture("06_glb_evening.png")
		time_manager.call("set_cycle_time", 23, 0, 0.0)
		await _settle_frames(90)
		await _capture("07_glb_moonlight.png")
	print("[ShallowReefCapture] final stats: ", _manager.call("get_debug_stats"))
	quit()


func _wait_for_stream(max_frames: int) -> bool:
	var stable_frames := 0
	for frame_index in range(max_frames):
		await process_frame
		var stats: Dictionary = _manager.call("get_debug_stats")
		if frame_index > 100 and int(stats.get("pending_tiles", 1)) == 0:
			stable_frames += 1
			if stable_frames >= 45:
				return true
		else:
			stable_frames = 0
	return false


func _settle_frames(frame_count: int) -> void:
	for _index in range(frame_count):
		await process_frame
	await RenderingServer.frame_post_draw


func _set_close_camera(target: Vector3) -> void:
	_camera.fov = 48.0
	_camera.position = target + Vector3(3.0, 5.2, 4.0)
	_camera.look_at(target + Vector3(0.0, -0.25, 0.0), Vector3.UP)
	_camera.make_current()


func _set_wide_camera(target: Vector3) -> void:
	_camera.position = target + Vector3(13.0, 14.0, 18.0)
	_camera.fov = 58.0
	_camera.look_at(target + Vector3(0.0, -0.25, 0.0), Vector3.UP)
	_camera.make_current()


func _apply_baseline_camera(key: String) -> bool:
	if not FileAccess.file_exists(BASELINE_CAMERA_PATH):
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(BASELINE_CAMERA_PATH))
	if not parsed is Dictionary or not parsed.has(key):
		return false
	var state: Dictionary = parsed[key]
	var position_values: Array = state.get("position", [])
	var quaternion_values: Array = state.get("quaternion", [])
	if position_values.size() != 3 or quaternion_values.size() != 4:
		return false
	_camera.global_transform = Transform3D(
		Basis(Quaternion(float(quaternion_values[0]), float(quaternion_values[1]), float(quaternion_values[2]), float(quaternion_values[3]))),
		Vector3(float(position_values[0]), float(position_values[1]), float(position_values[2]))
	)
	_camera.fov = float(state.get("fov", _camera.fov))
	_camera.make_current()
	return true


func _save_baseline_camera(key: String) -> void:
	var states: Dictionary = {}
	if FileAccess.file_exists(BASELINE_CAMERA_PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(BASELINE_CAMERA_PATH))
		if parsed is Dictionary:
			states = parsed
	var quaternion := _camera.global_basis.get_rotation_quaternion().normalized()
	states[key] = {
		"position": [_camera.global_position.x, _camera.global_position.y, _camera.global_position.z],
		"quaternion": [quaternion.x, quaternion.y, quaternion.z, quaternion.w],
		"fov": _camera.fov,
	}
	_write_text("camera_transforms.json", JSON.stringify(states, "\t"))


func _find_nearest_reef(manager: Node, origin: Vector3, minimum_distance: float, maximum_distance: float) -> Dictionary:
	var loaded_tiles: Dictionary = manager.get("_loaded_tiles")
	var library: ShallowReefAssetLibrary = manager.get("reef_asset_library")
	var nearest := {"valid": false, "distance_m": maximum_distance}
	for tile_key_variant in loaded_tiles:
		var tile_key: Vector2i = tile_key_variant
		var tile_data: Dictionary = loaded_tiles[tile_key]
		var tile_root := tile_data.get("root") as Node3D
		if not is_instance_valid(tile_root):
			continue
		var payload: Dictionary = tile_data.get("bundle", {}).get("reef_payload", {})
		var records_by_asset: Array = payload.get("asset_records", [])
		for asset_index in range(records_by_asset.size()):
			var asset_id := "asset_%d" % asset_index
			if library != null and asset_index < library.definitions.size():
				asset_id = String(library.definitions[asset_index].asset_id)
			for record in records_by_asset[asset_index]:
				nearest = _consider_reef(nearest, record, asset_id, tile_root, origin, minimum_distance)
	return nearest


func _consider_reef(nearest: Dictionary, record: Dictionary, asset_id: String, tile_root: Node3D, origin: Vector3, minimum_distance: float) -> Dictionary:
	var local_transform: Transform3D = record["transform"]
	var world_position := tile_root.global_transform * local_transform.origin
	var distance := Vector2(world_position.x - origin.x, world_position.z - origin.z).length()
	if distance < minimum_distance or distance >= float(nearest["distance_m"]):
		return nearest
	return {"valid": true, "position": world_position, "distance_m": distance, "asset_id": asset_id}


func _measure_scene_timing(frame_count: int) -> Dictionary:
	var fps_sum := 0.0
	var fps_count := 0
	var start_usec := Time.get_ticks_usec()
	var draw_calls_sum := 0.0
	var primitives_sum := 0.0
	for _frame in range(frame_count):
		await process_frame
		var fps := Engine.get_frames_per_second()
		if fps > 0:
			fps_sum += float(fps)
			fps_count += 1
		draw_calls_sum += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		primitives_sum += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	var elapsed_seconds := float(Time.get_ticks_usec() - start_usec) / 1000000.0
	return {
		"frames": frame_count,
		"elapsed_seconds": elapsed_seconds,
		"wall_fps": float(frame_count) / maxf(elapsed_seconds, 0.000001),
		"engine_fps_mean": fps_sum / maxf(float(fps_count), 1.0),
		"average_frame_ms": elapsed_seconds * 1000.0 / float(frame_count),
		"draw_calls_mean": draw_calls_sum / float(frame_count),
		"primitives_mean": primitives_sum / float(frame_count),
		"reef_stats": _manager.call("get_debug_stats"),
	}


func _make_performance_report(glb_timing: Dictionary, reefs_off_timing: Dictionary) -> String:
	var lines := PackedStringArray()
	lines.append("Godot 4.7.2 · Forward+ · same process/scene/camera transform/weather/time · 1920x1080")
	lines.append("Renderer/device is reported by the engine log; GPU timestamp queries are not exposed by this capture script.")
	lines.append("GLB reef clusters ON: %s" % JSON.stringify(glb_timing))
	lines.append("Reefs OFF: %s" % JSON.stringify(reefs_off_timing))
	return "\n".join(lines) + "\n"


func _capture(file_name: String) -> void:
	await RenderingServer.frame_post_draw
	var directory := ProjectSettings.globalize_path(OUTPUT_DIR)
	DirAccess.make_dir_recursive_absolute(directory)
	var image := root.get_texture().get_image()
	var path := OUTPUT_DIR.path_join(file_name)
	var error := image.save_png(ProjectSettings.globalize_path(path))
	print("[ShallowReefCapture] %s result=%s size=%s" % [path, str(error), str(image.get_size())])


func _write_text(file_name: String, contents: String) -> void:
	var directory := ProjectSettings.globalize_path(OUTPUT_DIR)
	DirAccess.make_dir_recursive_absolute(directory)
	var file := FileAccess.open(OUTPUT_DIR.path_join(file_name), FileAccess.WRITE)
	if file == null:
		push_error("Unable to write reef performance report: %s" % FileAccess.get_open_error())
		return
	file.store_string(contents)
	file.close()
