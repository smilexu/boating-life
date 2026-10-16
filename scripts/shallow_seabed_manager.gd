class_name ShallowSeabedManager
extends Node3D

## Streams deterministic, chart-derived 0–9 m seabed tiles around the player.
## The extra mesh below the 6 m visibility limit is only a hidden fade margin;
## it does not change bathymetry or navigation depth.

const CACHE_LIMIT := 24
const SCAN_CACHE_LIMIT := 512
const INVALID_TILE := Vector2i(-2147483647, -2147483647)
const ROCK_VARIANTS := 5
const ROCK_SEED := 76123

@export_category("References")
@export var georeference: GeoReference
@export_node_path("Node") var bathymetry_manager_path := NodePath("../BathymetryManager")
@export_node_path("Node3D") var player_boat_path := NodePath("../PlayerBoat/MotionRoot")
@export var water_material: ShaderMaterial
@export var seabed_material: ShaderMaterial

@export_category("Streaming")
@export var system_enabled := true
@export_range(32.0, 512.0, 16.0) var tile_size_m := 128.0
@export_range(64.0, 500.0, 16.0) var near_radius_m := 300.0
@export_range(200.0, 1200.0, 16.0) var far_radius_m := 600.0
@export_range(64.0, 1400.0, 16.0) var unload_radius_m := 704.0
@export_range(1.0, 60.0, 1.0) var coarse_scan_spacing_m := 32.0
@export_range(1, 4, 1) var generation_jobs_per_frame := 1
@export_range(8, 64, 1) var mesh_depth_limit_m := 9.0
@export_range(0.0, 2.0, 0.05) var water_surface_above_lat_m := 0.5

@export_category("Geometry LOD")
@export_range(8.0, 32.0, 1.0) var near_vertex_spacing_m := 16.0
@export_range(16.0, 64.0, 1.0) var far_vertex_spacing_m := 32.0
@export_range(8.0, 64.0, 4.0) var lod_hysteresis_m := 32.0
@export_range(0.0, 0.4, 0.01) var broad_relief_amplitude_m := 0.15
@export_range(0.0, 0.15, 0.01) var fine_relief_amplitude_m := 0.04

@export_category("Reefs")
@export var enable_procedural_rocks := true
@export_range(0.2, 6.0, 0.1) var maximum_rock_depth_m := 5.8
@export_range(8.0, 48.0, 2.0) var rock_candidate_spacing_m := 16.0
@export_range(0.0, 1.0, 0.05) var rock_density_near := 1.0
@export_range(0.0, 1.0, 0.05) var rock_density_far := 0.32

@export_category("Developer Controls")
@export var show_chunk_bounds := false
@export var show_statistics := false
@export var show_lod_debug := false

var _bathymetry: BathymetryManager
var _boat: Node3D
var _reef_meshes: Array[ArrayMesh] = []
var _reef_material: StandardMaterial3D
var _pending_scan: Array[Dictionary] = []
var _pending_build: Array[Dictionary] = []
var _requested_tiles: Dictionary = {}
var _scan_cache: Dictionary = {}
var _scan_cache_lru: Array[Vector2i] = []
var _loaded_tiles: Dictionary = {}
var _mesh_cache: Dictionary = {}
var _mesh_cache_lru: Array[Vector3i] = []
var _last_center_tile := INVALID_TILE
var _runtime_enabled := false
var _runtime_rocks_enabled := false
var _runtime_bounds_enabled := false
var _runtime_statistics_enabled := false
var _runtime_lod_debug := false
var _stats_label: Label
var _stats_layer: CanvasLayer
var _refresh_elapsed := 0.0
var _stats_elapsed := 0.0
var _last_build_ms := 0.0
var _average_build_ms := 0.0
var _completed_builds := 0
var _debug_rocks_count := 0


func _ready() -> void:
	_bathymetry = get_node_or_null(bathymetry_manager_path) as BathymetryManager
	_boat = get_node_or_null(player_boat_path) as Node3D
	if water_material == null and _bathymetry != null:
		water_material = _bathymetry.water_material
	if georeference == null and _bathymetry != null:
		georeference = _bathymetry.georeference
	if _bathymetry == null or _boat == null or georeference == null:
		push_error("ShallowSeabedManager requires BathymetryManager, GeoReference and PlayerBoat/MotionRoot.")
		system_enabled = false
		return
	if not _bathymetry.data_available:
		push_warning("Shallow seabed is disabled because the offline EMODnet grid is unavailable.")
		system_enabled = false
		return
	if seabed_material == null:
		push_error("ShallowSeabedManager needs its shallow seabed ShaderMaterial resource.")
		system_enabled = false
		return
	water_material.set_shader_parameter("shallow_surface_above_lat_m", water_surface_above_lat_m)

	_reef_meshes = ShallowReefGenerator.create_rock_meshes(ROCK_VARIANTS)
	_reef_material = _create_reef_material()
	_build_statistics_ui()
	_runtime_enabled = system_enabled
	_runtime_rocks_enabled = enable_procedural_rocks
	_runtime_bounds_enabled = show_chunk_bounds
	_runtime_statistics_enabled = show_statistics
	_runtime_lod_debug = show_lod_debug
	seabed_material.set_shader_parameter("show_lod_debug", show_lod_debug)
	if _runtime_enabled:
		visible = true
		_refresh_requested_tiles()
	var start_depth: Dictionary = _bathymetry.get_depth_at_world_position(_boat.global_position)
	var start_geo := georeference.world_to_geodetic(Vector3(_boat.global_position.x, 0.0, _boat.global_position.z))
	print("[ShallowSeabed] start GPS %.5f N, %.5f E · depth %s" % [start_geo.x, start_geo.y, _depth_text(start_depth)])


