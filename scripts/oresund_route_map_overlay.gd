extends Control

## Screen-space route strokes for the M-key top-down overview map.
## The route geometry remains sourced from RouteDefinition and GeoReference.

const VALIDATED_COLOR := Color(0.22, 0.91, 0.82, 0.98)
const REVIEW_COLOR := Color(1.0, 0.70, 0.31, 0.98)
const DISABLED_COLOR := Color(0.67, 0.74, 0.76, 0.88)
const DASH_LENGTH_PX := 8.0
const DASH_GAP_PX := 5.0
const ROUTE_LABEL_FONT_SIZE := 23
const ROUTE_LABEL_PADDING := Vector2(10.0, 5.0)
const BOAT_LABEL_FONT_SIZE := 22

var _route_manager: PortRouteManager
var _overview_camera: Camera3D
var _georeference: GeoReference
var _player_boat: Node3D


func configure(route_manager: PortRouteManager, overview_camera: Camera3D, georeference: GeoReference, player_boat: Node3D = null) -> void:
	_route_manager = route_manager
	_overview_camera = overview_camera
	_georeference = georeference
	_player_boat = player_boat
	if _route_manager != null and not _route_manager.routes_changed.is_connected(_on_routes_changed):
		_route_manager.routes_changed.connect(_on_routes_changed)
	queue_redraw()


func set_player_boat(player_boat: Node3D) -> void:
	_player_boat = player_boat
	queue_redraw()


func _draw() -> void:
	if _overview_camera == null or _georeference == null:
		return
	if _route_manager != null:
		for route in _route_manager.get_routes():
			if route == null:
				continue
			var world_points := route.get_world_points(_georeference)
			if world_points.size() < 2:
				continue
			var points := PackedVector2Array()
			var invalid_projection := false
			for world_point in world_points:
				if _overview_camera.is_position_behind(world_point):
					invalid_projection = true
					break
				points.append(_overview_camera.unproject_position(world_point))
			if invalid_projection or points.size() < 2:
				continue
			_draw_route(route, points)
	_draw_player_boat()


func _draw_route(route: RouteDefinition, source_points: PackedVector2Array) -> void:
	var color := REVIEW_COLOR
	var is_validated := route.cruise_allowed and route.validation_status == RouteDefinition.STATUS_VALIDATED
	var is_disabled := route.validation_status == RouteDefinition.STATUS_DISABLED
	if is_validated:
		color = VALIDATED_COLOR
	elif is_disabled:
		color = DISABLED_COLOR

	# The two prototype directions share nearly the same geographic corridor. A tiny
	# screen-space offset keeps both symbols readable without changing route data.
	var visual_offset := 3.0 if is_validated else -3.0
	if is_disabled:
		visual_offset = 0.0
	var points := _offset_polyline(source_points, visual_offset)
	for index in range(points.size() - 1):
		var start := points[index]
		var finish := points[index + 1]
		if is_validated:
			draw_line(start, finish, color, 3.5, true)
		else:
			_draw_dashed_line(start, finish, color, 3.0)
		_draw_direction_arrow(start, finish, color)

	draw_circle(points[0], 6.0, color, true, -1.0, true)
	for index in range(1, points.size() - 1):
		draw_circle(points[index], 4.0, color, false, 2.0, true)
	var arrival := points[-1]
	var diamond := PackedVector2Array([
		arrival + Vector2(0.0, -6.0),
		arrival + Vector2(6.0, 0.0),
		arrival + Vector2(0.0, 6.0),
		arrival + Vector2(-6.0, 0.0),
	])
	draw_colored_polygon(diamond, color)
	_draw_route_label(route.display_name, points, color, is_validated)


