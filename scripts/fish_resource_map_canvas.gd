class_name FishResourceMapCanvas
extends Control

signal school_hovered(school: Dictionary)
signal school_selected(school: Dictionary)
signal route_edit_map_clicked(world_position: Vector3, is_inside_map: bool, is_land: bool)
signal route_waypoint_selected(waypoint_index: int)
signal route_waypoint_moved(waypoint_index: int, world_position: Vector3, is_inside_map: bool, is_land: bool)

# The coastline and contour vectors remain full resolution. The background
# bathymetry is only a coarse color aid, so avoid thousands of startup samples.
const RASTER_WIDTH := 144
const RASTER_HEIGHT := 198
const RASTER_PIXELS_PER_SLICE := 576
const RESOURCE_CLUSTER_PIXELS := 18.0
const UNKNOWN_COLOR := Color("#25333b")
const LAND_COLOR := Color("#9e9b89")

var _manager: FishResourceManager
var _bathymetry: BathymetryManager
var _georeference: GeoReference
var _boat: Node3D
var _dolphin_manager: Node
var _route_definition: RouteDefinition
var _route_georeference: GeoReference
var _route_validation_hit_world_position := Vector3.ZERO
var _route_validation_hit_label := ""
var _has_route_validation_hit := false
var _resource_overlay_enabled := true
var _dolphins_enabled := true
var _editing_route: RouteDefinition
var _route_edit_enabled := false
var _route_edit_operation := "ADD"
var _selected_route_waypoint_index := -1
var _dragging_route_waypoint_index := -1
var _extent := Rect2()
var _map_rect := Rect2()
var _raster: ImageTexture
var _schools: Array[Dictionary] = []
var _dolphins: Array[Dictionary] = []
var _profiles: Dictionary = {}
var _selected_species: Array[String] = []
var _hovered_school: Dictionary = {}
var _selected_school: Dictionary = {}
var _raster_built := false
var _raster_building := false
var _raster_build_enabled := false
var _raster_image: Image
var _raster_cursor := 0
var _raster_build_started_usec := 0
var _raster_build_elapsed_ms := 0.0
var _raster_max_slice_ms := 0.0
var _raster_work_ms_total := 0.0
var _boat_pulse_enabled := false
var _boat_pulse_phase := 0.0
var _pulse_redraw_elapsed := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	custom_minimum_size = Vector2(640.0, 480.0)
	set_process(false)


func configure(manager: FishResourceManager, bathymetry: BathymetryManager, georeference: GeoReference, boat: Node3D, dolphin_manager: Node = null) -> void:
	_manager = manager
	_bathymetry = bathymetry
	_georeference = georeference
	_boat = boat
	_dolphin_manager = dolphin_manager
	_extent = georeference.region_bounds_east_north()
	_profiles.clear()
	_selected_species.clear()
	for profile in manager.get_species_profiles():
		_profiles[profile.species_id] = profile
	refresh_data()
	queue_redraw()
	_raster_built = false


func set_route_overlay(route: RouteDefinition, georeference: GeoReference) -> void:
	_route_definition = route
	_route_georeference = georeference
	queue_redraw()


func set_route_validation_hit(world_position: Vector3, label: String, enabled: bool) -> void:
	_route_validation_hit_world_position = world_position
	_route_validation_hit_label = label
	_has_route_validation_hit = enabled
	queue_redraw()


func set_route_editing(route: RouteDefinition, georeference: GeoReference, enabled: bool, operation: String, selected_waypoint_index: int) -> void:
	_editing_route = route
	_route_georeference = georeference
	_route_edit_enabled = enabled
	_route_edit_operation = operation
	_selected_route_waypoint_index = selected_waypoint_index
	if not enabled:
		_dragging_route_waypoint_index = -1
	queue_redraw()