func _process(delta: float) -> void:
	_sync_runtime_options()
	if not _runtime_enabled or _boat == null:
		return
	_refresh_elapsed += delta
	if _refresh_elapsed >= 0.5:
		_refresh_elapsed = fmod(_refresh_elapsed, 0.5)
		var current_tile := _get_boat_tile()
		if current_tile != _last_center_tile:
			_refresh_requested_tiles()
	_process_generation_queue()
	_stats_elapsed += delta
	if _stats_elapsed >= 0.25:
		_stats_elapsed = fmod(_stats_elapsed, 0.25)
		_update_statistics_text()


func _unhandled_key_input(event: InputEvent) -> void:
	if event is not InputEventKey or not event.pressed or event.echo:
		return
	if event.physical_keycode == KEY_F6:
		_toggle_water_transparency()
	elif event.physical_keycode == KEY_F7 and not event.shift_pressed and not event.ctrl_pressed:
		system_enabled = not system_enabled
		_sync_runtime_options()
	elif event.physical_keycode == KEY_F8:
		if event.shift_pressed:
			show_chunk_bounds = not show_chunk_bounds
		elif event.ctrl_pressed:
			enable_procedural_rocks = not enable_procedural_rocks
		elif event.alt_pressed:
			show_lod_debug = not show_lod_debug
		else:
			show_statistics = not show_statistics
		_sync_runtime_options()


func get_debug_stats() -> Dictionary:
	var triangle_count := 0
	var active_chunk_count := 0
	var rock_count := 0
	for tile_data in _loaded_tiles.values():
		if not is_instance_valid(tile_data.get("root")):
			continue
		active_chunk_count += 1
		triangle_count += int(tile_data.get("triangles", 0))
		if _runtime_rocks_enabled:
			rock_count += int(tile_data.get("rocks", 0))
	return {
		"enabled": _runtime_enabled,
		"loaded_chunks": _loaded_tiles.size(),
		"active_chunks": active_chunk_count,
		"loaded_triangles": triangle_count,
		"rock_instances": rock_count,
		"pending_tiles": _pending_scan.size() + _pending_build.size(),
		"last_chunk_build_ms": _last_build_ms,
		"average_chunk_build_ms": _average_build_ms,
		"near_lod_chunks": _count_lod_chunks(0),
		"far_lod_chunks": _count_lod_chunks(1),
	}


func _sync_runtime_options() -> void:
	if _runtime_enabled != system_enabled:
		_runtime_enabled = system_enabled
		visible = _runtime_enabled
		if _runtime_enabled:
			_last_center_tile = INVALID_TILE
			_refresh_requested_tiles()
		else:
			_pending_scan.clear()
			_pending_build.clear()
			_requested_tiles.clear()
			for key in _loaded_tiles.keys():
				_release_tile(key, true)
	if _runtime_rocks_enabled != enable_procedural_rocks:
		_runtime_rocks_enabled = enable_procedural_rocks
		_rebuild_active_rocks()
	if _runtime_bounds_enabled != show_chunk_bounds:
		_runtime_bounds_enabled = show_chunk_bounds
		for tile_data in _loaded_tiles.values():
			_set_tile_bounds_visible(tile_data, _runtime_bounds_enabled)
	if _runtime_statistics_enabled != show_statistics:
		_runtime_statistics_enabled = show_statistics
		if _stats_layer != null:
			_stats_layer.visible = _runtime_statistics_enabled
	if _runtime_lod_debug != show_lod_debug:
		_runtime_lod_debug = show_lod_debug
		if seabed_material != null:
			seabed_material.set_shader_parameter("show_lod_debug", _runtime_lod_debug)


func _refresh_requested_tiles() -> void:
	if not _runtime_enabled or _boat == null:
		return
	_last_center_tile = _get_boat_tile()
	_pending_scan.clear()
	_pending_build.clear()
	_requested_tiles.clear()
	var boat_east_north := Vector2(_boat.global_position.x, -_boat.global_position.z)
	var half_tile_diagonal := tile_size_m * sqrt(0.5)
	var tile_search_radius := ceili((unload_radius_m + half_tile_diagonal) / tile_size_m)
	var candidate_tiles: Array[Dictionary] = []
	for y in range(_last_center_tile.y - tile_search_radius, _last_center_tile.y + tile_search_radius + 1):
		for x in range(_last_center_tile.x - tile_search_radius, _last_center_tile.x + tile_search_radius + 1):
			var key := Vector2i(x, y)
			var center := Vector2((float(x) + 0.5) * tile_size_m, (float(y) + 0.5) * tile_size_m)
			var distance := center.distance_to(boat_east_north)
			if distance > far_radius_m + half_tile_diagonal:
				continue
			var lod := _choose_lod(key, distance)
			_requested_tiles[key] = lod
			candidate_tiles.append({"key": key, "lod": lod, "distance": distance})
	candidate_tiles.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["distance"]) < float(b["distance"]))
	for request in candidate_tiles:
		_queue_tile_if_needed(request["key"], int(request["lod"]))

	var loaded_keys: Array = _loaded_tiles.keys()
	for key_value in loaded_keys:
		var key: Vector2i = key_value
		var center := Vector2((float(key.x) + 0.5) * tile_size_m, (float(key.y) + 0.5) * tile_size_m)
		var distance := center.distance_to(boat_east_north)
		if distance > unload_radius_m + half_tile_diagonal:
			_release_tile(key, true)
			_requested_tiles.erase(key)
		elif not _requested_tiles.has(key):
			var existing_lod := int(_loaded_tiles[key].get("lod", 1))
			_requested_tiles[key] = existing_lod


