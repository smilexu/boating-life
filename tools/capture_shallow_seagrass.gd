extends SceneTree

## Captures the production Malmö shallow area and measures seagrass density presets.

const MAIN_SCENE := "res://scenes/main.tscn"
const OUTPUT_DIR := "res://docs/shallow_seagrass_art_upgrade"
const TEST_DATE := Vector3i(2026, 7, 15)

var _main: Node3D
var _boat: Node3D
var _manager: Node
var _camera: Camera3D
var _performance_results: Array[Dictionary] = []
var _generation_results: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	_main = load(MAIN_SCENE).instantiate() as Node3D
	root.add_child(_main)
	await process_frame
	_boat = _main.get_node("PlayerBoat/MotionRoot") as Node3D
	_boat.set("is_motion_paused", true)
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
	_manager.set("enable_seagrass", true)
	_manager.set("enable_seagrass_sway", true)
	_manager.set("seagrass_density_preset", 1)
	_manager.call("_sync_runtime_options")
	_camera = Camera3D.new()
	_camera.name = "ShallowSeagrassCaptureCamera"
	_camera.far = 1000.0
	_camera.fov = 52.0
	_main.add_child(_camera)
	var start_position := _boat.global_position
	_camera.global_position = start_position + Vector3(0.0, 12.0, 24.0)
	_camera.look_at(start_position + Vector3(0.0, -2.0, 0.0), Vector3.UP)
	_camera.make_current()
	_manager.call("_refresh_seagrass_stream", true)
	if not await _wait_for_stream(2600):
		push_error("Shallow seagrass streaming did not settle before capture.")
		quit(1)
		return
	print("[ShallowSeagrassCapture] initial stats: ", _manager.call("get_debug_stats"))
	await _settle_frames(60)
	await _capture("01_stern_oblique_normal.png")
	await _measure_density_profile("stern")
	_camera.global_position = start_position + Vector3(0.0, 24.0, 3.0)
	_camera.look_at(start_position + Vector3(0.0, -2.8, 0.0), Vector3.FORWARD)
	_camera.make_current()
	await _wait_for_stream(900)
	await _settle_frames(45)
	await _capture("02_top_down_malmo_start.png")
	var nearest_plant := _nearest_plant(start_position, 1000.0)
	var close_target: Vector3 = nearest_plant["position"] if bool(nearest_plant.get("valid", false)) else start_position
	print("[ShallowSeagrassCapture] close-up plant lookup: ", nearest_plant)
	_camera.global_position = close_target + Vector3(5.0, 6.4, 7.0)
	_camera.look_at(close_target + Vector3(0.0, 0.1, 0.0), Vector3.UP)
	_camera.make_current()
	await _wait_for_stream(900)
	await _settle_frames(45)
	await _measure_density_profile("closeup")
	await _wait_for_stream(900)
	await _settle_frames(45)
	await _capture("03_eelgrass_close_patch.png")
	await _capture("sway_closeup_t0.png")
	await _settle_frames(60)
	await _capture("sway_closeup_t1.png")
	await _settle_frames(60)
	await _capture("sway_closeup_t2.png")
	var reef_target := _nearest_reef(start_position, 35.0)
	if bool(reef_target.get("valid", false)):
		var target: Vector3 = reef_target["position"]
		_camera.global_position = target + Vector3(5.5, 7.0, 6.5)
		_camera.look_at(target + Vector3(0.0, -0.1, 0.0), Vector3.UP)
		_camera.make_current()
		await _wait_for_stream(1000)
		await _settle_frames(45)
		await _capture("04_reef_and_seagrass_transition.png")
	_manager.set("show_statistics", false)
	if time_manager != null:
		time_manager.call("set_cycle_time", 23, 0, 0.0)
	_camera.global_position = start_position + Vector3(0.0, 12.0, 24.0)
	_camera.look_at(start_position + Vector3(0.0, -2.0, 0.0), Vector3.UP)
	_camera.make_current()
	if not await _wait_for_stream(1200):
		push_warning("Night seagrass view did not finish streaming before capture.")
	await _settle_frames(90)
	await _capture("06_night_seagrass.png")
	if time_manager != null:
		time_manager.call("set_cycle_time", 12, 0, 0.0)
	_manager.set("show_statistics", true)
	_manager.set("show_seagrass_distribution", true)
	_manager.call("_sync_runtime_options")
	await _wait_for_stream(1200)
	await _settle_frames(30)
	await _capture("05_patch_distribution_debug.png")
	_write_performance_results(_performance_results)
	_write_generation_results(_generation_results)
	_write_report(_manager.call("get_debug_stats"))
	print("[ShallowSeagrassCapture] final stats: ", _manager.call("get_debug_stats"))
	quit()


