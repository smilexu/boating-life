extends Node3D

## Loads the offline, pre-triangulated OSM land mesh and provides a temporary
## top-down geospatial inspection mode. The sea and boat stay in the main scene.

const LANDMARKS := {
	"malmo": {"name": "Malmö", "latitude": 55.60587, "longitude": 13.00073, "color": Color(1.0, 0.75, 0.35)},
	"copenhagen": {"name": "Copenhagen", "latitude": 55.67605, "longitude": 12.56883, "color": Color(0.45, 0.88, 1.0)},
	"oresund_bridge": {"name": "Øresund Bridge · midpoint", "latitude": 55.57694, "longitude": 12.82333, "color": Color(1.0, 0.52, 0.56)},
}
const PEBERHOLM_LAYOUT_PATH := "res://resources/oresund_bridge_layout.json"
const PEBERHOLM_DEBUG_OUTLINE_MARGIN_M := 75.0
const PEBERHOLM_GROUND_SHADER := preload("res://shaders/peberholm_ground.gdshader")

@export var georeference: GeoReference
@export var peberholm_art_enabled := true
@export_file("*.json") var shoreline_data_path := "res://assets/geodata/processed/oresund_region.json"
@export_file("*.json") var terrain_manifest_path := "res://assets/terrain/processed/oresund_terrain/manifest.json"
@export_node_path("Node3D") var player_boat_path := NodePath("../PlayerBoat/MotionRoot")
@export_node_path("Camera3D") var player_camera_path := NodePath("../PlayerBoat/FollowCameraRig/Camera3D")
@export_range(0, 2, 1) var mesh_lod_index := 0
@export_range(0.2, 4.0, 0.1) var land_surface_height_m := 0.8
@export_range(1000.0, 10000.0, 500.0) var debug_grid_spacing_m := 5000.0
@export_range(-50.0, 50.0, 0.25) var terrain_vertical_offset_m := 0.0
@export_range(0.0, 5.0, 0.1) var terrain_coastal_floor_m := 0.5
@export_range(1000.0, 20000.0, 500.0) var minimum_map_zoom_size_m := 2000.0
@export_range(95000.0, 160000.0, 1000.0) var maximum_map_zoom_size_m := 120000.0
@export_range(0.5, 0.95, 0.01) var map_zoom_step := 0.82

@onready var _land_mesh_instance: MeshInstance3D = $Land
@onready var _terrain_chunks: Node3D = $TerrainChunks
@onready var _overview_camera: Camera3D = $OverviewCamera
@onready var _info_panel: PanelContainer = $DebugOverlay/InfoPanel
@onready var _info_label: Label = $DebugOverlay/InfoPanel/InfoLabel
@onready var _debug_overlay: CanvasLayer = $DebugOverlay

var _player_boat: Node3D
var _player_camera: Camera3D
var _debug_grid: MeshInstance3D
var _route_map_overlay: Control
var _route_manager: PortRouteManager
var _player_camera_rig: Node
var _markers: Array[Node3D] = []
var _map_debug_enabled := false
var _map_dragging := false
var _refresh_elapsed := 0.0
var _peberholm_outline := PackedVector2Array()
var _peberholm_render_debug_enabled := false
var _peberholm_material_splits_built := false
var _peberholm_terrain_splits: Array[Dictionary] = []
var _peberholm_debug_label: Label
var _peberholm_top_diagnostics: Dictionary = {}
var _peberholm_coast_diagnostics: Dictionary = {}
var _peberholm_body_diagnostics: Dictionary = {}
var _peberholm_flora: PeberholmFlora
var _peberholm_flora_diagnostics: Dictionary = {}


func _ready() -> void:
	_player_boat = get_node_or_null(player_boat_path) as Node3D
	_player_camera = get_node_or_null(player_camera_path) as Camera3D
	_player_camera_rig = get_node_or_null("../PlayerBoat/FollowCameraRig")
	_route_manager = get_node_or_null("../PortRouteManager") as PortRouteManager
	_build_route_map_overlay()
	_build_markers()
	_build_debug_grid()
	_peberholm_outline = _load_peberholm_outline()
	if _load_terrain_chunks():
		_land_mesh_instance.visible = false
	else:
		_load_land_mesh()
	var coast_loader := get_node_or_null("CoastTransitions") as CoastTransitionLoader
	if coast_loader != null and _peberholm_outline.size() >= 3:
		_peberholm_body_diagnostics = coast_loader.build_peberholm_closed_body(
			_peberholm_outline,
			PEBERHOLM_DEBUG_OUTLINE_MARGIN_M
		)
		if peberholm_art_enabled:
			_peberholm_coast_diagnostics = coast_loader.configure_peberholm_art(
				_peberholm_outline,
				PEBERHOLM_DEBUG_OUTLINE_MARGIN_M
			)
	_build_peberholm_terrain_material_splits()
	_peberholm_material_splits_built = true
	_build_peberholm_flora()
	_set_peberholm_render_debug(false)
	_build_peberholm_debug_label()
	_set_map_debug(false)
	_update_map_info()