func map_local_position_to_world(map_position: Vector2) -> Dictionary:
	if _georeference == null or _bathymetry == null or _extent.size.x <= 0.0 or _extent.size.y <= 0.0:
		return {"valid": false, "is_land": false, "world_position": Vector3.ZERO, "reason": "地图或陆地掩膜不可用"}
	var drawn_rect := _get_world_map_rect()
	if not drawn_rect.has_point(map_position):
		return {"valid": false, "is_land": false, "world_position": Vector3.ZERO}
	var scale := drawn_rect.size.x / maxf(_extent.size.x, 1.0)
	if scale <= 0.0:
		return {"valid": false, "is_land": false, "world_position": Vector3.ZERO}
	var east := _extent.position.x + (map_position.x - drawn_rect.position.x) / scale
	var north := _extent.end.y - (map_position.y - drawn_rect.position.y) / scale
	var world_position := Vector3(east, 0.0, -north)
	var geo := _georeference.world_to_geodetic(world_position)
	var within_region := geo.x >= _georeference.south_latitude_deg and geo.x <= _georeference.north_latitude_deg and geo.y >= _georeference.west_longitude_deg and geo.y <= _georeference.east_longitude_deg
	var is_land := _bathymetry != null and _bathymetry.is_land_at_east_north(east, north)
	return {
		"valid": within_region,
		"is_land": is_land,
		"world_position": world_position,
		"latitude_deg": geo.x,
		"longitude_deg": geo.y,
	}


func ensure_raster() -> void:
	if _raster_built:
		return
	if _raster_building:
		return
	if _bathymetry == null or _georeference == null or _extent.size.x <= 0.0 or _extent.size.y <= 0.0:
		return
	_raster_image = Image.create(RASTER_WIDTH, RASTER_HEIGHT, false, Image.FORMAT_RGBA8)
	_raster_cursor = 0
	_raster_building = true
	_raster_build_started_usec = Time.get_ticks_usec()
	_raster_build_elapsed_ms = 0.0
	_raster_max_slice_ms = 0.0
	_raster_work_ms_total = 0.0
	set_process(_raster_build_enabled)
	queue_redraw()


func set_raster_build_enabled(enabled: bool) -> void:
	_raster_build_enabled = enabled
	set_process(_boat_pulse_enabled or (enabled and _raster_building))


func set_boat_pulse_enabled(enabled: bool) -> void:
	_boat_pulse_enabled = enabled
	if enabled:
		queue_redraw()
	set_process(enabled or (_raster_build_enabled and _raster_building))


func is_raster_ready() -> bool:
	return _raster_built


func get_raster_build_statistics() -> Dictionary:
	return {
		"ready": _raster_built,
		"building": _raster_building,
		"pixels_completed": _raster_cursor,
		"pixels_total": RASTER_WIDTH * RASTER_HEIGHT,
		"build_elapsed_ms": _raster_build_elapsed_ms,
		"maximum_slice_ms": _raster_max_slice_ms,
		"total_slice_work_ms": _raster_work_ms_total,
	}


func set_species_filter(species_ids: Array[String]) -> void:
	_selected_species = species_ids.duplicate()
	refresh_data()
	queue_redraw()


func set_dolphins_enabled(enabled: bool) -> void:
	_dolphins_enabled = enabled
	if enabled:
		refresh_dolphin_data()
	else:
		queue_redraw()


func set_resource_overlay_enabled(enabled: bool) -> void:
	_resource_overlay_enabled = enabled
	queue_redraw()


func refresh_data() -> void:
	if _manager == null:
		return
	if _selected_species.is_empty():
		_schools.clear()
	else:
		_schools = _manager.get_map_distribution(_selected_species)
	refresh_dolphin_data()


func refresh_dolphin_data() -> void:
	_dolphins.clear()
	if _dolphins_enabled and is_instance_valid(_dolphin_manager) and _dolphin_manager.has_method("get_map_snapshot"):
		var dolphin_data: Variant = _dolphin_manager.call("get_map_snapshot")
		if dolphin_data is Array:
			for item in dolphin_data:
				if item is Dictionary:
					_dolphins.append(item)
	queue_redraw()


func get_school_count() -> int:
	return _schools.size()


func get_dolphin_count() -> int:
	return _dolphins.size() if _dolphins_enabled else 0


