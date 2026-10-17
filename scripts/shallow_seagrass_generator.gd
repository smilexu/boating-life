class_name ShallowSeagrassGenerator
extends RefCounted

## Shared procedural eelgrass and low brown algae meshes. Placement remains in
## ShallowSeabedManager so it can reuse the project's bathymetry and tile data.

const BLADE_SEGMENTS_NEAR := 5
const BLADE_SEGMENTS_FAR := 3
const DEFAULT_MESH_HEIGHTS := [0.72, 0.58, 0.66, 0.78]
const DEFAULT_MESH_WIDTHS := [0.021, 0.025, 0.020, 0.023]
const EELGRASS_PALETTE := [
	Color(0.25, 0.31, 0.11), # muted grey-green
	Color(0.29, 0.31, 0.10), # olive
	Color(0.25, 0.30, 0.085), # deep yellow-green
	Color(0.27, 0.29, 0.105), # subdued brown-green
]


static func create_eelgrass_variant(variant_index: int, far_lod: bool = false) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 8317 + variant_index * 191 + (10000 if far_lod else 0)
	var blade_count := rng.randi_range(5, 7) if not far_lod else rng.randi_range(3, 4)
	var segments := BLADE_SEGMENTS_NEAR if not far_lod else BLADE_SEGMENTS_FAR
	var target_height: float = float(DEFAULT_MESH_HEIGHTS[posmod(variant_index, DEFAULT_MESH_HEIGHTS.size())])
	var height_scale := rng.randf_range(0.84, 1.0)
	var target_width: float = float(DEFAULT_MESH_WIDTHS[posmod(variant_index, DEFAULT_MESH_WIDTHS.size())])
	if far_lod:
		target_height *= 1.08
		target_width *= 1.38
	var arrays := _new_surface_arrays()
	var vertex_index := 0
	var heading := rng.randf_range(0.0, TAU)
	var palette_color: Color = EELGRASS_PALETTE[posmod(variant_index, EELGRASS_PALETTE.size())]
	for leaf_index in range(blade_count):
		# Eelgrass blades rise from a crown in a loose fan. Restricting most of the
		# azimuth spread avoids the evenly radial, plastic-flower silhouette.
		var fan_position := (float(leaf_index) / maxf(float(blade_count - 1), 1.0) - 0.5) * 2.0
		var angle := heading + fan_position * rng.randf_range(0.72, 1.02) + rng.randf_range(-0.18, 0.18)
		if leaf_index == blade_count - 1 and rng.randf() < 0.28:
			angle += rng.randf_range(1.3, 2.1)
		var azimuth := Vector3(cos(angle), 0.0, sin(angle))
		var side_axis := Vector3(-azimuth.z, 0.0, azimuth.x)
		var length: float = target_height * height_scale * rng.randf_range(0.68, 1.0)
		var width: float = target_width * rng.randf_range(0.76, 1.12)
		var lean := rng.randf_range(0.10, 0.30)
		var bend_phase := rng.randf_range(0.0, TAU)
		var twist := rng.randf_range(-0.14, 0.14)
		var tone := rng.randf_range(0.90, 1.09)
		var color := palette_color * tone
		_append_ribbon(arrays, vertex_index, azimuth, side_axis, length, width, lean, bend_phase, twist, color, segments)
		vertex_index += (segments + 1) * 2
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return {"mesh": mesh, "triangles": PackedInt32Array(arrays[Mesh.ARRAY_INDEX]).size() / 3, "max_height": target_height * height_scale}


static func create_rock_algae_mesh() -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 338911
	var arrays := _new_surface_arrays()
	var vertex_index := 0
	var blade_count := 5
	var segments := 3
	for leaf_index in range(blade_count):
		var angle := rng.randf_range(0.0, TAU)
		var azimuth := Vector3(cos(angle), 0.0, sin(angle))
		var side_axis := Vector3(-azimuth.z, 0.0, azimuth.x)
		var length := rng.randf_range(0.20, 0.42)
		var width := rng.randf_range(0.026, 0.045)
		var color := Color(rng.randf_range(0.19, 0.30), rng.randf_range(0.20, 0.31), rng.randf_range(0.085, 0.15), 1.0)
		_append_ribbon(arrays, vertex_index, azimuth, side_axis, length, width, rng.randf_range(0.18, 0.42), rng.randf_range(0.0, TAU), rng.randf_range(-0.20, 0.20), color, segments)
		vertex_index += (segments + 1) * 2
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return {"mesh": mesh, "triangles": PackedInt32Array(arrays[Mesh.ARRAY_INDEX]).size() / 3, "max_height": 0.42}


