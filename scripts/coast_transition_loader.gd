class_name CoastTransitionLoader
extends Node3D

## Loads the offline, OSM-matched coast transition mesh. The builder scans and
## triangulates terrain boundaries once; this node does no per-frame work.

@export_file("*.bin") var mesh_path := "res://assets/terrain/processed/oresund_terrain/coast_transition.bin"
@export_file("*.json") var metadata_path := "res://assets/terrain/processed/oresund_terrain/coast_transition.json"

const PEBERHOLM_BODY_BOTTOM_Y_M := -2.5
const PEBERHOLM_COAST_TOE_Y_M := -0.3
const PEBERHOLM_BODY_VERTEX_QUANTIZATION := 1000.0
const PEBERHOLM_COAST_SHADER := preload("res://shaders/peberholm_coast.gdshader")

var _diagnostics: Dictionary = {"status": "pending"}
var _mesh_instance: MeshInstance3D
var _peberholm_split_ready := false
var _peberholm_remainder_instance: MeshInstance3D
var _peberholm_debug_instance: MeshInstance3D
var _peberholm_debug_material: StandardMaterial3D
var _peberholm_art_material: ShaderMaterial
var _peberholm_diagnostics: Dictionary = {"status": "not_built", "triangles": 0}
var _peberholm_body_instance: MeshInstance3D
var _peberholm_body_diagnostics: Dictionary = {"status": "not_built"}


func _ready() -> void:
	_load_transition_mesh()


func get_diagnostics() -> Dictionary:
	return _diagnostics.duplicate(true)


func get_peberholm_debug_diagnostics() -> Dictionary:
	return _peberholm_diagnostics.duplicate(true)


func get_peberholm_body_diagnostics() -> Dictionary:
	return _peberholm_body_diagnostics.duplicate(true)


func configure_peberholm_art(outline: PackedVector2Array, outline_margin_m: float = 75.0) -> Dictionary:
	if _mesh_instance == null or outline.size() < 3:
		_peberholm_diagnostics = {"status": "source_missing", "triangles": 0}
		return get_peberholm_debug_diagnostics()
	if not _peberholm_split_ready:
		_build_peberholm_debug_split(outline, outline_margin_m)
	if _peberholm_debug_instance == null or _peberholm_remainder_instance == null:
		return get_peberholm_debug_diagnostics()
	_peberholm_art_material = ShaderMaterial.new()
	_peberholm_art_material.shader = PEBERHOLM_COAST_SHADER
	_peberholm_debug_instance.name = "PeberholmCoastTransition_Art"
	_peberholm_debug_instance.material_override = _peberholm_art_material
	_peberholm_debug_instance.visible = true
	_peberholm_remainder_instance.visible = true
	_peberholm_diagnostics["material"] = "opaque world-space cellular gravel shader; island coast only"
	return get_peberholm_debug_diagnostics()