func _wait_for_stream(max_frames: int) -> bool:
	var stable_frames := 0
	for frame_index in range(max_frames):
		await process_frame
		var stats: Dictionary = _manager.call("get_debug_stats")
		if frame_index > 60 and int(stats.get("pending_tiles", 1)) == 0:
			stable_frames += 1
			if stable_frames >= 8:
				return true
		else:
			stable_frames = 0
	return false


func _settle_frames(frame_count: int) -> void:
	for _index in range(frame_count):
		await process_frame
	await RenderingServer.frame_post_draw


func _nearest_plant(origin: Vector3, maximum_distance: float) -> Dictionary:
	var best_position := Vector3.ZERO
	var best_distance := INF
	var multimesh_count := 0
	var instance_total := 0
	for candidate in _manager.find_children("*", "MultiMeshInstance3D", true, false):
		if not candidate.name.begins_with("Eelgrass_") or candidate.multimesh == null:
			continue
		multimesh_count += 1
		var multimesh: MultiMesh = candidate.multimesh
		instance_total += multimesh.instance_count
		for index in range(multimesh.instance_count):
			var local_position: Vector3 = multimesh.get_instance_transform(index).origin
			var world_position: Vector3 = candidate.global_transform * local_position
			var distance := Vector2(world_position.x - origin.x, world_position.z - origin.z).length()
			if distance < best_distance:
				best_position = world_position
				best_distance = distance
	return {
		"valid": is_finite(best_distance) and best_distance <= maximum_distance,
		"position": best_position,
		"distance_m": best_distance,
		"multimesh_count": multimesh_count,
		"instance_total": instance_total,
	}


func _nearest_reef(origin: Vector3, maximum_distance: float) -> Dictionary:
	var best := {"valid": false, "distance_m": maximum_distance}
	var loaded: Dictionary = _manager.get("_loaded_tiles")
	for tile_data in loaded.values():
		var root_node := tile_data.get("root") as Node3D
		if not is_instance_valid(root_node):
			continue
		var payload: Dictionary = tile_data.get("bundle", {}).get("reef_payload", {})
		for record in payload.get("cluster_debug", []):
			var local := Vector3(float(record.get("east", 0.0)) - float(tile_data["key"].x) * float(_manager.get("tile_size_m")), float(record.get("ground_y", 0.0)), float(tile_data["key"].y + 1) * float(_manager.get("tile_size_m")) - float(record.get("north", 0.0)))
			var world_position := root_node.global_transform * local
			var distance := Vector2(world_position.x - origin.x, world_position.z - origin.z).length()
			if distance < float(best["distance_m"]):
				best = {"valid": true, "position": world_position, "distance_m": distance}
	return best


