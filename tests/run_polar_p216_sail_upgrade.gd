extends SceneTree
## P2.16 Nordic 28 geometry-consistent sail upgrade. Runs a 12 kn / 90 deg
## smoke first, then the remaining mirrored speed cases using PolarTestRunner.

const LAB_SCENE := preload("res://scenes/SailboatLabP216.tscn")
const BOAT_SCENE := "res://scenes/boats/SailingBoat8mP216.tscn"
const PHYSICS_PROFILE_PATH := "res://resources/sailing/nordic28_p216_physics_profile.tres"
const VISUAL_PROFILE_PATH := "res://resources/sailing/nordic28_p216_visual_rig_profile.tres"
const BASE_PHYSICS_PROFILE := preload("res://resources/sailing/nordic28_p23c_physics_profile.tres")
const BASE_VISUAL_PROFILE := preload("res://resources/sailing/nordic28_p23c_visual_rig_profile.tres")
const POLAR_PROFILE := preload("res://resources/sailing/polar_test_profile.tres")
const AERO_MATH := preload("res://scripts/sailboat_aero_math.gd")
const OUTPUT_ROOT := "res://docs/sailing/polar_p216"
const P215_COMPARISON_CSV := "res://docs/sailing/polar_p215/speed_baseline_comparison.csv"
const ENGINE_PHYSICS_HZ := 480
const ACCELERATION_SCALE := 8.0
const CASE_TIMEOUT_S := 180.0
const BASELINE_FIELDS := [
	"mass_kg", "center_of_mass_m", "rest_submergence_m", "float_point_offsets_m",
	"buoyancy_damping_ratio", "maximum_point_force_ratio", "linear_damp_mode",
	"linear_damping", "angular_damping", "roll_damping_n_m_s_per_rad",
	"pitch_damping_n_m_s_per_rad", "yaw_damping_n_m_s_per_rad", "min_sail_angle_rad",
	"max_sail_angle_rad", "sail_rotation_speed_rad_s", "auto_main_trim_curve_points_degrees",
	"auto_headsail_trim_curve_points_degrees", "air_density_kg_m3",
	"sail_max_lift_coefficient", "sail_stall_angle_rad", "no_sail_wind_from_angle_rad",
	"full_lift_wind_from_angle_rad", "sail_base_drag_coefficient", "sail_induced_drag_factor",
	"sail_flat_plate_drag_factor", "sail_wrong_side_lift_retention", "headsail_enabled",
	"headsail_pressure_center_offset_from_centroid_m", "headsail_pressure_center_clew_follow",
	"min_headsail_angle_rad", "max_headsail_angle_rad", "headsail_rotation_speed_rad_s",
	"headsail_max_lift_coefficient", "headsail_stall_angle_rad",
	"headsail_no_sail_wind_from_angle_rad", "headsail_full_lift_wind_from_angle_rad",
	"headsail_base_drag_coefficient", "headsail_induced_drag_factor",
	"headsail_flat_plate_drag_factor", "headsail_wrong_side_lift_retention", "water_density_kg_m3",
	"keel_center_local_m", "keel_area_m2", "keel_lift_slope_per_rad",
	"keel_max_lift_coefficient", "keel_stall_angle_rad", "keel_base_drag_coefficient",
	"keel_induced_drag_factor", "keel_flat_plate_drag_factor", "keel_max_force_weight_ratio",
	"rudder_center_local_m", "rudder_area_m2", "max_rudder_angle_rad",
	"rudder_rotation_speed_rad_s", "rudder_lift_slope_per_rad",
	"rudder_max_lift_coefficient", "rudder_stall_angle_rad", "rudder_base_drag_coefficient",
	"rudder_induced_drag_factor", "rudder_flat_plate_drag_factor", "rudder_max_force_weight_ratio",
	"hull_longitudinal_drag_linear_n_s_m", "hull_longitudinal_drag_quadratic_n_s2_m2",
	"hull_lateral_drag_linear_n_s_m", "hull_lateral_drag_quadratic_n_s2_m2",
	"hull_drag_max_force_weight_ratio", "hull_lateral_center_from_com_local_m",
]
const BASE_VISUAL_FIELDS := [
	"mast_base_local_m", "visual_assembly_offset_local_m", "boom_pivot_local_m",
	"boom_length_m", "boom_clearance_over_roof_m", "helm_station_local_m",
	"helm_pedestal_height_m", "helm_pedestal_base_size_m", "helm_pedestal_top_size_m",
	"helm_wheel_outer_radius_m", "helm_wheel_degrees_per_rudder_degree",
	"helm_wheel_rotation_sign", "mast_step_embed_m", "minimum_boom_lower_edge_clearance_m",
	"roof_sample_half_width_m", "roof_sample_half_length_m", "rudder_axis_hull_embed_m",
	"rudder_visual_span_m", "rudder_visual_max_chord_m", "rudder_stock_radius_m",
	"rudder_foil_top_clearance_m",
]