# Reuse the loaded transition mesh's exact Peberholm toe ring so the added
# underwater wall meets the existing slope without a guessed horizontal offset.
func build_peberholm_closed_body(outline: PackedVector2Array, outline_margin_m: float = 75.0) -> Dictionary:
	if _peberholm_body_instance != null:
		return get_peberholm_body_diagnostics()
	if _mesh_instance == null or _mesh_instance.mesh == null or outline.size() < 3:
		_peberholm_body_diagnostics = {"status": "source_missing"}
		return get_peberholm_body_diagnostics()
	var mesh := _mesh_instance.mesh as ArrayMesh
	if mesh == null or mesh.get_surface_count() == 0:
		_peberholm_body_diagnostics = {"status": "unsupported_source_mesh"}
		return get_peberholm_body_diagnostics()
	var arrays := mesh.surface_get_arrays(0)
	var source_vertices := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
	var source_indices := arrays[Mesh.ARRAY_INDEX] as PackedInt32Array
	var bounds := _outline_bounds(outline).grow(outline_margin_m)
	var selected_edges: Dictionary = {}
	var selected_triangle_count := 0
	for index in range(0, source_indices.size(), 3):
		var first_index := source_indices[index]
		var second_index := source_indices[index + 1]
		var third_index := source_indices[index + 2]
		var first := source_vertices[first_index]
		var second := source_vertices[second_index]
		var third := source_vertices[third_index]
		var center := Vector2((first.x + second.x + third.x) / 3.0, (first.z + second.z + third.z) / 3.0)
		if not bounds.has_point(center) or _distance_to_outline(center, outline) > outline_margin_m:
			continue
		selected_triangle_count += 1
		_add_selected_edge(selected_edges, first_index, second_index)
		_add_selected_edge(selected_edges, second_index, third_index)
		_add_selected_edge(selected_edges, third_index, first_index)
	if selected_triangle_count == 0:
		_peberholm_body_diagnostics = {"status": "no_coast_match", "selected_coast_triangles": 0}
		return get_peberholm_body_diagnostics()
	var toe_boundary_edge_count := 0
	var adjacency: Dictionary = {}
	var toe_positions: Dictionary = {}
	for edge_data in selected_edges.values():
		if int(edge_data["count"]) != 1:
			continue
		var first: Vector3 = source_vertices[int(edge_data["first_index"])]
		var second: Vector3 = source_vertices[int(edge_data["second_index"])]
		if absf(first.y - PEBERHOLM_COAST_TOE_Y_M) > 0.025 or absf(second.y - PEBERHOLM_COAST_TOE_Y_M) > 0.025:
			continue
		var first_key := _quantized_xz(first)
		var second_key := _quantized_xz(second)
		if first_key == second_key:
			continue
		toe_positions[first_key] = Vector3(first.x, PEBERHOLM_COAST_TOE_Y_M, first.z)
		toe_positions[second_key] = Vector3(second.x, PEBERHOLM_COAST_TOE_Y_M, second.z)
		_add_neighbor(adjacency, first_key, second_key)
		_add_neighbor(adjacency, second_key, first_key)
		toe_boundary_edge_count += 1
	var ordered_loop := _order_closed_loop(adjacency)
	if ordered_loop.size() < 3 or ordered_loop.size() != toe_positions.size() or toe_boundary_edge_count != ordered_loop.size():
		_peberholm_body_diagnostics = {
			"status": "toe_boundary_not_closed",
			"selected_coast_triangles": selected_triangle_count,
			"toe_boundary_edges": toe_boundary_edge_count,
			"toe_boundary_vertices": toe_positions.size(),
			"ordered_loop_vertices": ordered_loop.size(),
		}
		push_warning("Peberholm closed body: coast toe boundary was not one continuous closed loop; no body mesh was added.")
		return get_peberholm_body_diagnostics()
	var toe_polygon := PackedVector2Array()
	for key in ordered_loop:
		var position: Vector3 = toe_positions[key]
		toe_polygon.append(Vector2(position.x, position.z))
	var cap_indices := Geometry2D.triangulate_polygon(toe_polygon)
	if cap_indices.size() < (toe_polygon.size() - 2) * 3:
		_peberholm_body_diagnostics = {
			"status": "bottom_triangulation_failed",
			"toe_boundary_vertices": toe_polygon.size(),
			"bottom_triangles": cap_indices.size() / 3,
		}
		push_warning("Peberholm closed body: could not triangulate the submerged bottom cap.")
		return get_peberholm_body_diagnostics()
	var side_vertices := PackedVector3Array()
	var side_normals := PackedVector3Array()
	var bottom_vertices := PackedVector3Array()
	var bottom_normals := PackedVector3Array()
	var polygon_area := _signed_area(toe_polygon)
	for index in range(ordered_loop.size()):
		var first_key: Vector2i = ordered_loop[index]
		var second_key: Vector2i = ordered_loop[(index + 1) % ordered_loop.size()]
		var first_top: Vector3 = toe_positions[first_key]
		var second_top: Vector3 = toe_positions[second_key]
		var first_bottom := Vector3(first_top.x, PEBERHOLM_BODY_BOTTOM_Y_M, first_top.z)
		var second_bottom := Vector3(second_top.x, PEBERHOLM_BODY_BOTTOM_Y_M, second_top.z)
		var tangent := second_top - first_top
		var expected_outward := Vector3(tangent.z, 0.0, -tangent.x)
		if polygon_area < 0.0:
			expected_outward = -expected_outward
		_append_flat_triangle(side_vertices, side_normals, first_top, second_top, second_bottom, expected_outward)
		_append_flat_triangle(side_vertices, side_normals, first_top, second_bottom, first_bottom, expected_outward)
	for index in range(0, cap_indices.size(), 3):
		var first := toe_polygon[cap_indices[index]]
		var second := toe_polygon[cap_indices[index + 1]]
		var third := toe_polygon[cap_indices[index + 2]]
		_append_flat_triangle(
			bottom_vertices,
			bottom_normals,
			Vector3(first.x, PEBERHOLM_BODY_BOTTOM_Y_M, first.y),
			Vector3(second.x, PEBERHOLM_BODY_BOTTOM_Y_M, second.y),
			Vector3(third.x, PEBERHOLM_BODY_BOTTOM_Y_M, third.y),
			Vector3.DOWN
		)
	if side_vertices.is_empty() or bottom_vertices.is_empty():
		_peberholm_body_diagnostics = {"status": "empty_body_mesh"}
		return get_peberholm_body_diagnostics()
	var body_mesh := ArrayMesh.new()
	body_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _triangle_surface_arrays(side_vertices, side_normals))
	body_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _triangle_surface_arrays(bottom_vertices, bottom_normals))
	var side_material := _make_body_material(Color(0.40, 0.43, 0.37))
	var bottom_material := _make_body_material(Color(0.30, 0.34, 0.32))
	body_mesh.surface_set_material(0, side_material)
	body_mesh.surface_set_material(1, bottom_material)
	_peberholm_body_instance = MeshInstance3D.new()
	_peberholm_body_instance.name = "PeberholmClosedUnderbody"
	_peberholm_body_instance.mesh = body_mesh
	_peberholm_body_instance.layers = _mesh_instance.layers
	_peberholm_body_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_peberholm_body_instance.transform = _mesh_instance.transform
	add_child(_peberholm_body_instance)
	var body_aabb := body_mesh.get_aabb()
	_peberholm_body_diagnostics = {
		"status": "closed_body_added",
		"source_path": mesh_path,
		"selected_coast_triangles": selected_triangle_count,
		"toe_boundary_edges": toe_boundary_edge_count,
		"toe_boundary_vertices": toe_polygon.size(),
		"side_triangles": side_vertices.size() / 3,
		"bottom_triangles": bottom_vertices.size() / 3,
		"bottom_y_m": PEBERHOLM_BODY_BOTTOM_Y_M,
		"coast_toe_y_m": PEBERHOLM_COAST_TOE_Y_M,
		"body_local_aabb": body_aabb,
		"body_world_aabb": _transform_aabb(_mesh_instance.global_transform, body_aabb),
		"material": "opaque unshaded gray; back-face culling disabled",
	}
	print("[PeberholmClosedBody] %d toe edges, %d side triangles, %d bottom triangles; closed at Y=%.2f m." % [
		toe_boundary_edge_count,
		side_vertices.size() / 3,
		bottom_vertices.size() / 3,
		PEBERHOLM_BODY_BOTTOM_Y_M,
	])
	return get_peberholm_body_diagnostics()