func _queue_tile_if_needed(key: Vector2i, lod: int) -> void:
	if _loaded_tiles.has(key) and int(_loaded_tiles[key].get("lod", -1)) == lod:
		return
	var cache_key := Vector3i(key.x, key.y, lod)
	if _mesh_cache.has(cache_key):
		_pending_build.append({"key": key, "lod": lod})
		return
	if _scan_cache.has(key):
		_touch_scan_cache(key)
		if bool(_scan_cache[key]):
			_pending_build.append({"key": key, "lod": lod})
		return
	_pending_scan.append({"key": key, "lod": lod})


func _choose_lod(key: Vector2i, distance: float) -> int:
	var previous_lod := -1
	if _loaded_tiles.has(key):
		previous_lod = int(_loaded_tiles[key].get("lod", -1))
	elif _requested_tiles.has(key):
		previous_lod = int(_requested_tiles[key])
	if previous_lod == 0:
		return 0 if distance <= near_radius_m + lod_hysteresis_m else 1
	if previous_lod == 1:
		return 0 if distance < near_radius_m - lod_hysteresis_m else 1
	return 0 if distance < near_radius_m else 1


func _process_generation_queue() -> void:
	var job_budget := maxi(generation_jobs_per_frame, 1)
	while job_budget > 0:
		job_budget -= 1
		if not _pending_scan.is_empty():
			_process_one_scan()
			continue
		if not _pending_build.is_empty():
			_process_one_build()
			continue
		break


func _process_one_scan() -> void:
	var request: Dictionary = _pending_scan.pop_front()
	var key: Vector2i = request["key"]
	if not _request_is_current(key, int(request["lod"])):
		return
	var has_shallow_water := _tile_has_shallow_water(key)
	_cache_scan_result(key, has_shallow_water)
	if has_shallow_water:
		_pending_build.append(request)


func _process_one_build() -> void:
	var request: Dictionary = _pending_build.pop_front()
	var key: Vector2i = request["key"]
	var lod := int(request["lod"])
	if not _request_is_current(key, lod):
		return
	var cache_key := Vector3i(key.x, key.y, lod)
	var bundle: Dictionary
	if _mesh_cache.has(cache_key):
		bundle = _take_cached_bundle(cache_key)
	else:
		var start_usec := Time.get_ticks_usec()
		bundle = _build_tile_bundle(key, lod)
		_last_build_ms = float(Time.get_ticks_usec() - start_usec) / 1000.0
		_completed_builds += 1
		_average_build_ms += (_last_build_ms - _average_build_ms) / float(_completed_builds)
	if bundle.is_empty() or bundle.get("mesh") == null:
		return
	_attach_tile(key, lod, bundle)


func _request_is_current(key: Vector2i, lod: int) -> bool:
	return _runtime_enabled and _requested_tiles.has(key) and int(_requested_tiles[key]) == lod


func _cache_scan_result(key: Vector2i, has_shallow_water: bool) -> void:
	_scan_cache[key] = has_shallow_water
	_touch_scan_cache(key)
	while _scan_cache_lru.size() > SCAN_CACHE_LIMIT:
		var oldest: Vector2i = _scan_cache_lru.pop_front()
		_scan_cache.erase(oldest)


func _touch_scan_cache(key: Vector2i) -> void:
	_scan_cache_lru.erase(key)
	_scan_cache_lru.append(key)


func _tile_has_shallow_water(key: Vector2i) -> bool:
	var east_min := float(key.x) * tile_size_m
	var north_min := float(key.y) * tile_size_m
	var samples := ceili(tile_size_m / coarse_scan_spacing_m)
	var spacing := tile_size_m / float(samples)
	for z_index in range(samples + 1):
		var north := north_min + float(z_index) * spacing
		for x_index in range(samples + 1):
			var east := east_min + float(x_index) * spacing
			var sample: Dictionary = _sample_depth(east, north)
			if bool(sample.get("valid", false)) and float(sample.get("depth_m", INF)) <= mesh_depth_limit_m:
				return true
	return false