var _lab: Node3D
var _boat: RigidBody3D
var _runner: PolarTestRunner
var _old_physics_hz := 60
var _old_time_scale := 1.0
var _error := ""
var _smoke_checkpoint: Dictionary = {}
var _full_checkpoint: Dictionary = {}
var _smoke_geometry: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_old_physics_hz = Engine.physics_ticks_per_second
	_old_time_scale = Engine.time_scale
	Engine.physics_ticks_per_second = ENGINE_PHYSICS_HZ
	Engine.time_scale = ACCELERATION_SCALE
	_lab = LAB_SCENE.instantiate() as Node3D
	_boat = _lab.get_node_or_null("SailboatBody") as RigidBody3D
	_runner = _lab.get_node_or_null("PolarTestRunner") as PolarTestRunner
	if _boat == null or _runner == null:
		_finish(2, "P2.16 SailboatLab is missing the boat or PolarTestRunner")
		return
	var test_profile := (POLAR_PROFILE as Resource).duplicate(true)
	test_profile.set("boat_scene_paths", PackedStringArray([BOAT_SCENE]))
	test_profile.set("case_timeout_seconds", CASE_TIMEOUT_S)
	_runner.profile = test_profile
	_boat.set("p22_extended_telemetry_enabled", true)
	root.add_child(_lab)
	await process_frame
	await process_frame
	_smoke_geometry = _validate_rig()
	if not bool(_smoke_geometry.get("valid", false)):
		print("P2.16 rig validation result · %s" % JSON.stringify(_smoke_geometry, "\t"))
		_finish(2, str(_smoke_geometry.get("reason", "P2.16 geometry validation failed")))
		return
	if OS.get_cmdline_user_args().has("--validate-only"):
		print("P2.16 rig validation · %s" % JSON.stringify(_smoke_geometry, "\t"))
		_finish(0)
		return
	var cmdline_args := OS.get_cmdline_user_args()
	if cmdline_args.has("--remaining-only"):
		if not _load_smoke_checkpoint():
			_finish(1, _error)
			return
		print("P2.16 reusing accepted smoke · run=%s · fingerprint=%s · %s" % [
			_smoke_checkpoint.get("test_run_id", ""), _smoke_checkpoint.get("config_hash", ""), JSON.stringify(_result_brief(_smoke_checkpoint)),
		])
	else:
		var smoke_cases: Array[Dictionary] = [_make_case(12.0, 90.0, "PORT")]
		var smoke_state := await _run_batch("smoke", smoke_cases)
		_smoke_checkpoint = smoke_state.get("checkpoint", {})
		if not bool(smoke_state.get("ok", false)):
			_finish(1, str(smoke_state.get("reason", "P2.16 smoke did not complete")))
			return
		if not _smoke_is_acceptable(_smoke_checkpoint):
			_finish(1, "P2.16 12 kn / 90° smoke was not STABLE with finite sail forces; remaining cases were not started")
			return
		if not _copy_run_artifacts(_smoke_checkpoint, "smoke", _smoke_geometry):
			_finish(1, _error)
			return
		print("P2.16 smoke passed · run=%s · fingerprint=%s · %s" % [
			_smoke_checkpoint.get("test_run_id", ""),
			_smoke_checkpoint.get("config_hash", ""),
			JSON.stringify(_result_brief(_smoke_checkpoint)),
		])
	if cmdline_args.has("--smoke-only"):
		_write_stage_manifest()
		_finish(0)
		return
	var remaining_cases := _build_remaining_cases()
	var full_state := await _run_batch("remaining", remaining_cases)
	_full_checkpoint = full_state.get("checkpoint", {})
	if not bool(full_state.get("ok", false)):
		_finish(1, str(full_state.get("reason", "P2.16 remaining cases did not complete")))
		return
	if not _copy_run_artifacts(_full_checkpoint, "remaining", _smoke_geometry):
		_finish(1, _error)
		return
	if not _write_combined_results():
		_finish(1, _error)
		return
	_write_stage_manifest()
	var combined := _all_results()
	var counts := _status_counts(combined)
	print("P2.16 complete · smoke=%s · remaining=%s · cases=%d/%d · statuses=%s · fingerprints=%s / %s" % [
		_smoke_checkpoint.get("test_run_id", ""), _full_checkpoint.get("test_run_id", ""),
		combined.size(), 12, JSON.stringify(counts), _smoke_checkpoint.get("config_hash", ""),
		_full_checkpoint.get("config_hash", ""),
	])
	_finish(0 if combined.size() == 12 else 1)


