class_name DepthChartView
extends Control

## North-up chart display. The boat stays at the chart centre; only its heading
## marker rotates. The low-resolution chart raster is rebuilt after the boat
## moves 45 m, not every frame.

const CHART_HEIGHT_RANGE_M := 1800.0
const RASTER_WIDTH := 128
const RASTER_HEIGHT := 92
const UNKNOWN_COLOR := Color("#263740")
const LAND_COLOR := Color("#aaa18d")

var _manager: BathymetryManager
var _boat: Node3D
var _chart_texture: ImageTexture
var _chart_center_east_north := Vector2(INF, INF)
var _boat_direction_screen := Vector2.UP
var _refresh_elapsed := 0.0
var _m_per_pixel := 1.0
var _map_rect := Rect2()
var _raster_image := Image.create(RASTER_WIDTH, RASTER_HEIGHT, false, Image.FORMAT_RGBA8)


func configure(manager: BathymetryManager, boat: Node3D) -> void:
	_manager = manager
	_boat = boat


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Coastline/contour polylines can start far outside the small chart viewport.
	# Clip their draw commands so the chart never paints over the 3D view or HUD.
	clip_contents = true
	custom_minimum_size = Vector2(324.0, 260.0)


func _process(delta: float) -> void:
	_refresh_elapsed += delta
	if _manager == null or _boat == null or _refresh_elapsed < 0.25:
		return
	_refresh_elapsed = fmod(_refresh_elapsed, 0.25)
	var world_position := _boat.global_position
	var calm_position := Vector3(world_position.x, 0.0, world_position.z)
	var east_north := Vector2(calm_position.x, -calm_position.z)
	var forward := -_boat.global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() > 0.0001:
		_boat_direction_screen = Vector2(forward.x, forward.z).normalized()
	if _chart_texture == null or east_north.distance_to(_chart_center_east_north) >= 45.0:
		_rebuild_chart(east_north)
	queue_redraw()


func _draw() -> void:
	_map_rect = Rect2(Vector2(8.0, 7.0), Vector2(size.x - 16.0, size.y - 43.0))
	if _map_rect.size.x <= 0.0 or _map_rect.size.y <= 0.0:
		return
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.025, 0.085, 0.11, 1.0), true)
	draw_rect(_map_rect, UNKNOWN_COLOR, true)
	if _chart_texture != null:
		draw_texture_rect(_chart_texture, _map_rect, false)
	else:
		_draw_unknown_hatch(_map_rect)
	if not is_finite(_chart_center_east_north.x) or not is_finite(_chart_center_east_north.y):
		draw_rect(_map_rect, Color(0.70, 0.86, 0.84, 0.72), false, 1.0)
		return
	_m_per_pixel = CHART_HEIGHT_RANGE_M / _map_rect.size.y
	_draw_distance_rings()
	_draw_coastlines()
	_draw_contours()
	_draw_boat_marker()
	_draw_compass_and_scale()
	draw_rect(_map_rect, Color(0.70, 0.86, 0.84, 0.72), false, 1.0)


func _rebuild_chart(center: Vector2) -> void:
	if _manager == null or _manager.georeference == null or size.x <= 0.0 or size.y <= 0.0:
		return
	var map_width := maxf(1.0, size.x - 16.0)
	var map_height := maxf(1.0, size.y - 43.0)
	var metres_per_pixel := CHART_HEIGHT_RANGE_M / map_height
	var world_width := map_width * metres_per_pixel
	var world_height := CHART_HEIGHT_RANGE_M
	var boat_geo := _manager.georeference.world_to_geodetic(Vector3(center.x, 0.0, -center.y))
	var row: int
	for y in range(RASTER_HEIGHT):
		var north := center.y + (0.5 - (float(y) + 0.5) / float(RASTER_HEIGHT)) * world_height
		for x in range(RASTER_WIDTH):
			var east := center.x + ((float(x) + 0.5) / float(RASTER_WIDTH) - 0.5) * world_width
			var color: Color
			if _manager.is_land_at_east_north(east, north):
				color = LAND_COLOR
			elif not _manager.data_available:
				color = _unknown_pixel(x, y)
			else:
				var world_geo := _manager.georeference.world_to_geodetic(Vector3(east, 0.0, -north))
				var sample := _manager.get_depth_at_geodetic(world_geo.x, world_geo.y, false, true)
				color = _depth_color(sample, x, y)
			_raster_image.set_pixel(x, y, color)
		_chart_texture = ImageTexture.create_from_image(_raster_image)
		_chart_center_east_north = center
		queue_redraw()


func _depth_color(sample: Dictionary, x: int, y: int) -> Color:
	if not bool(sample.get("valid", false)):
		return _unknown_pixel(x, y)
	var depth := float(sample.get("depth_m", 0.0))
	var color := Color("#83c7b7")
	if depth >= 20.0:
		color = Color("#17445c")
	elif depth >= 10.0:
		color = Color("#205d72")
	elif depth >= 5.0:
		color = Color("#317e8c")
	elif depth >= 2.0:
		color = Color("#4e9f9e")
	if bool(sample.get("estimated", false)):
		color = color.lerp(Color("#d6a85e"), 0.48)
	elif bool(sample.get("interpolated", false)):
		color = color.lerp(Color("#9abbb7"), 0.08)
	return color


func _unknown_pixel(x: int, y: int) -> Color:
	var shade := 0.035 if posmod(x + y * 2, 11) < 2 else 0.0
	return UNKNOWN_COLOR.lightened(shade)


