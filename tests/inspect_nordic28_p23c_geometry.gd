extends SceneTree
## Lightweight P2.3c mesh-space check. No Polar or sustained rigid-body run.

const LAB_SCENE := preload("res://scenes/SailboatLabP23c.tscn")
const P23B_PHYSICS := preload("res://resources/sailing/nordic28_p23b_physics_profile.tres")
const P23B_VISUAL := preload("res://resources/sailing/nordic28_p23b_visual_rig_profile.tres")
const AERO_MATH := preload("res://scripts/sailboat_aero_math.gd")
const MAIN_ANGLES_DEG := [-80.0, -60.0, -30.0, 0.0, 30.0, 60.0, 80.0]
const JIB_ANGLES_DEG := [-70.0, -60.0, -30.0, 0.0, 30.0, 60.0, 70.0]
const PLANE_EPSILON_M := 0.0001


func _initialize() -> void:
	call_deferred("_inspect")


func _inspect() -> void:
	var lab := LAB_SCENE.instantiate() as Node3D
	root.add_child(lab)
	await process_frame
	await process_frame
	var boat := lab.get_node_or_null("SailboatBody") as RigidBody3D
	var visual_root := boat.get_node_or_null("VisualRoot") as Node3D if boat != null else null
	var anchors := visual_root.get_node_or_null("VisualRigAnchors") as Node3D if visual_root != null else null
	var boom_pivot := visual_root.get_node_or_null("VisualBoomPivot") as Node3D if visual_root != null else null
	var main_mesh := boom_pivot.get_node_or_null("MainSailMesh") as MeshInstance3D if boom_pivot != null else null
	var jib_mesh := visual_root.get_node_or_null("HeadsailVisual") as MeshInstance3D if visual_root != null else null
	if boat == null or anchors == null or main_mesh == null or jib_mesh == null or not jib_mesh.has_method("get_vertices_for_angle"):
		push_error("P2.3c scene is missing the boat, rig anchors, or generated sail meshes")
		quit(2)
		return
	var physics := boat.get("profile") as Resource
	var visual := anchors.get("visual_profile") as Resource
	if physics == null or visual == null or physics.resource_path != "res://resources/sailing/nordic28_p23c_physics_profile.tres" or visual.resource_path != "res://resources/sailing/nordic28_p23c_visual_rig_profile.tres":
		push_error("P2.3c boat did not bind its independent visual and physics Profiles")
		quit(2)
		return
	var snapshot: Dictionary = anchors.call("get_alignment_snapshot")
	var visual_head: Vector3 = visual.get("jib_head_local_m")
	var visual_tack: Vector3 = visual.get("jib_tack_local_m")
	var visual_clew: Vector3 = visual.get("jib_clew_local_m")
	var visual_offset: Vector3 = visual.get("visual_assembly_offset_local_m")
	var physical_head: Vector3 = physics.get("headsail_head_local_m")
	var physical_tack: Vector3 = physics.get("headsail_tack_local_m")
	var physical_clew: Vector3 = physics.get("headsail_clew_neutral_local_m")
	var physical_area := float(physics.get("headsail_area_m2"))
	var visual_area := AERO_MATH.triangular_sail_area_m2(visual_head, visual_tack, visual_clew)
	var visual_center := AERO_MATH.triangular_sail_centroid(visual_head, visual_tack, visual_clew) + visual_offset
	var physical_center: Vector3 = AERO_MATH.triangular_sail_centroid(physical_head, physical_tack, physical_clew) + (physics.get("headsail_pressure_center_offset_from_centroid_m") as Vector3)
	var mast_z := float((visual.get("mast_base_local_m") as Vector3).z)
	var jib_vertices_by_angle: Dictionary = {}
	var jib_clew_by_angle: Dictionary = {}
	var maximum_jib_z_by_angle: Dictionary = {}
	var minimum_jib_hull_clearance_m := INF
	for angle_deg in JIB_ANGLES_DEG:
		var angle_rad := deg_to_rad(angle_deg)
		var jib_vertices: PackedVector3Array = jib_mesh.call("get_vertices_for_angle", angle_rad)
		var maximum_z := -INF
		for vertex in jib_vertices:
			maximum_z = maxf(maximum_z, (jib_mesh.transform * vertex).z)
			if absf((jib_mesh.transform * vertex).z - mast_z) <= PLANE_EPSILON_M and (jib_mesh.transform * vertex).distance_to(visual_head) > PLANE_EPSILON_M:
				push_error("A jib mesh point other than its fixed Head crossed the mast plane")
				quit(1)
				return
		jib_vertices_by_angle[angle_deg] = jib_vertices
		maximum_jib_z_by_angle[angle_deg] = maximum_z
		jib_clew_by_angle[angle_deg] = AERO_MATH.headsail_clew_from_sheet(visual_tack, visual_clew, angle_rad)
		if maximum_z > mast_z + PLANE_EPSILON_M:
			push_error("Jib mesh extends aft of the mast plane at %s degrees" % angle_deg)
			quit(1)
			return
	var main_arrays := main_mesh.mesh.surface_get_arrays(0)
	if main_arrays.size() <= Mesh.ARRAY_VERTEX:
		push_error("Generated mainsail mesh has no readable vertex array")
		quit(2)
		return
	var main_vertices: PackedVector3Array = main_arrays[Mesh.ARRAY_VERTEX]
	var main_min_z_by_angle: Dictionary = {}
	for angle_deg in MAIN_ANGLES_DEG:
		var angle_rad := deg_to_rad(angle_deg)
		var sheet_basis := Basis(Vector3.UP, angle_rad)
		var min_z := INF
		for vertex in main_vertices:
			var body_local_vertex := boom_pivot.position + sheet_basis * (main_mesh.transform * vertex)
			min_z = minf(min_z, body_local_vertex.z)
		if min_z < mast_z - PLANE_EPSILON_M:
			push_error("Mainsail mesh extends forward of the mast plane at %s degrees" % angle_deg)
			quit(1)
			return
		main_min_z_by_angle[angle_deg] = min_z
	var transition_jib_steps := 0
	for angle_deg in range(-70, 71):
		transition_jib_steps += 1
		var jib_transition_vertices: PackedVector3Array = jib_mesh.call("get_vertices_for_angle", deg_to_rad(float(angle_deg)))
		for vertex in jib_transition_vertices:
			if (jib_mesh.transform * vertex).z > mast_z + PLANE_EPSILON_M:
				push_error("Jib mesh crossed aft of the mast during a tack transition")
				quit(1)
				return
	var transition_main_steps := 0
	for angle_deg in range(-80, 81):
		transition_main_steps += 1
		var sheet_basis := Basis(Vector3.UP, deg_to_rad(float(angle_deg)))
		for vertex in main_vertices:
			var body_local_vertex := boom_pivot.position + sheet_basis * (main_mesh.transform * vertex)
			if body_local_vertex.z < mast_z - PLANE_EPSILON_M:
				push_error("Mainsail mesh crossed forward of the mast during a trim transition")
				quit(1)
				return
	var checked_pairs := 0
	for main_angle in MAIN_ANGLES_DEG:
		for jib_angle in JIB_ANGLES_DEG:
			checked_pairs += 1
			# Each generated triangle stays in its sail's closed half-space. Their
			# only shared mast-plane point is the fixed Jib Head on the main luff.
			if float(main_min_z_by_angle[main_angle]) < mast_z - PLANE_EPSILON_M or float(maximum_jib_z_by_angle[jib_angle]) > mast_z + PLANE_EPSILON_M:
				push_error("Mainsail/Jib half-space separation failed at %s / %s degrees" % [main_angle, jib_angle])
				quit(1)
				return
	for angle_deg in [0.0, 30.0, 60.0, 70.0]:
		var port_clew: Vector3 = jib_clew_by_angle[-angle_deg]
		var starboard_clew: Vector3 = jib_clew_by_angle[angle_deg]
		if absf(port_clew.x + starboard_clew.x) > PLANE_EPSILON_M or absf(port_clew.y - starboard_clew.y) > PLANE_EPSILON_M or absf(port_clew.z - starboard_clew.z) > PLANE_EPSILON_M:
			push_error("Jib port/starboard Clew positions are not mirrored at %s degrees" % angle_deg)
			quit(1)
			return
		if angle_deg < 70.0:
			var port_vertices: PackedVector3Array = jib_vertices_by_angle[-angle_deg]
			var starboard_vertices: PackedVector3Array = jib_vertices_by_angle[angle_deg]
			for vertex_index in range(port_vertices.size()):
				var port_vertex: Vector3 = jib_mesh.transform * port_vertices[vertex_index]
				var starboard_vertex: Vector3 = jib_mesh.transform * starboard_vertices[vertex_index]
				if absf(port_vertex.x + starboard_vertex.x) > PLANE_EPSILON_M or absf(port_vertex.y - starboard_vertex.y) > PLANE_EPSILON_M or absf(port_vertex.z - starboard_vertex.z) > PLANE_EPSILON_M:
					push_error("Jib mesh vertices are not mirrored at %s degrees" % angle_deg)
					quit(1)
					return
	var clearances: Dictionary = snapshot.get("jib_lower_edge_clearance_m", {})
	for angle_deg in JIB_ANGLES_DEG:
		var clearance := float(clearances.get(angle_deg, -INF))
		if not is_finite(clearance) or clearance < 0.0:
			push_error("Jib lower edge intersects or cannot be checked against the sampled hull at %s degrees" % angle_deg)
			quit(1)
			return
		minimum_jib_hull_clearance_m = minf(minimum_jib_hull_clearance_m, clearance)
	if absf(visual_head.y - P23B_VISUAL.get("jib_head_local_m").y) > PLANE_EPSILON_M or visual_head.z != P23B_VISUAL.get("jib_head_local_m").z or visual_tack != P23B_VISUAL.get("jib_tack_local_m"):
		push_error("P2.3c changed the approved P2.3b Jib Head or Tack")
		quit(1)
		return
	if absf(visual_clew.y - float(P23B_VISUAL.get("jib_clew_local_m").y)) > PLANE_EPSILON_M or visual_clew.z >= mast_z - 0.25:
		push_error("P2.3c Clew height or forward clearance does not meet its design target")
		quit(1)
		return
	if absf(visual_area - physical_area) > 0.0001 or visual_center.distance_to(physical_center) > 0.0001:
		push_error("P2.3c visual and physical Jib area/pressure centre do not match")
		quit(1)
		return
	if absf(float(physics.get("main_sail_area_m2")) - float(P23B_PHYSICS.get("main_sail_area_m2"))) > PLANE_EPSILON_M:
		push_error("P2.3c unexpectedly changed the approved P2.3b mainsail area")
		quit(1)
		return
	var result := {
		"scene": lab.scene_file_path,
		"checked_mainsail_jib_angle_pairs": checked_pairs,
		"checked_jib_transition_steps": transition_jib_steps,
		"checked_main_trim_transition_steps": transition_main_steps,
		"jib_head_visual_local_m": visual_head,
		"jib_tack_visual_local_m": visual_tack,
		"jib_clew_visual_local_m": visual_clew,
		"jib_clew_physics_local_m": physical_clew,
		"jib_area_visual_m2": visual_area,
		"jib_area_physics_m2": physical_area,
		"jib_pressure_center_local_m": physical_center,
		"center_delta_m": visual_center.distance_to(physical_center),
		"main_sail_area_unchanged_m2": physics.get("main_sail_area_m2"),
		"minimum_sampled_jib_foot_hull_clearance_m": minimum_jib_hull_clearance_m,
		"jib_max_z_by_sheet_deg": maximum_jib_z_by_angle,
		"main_min_z_by_boom_deg": main_min_z_by_angle,
	}
	print("P2.3c geometry inspection · %s" % JSON.stringify(result, "\t"))
	lab.queue_free()
	await process_frame
	quit(0)