func _validate_rig() -> Dictionary:
	if _boat.scene_file_path != BOAT_SCENE:
		return {"valid": false, "reason": "P2.16 lab instantiated %s instead of %s" % [_boat.scene_file_path, BOAT_SCENE]}
	var physics: Resource = _boat.get("profile") as Resource
	var anchors := _boat.get_node_or_null("VisualRoot/VisualRigAnchors") as Node3D
	var visual: Resource = anchors.get("visual_profile") as Resource if anchors != null else null
	if physics == null or visual == null or physics.resource_path != PHYSICS_PROFILE_PATH or visual.resource_path != VISUAL_PROFILE_PATH:
		return {"valid": false, "reason": "P2.16 boat is not bound to its independent Profiles"}
	var snapshot: Dictionary = anchors.call("get_alignment_snapshot")
	var geometry_motion_check := _check_sail_half_spaces(anchors, visual)
	var main_head: Vector3 = visual.get("main_head_local_m")
	var boom_pivot: Vector3 = visual.get("boom_pivot_local_m")
	var main_clew := boom_pivot + Vector3(0.0, 0.0, float(visual.get("boom_length_m")))
	var jib_head: Vector3 = visual.get("jib_head_local_m")
	var jib_tack: Vector3 = visual.get("jib_tack_local_m")
	var jib_clew: Vector3 = visual.get("jib_clew_local_m")
	var visual_offset: Vector3 = visual.get("visual_assembly_offset_local_m")
	var main_visual_area := AERO_MATH.triangular_sail_area_m2(main_head, boom_pivot, main_clew)
	var jib_visual_area := AERO_MATH.triangular_sail_area_m2(jib_head, jib_tack, jib_clew)
	var main_visual_center := (main_head + boom_pivot + main_clew) / 3.0 + visual_offset
	var jib_visual_center := (jib_head + jib_tack + jib_clew) / 3.0 + visual_offset
	var main_physics_center: Vector3 = physics.get("main_sail_pivot_local_m") + physics.get("main_sail_pressure_center_from_pivot_m")
	var jib_physics_center: Vector3 = (physics.get("headsail_head_local_m") + physics.get("headsail_tack_local_m") + physics.get("headsail_clew_neutral_local_m")) / 3.0 + physics.get("headsail_pressure_center_offset_from_centroid_m")
	var jib_head_clearance_to_main_head_m := main_head.y - jib_head.y
	var mast_top: Vector3 = visual.get("mast_base_local_m") + Vector3.UP * float(visual.get("mast_length_m"))
	var jib_clearances: Dictionary = snapshot.get("jib_lower_edge_clearance_m", {})
	var main_clearances: Dictionary = snapshot.get("main_lower_edge_clearance_m", {})
	var jib_max_hull_clearance := INF
	var main_min_boom_hull_clearance := INF
	var jib_hull_clearance_valid := true
	for angle in [-70.0, -60.0, -30.0, 0.0, 30.0, 60.0, 70.0]:
		var value := float(jib_clearances.get(angle, NAN))
		if not is_finite(value) or value < 0.0:
			jib_hull_clearance_valid = false
		jib_max_hull_clearance = minf(jib_max_hull_clearance, value)
	for angle in [-80.0, -60.0, -30.0, 0.0, 30.0, 60.0, 80.0]:
		var value := float(main_clearances.get(angle, NAN))
		if not is_finite(value):
			return {"valid": false, "reason": "Boom hull clearance could not be sampled at %s°" % angle}
		main_min_boom_hull_clearance = minf(main_min_boom_hull_clearance, value)
	var protected_profile_check := _check_protected_profiles(physics, visual)
	var result := {
		"valid": true,
		"boat_scene_path": _boat.scene_file_path,
		"physics_profile_path": physics.resource_path,
		"visual_profile_path": visual.resource_path,
		"main_sail_area_visual_m2": main_visual_area,
		"main_sail_area_physics_m2": physics.get("main_sail_area_m2"),
		"jib_area_visual_m2": jib_visual_area,
		"jib_area_physics_m2": physics.get("headsail_area_m2"),
		"total_area_visual_m2": main_visual_area + jib_visual_area,
		"total_area_physics_m2": float(physics.get("main_sail_area_m2")) + float(physics.get("headsail_area_m2")),
		"main_pressure_center_local_m": main_physics_center,
		"main_centroid_delta_m": main_visual_center.distance_to(main_physics_center),
		"jib_pressure_center_local_m": jib_physics_center,
		"jib_centroid_delta_m": jib_visual_center.distance_to(jib_physics_center),
		"mast_length_m": visual.get("mast_length_m"),
		"mast_base_local_m": visual.get("mast_base_local_m"),
		"mast_top_local_m": mast_top,
		"main_head_local_m": main_head,
		"jib_head_local_m": jib_head,
		"jib_head_below_main_head_m": jib_head_clearance_to_main_head_m,
		"boom_length_m": visual.get("boom_length_m"),
		"boom_pivot_local_m": boom_pivot,
		"boom_roof_clearance_m": snapshot.get("boom_roof_clearance_m"),
		"minimum_sampled_boom_hull_clearance_m": main_min_boom_hull_clearance,
		"minimum_sampled_jib_foot_hull_clearance_m": jib_max_hull_clearance,
		"jib_foot_clearance_by_angle_m": jib_clearances,
		"jib_tack_local_m": jib_tack,
		"jib_tack_matches_p23c_accepted_position": jib_tack == BASE_VISUAL_PROFILE.get("jib_tack_local_m"),
		"dynamic_sail_separation_check": geometry_motion_check,
		"visual_assembly_offset_local_m": visual_offset,
		"protected_profile_check": protected_profile_check,
	}
	if not bool(protected_profile_check.get("valid", false)):
		result["valid"] = false
		result["reason"] = protected_profile_check.get("reason", "P2.16 changed a protected field")
		return result
	if not bool(geometry_motion_check.get("valid", false)):
		result["valid"] = false
		result["reason"] = geometry_motion_check.get("reason", "Dynamic sail separation check failed")
		return result
	if not jib_hull_clearance_valid:
		result["valid"] = false
		result["reason"] = "Jib lower edge intersects sampled hull at one or more tested sheet angles"
		return result
	if absf(main_visual_area - float(physics.get("main_sail_area_m2"))) > 0.001 or absf(jib_visual_area - float(physics.get("headsail_area_m2"))) > 0.001:
		result["valid"] = false
		result["reason"] = "P2.16 visual triangle area does not match effective physical sail area"
		return result
	if absf(float(result["total_area_physics_m2"]) - 28.0) > 0.1 or absf(float(result["total_area_visual_m2"]) - 28.0) > 0.1:
		result["valid"] = false
		result["reason"] = "P2.16 total sail area is outside the 28.0 ± 0.1 m2 design target"
		return result
	if float(result["main_centroid_delta_m"]) > 0.002 or float(result["jib_centroid_delta_m"]) > 0.002:
		result["valid"] = false
		result["reason"] = "Physical pressure center differs from new geometric centroid"
		return result
	if absf(mast_top.y - main_head.y - 0.18) > 0.002 or absf(float(visual.get("boom_length_m")) - 4.4) > 0.001 or absf(float(visual.get("boom_pivot_local_m").y) - 2.4111) > 0.001:
		result["valid"] = false
		result["reason"] = "P2.16 changed the approved mast-top margin or cockpit Boom dimensions"
		return result
	if jib_tack != BASE_VISUAL_PROFILE.get("jib_tack_local_m"):
		result["valid"] = false
		result["reason"] = "P2.16 Jib Tack differs from the previously inspected P2.3c mounting point"
		return result
	if main_min_boom_hull_clearance < 0.20:
		result["valid"] = false
		result["reason"] = "Boom has less than 0.20 m sampled clearance to hull structure"
		return result
	return result


