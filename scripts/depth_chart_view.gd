class_name DepthChartView
extends Control

## North-up local sea chart. Bathymetry is sampled incrementally and static
## coastline/contour projections are cached until the chart centre changes.

const CHART_HEIGHT_RANGE_M := 1800.0
const RASTER_WIDTH := 128
const RASTER_HEIGHT := 92
const RASTER_PIXELS_PER_FRAME := 256
const CHART_RECENTER_DISTANCE_M := 45.0
const UNKNOWN_COLOR := Color("#263740")
const LAND_COLOR := Color("#aaa18d")

var _manager: BathymetryManager
var _boat: Node3D
var _chart_texture: ImageTexture
var _chart_geometry_dirty := true
var _chart_center_east_north := Vector2(INF, INF)
var _build_center_east_north := Vector2.ZERO
var _build_center_geodetic := Vector2.ZERO
var _geodetic_degrees_per_meter := Vector4.ZERO
var _boat_direction_screen := Vector2.UP
var _refresh_elapsed := 0.0
var _m_per_pixel := 1.0
var _map_rect := Rect2()
var _raster_image: Image
var _raster_building := false
var _raster_cursor := 0
var _build_sample_count := 0
var _last_build_sample_count := 0
var _last_build_max_slice_ms := 0.0
var _current_build_max_slice_ms := 0.0
var _texture_uploads_last_build := 0
var _texture_uploads_total := 0
var _build_started_usec := 0
var _cached_coastline_lines: Array[PackedVector2Array] = []
var _cached_contour_lines: Array[Dictionary] = []
var _cached_contour_labels: Array[Dictionary] = []


func configure(manager: BathymetryManager, boat: Node3D) -> void:
	_manager = manager
	_boat = boat


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	custom_minimum_size = Vector2(324.0, 260.0)
	resized.connect(_on_resized)
	set_process(true)


func _process(delta: float) -> void:
	var redraw_needed := false
	if _raster_building:
		_build_raster_slice()
		redraw_needed = true
	_refresh_elapsed += delta
	if _manager != null and _boat != null and _refresh_elapsed >= 0.25:
		_refresh_elapsed = fmod(_refresh_elapsed, 0.25)
		var world_position := _boat.global_position
		var east_north := Vector2(world_position.x, -world_position.z)
		var forward := -_boat.global_transform.basis.z
		forward.y = 0.0
		if forward.length_squared() > 0.0001:
			var next_direction := Vector2(forward.x, forward.z).normalized()
			if next_direction.dot(_boat_direction_screen) < 0.999:
				_boat_direction_screen = next_direction
				redraw_needed = true
		if not _raster_building and (_chart_texture == null or east_north.distance_to(_chart_center_east_north) >= CHART_RECENTER_DISTANCE_M):
			_start_chart_build(east_north)
			redraw_needed = true
	if redraw_needed:
		queue_redraw()


func is_chart_ready() -> bool:
	return _chart_texture != null


func is_chart_geometry_dirty() -> bool:
	return _chart_geometry_dirty


func get_chart_build_statistics() -> Dictionary:
	return {
		"ready": _chart_texture != null,
		"building": _raster_building,
		"pixels_completed": _raster_cursor,
		"pixels_total": RASTER_WIDTH * RASTER_HEIGHT,
		"pixels_per_frame_budget": RASTER_PIXELS_PER_FRAME,
		"depth_samples_last_build": _last_build_sample_count,
		"max_slice_ms_last_build": _last_build_max_slice_ms,
		"texture_uploads_last_build": _texture_uploads_last_build,
		"texture_uploads_total": _texture_uploads_total,
		"elapsed_ms_current_build": float(Time.get_ticks_usec() - _build_started_usec) / 1000.0 if _raster_building else 0.0,
	}


func request_chart_refresh() -> void:
	if _boat == null or not is_visible_in_tree():
		_chart_geometry_dirty = true
		return
	_raster_image = null
	_raster_building = false
	_start_chart_build(Vector2(_boat.global_position.x, -_boat.global_position.z))


func _start_chart_build(center: Vector2) -> void:
	if _manager == null or _manager.georeference == null:
		return
	_update_map_metrics()
	if _map_rect.size.x <= 0.0 or _map_rect.size.y <= 0.0:
		return
	_build_center_east_north = center
	var world_center := Vector3(center.x, 0.0, -center.y)
	var center_geo := _manager.georeference.world_to_geodetic(world_center)
	var east_geo := _manager.georeference.world_to_geodetic(world_center + Vector3.RIGHT)
	var north_geo := _manager.georeference.world_to_geodetic(world_center + Vector3.FORWARD)
	_build_center_geodetic = Vector2(center_geo.x, center_geo.y)
	_geodetic_degrees_per_meter = Vector4(
		east_geo.x - center_geo.x,
		east_geo.y - center_geo.y,
		north_geo.x - center_geo.x,
		north_geo.y - center_geo.y
	)
	_raster_image = Image.create(RASTER_WIDTH, RASTER_HEIGHT, false, Image.FORMAT_RGBA8)
	_raster_cursor = 0
	_build_sample_count = 0
	_current_build_max_slice_ms = 0.0
	_build_started_usec = Time.get_ticks_usec()
	_raster_building = true