func get_selected_school() -> Dictionary:
	return _selected_school


func _process(_delta: float) -> void:
	var needs_redraw := false
	if _boat_pulse_enabled:
		_boat_pulse_phase = fposmod(_boat_pulse_phase + _delta / 1.8, 1.0)
		_pulse_redraw_elapsed += _delta
		if _pulse_redraw_elapsed >= 0.04:
			_pulse_redraw_elapsed = fmod(_pulse_redraw_elapsed, 0.04)
			needs_redraw = true
	if _raster_building and _raster_build_enabled:
		var slice_started_usec := Time.get_ticks_usec()
		var pixel_count := RASTER_WIDTH * RASTER_HEIGHT
		var slice_end := mini(_raster_cursor + RASTER_PIXELS_PER_SLICE, pixel_count)
		while _raster_cursor < slice_end:
			var x := _raster_cursor % RASTER_WIDTH
			var y := int(_raster_cursor / RASTER_WIDTH)
			_raster_image.set_pixel(x, y, _raster_pixel_color(x, y))
			_raster_cursor += 1
		var slice_ms := float(Time.get_ticks_usec() - slice_started_usec) / 1000.0
		_raster_work_ms_total += slice_ms
		_raster_max_slice_ms = maxf(_raster_max_slice_ms, slice_ms)
		if _raster_cursor >= pixel_count:
			_raster = ImageTexture.create_from_image(_raster_image)
			_raster_built = true
			_raster_building = false
			_raster_build_elapsed_ms = float(Time.get_ticks_usec() - _raster_build_started_usec) / 1000.0
			_raster_image = null
			needs_redraw = true
		needs_redraw = true
	if needs_redraw:
		queue_redraw()
	if not _boat_pulse_enabled and not (_raster_build_enabled and _raster_building):
		set_process(false)


func _draw() -> void:
	_map_rect = Rect2(Vector2(10.0, 10.0), size - Vector2(20.0, 20.0))
	if _map_rect.size.x <= 0.0 or _map_rect.size.y <= 0.0:
		return
	draw_rect(_map_rect, Color("#102c38"), true)
	if _raster != null:
		draw_texture_rect(_raster, _get_world_map_rect(), false)
	elif _raster_building:
		var progress := 100.0 * float(_raster_cursor) / float(RASTER_WIDTH * RASTER_HEIGHT)
		draw_string(get_theme_default_font(), _map_rect.position + Vector2(14.0, 44.0), "正在构建离线水深底图 · %.0f%%" % progress, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 14, Color("#d4e4d6"))
	_draw_contours()
	_draw_coastlines()
	_draw_route()
	_draw_route_validation_hit()
	if _resource_overlay_enabled:
		_draw_resource_cells()
		if _dolphins_enabled:
			_draw_dolphins()
	_draw_boat()
	draw_rect(_map_rect, Color(0.67, 0.83, 0.81, 0.78), false, 1.5)
	var font := get_theme_default_font()
	draw_string(font, _map_rect.position + Vector2(10.0, 20.0), "WGS84 · NORTH UP", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11, Color(0.9, 0.95, 0.9, 0.84))
	draw_string(font, _map_rect.position + Vector2(10.0, _map_rect.size.y - 10.0), "ØRESUND", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11, Color(0.9, 0.95, 0.9, 0.84))
	_draw_scale_bar(font)