func _check_sail_half_spaces(anchors: Node3D, visual: Resource) -> Dictionary:
	var boom_pivot := _boat.get_node_or_null("VisualRoot/VisualBoomPivot") as Node3D
	var main_mesh := boom_pivot.get_node_or_null("MainSailMesh") as MeshInstance3D if boom_pivot != null else null
	var jib_mesh := _boat.get_node_or_null("VisualRoot/HeadsailVisual") as MeshInstance3D
	var mast_z := float((visual.get("mast_base_local_m") as Vector3).z)
	if main_mesh == null or jib_mesh == null or not jib_mesh.has_method("get_vertices_for_angle"):
		return {"valid": false, "reason": "Generated sail meshes are unavailable for motion geometry check"}
	var arrays := main_mesh.mesh.surface_get_arrays(0) if main_mesh.mesh != null else []
	if arrays.size() <= Mesh.ARRAY_VERTEX:
		return {"valid": false, "reason": "Main sail vertex array unavailable"}
	var main_vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var checked_main_steps := 0
	var checked_jib_steps := 0
	for angle in range(-80, 81):
		checked_main_steps += 1
		var basis := Basis(Vector3.UP, deg_to_rad(float(angle)))
		for vertex in main_vertices:
			var local_point := boom_pivot.position + basis * (main_mesh.transform * vertex)
			if local_point.z < mast_z - 0.0001:
				return {"valid": false, "reason": "Main sail crossed forward of mast plane at %d°" % angle}
	for angle in range(-70, 71):
		checked_jib_steps += 1
		var jib_vertices: PackedVector3Array = jib_mesh.call("get_vertices_for_angle", deg_to_rad(float(angle)))
		for vertex in jib_vertices:
			var local_point := jib_mesh.transform * vertex
			if local_point.z > mast_z + 0.0001:
				return {"valid": false, "reason": "Jib crossed aft of mast plane at %d°" % angle}
	for angle in [30.0, 45.0, 60.0, 70.0]:
		var port_vertices: PackedVector3Array = jib_mesh.call("get_vertices_for_angle", deg_to_rad(-angle))
		var starboard_vertices: PackedVector3Array = jib_mesh.call("get_vertices_for_angle", deg_to_rad(angle))
		if port_vertices.size() != starboard_vertices.size():
			return {"valid": false, "reason": "Jib mirror vertex counts differ at %.0f°" % angle}
		for index in range(port_vertices.size()):
			var port_point: Vector3 = jib_mesh.transform * port_vertices[index]
			var starboard_point: Vector3 = jib_mesh.transform * starboard_vertices[index]
			if absf(port_point.x + starboard_point.x) > 0.0001 or absf(port_point.y - starboard_point.y) > 0.0001 or absf(port_point.z - starboard_point.z) > 0.0001:
				return {"valid": false, "reason": "Jib port/starboard geometry is not mirrored at %.0f°" % angle}
	return {
		"valid": true,
		"main_trim_steps_checked": checked_main_steps,
		"jib_trim_steps_checked": checked_jib_steps,
		"tested_jib_mirror_angles_degrees": [30, 45, 60, 70],
		"main_and_jib_separated_by_mast_plane": true,
	}