func _measure_density_profile(camera_profile: String) -> void:
	var results: Array[Dictionary] = []
	var generation_results: Array[Dictionary] = []
	var states := [
		{"label": "OFF", "enabled": false, "preset": 1, "sway": false},
		{"label": "NORMAL_STATIC", "enabled": true, "preset": 1, "sway": false},
		{"label": "NORMAL_SWAY", "enabled": true, "preset": 1, "sway": true},
		{"label": "DENSE_SWAY", "enabled": true, "preset": 2, "sway": true},
	]
	for state in states:
		_manager.set("_maximum_seagrass_slice_ms", 0.0)
		_manager.set("_maximum_seagrass_finish_ms", 0.0)
		_manager.set("enable_seagrass", bool(state["enabled"]))
		_manager.set("enable_seagrass_sway", bool(state["sway"]))
		_manager.set("seagrass_density_preset", int(state["preset"]))
		_manager.call("_sync_runtime_options")
		var generation := {"profile": camera_profile, "label": str(state["label"]), "generation_wall_ms": 0.0, "maximum_generation_slice_ms": 0.0, "max_frame_ms": 0.0}
		if bool(state["enabled"]):
			generation = await _measure_generation_settle(str(state["label"]))
			generation["profile"] = camera_profile
			generation_results.append(generation)
			await _wait_for_stream(6000)
		await _settle_frames(60)
		if camera_profile == "stern" and state["label"] == "NORMAL_STATIC":
			await _capture("normal_sway_off.png")
		elif camera_profile == "stern" and state["label"] == "NORMAL_SWAY":
			await _capture("normal_sway_on.png")
		elif camera_profile == "stern" and state["label"] == "DENSE_SWAY":
			await _capture("dense_sway_on.png")
		elif camera_profile == "closeup" and state["label"] == "NORMAL_STATIC":
			await _capture("closeup_normal_static.png")
		elif camera_profile == "closeup" and state["label"] == "NORMAL_SWAY":
			await _capture("closeup_normal_sway.png")
		elif camera_profile == "closeup" and state["label"] == "DENSE_SWAY":
			await _capture("closeup_dense_sway.png")
		var repeats: Array[Dictionary] = []
		for repeat_index in range(3):
			await _settle_frames(30)
			repeats.append(await _measure_scene("%s_R%d" % [state["label"], repeat_index + 1]))
		results.append({"profile": camera_profile, "label": state["label"], "repeats": repeats, "generation": generation})
	_performance_results.append_array(results)
	_generation_results.append_array(generation_results)
	_manager.set("seagrass_density_preset", 1)
	_manager.set("enable_seagrass", true)
	_manager.set("enable_seagrass_sway", true)
	_manager.call("_sync_runtime_options")
	await _wait_for_stream(6000)
	await _settle_frames(60)


func _measure_scene(label: String) -> Dictionary:
	var frame_count := 180
	var frame_times := PackedFloat32Array()
	var fps_total := 0.0
	var fps_samples := 0
	var draw_calls_total := 0.0
	var primitives_total := 0.0
	for _frame in range(frame_count):
		var frame_started_usec := Time.get_ticks_usec()
		await process_frame
		frame_times.append(float(Time.get_ticks_usec() - frame_started_usec) / 1000.0)
		var fps := Engine.get_frames_per_second()
		if fps > 0:
			fps_total += float(fps)
			fps_samples += 1
		draw_calls_total += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		primitives_total += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	frame_times.sort()
	var mean_frame_ms := 0.0
	for frame_ms in frame_times:
		mean_frame_ms += frame_ms
	mean_frame_ms /= maxf(float(frame_count), 1.0)
	var stats: Dictionary = _manager.call("get_debug_stats")
	return {
		"label": label,
		"frames": frame_count,
		"wall_fps": 1000.0 / maxf(mean_frame_ms, 0.001),
		"engine_fps_mean": fps_total / maxf(float(fps_samples), 1.0),
		"mean_frame_ms": mean_frame_ms,
		"p95_frame_ms": frame_times[mini(frame_count - 1, int(ceil(float(frame_count) * 0.95)) - 1)],
		"p99_frame_ms": frame_times[mini(frame_count - 1, int(ceil(float(frame_count) * 0.99)) - 1)],
		"worst_frame_ms": frame_times[frame_count - 1],
		"draw_calls_mean": draw_calls_total / float(frame_count),
		"primitives_mean": primitives_total / float(frame_count),
		"seagrass_instances": stats.get("seagrass_instances", 0),
		"seagrass_triangles": stats.get("seagrass_triangles", 0),
		"seagrass_batches": stats.get("seagrass_batches", 0),
		"patch_extent_percent": stats.get("seagrass_estimated_patch_extent_percent", 0.0),
		"estimated_canopy_in_patches_percent": stats.get("seagrass_estimated_canopy_coverage_percent", 0.0),
		"generated_patch_density_per_m2": stats.get("seagrass_generated_density_per_patch_m2", 0.0),
		"last_build_cpu_ms": stats.get("seagrass_last_build_ms", 0.0),
		"average_build_cpu_ms": stats.get("seagrass_average_build_ms", 0.0),
	}