func _add_selected_edge(edges: Dictionary, first_index: int, second_index: int) -> void:
	var key := "%d:%d" % [mini(first_index, second_index), maxi(first_index, second_index)]
	if edges.has(key):
		var edge_data: Dictionary = edges[key]
		edge_data["count"] = int(edge_data["count"]) + 1
		edges[key] = edge_data
	else:
		edges[key] = {
			"count": 1,
			"first_index": first_index,
			"second_index": second_index,
		}


func _quantized_xz(position: Vector3) -> Vector2i:
	return Vector2i(
		roundi(position.x * PEBERHOLM_BODY_VERTEX_QUANTIZATION),
		roundi(position.z * PEBERHOLM_BODY_VERTEX_QUANTIZATION)
	)


func _add_neighbor(adjacency: Dictionary, key: Vector2i, neighbor: Vector2i) -> void:
	if not adjacency.has(key):
		adjacency[key] = []
	var neighbors: Array = adjacency[key]
	if not neighbors.has(neighbor):
		neighbors.append(neighbor)
	adjacency[key] = neighbors


func _order_closed_loop(adjacency: Dictionary) -> Array[Vector2i]:
	var ordered: Array[Vector2i] = []
	if adjacency.is_empty():
		return ordered
	for key in adjacency:
		var neighbors: Array = adjacency[key]
		if neighbors.size() != 2:
			return ordered
	var start_key: Vector2i = adjacency.keys()[0]
	var previous_key := Vector2i(2147483647, 2147483647)
	var current_key := start_key
	for _step in range(adjacency.size() + 1):
		if ordered.has(current_key):
			return []
		ordered.append(current_key)
		var neighbors: Array = adjacency[current_key]
		var next_key: Vector2i = neighbors[0] if neighbors[0] != previous_key else neighbors[1]
		if next_key == start_key:
			break
		previous_key = current_key
		current_key = next_key
	if ordered.size() != adjacency.size():
		return []
	return ordered


