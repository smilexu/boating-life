extends Node3D

## Loads the offline, pre-triangulated OSM land mesh and provides a temporary
## top-down geospatial inspection mode. The sea and boat stay in the main scene.

const LANDMARKS := {
	"malmo": {"name": "Malmö", "latitude": 55.60587, "longitude": 13.00073, "color": Color(1.0, 0.75, 0.35)},
	"copenhagen": {"name": "Copenhagen", "latitude": 55.67605, "longitude": 12.56883, "color": Color(0.45, 0.88, 1.0)},
	"oresund_bridge": {"name": "Øresund Bridge · midpoint", "latitude": 55.57694, "longitude": 12.82333, "color": Color(1.0, 0.52, 0.56)},
}

@export var georeference: GeoReference
@export_file("*.json") var shoreline_data_path := "res://assets/geodata/processed/oresund_region.json"
@export_node_path("Node3D") var player_boat_path := NodePath("../PlayerBoat/MotionRoot")
@export_node_path("Camera3D") var player_camera_path := NodePath("../PlayerBoat/FollowCameraRig/Camera3D")
@export_range(0, 2, 1) var mesh_lod_index := 0
@export_range(0.2, 4.0, 0.1) var land_surface_height_m := 0.8
@export_range(1000.0, 10000.0, 500.0) var debug_grid_spacing_m := 5000.0

@onready var _land_mesh_instance: MeshInstance3D = $Land
@onready var _overview_camera: Camera3D = $OverviewCamera
@onready var _info_panel: PanelContainer = $DebugOverlay/InfoPanel
@onready var _info_label: Label = $DebugOverlay/InfoPanel/InfoLabel
@onready var _debug_overlay: CanvasLayer = $DebugOverlay

var _player_boat: Node3D
var _player_camera: Camera3D
var _debug_grid: MeshInstance3D
var _boat_map_marker: Control
var _markers: Array[Node3D] = []
var _map_debug_enabled := false
var _refresh_elapsed := 0.0


func _ready() -> void:
	_player_boat = get_node_or_null(player_boat_path) as Node3D
	_player_camera = get_node_or_null(player_camera_path) as Camera3D
	_build_boat_map_marker()
	_build_markers()
	_build_debug_grid()
	_load_land_mesh()
	_set_map_debug(false)
	_update_map_info()


func _process(delta: float) -> void:
	if Input.is_action_just_pressed("map_debug_toggle"):
		_set_map_debug(not _map_debug_enabled)
	if _map_debug_enabled:
		_update_boat_map_marker()
		_refresh_elapsed += delta
		if _refresh_elapsed >= 0.25:
			_refresh_elapsed = fmod(_refresh_elapsed, 0.25)
			_update_map_info()


func _set_map_debug(enabled: bool) -> void:
	_map_debug_enabled = enabled
	_info_panel.visible = enabled
	_debug_grid.visible = enabled
	_boat_map_marker.visible = enabled
	for marker in _markers:
		marker.visible = enabled
	if enabled:
		_overview_camera.make_current()
		_update_map_info()
	elif _player_camera != null:
		_player_camera.make_current()
	if enabled:
		_update_boat_map_marker()


func _build_boat_map_marker() -> void:
	# This marker is drawn in screen space so it stays readable at the 95 km map zoom.
	var marker := Control.new()
	marker.name = "BoatMapMarker"
	marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	marker.custom_minimum_size = Vector2(120.0, 36.0)
	marker.size = marker.custom_minimum_size
	marker.z_index = 20
	marker.visible = false
	_debug_overlay.add_child(marker)
	_boat_map_marker = marker

	var dot := PanelContainer.new()
	dot.name = "PositionDot"
	dot.position = Vector2(-6.0, -6.0)
	dot.custom_minimum_size = Vector2(12.0, 12.0)
	dot.size = dot.custom_minimum_size
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dot_style := StyleBoxFlat.new()
	dot_style.bg_color = Color(1.0, 0.48, 0.16, 1.0)
	dot_style.border_color = Color(0.10, 0.16, 0.18, 1.0)
	dot_style.set_border_width_all(2)
	dot_style.set_corner_radius_all(6)
	dot.add_theme_stylebox_override("panel", dot_style)
	marker.add_child(dot)

	var tag := PanelContainer.new()
	tag.name = "PositionLabel"
	tag.position = Vector2(14.0, -15.0)
	tag.custom_minimum_size = Vector2(72.0, 28.0)
	tag.size = tag.custom_minimum_size
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tag_style := StyleBoxFlat.new()
	tag_style.bg_color = Color(0.035, 0.09, 0.13, 0.92)
	tag_style.border_color = Color(1.0, 0.48, 0.16, 0.95)
	tag_style.set_border_width_all(1)
	tag_style.set_corner_radius_all(6)
	tag_style.content_margin_left = 8.0
	tag_style.content_margin_right = 8.0
	tag_style.content_margin_top = 3.0
	tag_style.content_margin_bottom = 3.0
	tag.add_theme_stylebox_override("panel", tag_style)
	var label := Label.new()
	label.text = "船只"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", Color(1.0, 0.86, 0.68))
	label.add_theme_font_size_override("font_size", 15)
	tag.add_child(label)
	marker.add_child(tag)


func _update_boat_map_marker() -> void:
	if _boat_map_marker == null or _player_boat == null or not _map_debug_enabled:
		if _boat_map_marker != null:
			_boat_map_marker.visible = false
		return
	var world_position := _player_boat.global_position
	if _overview_camera.is_position_behind(world_position):
		_boat_map_marker.visible = false
		return
	var screen_position := _overview_camera.unproject_position(world_position)
	var visible_rect := get_viewport().get_visible_rect()
	if not visible_rect.has_point(screen_position):
		_boat_map_marker.visible = false
		return
	_boat_map_marker.position = screen_position
	_boat_map_marker.visible = true


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
	_info_label.text = "MAP DEBUG  ·  M 返回船尾镜头\n"
	_info_label.text += "原点 55.70000° N, 12.75000° E  ·  网格 %.0f m\n" % debug_grid_spacing_m
	_info_label.text += "Malmö: ΔE %+.1f km  ΔN %+.1f km\n" % [malmo.x / 1000.0, -malmo.z / 1000.0]
	_info_label.text += "Copenhagen: ΔE %+.1f km  ΔN %+.1f km\n" % [copenhagen.x / 1000.0, -copenhagen.z / 1000.0]
	_info_label.text += "两地直线距离：%.1f km\n" % (separation.length() / 1000.0)
	_info_label.text += boat_text + "\n© OpenStreetMap contributors · ODbL-1.0"
