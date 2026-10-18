class_name PeberholmFlora
extends Node3D

## Builds deterministic, static low-vegetation batches on the existing island top.

const CELL_SIZE_M := 240.0
const RANDOM_SEED := 812_407
const GRASS_TARGET := 12000
const WILDFLOWER_TARGET := 900
const SHRUB_TARGET := 320
const GROUND_SHADER := preload("res://shaders/peberholm_flora.gdshader")

var _outline := PackedVector2Array()
var _triangles: Array[Dictionary] = []
var _cumulative_area: Array[float] = []
var _total_area := 0.0
var _rng := RandomNumberGenerator.new()
var _instance_data: Dictionary = {}
var _counts := {"grass": 0, "wildflowers": 0, "shrubs": 0, "batches": 0}


func build(outline: PackedVector2Array, top_instances: Array[MeshInstance3D], region_root: Node3D) -> Dictionary:
	_outline = outline
	_triangles.clear()
	_cumulative_area.clear()
	_instance_data.clear()
	_counts = {"grass": 0, "wildflowers": 0, "shrubs": 0, "batches": 0}
	if _outline.size() < 3:
		return get_diagnostics()
	_collect_surface_triangles(top_instances, region_root)
	if _triangles.is_empty() or _total_area <= 0.0:
		push_warning("Peberholm flora: no island-top triangles are available.")
		return get_diagnostics()

	_spawn_species("grass", GRASS_TARGET, 8.0, 1.65, 0.72)
	_spawn_species("wildflowers", WILDFLOWER_TARGET, 12.0, 1.30, 0.82)
	_spawn_species("shrubs", SHRUB_TARGET, 17.0, 1.75, 0.78)
	_build_batches()
	print("[PeberholmFlora] area=%.2f km2 grass=%d wildflowers=%d shrubs=%d batches=%d seed=%d" % [
		_total_area / 1_000_000.0,
		_counts["grass"],
		_counts["wildflowers"],
		_counts["shrubs"],
		_counts["batches"],
		RANDOM_SEED,
	])
	return get_diagnostics()


func get_diagnostics() -> Dictionary:
	return _counts.duplicate(true)


func _collect_surface_triangles(top_instances: Array[MeshInstance3D], region_root: Node3D) -> void:
	for instance in top_instances:
		if not is_instance_valid(instance) or instance.mesh == null:
			continue
		var local_transform := region_root.global_transform.affine_inverse() * instance.global_transform
		for surface_index in range(instance.mesh.get_surface_count()):
			var arrays := instance.mesh.surface_get_arrays(surface_index)
			var vertices := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
			var indices := PackedInt32Array()
			if arrays[Mesh.ARRAY_INDEX] is PackedInt32Array:
				indices = arrays[Mesh.ARRAY_INDEX]
			var count := indices.size() if not indices.is_empty() else vertices.size()
			for index in range(0, count - 2, 3):
				var first := local_transform * vertices[indices[index] if not indices.is_empty() else index]
				var second := local_transform * vertices[indices[index + 1] if not indices.is_empty() else index + 1]
				var third := local_transform * vertices[indices[index + 2] if not indices.is_empty() else index + 2]
				var double_area := absf((second.x - first.x) * (third.z - first.z) - (second.z - first.z) * (third.x - first.x))
				if double_area < 0.02:
					continue
				_total_area += double_area * 0.5
				_triangles.append({"a": first, "b": second, "c": third})
				_cumulative_area.append(_total_area)


func _spawn_species(kind: String, target_count: int, shoreline_margin_m: float, cluster_scale_m: float, density_floor: float) -> void:
	_rng.seed = RANDOM_SEED + kind.hash()
	var attempt_limit := target_count * 3
	for _attempt in range(attempt_limit):
		if int(_counts[kind]) >= target_count:
			break
		var sample := _sample_triangle()
		if sample.is_empty():
			return
		var position: Vector3 = sample["position"]
		var xz := Vector2(position.x, position.z)
		if not Geometry2D.is_point_in_polygon(xz, _outline):
			continue
		if _distance_to_outline(xz) < shoreline_margin_m:
			continue
		var clustered_density := density_floor + (1.0 - density_floor) * _value_noise(xz / cluster_scale_m, kind.hash())
		if _rng.randf() > clustered_density:
			continue
		_add_species_instance(kind, position)


