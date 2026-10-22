extends SceneTree

const LAB_PATH := "res://scenes/SailboatLab.tscn"
var _checks := 0
var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene_error := change_scene_to_file(LAB_PATH)
	_expect(scene_error == OK, "loads SailboatLab with shared Nordic 28 boat scene")
	for _frame in range(48):
		await process_frame
	var lab := current_scene as Node3D
	if lab == null:
		_expect(false, "SailboatLab is active")
		_finish()
		return
	var boat := lab.get_node("SailboatBody") as RigidBody3D
	var helm := boat.get_node_or_null("VisualRoot/HelmVisual") as Node3D
	_expect(helm != null, "helm is installed under the unscaled shared VisualRoot")
	if helm == null:
		_finish()
		return
	var snapshot: Dictionary = helm.call("get_helm_snapshot")
	_expect(bool(snapshot.get("configured", false)), "helm configures after transformed Nordic hull geometry is ready")
	var anchors := boat.get_node("VisualRoot/VisualRigAnchors")
	var expected_floor := float(anchors.call("get_hull_surface_height_at", 0.0, 2.72))
	_expect(absf(helm.position.y - expected_floor) < 0.002, "pedestal foot is placed on sampled cockpit floor geometry")
	_expect(absf(helm.position.z - 2.72) < 0.001, "helm uses the approved cockpit station rather than the old yellow marker position")
	_expect(absf(float(snapshot.get("pedestal_height_m", 0.0)) - 0.72) < 0.001, "pedestal height is 0.72 m")
	_expect(absf(float(snapshot.get("wheel_outer_diameter_m", 0.0)) - 0.706) < 0.002, "wheel outer diameter is within the requested cruiser range")
	_expect(int(snapshot.get("spoke_count", 0)) == 6, "wooden wheel has six spokes")
	var pedestal := helm.get_node("FiberglassPedestal") as MeshInstance3D
	var pedestal_bounds := pedestal.mesh.get_aabb()
	_expect(absf(pedestal_bounds.size.y - 0.72) < 0.002, "trapezoid pedestal mesh spans the configured height")
	var rim := helm.get_node("HelmWheelActualAnglePivot/TeakWheelRim") as MeshInstance3D
	var teak_material := rim.material_override as StandardMaterial3D
	_expect(teak_material != null and teak_material.albedo_texture != null, "wheel rim uses generated teak grain texture")
	if teak_material != null:
		_expect(is_zero_approx(teak_material.metallic), "teak material is non-metallic")
		_expect(teak_material.roughness >= 0.30 and teak_material.roughness <= 0.45, "teak material retains a light varnished roughness")
	var spoke_batch := helm.get_node("HelmWheelActualAnglePivot/TeakWheelSpokes") as MultiMeshInstance3D
	_expect(spoke_batch.multimesh.instance_count == 6, "six teak spokes are batched into one low-cost draw")
	_expect(spoke_batch.material_override == teak_material, "teak texture is applied to the spokes as well as the rim")

	var rudder_marker := boat.get_node("VisualRoot/RudderAngleMarker") as Node3D
	_expect(not rudder_marker.visible, "old yellow rudder direction block is hidden during normal play")
	var marker_toggle := _find_named_node(lab.get_node("DebugPanel"), "RudderHeadingMarkerToggle") as CheckButton
	_expect(marker_toggle != null, "F3 underwater inspection retains a marker visibility toggle")
	if marker_toggle != null:
		marker_toggle.button_pressed = true
		await process_frame
		_expect(rudder_marker.visible, "F3 toggle can enable the yellow rudder debug marker")
		marker_toggle.button_pressed = false
		await process_frame
		_expect(not rudder_marker.visible, "F3 toggle can hide the rudder debug marker again")

	var rudder_pivot := boat.get_node("VisualRoot/RudderPivot") as Node3D
	var wheel_pivot := helm.get_node("HelmWheelActualAnglePivot") as Node3D
	for target_degrees in [-35.0, 0.0, 35.0]:
		boat.call("set_target_rudder_angle", deg_to_rad(target_degrees))
		for _step in range(80):
			await physics_frame
		var actual_angle := float(boat.get("actual_rudder_angle_rad"))
		var expected_wheel_angle := deg_to_rad(
			rad_to_deg(actual_angle)
			* float(snapshot.get("wheel_degrees_per_rudder_degree", 180.0 / 35.0))
			* float(snapshot.get("wheel_rotation_sign", -1.0))
		)
		_expect(absf(actual_angle - deg_to_rad(target_degrees)) < deg_to_rad(0.6), "body reaches requested physical rudder angle %+.0f degrees" % target_degrees)
		_expect(absf(rudder_pivot.rotation.y - actual_angle) < 0.0001, "underwater rudder visual keeps following the unchanged actual rudder angle")
		_expect(absf(wheel_pivot.rotation.z - expected_wheel_angle) < 0.0001, "helm wheel follows actual rudder angle with signed 180-to-35 mapping at %+.0f degrees" % target_degrees)
	_expect(float(snapshot.get("wheel_degrees_per_rudder_degree", 0.0)) > 5.14, "wheel angle ratio is kept as a Nordic visual profile setting")

	var body_snapshot: Dictionary = boat.call("get_debug_snapshot")
	_expect(int(body_snapshot.get("wave_query_count_per_tick", 0)) == 4, "helm adds no WaveSampler queries")
	_expect(int(body_snapshot.get("wind_query_count_per_tick", 0)) == 1, "helm adds no WindField queries")
	var physical_profile := boat.get("profile") as Resource
	_expect(is_equal_approx(float(physical_profile.get("main_sail_area_m2")), 10.16025), "physical main sail area remains unchanged")
	_expect(is_equal_approx(float(physical_profile.get("headsail_area_m2")), 5.16), "physical Jib area remains unchanged")
	_expect(is_equal_approx(float(physical_profile.get("rudder_area_m2")), 0.5), "physical rudder area remains unchanged")

	print("Nordic 28 helm snapshot: ", helm.call("get_helm_snapshot"))
	_finish()


func _find_named_node(root: Node, wanted_name: String) -> Node:
	if root.name == wanted_name:
		return root
	for child in root.get_children():
		var found := _find_named_node(child, wanted_name)
		if found != null:
			return found
	return null


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(description)
		push_error("FAIL: " + description)


func _finish() -> void:
	if _failures.is_empty():
		print("Nordic 28 helm visual tests: %d checks passed." % _checks)
		quit(0)
	else:
		push_error("Nordic 28 helm visual tests: %d checks, %d failures." % [_checks, _failures.size()])
		quit(1)