func _process(delta: float) -> void:
	if Input.is_action_just_pressed("map_debug_toggle"):
		_set_map_debug(not _map_debug_enabled)
	if _map_debug_enabled:
		_refresh_elapsed += delta
		if _refresh_elapsed >= 0.25:
			_refresh_elapsed = fmod(_refresh_elapsed, 0.25)
			if not is_instance_valid(_player_boat):
				_player_boat = get_node_or_null(player_boat_path) as Node3D
				if _route_map_overlay != null and _route_map_overlay.has_method("set_player_boat"):
					_route_map_overlay.call("set_player_boat", _player_boat)
			_update_map_info()
			if _route_map_overlay != null:
				_route_map_overlay.queue_redraw()


func _input(event: InputEvent) -> void:
	if not _map_debug_enabled:
		return
	# F4 is a full-screen CanvasLayer UI. The M-map uses _input (before GUI
	# dispatch) for panning, so it must release mouse events while that UI is open.
	var fish_map := get_node_or_null("../FishResourceMap")
	if is_instance_valid(fish_map) and fish_map.has_method("is_map_open") and bool(fish_map.call("is_map_open")):
		_map_dragging = false
		Input.set_default_cursor_shape(Input.CURSOR_ARROW)
		return
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_LEFT:
			if mouse_event.pressed:
				if _info_panel.get_global_rect().has_point(mouse_event.position):
					return
				_map_dragging = true
				Input.set_default_cursor_shape(Input.CURSOR_MOVE)
				get_viewport().set_input_as_handled()
			elif _map_dragging:
				_map_dragging = false
				Input.set_default_cursor_shape(Input.CURSOR_ARROW)
				get_viewport().set_input_as_handled()
			return
		if not mouse_event.pressed:
			return
		if mouse_event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_map_at_cursor(map_zoom_step)
			get_viewport().set_input_as_handled()
		elif mouse_event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_map_at_cursor(1.0 / map_zoom_step)
			get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion and _map_dragging:
		_pan_map(event.relative)
		get_viewport().set_input_as_handled()


func toggle_peberholm_render_debug() -> bool:
	if not OS.is_debug_build():
		return false
	_set_peberholm_render_debug(not _peberholm_render_debug_enabled)
	return _peberholm_render_debug_enabled


func is_peberholm_render_debug_enabled() -> bool:
	return _peberholm_render_debug_enabled


func _load_peberholm_outline() -> PackedVector2Array:
	var outline := PackedVector2Array()
	if georeference == null or not FileAccess.file_exists(PEBERHOLM_LAYOUT_PATH):
		return outline
	var file := FileAccess.open(PEBERHOLM_LAYOUT_PATH, FileAccess.READ)
	if file == null:
		return outline
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		return outline
	var island: Dictionary = parsed.get("peberholm", {})
	var coordinates: Variant = island.get("outline_lat_lon", [])
	if not coordinates is Array:
		return outline
	for coordinate in coordinates:
		if not coordinate is Array or coordinate.size() < 2:
			continue
		var world := georeference.geodetic_to_world(float(coordinate[0]), float(coordinate[1]))
		outline.append(Vector2(world.x, world.z))
	return outline


func _build_peberholm_debug_label() -> void:
	var panel := PanelContainer.new()
	panel.name = "PeberholmRenderDiagnostics"
	panel.position = Vector2(14.0, 184.0)
	panel.custom_minimum_size = Vector2(590.0, 132.0)
	panel.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.025, 0.055, 0.065, 0.94)
	style.border_color = Color(0.26, 0.74, 0.62, 0.9)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left = 10.0
	style.content_margin_right = 10.0
	style.content_margin_top = 7.0
	style.content_margin_bottom = 7.0
	panel.add_theme_stylebox_override("panel", style)
	_peberholm_debug_label = Label.new()
	_peberholm_debug_label.name = "Readout"
	_peberholm_debug_label.add_theme_font_size_override("font_size", 13)
	_peberholm_debug_label.add_theme_color_override("font_color", Color(0.91, 0.97, 0.94))
	_peberholm_debug_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(_peberholm_debug_label)
	_debug_overlay.add_child(panel)


