class_name NavigationDepthProvider
extends Node

## Game-logic depth queries. EMODnet is deliberately marked non-navigation-grade.

const STATUS_SAFE := "Safe"
const STATUS_CAUTION := "Caution"
const STATUS_UNSAFE := "Unsafe"
const STATUS_UNKNOWN := "Unknown"

@export_node_path("Node") var bathymetry_manager_path := NodePath("../BathymetryManager")
@export var georeference: GeoReference
@export_range(0.0, 5.0, 0.05) var safety_margin_m := 0.5
## Game surface height above LAT. Zero maps the prototype's calm Y=0 plane to LAT;
## this is an explicit game convention, not a real tide correction.
@export_range(-5.0, 5.0, 0.05) var game_surface_above_lat_m := 0.0

var _bathymetry: BathymetryManager
var _overrides: Array[Dictionary] = []


func _ready() -> void:
	_bathymetry = get_node_or_null(bathymetry_manager_path) as BathymetryManager
	if georeference == null and _bathymetry != null:
		georeference = _bathymetry.georeference


func query_world_position(world_position: Vector3) -> Dictionary:
	var east_north := Vector2(world_position.x, -world_position.z)
	var override := _find_override(east_north)
	if not override.is_empty():
		return {
			"valid": true,
			"data_state": "water",
			"depth_m": maxf(float(override["depth_m"]), 0.0),
			"seabed_elevation_m": -maxf(float(override["depth_m"]), 0.0),
			"vertical_datum": str(override["vertical_datum"]),
			"source": str(override["source"]),
			"quality": str(override["quality"]),
			"navigation_grade": false,
			"override_id": str(override["area_id"]),
			"reason": "Local gameplay-only depth polygon",
		}
	if _bathymetry == null:
		return _unknown_result("BathymetryManager is unavailable", "no_data")
	# Conservative hole fills are exposed only to navigation queries. They stay
	# explicitly marked and can never qualify as a fully Safe depth sample.
	var sample := _bathymetry.get_depth_at_world_position(world_position, true)
	if not bool(sample.get("valid", false)):
		var land := _bathymetry.is_land_at_east_north(east_north.x, east_north.y)
		var reason := str(sample.get("reason", "No bathymetry data"))
		return _unknown_result(reason, "land" if land else _classify_missing_reason(reason))

	var depth_lat := maxf(float(sample.get("depth_m", 0.0)), 0.0)
	var effective_depth := maxf(depth_lat + game_surface_above_lat_m, 0.0)
	var metadata := _bathymetry.get_source_metadata_at(georeference.world_to_geodetic(world_position).x)
	return {
		"valid": true,
		"data_state": "water",
		"depth_m": effective_depth,
		"seabed_elevation_m": -depth_lat,
		"raw_depth_m": depth_lat,
		"vertical_datum": "LAT",
		"game_surface_above_lat_m": game_surface_above_lat_m,
		"source": str(sample.get("source", "EMODnet DTM 2024")),
		"quality": _quality_for_sample(sample),
		"resolution_east_m": float(metadata.get("resolution_east_m", 0.0)),
		"resolution_north_m": float(metadata.get("resolution_north_m", 0.0)),
		"interpolated": bool(sample.get("interpolated", false)),
		"estimated": bool(sample.get("estimated", false)),
		"estimate_confidence": str(sample.get("estimate_confidence", "")),
		"value_count": float(sample.get("value_count", -1.0)),
		"navigation_grade": false,
		"reason": str(sample.get("reason", "Coarse chart-reference depth; not for navigation or safety")),
	}


func evaluate_world_position(world_position: Vector3, draft_m: float, margin_m: float = -1.0) -> Dictionary:
	var margin := safety_margin_m if margin_m < 0.0 else maxf(margin_m, 0.0)
	return evaluate_depth_sample(query_world_position(world_position), draft_m, margin)


static func evaluate_depth_sample(sample: Dictionary, draft_m: float, margin_m: float) -> Dictionary:
	var result := sample.duplicate(true)
	var draft := maxf(draft_m, 0.0)
	var margin := maxf(margin_m, 0.0)
	result["draft_m"] = draft
	result["safety_margin_m"] = margin
	result["required_depth_m"] = draft + margin
	if not bool(sample.get("valid", false)):
		result["status"] = STATUS_UNKNOWN
		return result
	var depth := maxf(float(sample.get("depth_m", 0.0)), 0.0)
	result["depth_m"] = depth
	if depth + 0.0001 < draft:
		result["status"] = STATUS_UNSAFE
	elif bool(sample.get("estimated", false)):
		result["status"] = STATUS_CAUTION
		result["reason"] = "Estimated water depth is gameplay-only; this location cannot be confirmed Safe"
	elif depth + 0.0001 < draft + margin:
		result["status"] = STATUS_CAUTION
	else:
		result["status"] = STATUS_SAFE
	return result