func _sample_triangle() -> Dictionary:
	var area_roll := _rng.randf() * _total_area
	var triangle_index := _cumulative_area.bsearch(area_roll)
	triangle_index = clampi(triangle_index, 0, _triangles.size() - 1)
	var triangle: Dictionary = _triangles[triangle_index]
	var first: Vector3 = triangle["a"]
	var second: Vector3 = triangle["b"]
	var third: Vector3 = triangle["c"]
	var root_random := sqrt(_rng.randf())
	var edge_random := _rng.randf()
	var position := first * (1.0 - root_random) + second * (root_random * (1.0 - edge_random)) + third * (root_random * edge_random)
	return {"position": position}


func _add_species_instance(kind: String, position: Vector3) -> void:
	var cell := Vector2i(floori(position.x / CELL_SIZE_M), floori(position.z / CELL_SIZE_M))
	if not _instance_data.has(kind):
		_instance_data[kind] = {}
	var species_cells: Dictionary = _instance_data[kind]
	if not species_cells.has(cell):
		species_cells[cell] = {"transforms": [], "tints": []}
	var cell_data: Dictionary = species_cells[cell]
	var center := Vector3((float(cell.x) + 0.5) * CELL_SIZE_M, 0.0, (float(cell.y) + 0.5) * CELL_SIZE_M)
	var yaw := _rng.randf_range(0.0, TAU)
	var scale := Vector3.ONE
	if kind == "grass":
		scale = Vector3(_rng.randf_range(0.8, 1.45), _rng.randf_range(0.72, 1.22), _rng.randf_range(0.8, 1.45))
	elif kind == "wildflowers":
		scale = Vector3(_rng.randf_range(0.72, 1.22), _rng.randf_range(0.68, 1.12), _rng.randf_range(0.72, 1.22))
	else:
		scale = Vector3(_rng.randf_range(1.0, 2.0), _rng.randf_range(0.75, 1.35), _rng.randf_range(0.9, 1.7))
	var basis := Basis(Vector3.UP, yaw).scaled(scale)
	var local_position := position - center
	cell_data["transforms"].append(Transform3D(basis, local_position))
	var tint_strength := _rng.randf_range(0.89, 1.10)
	cell_data["tints"].append(Color(
		tint_strength,
		_rng.randf_range(0.93, 1.07),
		_rng.randf_range(0.88, 1.08),
		1.0
	))
	_counts[kind] = int(_counts[kind]) + 1


func _build_batches() -> void:
	var meshes := {
		"grass": _make_grass_mesh(),
		"wildflowers": _make_wildflower_mesh(),
		"shrubs": _make_shrub_mesh(),
	}
	var far_ranges := {"grass": 520.0, "wildflowers": 260.0, "shrubs": 950.0}
	var fade_margins := {"grass": 90.0, "wildflowers": 55.0, "shrubs": 160.0}
	var material := ShaderMaterial.new()
	material.shader = GROUND_SHADER
	for kind in ["grass", "wildflowers", "shrubs"]:
		var species_cells: Dictionary = _instance_data.get(kind, {})
		for cell_value in species_cells:
			var cell: Vector2i = cell_value
			var cell_data: Dictionary = species_cells[cell]
			var transforms: Array = cell_data["transforms"]
			var tints: Array = cell_data["tints"]
			if transforms.is_empty():
				continue
			var multimesh := MultiMesh.new()
			multimesh.transform_format = MultiMesh.TRANSFORM_3D
			multimesh.use_custom_data = true
			multimesh.mesh = meshes[kind]
			multimesh.instance_count = transforms.size()
			for index in range(transforms.size()):
				multimesh.set_instance_transform(index, transforms[index])
				multimesh.set_instance_custom_data(index, tints[index])
			var instance := MultiMeshInstance3D.new()
			instance.name = "Peberholm_%s_%d_%d" % [kind.capitalize(), cell.x, cell.y]
			instance.position = Vector3((float(cell.x) + 0.5) * CELL_SIZE_M, 0.0, (float(cell.y) + 0.5) * CELL_SIZE_M)
			instance.multimesh = multimesh
			instance.material_override = material
			instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			instance.visibility_range_end = float(far_ranges[kind])
			instance.visibility_range_end_margin = float(fade_margins[kind])
			instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
			instance.custom_aabb = AABB(Vector3(-CELL_SIZE_M * 0.5, -0.5, -CELL_SIZE_M * 0.5), Vector3(CELL_SIZE_M, 4.2, CELL_SIZE_M))
			multimesh.custom_aabb = instance.custom_aabb
			add_child(instance)
			_counts["batches"] = int(_counts["batches"]) + 1