func _check_protected_profiles(physics: Resource, visual: Resource) -> Dictionary:
	var base_physics: Resource = BASE_PHYSICS_PROFILE
	var base_visual: Resource = BASE_VISUAL_PROFILE
	for property_name in BASELINE_FIELDS:
		if physics.get(property_name) != base_physics.get(property_name):
			return {"valid": false, "reason": "Protected physical configuration changed: %s" % property_name}
	var expected_visual := {
		"mast_length_m": 9.3,
		"main_head_local_m": Vector3(0.0, 10.4384, -1.0),
		"jib_head_local_m": Vector3(0.0, 10.33, -1.0),
		"jib_tack_local_m": Vector3(0.0, 1.9614, -3.5498),
		"jib_clew_local_m": Vector3(0.0, 2.0686, -1.05),
	}
	for property_name in BASE_VISUAL_FIELDS:
		if visual.get(property_name) != base_visual.get(property_name):
			return {"valid": false, "reason": "Protected visual configuration changed: %s" % property_name}
	for property_name in expected_visual:
		if visual.get(property_name) != expected_visual[property_name]:
			return {"valid": false, "reason": "Unexpected P2.16 visual anchor: %s" % property_name}
	var expected_physics := {
		"main_sail_area_m2": 17.66006,
		"main_sail_pressure_center_from_pivot_m": Vector3(0.0, 2.6757667, 1.4666667),
		"headsail_area_m2": 10.323244,
		"headsail_head_local_m": Vector3(0.0, 10.03, -1.0),
		"headsail_tack_local_m": Vector3(0.0, 1.6614, -3.5498),
		"headsail_clew_neutral_local_m": Vector3(0.0, 1.7686, -1.05),
	}
	for property_name in expected_physics:
		var actual: Variant = physics.get(property_name)
		var expected: Variant = expected_physics[property_name]
		if actual is float and expected is float:
			if absf(float(actual) - float(expected)) > 0.0001:
				return {"valid": false, "reason": "Unexpected P2.16 physics geometry: %s" % property_name}
		elif actual != expected:
			return {"valid": false, "reason": "Unexpected P2.16 physics geometry: %s" % property_name}
	return {"valid": true, "only_physical_changes": expected_physics.keys(), "only_visual_anchor_changes": expected_visual.keys()}


func _smoke_is_acceptable(checkpoint: Dictionary) -> bool:
	var rows: Array = checkpoint.get("results", [])
	if rows.size() != 1:
		return false
	var row: Dictionary = rows[0]
	if str(row.get("status", "")) != "STABLE":
		return false
	for key in ["mean_sog_kn", "measured_twa_deg", "mean_main_forward_force_n", "mean_headsail_forward_force_n"]:
		if not row.has(key) or not is_finite(float(row.get(key, NAN))):
			return false
	if float(row.get("mean_sog_kn", 0.0)) <= 0.0 or absf(absf(float(row.get("measured_twa_deg", 999.0))) - 90.0) > 5.0:
		return false
	return true


func _result_brief(checkpoint: Dictionary) -> Dictionary:
	var results: Array = checkpoint.get("results", [])
	return results[0] if not results.is_empty() else {}


func _load_smoke_checkpoint() -> bool:
	var manifest_path := OUTPUT_ROOT.path_join("p216_stage_manifest.json")
	if not FileAccess.file_exists(manifest_path):
		_error = "No saved P2.16 smoke manifest; run --smoke-only first"
		return false
	var manifest_variant: Variant = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	if not manifest_variant is Dictionary:
		_error = "Saved P2.16 smoke manifest is invalid"
		return false
	var run_id := str(manifest_variant.get("smoke_test_run_id", ""))
	var expected_fingerprint := str(manifest_variant.get("smoke_fingerprint", ""))
	if run_id.is_empty() or expected_fingerprint.is_empty():
		_error = "Saved P2.16 smoke manifest lacks run ID or fingerprint"
		return false
	var checkpoint_path := OUTPUT_ROOT.path_join("smoke").path_join(run_id).path_join("polar_checkpoint.json")
	if not FileAccess.file_exists(checkpoint_path):
		_error = "Saved P2.16 smoke checkpoint is missing: %s" % checkpoint_path
		return false
	var checkpoint_variant: Variant = JSON.parse_string(FileAccess.get_file_as_string(checkpoint_path))
	if not checkpoint_variant is Dictionary:
		_error = "Saved P2.16 smoke checkpoint is invalid"
		return false
	_smoke_checkpoint = checkpoint_variant
	if str(_smoke_checkpoint.get("test_run_id", "")) != run_id or str(_smoke_checkpoint.get("config_hash", "")) != expected_fingerprint:
		_error = "Saved P2.16 smoke run ID or fingerprint does not match its manifest"
		return false
	if not _smoke_is_acceptable(_smoke_checkpoint):
		_error = "Saved P2.16 smoke result no longer meets the stable acceptance criteria"
		return false
	return true


func _build_remaining_cases() -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	for tws in [8.0, 12.0, 16.0]:
		for angle in [90.0, 120.0]:
			for tack in ["PORT", "STARBOARD"]:
				if tws == 12.0 and angle == 90.0 and tack == "PORT":
					continue
				output.append(_make_case(float(tws), float(angle), str(tack)))
	return output


func _make_case(tws_kn: float, angle_deg: float, tack: String) -> Dictionary:
	var signed_angle := -angle_deg if tack == "PORT" else angle_deg
	var tack_id := tack.to_lower()
	return {
		"case_id": "p216_%02dkn_%03dtwa_%s" % [int(tws_kn), int(angle_deg), tack_id],
		"target_tws_kn": tws_kn,
		"target_twa_deg": signed_angle,
		"tack": tack,
		"experiment_group": "P216_NORDIC28_28M2_GEOMETRIC_RIG",
		"experiment_variable": "sail_rig_geometry_and_centroid",
		"experiment_label": "P2.16 · %.0f kn / %.0f° / %s" % [tws_kn, angle_deg, tack],
		"auto_sail_trim_enabled": true,
	}