func _set_peberholm_render_debug(enabled: bool) -> void:
	if enabled and _peberholm_outline.size() < 3:
		push_warning("Peberholm render diagnostic: OSM outline could not be loaded.")
		return
	if enabled and not _peberholm_material_splits_built:
		_build_peberholm_terrain_material_splits()
		_peberholm_material_splits_built = true
	if enabled and _peberholm_terrain_splits.is_empty():
		push_warning("Peberholm render diagnostic: no runtime terrain triangles matched the OSM outline.")
		return
	var coast_loader := get_node_or_null("CoastTransitions") as CoastTransitionLoader
	if enabled and coast_loader == null:
		push_warning("Peberholm render diagnostic: CoastTransitionLoader is missing.")
		return
	_peberholm_render_debug_enabled = enabled
	var survey_outline := get_node_or_null("../OresundBridge/PeberholmOutline/Peberholm_OSM_Coastline_Outline") as MeshInstance3D
	if survey_outline != null:
		survey_outline.visible = enabled
	for split in _peberholm_terrain_splits:
		var source := split.get("source") as MeshInstance3D
		var remainder := split.get("remainder") as MeshInstance3D
		var focus := split.get("focus") as MeshInstance3D
		if is_instance_valid(source):
			source.visible = false
		if is_instance_valid(remainder):
			remainder.visible = true
		if is_instance_valid(focus):
			focus.visible = true
			focus.material_override = split["debug_material"] if enabled else split["normal_material"]
	if is_instance_valid(_peberholm_flora):
		_peberholm_flora.visible = not enabled
	if coast_loader != null:
		_peberholm_coast_diagnostics = coast_loader.set_peberholm_render_debug(
			enabled,
			_peberholm_outline,
			PEBERHOLM_DEBUG_OUTLINE_MARGIN_M
		)
	if _peberholm_debug_label != null:
		_peberholm_debug_label.get_parent().visible = enabled
		if enabled:
			_update_peberholm_debug_label()
	if enabled:
		print("[PeberholmRenderDebug] enabled; top=%s coast=%s" % [str(_peberholm_top_diagnostics), str(_peberholm_coast_diagnostics)])
	else:
		print("[PeberholmRenderDebug] disabled; local opaque terrain and coast materials restored.")


func get_peberholm_render_debug_diagnostics() -> Dictionary:
	return {
		"enabled": _peberholm_render_debug_enabled,
		"outline_points": _peberholm_outline.size(),
		"top": _peberholm_top_diagnostics.duplicate(true),
		"coast": _peberholm_coast_diagnostics.duplicate(true),
		"closed_body": _peberholm_body_diagnostics.duplicate(true),
		"flora": _peberholm_flora_diagnostics.duplicate(true),
	}


func _build_peberholm_flora() -> void:
	if not peberholm_art_enabled or _peberholm_outline.size() < 3 or _peberholm_terrain_splits.is_empty():
		return
	var top_instances: Array[MeshInstance3D] = []
	for split in _peberholm_terrain_splits:
		var focus := split.get("focus") as MeshInstance3D
		if is_instance_valid(focus) and focus.mesh != null:
			top_instances.append(focus)
	_peberholm_flora = PeberholmFlora.new()
	_peberholm_flora.name = "PeberholmLowVegetation"
	add_child(_peberholm_flora)
	_peberholm_flora_diagnostics = _peberholm_flora.build(_peberholm_outline, top_instances, self)


