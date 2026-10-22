extends Node3D
## Builds a visual-only Nordic 28 spade rudder at the actual imported hull
## underside. It never writes to the vessel profile or physical force model.

const RUDDER_BLADE_PATH := ^"RudderBlade"
const RUDDER_STOCK_PATH := ^"RudderStock"
const HULL_MESH_PATH := ^"../HullModelAdapter/Nordic28Model/node_0"
const LOCAL_SAMPLE_EPSILON := 0.0001
const FOIL_SECTIONS := [
	{"depth": 0.00, "chord_fraction": 1.00},
	{"depth": 0.22, "chord_fraction": 1.00},
	{"depth": 0.64, "chord_fraction": 0.90},
	{"depth": 0.92, "chord_fraction": 0.53},
	{"depth": 1.00, "chord_fraction": 0.08},
]
const CHORD_SAMPLES := [0.0, 0.12, 0.38, 0.72, 1.0]

@export var visual_profile: Resource

var _boat: RigidBody3D
var _visual_root: Node3D
var _rudder_blade: MeshInstance3D
var _rudder_stock: MeshInstance3D
var _hull_bottom_y_m := NAN
var _axis_embed_m := 0.0
var _pivot_body_local_m := Vector3.ZERO
var _foil_top_local_y_m := NAN
var _stock_length_m := 0.0
var _stock_bottom_y_local_m := 0.0
var _stock_top_y_local_m := 0.0
var _stock_foil_overlap_m := 0.0
var _blade_size_m := Vector3.ZERO
var _foil_planform_area_m2 := 0.0
var _force_point_local_m := Vector3.ZERO
var _configured := false
var _stern_faces_local: Array[PackedVector3Array] = []
var _foil_top_clearance_by_angle := {}


func _ready() -> void:
	_rudder_blade = get_node_or_null(RUDDER_BLADE_PATH) as MeshInstance3D
	_rudder_stock = get_node_or_null(RUDDER_STOCK_PATH) as MeshInstance3D
	call_deferred("_configure_from_hull")


func _configure_from_hull() -> void:
	_boat = get_parent().get_parent() as RigidBody3D
	_visual_root = get_parent() as Node3D
	var rig_anchors := _visual_root.get_node_or_null("VisualRigAnchors") if _visual_root != null else null
	if rig_anchors != null and rig_anchors.has_method("apply_visual_assembly_offset"):
		rig_anchors.call("apply_visual_assembly_offset")
	if _boat == null or visual_profile == null or _rudder_blade == null or _rudder_stock == null:
		push_warning("Nordic28RudderVisual missing boat, visual profile, blade, or stock node.")
		return
	var hull_mesh_instance := get_node_or_null(HULL_MESH_PATH) as MeshInstance3D
	if hull_mesh_instance == null or hull_mesh_instance.mesh == null:
		push_warning("Nordic28RudderVisual could not locate the Nordic 28 stern mesh.")
		return
	var physics_snapshot: Dictionary = _boat.call("get_debug_snapshot")
	_force_point_local_m = physics_snapshot.get("rudder_center_local_m", Vector3.ZERO)
	var body_from_mesh := _boat.global_transform.affine_inverse() * hull_mesh_instance.global_transform
	if not _cache_stern_mesh_faces(hull_mesh_instance.mesh, body_from_mesh, _force_point_local_m):
		push_warning("Nordic28RudderVisual found no stern hull triangles near the rudder axis.")
		return
	_hull_bottom_y_m = _hull_bottom_height_at(_force_point_local_m.x, _force_point_local_m.z)
	if not is_finite(_hull_bottom_y_m):
		push_warning("Nordic28RudderVisual could not sample the actual hull underside at the rudder axis.")
		return

	_axis_embed_m = float(visual_profile.get("rudder_axis_hull_embed_m"))
	_pivot_body_local_m = Vector3(
		_force_point_local_m.x,
		_hull_bottom_y_m + _axis_embed_m,
		_force_point_local_m.z
	)
	# Hull measurements and hydrodynamic points are in boat-local space, while
	# this visual node is parented below the visually offset VisualRoot.
	position = _visual_root.to_local(_boat.to_global(_pivot_body_local_m))
	var span := float(visual_profile.get("rudder_visual_span_m"))
	var max_chord := float(visual_profile.get("rudder_visual_max_chord_m"))
	_foil_top_local_y_m = _hull_bottom_y_m - float(visual_profile.get("rudder_foil_top_clearance_m")) - _pivot_body_local_m.y
	_rudder_blade.mesh = _build_foil_mesh(span, max_chord, _foil_top_local_y_m)
	_rudder_blade.position = Vector3.ZERO
	_rudder_blade.material_override = _make_bottom_paint_material()
	_blade_size_m = _rudder_blade.mesh.get_aabb().size
	_configure_stock(float(visual_profile.get("rudder_stock_radius_m")))
	_configured = true
	for angle_degrees in [-35.0, 0.0, 35.0]:
		_foil_top_clearance_by_angle[angle_degrees] = _minimum_foil_top_clearance(deg_to_rad(angle_degrees))
	_stern_faces_local.clear()