func _offset_polyline(points: PackedVector2Array, offset_px: float) -> PackedVector2Array:
	if is_zero_approx(offset_px) or points.size() < 2:
		return points
	var result := PackedVector2Array()
	result.resize(points.size())
	for index in range(points.size()):
		var tangent: Vector2
		if index == 0:
			tangent = (points[1] - points[0]).normalized()
		elif index == points.size() - 1:
			tangent = (points[index] - points[index - 1]).normalized()
		else:
			var before := (points[index] - points[index - 1]).normalized()
			var after := (points[index + 1] - points[index]).normalized()
			tangent = (before + after).normalized()
		if tangent.length_squared() < 0.001:
			tangent = (points[mini(index + 1, points.size() - 1)] - points[maxi(index - 1, 0)]).normalized()
		if tangent.x < -0.0001 or (absf(tangent.x) <= 0.0001 and tangent.y < 0.0):
			tangent = -tangent
		var normal := Vector2(-tangent.y, tangent.x)
		result[index] = points[index] + normal * offset_px
	return result


func _draw_dashed_line(start: Vector2, finish: Vector2, color: Color, width: float) -> void:
	var delta := finish - start
	var length := delta.length()
	if length <= 0.001:
		return
	var direction := delta / length
	var distance := 0.0
	while distance < length:
		var dash_end := minf(distance + DASH_LENGTH_PX, length)
		draw_line(start + direction * distance, start + direction * dash_end, color, width, true)
		distance += DASH_LENGTH_PX + DASH_GAP_PX


func _draw_direction_arrow(start: Vector2, finish: Vector2, color: Color) -> void:
	var segment := finish - start
	var length := segment.length()
	if length < 22.0:
		return
	var direction := segment / length
	var side := Vector2(-direction.y, direction.x)
	var center := start.lerp(finish, 0.58)
	var back := center - direction * 7.0
	draw_line(back + side * 5.0, center, color, 2.5, true)
	draw_line(back - side * 5.0, center, color, 2.5, true)


func _draw_route_label(route_name: String, points: PackedVector2Array, color: Color, is_validated: bool) -> void:
	var label_fraction := 0.32 if is_validated else 0.68
	var label_offset := _normal_along_polyline(points, label_fraction) * (24.0 if is_validated else -24.0)
	var label_position := _point_along_polyline(points, label_fraction) + label_offset + Vector2(12.0, -12.0)
	var font := ThemeDB.fallback_font
	if font == null:
		return
	var text_size := font.get_string_size(route_name, HORIZONTAL_ALIGNMENT_LEFT, -1.0, ROUTE_LABEL_FONT_SIZE)
	var label_rect := Rect2(label_position - Vector2(6.0, ROUTE_LABEL_FONT_SIZE + ROUTE_LABEL_PADDING.y), text_size + ROUTE_LABEL_PADDING * 2.0 + Vector2(12.0, 4.0))
	label_rect.position.x = clampf(label_rect.position.x, 8.0, maxf(8.0, size.x - label_rect.size.x - 8.0))
	label_rect.position.y = clampf(label_rect.position.y, 8.0, maxf(8.0, size.y - label_rect.size.y - 8.0))
	draw_rect(label_rect, Color(0.015, 0.055, 0.075, 0.94), true)
	draw_rect(label_rect, Color(color.r, color.g, color.b, 0.95), false, 1.5, true)
	var text_position := label_rect.position + ROUTE_LABEL_PADDING + Vector2(2.0, ROUTE_LABEL_FONT_SIZE)
	draw_string(font, text_position + Vector2(1.0, 1.0), route_name, HORIZONTAL_ALIGNMENT_LEFT, -1.0, ROUTE_LABEL_FONT_SIZE, Color(0.02, 0.06, 0.08, 1.0))
	draw_string(font, text_position, route_name, HORIZONTAL_ALIGNMENT_LEFT, -1.0, ROUTE_LABEL_FONT_SIZE, color)


