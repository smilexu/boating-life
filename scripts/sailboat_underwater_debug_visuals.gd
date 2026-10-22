extends Node3D
## SailboatLab-only visual markers. This node never submits forces or changes
## collision, buoyancy, wind, or wave state.

const SYNC_INTERVAL_S := 0.10
const MARKER_RADIUS_M := 0.095

var _boat: RigidBody3D
var _sync_elapsed := 0.0
var _enabled := {
	"rudder_axis": false,
	"rudder_force_point": false,
	"keel_force_point": false,
	"collision_outline": false,
	"float_points": false,
}
var _markers: Dictionary = {}
var _collision_outline: MeshInstance3D
var _rudder_axis: MeshInstance3D
var _support_status := ""


func _ready() -> void:
	_boat = get_parent() as RigidBody3D
	_create_debug_geometry()
	_sync_markers()


func _process(delta: float) -> void:
	_sync_elapsed += delta
	if _sync_elapsed < SYNC_INTERVAL_S:
		return
	_sync_elapsed = 0.0
	_sync_markers()


func set_marker_enabled(marker_name: String, enabled: bool) -> void:
	if not _enabled.has(marker_name):
		return
	_enabled[marker_name] = enabled
	_sync_markers()


func is_marker_enabled(marker_name: String) -> bool:
	return bool(_enabled.get(marker_name, false))


func get_inspection_snapshot() -> Dictionary:
	if _boat == null:
		return {"available": false, "status": "未找到帆船刚体"}
	var physics: Dictionary = _boat.call("get_debug_snapshot")
	var body_inverse := _boat.global_transform.affine_inverse()
	var rudder_pivot := _boat.get_node_or_null("VisualRoot/RudderPivot") as Node3D
	var rudder_blade := _boat.get_node_or_null("VisualRoot/RudderPivot/RudderBlade") as MeshInstance3D
	var collision := _boat.get_node_or_null("CollisionShape3D") as CollisionShape3D
	var hull_bounds := _get_mesh_bounds_in_body_local("VisualRoot/HullModelAdapter/Nordic28Model", body_inverse)
	var rudder_bounds := _get_node_mesh_bounds_in_body_local(rudder_blade, body_inverse)
	var float_points: PackedVector3Array = physics.get("float_point_offsets_local_m", PackedVector3Array())
	var water_height := float(physics.get("water_height_m", 0.0))
	var water_plane_at_body := body_inverse * Vector3(_boat.global_position.x, water_height, _boat.global_position.z)
	var axis_local := Vector3.UP
	var pivot_local := Vector3.ZERO
	var visual_rudder_angle := 0.0
	if rudder_pivot != null:
		pivot_local = body_inverse * rudder_pivot.global_position
		axis_local = (_boat.global_basis.inverse() * rudder_pivot.global_basis * Vector3.UP).normalized()
		visual_rudder_angle = rudder_pivot.rotation.y
	var snapshot := {
		"available": true,
		"nordic_hull_found": hull_bounds.get("valid", false),
		"nordic_hull_size_m": hull_bounds.get("size", Vector3.ZERO),
		"nordic_hull_min_local_m": hull_bounds.get("min", Vector3.ZERO),
		"nordic_hull_max_local_m": hull_bounds.get("max", Vector3.ZERO),
		"waterline_local_y_m": water_plane_at_body.y,
		"rudder_pivot_found": rudder_pivot != null,
		"rudder_pivot_local_m": pivot_local,
		"rudder_axis_local": axis_local,
		"rudder_visual_angle_rad": visual_rudder_angle,
		"rudder_actual_angle_rad": float(physics.get("actual_rudder_angle_rad", 0.0)),
		"rudder_force_point_local_m": physics.get("rudder_center_local_m", Vector3.ZERO),
		"rudder_blade_bounds_valid": rudder_bounds.get("valid", false),
		"rudder_blade_min_local_m": rudder_bounds.get("min", Vector3.ZERO),
		"rudder_blade_max_local_m": rudder_bounds.get("max", Vector3.ZERO),
		"keel_force_point_local_m": physics.get("keel_center_local_m", Vector3.ZERO),
		"float_points_local_m": float_points,
		"collision_shape_type": _collision_shape_type(collision),
		"collision_shape_bounds_local_m": _get_collision_bounds_in_body_local(collision),
		"marker_flags": _enabled.duplicate(),
		"status": _support_status,
	}
	if rudder_pivot != null and rudder_pivot.has_method("get_visual_alignment_snapshot"):
		var rudder_alignment: Dictionary = rudder_pivot.call("get_visual_alignment_snapshot")
		snapshot["rudder_hull_bottom_y_local_m"] = rudder_alignment.get("hull_bottom_y_local_m", NAN)
		snapshot["rudder_axis_embed_m"] = rudder_alignment.get("axis_embed_m", 0.0)
		snapshot["rudder_stock_length_m"] = rudder_alignment.get("stock_length_m", 0.0)
		snapshot["rudder_visual_blade_size_m"] = rudder_alignment.get("blade_size_m", Vector3.ZERO)
		snapshot["rudder_foil_planform_area_m2"] = rudder_alignment.get("foil_planform_area_m2", 0.0)
		snapshot["rudder_foil_top_local_y_m"] = rudder_alignment.get("foil_top_local_y_m", NAN)
		snapshot["rudder_visual_force_point_offset_m"] = rudder_alignment.get("physical_point_relative_to_visual_pivot_m", Vector3.ZERO)
		snapshot["rudder_force_point_chord_fraction"] = rudder_alignment.get("physical_force_point_chord_fraction", NAN)
		snapshot["rudder_force_point_depth_fraction"] = rudder_alignment.get("physical_force_point_depth_fraction", NAN)
		snapshot["rudder_foil_top_clearance_by_angle_m"] = rudder_alignment.get("foil_top_clearance_by_angle_m", {})
	return snapshot