func _make_grass_mesh() -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	for blade_index in range(3):
		var angle := PI * float(blade_index) / 3.0
		var forward := Vector3(cos(angle), 0.0, sin(angle))
		var side := Vector3(-forward.z, 0.0, forward.x)
		var base_left := -side * 0.12
		var base_right := side * 0.12
		var mid_center := forward * 0.12 + Vector3.UP * 0.40
		var top := forward * 0.29 + Vector3.UP * 0.88
		var mid_left := mid_center - side * 0.07
		var mid_right := mid_center + side * 0.07
		var leaf_color: Color = [Color(0.36, 0.43, 0.28), Color(0.43, 0.48, 0.31), Color(0.32, 0.39, 0.25)][blade_index]
		_append_colored_triangle(vertices, normals, colors, base_left, base_right, mid_right, leaf_color.darkened(0.07), leaf_color)
		_append_colored_triangle(vertices, normals, colors, base_left, mid_right, mid_left, leaf_color.darkened(0.04), leaf_color)
		_append_colored_triangle(vertices, normals, colors, mid_left, mid_right, top, leaf_color, leaf_color.lightened(0.08))
	return _make_array_mesh(vertices, normals, colors)


func _make_wildflower_mesh() -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var stem_color := Color(0.31, 0.39, 0.24)
	var stem_left := Vector3(-0.018, 0.0, 0.0)
	var stem_right := Vector3(0.018, 0.0, 0.0)
	var stem_top_left := Vector3(-0.012, 0.38, 0.025)
	var stem_top_right := Vector3(0.012, 0.38, 0.025)
	_append_colored_triangle(vertices, normals, colors, stem_left, stem_right, stem_top_right, stem_color.darkened(0.06), stem_color)
	_append_colored_triangle(vertices, normals, colors, stem_left, stem_top_right, stem_top_left, stem_color, stem_color.lightened(0.05))
	var center := Vector3(0.0, 0.47, 0.025)
	var petal_color := Color(0.79, 0.78, 0.64)
	for petal_index in range(5):
		var angle := TAU * float(petal_index) / 5.0
		var outer := center + Vector3(cos(angle) * 0.14, 0.012, sin(angle) * 0.14)
		var inner_angle := angle + TAU / 10.0
		var outer_next := center + Vector3(cos(inner_angle) * 0.14, 0.012, sin(inner_angle) * 0.14)
		_append_colored_triangle(vertices, normals, colors, center, outer, outer_next, petal_color, petal_color.lightened(0.06))
	for petal_index in range(5):
		var angle := TAU * float(petal_index) / 5.0
		var outer := center + Vector3(cos(angle) * 0.04, 0.018, sin(angle) * 0.04)
		var inner_angle := angle + TAU / 10.0
		var outer_next := center + Vector3(cos(inner_angle) * 0.04, 0.018, sin(inner_angle) * 0.04)
		_append_colored_triangle(vertices, normals, colors, center + Vector3.UP * 0.018, outer, outer_next, Color(0.72, 0.52, 0.25), Color(0.82, 0.64, 0.32))
	return _make_array_mesh(vertices, normals, colors)