func _build_tile_bundle(key: Vector2i, lod: int) -> Dictionary:
	var east_min := float(key.x) * tile_size_m
	var north_min := float(key.y) * tile_size_m
	var north_max := north_min + tile_size_m
	var step := near_vertex_spacing_m if lod == 0 else far_vertex_spacing_m
	var segments := roundi(tile_size_m / step)
	if segments <= 0 or not is_equal_approx(float(segments) * step, tile_size_m):
		push_error("Tile size must be divisible by the selected seabed LOD spacing.")
		return {}
	var width := segments + 1
	var vertex_count := width * width
	var heights := PackedFloat32Array()
	var depths := PackedFloat32Array()
	var validity := PackedByteArray()
	heights.resize(vertex_count)
	depths.resize(vertex_count)
	validity.resize(vertex_count)

	for row in range(width):
		var north := north_max - float(row) * step
		for column in range(width):
			var east := east_min + float(column) * step
			var sample := _sample_tile_vertex(key, east, north, row, column, segments, step, lod)
			var index := row * width + column
			if bool(sample.get("valid", false)):
				depths[index] = float(sample["depth_m"])
				heights[index] = float(sample["height_m"])
				validity[index] = 1
			else:
				depths[index] = mesh_depth_limit_m + 1.0
				heights[index] = -mesh_depth_limit_m
				validity[index] = 0

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	vertices.resize(vertex_count)
	normals.resize(vertex_count)
	colors.resize(vertex_count)
	uvs.resize(vertex_count)
	for row in range(width):
		for column in range(width):
			var index := row * width + column
			var east := east_min + float(column) * step
			var north := north_max - float(row) * step
			vertices[index] = Vector3(float(column) * step, heights[index], float(row) * step)
			uvs[index] = Vector2(east, north) * 0.06
			normals[index] = _vertex_normal(key, east, north, row, column, segments, width, step, heights, validity, lod)
			if validity[index] == 1:
				var slope := _grid_slope(row, column, width, step, heights, validity)
				colors[index] = _material_weights(east, north, depths[index], slope, lod)
			else:
				colors[index] = Color(1.0, 0.0, 0.0, 1.0 if lod == 0 else 0.0)
	if lod == 0:
		_constrain_near_edge_colors(colors, depths, validity, width, segments)

	var indices := PackedInt32Array()
	var triangle_count := 0
	for row in range(segments):
		for column in range(segments):
			var north_west := row * width + column
			var south_west := north_west + width
			var north_east := north_west + 1
			var south_east := south_west + 1
			if _triangle_is_valid([north_west, south_west, north_east], depths, validity):
				# Godot front-face winding for a top-facing X/Z grid is clockwise
				# when viewed from +Y. Keep the supplied finite-difference normals up.
				indices.append_array(PackedInt32Array([north_west, north_east, south_west]))
				triangle_count += 1
			if _triangle_is_valid([north_east, south_west, south_east], depths, validity):
				indices.append_array(PackedInt32Array([north_east, south_east, south_west]))
				triangle_count += 1
	if triangle_count == 0:
		return {}

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var rock_records := _build_rock_records(key, lod, east_min, north_min, north_max)
	var rock_count := 0
	for variant_records in rock_records:
		rock_count += variant_records.size()
	return {
		"mesh": mesh,
		"triangles": triangle_count,
		"rocks": rock_count,
		"rock_records": rock_records,
		"lod": lod,
	}


func _sample_tile_vertex(
	key: Vector2i,
	east: float,
	north: float,
	row: int,
	column: int,
	segments: int,
	step: float,
	lod: int
) -> Dictionary:
	if lod != 0:
		return _sample_ground(east, north)
	var is_vertical_edge := column == 0 or column == segments
	var is_horizontal_edge := row == 0 or row == segments
	var anchor_step := far_vertex_spacing_m
	if is_vertical_edge and row % 2 != 0:
		var low_north := floorf(north / anchor_step) * anchor_step
		var high_north := low_north + anchor_step
		var t := clampf((north - low_north) / anchor_step, 0.0, 1.0)
		return _lerp_ground_samples(_sample_ground(east, low_north), _sample_ground(east, high_north), t)
	if is_horizontal_edge and column % 2 != 0:
		var low_east := floorf(east / anchor_step) * anchor_step
		var high_east := low_east + anchor_step
		var t := clampf((east - low_east) / anchor_step, 0.0, 1.0)
		return _lerp_ground_samples(_sample_ground(low_east, north), _sample_ground(high_east, north), t)
	return _sample_ground(east, north)


func _lerp_ground_samples(a: Dictionary, b: Dictionary, weight: float) -> Dictionary:
	if not bool(a.get("valid", false)) or not bool(b.get("valid", false)):
		return {"valid": false}
	return {
		"valid": true,
		"depth_m": lerpf(float(a["depth_m"]), float(b["depth_m"]), weight),
		"height_m": lerpf(float(a["height_m"]), float(b["height_m"]), weight),
	}


func _sample_ground(east: float, north: float) -> Dictionary:
	var depth_data := _sample_depth(east, north)
	if not bool(depth_data.get("valid", false)):
		return {"valid": false}
	var depth_m := float(depth_data.get("depth_m", INF))
	if depth_m < 0.0:
		return {"valid": false}
	var relief := _visual_relief(east, north)
	return {
		"valid": true,
		"depth_m": depth_m,
		"height_m": -(depth_m + water_surface_above_lat_m) + relief,
	}


func _sample_depth(east: float, north: float) -> Dictionary:
	return _bathymetry.get_depth_at_world_position(Vector3(east, 0.0, -north))


