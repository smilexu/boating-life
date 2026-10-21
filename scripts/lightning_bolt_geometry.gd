extends RefCounted
class_name LightningBoltGeometry

## Pure deterministic bolt mesh builder. Paths are world-metre offsets from the
## event origin; all discharge layers are batched into one ArrayMesh surface.

enum Quality { LOW, MEDIUM, HIGH }

const TUBE_SIDES := 6
const BOLT_BLUE := Color(0.39, 0.66, 1.0)
const BOLT_AURA := Color(0.70, 0.84, 1.0)
const BOLT_CORE := Color(1.0, 0.985, 0.93)


static func build(
	event_type: String,
	seed: int,
	quality: int,
	intensity: float,
	width_multiplier: float = 1.0,
	curve_multiplier: float = 1.0,
	primary_density_multiplier: float = 1.0,
	secondary_density_multiplier: float = 1.0,
	vertical_span_meters: float = 1900.0
) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var tier := clampi(quality, Quality.LOW, Quality.HIGH)
	var strength := clampf(intensity, 0.0, 1.0)
	var width_scale := clampf(width_multiplier, 0.5, 3.0)
	var curve_scale := clampf(curve_multiplier, 0.4, 2.5)
	var primary_scale := clampf(primary_density_multiplier, 0.35, 2.0)
	var secondary_scale := clampf(secondary_density_multiplier, 0.35, 2.0)
	var vertical_span := maxf(vertical_span_meters, 100.0)
	var distance_class := _distance_class(event_type)
	var main_radius := lerpf(0.72, 4.6, distance_class) * lerpf(0.72, 1.0, strength) * width_scale
	var paths: Array[Dictionary] = []
	var primary_count := 0
	var secondary_count := 0

	if event_type in ["near_cg", "medium_cg", "distant_cg"]:
		var trunk_length := vertical_span if event_type != "distant_cg" else vertical_span * 0.92
		var main_path := _make_vertical_path(trunk_length, curve_scale, rng, 4 if tier == Quality.LOW else 5)
		paths.append({"kind": "main", "points": main_path, "radius": main_radius})
		primary_count = _primary_count_for(event_type, tier, rng, primary_scale)
		var secondary_target := _secondary_count_for(event_type, tier, rng, secondary_scale)
		var primary_paths: Array[Array] = []
		for branch_index in range(primary_count):
			var start_index := rng.randi_range(2, main_path.size() - 3)
			var branch := _make_primary_branch(main_path[start_index], rng, event_type, curve_scale)
			primary_paths.append(branch)
			paths.append({"kind": "primary", "points": branch, "radius": main_radius * 0.54})
		for branch_index in range(secondary_target):
			var parent: Array = primary_paths[branch_index % primary_paths.size()]
			var attach_index := rng.randi_range(1, parent.size() - 2)
			var child := _make_secondary_branch(parent, attach_index, rng, curve_scale, distance_class)
			paths.append({"kind": "secondary", "points": child, "radius": main_radius * rng.randf_range(0.19, 0.27)})
		secondary_count = secondary_target
	elif event_type == "cloud_to_cloud":
		var span := rng.randf_range(680.0, 1450.0)
		var cloud_main := _subdivide_path(
			Vector3(-span * 0.5, 0.0, 0.0),
			Vector3(span * 0.5, rng.randf_range(-120.0, 120.0), rng.randf_range(-160.0, 160.0)),
			rng,
			span * 0.12 * curve_scale,
			4 if tier == Quality.LOW else 5
		)
		paths.append({"kind": "main", "points": cloud_main, "radius": main_radius * 0.66})
		primary_count = 4 if tier == Quality.LOW else (7 if tier == Quality.MEDIUM else 10)
		for branch_index in range(primary_count):
			var start_index := rng.randi_range(2, cloud_main.size() - 3)
			var start := cloud_main[start_index]
			var side_sign := -1.0 if rng.randf() < 0.5 else 1.0
			var end := start + Vector3(
				rng.randf_range(100.0, 360.0) * side_sign,
				rng.randf_range(-260.0, 260.0),
				rng.randf_range(-320.0, 320.0)
			)
			var branch := _subdivide_path(start, end, rng, end.distance_to(start) * 0.17 * curve_scale, 2)
			paths.append({"kind": "primary", "points": branch, "radius": main_radius * 0.42})
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var maximum_segment_length := 0.0
	for path_data in paths:
		var points: Array = path_data["points"]
		var kind := str(path_data["kind"])
		var radius := float(path_data["radius"])
		var width_profile := _make_width_profile(points.size(), kind, rng)
		var branch_brightness := 1.0 if kind == "main" else (0.76 if kind == "primary" else 0.52)
		for index in range(1, points.size()):
			maximum_segment_length = maxf(maximum_segment_length, (points[index] as Vector3).distance_to(points[index - 1]))
		_append_tube(points, width_profile, radius * 4.2, Color(BOLT_BLUE.r, BOLT_BLUE.g, BOLT_BLUE.b, 0.055 * branch_brightness), vertices, colors, indices)
		_append_tube(points, width_profile, radius * 1.85, Color(BOLT_AURA.r, BOLT_AURA.g, BOLT_AURA.b, 0.34 * branch_brightness), vertices, colors, indices)
		_append_tube(points, width_profile, radius * 0.48, Color(BOLT_CORE.r, BOLT_CORE.g, BOLT_CORE.b, 0.98 * branch_brightness), vertices, colors, indices)

	return {
		"vertices": vertices,
		"colors": colors,
		"indices": indices,
		"paths": paths,
		"primary_branch_count": primary_count,
		"secondary_branch_count": secondary_count,
		"path_count": paths.size(),
		"max_segment_length": maximum_segment_length,
		"main_core_radius": main_radius * 0.48,
		"main_aura_radius": main_radius * 1.85,
		"main_halo_radius": main_radius * 4.2,
		"vertex_count": vertices.size(),
		"triangle_count": indices.size() / 3,
	}