func _signed_area(polygon: PackedVector2Array) -> float:
	var area := 0.0
	for index in range(polygon.size()):
		var first := polygon[index]
		var second := polygon[(index + 1) % polygon.size()]
		area += first.x * second.y - second.x * first.y
	return area * 0.5


func _append_flat_triangle(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	first: Vector3,
	second: Vector3,
	third: Vector3,
	expected_normal: Vector3
) -> void:
	var face_normal := (second - first).cross(third - first)
	if face_normal.length_squared() < 0.000001:
		return
	if expected_normal.length_squared() > 0.000001 and face_normal.dot(expected_normal) < 0.0:
		var swap := second
		second = third
		third = swap
		face_normal = -face_normal
	var normal := face_normal.normalized()
	vertices.append(first)
	vertices.append(second)
	vertices.append(third)
	normals.append(normal)
	normals.append(normal)
	normals.append(normal)


func _triangle_surface_arrays(vertices: PackedVector3Array, normals: PackedVector3Array) -> Array:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	return arrays


func _make_body_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.roughness = 1.0
	return material


func set_peberholm_render_debug(enabled: bool, outline: PackedVector2Array, outline_margin_m: float = 75.0) -> Dictionary:
	if _mesh_instance == null or outline.size() < 3:
		_peberholm_diagnostics = {"status": "source_missing", "triangles": 0}
		return get_peberholm_debug_diagnostics()
	if enabled and not _peberholm_split_ready:
		_build_peberholm_debug_split(outline, outline_margin_m)
	if enabled and (_peberholm_debug_instance == null or _peberholm_remainder_instance == null):
		return get_peberholm_debug_diagnostics()
	_mesh_instance.visible = true
	if _peberholm_remainder_instance != null:
		_peberholm_remainder_instance.visible = true
	if _peberholm_debug_instance != null:
		_peberholm_debug_instance.visible = enabled
		if not enabled and _peberholm_art_material != null:
			_peberholm_debug_instance.visible = true
			_peberholm_debug_instance.material_override = _peberholm_art_material
		elif enabled:
			_peberholm_debug_instance.visible = true
			_peberholm_debug_instance.material_override = _peberholm_debug_material
	if not enabled:
		_peberholm_diagnostics["status"] = "off"
	return get_peberholm_debug_diagnostics()