func _build_peberholm_terrain_material_splits() -> void:
	_peberholm_terrain_splits.clear()
	_peberholm_top_diagnostics = {"status": "no_match", "triangles": 0}
	var outline_rect := _get_outline_rect(_peberholm_outline)
	if outline_rect.size == Vector2.ZERO:
		return
	var margin := PEBERHOLM_DEBUG_OUTLINE_MARGIN_M
	var expanded_rect := outline_rect.grow(margin)
	var material := _make_peberholm_debug_material(Color(0.0, 1.0, 0.04, 1.0))
	var selected_triangle_count := 0
	var selected_height_min := INF
	var selected_height_max := -INF
	var selected_aabb := AABB()
	var selected_aabb_started := false
	var selected_source_paths := PackedStringArray()
	for child in _terrain_chunks.get_children():
		var source := child as MeshInstance3D
		if source == null or source.mesh == null or not source.name.begins_with("Terrain_"):
			continue
		var source_aabb := source.mesh.get_aabb()
		if not _aabb_rect(source_aabb).intersects(expanded_rect):
			continue
		var debug_vertices := PackedVector3Array()
		var debug_normals := PackedVector3Array()
		var debug_colors := PackedColorArray()
		var remainder_vertices := PackedVector3Array()
		var remainder_normals := PackedVector3Array()
		var remainder_colors := PackedColorArray()
		for surface in range(source.mesh.get_surface_count()):
			var arrays := source.mesh.surface_get_arrays(surface)
			var source_vertices := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
			var source_normals := arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array
			var source_colors := arrays[Mesh.ARRAY_COLOR] as PackedColorArray
			var source_indices := arrays[Mesh.ARRAY_INDEX] as PackedInt32Array
			for index in range(0, source_indices.size(), 3):
				var a_index := source_indices[index]
				var b_index := source_indices[index + 1]
				var c_index := source_indices[index + 2]
				var a := source_vertices[a_index]
				var b := source_vertices[b_index]
				var c := source_vertices[c_index]
				var center := Vector2((a.x + b.x + c.x) / 3.0, (a.z + b.z + c.z) / 3.0)
				var in_debug_region := expanded_rect.has_point(center) and _point_matches_peberholm(center, outline_rect, margin)
				if in_debug_region:
					_append_mesh_vertex(debug_vertices, debug_normals, debug_colors, a, source_normals[a_index], source_colors[a_index])
					_append_mesh_vertex(debug_vertices, debug_normals, debug_colors, b, source_normals[b_index], source_colors[b_index])
					_append_mesh_vertex(debug_vertices, debug_normals, debug_colors, c, source_normals[c_index], source_colors[c_index])
					selected_triangle_count += 1
					selected_height_min = minf(selected_height_min, minf(a.y, minf(b.y, c.y)))
					selected_height_max = maxf(selected_height_max, maxf(a.y, maxf(b.y, c.y)))
					for point in [a, b, c]:
						var point_aabb := AABB(point, Vector3.ZERO)
						if selected_aabb_started:
							selected_aabb = selected_aabb.merge(point_aabb)
						else:
							selected_aabb = point_aabb
							selected_aabb_started = true
				else:
					_append_mesh_vertex(remainder_vertices, remainder_normals, remainder_colors, a, source_normals[a_index], source_colors[a_index])
					_append_mesh_vertex(remainder_vertices, remainder_normals, remainder_colors, b, source_normals[b_index], source_colors[b_index])
					_append_mesh_vertex(remainder_vertices, remainder_normals, remainder_colors, c, source_normals[c_index], source_colors[c_index])
		if debug_vertices.is_empty():
			continue
		var remainder_mesh := _make_unindexed_mesh(remainder_vertices, remainder_normals, remainder_colors)
		var focus_mesh := _make_unindexed_mesh(debug_vertices, debug_normals, debug_colors)
		var remainder := _make_material_split_instance("%s_WithoutPeberholm" % source.name, remainder_mesh, source, source.material_override, false)
		var focus := _make_material_split_instance("%s_PeberholmTop" % source.name, focus_mesh, source, material, false)
		_terrain_chunks.add_child(remainder)
		_terrain_chunks.add_child(focus)
		# These existing triangles use the opposite winding to Godot primitives.
		# Correct only their material culling; retain positions, normals and face order.
		var normal_material: Material = _make_peberholm_ground_material() if peberholm_art_enabled else _make_terrain_material()
		if not peberholm_art_enabled:
			(normal_material as StandardMaterial3D).cull_mode = BaseMaterial3D.CULL_FRONT
		_peberholm_terrain_splits.append({"source": source, "remainder": remainder, "focus": focus, "debug_material": material, "normal_material": normal_material})
		selected_source_paths.append(str(source.get_meta("terrain_source_path", "runtime ArrayMesh")))
	_peberholm_top_diagnostics = {
		"status": "ready" if selected_triangle_count > 0 else "no_match",
		"source_paths": selected_source_paths,
		"triangles": selected_triangle_count,
		"height_min_m": selected_height_min,
		"height_max_m": selected_height_max,
		"local_aabb": selected_aabb,
		"world_aabb": _transform_aabb(global_transform, selected_aabb) if selected_aabb_started else AABB(),
		"visibility_layer": int((_peberholm_terrain_splits[0].get("focus") as MeshInstance3D).layers) if not _peberholm_terrain_splits.is_empty() else 0,
		"source_mesh_resource_path": "runtime ArrayMesh from OZTR binary chunks",
		"source_material": "opaque procedural grass/soil/gravel world shader; Peberholm winding compensated with CULL_FRONT",
	}


func _make_peberholm_ground_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = PEBERHOLM_GROUND_SHADER
	return material


func _point_matches_peberholm(point: Vector2, outline_rect: Rect2, margin_m: float) -> bool:
	if Geometry2D.is_point_in_polygon(point, _peberholm_outline):
		return true
	if not outline_rect.grow(margin_m).has_point(point):
		return false
	return _distance_to_outline(point) <= margin_m


func _distance_to_outline(point: Vector2) -> float:
	var closest_distance := INF
	for index in range(_peberholm_outline.size()):
		var first := _peberholm_outline[index]
		var second := _peberholm_outline[(index + 1) % _peberholm_outline.size()]
		var segment := second - first
		var length_squared := segment.length_squared()
		if length_squared <= 0.000001:
			closest_distance = minf(closest_distance, point.distance_to(first))
			continue
		var t := clampf((point - first).dot(segment) / length_squared, 0.0, 1.0)
		closest_distance = minf(closest_distance, point.distance_to(first + segment * t))
	return closest_distance


func _get_outline_rect(outline: PackedVector2Array) -> Rect2:
	if outline.is_empty():
		return Rect2()
	var minimum := outline[0]
	var maximum := outline[0]
	for point in outline:
		minimum.x = minf(minimum.x, point.x)
		minimum.y = minf(minimum.y, point.y)
		maximum.x = maxf(maximum.x, point.x)
		maximum.y = maxf(maximum.y, point.y)
	return Rect2(minimum, maximum - minimum)


func _aabb_rect(aabb: AABB) -> Rect2:
	return Rect2(Vector2(aabb.position.x, aabb.position.z), Vector2(aabb.size.x, aabb.size.z))