static func build_patch_centers(
	min_east: float,
	min_north: float,
	max_east: float,
	max_north: float,
	grid_spacing_m: float,
	seed: int,
	coverage_scale: float
) -> Array[Dictionary]:
	var centers: Array[Dictionary] = []
	var radius_limit := 31.0 * coverage_scale
	var x_min := floori((min_east - radius_limit) / grid_spacing_m)
	var x_max := floori((max_east + radius_limit) / grid_spacing_m)
	var z_min := floori((min_north - radius_limit) / grid_spacing_m)
	var z_max := floori((max_north + radius_limit) / grid_spacing_m)
	for grid_north in range(z_min, z_max + 1):
		for grid_east in range(x_min, x_max + 1):
			if hash01(grid_east, grid_north, seed + 11) > 0.78:
				continue
			var center_east := (float(grid_east) + 0.5 + (hash01(grid_east, grid_north, seed + 12) - 0.5) * 0.74) * grid_spacing_m
			var center_north := (float(grid_north) + 0.5 + (hash01(grid_east, grid_north, seed + 13) - 0.5) * 0.74) * grid_spacing_m
			var tier := hash01(grid_east, grid_north, seed + 14)
			var major_radius: float
			var minor_radius: float
			var patch_type := "small"
			if tier < 0.20:
				major_radius = lerpf(2.0, 4.0, hash01(grid_east, grid_north, seed + 15))
				minor_radius = lerpf(2.0, 4.0, hash01(grid_east, grid_north, seed + 16))
			elif tier < 0.65:
				patch_type = "medium"
				major_radius = lerpf(5.0, 12.5, hash01(grid_east, grid_north, seed + 15))
				minor_radius = lerpf(3.5, 8.5, hash01(grid_east, grid_north, seed + 16))
			else:
				patch_type = "large"
				major_radius = lerpf(15.0, 30.0, hash01(grid_east, grid_north, seed + 15))
				minor_radius = lerpf(5.0, 12.5, hash01(grid_east, grid_north, seed + 16))
			var angle := hash01(grid_east, grid_north, seed + 17) * TAU
			var cosine := cos(angle)
			var sine := sin(angle)
			centers.append({
				"east": center_east,
				"north": center_north,
				"major": major_radius * coverage_scale,
				"minor": minor_radius * coverage_scale,
				"angle": angle,
				"cos_angle": cosine,
				"sin_angle": sine,
				"extent_east": sqrt(pow(major_radius * cosine, 2.0) + pow(minor_radius * sine, 2.0)) * coverage_scale * 1.3,
				"extent_north": sqrt(pow(major_radius * sine, 2.0) + pow(minor_radius * cosine, 2.0)) * coverage_scale * 1.3,
				"inverse_major_sq": 1.0 / maxf(pow(major_radius * coverage_scale, 2.0), 0.001),
				"inverse_minor_sq": 1.0 / maxf(pow(minor_radius * coverage_scale, 2.0), 0.001),
				"type": patch_type,
				"cell_east": grid_east,
				"cell_north": grid_north,
			})
	return centers


static func build_patch_lookup(centers: Array[Dictionary]) -> Dictionary:
	var lookup: Dictionary = {}
	for patch in centers:
		lookup[Vector2i(int(patch["cell_east"]), int(patch["cell_north"]))] = patch
	return lookup


static func patch_weight(east: float, north: float, lookup: Dictionary, grid_spacing_m: float, coverage_scale: float) -> float:
	var best := 0.0
	var grid_east := floori(east / grid_spacing_m)
	var grid_north := floori(north / grid_spacing_m)
	var search_radius := ceili((31.0 * coverage_scale + grid_spacing_m * 0.37) / grid_spacing_m)
	for cell_north in range(grid_north - search_radius, grid_north + search_radius + 1):
		for cell_east in range(grid_east - search_radius, grid_east + search_radius + 1):
			var patch_variant: Variant = lookup.get(Vector2i(cell_east, cell_north))
			if patch_variant == null:
				continue
			var patch: Dictionary = patch_variant
			var dx := east - float(patch["east"])
			var dz := north - float(patch["north"])
			if absf(dx) > float(patch["extent_east"]) or absf(dz) > float(patch["extent_north"]):
				continue
			var cosine := float(patch["cos_angle"])
			var sine := float(patch["sin_angle"])
			var along := dx * cosine + dz * sine
			var across := -dx * sine + dz * cosine
			var normalized_distance := sqrt(along * along * float(patch["inverse_major_sq"]) + across * across * float(patch["inverse_minor_sq"]))
			var edge_seed := int(patch["cell_east"]) * 31 + int(patch["cell_north"]) * 47 + 221
			var edge_warp := (value_noise(east, north, 0.14, edge_seed) - 0.5) * 0.20
			best = maxf(best, 1.0 - smoothstep(0.76 + edge_warp, 1.12 + edge_warp, normalized_distance))
	return best


