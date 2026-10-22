extends Node3D
## Applies approved Nordic 28 visual rig anchors and measures them against the
## transformed hull mesh. Physical sail centres remain in the vessel profile.

const AERO_MATH := preload("res://scripts/sailboat_aero_math.gd")
const TRIM_ANGLES_DEGREES := [0.0, 30.0, -30.0, 60.0, -60.0, 70.0, -70.0, 80.0, -80.0]
const ROOF_GRID_CELL_M := 0.20

@export var visual_profile: Resource
@export_node_path("Node3D") var hull_adapter_path: NodePath = ^"../HullModelAdapter"
@export_node_path("Node3D") var nordic_model_path: NodePath = ^"../HullModelAdapter/Nordic28Model"
@export_node_path("MeshInstance3D") var hull_mesh_path: NodePath = ^"../HullModelAdapter/Nordic28Model/node_0"
@export_node_path("MeshInstance3D") var mast_mesh_path: NodePath = ^"../Mast"
@export_node_path("Node3D") var boom_pivot_path: NodePath = ^"../VisualBoomPivot"
@export_node_path("MeshInstance3D") var boom_mesh_path: NodePath = ^"../VisualBoomPivot/Boom"
@export_node_path("MeshInstance3D") var main_sail_mesh_path: NodePath = ^"../VisualBoomPivot/MainSailMesh"
@export_node_path("MeshInstance3D") var jib_mesh_path: NodePath = ^"../HeadsailVisual"

var _hull_points_local: PackedVector3Array = PackedVector3Array()
var _hull_faces_local: Array[PackedVector3Array] = []
var _hull_spatial_grid: Dictionary = {}
var _hull_min_z := 0.0
var _hull_max_z := 0.0
var _cabin_roof_y := 0.0
var _mast_station_z := 0.0
var _mast_support_y := NAN
var _visual_boom_local := Vector3.ZERO
var _visual_mast_base_local := Vector3.ZERO
var _visual_mast_top_local := Vector3.ZERO
var _visual_main_clew_local := Vector3.ZERO
var _visual_main_head_local := Vector3.ZERO
var _visual_jib_head_local := Vector3.ZERO
var _visual_jib_tack_local := Vector3.ZERO
var _visual_jib_clew_local := Vector3.ZERO
var _configured := false


func _ready() -> void:
	apply_visual_assembly_offset()
	call_deferred("_configure_visual_rig")


func apply_visual_assembly_offset() -> void:
	if visual_profile == null:
		return
	var visual_root := get_parent() as Node3D
	if visual_root == null:
		return
	# Assign the configured offset instead of adding it, so repeated setup cannot
	# accumulate the 30 cm draft adjustment.
	visual_root.position = visual_profile.get("visual_assembly_offset_local_m")