static func _distance_class(event_type: String) -> float:
	match event_type:
		"near_cg":
			return 1.0
		"medium_cg":
			return 0.58
		"distant_cg":
			return 0.16
		"cloud_to_cloud":
			return 0.42
	return 0.0


static func _primary_count_for(event_type: String, quality: int, rng: RandomNumberGenerator, density: float) -> int:
	var minimum := 7
	var maximum := 10
	if event_type == "medium_cg":
		minimum = 5
		maximum = 8
	elif event_type == "distant_cg":
		minimum = 3
		maximum = 5
	if quality == Quality.LOW:
		minimum = mini(minimum, 4)
		maximum = mini(maximum, 6)
	elif quality == Quality.HIGH:
		minimum += 2
		maximum += 2
	return clampi(roundi(float(rng.randi_range(minimum, maximum)) * density), 3, 14)


static func _secondary_count_for(event_type: String, quality: int, rng: RandomNumberGenerator, density: float) -> int:
	var minimum := 18
	var maximum := 30
	if event_type == "medium_cg":
		minimum = 12
		maximum = 22
	elif event_type == "distant_cg":
		minimum = 5
		maximum = 10
	if quality == Quality.LOW:
		minimum = 7
		maximum = 14
	elif quality == Quality.HIGH:
		minimum += 8
		maximum += 8
	return clampi(roundi(float(rng.randi_range(minimum, maximum)) * density), 4, 45)


static func _make_vertical_path(length: float, curve: float, rng: RandomNumberGenerator, depth: int) -> Array[Vector3]:
	return _subdivide_path(Vector3.ZERO, Vector3(0.0, -length, 0.0), rng, length * 0.12 * curve, depth)


static func _make_primary_branch(start: Vector3, rng: RandomNumberGenerator, event_type: String, curve: float) -> Array[Vector3]:
	var spread_scale := 1.0 if event_type == "near_cg" else (0.72 if event_type == "medium_cg" else 0.42)
	var side_sign := -1.0 if rng.randf() < 0.5 else 1.0
	var lateral := Vector3(side_sign, rng.randf_range(-0.2, 0.2), rng.randf_range(-0.85, 0.85)).normalized()
	var reach := rng.randf_range(270.0, 680.0) * spread_scale
	var descent := rng.randf_range(120.0, 520.0) * spread_scale
	var end := start + lateral * reach + Vector3(0.0, -descent, 0.0)
	return _subdivide_path(start, end, rng, reach * 0.17 * curve, 2)


