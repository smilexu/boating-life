class_name RouteDefinition
extends Resource

## Preset route points are WGS84 coordinates; runtime distances are computed
## from GeoReference world positions so serialized data has no stale distance.

@export var route_id: StringName = &""
@export var display_name := ""
@export var origin_port_id: StringName = &""
@export var destination_port_id: StringName = &""
@export var departure_point_id: StringName = &""
@export_range(-90.0, 90.0, 0.000001) var departure_latitude_deg := 0.0
@export_range(-180.0, 180.0, 0.000001) var departure_longitude_deg := 0.0
@export var arrival_point_id: StringName = &""
@export_range(-90.0, 90.0, 0.000001) var arrival_latitude_deg := 0.0
@export_range(-180.0, 180.0, 0.000001) var arrival_longitude_deg := 0.0
@export var waypoints: Array[RouteWaypoint] = []
@export var validation_status := "unverified_gameplay_route"
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
	# Port anchors and the calm-water reference use a flat game Y=0 plane.
	position.y = 0.0
	return position


func get_total_distance_m(georeference: GeoReference) -> float:
	var points := get_world_points(georeference)
	var distance := 0.0
	for index in range(points.size() - 1):
		distance += _flat_distance(points[index], points[index + 1])
	return distance


func get_remaining_distance_m(world_position: Vector3, georeference: GeoReference) -> float:
	var points := get_world_points(georeference)
	if points.size() < 2:
		return 0.0
	var best_distance_squared := INF
	var remaining := 0.0
	var distance_after_segment := 0.0
	for index in range(points.size() - 2, -1, -1):
		var start := points[index]
		var finish := points[index + 1]
		var segment := Vector2(finish.x - start.x, finish.z - start.z)
		var segment_length_squared := segment.length_squared()
		var t := 0.0
		if segment_length_squared > 0.0001:
			t = clampf(Vector2(world_position.x - start.x, world_position.z - start.z).dot(segment) / segment_length_squared, 0.0, 1.0)
		var projection := start.lerp(finish, t)
		var distance_squared := Vector2(world_position.x - projection.x, world_position.z - projection.z).length_squared()
		if distance_squared < best_distance_squared:
			best_distance_squared = distance_squared
			remaining = _flat_distance(projection, finish) + distance_after_segment
		distance_after_segment += _flat_distance(start, finish)
	return remaining


func get_estimated_travel_time_seconds(cruise_speed_mps: float, georeference: GeoReference) -> float:
	if not is_finite(cruise_speed_mps) or cruise_speed_mps <= 0.0:
		return -1.0
	return get_total_distance_m(georeference) / cruise_speed_mps


static func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(b.x - a.x, b.z - a.z).length()