func _visual_relief(east: float, north: float) -> float:
	var broad := _value_noise(east, north, 0.0045, 811) - 0.5
	var fine := _value_noise(east, north, 0.022, 227) - 0.5
	return broad * 2.0 * broad_relief_amplitude_m + fine * 2.0 * fine_relief_amplitude_m


func _vertex_normal(
	key: Vector2i,
	east: float,
	north: float,
	row: int,
	column: int,
	segments: int,
	width: int,
	step: float,
	heights: PackedFloat32Array,
	validity: PackedByteArray,
	lod: int
) -> Vector3:
	if validity[row * width + column] == 0:
		return Vector3.UP
	var is_vertical_edge := column == 0 or column == segments
	var is_horizontal_edge := row == 0 or row == segments
	if lod == 0 and (is_vertical_edge or is_horizontal_edge):
		var anchor_step := far_vertex_spacing_m
		if is_vertical_edge and row % 2 != 0:
			var low_north := floorf(north / anchor_step) * anchor_step
			var t := clampf((north - low_north) / anchor_step, 0.0, 1.0)
			var low_normal := _world_edge_normal(east, low_north, anchor_step)
			var high_normal := _world_edge_normal(east, low_north + anchor_step, anchor_step)
			return low_normal.lerp(high_normal, t).normalized()
		if is_horizontal_edge and column % 2 != 0:
			var low_east := floorf(east / anchor_step) * anchor_step
			var t := clampf((east - low_east) / anchor_step, 0.0, 1.0)
			var low_normal := _world_edge_normal(low_east, north, anchor_step)
			var high_normal := _world_edge_normal(low_east + anchor_step, north, anchor_step)
			return low_normal.lerp(high_normal, t).normalized()
		return _world_edge_normal(east, north, anchor_step)

	var center := heights[row * width + column]
	var left := center
	var right := center
	var north_height := center
	var south := center
	var left_valid := column > 0 and validity[row * width + column - 1] == 1
	var right_valid := column < segments and validity[row * width + column + 1] == 1
	var north_valid := row > 0 and validity[(row - 1) * width + column] == 1
	var south_valid := row < segments and validity[(row + 1) * width + column] == 1
	if left_valid:
		left = heights[row * width + column - 1]
	if right_valid:
		right = heights[row * width + column + 1]
	if north_valid:
		north_height = heights[(row - 1) * width + column]
	if south_valid:
		south = heights[(row + 1) * width + column]
	var x_distance := step * (2.0 if left_valid and right_valid else 1.0)
	var z_distance := step * (2.0 if north_valid and south_valid else 1.0)
	var derivative_east := (right - left) / maxf(x_distance, 0.001)
	var derivative_south := (south - north_height) / maxf(z_distance, 0.001)
	return Vector3(-derivative_east, 1.0, -derivative_south).normalized()


func _world_edge_normal(east: float, north: float, step: float) -> Vector3:
	var center := _sample_height_or_zero(east, north)
	var east_plus := _sample_height_or_center(east + step, north, center)
	var east_minus := _sample_height_or_center(east - step, north, center)
	var north_plus := _sample_height_or_center(east, north + step, center)
	var north_minus := _sample_height_or_center(east, north - step, center)
	var d_east := (east_plus - east_minus) / (2.0 * step)
	var d_north := (north_plus - north_minus) / (2.0 * step)
	return Vector3(-d_east, 1.0, d_north).normalized()


func _sample_height_or_zero(east: float, north: float) -> float:
	var sample := _sample_ground(east, north)
	return float(sample.get("height_m", 0.0)) if bool(sample.get("valid", false)) else 0.0


func _sample_height_or_center(east: float, north: float, center: float) -> float:
	var sample := _sample_ground(east, north)
	return float(sample.get("height_m", center)) if bool(sample.get("valid", false)) else center


func _grid_slope(row: int, column: int, width: int, step: float, heights: PackedFloat32Array, validity: PackedByteArray) -> float:
	var index := row * width + column
	var center := heights[index]
	var left := center
	var right := center
	var north_height := center
	var south := center
	if column > 0 and validity[index - 1] == 1:
		left = heights[index - 1]
	if column + 1 < width and validity[index + 1] == 1:
		right = heights[index + 1]
	if row > 0 and validity[index - width] == 1:
		north_height = heights[index - width]
	if row + 1 < width and validity[index + width] == 1:
		south = heights[index + width]
	var d_east := absf(right - left) / maxf(step * 2.0, 0.001)
	var d_south := absf(south - north_height) / maxf(step * 2.0, 0.001)
	return sqrt(d_east * d_east + d_south * d_south)


func _material_weights(east: float, north: float, depth: float, slope: float, lod: int) -> Color:
	var geology := _value_noise(east, north, 0.0036, 501) * 0.62 + _value_noise(east, north, 0.010, 793) * 0.38
	var slope_rock := smoothstep(0.012, 0.055, slope)
	var rock := clampf(smoothstep(0.57, 0.78, geology) * 0.63 + slope_rock * 0.40, 0.0, 0.86)
	var patch := _value_noise(east, north, 0.006, 1987)
	var mud_zone := smoothstep(2.8, 6.2, depth)
	var mud := clampf(mud_zone * (0.20 + 0.28 * (1.0 - patch)) * (1.0 - rock), 0.0, 0.62)
	var sand := maxf(1.0 - rock - mud, 0.0)
	var sum_weights := maxf(sand + mud + rock, 0.001)
	return Color(sand / sum_weights, mud / sum_weights, rock / sum_weights, 1.0 if lod == 0 else 0.0)