func _draw_unknown_hatch(rect: Rect2) -> void:
	for diagonal in range(-int(rect.size.y), int(rect.size.x), 14):
		var start := Vector2(maxf(0.0, float(diagonal)), maxf(0.0, -float(diagonal))) + rect.position
		var finish := Vector2(minf(rect.size.x, float(diagonal) + rect.size.y), minf(rect.size.y, rect.size.y + float(diagonal))) + rect.position
		if start.x <= rect.end.x and finish.y >= rect.position.y:
			draw_line(start, finish, Color(0.55, 0.64, 0.64, 0.10), 1.0)


func _draw_distance_rings() -> void:
	var center := _map_rect.get_center()
	for radius_m in [250.0, 500.0]:
		draw_arc(center, radius_m / _m_per_pixel, 0.0, TAU, 48, Color(0.79, 0.9, 0.86, 0.25), 1.0, true)


func _draw_coastlines() -> void:
	if _manager == null:
		return
	var chart_bounds := _world_chart_bounds().grow(30.0)
	for index in range(_manager.coastlines.size()):
		if index < _manager.coastline_bounds.size() and not chart_bounds.intersects(_manager.coastline_bounds[index]):
			continue
		var line := _manager.coastlines[index]
		var screen_line := PackedVector2Array()
		for point in line:
			screen_line.append(_world_to_chart(point))
		if screen_line.size() >= 2:
			draw_polyline(screen_line, Color(0.88, 0.83, 0.70, 0.95), 1.35, true)


func _draw_contours() -> void:
	if _manager == null:
		return
	var chart_bounds := _world_chart_bounds().grow(30.0)
	for level_string in _manager.get_contour_levels():
		var level := float(level_string)
		var color := Color(0.78, 0.94, 0.88, 0.8)
		if level >= 20.0:
			color = Color(0.66, 0.85, 0.94, 0.72)
		elif level >= 10.0:
			color = Color(0.69, 0.91, 0.91, 0.76)
		elif level >= 5.0:
			color = Color(0.75, 0.96, 0.90, 0.82)
		var lines: Array = _manager.contours_by_depth.get(level_string, [])
		var line_bounds: Array = _manager.contour_bounds_by_depth.get(level_string, [])
		var labeled := false
		for index in range(lines.size()):
			if index < line_bounds.size() and not chart_bounds.intersects(line_bounds[index]):
				continue
			var line: PackedVector2Array = lines[index]
			var screen_line := PackedVector2Array()
			for point in line:
				screen_line.append(_world_to_chart(point))
			if screen_line.size() >= 2:
				draw_polyline(screen_line, color, 1.0, true)
				if not labeled and screen_line.size() > 5:
					var midpoint := screen_line[screen_line.size() / 2]
					if _map_rect.has_point(midpoint):
						draw_string(get_theme_default_font(), midpoint + Vector2(3.0, -3.0), "%dm" % roundi(level), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 10, color)
						labeled = true


func _draw_boat_marker() -> void:
	var center := _map_rect.get_center()
	var direction := _boat_direction_screen.normalized()
	if direction.length_squared() < 0.1:
		direction = Vector2.UP
	var side := Vector2(-direction.y, direction.x)
	var triangle := PackedVector2Array([
		center + direction * 11.0,
		center - direction * 7.0 + side * 6.0,
		center - direction * 7.0 - side * 6.0,
	])
	draw_colored_polygon(triangle, Color("#ffd07a"))
	draw_polyline(PackedVector2Array([triangle[0], triangle[1], triangle[2], triangle[0]]), Color("#17343c"), 1.4, true)


func _draw_compass_and_scale() -> void:
	var font := get_theme_default_font()
	var north_position := Vector2(_map_rect.end.x - 20.0, _map_rect.position.y + 17.0)
	draw_string(font, north_position, "N", HORIZONTAL_ALIGNMENT_CENTER, -1.0, 12, Color(0.94, 0.97, 0.90, 0.95))
	draw_line(north_position + Vector2(0.0, 10.0), north_position + Vector2(0.0, 24.0), Color(0.94, 0.97, 0.90, 0.8), 1.5)
	var bar_length := 500.0 / _m_per_pixel
	var bar_start := Vector2(_map_rect.position.x + 11.0, _map_rect.end.y - 11.0)
	draw_line(bar_start, bar_start + Vector2(bar_length, 0.0), Color(0.97, 0.97, 0.87, 0.95), 2.0)
	draw_line(bar_start + Vector2(0.0, -4.0), bar_start + Vector2(0.0, 4.0), Color(0.97, 0.97, 0.87, 0.95), 1.5)
	draw_line(bar_start + Vector2(bar_length, -4.0), bar_start + Vector2(bar_length, 4.0), Color(0.97, 0.97, 0.87, 0.95), 1.5)
	draw_string(font, bar_start + Vector2(0.0, -5.0), "500 m", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 10, Color(0.97, 0.97, 0.87, 0.95))


func _world_to_chart(east_north: Vector2) -> Vector2:
	var center := _map_rect.get_center()
	var center_en := _chart_center_east_north
	return center + Vector2(
		(east_north.x - center_en.x) / _m_per_pixel,
		-(east_north.y - center_en.y) / _m_per_pixel
	)


func _world_chart_bounds() -> Rect2:
	var width_m := _map_rect.size.x * _m_per_pixel
	var height_m := _map_rect.size.y * _m_per_pixel
	return Rect2(
		_chart_center_east_north - Vector2(width_m, height_m) * 0.5,
		Vector2(width_m, height_m)
	)