func _configure_visual_rig() -> void:
	var hull_adapter := get_node_or_null(hull_adapter_path) as Node3D
	var nordic_model := get_node_or_null(nordic_model_path) as Node3D
	var hull_mesh := get_node_or_null(hull_mesh_path) as MeshInstance3D
	var mast_mesh := get_node_or_null(mast_mesh_path) as MeshInstance3D
	var boom_pivot := get_node_or_null(boom_pivot_path) as Node3D
	var boom_mesh := get_node_or_null(boom_mesh_path) as MeshInstance3D
	var main_sail_mesh := get_node_or_null(main_sail_mesh_path) as MeshInstance3D
	var jib_mesh := get_node_or_null(jib_mesh_path) as MeshInstance3D
	if visual_profile == null or hull_adapter == null or nordic_model == null or hull_mesh == null or hull_mesh.mesh == null:
		push_warning("Nordic28VisualRigAnchors could not read the Nordic 28 hull mesh; visual defaults are retained.")
		return
	if not _cache_hull_points(hull_adapter, nordic_model, hull_mesh):
		push_warning("Nordic28VisualRigAnchors found no usable hull vertices; visual defaults are retained.")
		return
	if not _derive_roof_and_mast_station():
		push_warning("Nordic28VisualRigAnchors could not locate the cabin roof; visual defaults are retained.")
		return

	_visual_mast_base_local = visual_profile.get("mast_base_local_m")
	var mast_height := float(visual_profile.get("mast_length_m"))
	_visual_mast_top_local = _visual_mast_base_local + Vector3.UP * mast_height
	_visual_boom_local = visual_profile.get("boom_pivot_local_m")
	_visual_main_head_local = visual_profile.get("main_head_local_m")
	_visual_main_clew_local = _visual_boom_local + Vector3(0.0, 0.0, float(visual_profile.get("boom_length_m")))
	_visual_jib_head_local = visual_profile.get("jib_head_local_m")
	_mast_station_z = _visual_mast_base_local.z
	_mast_support_y = _hull_surface_height_at(_visual_mast_base_local.x, _mast_station_z)
	_cabin_roof_y = _roof_height_at(_mast_station_z)
	if not is_finite(_cabin_roof_y):
		_cabin_roof_y = _mast_support_y
	var configured_step_embed := float(visual_profile.get("mast_step_embed_m"))
	var measured_step_embed := _mast_support_y - _visual_mast_base_local.y
	if absf(measured_step_embed - configured_step_embed) > 0.01:
		push_warning("Nordic 28 MastBase differs from the configured step embed by %.3f m." % (measured_step_embed - configured_step_embed))
	var boom_clearance_target := float(visual_profile.get("boom_clearance_over_roof_m"))
	var measured_boom_clearance := _visual_boom_local.y - _cabin_roof_y
	if absf(measured_boom_clearance - boom_clearance_target) > 0.05:
		push_warning("Nordic 28 Boom differs from its roof-clearance target by %.3f m." % (measured_boom_clearance - boom_clearance_target))
	var minimum_boom_clearance := float(visual_profile.get("minimum_boom_lower_edge_clearance_m"))
	var current_boom_clearance := _minimum_main_boom_lower_clearance()
	if is_finite(current_boom_clearance) and current_boom_clearance < minimum_boom_clearance:
		push_warning("Approved Nordic 28 boom anchors have only %.3f m sampled hull clearance (minimum %.3f m)." % [current_boom_clearance, minimum_boom_clearance])

	_configure_mast_mesh(mast_mesh, _visual_mast_base_local, _visual_mast_top_local)
	_set_marker("VisualMastBase", _visual_mast_base_local)
	_set_marker("VisualMastTop", _visual_mast_top_local)
	_set_marker("VisualBoomPivot", _visual_boom_local)
	_set_marker("VisualMainTack", _visual_boom_local)
	_set_marker("VisualMainHead", _visual_main_head_local)
	_set_marker("VisualJibHead", _visual_jib_head_local)
	_set_marker("VisualMainClew", _visual_main_clew_local)

	if boom_pivot != null:
		boom_pivot.position = _visual_boom_local
	if boom_mesh != null:
		var boom_length := _visual_main_clew_local.distance_to(_visual_boom_local)
		if boom_mesh.mesh is CylinderMesh:
			(boom_mesh.mesh as CylinderMesh).height = boom_length
		boom_mesh.position = Vector3(0.0, 0.0, boom_length * 0.5)
		_configure_main_sail(main_sail_mesh, _visual_boom_local, _visual_main_head_local, _visual_main_clew_local)
	_configure_jib(jib_mesh)
	_configured = true


func _cache_hull_points(hull_adapter: Node3D, nordic_model: Node3D, hull_mesh: MeshInstance3D) -> bool:
	_hull_points_local.clear()
	_hull_faces_local.clear()
	_hull_spatial_grid.clear()
	var vertex_transform := hull_adapter.transform * nordic_model.transform * hull_mesh.transform
	for surface_index in range(hull_mesh.mesh.get_surface_count()):
		var arrays := hull_mesh.mesh.surface_get_arrays(surface_index)
		if arrays.size() <= Mesh.ARRAY_VERTEX:
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for vertex in vertices:
			var point := vertex_transform * vertex
			_hull_points_local.append(point)
			var cell := Vector2i(floori(point.x / ROOF_GRID_CELL_M), floori(point.z / ROOF_GRID_CELL_M))
			var cell_points: Array = _hull_spatial_grid.get(cell, [])
			cell_points.append(point)
			_hull_spatial_grid[cell] = cell_points
	var mesh_faces := hull_mesh.mesh.get_faces()
	for face_index in range(0, mesh_faces.size() - 2, 3):
		_hull_faces_local.append(PackedVector3Array([
			vertex_transform * mesh_faces[face_index],
			vertex_transform * mesh_faces[face_index + 1],
			vertex_transform * mesh_faces[face_index + 2],
		]))
	if _hull_points_local.is_empty():
		return false
	_hull_min_z = _hull_points_local[0].z
	_hull_max_z = _hull_points_local[0].z
	for point in _hull_points_local:
		_hull_min_z = minf(_hull_min_z, point.z)
		_hull_max_z = maxf(_hull_max_z, point.z)
	return _hull_max_z - _hull_min_z > 1.0


func _derive_roof_and_mast_station() -> bool:
	var configured_mast_base: Vector3 = visual_profile.get("mast_base_local_m")
	_mast_station_z = configured_mast_base.z
	_cabin_roof_y = _roof_height_at(_mast_station_z)
	_mast_support_y = _hull_surface_height_at(configured_mast_base.x, _mast_station_z)
	return is_finite(_cabin_roof_y) and _cabin_roof_y > 0.5 and is_finite(_mast_support_y)