static func worse_status(a: String, b: String) -> String:
	var rank := {
		STATUS_SAFE: 0,
		STATUS_CAUTION: 1,
		STATUS_UNKNOWN: 2,
		STATUS_UNSAFE: 3,
	}
	return a if int(rank.get(a, 2)) >= int(rank.get(b, 2)) else b


func register_polygon_override(
	area_id: String,
	anchor_world: Vector3,
	polygon_east_north_offsets_m: PackedVector2Array,
	depth_m: float,
	priority: int,
	vertical_datum: String = "GAME_SURFACE_REFERENCE",
	source: String = "Gameplay-configured depth (unverified)"
) -> bool:
	if area_id.is_empty() or polygon_east_north_offsets_m.size() < 3 or depth_m < 0.0:
		return false
	remove_depth_override(area_id)
	_overrides.append({
		"area_id": area_id,
		"anchor_east_north": Vector2(anchor_world.x, -anchor_world.z),
		"polygon": polygon_east_north_offsets_m,
		"depth_m": depth_m,
		"priority": priority,
		"vertical_datum": vertical_datum,
		"source": source,
		"quality": "Game-design value; not surveyed",
	})
	return true


func remove_depth_override(area_id: String) -> void:
	for index in range(_overrides.size() - 1, -1, -1):
		if str(_overrides[index].get("area_id", "")) == area_id:
			_overrides.remove_at(index)


func get_registered_overrides() -> Array[Dictionary]:
	return _overrides.duplicate(true)


func get_status_name(status: String) -> String:
	match status:
		STATUS_SAFE:
			return "安全余量满足"
		STATUS_CAUTION:
			return "余量不足"
		STATUS_UNSAFE:
			return "水深小于吃水"
		_:
			return "水深未知/非水域"


func get_data_metadata(world_position: Vector3) -> Dictionary:
	var query := query_world_position(world_position)
	return {
		"source": query.get("source", ""),
		"quality": query.get("quality", "Unknown"),
		"vertical_datum": query.get("vertical_datum", "Unknown"),
		"data_state": query.get("data_state", "no_data"),
		"resolution_east_m": query.get("resolution_east_m", 0.0),
		"resolution_north_m": query.get("resolution_north_m", 0.0),
		"navigation_grade": query.get("navigation_grade", false),
		"reason": query.get("reason", ""),
	}


func _find_override(point_east_north: Vector2) -> Dictionary:
	var best: Dictionary = {}
	for area in _overrides:
		var anchor: Vector2 = area["anchor_east_north"]
		var local_point := point_east_north - anchor
		if not _point_in_polygon(local_point, area["polygon"]):
			continue
		if best.is_empty() or int(area["priority"]) > int(best["priority"]):
			best = area
	return best


func _point_in_polygon(point: Vector2, polygon: PackedVector2Array) -> bool:
	var inside := false
	var previous := polygon.size() - 1
	for current in range(polygon.size()):
		var a := polygon[current]
		var b := polygon[previous]
		var crosses := (a.y > point.y) != (b.y > point.y)
		if crosses:
			var crossing_x := (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
			if point.x < crossing_x:
				inside = not inside
		previous = current
	return inside


func _quality_for_sample(sample: Dictionary) -> String:
	if bool(sample.get("estimated", false)):
		return str(sample.get("quality_label", "Conservative estimated water depth; not navigation-grade"))
	if bool(sample.get("interpolated", false)):
		return "Coarse/interpolated DTM reference; not navigation-grade"
	var count := float(sample.get("quality", -1.0))
	if count >= 0.0 and count < 2.0:
		return "Sparse DTM support; not navigation-grade"
	return "Coarse DTM reference; not navigation-grade"


func _classify_missing_reason(reason: String) -> String:
	if reason.contains("Outside"):
		return "outside_coverage"
	# Exact land classification comes from the separate OSM land mask above.
	# A failed DTM interpolation neighbourhood can straddle land while the query
	# point itself is water, so that case must remain no_data, not be mislabeled.
	return "no_data"


func _unknown_result(reason: String, data_state: String) -> Dictionary:
	return {
		"valid": false,
		"data_state": data_state,
		"depth_m": 0.0,
		"seabed_elevation_m": 0.0,
		"vertical_datum": "Unknown",
		"source": "No valid depth source",
		"quality": "Unknown",
		"navigation_grade": false,
		"reason": reason,
	}
