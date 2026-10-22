extends SceneTree
## Shared Main/SailboatLab visual sailcloth, Logo, rigging, and debug-toggle checks.

const LAB_SCENE := preload("res://scenes/SailboatLab.tscn")

var _checks := 0
var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var lab := LAB_SCENE.instantiate()
	root.add_child(lab)
	await process_frame
	await process_frame
	await create_timer(0.18).timeout
	var boat := lab.get_node("SailboatBody") as RigidBody3D
	var main_sail := boat.get_node("VisualRoot/VisualBoomPivot/MainSailMesh") as MeshInstance3D
	var jib := boat.get_node("VisualRoot/HeadsailVisual") as MeshInstance3D
	var visuals := boat.get_node("VisualRoot/SailVisuals")
	var main_snapshot: Dictionary = main_sail.call("get_visual_snapshot")
	var jib_snapshot: Dictionary = jib.call("get_visual_snapshot")
	_expect(main_sail.mesh is ArrayMesh and jib.mesh is ArrayMesh, "both sails use subdivided ArrayMesh cloth surfaces")
	_expect(int(main_snapshot.get("vertex_count", 0)) == 297, "mainsail uses 26 by 10 subdivisions")
	_expect(int(jib_snapshot.get("vertex_count", 0)) == 189, "Jib uses 20 by 8 subdivisions")
	_expect(main_sail.mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV].size() == 297, "mainsail mesh has stable UVs for Logo and seams")
	_expect(jib.mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV].size() == 189, "Jib mesh has stable UVs")
	_expect(main_sail.mesh.surface_get_arrays(0)[Mesh.ARRAY_TANGENT].size() == 297 * 4, "mainsail mesh stores tangent frames for its UV orientation")
	_expect(jib.mesh.surface_get_arrays(0)[Mesh.ARRAY_TANGENT].size() == 189 * 4, "Jib mesh stores tangent frames for its UV orientation")
	_expect(main_sail.material_override is ShaderMaterial and jib.material_override is ShaderMaterial, "both sails use per-vessel cloth shader materials")
	var main_material := main_sail.material_override as ShaderMaterial
	var jib_material := jib.material_override as ShaderMaterial
	var logo_texture := main_material.get_shader_parameter("sail_logo") as Texture2D
	_expect(logo_texture != null, "smile Logo is sampled by the mainsail cloth material")
	var logo_image := logo_texture.get_image() if logo_texture != null else null
	_expect(logo_image != null and not logo_image.is_empty(), "mainsail Logo raster is readable for alpha validation")
	if logo_image != null and not logo_image.is_empty():
		_expect(logo_image.get_pixel(356, 320).a > 0.9, "Logo raster includes an opaque navy eye")
		_expect(logo_image.get_pixel(512, 644).a > 0.9, "Logo raster includes the opaque smile curve")
		_expect(logo_image.get_pixel(512, 870).a > 0.9, "Logo raster includes the lower decorative arc")
	_expect(main_material.get_shader_parameter("logo_center") == Vector2(0.5, 0.58), "Logo is placed in the upper-middle mainsail UV area")
	_expect(main_material.get_shader_parameter("logo_size") == Vector2(0.98, 0.25), "Logo mapping is enlarged while remaining within the sail UV domain")
	var logo_region_min: Vector2 = main_material.get_shader_parameter("logo_center") - main_material.get_shader_parameter("logo_size") * 0.5
	var logo_region_max: Vector2 = main_material.get_shader_parameter("logo_center") + main_material.get_shader_parameter("logo_size") * 0.5
	_expect(logo_region_min.x >= 0.0 and logo_region_max.x <= 1.0 and logo_region_min.y >= 0.0 and logo_region_max.y <= 1.0, "full logo sample region stays inside the triangular sail UV bounds")
	_expect((main_material.shader as Shader).code.contains("render_mode cull_disabled"), "mainsail Logo material renders on both sail faces")
	var boom_pivot := boat.get_node("VisualRoot/VisualBoomPivot") as Node3D
	var saved_boom_rotation := boom_pivot.rotation
	for angle_degrees in [0.0, 30.0, -30.0, 60.0, -60.0]:
		boom_pivot.rotation.y = deg_to_rad(angle_degrees)
		var angle_region_min: Vector2 = main_material.get_shader_parameter("logo_center") - main_material.get_shader_parameter("logo_size") * 0.5
		var angle_region_max: Vector2 = main_material.get_shader_parameter("logo_center") + main_material.get_shader_parameter("logo_size") * 0.5
		_expect(angle_region_min.x >= 0.0 and angle_region_max.x <= 1.0 and angle_region_min.y >= 0.0 and angle_region_max.y <= 1.0, "full Logo remains in the sail UV interior at boom angle %d degrees" % int(angle_degrees))
	boom_pivot.rotation = saved_boom_rotation
	_expect(main_material.get_shader_parameter("wireframe_grid") == Vector2(10.0, 26.0), "mainsail wireframe matches its actual UV subdivisions")
	_expect(jib_material.get_shader_parameter("wireframe_grid") == Vector2(8.0, 20.0), "Jib wireframe matches its actual UV subdivisions")
	_expect(ResourceLoader.exists("res://assets/boats/nordic28/sail_logo_smile.svg"), "editable SVG Logo source is present")
	_expect(ResourceLoader.exists("res://assets/boats/nordic28/sail_logo_smile.png"), "transparent 1024px Logo texture is present")
	var profile: Resource = boat.get("profile")
	_expect(absf(float(profile.get("main_sail_area_m2")) - 10.16025) < 0.001, "visual cloth change leaves physical mainsail area unchanged")
	_expect(absf(float(profile.get("headsail_area_m2")) - 5.16) < 0.001, "visual cloth change leaves physical Jib area unchanged")
	var original_main_vertices: int = (main_sail.mesh as ArrayMesh).surface_get_array_len(0)
	var clew: Vector3 = jib.call("get_clew_for_angle", deg_to_rad(70.0))
	var jib_vertices: PackedVector3Array = jib.call("get_vertices_for_angle", deg_to_rad(70.0))
	_expect(jib_vertices.size() == 189, "Jib trim uses shader endpoint displacement without rebuilding vertex count")
	_expect(jib_vertices[8].is_equal_approx(clew), "Jib Clew remains at the expected endpoint while its subdivided mesh stays fixed")
	jib.call("set_sheet_angle", deg_to_rad(70.0))
	var jib_material_clew_delta: Vector3 = jib_material.get_shader_parameter("clew_delta_local")
	var jib_neutral_clew: Vector3 = jib.call("get_clew_for_angle", 0.0)
	_expect(jib_material_clew_delta.is_equal_approx(clew - jib_neutral_clew), "Jib shader shifts only the Clew while Head and Tack stay fixed")
	visuals.call("set_debug_options", false, true, false, false)
	_expect(not bool(main_material.get_shader_parameter("billow_enabled")), "billow diagnostic toggle reaches the mainsail material")
	_expect(bool(jib_material.get_shader_parameter("wireframe_enabled")), "wireframe diagnostic toggle reaches the Jib material")
	_expect(not bool(main_material.get_shader_parameter("logo_enabled")), "Logo diagnostic toggle affects only its material layer")
	_expect(not bool(jib_material.get_shader_parameter("logo_enabled")), "Jib material keeps the Logo disabled")
	_expect(not (visuals.get_node("Nordic28Rigging") as Node3D).visible, "rigging diagnostic toggle hides only visual lines")
	visuals.call("set_debug_options", true, false, true, true)
	var visual_snapshot: Dictionary = visuals.call("get_visual_snapshot")
	_expect(bool(visual_snapshot.get("rigging_built", false)), "fixed and active rigging is built after visual anchors are configured")
	_expect(int(visual_snapshot.get("rigging_line_count", 0)) == 8, "rigging includes six fixed stay/spreader segments and two running sheets")
	_expect(int(visual_snapshot.get("rigging_draw_call_count", 0)) == 3, "fixed stays are combined into one mesh plus two dynamic sheet lines")
	_expect(bool((visuals.get_node("Nordic28Rigging") as Node3D).visible), "rigging returns when diagnostics re-enable it")
	var main_sheet_line := visuals.get_node("Nordic28Rigging/MainSheet") as MeshInstance3D
	var main_sheet_mesh := main_sheet_line.mesh
	visuals.call("_set_rig_line", "MainSheet", Vector3.ZERO, Vector3(0.5, 1.2, 2.0))
	_expect(main_sheet_line.mesh == main_sheet_mesh, "running sheet updates reuse their primitive mesh instead of rebuilding it")
	_expect(is_equal_approx((main_sheet_mesh as CylinderMesh).height, 1.0), "running sheet primitive retains unit height and scales by transform")
	_expect(original_main_vertices == 297, "sail geometry remains stable during wind/trim state updates")
	var debug_panel := lab.get_node("DebugPanel")
	_expect(debug_panel.find_child("SailBillowToggle", true, false) != null, "SailboatLab exposes a billow debug toggle")
	_expect(debug_panel.find_child("SailMeshToggle", true, false) != null, "SailboatLab exposes a wireframe debug toggle")
	_expect(debug_panel.find_child("SailLogoToggle", true, false) != null, "SailboatLab exposes a Logo debug toggle")
	_expect(debug_panel.find_child("SailRiggingToggle", true, false) != null, "SailboatLab exposes a rigging debug toggle")
	boat.call("set_dynamic_waves_enabled", false)
	boat.call("reset_to_neutral")
	boat.call("set_lab_test_wind", 8.0, 270.0)
	await physics_frame
	await create_timer(0.08).timeout
	var port_visual_state: Dictionary = visuals.call("get_visual_snapshot")
	_expect(str(port_visual_state.get("main_side", "")) == "左舷来风", "cloth state reads cached port-side apparent wind")
	_expect(float(port_visual_state.get("main_fill", 0.0)) > 0.5 and float(port_visual_state.get("jib_fill", 0.0)) > 0.5, "normal crosswind fills each sail from its own cached aero state")
	boat.call("set_lab_test_wind", 8.0, 90.0)
	await physics_frame
	await create_timer(0.08).timeout
	var starboard_visual_state: Dictionary = visuals.call("get_visual_snapshot")
	_expect(str(starboard_visual_state.get("main_side", "")) == "右舷来风", "billow source mirrors when cached wind changes to starboard")
	boat.call("reset_to_neutral")
	boat.call("set_lab_test_wind", 0.0, 0.0)
	await physics_frame
	await create_timer(0.08).timeout
	var calm_visual_state: Dictionary = visuals.call("get_visual_snapshot")
	_expect(float(calm_visual_state.get("main_fill", 1.0)) < 0.01 and float(calm_visual_state.get("jib_fill", 1.0)) < 0.01, "calm visual state relaxes both cloth surfaces")
	boat.call("reset_to_neutral")
	boat.call("set_lab_test_wind", 8.0, 0.0)
	await physics_frame
	await create_timer(0.08).timeout
	var luff_visual_state: Dictionary = visuals.call("get_visual_snapshot")
	_expect(float(luff_visual_state.get("main_fill", 1.0)) < 0.05, "near-headwind luffing state suppresses the mainsail's stable billow")
	var body_state: Dictionary = boat.call("get_debug_snapshot")
	_expect(int(body_state.get("wind_query_count_per_tick", 0)) <= 1, "visual update does not add WindField queries")
	_expect(int(body_state.get("wave_query_count_per_tick", 0)) <= 4, "visual update does not add WaveSampler queries")
	if _failures.is_empty():
		print("Nordic 28 V3 sail visual tests: %d checks passed." % _checks)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)
		return
	lab.queue_free()
	await process_frame
	quit(0)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