static func _make_secondary_branch(parent: Array, start_index: int, rng: RandomNumberGenerator, curve: float, distance_class: float) -> Array[Vector3]:
	var start: Vector3 = parent[start_index]
	var tangent := (parent[start_index + 1] as Vector3 - parent[start_index - 1] as Vector3).normalized()
	var side := tangent.cross(Vector3.UP).normalized()
	if side.length_squared() < 0.1:
		side = Vector3.RIGHT
	var sign := -1.0 if rng.randf() < 0.5 else 1.0
	var reach := rng.randf_range(95.0, 290.0) * lerpf(0.55, 1.0, distance_class)
	var end := start + tangent * reach * 0.30 + side * sign * reach + Vector3(0.0, -reach * rng.randf_range(0.12, 0.42), 0.0)
	return _subdivide_path(start, end, rng, reach * 0.22 * curve, 1)


static func _subdivide_path(start: Vector3, end: Vector3, rng: RandomNumberGenerator, initial_offset: float, depth: int) -> Array[Vector3]:
	var points: Array[Vector3] = [start, end]
	for level in range(depth):
		var expanded: Array[Vector3] = []
		var offset := initial_offset * pow(0.52, float(level))
		for index in range(points.size() - 1):
			var a := points[index]
			var b := points[index + 1]
			expanded.append(a)
			var axis := (b - a).normalized()
			var lateral := axis.cross(Vector3.UP).normalized()
			if lateral.length_squared() < 0.1:
				lateral = Vector3.RIGHT
			var depth_axis := axis.cross(lateral).normalized()
			var midpoint := (a + b) * 0.5
			midpoint += lateral * rng.randf_range(-offset, offset)
			midpoint += depth_axis * rng.randf_range(-offset * 0.72, offset * 0.72)
			expanded.append(midpoint)
		expanded.append(points.back())
		points = expanded
	return points


static func _make_width_profile(point_count: int, kind: String, rng: RandomNumberGenerator) -> Array[float]:
	var widths: Array[float] = []
	for index in range(point_count):
		var t := float(index) / float(maxi(point_count - 1, 1))
		var envelope := sqrt(maxf(sin(PI * t), 0.0))
		var minimum := 0.31 if kind == "main" else (0.16 if kind == "primary" else 0.07)
		var variation := rng.randf_range(0.78, 1.24) if index > 0 and index < point_count - 1 else 0.66
		widths.append((minimum + (1.0 - minimum) * envelope) * variation)
	return widths


static func _append_tube(
	path: Array,
	width_profile: Array[float],
	radius: float,
	color: Color,
	vertices: PackedVector3Array,
	colors: PackedColorArray,
	indices: PackedInt32Array
) -> void:
	if path.size() < 2:
		return
	var first_vertex := vertices.size()
	for point_index in range(path.size()):
		var point: Vector3 = path[point_index]
		var tangent: Vector3
		if point_index == 0:
			tangent = (path[1] as Vector3 - point).normalized()
		elif point_index == path.size() - 1:
			tangent = (point - path[point_index - 1] as Vector3).normalized()
		else:
			tangent = ((path[point_index + 1] as Vector3) - (path[point_index - 1] as Vector3)).normalized()
		var reference := Vector3.UP if absf(tangent.dot(Vector3.UP)) < 0.91 else Vector3.RIGHT
		var axis_u := tangent.cross(reference).normalized()
		var axis_v := tangent.cross(axis_u).normalized()
		var local_radius := radius * width_profile[point_index]
		for side_index in range(TUBE_SIDES):
			var angle := TAU * float(side_index) / float(TUBE_SIDES)
			var radial := axis_u * cos(angle) + axis_v * sin(angle)
			vertices.append(point + radial * local_radius)
			colors.append(color)
	for point_index in range(path.size() - 1):
		for side_index in range(TUBE_SIDES):
			var next_side := (side_index + 1) % TUBE_SIDES
			var a := first_vertex + point_index * TUBE_SIDES + side_index
			var b := first_vertex + point_index * TUBE_SIDES + next_side
			var c := first_vertex + (point_index + 1) * TUBE_SIDES + side_index
			var d := first_vertex + (point_index + 1) * TUBE_SIDES + next_side
			indices.append(a)
			indices.append(b)
			indices.append(c)
			indices.append(b)
			indices.append(d)
			indices.append(c)