func _gui_input(event: InputEvent) -> void:
	if _route_edit_enabled:
		# Read pointer coordinates in this Control's local space. This keeps the
		# map hit-test correct regardless of CanvasLayer/window scaling.
		var pointer_position := get_local_mouse_position()
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			var mapped := map_local_position_to_world(pointer_position)
			if event.pressed:
				if _route_edit_operation == "DRAG":
					_dragging_route_waypoint_index = _nearest_edit_waypoint_index(pointer_position)
					if _dragging_route_waypoint_index >= 0:
						_selected_route_waypoint_index = _dragging_route_waypoint_index
					route_waypoint_selected.emit(_selected_route_waypoint_index)
				else:
					route_edit_map_clicked.emit(mapped.get("world_position", Vector3.ZERO), bool(mapped.get("valid", false)), bool(mapped.get("is_land", false)))
			else:
				_dragging_route_waypoint_index = -1
			accept_event()
			queue_redraw()
		elif event is InputEventMouseMotion and _dragging_route_waypoint_index >= 0:
			var mapped_motion := map_local_position_to_world(pointer_position)
			route_waypoint_moved.emit(
				_dragging_route_waypoint_index,
				mapped_motion.get("world_position", Vector3.ZERO),
				bool(mapped_motion.get("valid", false)),
				bool(mapped_motion.get("is_land", false))
			)
			accept_event()
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			_dragging_route_waypoint_index = -1
			accept_event()
		return
	if not _resource_overlay_enabled:
		return
	if event is InputEventMouseMotion:
		var hovered := _nearest_school(event.position)
		if str(hovered.get("school_id", "")) != str(_hovered_school.get("school_id", "")):
			_hovered_school = hovered
			school_hovered.emit(_hovered_school)
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_selected_school = _nearest_school(event.position)
		school_selected.emit(_selected_school)
		accept_event()


func _raster_pixel_color(x: int, y: int) -> Color:
	var north := _extent.end.y - (float(y) + 0.5) / float(RASTER_HEIGHT) * _extent.size.y
	var east := _extent.position.x + (float(x) + 0.5) / float(RASTER_WIDTH) * _extent.size.x
	if _bathymetry.is_land_at_east_north(east, north):
		return LAND_COLOR
	var sample := _bathymetry.get_depth_at_world_position(Vector3(east, 0.0, -north))
	return _depth_color(sample, x, y)


func _draw_contours() -> void:
	if _bathymetry == null:
		return
	var colors := {"2": Color("#b5ded2"), "5": Color("#b5ddd7"), "10": Color("#d0e8e7"), "20": Color("#c5d9e8")}
	for level_string in _bathymetry.get_contour_levels():
		var lines: Array = _bathymetry.contours_by_depth.get(level_string, [])
		var bounds_list: Array = _bathymetry.contour_bounds_by_depth.get(level_string, [])
		var line_color: Color = colors.get(level_string, Color(0.75, 0.88, 0.88, 0.45))
		for index in range(lines.size()):
			if index < bounds_list.size() and not _extent.intersects(bounds_list[index]):
				continue
			var source_line: PackedVector2Array = lines[index]
			var points := PackedVector2Array()
			for point in source_line:
				points.append(_world_to_map(point))
			if points.size() >= 2:
				draw_polyline(points, line_color, 1.0, true)


func _draw_coastlines() -> void:
	if _bathymetry == null:
		return
	for index in range(_bathymetry.coastlines.size()):
		if index < _bathymetry.coastline_bounds.size() and not _extent.intersects(_bathymetry.coastline_bounds[index]):
			continue
		var source_line: PackedVector2Array = _bathymetry.coastlines[index]
		var points := PackedVector2Array()
		for point in source_line:
			points.append(_world_to_map(point))
		if points.size() >= 2:
			draw_polyline(points, Color("#f0dfb8"), 1.5, true)


