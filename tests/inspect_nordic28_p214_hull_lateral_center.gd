extends SceneTree
## Read-only P2.14 estimate of the immersed hull's lateral side-projection
## centroid. The merged central keel fin is excluded by the documented region.

const LAB_SCENE := preload("res://scenes/SailboatLabP23c.tscn")
const PHYSICS_PROFILE_PATH := "res://resources/sailing/nordic28_p23c_physics_profile.tres"
const VISUAL_PROFILE_PATH := "res://resources/sailing/nordic28_p23c_visual_rig_profile.tres"
const KEEL_HALF_WIDTH_M := 0.25
const KEEL_TOP_Y_M := -0.60

var _lab: Node3D


func _initialize() -> void:
	call_deferred("_inspect")


func _inspect() -> void:
	_lab = LAB_SCENE.instantiate() as Node3D
	root.add_child(_lab)
	await process_frame
	await process_frame
	var boat := _lab.get_node_or_null("SailboatBody") as RigidBody3D
	var mesh_instance := boat.get_node_or_null("VisualRoot/HullModelAdapter/Nordic28Model/node_0") as MeshInstance3D if boat != null else null
	if boat == null or mesh_instance == null or mesh_instance.mesh == null:
		_finish(2, "P2.3c Nordic 28 hull mesh was not found")
		return
	var physics: Resource = boat.get("profile") as Resource
	var rig := boat.get_node_or_null("VisualRoot/VisualRigAnchors") as Node3D
	var visual: Resource = rig.get("visual_profile") as Resource if rig != null else null
	if physics == null or visual == null or physics.resource_path != PHYSICS_PROFILE_PATH or visual.resource_path != VISUAL_PROFILE_PATH:
		_finish(2, "The scene did not bind the expected P2.3c physics and visual Profiles")
		return
	var float_points: PackedVector3Array = physics.get("float_point_offsets_m")
	var mean_float_y := 0.0
	for point in float_points:
		mean_float_y += point.y
	mean_float_y /= float(maxi(float_points.size(), 1))
	var waterline_body_local_y := float(physics.get("rest_submergence_m")) + mean_float_y
	var body_from_mesh := boat.global_transform.affine_inverse() * mesh_instance.global_transform
	var full_stats := _measure_projection(mesh_instance.mesh, body_from_mesh, waterline_body_local_y, false, KEEL_HALF_WIDTH_M, KEEL_TOP_Y_M)
	var hull_stats := _measure_projection(mesh_instance.mesh, body_from_mesh, waterline_body_local_y, true, KEEL_HALF_WIDTH_M, KEEL_TOP_Y_M)
	if float(hull_stats.get("projected_area_m2", 0.0)) <= 0.0:
		_finish(2, "No immersed lateral hull projection survived the keel exclusion")
		return
	var com_local: Vector3 = physics.get("center_of_mass_m")
	var full_center: Vector3 = full_stats["centroid_local_m"]
	var hull_center: Vector3 = hull_stats["centroid_local_m"]
	var sensitivity := []
	for keel_width in [0.20, 0.25, 0.30]:
		for keel_top in [-0.50, -0.60, -0.70]:
			var sample := _measure_projection(mesh_instance.mesh, body_from_mesh, waterline_body_local_y, true, keel_width, keel_top)
			sensitivity.append({
				"keel_exclusion_half_width_m": keel_width,
				"keel_exclusion_top_y_m": keel_top,
				"projected_area_m2": sample.get("projected_area_m2", 0.0),
				"centroid_local_m": sample.get("centroid_local_m", Vector3.ZERO),
			})
	var result := {
		"boat_scene": "res://scenes/boats/SailingBoat8mP23c.tscn",
		"physics_profile_path": PHYSICS_PROFILE_PATH,
		"visual_profile_path": VISUAL_PROFILE_PATH,
		"mesh_path": "VisualRoot/HullModelAdapter/Nordic28Model/node_0",
		"mesh_surface_count": mesh_instance.mesh.get_surface_count(),
		"body_from_mesh_transform": body_from_mesh,
		"hull_visual_assembly_offset_local_m": visual.get("visual_assembly_offset_local_m"),
		"waterline_derivation": "static reset: body_origin_y = water_height - rest_submergence - mean_float_y; therefore body-local waterline_y = rest_submergence + mean_float_y",
		"waterline_body_local_y_m": waterline_body_local_y,
		"rest_submergence_m": physics.get("rest_submergence_m"),
		"mean_float_point_y_m": mean_float_y,
		"keel_exclusion": {"method": "exclude side-projection portions in center strip |X| <= half_width below top_y", "half_width_m": KEEL_HALF_WIDTH_M, "top_y_m": KEEL_TOP_Y_M},
		"full_immersed_side_projection_area_m2_including_keel": full_stats.get("projected_area_m2"),
		"full_immersed_side_projection_centroid_body_local_m_including_keel": full_center,
		"hull_only_side_projection_area_m2": hull_stats.get("projected_area_m2"),
		"hull_only_side_projection_centroid_body_local_m": hull_center,
		"center_of_mass_body_local_m": com_local,
		"full_geometry_centroid_from_com_local_m": full_center - com_local,
		"hull_geometry_centroid_from_com_local_m": hull_center - com_local,
		"p213_first_pass_z_only_from_com_local_m": Vector3(0.0, 0.0, hull_center.z - com_local.z),
		"keel_exclusion_sensitivity": sensitivity,
		"limitations": "The GLB combines shell and fin keel in one mesh. Side-projection centroid is a geometric initialization, not a dynamic hydrodynamic pressure center. Roll-height is not used for the first z-only test.",
	}
	print("P2.14 immersed hull side projection · %s" % JSON.stringify(result, "\t"))
	_finish(0)