func _constrain_near_edge_colors(colors: PackedColorArray, depths: PackedFloat32Array, validity: PackedByteArray, width: int, segments: int) -> void:
	for row in range(width):
		for column in range(width):
			var on_vertical := column == 0 or column == segments
			var on_horizontal := row == 0 or row == segments
			var lower_index := -1
			var upper_index := -1
			var current_index := row * width + column
			if on_vertical and row % 2 != 0:
				lower_index = (row - 1) * width + column
				upper_index = (row + 1) * width + column
			elif on_horizontal and column % 2 != 0:
				lower_index = row * width + column - 1
				upper_index = row * width + column + 1
			if lower_index >= 0 and validity[lower_index] == 1 and validity[upper_index] == 1:
				colors[current_index] = colors[lower_index].lerp(colors[upper_index], 0.5)
				depths[current_index] = lerpf(depths[lower_index], depths[upper_index], 0.5)


func _triangle_is_valid(indices: Array[int], depths: PackedFloat32Array, validity: PackedByteArray) -> bool:
	for index in indices:
		if validity[index] == 0 or depths[index] > mesh_depth_limit_m:
			return false
	return true


func _build_rock_records(key: Vector2i, lod: int, east_min: float, north_min: float, north_max: float) -> Array:
	var records_by_variant: Array = []
	for _variant in range(ROCK_VARIANTS):
		records_by_variant.append([])
	if not enable_procedural_rocks:
		return records_by_variant
	var candidate_spacing := maxf(rock_candidate_spacing_m, 8.0)
	var first_east_cell := floori(east_min / candidate_spacing)
	var first_north_cell := floori(north_min / candidate_spacing)
	var cells_per_tile := roundi(tile_size_m / candidate_spacing)
	var lod_density := rock_density_near if lod == 0 else rock_density_far
	for north_cell_offset in range(cells_per_tile):
		var north_cell := first_north_cell + north_cell_offset
		for east_cell_offset in range(cells_per_tile):
			var east_cell := first_east_cell + east_cell_offset
			var random_value := _hash01(east_cell, north_cell, ROCK_SEED)
			var east := (float(east_cell) + 0.5 + (_hash01(east_cell, north_cell, 31) - 0.5) * 0.55) * candidate_spacing
			var north := (float(north_cell) + 0.5 + (_hash01(east_cell, north_cell, 47) - 0.5) * 0.55) * candidate_spacing
			var depth_data := _sample_depth(east, north)
			if not bool(depth_data.get("valid", false)):
				continue
			var depth := float(depth_data.get("depth_m", INF))
			if depth < 0.45 or depth > maximum_rock_depth_m:
				continue
			var slope := _candidate_slope(east, north, depth)
			var geology := _value_noise(east, north, 0.0036, 501) * 0.62 + _value_noise(east, north, 0.010, 793) * 0.38
			var rock_weight := clampf(smoothstep(0.57, 0.78, geology) * 0.63 + smoothstep(0.012, 0.055, slope) * 0.40, 0.0, 0.86)
			var mud_weight := smoothstep(2.8, 6.2, depth) * 0.38
			var placement_chance := (0.025 + 0.30 * rock_weight) * lod_density * (1.0 - 0.72 * mud_weight)
			if _hash01(east_cell, north_cell, 91) > placement_chance:
				continue
			var ground := _sample_ground(east, north)
			if not bool(ground.get("valid", false)):
				continue
			var variant := clampi(int(_hash01(east_cell, north_cell, 123) * float(ROCK_VARIANTS)), 0, ROCK_VARIANTS - 1)
			var rock_height := minf(0.35 + _hash01(east_cell, north_cell, 171) * 1.05, maxf(-float(ground["height_m"]), 0.12) * 0.64)
			if rock_height < 0.18:
				continue
			var scale := Vector3(
				rock_height * (0.65 + _hash01(east_cell, north_cell, 191) * 0.75),
				rock_height,
				rock_height * (0.60 + _hash01(east_cell, north_cell, 211) * 0.86)
			)
			var rotation := Vector3(
				(_hash01(east_cell, north_cell, 233) - 0.5) * 0.20,
				_hash01(east_cell, north_cell, 251) * TAU,
				(_hash01(east_cell, north_cell, 271) - 0.5) * 0.20
			)
			var local_position := Vector3(east - east_min, float(ground["height_m"]) + rock_height * 0.16, north_max - north)
			var transform := Transform3D(Basis.from_euler(rotation).scaled(scale), local_position)
			var tint := 0.88 + _hash01(east_cell, north_cell, 307) * 0.20
			var color := Color(tint, tint * (0.97 + _hash01(east_cell, north_cell, 331) * 0.06), tint * (0.92 + _hash01(east_cell, north_cell, 353) * 0.10), 1.0)
			records_by_variant[variant].append({"transform": transform, "color": color})
	return records_by_variant