func _roof_height_at(local_z: float) -> float:
	var half_width := float(visual_profile.get("roof_sample_half_width_m"))
	var half_length := float(visual_profile.get("roof_sample_half_length_m"))
	var highest := -INF
	for point in _hull_points_local:
		if absf(point.x) <= half_width and absf(point.z - local_z) <= half_length:
			highest = maxf(highest, point.y)
	return highest


func _hull_surface_height_at(local_x: float, local_z: float) -> float:
	var highest := -INF
	for face in _hull_faces_local:
		var a: Vector3 = face[0]
		var b: Vector3 = face[1]
		var c: Vector3 = face[2]
		var denominator := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
		if absf(denominator) < 0.000001:
			continue
		var weight_a := ((b.z - c.z) * (local_x - c.x) + (c.x - b.x) * (local_z - c.z)) / denominator
		var weight_b := ((c.z - a.z) * (local_x - c.x) + (a.x - c.x) * (local_z - c.z)) / denominator
		var weight_c := 1.0 - weight_a - weight_b
		if weight_a < -0.0001 or weight_b < -0.0001 or weight_c < -0.0001:
			continue
		highest = maxf(highest, weight_a * a.y + weight_b * b.y + weight_c * c.y)
	return highest


func _configure_mast_mesh(mast_mesh: MeshInstance3D, mast_base: Vector3, mast_top: Vector3) -> void:
	if mast_mesh == null or not mast_mesh.mesh is CylinderMesh:
		return
	var mast_cylinder := mast_mesh.mesh as CylinderMesh
	mast_cylinder.height = mast_base.distance_to(mast_top)
	mast_mesh.position = (mast_base + mast_top) * 0.5


func _configure_main_sail(main_sail_mesh: MeshInstance3D, boom_local: Vector3, head_local: Vector3, clew_local: Vector3) -> void:
	if main_sail_mesh == null or not main_sail_mesh.has_method("configure"):
		return
	var head_from_pivot := head_local - boom_local
	var tack_from_pivot := Vector3.ZERO
	var clew_from_pivot := clew_local - boom_local
	main_sail_mesh.call("configure", head_from_pivot, tack_from_pivot, clew_from_pivot)


func _configure_jib(jib_mesh: MeshInstance3D) -> void:
	if jib_mesh == null or not jib_mesh.has_method("configure"):
		return
	_visual_jib_head_local = visual_profile.get("jib_head_local_m")
	_visual_jib_tack_local = visual_profile.get("jib_tack_local_m")
	_visual_jib_clew_local = visual_profile.get("jib_clew_local_m")
	_set_marker("VisualJibHead", _visual_jib_head_local)
	_set_marker("VisualJibTack", _visual_jib_tack_local)
	_set_marker("VisualJibClew", _visual_jib_clew_local)
	jib_mesh.call("configure", _visual_jib_head_local, _visual_jib_tack_local, _visual_jib_clew_local)


func _set_marker(marker_name: String, local_position: Vector3) -> void:
	var marker := get_node_or_null(marker_name) as Marker3D
	if marker != null:
		marker.position = local_position


func is_configured() -> bool:
	return _configured


func get_hull_surface_height_at(local_x: float, local_z: float) -> float:
	## Visual-only hull surface lookup used to seat standing rigging and sheet
	## fairleads on the imported Nordic 28 model. Never feeds vessel physics.
	if not _configured or not is_finite(local_x) or not is_finite(local_z):
		return NAN
	return _hull_surface_height_at(local_x, local_z)