func _cache_stern_mesh_faces(mesh: Mesh, body_from_mesh: Transform3D, axis_local: Vector3) -> bool:
	_stern_faces_local.clear()
	var all_faces := mesh.get_faces()
	var chord_half := float(visual_profile.get("rudder_visual_max_chord_m")) * 0.5 + 0.20
	var stern_min_z := axis_local.z - chord_half - 0.30
	var stern_max_z := axis_local.z + chord_half + 0.30
	var side_min_x := axis_local.x - chord_half - 0.20
	var side_max_x := axis_local.x + chord_half + 0.20
	for index in range(0, all_faces.size(), 3):
		var a := body_from_mesh * all_faces[index]
		var b := body_from_mesh * all_faces[index + 1]
		var c := body_from_mesh * all_faces[index + 2]
		var min_x := minf(a.x, minf(b.x, c.x))
		var max_x := maxf(a.x, maxf(b.x, c.x))
		var min_z := minf(a.z, minf(b.z, c.z))
		var max_z := maxf(a.z, maxf(b.z, c.z))
		if max_x < side_min_x or min_x > side_max_x or max_z < stern_min_z or min_z > stern_max_z:
			continue
		_stern_faces_local.append(PackedVector3Array([a, b, c]))
	return not _stern_faces_local.is_empty()


func _hull_bottom_height_at(x: float, z: float) -> float:
	var lowest_y := INF
	for face in _stern_faces_local:
		var a: Vector3 = face[0]
		var b: Vector3 = face[1]
		var c: Vector3 = face[2]
		var denominator := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
		if absf(denominator) < LOCAL_SAMPLE_EPSILON:
			continue
		var weight_a := ((b.z - c.z) * (x - c.x) + (c.x - b.x) * (z - c.z)) / denominator
		var weight_b := ((c.z - a.z) * (x - c.x) + (a.x - c.x) * (z - c.z)) / denominator
		var weight_c := 1.0 - weight_a - weight_b
		if weight_a < -LOCAL_SAMPLE_EPSILON or weight_b < -LOCAL_SAMPLE_EPSILON or weight_c < -LOCAL_SAMPLE_EPSILON:
			continue
		lowest_y = minf(lowest_y, weight_a * a.y + weight_b * b.y + weight_c * c.y)
	return lowest_y


func _build_foil_mesh(span: float, max_chord: float, foil_top_y_from_pivot: float) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var section_rings: Array[PackedVector3Array] = []
	var chord_area := 0.0
	var previous_chord := 0.0
	var previous_depth := 0.0
	for section_index in range(FOIL_SECTIONS.size()):
		var section: Dictionary = FOIL_SECTIONS[section_index]
		var depth := float(section["depth"])
		var y := foil_top_y_from_pivot - span * depth
		var chord := max_chord * float(section["chord_fraction"])
		var leading_z := -0.25 * chord
		if section_index > 0:
			chord_area += 0.5 * (previous_chord + chord) * span * (depth - previous_depth)
		previous_chord = chord
		previous_depth = depth
		var ring := PackedVector3Array()
		for chord_fraction: float in CHORD_SAMPLES:
			var thickness := _foil_thickness(chord, chord_fraction)
			ring.append(Vector3(thickness, y, leading_z + chord * chord_fraction))
		for chord_index in range(CHORD_SAMPLES.size() - 1, -1, -1):
			var chord_fraction: float = CHORD_SAMPLES[chord_index]
			var thickness := _foil_thickness(chord, chord_fraction)
			ring.append(Vector3(-thickness, y, leading_z + chord * chord_fraction))
		section_rings.append(ring)
	_foil_planform_area_m2 = chord_area
	for ring_index in range(section_rings.size() - 1):
		var upper_ring := section_rings[ring_index]
		var lower_ring := section_rings[ring_index + 1]
		for point_index in range(upper_ring.size()):
			var next_index := (point_index + 1) % upper_ring.size()
			_add_triangle(surface, upper_ring[point_index], upper_ring[next_index], lower_ring[next_index])
			_add_triangle(surface, upper_ring[point_index], lower_ring[next_index], lower_ring[point_index])
	_add_cap(surface, section_rings[0], true)
	_add_cap(surface, section_rings[section_rings.size() - 1], false)
	surface.generate_normals()
	var foil := surface.commit()
	return foil as ArrayMesh


func _foil_thickness(chord: float, chord_fraction: float) -> float:
	if chord_fraction <= 0.0 or chord_fraction >= 1.0:
		return 0.0
	return chord * 0.095 * sin(PI * chord_fraction)


func _add_cap(surface: SurfaceTool, ring: PackedVector3Array, top: bool) -> void:
	var center := Vector3.ZERO
	for point in ring:
		center += point
	center /= float(ring.size())
	for index in range(ring.size()):
		var next_index := (index + 1) % ring.size()
		if top:
			_add_triangle(surface, center, ring[next_index], ring[index])
		else:
			_add_triangle(surface, center, ring[index], ring[next_index])