func _draw_resource_cells() -> void:
	var clusters: Dictionary = {}
	for school in _schools:
		var world_position: Array = school["world_position"]
		var point := _world_to_map(Vector2(float(world_position[0]), -float(world_position[2])))
		if not _map_rect.has_point(point):
			continue
		var profile: FishSpeciesProfile = _profiles.get(str(school["species_id"]))
		if profile == null:
			continue
		var render_state := str(school.get("render_state", "visual"))
		var grid := Vector2i(
			floori((point.x - _map_rect.position.x) / RESOURCE_CLUSTER_PIXELS),
			floori((point.y - _map_rect.position.y) / RESOURCE_CLUSTER_PIXELS)
		)
		var cluster_key := "%s:%s:%d:%d" % [profile.species_id, render_state, grid.x, grid.y]
		if not clusters.has(cluster_key):
			clusters[cluster_key] = {
				"species_id": profile.species_id,
				"render_state": render_state,
				"color": profile.map_color,
				"position_sum": Vector2.ZERO,
				"school_count": 0,
				"population": 0,
			}
		var cluster: Dictionary = clusters[cluster_key]
		cluster["position_sum"] = Vector2(cluster["position_sum"]) + point
		cluster["school_count"] = int(cluster["school_count"]) + 1
		cluster["population"] = int(cluster["population"]) + int(school.get("population", 0))
	for cluster in clusters.values():
		var school_count := int(cluster["school_count"])
		var point: Vector2 = cluster["position_sum"] / float(maxi(school_count, 1))
		var population := int(cluster["population"])
		var radius := clampf(3.0 + log(maxf(1.0, float(school_count))) * 1.5 + log(maxf(1.0, float(population))) * 0.35, 3.0, 11.0)
		var color: Color = cluster["color"]
		if str(cluster["render_state"]) == "logical":
			var logical_color := color.lerp(Color("#9aabb1"), 0.68)
			draw_arc(point, radius, 0.0, TAU, 20, Color(logical_color.r, logical_color.g, logical_color.b, 0.78), 1.4, true)
			for segment in range(4):
				var start_angle := float(segment) * TAU * 0.25 + 0.12
				draw_arc(point, radius + 1.2, start_angle, start_angle + TAU * 0.12, 6, Color("#d1dcdf"), 1.0, true)
		else:
			draw_circle(point, radius + 3.0, Color(color.r, color.g, color.b, 0.16))
			draw_circle(point, radius, Color(color.r, color.g, color.b, 0.88))
			draw_arc(point, radius + 0.5, 0.0, TAU, 24, Color(0.94, 0.97, 0.92, 0.9), 0.8, true)


func _draw_dolphins() -> void:
	for pod in _dolphins:
		var world_position: Array = pod.get("world_position", [])
		if world_position.size() < 3:
			continue
		var point := _world_to_map(Vector2(float(world_position[0]), -float(world_position[2])))
		if not _map_rect.has_point(point):
			continue
		var color := Color("#e8c78b") if bool(pod.get("is_following", false)) else Color("#a9e5df")
		# Distinct small cetacean glyph: arched body, pointed rostrum and tail flukes.
		draw_arc(point + Vector2(0.0, 1.0), 8.0, PI * 1.08, PI * 1.92, 18, color, 2.6, true)
		draw_line(point + Vector2(6.0, 0.2), point + Vector2(12.0, -1.4), color, 2.2, true)
		var fluke := PackedVector2Array([point + Vector2(-6.0, 0.0), point + Vector2(-12.0, -5.0), point + Vector2(-10.0, 1.0), point + Vector2(-12.0, 5.0)])
		draw_colored_polygon(fluke, color)
		draw_line(point + Vector2(-1.0, -4.0), point + Vector2(-3.0, -8.0), color, 2.0, true)
		draw_arc(point, 16.0, 0.0, TAU, 30, Color(color.r, color.g, color.b, 0.45), 1.2, true)
		draw_string(get_theme_default_font(), point + Vector2(19.0, 4.0), "海豚 ×%d" % int(pod.get("population", 0)), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, color)