func _append_mesh_vertex(vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, vertex: Vector3, normal: Vector3, color: Color) -> void:
	vertices.append(vertex)
	normals.append(normal)
	colors.append(color)


func _make_unindexed_mesh(vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray) -> ArrayMesh:
	if vertices.size() < 3:
		return null
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _make_material_split_instance(node_name: String, mesh: ArrayMesh, source: MeshInstance3D, material: Material, initially_visible: bool) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.transform = source.transform
	instance.material_override = material
	instance.visible = initially_visible
	instance.layers = source.layers
	instance.cast_shadow = source.cast_shadow
	instance.visibility_range_begin = source.visibility_range_begin
	instance.visibility_range_end = source.visibility_range_end
	instance.visibility_range_fade_mode = source.visibility_range_fade_mode
	return instance


func _make_peberholm_debug_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.vertex_color_use_as_albedo = false
	material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


func _transform_aabb(transform: Transform3D, local_aabb: AABB) -> AABB:
	var minimum := Vector3(INF, INF, INF)
	var maximum := Vector3(-INF, -INF, -INF)
	for x_sign in range(2):
		for y_sign in range(2):
			for z_sign in range(2):
				var corner := local_aabb.position + Vector3(
					local_aabb.size.x * float(x_sign),
					local_aabb.size.y * float(y_sign),
					local_aabb.size.z * float(z_sign)
				)
				var world_corner := transform * corner
				minimum = minimum.min(world_corner)
				maximum = maximum.max(world_corner)
	return AABB(minimum, maximum - minimum)


func _update_peberholm_debug_label() -> void:
	if _peberholm_debug_label == null:
		return
	var top_aabb: AABB = _peberholm_top_diagnostics.get("world_aabb", AABB())
	var coast_aabb: AABB = _peberholm_coast_diagnostics.get("world_aabb", AABB())
	var top_sources := ", ".join(_peberholm_top_diagnostics.get("source_paths", PackedStringArray()))
	_peberholm_debug_label.text = (
		"PEBERHOLM RENDER DIAGNOSTIC · ON · F3 debug panel toggles this view\n"
		+ "Top: %s tris · Y %.2f..%.2f m · world X %.1f..%.1f / Z %.1f..%.1f · layer %d\n"
		+ "Source: %s · material: opaque, vertex-color, local CULL_FRONT\n"
		+ "Coast: %s tris · world Y %.2f..%.2f · layer %d · red debug material (unshaded, two-sided)\n"
		+ "Closed body: %s · side %s / bottom %s tris · bottom Y %.2f m"
	) % [
		int(_peberholm_top_diagnostics.get("triangles", 0)),
		float(_peberholm_top_diagnostics.get("height_min_m", 0.0)),
		float(_peberholm_top_diagnostics.get("height_max_m", 0.0)),
		top_aabb.position.x,
		top_aabb.end.x,
		top_aabb.position.z,
		top_aabb.end.z,
		int(_peberholm_top_diagnostics.get("visibility_layer", 0)),
		top_sources,
		int(_peberholm_coast_diagnostics.get("triangles", 0)),
		coast_aabb.position.y,
		coast_aabb.end.y,
		int(_peberholm_coast_diagnostics.get("visibility_layer", 0)),
		str(_peberholm_body_diagnostics.get("status", "not_built")),
		str(_peberholm_body_diagnostics.get("side_triangles", 0)),
		str(_peberholm_body_diagnostics.get("bottom_triangles", 0)),
		float(_peberholm_body_diagnostics.get("bottom_y_m", 0.0)),
	]


func _set_map_debug(enabled: bool) -> void:
	_map_debug_enabled = enabled
	if not enabled:
		_map_dragging = false
		Input.set_default_cursor_shape(Input.CURSOR_ARROW)
	_info_panel.visible = enabled
	_debug_grid.visible = enabled
	if _route_map_overlay != null:
		_route_map_overlay.visible = enabled
	for marker in _markers:
		marker.visible = enabled
	if enabled:
		if _player_camera_rig != null and _player_camera_rig.has_method("release_mouse_look"):
			_player_camera_rig.call("release_mouse_look")
		_overview_camera.make_current()
		if _route_map_overlay != null:
			_route_map_overlay.queue_redraw()
		_update_map_info()
	elif _player_camera != null:
		_player_camera.make_current()


func _build_route_map_overlay() -> void:
	var overlay := Control.new()
	overlay.name = "RouteMapOverlay"
	overlay.set_script(preload("res://scripts/oresund_route_map_overlay.gd"))
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.z_index = 5
	overlay.visible = false
	_debug_overlay.add_child(overlay)
	_route_map_overlay = overlay
	if overlay.has_method("configure"):
		overlay.call("configure", _route_manager, _overview_camera, georeference, _player_boat)
	if _route_manager == null:
		push_warning("M map route overlay: PortRouteManager is unavailable.")
		return
	_info_panel.z_index = 10


