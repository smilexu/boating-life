class_name ShallowReefGenerator
extends RefCounted

## Builds a small shared library of low-poly rock variants and batches each
## chunk's deterministic transforms into one MultiMesh per variant.

const ROCK_PALETTE := [
	Color(0.34, 0.39, 0.42),
	Color(0.30, 0.35, 0.38),
	Color(0.41, 0.37, 0.31),
	Color(0.28, 0.34, 0.38),
	Color(0.44, 0.41, 0.35),
]


static func create_rock_meshes(variant_count: int = 5) -> Array[ArrayMesh]:
	var meshes: Array[ArrayMesh] = []
	for variant in range(maxi(variant_count, 1)):
		meshes.append(_create_rock_mesh(variant))
	return meshes


static func add_chunk_multimeshes(
	parent: Node3D,
	variant_meshes: Array[ArrayMesh],
	instances_by_variant: Array,
	material: Material,
	visible: bool,
	tile_size_m: float
) -> int:
	var instance_total := 0
	for variant in range(mini(variant_meshes.size(), instances_by_variant.size())):
		var records: Array = instances_by_variant[variant]
		if records.is_empty():
			continue
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.use_colors = true
		multimesh.mesh = variant_meshes[variant]
		multimesh.instance_count = records.size()
		for index in range(records.size()):
			var record: Dictionary = records[index]
			multimesh.set_instance_transform(index, record["transform"])
			multimesh.set_instance_color(index, record["color"])
		var instance := MultiMeshInstance3D.new()
		instance.name = "RockVariant_%d" % variant
		instance.multimesh = multimesh
		instance.material_override = material
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		instance.custom_aabb = AABB(Vector3(-2.0, -14.0, -2.0), Vector3(tile_size_m + 4.0, 20.0, tile_size_m + 4.0))
		instance.visible = visible
		parent.add_child(instance)
		instance_total += records.size()
	return instance_total


static func _create_rock_mesh(variant: int) -> ArrayMesh:
	var t := (1.0 + sqrt(5.0)) * 0.5
	var source_vertices: Array[Vector3] = [
		Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1),
	]
	var faces := PackedInt32Array([
		0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11,
		1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
		3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9,
		4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1,
	])
	var deformed: Array[Vector3] = []
	for index in range(source_vertices.size()):
		var direction := source_vertices[index].normalized()
		var radial := 0.82 + _hash01(index, variant, 17) * 0.34
		var vertical_shape := 0.70 + _hash01(index, variant, 43) * 0.44
		var point := Vector3(direction.x * radial, direction.y * radial * vertical_shape, direction.z * radial)
		point.y += (direction.x * direction.z) * (0.05 + 0.02 * float(variant % 3))
		deformed.append(point)

	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	for face_index in range(0, faces.size(), 3):
		var a := deformed[faces[face_index]]
		var b := deformed[faces[face_index + 1]]
		var c := deformed[faces[face_index + 2]]
		var face_center := (a + b + c) / 3.0
		var face_normal := (b - a).cross(c - a).normalized()
		if face_normal.dot(face_center) < 0.0:
			var swap := b
			b = c
			c = swap
			face_normal = -face_normal
		var base_color: Color = ROCK_PALETTE[variant % ROCK_PALETTE.size()]
		var facet_gain := 0.72 + _hash01(face_index / 3, variant, 97) * 0.48
		var facet_color := Color(
			clampf(base_color.r * facet_gain, 0.0, 1.0),
			clampf(base_color.g * facet_gain, 0.0, 1.0),
			clampf(base_color.b * facet_gain, 0.0, 1.0),
			1.0
		)
		# Godot rasterizes clockwise front faces for this project’s top-facing
		# geometry. Reverse the outward icosahedron triangle order so its outer
		# faces remain visible with the reef material’s back-face culling.
		for point in [a, c, b]:
			positions.append(point)
			normals.append(face_normal)
			colors.append(facet_color)

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _hash01(x: int, y: int, seed: int) -> float:
	var value := sin(float(x) * 127.1 + float(y) * 311.7 + float(seed) * 74.7) * 43758.5453
	return value - floor(value)