func _measure_generation_settle(label: String) -> Dictionary:
	_manager.set("_maximum_seagrass_slice_ms", 0.0)
	var started_usec := Time.get_ticks_usec()
	var stable_frames := 0
	var frame_count := 0
	var max_frame_ms := 0.0
	var frame_ms_total := 0.0
	var fps_total := 0.0
	var fps_samples := 0
	var stats: Dictionary = {}
	var slow_frames: Array[Dictionary] = []
	while frame_count < 2400 and stable_frames < 8:
		var frame_started := Time.get_ticks_usec()
		await process_frame
		var frame_ms := float(Time.get_ticks_usec() - frame_started) / 1000.0
		frame_count += 1
		frame_ms_total += frame_ms
		max_frame_ms = maxf(max_frame_ms, frame_ms)
		var fps := Engine.get_frames_per_second()
		if fps > 0:
			fps_total += float(fps)
			fps_samples += 1
		stats = _manager.call("get_debug_stats")
		if frame_ms >= 15.0:
			slow_frames.append({
				"frame_ms": frame_ms,
				"pending_tiles": stats.get("pending_tiles", -1),
				"last_grass_slice_ms": stats.get("seagrass_last_slice_ms", 0.0),
				"max_grass_slice_ms": stats.get("seagrass_maximum_slice_ms", 0.0),
				"last_grass_finish_ms": stats.get("seagrass_last_finish_ms", 0.0),
				"max_grass_finish_ms": stats.get("seagrass_maximum_finish_ms", 0.0),
				"last_terrain_build_ms": stats.get("last_chunk_build_ms", 0.0),
			})
		if int(stats.get("pending_tiles", 1)) == 0:
			stable_frames += 1
		else:
			stable_frames = 0
	if stable_frames < 8:
		push_error("Seagrass generation did not settle during the %s measurement." % label)
	slow_frames.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["frame_ms"]) > float(b["frame_ms"]))
	if slow_frames.size() > 8:
		slow_frames.resize(8)
	var elapsed_usec := Time.get_ticks_usec() - started_usec
	return {
		"label": label,
		"frames_until_settled": frame_count,
		"generation_wall_ms": float(elapsed_usec) / 1000.0,
		"mean_frame_ms": frame_ms_total / maxf(float(frame_count), 1.0),
		"max_frame_ms": max_frame_ms,
		"engine_fps_mean": fps_total / maxf(float(fps_samples), 1.0),
		"maximum_generation_slice_ms": stats.get("seagrass_maximum_slice_ms", 0.0),
		"slow_frames_over_15ms": slow_frames,
		"eelgrass_instances": stats.get("eelgrass_instances", 0),
		"seagrass_triangles": stats.get("seagrass_triangles", 0),
		"last_tile_cpu_ms": stats.get("seagrass_last_build_ms", 0.0),
	}


func _capture(file_name: String) -> void:
	await RenderingServer.frame_post_draw
	var directory := ProjectSettings.globalize_path(OUTPUT_DIR)
	DirAccess.make_dir_recursive_absolute(directory)
	var image := root.get_texture().get_image()
	var error := image.save_png(ProjectSettings.globalize_path(OUTPUT_DIR.path_join(file_name)))
	print("[ShallowSeagrassCapture] %s result=%s size=%s" % [file_name, str(error), str(image.get_size())])


func _write_performance_results(results: Array[Dictionary]) -> void:
	var lines := PackedStringArray()
	lines.append("Godot 4.7.2 Forward+ / Metal · Apple M2 Pro · 1920×1080 · two fixed camera profiles (stern-oblique and dense close-up), same GPS/time/weather · three repeats × 180 frames per condition · seagrass budget %.1f ms, 64 candidates/slice" % float(_manager.get("seagrass_generation_budget_ms")))
	lines.append("Frame times are wall-clock intervals across process_frame, not GPU timestamps. Draw calls/primitives use Godot Rendering monitors. BaseBoat FBX is a Git LFS pointer in this checkout, so screenshots do not include its visual mesh.")
	for result in results:
		lines.append(JSON.stringify(result))
	_write_text("performance.txt", "\n".join(lines) + "\n")


func _write_generation_results(results: Array[Dictionary]) -> void:
	var lines := PackedStringArray()
	lines.append("Godot 4.7.2 Forward+ / Metal · Apple M2 Pro · 1920×1080 · fixed stern-oblique and dense close-up profiles · %.1f ms seagrass-generation budget · 64 candidate samples per slice." % float(_manager.get("seagrass_generation_budget_ms")))
	lines.append("Generation frames include engine scheduling, script sampling, mesh/MultiMesh setup and rendering; GPU timestamps are unavailable.")
	for result in results:
		lines.append(JSON.stringify(result))
	_write_text("generation_performance.txt", "\n".join(lines) + "\n")