func _zoom_map_at_cursor(factor: float) -> void:
	var viewport := get_viewport()
	var cursor := viewport.get_mouse_position()
	var anchor_before := _map_plane_point_at_screen(cursor)
	_overview_camera.size = clampf(
		_overview_camera.size * factor,
		minimum_map_zoom_size_m,
		maximum_map_zoom_size_m
	)
	var anchor_after := _map_plane_point_at_screen(cursor)
	var camera_position := _overview_camera.global_position
	camera_position.x += anchor_before.x - anchor_after.x
	camera_position.z += anchor_before.y - anchor_after.y
	_overview_camera.global_position = camera_position
	if _route_map_overlay != null:
		_route_map_overlay.queue_redraw()
	viewport.set_input_as_handled()


func _pan_map(screen_delta: Vector2) -> void:
	var viewport_height := maxf(get_viewport().get_visible_rect().size.y, 1.0)
	var world_units_per_pixel := _overview_camera.size / viewport_height
	var camera_basis := _overview_camera.global_basis.orthonormalized()
	var movement := (-camera_basis.x * screen_delta.x + camera_basis.y * screen_delta.y) * world_units_per_pixel
	movement.y = 0.0
	_overview_camera.global_position += movement
	if _route_map_overlay != null:
		_route_map_overlay.queue_redraw()


func _map_plane_point_at_screen(screen_position: Vector2) -> Vector2:
	var ray_origin := _overview_camera.project_ray_origin(screen_position)
	var ray_direction := _overview_camera.project_ray_normal(screen_position)
	var map_plane_y := to_global(Vector3.ZERO).y
	if absf(ray_direction.y) < 0.00001:
		return Vector2(ray_origin.x, ray_origin.z)
	var distance := (map_plane_y - ray_origin.y) / ray_direction.y
	var world_point := ray_origin + ray_direction * distance
	return Vector2(world_point.x, world_point.z)


func _load_terrain_chunks() -> bool:
	if not FileAccess.file_exists(terrain_manifest_path):
		push_warning("Generated terrain is missing. Run .venv/bin/python tools/terrain/build_terrain.py --zoom 11")
		return false
	var manifest_file := FileAccess.open(terrain_manifest_path, FileAccess.READ)
	if manifest_file == null:
		push_error("Could not open terrain manifest: %s" % terrain_manifest_path)
		return false
	var parsed: Variant = JSON.parse_string(manifest_file.get_as_text())
	if not parsed is Dictionary or int(parsed.get("schema_version", -1)) != 1:
		push_error("Terrain manifest has an unsupported schema: %s" % terrain_manifest_path)
		return false
	var chunks: Array = parsed.get("chunks", [])
	if chunks.is_empty():
		push_error("Terrain manifest contains no generated chunks: %s" % terrain_manifest_path)
		return false
	var loaded_chunks: Array[Dictionary] = []
	for chunk_data in chunks:
		if not chunk_data is Dictionary or not chunk_data.has("file"):
			push_error("Terrain manifest contains an invalid chunk entry.")
			return false
		var chunk_path := terrain_manifest_path.get_base_dir().path_join(str(chunk_data["file"]))
		var chunk_mesh := _read_terrain_chunk(chunk_path)
		if chunk_mesh == null:
			return false
		loaded_chunks.append({"mesh": chunk_mesh, "file": str(chunk_data["file"])})
	var terrain_material := _make_terrain_material()
	for chunk_data in loaded_chunks:
		var chunk_instance := MeshInstance3D.new()
		chunk_instance.name = "Terrain_%s" % str(chunk_data["file"]).get_file().get_basename()
		chunk_instance.mesh = chunk_data["mesh"]
		chunk_instance.material_override = terrain_material
		chunk_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		chunk_instance.set_meta("terrain_source_path", terrain_manifest_path.get_base_dir().path_join(str(chunk_data["file"])))
		_terrain_chunks.add_child(chunk_instance)
	_terrain_chunks.visible = true
	return true