static func hash01(x: int, y: int, seed: int) -> float:
	# Integer-only 32-bit mixing keeps layout deterministic and avoids a sine per
	# placement candidate. Values are masked before multiplication to stay inside
	# signed 64-bit integer range on every supported Godot platform.
	const MASK_32 := 0xffffffff
	var value := (x * 374761393 + y * 668265263 + seed * 1442695041) & MASK_32
	value = ((value ^ (value >> 13)) * 1274126177) & MASK_32
	value = (value ^ (value >> 16)) & MASK_32
	return float(value) / 4294967295.0


static func value_noise(east: float, north: float, frequency: float, seed: int) -> float:
	var px := east * frequency
	var py := north * frequency
	var ix := floori(px)
	var iy := floori(py)
	var tx := px - float(ix)
	var ty := py - float(iy)
	tx = tx * tx * (3.0 - 2.0 * tx)
	ty = ty * ty * (3.0 - 2.0 * ty)
	var a := hash01(ix, iy, seed)
	var b := hash01(ix + 1, iy, seed)
	var c := hash01(ix, iy + 1, seed)
	var d := hash01(ix + 1, iy + 1, seed)
	return lerpf(lerpf(a, b, tx), lerpf(c, d, tx), ty)


static func _new_surface_arrays() -> Array:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array()
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array()
	arrays[Mesh.ARRAY_COLOR] = PackedColorArray()
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array()
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array()
	return arrays


static func _append_ribbon(
	arrays: Array,
	base_index: int,
	azimuth: Vector3,
	side_axis: Vector3,
	length: float,
	width: float,
	lean: float,
	bend_phase: float,
	twist: float,
	color: Color,
	segments: int
) -> void:
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var centers: Array[Vector3] = []
	var sides: Array[Vector3] = []
	for row in range(segments + 1):
		var t := float(row) / float(segments)
		centers.append(_blade_center(azimuth, length, lean, bend_phase, t))
		sides.append(side_axis.rotated(Vector3.UP, twist * t).normalized())
	for row in range(segments + 1):
		var t := float(row) / float(segments)
		var previous_index := maxi(row - 1, 0)
		var next_index := mini(row + 1, segments)
		var tangent := (centers[next_index] - centers[previous_index]).normalized()
		var normal := tangent.cross(sides[row]).normalized()
		if normal.length_squared() < 0.1:
			normal = Vector3.FORWARD
		var blade_width := width * _blade_width_profile(t)
		var center := centers[row]
		var shade := lerpf(0.80, 1.08, smoothstep(0.0, 1.0, t))
		var vertex_color := color * shade
		vertices.append(center - sides[row] * blade_width * 0.5)
		vertices.append(center + sides[row] * blade_width * 0.5)
		normals.append(normal)
		normals.append(normal)
		colors.append(vertex_color)
		colors.append(vertex_color)
		uvs.append(Vector2(0.0, t))
		uvs.append(Vector2(1.0, t))
	for segment in range(segments):
		var row_base := base_index + segment * 2
		indices.append_array(PackedInt32Array([row_base, row_base + 2, row_base + 1, row_base + 1, row_base + 2, row_base + 3]))
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices


static func _blade_width_profile(t: float) -> float:
	# A real eelgrass ribbon keeps most of its width, then rounds down over its
	# final third instead of tapering into a long, sharp triangle.
	var root_profile := lerpf(0.38, 1.0, smoothstep(0.0, 0.20, t))
	var tip_profile := 1.0 - 0.95 * smoothstep(0.64, 1.0, t)
	return root_profile * tip_profile


static func _blade_center(azimuth: Vector3, length: float, lean: float, phase: float, t: float) -> Vector3:
	var bend := pow(t, 2.0) * length * lean
	var side := sin(t * PI + phase) * length * 0.045 * t
	var secondary := sin(t * TAU + phase * 0.63) * length * 0.012 * t
	return Vector3(azimuth.x * (bend + secondary) - azimuth.z * side, t * length, azimuth.z * (bend + secondary) + azimuth.x * side)
