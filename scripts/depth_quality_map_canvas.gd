class_name DepthQualityMapCanvas
extends Control

## Full-region bathymetry overview for the F4 map. The chart is north-up;
## zooming and panning only change this view and never affect navigation data.

const RASTER_WIDTH := 240
const RASTER_HEIGHT := 330
const RASTER_PIXELS_PER_SLICE := 576
const UNKNOWN_COLOR := Color("#25333b")
const LAND_COLOR := Color("#9e9b89")
const ESTIMATED_COLOR := Color("#ffd166")
const UNRESOLVED_COLOR := Color("#ff5964")
const MIN_ZOOM := 1.0
const MAX_ZOOM := 12.0

var _bathymetry: BathymetryManager
var _georeference: GeoReference
var _boat: Node3D
var _extent := Rect2()
var _view_center := Vector2.ZERO
var _zoom := 1.0
var _map_rect := Rect2()
var _raster: ImageTexture
var _raster_image: Image
var _raster_cursor := 0
var _raster_building := false
var _chart_active := false
var _dragging := false
var _last_boat_position := Vector3(INF, INF, INF)
var _refresh_elapsed := 0.0
var _estimated_points := PackedVector2Array()
var _unresolved_points := PackedVector2Array()
var _cell_size_m := Vector2(66.0, 116.0)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	custom_minimum_size = Vector2(640.0, 480.0)
	set_process(false)


func configure(bathymetry: BathymetryManager, georeference: GeoReference, boat: Node3D) -> void:
	_bathymetry = bathymetry
	_georeference = georeference
	_boat = boat
	if _georeference != null:
		_extent = _georeference.region_bounds_east_north()
		_view_center = _extent.get_center()
	if _bathymetry != null:
		var overlay_data := _bathymetry.get_depth_quality_overlay_data()
		_estimated_points = overlay_data.get("estimated_points", PackedVector2Array())
		_unresolved_points = overlay_data.get("unresolved_points", PackedVector2Array())
		var latitude := _georeference.origin_latitude_deg if _georeference != null else 55.7
		var source_metadata := _bathymetry.get_source_metadata_at(latitude)
		_cell_size_m = Vector2(
			float(source_metadata.get("resolution_east_m", 66.0)),
			float(source_metadata.get("resolution_north_m", 116.0))
		)
	queue_redraw()


func set_chart_active(active: bool) -> void:
	_chart_active = active
	if active:
		ensure_raster()
		set_process(true)
	else:
		set_process(false)


func get_estimated_cell_count() -> int:
	return _estimated_points.size()


func get_unresolved_cell_count() -> int:
	return _unresolved_points.size()


func zoom_in() -> void:
	_set_zoom(_zoom * 1.25, _map_rect.get_center())


func zoom_out() -> void:
	_set_zoom(_zoom / 1.25, _map_rect.get_center())


func reset_view() -> void:
	_zoom = 1.0
	_view_center = _extent.get_center()
	queue_redraw()


func ensure_raster() -> void:
	if _raster != null or _raster_building or _bathymetry == null or _georeference == null:
		return
	if _extent.size.x <= 0.0 or _extent.size.y <= 0.0:
		return
	_raster_image = Image.create(RASTER_WIDTH, RASTER_HEIGHT, false, Image.FORMAT_RGBA8)
	_raster_cursor = 0
	_raster_building = true
	set_process(true)
	queue_redraw()


func _process(delta: float) -> void:
	var redraw_needed := false
	if _raster_building and _chart_active:
		var pixel_count := RASTER_WIDTH * RASTER_HEIGHT
		var slice_end := mini(_raster_cursor + RASTER_PIXELS_PER_SLICE, pixel_count)
		while _raster_cursor < slice_end:
			var x := _raster_cursor % RASTER_WIDTH
			var y := int(_raster_cursor / RASTER_WIDTH)
			_raster_image.set_pixel(x, y, _raster_pixel_color(x, y))
			_raster_cursor += 1
		if _raster_cursor >= pixel_count:
			_raster = ImageTexture.create_from_image(_raster_image)
			_raster_image = null
			_raster_building = false
		redraw_needed = true
	if _chart_active and _boat != null:
		_refresh_elapsed += delta
		if _refresh_elapsed >= 0.35:
			_refresh_elapsed = fmod(_refresh_elapsed, 0.35)
			var boat_position := _boat.global_position
			if boat_position.distance_squared_to(_last_boat_position) > 0.01:
				_last_boat_position = boat_position
				redraw_needed = true
	if redraw_needed:
		queue_redraw()
	if not _chart_active and not _raster_building:
		set_process(false)