func _write_report(stats: Dictionary) -> void:
	var lines := PackedStringArray()
	lines.append("# Shallow Seagrass Art Upgrade")
	lines.append("")
	lines.append("Godot 4.7.2 / Forward+ / Apple M2 Pro · 1920×1080 · July clear midday · Malmö start 2.24 m LAT · performance capture run after the laptop was plugged in.")
	lines.append("The development checkout contains `assets/boats/base_boat.fbx` as a Git LFS pointer, so the stern camera framing is representative but the boat mesh is missing in these captures.")
	lines.append("")
	lines.append("The mesh silhouette, vertex colors and vertex-stage sway were upgraded. GPS placement, ecology patch layout, layout seed/version, coverage and density targets were left unchanged. Eelgrass mesh style version is `%s`." % str(stats.get("seagrass_mesh_style_version", "unknown")))
	lines.append("")
	lines.append("End-of-run stats snapshot (after moving through the top-down, close-up, reef-transition, and debug views; active tiles follow the camera): `%s`" % JSON.stringify(stats))
	lines.append("")
	lines.append("## Shape and visual comparison")
	lines.append("")
	lines.append("| Before | After |")
	lines.append("| --- | --- |")
	lines.append("| ![Previous eelgrass close-up](../shallow_seagrass/03_eelgrass_close_patch.png) | ![Updated eelgrass close-up](03_eelgrass_close_patch.png) |")
	lines.append("")
	lines.append("The updated ribbon keeps a stable-width body, narrows only near its tip, and starts from a loose fan crown. The near mesh uses shared segment-row vertices (about 40% fewer vertices for the same triangles than the old duplicated-row representation); far LOD uses about 33% fewer. Colors remain muted gray-green/olive, with slight per-leaf variation. Root motion is weighted to zero; two slow low-cost flow waves act mainly on upper blades.")
	lines.append("")
	lines.append("## Captures")
	lines.append("")
	lines.append("| View | Image |")
	lines.append("| --- | --- |")
	lines.append("| Normal density, stern-oblique camera | ![Normal stern view](01_stern_oblique_normal.png) |")
	lines.append("| Normal density, sway off | ![Normal sway off](normal_sway_off.png) |")
	lines.append("| Normal density, sway on | ![Normal sway on](normal_sway_on.png) |")
	lines.append("| Dense density, sway on | ![Dense sway on](dense_sway_on.png) |")
	lines.append("| Dense close-up, Normal static / Normal sway / Dense sway | ![Normal static close-up](closeup_normal_static.png) ![Normal sway close-up](closeup_normal_sway.png) ![Dense sway close-up](closeup_dense_sway.png) |")
	lines.append("| Sway snapshots | [t0](sway_closeup_t0.png) · [t1](sway_closeup_t1.png) · [t2](sway_closeup_t2.png) |")
	lines.append("| Top-down distribution | ![Top-down](02_top_down_malmo_start.png) |")
	lines.append("| Eelgrass patch close-up | ![Close-up](03_eelgrass_close_patch.png) |")
	lines.append("| Reef transition | ![Reef transition](04_reef_and_seagrass_transition.png) |")
	lines.append("| Patch guides and stats | ![Patch debug](05_patch_distribution_debug.png) |")
	lines.append("| Night light response | ![Night seagrass](06_night_seagrass.png) |")
	lines.append("")
	lines.append("Steady-state A/B performance is in `performance.txt`; generation-phase frame measurements are in `generation_performance.txt`. It uses two fixed camera profiles (stern-oblique and dense close-up); each profile holds GPS, camera, time, weather, resolution and warm-up constant across modes, with three 180-frame repeats. The current base-boat LFS resource is missing, so the camera can frame the meadow but cannot show the actual hull.")
	lines.append("")
	lines.append("Canopy percentage is an area estimate using a fixed projected footprint per tuft; it is not measured from rendered pixels. Patch coverage and density remain artistic approximations, not local ecological survey data.")
	_write_text("README.md", "\n".join(lines) + "\n")


func _write_text(file_name: String, contents: String) -> void:
	var directory := ProjectSettings.globalize_path(OUTPUT_DIR)
	DirAccess.make_dir_recursive_absolute(directory)
	var file := FileAccess.open(OUTPUT_DIR.path_join(file_name), FileAccess.WRITE)
	if file == null:
		push_error("Unable to write seagrass report: %s" % FileAccess.get_open_error())
		return
	file.store_string(contents)
	file.close()