func _measure_projection(mesh: Mesh, body_from_mesh: Transform3D, waterline_y: float, exclude_keel: bool, keel_half_width: float, keel_top_y: float) -> Dictionary:
	var projected_area := 0.0
	var centroid_sum := Vector3.ZERO
	var triangle_count := 0
	var submerged_triangle_count := 0
	for surface_index in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(surface_index)
		if arrays.size() <= Mesh.ARRAY_VERTEX:
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays.size() > Mesh.ARRAY_INDEX else PackedInt32Array()
		var triangle_index_count := indices.size() if not indices.is_empty() else vertices.size()
		for index in range(0, triangle_index_count - 2, 3):
			var ia := indices[index] if not indices.is_empty() else index
			var ib := indices[index + 1] if not indices.is_empty() else index + 1
			var ic := indices[index + 2] if not indices.is_empty() else index + 2
			var a := body_from_mesh * vertices[ia]
			var b := body_from_mesh * vertices[ib]
			var c := body_from_mesh * vertices[ic]
			var face_cross := (b - a).cross(c - a)
			if absf(face_cross.x) <= 0.000001:
				continue
			triangle_count += 1
			var underwater := _clip_axis([a, b, c], Vector3.AXIS_Y, waterline_y, true)
			if underwater.size() < 3:
				continue
			submerged_triangle_count += 1
			var pieces: Array = [underwater]
			if exclude_keel:
				pieces = [
					_clip_axis(underwater, Vector3.AXIS_X, -keel_half_width, true),
					_clip_axis(underwater, Vector3.AXIS_X, keel_half_width, false),
					_clip_axis(_clip_axis(_clip_axis(underwater, Vector3.AXIS_X, -keel_half_width, false), Vector3.AXIS_X, keel_half_width, true), Vector3.AXIS_Y, keel_top_y, false),
				]
			for polygon_value in pieces:
				var polygon: Array[Vector3] = polygon_value
				var stats := _projected_polygon_stats(polygon)
				var area := float(stats.get("area_m2", 0.0))
				if area <= 0.0000001:
					continue
				projected_area += area
				centroid_sum += (stats["centroid_local_m"] as Vector3) * area
	return {
		"projected_area_m2": projected_area,
		"centroid_local_m": centroid_sum / projected_area if projected_area > 0.0 else Vector3.ZERO,
		"triangles_with_lateral_projection": triangle_count,
		"triangles_intersecting_waterline": submerged_triangle_count,
	}


func _clip_axis(input_polygon: Array[Vector3], axis: Vector3.Axis, boundary: float, keep_less: bool) -> Array[Vector3]:
	var output: Array[Vector3] = []
	if input_polygon.is_empty():
		return output
	var previous: Vector3 = input_polygon.back()
	var previous_value := previous[axis]
	var previous_inside := previous_value <= boundary if keep_less else previous_value >= boundary
	for current in input_polygon:
		var current_value := current[axis]
		var current_inside := current_value <= boundary if keep_less else current_value >= boundary
		if current_inside != previous_inside:
			var denominator := current_value - previous_value
			if absf(denominator) > 0.0000001:
				var fraction := (boundary - previous_value) / denominator
				output.append(previous.lerp(current, fraction))
		if current_inside:
			output.append(current)
		previous = current
		previous_value = current_value
		previous_inside = current_inside
	return output


func _projected_polygon_stats(polygon: Array[Vector3]) -> Dictionary:
	if polygon.size() < 3:
		return {"area_m2": 0.0, "centroid_local_m": Vector3.ZERO}
	var twice_area := 0.0
	var centroid_x_numerator := 0.0
	var centroid_y_numerator := 0.0
	var centroid_z_numerator := 0.0
	for index in range(polygon.size()):
		var a: Vector3 = polygon[index]
		var b: Vector3 = polygon[(index + 1) % polygon.size()]
		var cross_2d := a.y * b.z - b.y * a.z
		twice_area += cross_2d
		centroid_x_numerator += (a.x + b.x) * cross_2d
		centroid_y_numerator += (a.y + b.y) * cross_2d
		centroid_z_numerator += (a.z + b.z) * cross_2d
	if absf(twice_area) <= 0.0000001:
		return {"area_m2": 0.0, "centroid_local_m": Vector3.ZERO}
	var centroid := Vector3(centroid_x_numerator, centroid_y_numerator, centroid_z_numerator) / (3.0 * twice_area)
	return {"area_m2": absf(twice_area) * 0.5, "centroid_local_m": centroid}


func _finish(code: int, message: String = "") -> void:
	if not message.is_empty():
		push_error(message)
	if _lab != null and is_instance_valid(_lab):
		_lab.queue_free()
	await process_frame
	quit(code)