func _candidate_slope(east: float, north: float, center_depth: float) -> float:
	const sample_offset := 12.0
	var east_plus := _sample_depth(east + sample_offset, north)
	var east_minus := _sample_depth(east - sample_offset, north)
	var north_plus := _sample_depth(east, north + sample_offset)
	var north_minus := _sample_depth(east, north - sample_offset)
	var d_east := 0.0
	var d_north := 0.0
	if bool(east_plus.get("valid", false)) and bool(east_minus.get("valid", false)):
		d_east = (float(east_plus["depth_m"]) - float(east_minus["depth_m"])) / (sample_offset * 2.0)
	elif bool(east_plus.get("valid", false)):
		d_east = (float(east_plus["depth_m"]) - center_depth) / sample_offset
	elif bool(east_minus.get("valid", false)):
		d_east = (center_depth - float(east_minus["depth_m"])) / sample_offset
	if bool(north_plus.get("valid", false)) and bool(north_minus.get("valid", false)):
		d_north = (float(north_plus["depth_m"]) - float(north_minus["depth_m"])) / (sample_offset * 2.0)
	elif bool(north_plus.get("valid", false)):
		d_north = (float(north_plus["depth_m"]) - center_depth) / sample_offset
	elif bool(north_minus.get("valid", false)):
		d_north = (center_depth - float(north_minus["depth_m"])) / sample_offset
	return sqrt(d_east * d_east + d_north * d_north)


func _attach_tile(key: Vector2i, lod: int, bundle: Dictionary) -> void:
	if _loaded_tiles.has(key):
		var previous: Dictionary = _loaded_tiles[key]
		_cache_bundle(key, int(previous["lod"]), previous["bundle"])
		previous["root"].visible = false
		previous["root"].queue_free()
		_loaded_tiles.erase(key)
	var east_min := float(key.x) * tile_size_m
	var north_min := float(key.y) * tile_size_m
	var north_max := north_min + tile_size_m
	var tile_root := Node3D.new()
	tile_root.name = "Seabed_%d_%d_%s" % [key.x, key.y, "Near" if lod == 0 else "Far"]
	tile_root.position = to_local(Vector3(east_min, 0.0, -north_max))
	add_child(tile_root)
	var seabed := MeshInstance3D.new()
	seabed.name = "SeabedMesh"
	seabed.mesh = bundle["mesh"]
	seabed.material_override = seabed_material
	seabed.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	tile_root.add_child(seabed)
	var rocks_root := Node3D.new()
	rocks_root.name = "ProceduralReefs"
	tile_root.add_child(rocks_root)
	var rock_count := 0
	if _runtime_rocks_enabled:
		rock_count = ShallowReefGenerator.add_chunk_multimeshes(
			rocks_root,
			_reef_meshes,
			bundle["rock_records"],
			_reef_material,
			true,
			tile_size_m
		)
	if _runtime_bounds_enabled:
		_add_chunk_bounds(tile_root)
	_loaded_tiles[key] = {
		"root": tile_root,
		"lod": lod,
		"triangles": int(bundle["triangles"]),
		"rocks": rock_count,
		"bundle": bundle,
	}


func _release_tile(key: Vector2i, cache: bool) -> void:
	if not _loaded_tiles.has(key):
		return
	var data: Dictionary = _loaded_tiles[key]
	if cache:
		_cache_bundle(key, int(data["lod"]), data["bundle"])
	if is_instance_valid(data.get("root")):
		data["root"].queue_free()
	_loaded_tiles.erase(key)


func _cache_bundle(key: Vector2i, lod: int, bundle: Dictionary) -> void:
	var cache_key := Vector3i(key.x, key.y, lod)
	_mesh_cache[cache_key] = bundle
	_mesh_cache_lru.erase(cache_key)
	_mesh_cache_lru.append(cache_key)
	while _mesh_cache_lru.size() > CACHE_LIMIT:
		var oldest: Vector3i = _mesh_cache_lru.pop_front()
		_mesh_cache.erase(oldest)


func _take_cached_bundle(cache_key: Vector3i) -> Dictionary:
	_mesh_cache_lru.erase(cache_key)
	_mesh_cache_lru.append(cache_key)
	return _mesh_cache[cache_key]


func _rebuild_active_rocks() -> void:
	for tile_data in _loaded_tiles.values():
		var root: Node3D = tile_data["root"]
		var old_rocks := root.get_node_or_null("ProceduralReefs")
		if old_rocks != null:
			old_rocks.queue_free()
		var rocks_root := Node3D.new()
		rocks_root.name = "ProceduralReefs"
		root.add_child(rocks_root)
		var rock_count := 0
		if _runtime_rocks_enabled:
			rock_count = ShallowReefGenerator.add_chunk_multimeshes(
				rocks_root,
				_reef_meshes,
				tile_data["bundle"]["rock_records"],
				_reef_material,
				true,
				tile_size_m
			)
		tile_data["rocks"] = rock_count