func _run_batch(label: String, cases: Array[Dictionary]) -> Dictionary:
	if not _runner.start_new_batch({"include_extended_telemetry": true, "explicit_cases": cases}):
		return {"ok": false, "reason": "P2.16 %s batch failed to start: %s" % [label, str(_runner.get_status_snapshot().get("status", "unknown"))]}
	var initial_state := _runner.get_status_snapshot()
	print("P2.16 %s started · run=%s · boat=%s · dt=%.9f s · engine=%d Hz × %.1f · cases=%d" % [
		label, str(initial_state.get("test_run_id", "pending")), BOAT_SCENE,
		1.0 / 60.0, ENGINE_PHYSICS_HZ, ACCELERATION_SCALE, cases.size(),
	])
	await _wait_for_batch(label)
	var state := _runner.get_status_snapshot()
	var checkpoint_path := str(state.get("output_path", ""))
	if checkpoint_path.is_empty() or not FileAccess.file_exists(checkpoint_path):
		return {"ok": false, "reason": "P2.16 %s completed without a readable checkpoint" % label}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(checkpoint_path))
	if not parsed is Dictionary:
		return {"ok": false, "reason": "P2.16 %s checkpoint could not be parsed" % label}
	var checkpoint: Dictionary = parsed
	if int(state.get("completed_count", 0)) != cases.size() or checkpoint.get("results", []).size() != cases.size():
		return {"ok": false, "reason": "P2.16 %s incomplete: %d/%d" % [label, int(state.get("completed_count", 0)), cases.size()]}
	return {"ok": true, "checkpoint": checkpoint}


func _wait_for_batch(label: String) -> void:
	var last_case := ""
	var last_log_usec := 0
	while bool(_runner.get_status_snapshot().get("running", false)):
		await process_frame
		var snapshot := _runner.get_status_snapshot()
		var case_id := str(snapshot.get("current_case_id", ""))
		var now := Time.get_ticks_usec()
		if case_id != last_case or now - last_log_usec >= 15000000:
			last_case = case_id
			last_log_usec = now
			print("P2.16 %s progress · %d/%d · %s · sim %.0f s · %.2f kn · TWA %+.1f°" % [
				label, int(snapshot.get("completed_count", 0)), int(snapshot.get("case_count", 0)), case_id,
				float(snapshot.get("simulation_seconds", 0.0)), float(snapshot.get("sog_kn", 0.0)), float(snapshot.get("measured_twa_deg", 0.0)),
			])


func _copy_run_artifacts(checkpoint: Dictionary, stage: String, geometry: Dictionary) -> bool:
	var run_id := str(checkpoint.get("test_run_id", ""))
	var destination := OUTPUT_ROOT.path_join(stage).path_join(run_id)
	var absolute_directory := ProjectSettings.globalize_path(destination)
	if DirAccess.dir_exists_absolute(absolute_directory):
		_error = "Refusing to overwrite existing P2.16 run artifacts: %s" % destination
		return false
	if DirAccess.make_dir_recursive_absolute(absolute_directory) != OK:
		_error = "Could not create P2.16 output directory %s" % absolute_directory
		return false
	var source_directory := str(checkpoint.get("run_directory", ""))
	for filename in ["polar_results.csv", "polar_results.json", "polar_summary.json", "polar_checkpoint.json"]:
		var source := source_directory.path_join(filename)
		if not FileAccess.file_exists(source):
			_error = "Missing Polar artifact %s" % source
			return false
		var file := FileAccess.open(absolute_directory.path_join(filename), FileAccess.WRITE)
		if file == null:
			_error = "Could not write P2.16 artifact %s" % filename
			return false
		file.store_string(FileAccess.get_file_as_string(source))
	var metadata: Dictionary = checkpoint.get("run_metadata", {})
	_write_json(destination.path_join("p216_manifest.json"), {
		"phase": "Nordic 28 P2.16 geometry-consistent 28 m2 sail rig",
		"stage": stage,
		"test_run_id": run_id,
		"polar_config_fingerprint": checkpoint.get("config_hash", ""),
		"boat_config_fingerprint": checkpoint.get("boat_config_hash", ""),
		"boat_scene_path": BOAT_SCENE,
		"boat_scene_sha256": _sha256_file(BOAT_SCENE),
		"physics_profile_path": PHYSICS_PROFILE_PATH,
		"physics_profile_sha256": _sha256_file(PHYSICS_PROFILE_PATH),
		"visual_profile_path": VISUAL_PROFILE_PATH,
		"visual_profile_sha256": _sha256_file(VISUAL_PROFILE_PATH),
		"rig_geometry": geometry,
		"conditions": metadata.get("config", {}).get("explicit_cases", []),
		"engine_state_expected": "OFF",
		"auto_trim": true,
		"wave_mode": "WaveSampler active, sampler strength zeroed by Polar runner",
		"water_current": "zero",
		"physics_step_seconds": 1.0 / 60.0,
		"execution_acceleration": {"engine_physics_ticks_per_second": ENGINE_PHYSICS_HZ, "time_scale": ACCELERATION_SCALE, "effective_simulated_step_seconds": 1.0 / 60.0},
		"stability_config": metadata.get("config", {}),
		"configuration_note": "P2.3c physics/visual resources remain unchanged. P2.16 modifies only physical sail areas and corresponding pressure-centre geometry plus the listed visual rig anchors.",
	})
	return true