func _create_debug_geometry() -> void:
	if _boat == null:
		return
	var outline_material := _make_marker_material(Color(0.27, 0.96, 0.62, 0.95))
	var outline_mesh := BoxMesh.new()
	var collision := _boat.get_node_or_null("CollisionShape3D") as CollisionShape3D
	var box_shape := collision.shape as BoxShape3D if collision != null else null
	if box_shape != null:
		_collision_outline = _create_mesh_instance(
			"CollisionOutline",
			_build_box_outline_mesh(box_shape.size, outline_material),
			outline_material
		)
	else:
		_support_status = "碰撞轮廓目前只支持 BoxShape3D"

	var axis_mesh := CylinderMesh.new()
	axis_mesh.top_radius = 0.018
	axis_mesh.bottom_radius = 0.018
	axis_mesh.height = 0.82
	axis_mesh.radial_segments = 8
	_rudder_axis = _create_mesh_instance("RudderAxisMarker", axis_mesh, _make_marker_material(Color(1.0, 0.32, 0.18, 1.0)))

	_add_sphere_marker("RudderForcePoint", Color(0.18, 0.88, 1.0, 1.0))
	_add_sphere_marker("KeelForcePoint", Color(1.0, 0.28, 0.75, 1.0))
	for index in range(4):
		_add_sphere_marker("FloatPoint%d" % index, Color(1.0, 0.82, 0.2, 1.0))
	_apply_marker_visibility()


func _add_sphere_marker(marker_name: String, color: Color) -> void:
	var sphere := SphereMesh.new()
	sphere.radius = MARKER_RADIUS_M
	sphere.height = MARKER_RADIUS_M * 2.0
	sphere.radial_segments = 8
	sphere.rings = 4
	_markers[marker_name] = _create_mesh_instance(marker_name, sphere, _make_marker_material(color))


func _create_mesh_instance(node_name: String, mesh: Mesh, material: StandardMaterial3D) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)
	return instance


func _make_marker_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 0.35
	return material


func _build_box_outline_mesh(size: Vector3, material: StandardMaterial3D) -> ImmediateMesh:
	var mesh := ImmediateMesh.new()
	var half := size * 0.5
	var corners := [
		Vector3(-half.x, -half.y, -half.z), Vector3(half.x, -half.y, -half.z),
		Vector3(half.x, -half.y, half.z), Vector3(-half.x, -half.y, half.z),
		Vector3(-half.x, half.y, -half.z), Vector3(half.x, half.y, -half.z),
		Vector3(half.x, half.y, half.z), Vector3(-half.x, half.y, half.z),
	]
	var edges := [
		Vector2i(0, 1), Vector2i(1, 2), Vector2i(2, 3), Vector2i(3, 0),
		Vector2i(4, 5), Vector2i(5, 6), Vector2i(6, 7), Vector2i(7, 4),
		Vector2i(0, 4), Vector2i(1, 5), Vector2i(2, 6), Vector2i(3, 7),
	]
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	for edge: Vector2i in edges:
		mesh.surface_add_vertex(corners[edge.x])
		mesh.surface_add_vertex(corners[edge.y])
	mesh.surface_end()
	return mesh