func _build_raster_slice() -> void:
	if _raster_image == null or _manager == null:
		_raster_building = false
		return
	var slice_started_usec := Time.get_ticks_usec()
	var total_pixels := RASTER_WIDTH * RASTER_HEIGHT
	var slice_end := mini(_raster_cursor + RASTER_PIXELS_PER_FRAME, total_pixels)
	var map_width_m := _map_rect.size.x * _m_per_pixel
	while _raster_cursor < slice_end:
		var x := _raster_cursor % RASTER_WIDTH
		var y := int(_raster_cursor / RASTER_WIDTH)
		var east := _build_center_east_north.x + ((float(x) + 0.5) / float(RASTER_WIDTH) - 0.5) * map_width_m
		var north := _build_center_east_north.y + (0.5 - (float(y) + 0.5) / float(RASTER_HEIGHT)) * CHART_HEIGHT_RANGE_M
		var color := _sample_chart_color(east, north, x, y)
		_raster_image.set_pixel(x, y, color)
		_raster_cursor += 1
	_current_build_max_slice_ms = maxf(_current_build_max_slice_ms, float(Time.get_ticks_usec() - slice_started_usec) / 1000.0)
	if _raster_cursor < total_pixels:
		return
	_chart_texture = ImageTexture.create_from_image(_raster_image)
	_texture_uploads_total += 1
	_texture_uploads_last_build = 1
	_last_build_sample_count = _build_sample_count
	_last_build_max_slice_ms = _current_build_max_slice_ms
	_chart_center_east_north = _build_center_east_north
	_raster_image = null
	_raster_building = false
	_cache_chart_geometry()


func _sample_chart_color(east: float, north: float, x: int, y: int) -> Color:
	if _manager.is_land_at_east_north(east, north):
		return LAND_COLOR
	if not _manager.data_available:
		return _unknown_pixel(x, y)
	# The chart covers only 1.8 km. A local WGS84 Jacobian (computed at chart
	# centre) avoids running the full ECEF inverse for every raster pixel.
	var delta_east := east - _build_center_east_north.x
	var delta_north := north - _build_center_east_north.y
	var latitude := _build_center_geodetic.x + delta_east * _geodetic_degrees_per_meter.x + delta_north * _geodetic_degrees_per_meter.z
	var longitude := _build_center_geodetic.y + delta_east * _geodetic_degrees_per_meter.y + delta_north * _geodetic_degrees_per_meter.w
	var sample := _manager.get_depth_at_geodetic(latitude, longitude, false, true)
	_build_sample_count += 1
	return _depth_color(sample, x, y)


func _update_map_metrics() -> void:
	_map_rect = Rect2(Vector2(8.0, 7.0), Vector2(size.x - 16.0, size.y - 43.0))
	if _map_rect.size.y > 0.0:
		_m_per_pixel = CHART_HEIGHT_RANGE_M / _map_rect.size.y


func _on_resized() -> void:
	_update_map_metrics()
	_chart_geometry_dirty = true
	if not is_visible_in_tree():
		return
	if _boat != null:
		request_chart_refresh()
	elif _chart_texture != null and is_finite(_chart_center_east_north.x):
		_cache_chart_geometry()
	queue_redraw()


func _cache_chart_geometry() -> void:
	_update_map_metrics()
	_cached_coastline_lines.clear()
	_cached_contour_lines.clear()
	_cached_contour_labels.clear()
	if _manager == null or not is_finite(_chart_center_east_north.x) or _map_rect.size.x <= 0.0 or _map_rect.size.y <= 0.0:
		return
	_chart_geometry_dirty = false
	var chart_bounds := _world_chart_bounds(_chart_center_east_north).grow(30.0)
	for index in range(_manager.coastlines.size()):
		if index < _manager.coastline_bounds.size() and not chart_bounds.intersects(_manager.coastline_bounds[index]):
			continue
		var source_line: PackedVector2Array = _manager.coastlines[index]
		var screen_pieces := clip_polyline_to_rect(_project_line(source_line, _chart_center_east_north), _map_rect)
		for screen_line in screen_pieces:
			if screen_line.size() < 2:
				continue
			_cached_coastline_lines.append(screen_line)
	var labels_added: Dictionary = {}
	for level_string in _manager.get_contour_levels():
		var level := float(level_string)
		var color := _contour_color(level)
		var lines: Array = _manager.contours_by_depth.get(level_string, [])
		var line_bounds: Array = _manager.contour_bounds_by_depth.get(level_string, [])
		for index in range(lines.size()):
			if index < line_bounds.size() and not chart_bounds.intersects(line_bounds[index]):
				continue
			var source_line: PackedVector2Array = lines[index]
			var screen_pieces := clip_polyline_to_rect(_project_line(source_line, _chart_center_east_north), _map_rect)
			for screen_line in screen_pieces:
				if screen_line.size() < 2:
					continue
				_cached_contour_lines.append({"points": screen_line, "color": color})
				if not labels_added.has(level_string) and screen_line.size() > 5:
					var midpoint := screen_line[screen_line.size() / 2]
					_cached_contour_labels.append({"position": midpoint, "text": "%dm" % roundi(level), "color": color})
					labels_added[level_string] = true