func _make_shrub_mesh() -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var lobes := [
		{"center": Vector3(0.0, 0.62, 0.0), "scale": Vector3(0.80, 0.58, 0.72), "color": Color(0.28, 0.35, 0.23)},
		{"center": Vector3(-0.48, 0.48, 0.08), "scale": Vector3(0.55, 0.42, 0.50), "color": Color(0.34, 0.40, 0.26)},
		{"center": Vector3(0.46, 0.50, -0.10), "scale": Vector3(0.58, 0.44, 0.52), "color": Color(0.31, 0.38, 0.25)},
	]
	for lobe in lobes:
		var center: Vector3 = lobe["center"]
		var scale: Vector3 = lobe["scale"]
		var color: Color = lobe["color"]
		var top := center + Vector3.UP * scale.y
		var bottom := center - Vector3.UP * scale.y
		var east := center + Vector3.RIGHT * scale.x
		var west := center - Vector3.RIGHT * scale.x
		var north := center + Vector3.FORWARD * scale.z
		var south := center - Vector3.FORWARD * scale.z
		var faces := [
			[top, east, north], [top, north, west], [top, west, south], [top, south, east],
			[bottom, north, east], [bottom, west, north], [bottom, south, west], [bottom, east, south],
		]
		for face in faces:
			var first: Vector3 = face[0]
			var second: Vector3 = face[1]
			var third: Vector3 = face[2]
			var expected := ((first + second + third) / 3.0) - center
			_append_oriented_triangle(vertices, normals, colors, first, second, third, expected, color)
	return _make_array_mesh(vertices, normals, colors)


func _append_colored_triangle(vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, first: Vector3, second: Vector3, third: Vector3, first_color: Color, other_color: Color) -> void:
	var normal := (second - first).cross(third - first).normalized()
	if normal.length_squared() < 0.5:
		return
	vertices.append(first)
	vertices.append(second)
	vertices.append(third)
	normals.append(normal)
	normals.append(normal)
	normals.append(normal)
	colors.append(first_color)
	colors.append(other_color)
	colors.append(other_color)


func _append_oriented_triangle(vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, first: Vector3, second: Vector3, third: Vector3, expected_normal: Vector3, color: Color) -> void:
	var face_normal := (second - first).cross(third - first)
	if face_normal.dot(expected_normal) < 0.0:
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
	colors.append(color.darkened(0.05))
	colors.append(color)
	colors.append(color.lightened(0.04))


func _make_array_mesh(vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray) -> ArrayMesh:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _distance_to_outline(point: Vector2) -> float:
	var closest_distance := INF
	for index in range(_outline.size()):
		var first := _outline[index]
		var second := _outline[(index + 1) % _outline.size()]
		var segment := second - first
		var length_squared := segment.length_squared()
		if length_squared <= 0.000001:
			closest_distance = minf(closest_distance, point.distance_to(first))
			continue
		var t := clampf((point - first).dot(segment) / length_squared, 0.0, 1.0)
		closest_distance = minf(closest_distance, point.distance_to(first + segment * t))
	return closest_distance


func _value_noise(point: Vector2, salt: int) -> float:
	var cell := Vector2i(floori(point.x), floori(point.y))
	var fraction := Vector2(point.x - float(cell.x), point.y - float(cell.y))
	fraction = fraction * fraction * (Vector2(3.0, 3.0) - fraction * 2.0)
	var lower := lerpf(_hash_grid(cell, salt), _hash_grid(cell + Vector2i.RIGHT, salt), fraction.x)
	var upper := lerpf(_hash_grid(cell + Vector2i.DOWN, salt), _hash_grid(cell + Vector2i.ONE, salt), fraction.x)
	return lerpf(lower, upper, fraction.y)


func _hash_grid(cell: Vector2i, salt: int) -> float:
	var value := sin(float(cell.x * 127 + cell.y * 311 + salt * 17)) * 43758.5453
	return value - floorf(value)
