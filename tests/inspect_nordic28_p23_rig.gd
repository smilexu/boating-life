extends SceneTree
## Read-only geometry inspection for the isolated Nordic 28 P2.3 SailboatLab.

const LAB_SCENE := preload("res://scenes/SailboatLabP23.tscn")


func _initialize() -> void:
	call_deferred("_inspect")


func _inspect() -> void:
	var lab := LAB_SCENE.instantiate() as Node3D
	root.add_child(lab)
	await process_frame
	await process_frame
	var anchors := lab.get_node_or_null("SailboatBody/VisualRoot/VisualRigAnchors") as Node3D
	if anchors == null or not anchors.has_method("get_alignment_snapshot"):
		push_error("P2.3 scene is missing its visual rig geometry inspector")
		quit(2)
		return
	var snapshot: Dictionary = anchors.call("get_alignment_snapshot")
	if not bool(snapshot.get("configured", false)):
		push_error("P2.3 visual rig did not configure against the imported hull")
		quit(2)
		return
	var main_clearances: Dictionary = snapshot.get("main_lower_edge_clearance_m", {})
	var jib_clearances: Dictionary = snapshot.get("jib_lower_edge_clearance_m", {})
	var selected := {
		"configured": snapshot.get("configured"),
		"cabin_roof_y_m": snapshot.get("cabin_roof_y_m"),
		"mast_step_embed_measured_m": snapshot.get("mast_step_embed_measured_m"),
		"boom_roof_clearance_m": snapshot.get("boom_roof_clearance_m"),
		"boom_length_m": snapshot.get("boom_length_m"),
		"main_visual_area_m2": snapshot.get("main_visual_area_m2"),
		"jib_visual_area_m2": snapshot.get("jib_visual_area_m2"),
		"main_boom_clearance_at_trim_angles_m": {},
		"jib_clew_clearance_at_trim_angles_m": {},
	}
	for angle in [0.0, 30.0, -30.0, 60.0, -60.0, 80.0, -80.0]:
		var value := float(main_clearances.get(angle, NAN))
		selected["main_boom_clearance_at_trim_angles_m"][str(angle)] = value if is_finite(value) else null
	for angle in [0.0, 45.0, -45.0, 70.0, -70.0]:
		var value := float(jib_clearances.get(angle, NAN))
		selected["jib_clew_clearance_at_trim_angles_m"][str(angle)] = value if is_finite(value) else null
	print("P2.3 visual alignment · %s" % JSON.stringify(selected, "\t"))
	lab.queue_free()
	await process_frame
	quit(0)