func _draw_route() -> void:
	var drawing_route := _editing_route if _route_edit_enabled and _editing_route != null else _route_definition
	if drawing_route == null or _route_georeference == null:
		return
	var world_points := drawing_route.get_world_points(_route_georeference)
	if world_points.size() < 2:
		return
	var map_points := PackedVector2Array()
	for world_point in world_points:
		map_points.append(_world_to_map(Vector2(world_point.x, -world_point.z)))
	var route_color := Color("#8bd6c8") if _route_edit_enabled else Color("#f4c46d")
	draw_polyline(map_points, Color(0.01, 0.10, 0.13, 0.9), 7.0, true)
	draw_polyline(map_points, route_color, 3.0, true)
	for index in range(map_points.size()):
		var point := map_points[index]
		var endpoint := index == 0 or index == map_points.size() - 1
		draw_circle(point, 7.0 if endpoint else 5.0, Color("#102c38"))
		var selected := _route_edit_enabled and index > 0 and index < map_points.size() - 1 and index - 1 == _selected_route_waypoint_index
		draw_arc(point, 9.0 if selected else 7.0 if endpoint else 5.0, 0.0, TAU, 20, Color("#fff1c1") if selected else route_color, 2.0 if selected else 1.5, true)
		var label := drawing_route.departure_display_name if index == 0 else drawing_route.arrival_display_name if index == map_points.size() - 1 else (drawing_route.waypoints[index - 1].display_name if drawing_route.waypoints[index - 1] != null and not drawing_route.waypoints[index - 1].display_name.is_empty() else "WP%d" % index)
		draw_string(get_theme_default_font(), point + Vector2(8.0, -7.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11, Color("#fff1c7"))


func _draw_route_validation_hit() -> void:
	if not _has_route_validation_hit:
		return
	var point := _world_to_map(Vector2(_route_validation_hit_world_position.x, -_route_validation_hit_world_position.z))
	if not _map_rect.has_point(point):
		return
	draw_circle(point, 9.0, Color("#ff4d55"))
	draw_line(point + Vector2(-13.0, -13.0), point + Vector2(13.0, 13.0), Color.WHITE, 2.5, true)
	draw_line(point + Vector2(-13.0, 13.0), point + Vector2(13.0, -13.0), Color.WHITE, 2.5, true)
	draw_string(get_theme_default_font(), point + Vector2(14.0, -10.0), _route_validation_hit_label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, Color("#ffd9d9"))


func _nearest_edit_waypoint_index(screen_position: Vector2) -> int:
	if _editing_route == null or _route_georeference == null or not _map_rect.has_point(screen_position):
		return -1
	var points := _editing_route.get_world_points(_route_georeference)
	var nearest_index := -1
	var nearest_distance := 18.0
	for map_index in range(1, points.size() - 1):
		var map_point := _world_to_map(Vector2(points[map_index].x, -points[map_index].z))
		var distance := map_point.distance_to(screen_position)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest_index = map_index - 1
	return nearest_index


func _draw_boat() -> void:
	if _boat == null:
		return
	var point := _world_to_map(Vector2(_boat.global_position.x, -_boat.global_position.z))
	# Two slowly expanding rings make the player's location readable above dense
	# resource markers without adding a separate UI or world-space effect.
	for ring_index in range(2):
		var phase := fposmod(_boat_pulse_phase + float(ring_index) * 0.5, 1.0)
		var radius := lerpf(13.0, 46.0, phase)
		var alpha := (1.0 - phase) * 0.9
		draw_arc(point, radius, 0.0, TAU, 48, Color(0.30, 0.96, 1.0, alpha), 2.2, true)
	draw_circle(point, 12.0, Color(0.12, 0.82, 0.92, 0.35))
	draw_arc(point, 13.0, 0.0, TAU, 40, Color("#e9ffff"), 2.0, true)
	var forward := -_boat.global_transform.basis.z
	var screen_forward := Vector2(forward.x, -forward.z).normalized()
	if screen_forward.length_squared() < 0.1:
		screen_forward = Vector2.UP
	var side := Vector2(-screen_forward.y, screen_forward.x)
	var triangle := PackedVector2Array([
		point + screen_forward * 16.0,
		point - screen_forward * 11.0 + side * 10.0,
		point - screen_forward * 11.0 - side * 10.0,
	])
	draw_colored_polygon(triangle, Color("#f8ffff"))
	draw_polyline(PackedVector2Array([triangle[0], triangle[1], triangle[2], triangle[0]]), Color("#073847"), 3.5, true)
	draw_polyline(PackedVector2Array([triangle[0], triangle[1], triangle[2], triangle[0]]), Color("#52efff"), 1.5, true)
	var label_position := point + Vector2(22.0, -18.0)
	var label_rect := Rect2(label_position - Vector2(5.0, 15.0), Vector2(62.0, 23.0))
	draw_rect(label_rect, Color(0.015, 0.07, 0.09, 0.82), true)
	draw_rect(label_rect, Color(0.32, 0.91, 0.96, 0.8), false, 1.0)
	draw_string(get_theme_default_font(), label_position, "你在这里", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13, Color("#f2ffff"))


func _nearest_school(screen_position: Vector2) -> Dictionary:
	if not _map_rect.has_point(screen_position):
		return {}
	var nearest: Dictionary = {}
	var nearest_distance := 22.0
	for school in _schools:
		var world_position: Array = school["world_position"]
		var point := _world_to_map(Vector2(float(world_position[0]), -float(world_position[2])))
		var distance := point.distance_to(screen_position)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = school
	if _dolphins_enabled:
		for pod in _dolphins:
			var world_position: Array = pod.get("world_position", [])
			if world_position.size() < 3:
				continue
			var point := _world_to_map(Vector2(float(world_position[0]), -float(world_position[2])))
			var distance := point.distance_to(screen_position)
			if distance < nearest_distance:
				nearest_distance = distance
				nearest = pod
	return nearest


func _world_to_map(east_north: Vector2) -> Vector2:
	var map_rect := _get_world_map_rect()
	var scale := map_rect.size.x / maxf(_extent.size.x, 1.0)
	return Vector2(
		map_rect.position.x + (east_north.x - _extent.position.x) * scale,
		map_rect.position.y + (_extent.end.y - east_north.y) * scale
	)


func _get_world_map_rect() -> Rect2:
	var available := _map_rect.size - Vector2(16.0, 16.0)
	var scale := minf(available.x / maxf(_extent.size.x, 1.0), available.y / maxf(_extent.size.y, 1.0))
	var drawn_size := _extent.size * scale
	return Rect2(_map_rect.position + (_map_rect.size - drawn_size) * 0.5, drawn_size)


func _draw_scale_bar(font: Font) -> void:
	var scale := minf(
		(_map_rect.size.x - 16.0) / maxf(_extent.size.x, 1.0),
		(_map_rect.size.y - 16.0) / maxf(_extent.size.y, 1.0)
	)
	var bar_length := 20000.0 * scale
	var end := _map_rect.position + Vector2(_map_rect.size.x - 18.0, _map_rect.size.y - 18.0)
	var start := end - Vector2(bar_length, 0.0)
	draw_line(start, end, Color(0.92, 0.95, 0.88, 0.92), 2.0, true)
	draw_line(start + Vector2(0.0, -4.0), start + Vector2(0.0, 4.0), Color(0.92, 0.95, 0.88, 0.92), 1.0, true)
	draw_line(end + Vector2(0.0, -4.0), end + Vector2(0.0, 4.0), Color(0.92, 0.95, 0.88, 0.92), 1.0, true)
	draw_string(font, start + Vector2(0.0, -6.0), "20 km", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11, Color(0.9, 0.95, 0.9, 0.84))


func _depth_color(sample: Dictionary, x: int, y: int) -> Color:
	if not bool(sample.get("valid", false)):
		return UNKNOWN_COLOR.lightened(0.025 if posmod(x + y, 7) == 0 else 0.0)
	var depth := float(sample.get("depth_m", 0.0))
	var very_shallow := Color("#80b8a8")
	var shallow := Color("#6fae9e")
	var coastal := Color("#458c88")
	var shelf := Color("#2f6d7c")
	var deep := Color("#24546d")
	var very_deep := Color("#193d58")
	if depth < 2.0:
		return very_shallow.lerp(shallow, _smooth_fraction(depth / 2.0))
	if depth < 5.0:
		return shallow.lerp(coastal, _smooth_fraction((depth - 2.0) / 3.0))
	if depth < 10.0:
		return coastal.lerp(shelf, _smooth_fraction((depth - 5.0) / 5.0))
	if depth < 20.0:
		return shelf.lerp(deep, _smooth_fraction((depth - 10.0) / 10.0))
	return deep.lerp(very_deep, _smooth_fraction((depth - 20.0) / 15.0))


func _smooth_fraction(value: float) -> float:
	var t := clampf(value, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