func get_alignment_snapshot() -> Dictionary:
	var main_clearances: Dictionary = {}
	var jib_clearances: Dictionary = {}
	var main_clews_by_angle: Dictionary = {}
	var jib_clews_by_angle: Dictionary = {}
	for angle_degrees in TRIM_ANGLES_DEGREES:
		var angle := deg_to_rad(float(angle_degrees))
		var main_clew_at_angle := _visual_boom_local + Basis(Vector3.UP, angle) * Vector3(0.0, 0.0, _main_boom_length())
		main_clews_by_angle[angle_degrees] = main_clew_at_angle
		main_clearances[angle_degrees] = _measure_segment_clearance(
			_visual_boom_local,
			main_clew_at_angle,
			false
		)
		var jib_clew_at_angle: Vector3 = AERO_MATH.headsail_clew_from_sheet(_visual_jib_tack_local, _visual_jib_clew_local, angle)
		jib_clews_by_angle[angle_degrees] = jib_clew_at_angle
		jib_clearances[angle_degrees] = _measure_segment_clearance(_visual_jib_tack_local, jib_clew_at_angle, true)
	var main_area := AERO_MATH.triangular_sail_area_m2(_visual_main_head_local, _visual_boom_local, _visual_main_clew_local)
	var jib_area := AERO_MATH.triangular_sail_area_m2(_visual_jib_head_local, _visual_jib_tack_local, _visual_jib_clew_local)
	return {
		"configured": _configured,
		"visual_assembly_offset_local_m": (get_parent() as Node3D).position if get_parent() is Node3D else Vector3.ZERO,
		"hull_length_m": _hull_max_z - _hull_min_z,
		"cabin_roof_y_m": _cabin_roof_y,
		"mast_station_z_m": _mast_station_z,
		"mast_centerline_support_y_m": _mast_support_y,
		"mast_step_embed_measured_m": _mast_support_y - _visual_mast_base_local.y if is_finite(_mast_support_y) else NAN,
		"mast_step_embed_target_m": float(visual_profile.get("mast_step_embed_m")),
		"mast_length_m": _visual_mast_base_local.distance_to(_visual_mast_top_local),
		"visual_mast_base_local_m": _visual_mast_base_local,
		"visual_mast_top_local_m": _visual_mast_top_local,
		"visual_boom_local_m": _visual_boom_local,
		"visual_main_tack_local_m": _visual_boom_local,
		"visual_main_clew_local_m": _visual_main_clew_local,
		"visual_main_head_local_m": _visual_main_head_local,
		"visual_jib_head_local_m": _visual_jib_head_local,
		"visual_jib_tack_local_m": _visual_jib_tack_local,
		"visual_jib_clew_local_m": _visual_jib_clew_local,
		"boom_length_m": _visual_boom_local.distance_to(_visual_main_clew_local),
		"boom_roof_clearance_m": _visual_boom_local.y - _cabin_roof_y,
		"boom_roof_clearance_target_m": float(visual_profile.get("boom_clearance_over_roof_m")),
		"main_visual_area_m2": main_area,
		"jib_visual_area_m2": jib_area,
		"main_lower_edge_clearance_m": main_clearances,
		"main_clew_by_angle_local_m": main_clews_by_angle,
		"jib_lower_edge_clearance_m": jib_clearances,
		"jib_clew_by_angle_local_m": jib_clews_by_angle,
	}


func _main_boom_length() -> float:
	return float(visual_profile.get("boom_length_m")) if visual_profile != null else 3.30


func _measure_segment_clearance(start: Vector3, end: Vector3, include_mesh_radius: bool) -> float:
	if _hull_points_local.is_empty():
		return -INF
	var minimum_clearance := INF
	var found_hull := false
	for sample_index in range(41):
		var ratio := float(sample_index) / 40.0
		var point := start.lerp(end, ratio)
		var local_roof := _highest_hull_point_near(point)
		if not is_finite(local_roof):
			continue
		var radius := 0.0
		if include_mesh_radius:
			radius = 0.0
		else:
			var boom_mesh := get_node_or_null(boom_mesh_path) as MeshInstance3D
			if boom_mesh != null and boom_mesh.mesh is CylinderMesh:
				radius = maxf((boom_mesh.mesh as CylinderMesh).top_radius, (boom_mesh.mesh as CylinderMesh).bottom_radius)
		minimum_clearance = minf(minimum_clearance, point.y - local_roof - radius)
		found_hull = true
	return minimum_clearance if found_hull else -INF


func _highest_hull_point_near(position: Vector3) -> float:
	var highest := -INF
	var max_distance_squared := 0.22 * 0.22
	var radius_cells := ceili(0.22 / ROOF_GRID_CELL_M) + 1
	var center_cell := Vector2i(floori(position.x / ROOF_GRID_CELL_M), floori(position.z / ROOF_GRID_CELL_M))
	for x_offset in range(-radius_cells, radius_cells + 1):
		for z_offset in range(-radius_cells, radius_cells + 1):
			var cell_points: Array = _hull_spatial_grid.get(center_cell + Vector2i(x_offset, z_offset), [])
			for hull_point_variant in cell_points:
				var hull_point: Vector3 = hull_point_variant
				var dx := hull_point.x - position.x
				var dz := hull_point.z - position.z
				if dx * dx + dz * dz <= max_distance_squared:
					highest = maxf(highest, hull_point.y)
	return highest


func _minimum_main_boom_lower_clearance() -> float:
	var minimum := INF
	for angle_degrees in TRIM_ANGLES_DEGREES:
		var angle := deg_to_rad(float(angle_degrees))
		var end := _visual_boom_local + Basis(Vector3.UP, angle) * Vector3(0.0, 0.0, _main_boom_length())
		minimum = minf(minimum, _measure_segment_clearance(_visual_boom_local, end, false))
	return minimum