func _add_triangle(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	surface.add_vertex(a)
	surface.add_vertex(b)
	surface.add_vertex(c)


func _configure_stock(radius: float) -> void:
	_stock_top_y_local_m = _axis_embed_m + 0.03
	_stock_bottom_y_local_m = _foil_top_local_y_m - 0.03
	_stock_foil_overlap_m = maxf(_foil_top_local_y_m - _stock_bottom_y_local_m, 0.0)
	_stock_length_m = maxf(_stock_top_y_local_m - _stock_bottom_y_local_m, 0.01)
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = radius
	cylinder.bottom_radius = radius
	cylinder.height = _stock_length_m
	cylinder.radial_segments = 8
	cylinder.rings = 1
	_rudder_stock.mesh = cylinder
	_rudder_stock.position = Vector3(0.0, (_stock_top_y_local_m + _stock_bottom_y_local_m) * 0.5, 0.0)
	_rudder_stock.material_override = _make_bottom_paint_material()


func _make_bottom_paint_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.035, 0.085, 0.16, 1.0)
	material.roughness = 0.72
	material.metallic = 0.0
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


func get_visual_alignment_snapshot() -> Dictionary:
	return {
		"configured": _configured,
		"hull_bottom_y_local_m": _hull_bottom_y_m,
		"rudder_pivot_local_m": _pivot_body_local_m,
		"rudder_pivot_visual_root_local_m": position,
		"axis_embed_m": _axis_embed_m,
		"blade_size_m": _blade_size_m,
		"foil_planform_area_m2": _foil_planform_area_m2,
		"foil_top_local_y_m": _pivot_body_local_m.y + _foil_top_local_y_m,
		"stock_length_m": _stock_length_m,
		"stock_top_local_y_m": _pivot_body_local_m.y + _stock_top_y_local_m,
		"stock_bottom_local_y_m": _pivot_body_local_m.y + _stock_bottom_y_local_m,
		"stock_foil_overlap_m": _stock_foil_overlap_m,
		"force_point_local_m": _force_point_local_m,
		"physical_point_relative_to_visual_pivot_m": _force_point_local_m - _pivot_body_local_m,
		"physical_force_point_chord_fraction": _force_point_chord_fraction(),
		"physical_force_point_depth_fraction": _physical_force_point_depth_fraction(),
		"foil_top_clearance_by_angle_m": _foil_top_clearance_by_angle.duplicate(),
	}


func _physical_force_point_depth_fraction() -> float:
	if not _configured:
		return NAN
	var span := float(visual_profile.get("rudder_visual_span_m"))
	var force_point_y_from_pivot := _force_point_local_m.y - _pivot_body_local_m.y
	return (_foil_top_local_y_m - force_point_y_from_pivot) / span if span > 0.0 else NAN


func _force_point_chord_fraction() -> float:
	if not _configured:
		return NAN
	var span := float(visual_profile.get("rudder_visual_span_m"))
	var depth := _physical_force_point_depth_fraction()
	for index in range(FOIL_SECTIONS.size() - 1):
		var first: Dictionary = FOIL_SECTIONS[index]
		var second: Dictionary = FOIL_SECTIONS[index + 1]
		var first_depth := float(first["depth"])
		var second_depth := float(second["depth"])
		if depth < first_depth or depth > second_depth:
			continue
		var blend := inverse_lerp(first_depth, second_depth, depth)
		var chord := float(visual_profile.get("rudder_visual_max_chord_m")) * lerpf(
			float(first["chord_fraction"]), float(second["chord_fraction"]), blend
		)
		var leading_z := -0.25 * chord
		var force_z_from_pivot := _force_point_local_m.z - _pivot_body_local_m.z
		return (force_z_from_pivot - leading_z) / chord if chord > 0.0 else NAN
	return NAN


func _minimum_foil_top_clearance(rudder_angle_rad: float) -> float:
	if not _configured:
		return NAN
	var minimum_clearance := INF
	var max_chord := float(visual_profile.get("rudder_visual_max_chord_m"))
	var top_section: Dictionary = FOIL_SECTIONS[0]
	var top_chord := max_chord * float(top_section["chord_fraction"])
	var leading_z := -0.25 * top_chord
	var rotation := Basis(Vector3.UP, rudder_angle_rad)
	var top_y := _pivot_body_local_m.y + _foil_top_local_y_m
	for chord_fraction: float in CHORD_SAMPLES:
		for side: float in [-1.0, 1.0]:
			var thickness := _foil_thickness(top_chord, chord_fraction) * side
			var point_in_pivot := Vector3(thickness, _foil_top_local_y_m, leading_z + top_chord * chord_fraction)
			var rotated := rotation * point_in_pivot
			var hull_y := _hull_bottom_height_at(_pivot_body_local_m.x + rotated.x, _pivot_body_local_m.z + rotated.z)
			if is_finite(hull_y):
				minimum_clearance = minf(minimum_clearance, hull_y - top_y)
	return minimum_clearance