func _draw() -> void:
	_map_rect = Rect2(Vector2(10.0, 10.0), size - Vector2(20.0, 20.0))
	if _map_rect.size.x <= 0.0 or _map_rect.size.y <= 0.0:
		return
	draw_rect(_map_rect, Color("#102c38"), true)
	if _extent.size.x <= 0.0 or _extent.size.y <= 0.0:
		return
	if _raster != null:
		draw_texture_rect(_raster, _get_extent_screen_rect(), false)
	else:
		draw_rect(_get_extent_screen_rect(), UNKNOWN_COLOR, true)
		var progress := 100.0 * float(_raster_cursor) / float(RASTER_WIDTH * RASTER_HEIGHT)
		var message := "正在构建完整水深图 · %.0f%%" % progress if _raster_building else "选择“水深图”标签以载入离线海图"
		draw_string(get_theme_default_font(), _map_rect.position + Vector2(16.0, 34.0), message, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 15, Color("#d4e4d6"))
	_draw_contours()
	_draw_coastlines()
	_draw_quality_cells(_estimated_points, ESTIMATED_COLOR)
	_draw_quality_cells(_unresolved_points, UNRESOLVED_COLOR)
	_draw_boat_marker()
	draw_rect(_map_rect, Color(0.67, 0.83, 0.81, 0.82), false, 1.5)
	var font := get_theme_default_font()
	draw_string(font, _map_rect.position + Vector2(12.0, 20.0), "EMODnet DTM 2024 · LAT · NORTH UP", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13, Color(0.93, 0.97, 0.92, 0.95))
	var zoom_text := "%.1f×" % _zoom
	draw_string(font, _map_rect.position + Vector2(_map_rect.size.x - 16.0, 20.0), zoom_text, HORIZONTAL_ALIGNMENT_RIGHT, -1.0, 13, Color(0.93, 0.97, 0.92, 0.95))
	_draw_scale_bar(font)


func _gui_input(event: InputEvent) -> void:
	var pointer := get_local_mouse_position()
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if not _map_rect.has_point(pointer):
				return
			var direction := 1.25 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.25
			_set_zoom(_zoom * direction, pointer)
			accept_event()
			return
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and _map_rect.has_point(pointer):
				_dragging = true
				mouse_default_cursor_shape = Control.CURSOR_DRAG
				accept_event()
			elif not event.pressed and _dragging:
				_dragging = false
				mouse_default_cursor_shape = Control.CURSOR_ARROW
				accept_event()
			return
	if event is InputEventMouseMotion and _dragging:
		var scale := _view_scale()
		if scale > 0.0:
			_view_center += Vector2(-event.relative.x / scale, event.relative.y / scale)
			_clamp_view_center()
			queue_redraw()
		accept_event()


func _set_zoom(next_zoom: float, focus_screen_position: Vector2) -> void:
	if _extent.size.x <= 0.0 or _extent.size.y <= 0.0:
		return
	var bounded_zoom := clampf(next_zoom, MIN_ZOOM, MAX_ZOOM)
	if is_equal_approx(bounded_zoom, _zoom):
		return
	var focus_world := _screen_to_world(focus_screen_position)
	_zoom = bounded_zoom
	var scale := _view_scale()
	var delta := focus_screen_position - _map_rect.get_center()
	_view_center = Vector2(focus_world.x - delta.x / scale, focus_world.y + delta.y / scale)
	_clamp_view_center()
	queue_redraw()


func _view_scale() -> float:
	if _extent.size.x <= 0.0 or _extent.size.y <= 0.0:
		return 0.0
	return minf(_map_rect.size.x / _extent.size.x, _map_rect.size.y / _extent.size.y) * _zoom


func _world_to_map(position: Vector2) -> Vector2:
	var scale := _view_scale()
	var center_screen := _map_rect.get_center()
	return center_screen + Vector2((position.x - _view_center.x) * scale, -((position.y - _view_center.y) * scale))


func _screen_to_world(position: Vector2) -> Vector2:
	var scale := _view_scale()
	if scale <= 0.0:
		return _view_center
	var delta := position - _map_rect.get_center()
	return _view_center + Vector2(delta.x / scale, -delta.y / scale)


func _get_extent_screen_rect() -> Rect2:
	var north_west := _world_to_map(Vector2(_extent.position.x, _extent.end.y))
	var south_east := _world_to_map(Vector2(_extent.end.x, _extent.position.y))
	return Rect2(north_west, south_east - north_west)


func _clamp_view_center() -> void:
	var scale := _view_scale()
	if scale <= 0.0:
		return
	var half_view := _map_rect.size / (2.0 * scale)
	var min_x := _extent.position.x + minf(half_view.x, _extent.size.x * 0.5)
	var max_x := _extent.end.x - minf(half_view.x, _extent.size.x * 0.5)
	var min_y := _extent.position.y + minf(half_view.y, _extent.size.y * 0.5)
	var max_y := _extent.end.y - minf(half_view.y, _extent.size.y * 0.5)
	_view_center.x = clampf(_view_center.x, min_x, max_x)
	_view_center.y = clampf(_view_center.y, min_y, max_y)


func _raster_pixel_color(x: int, y: int) -> Color:
	var east := _extent.position.x + (float(x) + 0.5) / float(RASTER_WIDTH) * _extent.size.x
	var north := _extent.end.y - (float(y) + 0.5) / float(RASTER_HEIGHT) * _extent.size.y
	if _bathymetry.is_land_at_east_north(east, north):
		return LAND_COLOR
	var geodetic := _georeference.world_to_geodetic(Vector3(east, 0.0, -north))
	var sample := _bathymetry.get_depth_at_geodetic(geodetic.x, geodetic.y, false, true)
	return _depth_color(sample, x, y)