func _sync_markers() -> void:
	if _boat == null or not is_inside_tree():
		return
	var physics: Dictionary = _boat.call("get_debug_snapshot")
	var body_inverse := _boat.global_transform.affine_inverse()
	var rudder_pivot := _boat.get_node_or_null("VisualRoot/RudderPivot") as Node3D
	var collision := _boat.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if _collision_outline != null and collision != null:
		_collision_outline.transform = body_inverse * collision.global_transform
	if _rudder_axis != null and rudder_pivot != null:
		_rudder_axis.transform = body_inverse * rudder_pivot.global_transform
	var rudder_point: Vector3 = physics.get("rudder_center_local_m", Vector3.ZERO)
	var keel_point: Vector3 = physics.get("keel_center_local_m", Vector3.ZERO)
	_set_marker_position("RudderForcePoint", rudder_point)
	_set_marker_position("KeelForcePoint", keel_point)
	var float_points: PackedVector3Array = physics.get("float_point_offsets_local_m", PackedVector3Array())
	for index in range(4):
		if index < float_points.size():
			_set_marker_position("FloatPoint%d" % index, float_points[index])
	_apply_marker_visibility()


func _set_marker_position(marker_name: String, position_local: Vector3) -> void:
	var marker := _markers.get(marker_name) as MeshInstance3D
	if marker != null:
		marker.position = position_local


func _apply_marker_visibility() -> void:
	if _collision_outline != null:
		_collision_outline.visible = bool(_enabled.get("collision_outline", false))
	if _rudder_axis != null:
		_rudder_axis.visible = bool(_enabled.get("rudder_axis", false))
	if _markers.has("RudderForcePoint"):
		(_markers["RudderForcePoint"] as MeshInstance3D).visible = bool(_enabled.get("rudder_force_point", false))
	if _markers.has("KeelForcePoint"):
		(_markers["KeelForcePoint"] as MeshInstance3D).visible = bool(_enabled.get("keel_force_point", false))
	for index in range(4):
		var marker := _markers.get("FloatPoint%d" % index) as MeshInstance3D
		if marker != null:
			marker.visible = bool(_enabled.get("float_points", false))


func _get_mesh_bounds_in_body_local(path: String, body_inverse: Transform3D) -> Dictionary:
	var root := _boat.get_node_or_null(NodePath(path))
	if root == null:
		return {"valid": false}
	var result := _empty_bounds()
	_collect_mesh_bounds(root, body_inverse, result)
	return _finish_bounds(result)


func _collect_mesh_bounds(node: Node, body_inverse: Transform3D, result: Dictionary) -> void:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh != null:
			_include_aabb(mesh_instance.mesh.get_aabb(), body_inverse * mesh_instance.global_transform, result)
	for child in node.get_children():
		_collect_mesh_bounds(child, body_inverse, result)


func _get_node_mesh_bounds_in_body_local(node: MeshInstance3D, body_inverse: Transform3D) -> Dictionary:
	if node == null or node.mesh == null:
		return {"valid": false}
	var result := _empty_bounds()
	_include_aabb(node.mesh.get_aabb(), body_inverse * node.global_transform, result)
	return _finish_bounds(result)


func _include_aabb(bounds: AABB, transform: Transform3D, result: Dictionary) -> void:
	for x_sign in [0.0, 1.0]:
		for y_sign in [0.0, 1.0]:
			for z_sign in [0.0, 1.0]:
				var corner := bounds.position + Vector3(bounds.size.x * x_sign, bounds.size.y * y_sign, bounds.size.z * z_sign)
				var point := transform * corner
				var minimum: Vector3 = result["min"]
				var maximum: Vector3 = result["max"]
				result["min"] = minimum.min(point)
				result["max"] = maximum.max(point)
				result["valid"] = true


func _empty_bounds() -> Dictionary:
	return {"valid": false, "min": Vector3(INF, INF, INF), "max": Vector3(-INF, -INF, -INF)}


func _finish_bounds(result: Dictionary) -> Dictionary:
	if not bool(result.get("valid", false)):
		return result
	var minimum: Vector3 = result["min"]
	var maximum: Vector3 = result["max"]
	result["size"] = maximum - minimum
	return result


func _get_collision_bounds_in_body_local(collision: CollisionShape3D) -> Dictionary:
	if collision == null or not collision.shape is BoxShape3D:
		return {"valid": false}
	var box := collision.shape as BoxShape3D
	var result := _empty_bounds()
	_include_aabb(AABB(-box.size * 0.5, box.size), _boat.global_transform.affine_inverse() * collision.global_transform, result)
	return _finish_bounds(result)


func _collision_shape_type(collision: CollisionShape3D) -> String:
	if collision == null or collision.shape == null:
		return "不可用"
	return collision.shape.get_class()
