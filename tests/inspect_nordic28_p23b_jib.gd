extends SceneTree
## Lightweight P2.3b Jib profile, area, centroid, and hull-clearance check.

const LAB_SCENE := preload("res://scenes/SailboatLabP23b.tscn")
const P23_PHYSICS := preload("res://resources/sailing/nordic28_p23_physics_profile.tres")
const P23_VISUAL := preload("res://resources/sailing/nordic28_p23_visual_rig_profile.tres")
const AERO_MATH := preload("res://scripts/sailboat_aero_math.gd")


func _initialize() -> void:
	call_deferred("_inspect")


func _inspect() -> void:
	var lab := LAB_SCENE.instantiate() as Node3D
	root.add_child(lab)
	await process_frame
	await process_frame
	var boat := lab.get_node_or_null("SailboatBody") as RigidBody3D
	var anchors := lab.get_node_or_null("SailboatBody/VisualRoot/VisualRigAnchors") as Node3D
	if boat == null or anchors == null or not anchors.has_method("get_alignment_snapshot"):
		push_error("P2.3b lab scene is missing the boat or Nordic 28 rig anchor component")
		quit(2)
		return
	var physics: Resource = boat.get("profile") as Resource
	var visual: Resource = anchors.get("visual_profile") as Resource
	if physics == null or visual == null:
		push_error("P2.3b scene did not bind its independent Profiles")
		quit(2)
		return
	var snapshot: Dictionary = anchors.call("get_alignment_snapshot")
	var visual_head: Vector3 = visual.get("jib_head_local_m")
	var visual_tack: Vector3 = visual.get("jib_tack_local_m")
	var visual_clew: Vector3 = visual.get("jib_clew_local_m")
	var visual_offset: Vector3 = visual.get("visual_assembly_offset_local_m")
	var visual_area := AERO_MATH.triangular_sail_area_m2(visual_head, visual_tack, visual_clew)
	var visual_center := AERO_MATH.triangular_sail_centroid(visual_head, visual_tack, visual_clew) + visual_offset
	var physics_head: Vector3 = physics.get("headsail_head_local_m")
	var physics_tack: Vector3 = physics.get("headsail_tack_local_m")
	var physics_clew: Vector3 = physics.get("headsail_clew_neutral_local_m")
	var physics_area := float(physics.get("headsail_area_m2"))
	var pressure_center_offset: Vector3 = physics.get("headsail_pressure_center_offset_from_centroid_m")
	var physics_center := AERO_MATH.triangular_sail_centroid(physics_head, physics_tack, physics_clew) + pressure_center_offset
	var old_head: Vector3 = P23_PHYSICS.get("headsail_head_local_m")
	var old_tack: Vector3 = P23_PHYSICS.get("headsail_tack_local_m")
	var old_clew: Vector3 = P23_PHYSICS.get("headsail_clew_neutral_local_m")
	var old_visual_head: Vector3 = P23_VISUAL.get("jib_head_local_m")
	var old_visual_tack: Vector3 = P23_VISUAL.get("jib_tack_local_m")
	var old_visual_clew: Vector3 = P23_VISUAL.get("jib_clew_local_m")
	var result := {
		"scene": lab.scene_file_path,
		"head_local_m": visual_head,
		"tack_local_m": visual_tack,
		"clew_local_m": visual_clew,
		"physics_clew_local_m": physics_clew,
		"visual_area_m2": visual_area,
		"physics_area_m2": physics_area,
		"visual_centroid_body_local_m": visual_center,
		"physics_pressure_center_body_local_m": physics_center,
		"center_delta_m": visual_center.distance_to(physics_center),
		"jib_clearance_by_angle_m": snapshot.get("jib_lower_edge_clearance_m", {}),
		"main_area_unchanged_m2": physics.get("main_sail_area_m2"),
	}
	print("P2.3b Jib inspection · %s" % JSON.stringify(result, "\t"))
	if absf(visual_area - physics_area) > 0.0001 or visual_center.distance_to(physics_center) > 0.0001:
		push_error("P2.3b visual Jib area or centre does not match its physical Profile")
		quit(1)
		return
	if visual_head != old_visual_head or visual_tack != old_visual_tack or physics_head != old_head or physics_tack != old_tack:
		push_error("P2.3b unexpectedly changed the Jib Head or Tack")
		quit(1)
		return
	if absf(visual_clew.y - old_visual_clew.y - 0.4) > 0.00001:
		push_error("P2.3b Clew was not raised by exactly 0.40 m")
		quit(1)
		return
	if absf(physics_clew.y - old_clew.y - 0.4) > 0.00001:
		push_error("P2.3b physical Clew was not raised by exactly 0.40 m")
		quit(1)
		return
	if float(physics.get("main_sail_area_m2")) != float(P23_PHYSICS.get("main_sail_area_m2")):
		push_error("P2.3b unexpectedly changed the mainsail area")
		quit(1)
		return
	lab.queue_free()
	await process_frame
	quit(0)