func _build_peberholm_debug_split(outline: PackedVector2Array, outline_margin_m: float) -> void:
	_peberholm_split_ready = true
	var arrays := _mesh_instance.mesh.surface_get_arrays(0)
	var source_vertices := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
	var source_normals := arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array
	var source_colors := arrays[Mesh.ARRAY_COLOR] as PackedColorArray
	var source_indices := arrays[Mesh.ARRAY_INDEX] as PackedInt32Array
	var bounds := _outline_bounds(outline).grow(outline_margin_m)
	var target_vertices := PackedVector3Array()
	var target_normals := PackedVector3Array()
	var target_colors := PackedColorArray()
	var remainder_vertices := PackedVector3Array()
	var remainder_normals := PackedVector3Array()
	var remainder_colors := PackedColorArray()
	var target_triangle_count := 0
	var remainder_triangle_count := 0
	for index in range(0, source_indices.size(), 3):
		var a_index := source_indices[index]
		var b_index := source_indices[index + 1]
		var c_index := source_indices[index + 2]
		var a := source_vertices[a_index]
		var b := source_vertices[b_index]
		var c := source_vertices[c_index]
		var center := Vector2((a.x + b.x + c.x) / 3.0, (a.z + b.z + c.z) / 3.0)
		var is_peberholm_coast := bounds.has_point(center) and _distance_to_outline(center, outline) <= outline_margin_m
		if is_peberholm_coast:
			_append_vertex(target_vertices, target_normals, target_colors, a, source_normals[a_index], source_colors[a_index])
			_append_vertex(target_vertices, target_normals, target_colors, b, source_normals[b_index], source_colors[b_index])
			_append_vertex(target_vertices, target_normals, target_colors, c, source_normals[c_index], source_colors[c_index])
			target_triangle_count += 1
		else:
			_append_vertex(remainder_vertices, remainder_normals, remainder_colors, a, source_normals[a_index], source_colors[a_index])
			_append_vertex(remainder_vertices, remainder_normals, remainder_colors, b, source_normals[b_index], source_colors[b_index])
			_append_vertex(remainder_vertices, remainder_normals, remainder_colors, c, source_normals[c_index], source_colors[c_index])
			remainder_triangle_count += 1
	if target_triangle_count == 0:
		_peberholm_diagnostics = {
			"status": "no_match",
			"source_path": mesh_path,
			"triangles": 0,
			"source_triangles": source_indices.size() / 3,
		}
		return
	var remainder_mesh := _make_unindexed_mesh(remainder_vertices, remainder_normals, remainder_colors)
	var focus_mesh := _make_unindexed_mesh(target_vertices, target_normals, target_colors)
	_peberholm_debug_material = StandardMaterial3D.new()
	_peberholm_debug_material.albedo_color = Color(1.0, 0.015, 0.015, 1.0)
	_peberholm_debug_material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	_peberholm_debug_material.vertex_color_use_as_albedo = false
	_peberholm_debug_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_peberholm_debug_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Replace the source mesh with its exact non-island remainder, then render the
	# selected island triangles in one local art/debug instance. Source vertices
	# and triangle coordinates are copied unchanged; this keeps the material local.
	_mesh_instance.mesh = remainder_mesh
	_mesh_instance.material_override = _make_material()
	_mesh_instance.visible = true
	_peberholm_remainder_instance = _mesh_instance
	_peberholm_art_material = ShaderMaterial.new()
	_peberholm_art_material.shader = PEBERHOLM_COAST_SHADER
	_peberholm_debug_instance = _make_split_instance("PeberholmCoastTransition_Art", focus_mesh, _mesh_instance, _peberholm_art_material)
	_peberholm_debug_instance.visible = true
	add_child(_peberholm_debug_instance)
	_peberholm_diagnostics = {
		"status": "ready",
		"source_path": mesh_path,
		"source_mesh_resource_path": _mesh_instance.mesh.resource_path,
		"source_triangles": source_indices.size() / 3,
		"triangles": target_triangle_count,
		"remainder_triangles": remainder_triangle_count,
		"local_aabb": focus_mesh.get_aabb(),
		"world_aabb": _transform_aabb(_mesh_instance.global_transform, focus_mesh.get_aabb()),
		"visibility_layer": _peberholm_debug_instance.layers,
		"source_material": "opaque vertex-color remainder; island triangles use local procedural gravel shader",
		"partition_preserved": target_triangle_count + remainder_triangle_count == source_indices.size() / 3,
	}


func _outline_bounds(outline: PackedVector2Array) -> Rect2:
	var minimum := outline[0]
	var maximum := outline[0]
	for point in outline:
		minimum.x = minf(minimum.x, point.x)
		minimum.y = minf(minimum.y, point.y)
		maximum.x = maxf(maximum.x, point.x)
		maximum.y = maxf(maximum.y, point.y)
	return Rect2(minimum, maximum - minimum)


func _distance_to_outline(point: Vector2, outline: PackedVector2Array) -> float:
	var closest_distance := INF
	for index in range(outline.size()):
		var first := outline[index]
		var second := outline[(index + 1) % outline.size()]
		var segment := second - first
		var length_squared := segment.length_squared()
		if length_squared <= 0.000001:
			closest_distance = minf(closest_distance, point.distance_to(first))
			continue
		var t := clampf((point - first).dot(segment) / length_squared, 0.0, 1.0)
		closest_distance = minf(closest_distance, point.distance_to(first + segment * t))
	return closest_distance


