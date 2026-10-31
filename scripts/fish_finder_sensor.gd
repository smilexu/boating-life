class_name FishFinderSensor
extends Node

## Lightweight downward-looking echo sampler over the shared fish authority.
## Echoes intentionally omit species identity and never create visual fish.

signal scan_completed(result: Dictionary)

@export_category("Sonar")
@export_range(10.0, 1000.0, 5.0) var max_slant_range_m := 220.0
@export_range(5.0, 120.0, 1.0) var beam_angle_deg := 42.0
@export_range(1.0, 100.0, 1.0) var maximum_water_depth_m := 45.0
@export_range(0.25, 30.0, 0.25) var scan_interval_game_seconds := 2.0
@export_range(1, 64, 1) var history_capacity := 12
@export var transducer_offset_local_m := Vector3(0.0, -0.55, 0.0)
@export_range(-500.0, 500.0, 0.1) var chart_datum_world_y_m := 0.0
@export_range(0.0, 5.0, 0.1) var seabed_clearance_m := 0.6

var _manager: Node
var _boat: Node3D
var _bathymetry: Node
var _wave_sampler: Node
var _history: Array[Dictionary] = []
var _last_scan_game_time_seconds := -INF
var _scan_sequence := 0


func configure(manager: Node, boat: Node3D, bathymetry: Node, wave_sampler: Node) -> void:
	_manager = manager
	_boat = boat
	_bathymetry = bathymetry
	_wave_sampler = wave_sampler


func scan(force: bool = false) -> Dictionary:
	if _manager != null and _manager.has_method("get_boat"):
		_boat = _manager.call("get_boat") as Node3D
	var now := _game_time_seconds()
	if not force and now - _last_scan_game_time_seconds < scan_interval_game_seconds:
		return {"accepted": false, "reason": "scan_interval", "last_scan": get_last_scan()}
	_last_scan_game_time_seconds = now
	_scan_sequence += 1
	var result := {
		"accepted": false,
		"scan_id": _scan_sequence,
		"scan_game_time_seconds": now,
		"echoes": [],
		"reason": "dependencies_unavailable",
	}
	if _manager == null or _boat == null or _bathymetry == null or _wave_sampler == null:
		_record_scan(result)
		return result

	var probe_world_position: Vector3 = _boat.global_transform * transducer_offset_local_m
	var probe_xz := Vector3(probe_world_position.x, 0.0, probe_world_position.z)
	var bathymetry: Dictionary = _bathymetry.call("get_depth_at_world_position", probe_xz)
	if not bool(bathymetry.get("valid", false)):
		result["probe_world_position"] = probe_world_position
		result["reason"] = str(bathymetry.get("reason", "bathymetry_unavailable"))
		_record_scan(result)
		return result

	var wave_time := float(_wave_sampler.get("wave_time_seconds"))
	var surface: Dictionary = _wave_sampler.call("sample_physics_surface", probe_xz, wave_time)
	var surface_y := float(surface.get("height", chart_datum_world_y_m))
	var chart_depth := float(bathymetry.get("depth_m", 0.0))
	var water_column := maxf(0.0, chart_depth + surface_y - chart_datum_world_y_m)
	var schools: Array[Dictionary] = _manager.call("get_schools_near", probe_world_position, max_slant_range_m)
	var echoes: Array[Dictionary] = []
	var school_count := 0
	for school in schools:
		school_count += 1
		var anchor := _school_position(school)
		var school_bathymetry: Dictionary = _bathymetry.call("get_depth_at_world_position", Vector3(anchor.x, 0.0, anchor.z))
		if not bool(school_bathymetry.get("valid", false)):
			continue
		var school_surface := _sample_surface_y(anchor)
		var activity_depth := maxf(0.0, float(school.get("activity_depth_m", 0.0)))
		var school_water_column := maxf(0.0, float(school_bathymetry.get("depth_m", 0.0)) + school_surface - chart_datum_world_y_m)
		if activity_depth > maximum_water_depth_m or activity_depth > school_water_column - seabed_clearance_m:
			continue
		var fish_world_position := Vector3(anchor.x, school_surface - activity_depth, anchor.z)
		var relative := fish_world_position - probe_world_position
		var vertical_depth := probe_world_position.y - fish_world_position.y
		if vertical_depth <= 0.0:
			continue
		var horizontal_distance := Vector2(relative.x, relative.z).length()
		var slant_range := relative.length()
		if slant_range > max_slant_range_m or not is_within_beam(horizontal_distance, vertical_depth, beam_angle_deg, max_slant_range_m):
			continue
		var population := maxi(0, int(school.get("population", 0)))
		if population <= 0:
			continue
		var range_factor := 1.0 - clampf(slant_range / max_slant_range_m, 0.0, 1.0)
		var echo := {
			"echo_id": "echo_%d_%d" % [_scan_sequence, echoes.size()],
			"relative_position_m": relative,
			"depth_below_surface_m": activity_depth,
			"slant_range_m": slant_range,
			"horizontal_offset_m": horizontal_distance,
			"activity_state": str(school.get("surface_activity_state", "unknown")),
			"echo_strength": clampf(sqrt(float(population)) / 8.0 * (0.25 + range_factor * 0.75), 0.05, 1.0),
			"estimated_group_size_band": _population_band(population),
		}
		echoes.append(echo)
	result.merge({
		"accepted": true,
		"reason": "ok",
		"probe_world_position": probe_world_position,
		"chart_depth_lat_m": chart_depth,
		"surface_height_world_y_m": surface_y,
		"water_column_below_surface_m": water_column,
		"schools_in_query_radius": school_count,
		"echoes": echoes,
	}, true)
	_record_scan(result)
	scan_completed.emit(result.duplicate(true))
	return result


func get_scan_history() -> Array[Dictionary]:
	return _history.duplicate(true)


func get_last_scan() -> Dictionary:
	return _history.back().duplicate(true) if not _history.is_empty() else {}


static func is_within_beam(horizontal_distance_m: float, vertical_depth_m: float, full_beam_angle_deg: float, max_range_m: float) -> bool:
	if horizontal_distance_m < 0.0 or vertical_depth_m <= 0.0 or max_range_m <= 0.0:
		return false
	var radius := vertical_depth_m * tan(deg_to_rad(clampf(full_beam_angle_deg, 1.0, 179.0) * 0.5))
	var slant_range := sqrt(horizontal_distance_m * horizontal_distance_m + vertical_depth_m * vertical_depth_m)
	return horizontal_distance_m <= radius and slant_range <= max_range_m


func _sample_surface_y(position: Vector3) -> float:
	var query := Vector3(position.x, 0.0, position.z)
	var sample: Dictionary = _wave_sampler.call("sample_physics_surface", query, float(_wave_sampler.get("wave_time_seconds")))
	return float(sample.get("height", chart_datum_world_y_m))


func _game_time_seconds() -> float:
	return maxf(0.0, float(_manager.call("get_world_game_time_seconds"))) if _manager != null and _manager.has_method("get_world_game_time_seconds") else 0.0


func _school_position(school: Dictionary) -> Vector3:
	var value: Variant = school.get("world_position", [])
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return Vector3.ZERO


func _population_band(population: int) -> String:
	if population <= 3:
		return "small"
	if population <= 10:
		return "medium"
	return "large"


func _record_scan(result: Dictionary) -> void:
	_history.append(result.duplicate(true))
	while _history.size() > maxi(1, history_capacity):
		_history.pop_front()