func _normal_along_polyline(points: PackedVector2Array, fraction: float) -> Vector2:
	var point := _point_along_polyline(points, fraction)
	var closest_segment := 0
	var closest_distance := INF
	for index in range(points.size() - 1):
		var segment := points[index + 1] - points[index]
		var segment_length_squared := segment.length_squared()
		if segment_length_squared <= 0.001:
			continue
		var projection := clampf((point - points[index]).dot(segment) / segment_length_squared, 0.0, 1.0)
		var distance := point.distance_squared_to(points[index] + segment * projection)
		if distance < closest_distance:
			closest_distance = distance
			closest_segment = index
	var tangent := (points[closest_segment + 1] - points[closest_segment]).normalized()
	if tangent.x < -0.0001 or (absf(tangent.x) <= 0.0001 and tangent.y < 0.0):
		tangent = -tangent
	return Vector2(-tangent.y, tangent.x)


func _draw_player_boat() -> void:
	if not is_instance_valid(_player_boat):
		return
	var world_position := _player_boat.global_position
	if _overview_camera.is_position_behind(world_position):
		return
	var screen_position := _overview_camera.unproject_position(world_position)
	if not Rect2(Vector2.ZERO, size).has_point(screen_position):
		return
	var direction_world := -_player_boat.global_basis.z
	direction_world.y = 0.0
	var direction := Vector2.UP
	if direction_world.length_squared() > 0.001:
		var projected_forward := _overview_camera.unproject_position(world_position + direction_world.normalized() * 30.0)
		var projected_direction := projected_forward - screen_position
		if projected_direction.length_squared() > 0.001:
			direction = projected_direction.normalized()
	var side := Vector2(-direction.y, direction.x)
	var boat_color := Color("#ffb84d")
	draw_circle(screen_position, 22.0, Color(1.0, 0.62, 0.23, 0.2), true, -1.0, true)
	draw_arc(screen_position, 22.0, 0.0, TAU, 36, Color(1.0, 0.72, 0.37, 0.95), 2.0, true)
	var hull := PackedVector2Array([
		screen_position + direction * 18.0,
		screen_position - direction * 11.0 + side * 8.0,
		screen_position - direction * 7.0,
		screen_position - direction * 11.0 - side * 8.0,
	])
	draw_colored_polygon(hull, boat_color)
	draw_polyline(PackedVector2Array([hull[0], hull[1], hull[2], hull[3], hull[0]]), Color("#172b32"), 2.0, true)
	var label_text := "本船"
	var font := ThemeDB.fallback_font
	if font == null:
		return
	var text_size := font.get_string_size(label_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, BOAT_LABEL_FONT_SIZE)
	var label_rect := Rect2(screen_position + Vector2(25.0, -27.0), text_size + Vector2(28.0, 14.0))
	label_rect.position.x = clampf(label_rect.position.x, 8.0, maxf(8.0, size.x - label_rect.size.x - 8.0))
	label_rect.position.y = clampf(label_rect.position.y, 8.0, maxf(8.0, size.y - label_rect.size.y - 8.0))
	draw_rect(label_rect, Color(0.015, 0.055, 0.075, 0.97), true)
	draw_rect(label_rect, boat_color, false, 2.0, true)
	var text_position := label_rect.position + Vector2(14.0, BOAT_LABEL_FONT_SIZE + 7.0)
	draw_string(font, text_position + Vector2(1.0, 1.0), label_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, BOAT_LABEL_FONT_SIZE, Color("#0b171a"))
	draw_string(font, text_position, label_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, BOAT_LABEL_FONT_SIZE, Color("#ffe2b5"))


func _point_along_polyline(points: PackedVector2Array, fraction: float) -> Vector2:
	var total_length := 0.0
	for index in range(points.size() - 1):
		total_length += points[index].distance_to(points[index + 1])
	if total_length <= 0.001:
		return points[0]
	var target_distance := total_length * clampf(fraction, 0.0, 1.0)
	for index in range(points.size() - 1):
		var segment_length := points[index].distance_to(points[index + 1])
		if target_distance <= segment_length:
			return points[index].lerp(points[index + 1], target_distance / maxf(segment_length, 0.001))
		target_distance -= segment_length
	return points[-1]


func _on_routes_changed() -> void:
	queue_redraw()