func _read_terrain_chunk(path: String) -> ArrayMesh:
	if not FileAccess.file_exists(path):
		push_error("Generated terrain chunk is missing: %s" % path)
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("Could not open generated terrain chunk: %s" % path)
		return null
	var data := file.get_buffer(file.get_length())
	if data.size() < 16 or data.slice(0, 4).get_string_from_ascii() != "OZTR":
		push_error("Generated terrain chunk has an invalid header: %s" % path)
		return null
	var format_version := data.decode_u32(4)
	var vertex_count := int(data.decode_u32(8))
	var index_count := int(data.decode_u32(12))
	var expected_size := 16 + vertex_count * 40 + index_count * 4
	if format_version != 1 or vertex_count < 3 or index_count < 3 or index_count % 3 != 0 or data.size() != expected_size:
		push_error("Generated terrain chunk has invalid counts or version: %s" % path)
		return null
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	vertices.resize(vertex_count)
	normals.resize(vertex_count)
	colors.resize(vertex_count)
	var offset := 16
	for index in range(vertex_count):
		var east := data.decode_float(offset)
		var height := maxf(data.decode_float(offset + 4) + terrain_vertical_offset_m, terrain_coastal_floor_m)
		var south := data.decode_float(offset + 8)
		vertices[index] = Vector3(east, height, south)
		normals[index] = Vector3(data.decode_float(offset + 12), data.decode_float(offset + 16), data.decode_float(offset + 20))
		colors[index] = Color(data.decode_float(offset + 24), data.decode_float(offset + 28), data.decode_float(offset + 32), data.decode_float(offset + 36))
		offset += 40
	var indices := PackedInt32Array()
	indices.resize(index_count)
	for index in range(index_count):
		var vertex_index := int(data.decode_u32(offset))
		if vertex_index >= vertex_count:
			push_error("Generated terrain chunk references a missing vertex: %s" % path)
			return null
		indices[index] = vertex_index
		offset += 4
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _make_terrain_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.WHITE
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	material.roughness = 0.96
	material.metallic = 0.0
	# The land surface is an open terrain sheet. CoastTransitionLoader now builds
	# actual seaward slopes from the same land mask; do not render the sheet's
	# underside through the water as a floating plate.
	material.cull_mode = BaseMaterial3D.CULL_BACK
	return material


func _load_land_mesh() -> void:
	if not FileAccess.file_exists(shoreline_data_path):
		push_warning("Øresund coastline data is not generated yet. Run tools/build_oresund_map.py --download when online.")
		return
	var file := FileAccess.open(shoreline_data_path, FileAccess.READ)
	if file == null:
		push_error("Could not open processed coastline data: %s" % shoreline_data_path)
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary or int(parsed.get("schema_version", -1)) != 1:
		push_error("Processed coastline data has an unsupported schema: %s" % shoreline_data_path)
		return
	var lods: Array = parsed.get("lods", [])
	if lods.is_empty():
		push_error("Processed coastline data contains no mesh LODs: %s" % shoreline_data_path)
		return
	var lod_index := clampi(mesh_lod_index, 0, lods.size() - 1)
	var lod: Dictionary = lods[lod_index]
	var source_vertices: Array = lod.get("vertices_east_north_m", [])
	var source_indices: Array = lod.get("indices", [])
	if source_vertices.is_empty() or source_indices.is_empty():
		push_error("Processed coastline LOD is empty: %s" % shoreline_data_path)
		return
	var vertices := PackedVector3Array()
	vertices.resize(source_vertices.size())
	for index in range(source_vertices.size()):
		var point: Array = source_vertices[index]
		vertices[index] = Vector3(float(point[0]), land_surface_height_m, -float(point[1]))
	var indices := PackedInt32Array()
	indices.resize(source_indices.size())
	for index in range(source_indices.size()):
		indices[index] = int(source_indices[index])
	var normals := PackedVector3Array()
	normals.resize(vertices.size())
	for index in range(normals.size()):
		normals[index] = Vector3.UP
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_land_mesh_instance.mesh = mesh
	_land_mesh_instance.visible = true
	_land_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_land_mesh_instance.material_override = _make_land_material()
	_land_mesh_instance.name = "OSM Land · LOD %d" % lod_index


func _build_markers() -> void:
	var marker_parent := Node3D.new()
	marker_parent.name = "ReferenceMarkers"
	add_child(marker_parent)
	for key in LANDMARKS:
		var data: Dictionary = LANDMARKS[key]
		var position := georeference.geodetic_to_world(float(data["latitude"]), float(data["longitude"]), 1.0)
		var marker := Node3D.new()
		marker.name = key
		marker.position = position
		marker.visible = false
		marker_parent.add_child(marker)

		var sphere := MeshInstance3D.new()
		sphere.name = "Marker"
		var sphere_mesh := SphereMesh.new()
		sphere_mesh.radius = 2.0
		sphere_mesh.height = 4.0
		sphere.mesh = sphere_mesh
		var marker_material := StandardMaterial3D.new()
		marker_material.albedo_color = data["color"]
		marker_material.roughness = 0.65
		sphere.material_override = marker_material
		sphere.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		marker.add_child(sphere)

		var label := Label3D.new()
		label.name = "Label"
		label.text = "%s\n%.5f° N, %.5f° E" % [data["name"], float(data["latitude"]), float(data["longitude"])]
		label.position = Vector3(0.0, 5.0, 0.0)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.font_size = 56
		label.pixel_size = 0.01
		label.outline_size = 10
		label.modulate = Color(0.97, 0.98, 0.94)
		marker.add_child(label)
		_markers.append(marker)

	var origin := Node3D.new()
	origin.name = "MapOrigin"
	origin.position = Vector3(0.0, 1.0, 0.0)
	origin.visible = false
	marker_parent.add_child(origin)
	var origin_visual := MeshInstance3D.new()
	var origin_mesh := BoxMesh.new()
	origin_mesh.size = Vector3(80.0, 0.8, 0.8)
	origin_visual.mesh = origin_mesh
	var origin_material := StandardMaterial3D.new()
	origin_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	origin_material.albedo_color = Color(1.0, 0.92, 0.35, 0.85)
	origin_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	origin_visual.material_override = origin_material
	origin_visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	origin.add_child(origin_visual)
	var north_axis := MeshInstance3D.new()
	var north_mesh := BoxMesh.new()
	north_mesh.size = Vector3(0.8, 0.8, 80.0)
	north_axis.mesh = north_mesh
	north_axis.material_override = origin_material
	north_axis.position.z = -40.0
	origin.add_child(north_axis)
	var origin_label := Label3D.new()
	origin_label.text = "MAP ORIGIN\n55.70000° N, 12.75000° E"
	origin_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	origin_label.font_size = 48
	origin_label.pixel_size = 0.01
	origin_label.position.y = 5.0
	origin_label.modulate = Color(1.0, 0.94, 0.55)
	origin.add_child(origin_label)
	_markers.append(origin)


