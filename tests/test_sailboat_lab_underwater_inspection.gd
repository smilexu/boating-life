extends SceneTree

const LAB_PATH := "res://scenes/SailboatLab.tscn"
const SHARED_WATER_PATH := "res://materials/sea_water_material.tres"
var _checks := 0
var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var shared_water := load(SHARED_WATER_PATH) as ShaderMaterial
	var scene_error := change_scene_to_file(LAB_PATH)
	_expect(scene_error == OK, "test loads SailboatLab")
	for _frame in range(20):
		await process_frame
		if current_scene != null:
			break
	var lab := current_scene as Node3D
	_expect(lab != null, "SailboatLab is active")
	if lab == null:
		_finish()
		return

	var boat := lab.get_node("SailboatBody") as RigidBody3D
	var water := lab.get_node("WaterSurface") as MeshInstance3D
	var static_water := lab.get_node("WaterSurfaceStatic") as MeshInstance3D
	var sampler := lab.get_node("WaveSampler") as WaveSampler
	var material := water.material_override as ShaderMaterial
	_expect(material != null and material != shared_water, "SailboatLab uses a private ShaderMaterial instance")
	_expect(material.shader == shared_water.shader, "private material retains the shared water shader")
	_expect(shared_water.get_shader_parameter("debug_visual_alpha_scale") == 1.0, "shared material keeps its opaque default")
	_expect(water.visible and not static_water.visible, "normal mode shows the dynamic sea only")

	var transform_before := boat.global_transform
	lab.call("set_water_display_mode", 1)
	_expect(water.visible and not static_water.visible, "translucent mode keeps the active dynamic sea visible")
	_expect(is_equal_approx(float(material.get_shader_parameter("debug_visual_alpha_scale")), 0.25), "translucent mode applies 25% visual opacity")
	_expect(boat.global_transform.is_equal_approx(transform_before), "changing water appearance does not teleport the rigid body")
	_expect(shared_water.get_shader_parameter("debug_visual_alpha_scale") == 1.0, "translucent mode does not mutate the shared material")

	lab.call("set_water_display_mode", 2)
	_expect(not water.visible and not static_water.visible, "hidden mode hides only the visible water meshes")
	_expect(bool(boat.call("get_debug_snapshot").get("dynamic_waves_enabled", false)), "hidden water does not disable dynamic buoyancy sampling")
	_expect(sampler == lab.get_node("WaveSampler"), "WaveSampler remains alive in hidden mode")
	var start_wave_time := sampler.wave_time_seconds
	for _step in range(24):
		await physics_frame
	var physics_snapshot: Dictionary = boat.call("get_debug_snapshot")
	_expect(sampler.wave_time_seconds > start_wave_time, "wave time continues to advance with water hidden")
	_expect(int(physics_snapshot.get("wave_query_count_per_tick", 0)) == 4, "four physical wave queries continue with water hidden")
	_expect(float(physics_snapshot.get("buoyancy_total_n", 0.0)) > 0.0, "buoyancy force remains active with water hidden")

	lab.call("set_water_display_mode", 0)
	_expect(water.visible and is_equal_approx(float(material.get_shader_parameter("debug_visual_alpha_scale")), 1.0), "normal mode restores opaque water appearance")
	lab.call("set_dynamic_waves_enabled", false)
	_expect(not water.visible and static_water.visible, "static-water physics mode selects only the static visual")
	lab.call("set_water_display_mode", 1)
	var static_material := static_water.material_override as BaseMaterial3D
	_expect(static_water.visible and static_material.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA, "static water also supports the translucent inspection mode")
	_expect(is_equal_approx(static_material.albedo_color.a, 0.25), "static water translucent mode uses 25% opacity")
	lab.call("set_water_display_mode", 2)
	_expect(not water.visible and not static_water.visible, "hidden mode also hides the static water visual")
	lab.call("set_water_display_mode", 0)
	_expect(static_water.visible and not water.visible, "restoring normal mode restores static-water visibility")
	lab.call("set_dynamic_waves_enabled", true)
	_expect(water.visible and not static_water.visible, "restoring dynamic waves restores the dynamic water visual")

	var visuals := boat.get_node("UnderwaterDebugVisuals")
	var inspect: Dictionary = visuals.call("get_inspection_snapshot")
	var force_point: Vector3 = physics_snapshot.get("rudder_center_local_m", Vector3.ZERO)
	var keel_point: Vector3 = physics_snapshot.get("keel_center_local_m", Vector3.ZERO)
	var floats: PackedVector3Array = physics_snapshot.get("float_point_offsets_local_m", PackedVector3Array())
	_expect(floats.size() == 4, "debug snapshot exposes the four real profile float points")
	_expect(Vector3(inspect.get("rudder_force_point_local_m", Vector3.ZERO)).is_equal_approx(force_point), "rudder force marker source is the physical profile point")
	_expect(Vector3(inspect.get("keel_force_point_local_m", Vector3.ZERO)).is_equal_approx(keel_point), "keel force marker source is the physical profile point")
	_expect(bool(inspect.get("nordic_hull_found", false)), "Nordic 28 hull mesh geometry is available for inspection")
	_expect(bool(inspect.get("rudder_blade_bounds_valid", false)), "rudder blade visual bounds are measured from its mesh")
	_expect(str(inspect.get("collision_shape_type", "")) == "BoxShape3D", "collision outline uses the real BoxShape3D")
	for marker_name in ["rudder_axis", "rudder_force_point", "keel_force_point", "collision_outline", "float_points"]:
		visuals.call("set_marker_enabled", marker_name, true)
		_expect(bool(visuals.call("is_marker_enabled", marker_name)), "%s debug marker can be enabled" % marker_name)
	_expect((visuals.get_node("CollisionOutline") as MeshInstance3D).visible, "collision outline becomes visible when enabled")
	_expect((visuals.get_node("RudderForcePoint") as MeshInstance3D).position.is_equal_approx(force_point), "rudder force marker is placed at its current profile location")
	_expect((visuals.get_node("KeelForcePoint") as MeshInstance3D).position.is_equal_approx(keel_point), "keel force marker is placed at its current profile location")
	for index in range(mini(4, floats.size())):
		_expect((visuals.get_node("FloatPoint%d" % index) as MeshInstance3D).position.is_equal_approx(floats[index]), "float marker %d matches its profile location" % index)

	var pivot := boat.get_node("VisualRoot/RudderPivot") as Node3D
	boat.call("set_target_rudder_angle", deg_to_rad(35.0))
	for _step in range(42):
		await physics_frame
	var rudder_snapshot: Dictionary = visuals.call("get_inspection_snapshot")
	_expect(absf(float(rudder_snapshot.get("rudder_actual_angle_rad", 0.0)) - float(rudder_snapshot.get("rudder_visual_angle_rad", 0.0))) < deg_to_rad(0.5), "rudder visual pivot follows the limited physical rudder angle")
	_expect(is_equal_approx(pivot.rotation.y, float(rudder_snapshot.get("rudder_actual_angle_rad", 0.0))), "visual rudder angle uses the body actual angle")
	var rudder_alignment: Dictionary = pivot.call("get_visual_alignment_snapshot")
	print("Nordic 28 rudder visual alignment: ", rudder_alignment)
	_expect(bool(rudder_alignment.get("configured", false)), "Nordic 28 rudder visual alignment configures from actual hull triangles")
	var aligned_pivot_local: Vector3 = rudder_alignment.get("rudder_pivot_local_m", Vector3.ZERO)
	var visual_force_point: Vector3 = rudder_alignment.get("force_point_local_m", Vector3.ZERO)
	_expect(absf(aligned_pivot_local.y - float(rudder_alignment.get("hull_bottom_y_local_m", NAN)) - float(rudder_alignment.get("axis_embed_m", 0.0))) < 0.005, "visual rudder pivot is mounted at the sampled stern underside with the configured embed")
	_expect(visual_force_point.is_equal_approx(force_point), "visual rudder does not change the physical hydrodynamic force point")
	var force_point_chord_fraction := float(rudder_alignment.get("physical_force_point_chord_fraction", NAN))
	_expect(force_point_chord_fraction >= 0.24 and force_point_chord_fraction <= 0.26, "physical rudder force point aligns with the visual foil quarter-chord")
	var force_point_depth_fraction := float(rudder_alignment.get("physical_force_point_depth_fraction", NAN))
	_expect(force_point_depth_fraction >= 0.39 and force_point_depth_fraction <= 0.44, "unchanged physical rudder force point remains inside the vertically shifted visual foil")
	_expect(is_equal_approx(aligned_pivot_local.z, force_point.z), "visual rudder axis retains the profile stern station")
	var blade_size: Vector3 = rudder_alignment.get("blade_size_m", Vector3.ZERO)
	_expect(blade_size.y > 1.2 and blade_size.z > 0.4, "rudder foil spans from near the hull to close to the keel bottom")
	_expect(float(rudder_alignment.get("foil_planform_area_m2", 0.0)) > 0.48 and float(rudder_alignment.get("foil_planform_area_m2", 0.0)) < 0.53, "rudder foil planform remains close to the existing 0.5 m2 physical rudder area")
	var foil_top_y := float(rudder_alignment.get("foil_top_local_y_m", NAN))
	var hull_bottom_y := float(rudder_alignment.get("hull_bottom_y_local_m", NAN))
	_expect(is_equal_approx(hull_bottom_y - foil_top_y, 0.08), "rudder foil top sits 8 cm below the curved stern underside")
	var top_clearance: Dictionary = rudder_alignment.get("foil_top_clearance_by_angle_m", {})
	_expect(float(top_clearance.get(-35.0, NAN)) > 0.015, "foil top remains clear of the curved hull underside at minus full rudder")
	_expect(float(top_clearance.get(0.0, NAN)) > 0.015, "foil top remains clear of the curved hull underside at neutral rudder")
	_expect(float(top_clearance.get(35.0, NAN)) > 0.015, "foil top remains clear of the curved hull underside at plus full rudder")
	_expect(float(rudder_alignment.get("stock_length_m", 0.0)) > 0.14 and float(rudder_alignment.get("stock_length_m", 1.0)) < 0.18, "visual rudder stock extends through the old gap and overlaps the foil by 3 cm")
	_expect(absf(float(rudder_alignment.get("stock_foil_overlap_m", 0.0)) - 0.03) < 0.001, "visual rudder stock embeds 3 cm into the foil to close the previous 5 cm gap")
	_expect(float(rudder_alignment.get("stock_bottom_local_y_m", 0.0)) < float(rudder_alignment.get("foil_top_local_y_m", 0.0)), "rudder stock ends inside the blade while sharing its rotation pivot")
	for target_degrees in [-35.0, 0.0, 35.0]:
		boat.call("set_target_rudder_angle", deg_to_rad(target_degrees))
		for _step in range(72):
			await physics_frame
		var angle_snapshot: Dictionary = boat.call("get_debug_snapshot")
		var actual_degrees := rad_to_deg(float(angle_snapshot.get("actual_rudder_angle_rad", 0.0)))
		_expect(absf(actual_degrees - target_degrees) < 0.5, "rudder physically reaches the %+.0f degree visual clearance case" % target_degrees)
		_expect(absf(rad_to_deg(pivot.rotation.y) - actual_degrees) < 0.1, "visual rudder matches actual angle at %+.0f degrees" % target_degrees)

	var camera := lab.get_node("Camera3D") as Camera3D
	var boat_transform_before_camera := boat.global_transform
	lab.call("set_camera_mode", 2)
	_expect(boat.global_transform.is_equal_approx(boat_transform_before_camera), "underwater camera mode does not alter the rigid-body transform")
	_expect(int(lab.call("get_camera_mode")) == 2, "underwater camera mode can be selected")
	var camera_before_drag := camera.global_transform
	var debug_panel := lab.get_node("DebugPanel").find_child("SailboatLabDebugPanelContent", true, false) as Control
	var wheel_over_panel := InputEventMouseButton.new()
	wheel_over_panel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel_over_panel.pressed = true
	wheel_over_panel.position = debug_panel.get_global_rect().get_center()
	var radius_before_panel_wheel := float(lab.get("_inspection_radius_m"))
	lab.call("_input", wheel_over_panel)
	_expect(is_equal_approx(float(lab.get("_inspection_radius_m")), radius_before_panel_wheel), "mouse wheel over the F3 panel remains available for panel interaction")
	var wheel_over_view := InputEventMouseButton.new()
	wheel_over_view.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel_over_view.pressed = true
	wheel_over_view.position = lab.get_viewport().get_visible_rect().size * Vector2(0.8, 0.5)
	lab.call("_input", wheel_over_view)
	_expect(is_equal_approx(float(lab.get("_inspection_radius_m")), radius_before_panel_wheel - 0.5), "mouse wheel over the 3D view still zooms the inspection camera")
	var right_press := InputEventMouseButton.new()
	right_press.button_index = MOUSE_BUTTON_RIGHT
	right_press.pressed = true
	lab.call("_input", right_press)
	var mouse_move := InputEventMouseMotion.new()
	mouse_move.relative = Vector2(25.0, -10.0)
	lab.call("_input", mouse_move)
	lab.call("_process", 0.2)
	_expect(not camera.global_transform.is_equal_approx(camera_before_drag), "underwater camera orbit responds to mouse drag")
	var right_release := right_press.duplicate() as InputEventMouseButton
	right_release.pressed = false
	lab.call("_input", right_release)
	var camera_before_pan := camera.global_transform
	var middle_press := InputEventMouseButton.new()
	middle_press.button_index = MOUSE_BUTTON_MIDDLE
	middle_press.pressed = true
	lab.call("_input", middle_press)
	var pan_move := InputEventMouseMotion.new()
	pan_move.relative = Vector2(36.0, 22.0)
	lab.call("_input", pan_move)
	lab.call("_process", 0.2)
	_expect(not camera.global_transform.is_equal_approx(camera_before_pan), "underwater camera middle-button drag pans the inspection view")
	var middle_release := middle_press.duplicate() as InputEventMouseButton
	middle_release.pressed = false
	lab.call("_input", middle_release)
	_expect(boat.global_transform.is_equal_approx(boat_transform_before_camera), "camera orbit remains presentation-only")

	print("Nordic 28 inspection snapshot: hull=%s min=%s max=%s rudder_pivot=%s axis=%s blade_min=%s blade_max=%s waterline_y=%.3f rudder_force=%s keel_force=%s collision=%s" % [
		str(inspect.get("nordic_hull_size_m", Vector3.ZERO)),
		str(inspect.get("nordic_hull_min_local_m", Vector3.ZERO)),
		str(inspect.get("nordic_hull_max_local_m", Vector3.ZERO)),
		str(inspect.get("rudder_pivot_local_m", Vector3.ZERO)),
		str(inspect.get("rudder_axis_local", Vector3.UP)),
		str(inspect.get("rudder_blade_min_local_m", Vector3.ZERO)),
		str(inspect.get("rudder_blade_max_local_m", Vector3.ZERO)),
		float(inspect.get("waterline_local_y_m", 0.0)),
		str(force_point),
		str(keel_point),
		str(inspect.get("collision_shape_bounds_local_m", {})),
	])
	_finish()


func _finish() -> void:
	if _failures.is_empty():
		print("SailboatLab underwater inspection tests: %d checks passed." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("FAIL: " + description)
		push_error("FAIL: " + description)