func _project_line(source_line: PackedVector2Array, center: Vector2) -> PackedVector2Array:
	var screen_line := PackedVector2Array()
	for point in source_line:
		screen_line.append(_world_to_chart_at(point, center))
	return screen_line


static func clip_polyline_to_rect(points: PackedVector2Array, rect: Rect2) -> Array[PackedVector2Array]:
	var pieces: Array[PackedVector2Array] = []
	if points.size() < 2 or rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return pieces
	var current := PackedVector2Array()
	for index in range(points.size() - 1):
		var segment := _clip_segment_to_rect(points[index], points[index + 1], rect)
		if segment.is_empty():
			if current.size() >= 2:
				pieces.append(current)
			current = PackedVector2Array()
			continue
		if not current.is_empty() and current[current.size() - 1].distance_to(segment[0]) <= 0.01:
			if current[current.size() - 1].distance_to(segment[1]) > 0.001:
				current.append(segment[1])
		else:
			if current.size() >= 2:
				pieces.append(current)
			current = PackedVector2Array([segment[0], segment[1]])
	if current.size() >= 2:
		pieces.append(current)
	return pieces


static func _clip_segment_to_rect(start: Vector2, finish: Vector2, rect: Rect2) -> PackedVector2Array:
	var delta := finish - start
	var t_min := 0.0
	var t_max := 1.0
	var p_values := [-delta.x, delta.x, -delta.y, delta.y]
	var q_values := [start.x - rect.position.x, rect.end.x - start.x, start.y - rect.position.y, rect.end.y - start.y]
	for index in range(4):
		var p := float(p_values[index])
		var q := float(q_values[index])
		if is_zero_approx(p):
			if q < 0.0:
				return PackedVector2Array()
			continue
		var ratio := q / p
		if p < 0.0:
			if ratio > t_max:
				return PackedVector2Array()
			t_min = maxf(t_min, ratio)
		else:
			if ratio < t_min:
				return PackedVector2Array()
			t_max = minf(t_max, ratio)
	if t_min > t_max:
		return PackedVector2Array()
	return PackedVector2Array([start + delta * t_min, start + delta * t_max])


func _draw() -> void:
	_update_map_metrics()
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
	_draw_distance_rings()
	_draw_coastlines()
	_draw_contours()
	_draw_boat_marker()
	_draw_compass_and_scale()
	draw_rect(_map_rect, Color(0.70, 0.86, 0.84, 0.72), false, 1.0)


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
	for screen_line in _cached_coastline_lines:
		draw_polyline(screen_line, Color(0.88, 0.83, 0.70, 0.95), 1.35, true)


func _draw_contours() -> void:
	for line_data in _cached_contour_lines:
		draw_polyline(line_data["points"], line_data["color"], 1.0, true)
	for label_data in _cached_contour_labels:
		draw_string(get_theme_default_font(), label_data["position"] + Vector2(3.0, -3.0), label_data["text"], HORIZONTAL_ALIGNMENT_LEFT, -1.0, 10, label_data["color"])


func _contour_color(level: float) -> Color:
	if level >= 20.0:
		return Color(0.66, 0.85, 0.94, 0.72)
	if level >= 10.0:
		return Color(0.69, 0.91, 0.91, 0.76)
	if level >= 5.0:
		return Color(0.75, 0.96, 0.90, 0.82)
	return Color(0.78, 0.94, 0.88, 0.8)


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


func _world_to_chart_at(east_north: Vector2, center: Vector2) -> Vector2:
	var screen_center := _map_rect.get_center()
	return screen_center + Vector2(
		(east_north.x - center.x) / _m_per_pixel,
		-(east_north.y - center.y) / _m_per_pixel
	)


func _world_chart_bounds(center: Vector2) -> Rect2:
	var width_m := _map_rect.size.x * _m_per_pixel
	var height_m := _map_rect.size.y * _m_per_pixel
	return Rect2(center - Vector2(width_m, height_m) * 0.5, Vector2(width_m, height_m))