func _add_chunk_bounds(tile_root: Node3D) -> void:
	if tile_root.get_node_or_null("DebugBounds") != null:
		return
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.76, 0.88, 0.38, 0.85)
	material.no_depth_test = true
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	var x0 := 0.0
	var x1 := tile_size_m
	var z0 := 0.0
	var z1 := tile_size_m
	var y0 := 0.20
	var y1 := -mesh_depth_limit_m
	var corners := [
		Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(x0, y0, z1),
		Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(x0, y1, z1),
	]
	var edges := PackedInt32Array([0, 1, 1, 2, 2, 3, 3, 0, 4, 5, 5, 6, 6, 7, 7, 4, 0, 4, 1, 5, 2, 6, 3, 7])
	for edge_index in range(0, edges.size(), 2):
		mesh.surface_add_vertex(corners[edges[edge_index]])
		mesh.surface_add_vertex(corners[edges[edge_index + 1]])
	mesh.surface_end()
	var bounds := MeshInstance3D.new()
	bounds.name = "DebugBounds"
	bounds.mesh = mesh
	bounds.visible = _runtime_bounds_enabled
	bounds.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	tile_root.add_child(bounds)


func _set_tile_bounds_visible(tile_data: Dictionary, bounds_visible: bool) -> void:
	var root: Node3D = tile_data["root"]
	var bounds := root.get_node_or_null("DebugBounds") as MeshInstance3D
	if bounds_visible and bounds == null:
		_add_chunk_bounds(root)
	elif bounds != null:
		bounds.visible = bounds_visible


func _toggle_water_transparency() -> void:
	if water_material == null:
		return
	var currently_enabled := bool(water_material.get_shader_parameter("shallow_transparency_enabled"))
	water_material.set_shader_parameter("shallow_transparency_enabled", not currently_enabled)
	print("[ShallowSeabed] Shallow water transmission: %s" % ("ON" if not currently_enabled else "OFF"))


func _build_statistics_ui() -> void:
	_stats_layer = CanvasLayer.new()
	_stats_layer.name = "ShallowSeabedDebugLayer"
	_stats_layer.layer = 12
	_stats_layer.visible = show_statistics
	add_child(_stats_layer)
	var panel := PanelContainer.new()
	panel.name = "StatisticsPanel"
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.offset_left = -366.0
	panel.offset_top = 16.0
	panel.offset_right = -16.0
	panel.offset_bottom = 160.0
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.018, 0.065, 0.082, 0.92)
	style.border_color = Color(0.36, 0.68, 0.66, 0.82)
	style.set_border_width_all(1)
	style.set_corner_radius_all(7)
	style.set_content_margin_all(10.0)
	panel.add_theme_stylebox_override("panel", style)
	_stats_layer.add_child(panel)
	_stats_label = Label.new()
	_stats_label.add_theme_color_override("font_color", Color(0.88, 0.94, 0.89))
	_stats_label.add_theme_font_size_override("font_size", 13)
	panel.add_child(_stats_label)


func _update_statistics_text() -> void:
	if _stats_label == null or not _runtime_statistics_enabled:
		return
	var stats := get_debug_stats()
	_stats_label.text = "SHALLOW SEABED · %s\n" % ("ON" if bool(stats["enabled"]) else "OFF")
	_stats_label.text += "Chunks %d active / %d · near %d / far %d\n" % [stats["active_chunks"], stats["loaded_chunks"], stats["near_lod_chunks"], stats["far_lod_chunks"]]
	_stats_label.text += "Triangles loaded %d · rocks %d · queued %d\n" % [stats["loaded_triangles"], stats["rock_instances"], stats["pending_tiles"]]
	_stats_label.text += "Build %.2f ms last · %.2f ms avg\n" % [stats["last_chunk_build_ms"], stats["average_chunk_build_ms"]]
	_stats_label.text += "F6 water transparency · F7 seabed · F8 stats · Shift+F8 bounds\nCtrl+F8 rocks · Alt+F8 LOD colors"


func _create_reef_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.90
	material.metallic = 0.0
	material.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	return material


func _get_boat_tile() -> Vector2i:
	var east := _boat.global_position.x
	var north := -_boat.global_position.z
	return Vector2i(floori(east / tile_size_m), floori(north / tile_size_m))


func _count_lod_chunks(lod: int) -> int:
	var count := 0
	for tile_data in _loaded_tiles.values():
		if int(tile_data.get("lod", -1)) == lod:
			count += 1
	return count


func _depth_text(depth_data: Dictionary) -> String:
	if not bool(depth_data.get("valid", false)):
		return "unknown"
	return "%.2f m LAT" % float(depth_data.get("depth_m", -1.0))


func _value_noise(east: float, north: float, frequency: float, seed: int) -> float:
	var px := east * frequency
	var py := north * frequency
	var ix := floori(px)
	var iy := floori(py)
	var tx := px - float(ix)
	var ty := py - float(iy)
	tx = tx * tx * (3.0 - 2.0 * tx)
	ty = ty * ty * (3.0 - 2.0 * ty)
	var a := _hash01(ix, iy, seed)
	var b := _hash01(ix + 1, iy, seed)
	var c := _hash01(ix, iy + 1, seed)
	var d := _hash01(ix + 1, iy + 1, seed)
	return lerpf(lerpf(a, b, tx), lerpf(c, d, tx), ty)


func _hash01(x: int, y: int, seed: int) -> float:
	var value := sin(float(x) * 127.1 + float(y) * 311.7 + float(seed) * 74.7) * 43758.5453
	return value - floor(value)