func _build_debug_grid() -> void:
	var bounds := georeference.region_bounds_east_north()
	var east_min := bounds.position.x
	var east_max := bounds.end.x
	var north_min := bounds.position.y
	var north_max := bounds.end.y
	var interval := debug_grid_spacing_m
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.75, 0.91, 0.88, 0.18)
	material.no_depth_test = true
	var grid_mesh := ImmediateMesh.new()
	grid_mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	var first_east := ceilf(east_min / interval) * interval
	var first_north := ceilf(north_min / interval) * interval
	for east in range(roundi(first_east), floori(east_max), roundi(interval)):
		grid_mesh.surface_add_vertex(Vector3(east, 0.25, -north_min))
		grid_mesh.surface_add_vertex(Vector3(east, 0.25, -north_max))
	for north in range(roundi(first_north), floori(north_max), roundi(interval)):
		grid_mesh.surface_add_vertex(Vector3(east_min, 0.25, -north))
		grid_mesh.surface_add_vertex(Vector3(east_max, 0.25, -north))
	grid_mesh.surface_end()
	_debug_grid = MeshInstance3D.new()
	_debug_grid.name = "LocalCoordinateGrid"
	_debug_grid.mesh = grid_mesh
	_debug_grid.visible = false
	_debug_grid.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_debug_grid)


func _make_land_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.31, 0.39, 0.29)
	material.roughness = 0.94
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


func _update_map_info() -> void:
	if georeference == null:
		_info_label.text = "Map debug unavailable: GeoReference is not assigned."
		return
	var malmo_data: Dictionary = LANDMARKS["malmo"]
	var copenhagen_data: Dictionary = LANDMARKS["copenhagen"]
	var malmo := georeference.geodetic_to_world(float(malmo_data["latitude"]), float(malmo_data["longitude"]))
	var copenhagen := georeference.geodetic_to_world(float(copenhagen_data["latitude"]), float(copenhagen_data["longitude"]))
	var separation := Vector2(malmo.x - copenhagen.x, malmo.z - copenhagen.z)
	var boat_text := "Boat: unavailable"
	if _player_boat != null:
		var local_boat_position := to_local(_player_boat.global_position)
		var coordinates := georeference.world_to_geodetic(local_boat_position)
		boat_text = "Boat WGS84: %.5f° N, %.5f° E" % [coordinates.x, coordinates.y]
	_info_label.text = "MAP DEBUG  ·  M 返回船尾镜头  ·  滚轮缩放  ·  左键拖动\n"
	_info_label.text += "原点 55.70000° N, 12.75000° E  ·  网格 %.0f m\n" % debug_grid_spacing_m
	_info_label.text += "当前纵向地图范围：%.1f km\n" % (_overview_camera.size / 1000.0)
	_info_label.text += "Malmö: ΔE %+.1f km  ΔN %+.1f km\n" % [malmo.x / 1000.0, -malmo.z / 1000.0]
	_info_label.text += "Copenhagen: ΔE %+.1f km  ΔN %+.1f km\n" % [copenhagen.x / 1000.0, -copenhagen.z / 1000.0]
	_info_label.text += "两地直线距离：%.1f km\n" % (separation.length() / 1000.0)
	_info_label.text += _get_route_legend_text()
	_info_label.text += "橙色船形标记：本船当前位置与航向\n"
	_info_label.text += boat_text + "\n© OpenStreetMap contributors · ODbL-1.0"
	_info_label.text += "\n© Mapzen / Tilezen · EU-DEM / Copernicus"


func _get_route_legend_text() -> String:
	if _route_manager == null:
		return "路线：不可用\n"
	var lines := "航线（实线=游戏内已验证，虚线=待复核；双向线略微错开显示）：\n"
	for route in _route_manager.get_routes():
		if route == null:
			continue
		var status := "已验证" if _route_manager.is_route_cruise_eligible(route) else "待复核/禁用"
		lines += "· %s  %s\n" % [route.display_name, status]
	return lines