func _write_combined_results() -> bool:
	var rows := _all_results()
	if rows.size() != 12:
		_error = "Expected 12 mirrored P2.16 conditions, got %d" % rows.size()
		return false
	var enriched: Array[Dictionary] = []
	for row_variant in rows:
		var row: Dictionary = row_variant.duplicate(true)
		if str(row.get("case_id", "")).ends_with("_090twa_port"):
			row["source_test_run_id"] = _smoke_checkpoint.get("test_run_id", "")
			row["polar_config_fingerprint"] = _smoke_checkpoint.get("config_hash", "")
		else:
			row["source_test_run_id"] = _full_checkpoint.get("test_run_id", "")
			row["polar_config_fingerprint"] = _full_checkpoint.get("config_hash", "")
		enriched.append(row)
	_write_json(OUTPUT_ROOT.path_join("p216_results.json"), enriched)
	var csv_path := ProjectSettings.globalize_path(OUTPUT_ROOT.path_join("p216_results.csv"))
	var csv := FileAccess.open(csv_path, FileAccess.WRITE)
	if csv == null:
		_error = "Could not write combined P2.16 CSV"
		return false
	var fields := [
		"case_id", "source_test_run_id", "polar_config_fingerprint", "target_tws_kn", "target_twa_deg", "tack", "status",
		"measured_twa_deg", "mean_sog_kn", "mean_vmg_kn", "mean_stw_kn", "mean_heel_deg", "mean_rudder_deg",
		"rudder_saturation_fraction", "main_sail_deg", "headsail_deg", "mean_main_forward_force_n",
		"mean_headsail_forward_force_n", "failure_reason",
	]
	csv.store_csv_line(PackedStringArray(fields))
	for row in enriched:
		var values := PackedStringArray()
		for field in fields:
			values.append(str(row.get(field, "")))
		csv.store_csv_line(values)
	csv.close()
	_write_comparison()
	_write_json(OUTPUT_ROOT.path_join("p216_summary.json"), {
		"experiment": "Nordic 28 P2.16 geometry-consistent approximately 28 m2 rig speed validation",
		"boat_scene_path": BOAT_SCENE,
		"physics_profile_path": PHYSICS_PROFILE_PATH,
		"visual_profile_path": VISUAL_PROFILE_PATH,
		"test_run_ids": [_smoke_checkpoint.get("test_run_id", ""), _full_checkpoint.get("test_run_id", "")],
		"configuration_fingerprints": [_smoke_checkpoint.get("config_hash", ""), _full_checkpoint.get("config_hash", "")],
		"boat_configuration_fingerprints": [_smoke_checkpoint.get("boat_config_hash", ""), _full_checkpoint.get("boat_config_hash", "")],
		"result_count": enriched.size(),
		"status_counts": _status_counts(enriched),
		"rig_geometry": _smoke_geometry,
		"comparison_baseline": P215_COMPARISON_CSV,
		"comparison_policy": "SOG comparison is presented only when each P2.16 condition has STABLE port and starboard rows; baseline is P2.15 stable-tack mean. Heel and rudder are absolute-value means.",
	})
	return true