func _depth_color(sample: Dictionary, x: int, y: int) -> Color:
	if not bool(sample.get("valid", false)):
		return UNKNOWN_COLOR.lightened(0.025 if posmod(x + y, 7) == 0 else 0.0)
	var depth := float(sample.get("depth_m", 0.0))
	var color := Color("#80b8a8")
	if depth >= 20.0:
		color = Color("#193d58")
	elif depth >= 10.0:
		color = Color("#24546d")
	elif depth >= 5.0:
		color = Color("#2f6d7c")
	elif depth >= 2.0:
		color = Color("#458c88")
	if bool(sample.get("estimated", false)):
		color = color.lerp(ESTIMATED_COLOR, 0.35)
	return color


func _draw_quality_cells(points: PackedVector2Array, color: Color) -> void:
	var scale := _view_scale()
	var native_size := Vector2(_cell_size_m.x * scale, _cell_size_m.y * scale)
	var marker_size := Vector2(maxf(2.4, native_size.x), maxf(2.4, native_size.y))
	for east_north in points:
		var point := _world_to_map(east_north)
		if not _map_rect.grow(marker_size.length()).has_point(point):
			continue
		var marker := Rect2(point - marker_size * 0.5, marker_size)
		draw_rect(marker, Color(color.r, color.g, color.b, 0.9), true)
		if marker_size.x > 5.0 or marker_size.y > 5.0:
			draw_rect(marker, Color(0.08, 0.1, 0.12, 0.78), false, 1.0)


func _draw_coastlines() -> void:
	if _bathymetry == null:
		return
	var view_bounds := _visible_world_bounds().grow(100.0)
	for index in range(_bathymetry.coastlines.size()):
		if index < _bathymetry.coastline_bounds.size() and not view_bounds.intersects(_bathymetry.coastline_bounds[index]):
			continue
		var line: PackedVector2Array = _bathymetry.coastlines[index]
		var screen_line := PackedVector2Array()
		for point in line:
			screen_line.append(_world_to_map(point))
		if screen_line.size() >= 2:
			draw_polyline(screen_line, Color("#f0dfb8"), 1.4, true)


func _draw_contours() -> void:
	if _bathymetry == null:
		return
	var view_bounds := _visible_world_bounds().grow(100.0)
	for level_string in _bathymetry.get_contour_levels():
		var color := Color("#b5ded2")
		var level := float(level_string)
		if level >= 20.0:
			color = Color("#c5d9e8")
		elif level >= 10.0:
			color = Color("#d0e8e7")
		var lines: Array = _bathymetry.contours_by_depth.get(level_string, [])
		var bounds_list: Array = _bathymetry.contour_bounds_by_depth.get(level_string, [])
		for index in range(lines.size()):
			if index < bounds_list.size() and not view_bounds.intersects(bounds_list[index]):
				continue
			var source_line: PackedVector2Array = lines[index]
			var screen_line := PackedVector2Array()
			for point in source_line:
				screen_line.append(_world_to_map(point))
			if screen_line.size() >= 2:
				draw_polyline(screen_line, color, 1.0, true)


func _visible_world_bounds() -> Rect2:
	var northwest := _screen_to_world(_map_rect.position)
	var southeast := _screen_to_world(_map_rect.end)
	return Rect2(Vector2(northwest.x, southeast.y), Vector2(southeast.x - northwest.x, northwest.y - southeast.y))


func _draw_boat_marker() -> void:
	if _boat == null:
		return
	var position := Vector2(_boat.global_position.x, -_boat.global_position.z)
	var point := _world_to_map(position)
	if not _map_rect.has_point(point):
		return
	draw_circle(point, 7.0, Color("#23d8ed"))
	draw_arc(point, 10.0, 0.0, TAU, 28, Color.WHITE, 1.5, true)
	var forward := -_boat.global_transform.basis.z
	var direction := Vector2(forward.x, -forward.z).normalized()
	if direction.length_squared() > 0.1:
		draw_line(point, point + direction * 16.0, Color.WHITE, 2.2, true)


func _draw_scale_bar(font: Font) -> void:
	var scale := _view_scale()
	if scale <= 0.0:
		return
	var target_m := 20000.0 / _zoom
	var bar_length := target_m * scale
	var end := _map_rect.position + Vector2(_map_rect.size.x - 20.0, _map_rect.size.y - 20.0)
	var start := end - Vector2(bar_length, 0.0)
	draw_line(start, end, Color(0.92, 0.95, 0.88, 0.92), 2.0, true)
	draw_line(start + Vector2(0.0, -4.0), start + Vector2(0.0, 4.0), Color(0.92, 0.95, 0.88, 0.92), 1.0, true)
	draw_line(end + Vector2(0.0, -4.0), end + Vector2(0.0, 4.0), Color(0.92, 0.95, 0.88, 0.92), 1.0, true)
	draw_string(font, start + Vector2(0.0, -6.0), "%.0f km" % (target_m / 1000.0), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11, Color(0.9, 0.95, 0.9, 0.84))
