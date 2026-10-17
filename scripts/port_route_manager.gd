class_name PortRouteManager
extends Node3D

@export var georeference: GeoReference
@export var port_definitions: Array[PortDefinition] = []
@export var route_definitions: Array[RouteDefinition] = []
@export var debug_enabled := false

var _ports: Dictionary = {}
var _routes: Dictionary = {}
var _debug_root: Node3D


func _ready() -> void:
	for port in port_definitions:
		if port == null or port.port_id.is_empty():
			continue
		if _ports.has(str(port.port_id)):
			push_error("PortRouteManager: duplicate port ID %s" % port.port_id)
			continue
		_ports[str(port.port_id)] = port
	for route in route_definitions:
		if route == null or route.route_id.is_empty():
			continue
		if _routes.has(str(route.route_id)):
			push_error("PortRouteManager: duplicate route ID %s" % route.route_id)
			continue
		if not _ports.has(str(route.origin_port_id)) or not _ports.has(str(route.destination_port_id)):
			push_error("PortRouteManager: route %s references an unregistered port" % route.route_id)
			continue
		_routes[str(route.route_id)] = route
	_build_debug_visuals()
	set_debug_visible(debug_enabled)


func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_action_pressed("route_debug_toggle") or event.is_echo():
		return
	toggle_debug()
	get_viewport().set_input_as_handled()


func get_port(port_id: String) -> PortDefinition:
	return _ports.get(port_id) as PortDefinition


func get_registered_port_ids() -> PackedStringArray:
	var result := PackedStringArray()
	for key in _ports:
		result.append(str(key))
	result.sort()
	return result


func get_route(route_id: String) -> RouteDefinition:
	return _routes.get(route_id) as RouteDefinition


func get_routes() -> Array[RouteDefinition]:
	var result: Array[RouteDefinition] = []
	for route in _routes.values():
		result.append(route as RouteDefinition)
	return result


func get_route_between(origin_port_id: String, destination_port_id: String) -> RouteDefinition:
	for route in _routes.values():
		var candidate := route as RouteDefinition
		if str(candidate.origin_port_id) == origin_port_id and str(candidate.destination_port_id) == destination_port_id:
			return candidate
	return null


func get_route_summary(route: RouteDefinition, cruise_speed_mps: float) -> Dictionary:
	if route == null or georeference == null:
		return {}
	var distance := route.get_total_distance_m(georeference)
	var time_seconds := route.get_estimated_travel_time_seconds(cruise_speed_mps, georeference)
	return {
		"route_id": str(route.route_id),
		"display_name": route.display_name,
		"origin_port_id": str(route.origin_port_id),
		"destination_port_id": str(route.destination_port_id),
		"distance_m": distance,
		"estimated_seconds": time_seconds,
		"validation_status": route.validation_status,
		"waypoint_count": route.waypoints.size(),
	}


func set_debug_visible(visible: bool) -> void:
	debug_enabled = visible
	if _debug_root != null:
		_debug_root.visible = visible


func toggle_debug() -> void:
	set_debug_visible(not debug_enabled)


func get_debug_summary(cruise_speed_mps: float) -> String:
	var lines := PackedStringArray()
	for route in get_routes():
		var summary := get_route_summary(route, cruise_speed_mps)
		var travel_seconds := float(summary.get("estimated_seconds", -1.0))
		var travel_minutes := int(round(travel_seconds / 60.0)) if travel_seconds >= 0.0 else -1
		var travel_text := "%d:%02d h" % [int(travel_minutes / 60), travel_minutes % 60] if travel_minutes >= 60 else "%d min" % travel_minutes
		lines.append("%s · %d WP · %.2f km · ETA %s @ %.1f m/s · %s" % [
			str(summary.get("route_id", "")),
			int(summary.get("waypoint_count", 0)),
			float(summary.get("distance_m", 0.0)) / 1000.0,
			travel_text,
			cruise_speed_mps,
			str(summary.get("validation_status", "Unknown")),
		])
	return "\n".join(lines)


func _build_debug_visuals() -> void:
	_debug_root = Node3D.new()
	_debug_root.name = "RouteDebugVisuals"
	add_child(_debug_root)
	for route in get_routes():
		var points := route.get_world_points(georeference)
		if points.size() < 2:
			continue
		var line_mesh := ImmediateMesh.new()
		line_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
		for point in points:
			line_mesh.surface_add_vertex(point + Vector3(0.0, 2.0, 0.0))
		line_mesh.surface_end()
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = Color("#f0b75a") if str(route.origin_port_id) == "kobenhavn_test" else Color("#46e5de")
		line_mesh.surface_set_material(0, material)
		var line := MeshInstance3D.new()
		line.name = "Route_%s" % route.route_id
		line.mesh = line_mesh
		_debug_root.add_child(line)
		for index in range(points.size()):
			var marker := MeshInstance3D.new()
			marker.name = "RoutePoint_%s_%02d" % [route.route_id, index]
			var sphere := SphereMesh.new()
			sphere.radius = 3.2 if index == 0 or index == points.size() - 1 else 2.0
			sphere.height = sphere.radius * 2.0
			sphere.material = material
			marker.mesh = sphere
			marker.position = points[index] + Vector3(0.0, 2.5, 0.0)
			_debug_root.add_child(marker)
			var label := Label3D.new()
			label.name = "RouteLabel_%s_%02d" % [route.route_id, index]
			label.text = ("出发" if index == 0 else "到达" if index == points.size() - 1 else "WP %02d" % index)
			label.position = points[index] + Vector3(0.0, 7.0, 0.0)
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			label.font_size = 36
			label.modulate = material.albedo_color
			_debug_root.add_child(label)