func _append_vertex(vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, vertex: Vector3, normal: Vector3, color: Color) -> void:
	vertices.append(vertex)
	normals.append(normal)
	colors.append(color)


func _make_unindexed_mesh(vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray) -> ArrayMesh:
	if vertices.size() < 3:
		return null
	var mesh_arrays: Array = []
	mesh_arrays.resize(Mesh.ARRAY_MAX)
	mesh_arrays[Mesh.ARRAY_VERTEX] = vertices
	mesh_arrays[Mesh.ARRAY_NORMAL] = normals
	mesh_arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mesh_arrays)
	return mesh


func _make_split_instance(node_name: String, mesh: ArrayMesh, source: MeshInstance3D, material: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = material
	instance.visible = false
	instance.layers = source.layers
	instance.cast_shadow = source.cast_shadow
	instance.visibility_range_begin = source.visibility_range_begin
	instance.visibility_range_end = source.visibility_range_end
	instance.visibility_range_fade_mode = source.visibility_range_fade_mode
	return instance


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


func _load_transition_mesh() -> void:
	if not FileAccess.file_exists(mesh_path):
		_fail("Prebuilt coast transition mesh is missing. Run tools/terrain/build_coast_support.py.")
		return
	var file := FileAccess.open(mesh_path, FileAccess.READ)
	if file == null:
		_fail("Could not open coast transition mesh: %s" % mesh_path)
		return
	var data := file.get_buffer(file.get_length())
	if data.size() < 16 or data.slice(0, 4).get_string_from_ascii() != "OZCT":
		_fail("Coast transition mesh has an invalid header.")
		return
	var version := int(data.decode_u32(4))
	var vertex_count := int(data.decode_u32(8))
	var index_count := int(data.decode_u32(12))
	var expected_size := 16 + vertex_count * 40 + index_count * 4
	if version != 1 or vertex_count < 3 or index_count < 3 or index_count % 3 != 0 or data.size() != expected_size:
		_fail("Coast transition mesh counts or version are invalid.")
		return
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	vertices.resize(vertex_count)
	normals.resize(vertex_count)
	colors.resize(vertex_count)
	var offset := 16
	for index in range(vertex_count):
		vertices[index] = Vector3(data.decode_float(offset), data.decode_float(offset + 4), data.decode_float(offset + 8))
		normals[index] = Vector3(data.decode_float(offset + 12), data.decode_float(offset + 16), data.decode_float(offset + 20))
		colors[index] = Color(data.decode_float(offset + 24), data.decode_float(offset + 28), data.decode_float(offset + 32), data.decode_float(offset + 36))
		offset += 40
	var indices := PackedInt32Array()
	indices.resize(index_count)
	for index in range(index_count):
		var vertex_index := int(data.decode_u32(offset))
		if vertex_index >= vertex_count:
			_fail("Coast transition mesh references a missing vertex.")
			return
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
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "OresundCoastTransitionMesh"
	_mesh_instance.mesh = mesh
	_mesh_instance.material_override = _make_material()
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(_mesh_instance)
	_diagnostics = _load_metadata()
	_diagnostics["status"] = "loaded"
	_diagnostics["vertex_count"] = vertex_count
	_diagnostics["triangle_count"] = index_count / 3
	_diagnostics["mesh_bytes"] = data.size()
	print("[CoastTransitionLoader] Loaded %d terrain-mask-matched coast edges as %d static triangles (%.2f MiB)." % [
		int(_diagnostics.get("matched_coast_edge_count", 0)),
		index_count / 3,
		float(data.size()) / (1024.0 * 1024.0),
	])


func _load_metadata() -> Dictionary:
	if not FileAccess.file_exists(metadata_path):
		return {"status": "metadata_missing"}
	var file := FileAccess.open(metadata_path, FileAccess.READ)
	if file == null:
		return {"status": "metadata_unreadable"}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary or int(parsed.get("schema_version", -1)) != 1:
		return {"status": "metadata_invalid"}
	return parsed.duplicate(true)


func _make_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.WHITE
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	material.roughness = 0.96
	material.metallic = 0.0
	material.cull_mode = BaseMaterial3D.CULL_BACK
	return material


func _fail(message: String) -> void:
	_diagnostics = {"status": "failed", "reason": message}
	push_warning("CoastTransitionLoader: %s" % message)