func _write_comparison() -> void:
	var baseline_file := FileAccess.open(P215_COMPARISON_CSV, FileAccess.READ)
	if baseline_file == null:
		_error = "P2.15 comparison data unavailable: %s" % P215_COMPARISON_CSV
		return
	var baseline_rows: Dictionary = {}
	var headers := baseline_file.get_csv_line()
	while not baseline_file.eof_reached():
		var values := baseline_file.get_csv_line()
		if values.is_empty() or values.size() < headers.size():
			continue
		var row: Dictionary = {}
		for index in range(headers.size()):
			row[headers[index]] = values[index]
		baseline_rows["%.0f/%.0f" % [float(row.get("target_tws_kn", 0.0)), float(row.get("target_twa_deg", 0.0))]] = row
	baseline_file.close()
	var grouped: Dictionary = {}
	for row_variant in _all_results():
		var row: Dictionary = row_variant
		var key := "%.0f/%.0f" % [float(row.get("target_tws_kn", 0.0)), absf(float(row.get("target_twa_deg", 0.0)))]
		var group: Array = grouped.get(key, [])
		group.append(row)
		grouped[key] = group
	var output_fields := PackedStringArray([
		"target_tws_kn", "target_twa_deg", "p23c_status", "p23c_sog_kn", "p216_port_status", "p216_starboard_status",
		"p216_mean_stable_sog_kn", "p216_vs_p23c_sog_change_pct", "p216_actual_twa_abs_deg",
		"p216_heel_abs_deg", "p216_rudder_abs_deg", "p216_rudder_saturation_fraction",
		"p216_main_forward_force_n", "p216_jib_forward_force_n",
	])
	var comparison_csv := FileAccess.open(ProjectSettings.globalize_path(OUTPUT_ROOT.path_join("p216_vs_p215.csv")), FileAccess.WRITE)
	if comparison_csv == null:
		_error = "Could not write P2.16 vs P2.15 comparison CSV"
		return
	comparison_csv.store_csv_line(output_fields)
	var comparison_json: Array[Dictionary] = []
	for tws in [8.0, 12.0, 16.0]:
		for angle in [90.0, 120.0]:
			var key := "%.0f/%.0f" % [tws, angle]
			var group: Array = grouped.get(key, [])
			var port: Dictionary = {}
			var starboard: Dictionary = {}
			for result in group:
				if str(result.get("tack", "")) == "PORT":
					port = result
				else:
					starboard = result
			var base: Dictionary = baseline_rows.get(key, {})
			var pair_stable := not port.is_empty() and not starboard.is_empty() and str(port.get("status", "")) == "STABLE" and str(starboard.get("status", "")) == "STABLE"
			var p216_sog := (float(port.get("mean_sog_kn", 0.0)) + float(starboard.get("mean_sog_kn", 0.0))) * 0.5 if pair_stable else NAN
			var base_sog := float(base.get("p23c_sog_kn", NAN))
			var change_pct := (p216_sog / base_sog - 1.0) * 100.0 if pair_stable and base_sog > 0.0 else NAN
			var comparison := {
				"target_tws_kn": tws,
				"target_twa_deg": angle,
				"p23c_status": base.get("p23c_status", "MISSING"),
				"p23c_sog_kn": base_sog,
				"p216_port_status": port.get("status", "MISSING"),
				"p216_starboard_status": starboard.get("status", "MISSING"),
				"p216_mean_stable_sog_kn": p216_sog,
				"p216_vs_p23c_sog_change_pct": change_pct,
				"p216_actual_twa_abs_deg": (absf(float(port.get("measured_twa_deg", 0.0))) + absf(float(starboard.get("measured_twa_deg", 0.0)))) * 0.5 if not port.is_empty() and not starboard.is_empty() else NAN,
				"p216_heel_abs_deg": (absf(float(port.get("mean_heel_deg", 0.0))) + absf(float(starboard.get("mean_heel_deg", 0.0)))) * 0.5 if not port.is_empty() and not starboard.is_empty() else NAN,
				"p216_rudder_abs_deg": (absf(float(port.get("mean_rudder_deg", 0.0))) + absf(float(starboard.get("mean_rudder_deg", 0.0)))) * 0.5 if not port.is_empty() and not starboard.is_empty() else NAN,
				"p216_rudder_saturation_fraction": (float(port.get("rudder_saturation_fraction", 0.0)) + float(starboard.get("rudder_saturation_fraction", 0.0))) * 0.5 if not port.is_empty() and not starboard.is_empty() else NAN,
				"p216_main_forward_force_n": (float(port.get("mean_main_forward_force_n", 0.0)) + float(starboard.get("mean_main_forward_force_n", 0.0))) * 0.5 if pair_stable else NAN,
				"p216_jib_forward_force_n": (float(port.get("mean_headsail_forward_force_n", 0.0)) + float(starboard.get("mean_headsail_forward_force_n", 0.0))) * 0.5 if pair_stable else NAN,
				"p216_stable_pair": pair_stable,
			}
			comparison_json.append(comparison)
			var line := PackedStringArray()
			for field in output_fields:
				var value: Variant = comparison.get(field, "")
				line.append("" if value is float and not is_finite(value) else str(value))
			comparison_csv.store_csv_line(line)
	comparison_csv.close()
	_write_json(OUTPUT_ROOT.path_join("p216_vs_p215.json"), comparison_json)


func _all_results() -> Array:
	var result: Array = []
	result.append_array(_smoke_checkpoint.get("results", []))
	result.append_array(_full_checkpoint.get("results", []))
	return result


func _status_counts(rows: Array) -> Dictionary:
	var counts: Dictionary = {}
	for row in rows:
		var status := str(row.get("status", "UNKNOWN"))
		counts[status] = int(counts.get(status, 0)) + 1
	return counts


func _write_stage_manifest() -> void:
	_write_json(OUTPUT_ROOT.path_join("p216_stage_manifest.json"), {
		"phase": "Nordic 28 P2.16 28 m2 sail upgrade",
		"smoke_test_run_id": _smoke_checkpoint.get("test_run_id", ""),
		"smoke_fingerprint": _smoke_checkpoint.get("config_hash", ""),
		"remaining_test_run_id": _full_checkpoint.get("test_run_id", ""),
		"remaining_fingerprint": _full_checkpoint.get("config_hash", ""),
		"boat_configuration_fingerprint": _smoke_checkpoint.get("boat_config_hash", ""),
		"rig_geometry": _smoke_geometry,
	})


func _sha256_file(resource_path: String) -> String:
	var file := FileAccess.open(resource_path, FileAccess.READ)
	if file == null:
		return "UNAVAILABLE"
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(file.get_buffer(file.get_length()))
	return context.finish().hex_encode()


func _write_json(resource_path: String, value: Variant) -> void:
	var absolute_path := ProjectSettings.globalize_path(resource_path)
	var directory := absolute_path.get_base_dir()
	if DirAccess.make_dir_recursive_absolute(directory) != OK and not DirAccess.dir_exists_absolute(directory):
		_error = "Could not create output directory %s" % directory
		return
	var file := FileAccess.open(absolute_path, FileAccess.WRITE)
	if file == null:
		_error = "Could not write JSON: %s" % absolute_path
		return
	file.store_string(JSON.stringify(value, "\t") + "\n")


func _finish(exit_code: int, message: String = "") -> void:
	Engine.physics_ticks_per_second = _old_physics_hz
	Engine.time_scale = _old_time_scale
	if _lab != null and is_instance_valid(_lab):
		_lab.queue_free()
	if not message.is_empty():
		push_error("[polar p2.16] " + message)
		quit(exit_code)
		return
	if not _error.is_empty():
		push_error("[polar p2.16] " + _error)
		quit(1)
		return
	quit(exit_code)
