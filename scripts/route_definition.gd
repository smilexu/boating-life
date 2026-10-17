class_name RouteDefinition
extends Resource

## Preset route points are WGS84 coordinates; runtime distances are computed
## from GeoReference world positions so serialized data has no stale distance.

const STATUS_DRAFT := "DRAFT"
const STATUS_NEEDS_REVIEW := "NEEDS_REVIEW"
const STATUS_VALIDATED := "VALIDATED_FOR_GAMEPLAY"
const STATUS_DISABLED := "DISABLED"

@export var route_id: StringName = &""
@export var display_name := ""
@export var origin_port_id: StringName = &""
@export var destination_port_id: StringName = &""
@export var departure_point_id: StringName = &""
@export var departure_display_name := "出港等待点"
@export_range(-90.0, 90.0, 0.000001) var departure_latitude_deg := 0.0
@export_range(-180.0, 180.0, 0.000001) var departure_longitude_deg := 0.0
@export var arrival_point_id: StringName = &""
@export var arrival_display_name := "进港等待点"
@export_range(-90.0, 90.0, 0.000001) var arrival_latitude_deg := 0.0
@export_range(-180.0, 180.0, 0.000001) var arrival_longitude_deg := 0.0
@export_range(10.0, 2000.0, 1.0) var arrival_radius_m := 180.0
@export var waypoints: Array[RouteWaypoint] = []
@export var cruise_allowed := false
@export var validation_status := STATUS_DRAFT
@export_range(1, 1000000, 1) var updated_version := 1
@export_multiline var data_source := ""


func get_world_points(georeference: GeoReference) -> Array[Vector3]:
	var points: Array[Vector3] = []
	if georeference == null:
		return points
	points.append(_flat_geodetic_position(georeference, departure_latitude_deg, departure_longitude_deg))
	for waypoint in waypoints:
		if waypoint != null:
			points.append(_flat_geodetic_position(georeference, waypoint.latitude_deg, waypoint.longitude_deg))
	points.append(_flat_geodetic_position(georeference, arrival_latitude_deg, arrival_longitude_deg))
	return points


static func _flat_geodetic_position(georeference: GeoReference, latitude_deg: float, longitude_deg: float) -> Vector3:
	var position := georeference.geodetic_to_world(latitude_deg, longitude_deg)
	# Route anchors use the same calm-water reference plane as harbor anchors.
	position.y = 0.0
	return position


func get_segment_lengths_m(georeference: GeoReference) -> PackedFloat32Array:
	var points := get_world_points(georeference)
	var lengths := PackedFloat32Array()
	for index in range(points.size() - 1):
		lengths.append(_flat_distance(points[index], points[index + 1]))
	return lengths


func get_total_distance_m(georeference: GeoReference) -> float:
	var total := 0.0
	for segment_length in get_segment_lengths_m(georeference):
		total += segment_length
	return total


func find_nearest_projection(world_position: Vector3, georeference: GeoReference, first_segment: int = 0, last_segment: int = -1) -> Dictionary:
	var points := get_world_points(georeference)
	if points.size() < 2:
		return {}
	var segment_count := points.size() - 1
	var first := clampi(first_segment, 0, segment_count - 1)
	var last := segment_count - 1 if last_segment < 0 else clampi(last_segment, first, segment_count - 1)
	var nearest := {
		"distance_m": INF,
		"route_progress_m": 0.0,
		"segment_index": first,
		"segment_t": 0.0,
		"position": points[first],
		"tangent": Vector2.ZERO,
	}
	var route_distance_before := 0.0
	for segment_index in range(segment_count):
		var start := points[segment_index]
		var finish := points[segment_index + 1]
		var segment := Vector2(finish.x - start.x, finish.z - start.z)
		var length_squared := segment.length_squared()
		var length := sqrt(length_squared)
		if segment_index >= first and segment_index <= last and length_squared > 0.0001:
			var offset := Vector2(world_position.x - start.x, world_position.z - start.z)
			var t := clampf(offset.dot(segment) / length_squared, 0.0, 1.0)
			var projected := start.lerp(finish, t)
			var distance := Vector2(world_position.x - projected.x, world_position.z - projected.z).length()
			if distance < float(nearest["distance_m"]):
				nearest = {
					"distance_m": distance,
					"route_progress_m": route_distance_before + length * t,
					"segment_index": segment_index,
					"segment_t": t,
					"position": projected,
					"tangent": segment / length,
				}
		route_distance_before += length
	return nearest


func get_point_at_distance(distance_m: float, georeference: GeoReference) -> Dictionary:
	var points := get_world_points(georeference)
	if points.size() < 2:
		return {}
	var remaining := clampf(distance_m, 0.0, get_total_distance_m(georeference))
	for index in range(points.size() - 1):
		var start := points[index]
		var finish := points[index + 1]
		var delta := Vector2(finish.x - start.x, finish.z - start.z)
		var length := delta.length()
		if length <= 0.0001:
			continue
		if remaining <= length or index == points.size() - 2:
			var t := clampf(remaining / length, 0.0, 1.0)
			return {
				"position": start.lerp(finish, t),
				"tangent": delta / length,
				"segment_index": index,
			}
		remaining -= length
	return {"position": points[-1], "tangent": Vector2.ZERO, "segment_index": points.size() - 2}


func get_remaining_distance_m(world_position: Vector3, georeference: GeoReference, minimum_progress_m: float = 0.0, first_segment: int = 0) -> float:
	var projection := find_nearest_projection(world_position, georeference, first_segment)
	if projection.is_empty():
		return 0.0
	var progress := maxf(float(projection["route_progress_m"]), minimum_progress_m)
	return maxf(get_total_distance_m(georeference) - progress, 0.0)


func get_estimated_travel_time_seconds(cruise_speed_mps: float, georeference: GeoReference) -> float:
	if not is_finite(cruise_speed_mps) or cruise_speed_mps <= 0.0:
		return -1.0
	return get_total_distance_m(georeference) / cruise_speed_mps


func invalidate_for_edit() -> void:
	updated_version += 1
	cruise_allowed = false
	validation_status = STATUS_NEEDS_REVIEW


static func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(b.x - a.x, b.z - a.z).length()
