class_name FishingRodRig
extends Node3D

## Small visual-only rod rig. Rod, guides and line use fixed-topology MultiMeshes;
## only their transforms change while the P2 state is active.

const LINE_RADIUS_M := 0.0012
const REEL_ROTATION_SIGN := -1.0
const REEL_SPOOL_CORE_RADIUS_M := 0.028
const REEL_LINE_LAYER_MIN_THICKNESS_M := 0.003
const REEL_LINE_LAYER_MAX_THICKNESS_M := 0.012
const REEL_LINE_VISUAL_RANGE_M := 50.0
const REEL_SPOOL_AXIAL_WIDTH_M := 0.064
const REEL_WINDING_BASE_OUTER_RADIUS_M := REEL_SPOOL_CORE_RADIUS_M + REEL_LINE_LAYER_MIN_THICKNESS_M
const REEL_WINDING_RING_COUNT := 56
const HANDHELD_WINDING_SHADER_CODE := """
shader_type spatial;
render_mode skip_vertex_transform, cull_back, diffuse_burley, specular_schlick_ggx;

instance uniform vec4 camera_relative_column_0 = vec4(1.0, 0.0, 0.0, 0.0);
instance uniform vec4 camera_relative_column_1 = vec4(0.0, 1.0, 0.0, 0.0);
instance uniform vec4 camera_relative_column_2 = vec4(0.0, 0.0, 1.0, 0.0);
instance uniform vec4 camera_relative_column_3 = vec4(0.0, 0.0, 0.0, 1.0);
uniform vec4 base_color : source_color = vec4(0.56, 0.63, 0.60, 1.0);
uniform vec4 strand_color : source_color = vec4(0.74, 0.78, 0.75, 1.0);
uniform float wraps_across_width = 16.0;
uniform float strand_half_width = 0.14;

void vertex() {
	mat4 camera_relative_model = mat4(
		camera_relative_column_0,
		camera_relative_column_1,
		camera_relative_column_2,
		camera_relative_column_3
	);
	mat3 camera_relative_basis = mat3(camera_relative_model);
	NORMAL = normalize(transpose(inverse(camera_relative_basis)) * NORMAL);
	TANGENT = normalize(camera_relative_basis * TANGENT);
	BINORMAL = normalize(camera_relative_basis * BINORMAL);
	vec4 view_position = camera_relative_model * vec4(VERTEX, 1.0);
	VERTEX = view_position.xyz;
	POSITION = PROJECTION_MATRIX * view_position;
}

void fragment() {
	// A low-frequency helical marking reads as wound line while avoiding the
	// sub-pixel torus repetition that shimmered as the camera moved.
	float phase = UV.y * wraps_across_width - UV.x;
	float distance_to_strand = abs(fract(phase) - 0.5);
	float antialias_width = max(fwidth(phase), 0.004);
	float strand = 1.0 - smoothstep(
		strand_half_width - antialias_width,
		strand_half_width + antialias_width,
		distance_to_strand
	);
	ALBEDO = mix(base_color.rgb, strand_color.rgb, strand * 0.58);
	METALLIC = 0.0;
	ROUGHNESS = 0.96;
}
"""
const REEL_SPOOL_CENTER_LOCAL := Vector3(0.046, 0.045, 0.19)
const CATCH_HOOK_LENGTH_RATIO := 0.45
const CATCH_DEFORMATION_SHADER := preload("res://shaders/fishing_catch_deform.gdshader")
const CATCH_BODY_CURVE_HOOK_U := 0.95
const CATCH_BODY_CURVE_TAIL_U := 0.05

var _profile: FishingRodMountProfile
var _rod_mesh: CylinderMesh
var _rod_multimesh: MultiMesh
var _rod_instance: MultiMeshInstance3D
var _guide_multimesh: MultiMesh
var _guide_instance: MultiMeshInstance3D
var _line_multimesh: MultiMesh
var _line_instance: MultiMeshInstance3D
var _reel_rotating_assembly: Node3D
var _reel_spool_visual: Node3D
var _reel_winding_visual: MultiMeshInstance3D
var _last_reel_line_length_m := -1.0
var _line_material: StandardMaterial3D
var _catch_container: Node3D
var _catch_body_length_m := 0.0
var _splash_ring: MeshInstance3D
var _splash_droplets: MultiMeshInstance3D
var _splash_droplet_multimesh: MultiMesh
var _splash_material: StandardMaterial3D
var _splash_elapsed := 10.0
var _splash_strength := 1.0
var _splash_origin_local := Vector3.ZERO
var _smoothed_load := 0.0
var _target_load := 0.0
var _tip_recoil_displacement := 0.0
var _tip_recoil_velocity := 0.0
var _animation_clock := 0.0
var _reel_spin_speed := 0.0
var _presentation_time_scale := 1.0
var _presentation_paused := false
var _line_active := false
var _hanging_line_active := false
var _line_tension := 0.35
var _line_water_entry_world := Vector3.ZERO
var _line_end_world := Vector3.ZERO
var _catch_deformation_surfaces: Array[Dictionary] = []
var _catch_hook_wriggle_offset_local := Vector3.ZERO
var _catch_tail_wriggle_offset_local := Vector3.ZERO
var _catch_spine_bend_angle_degrees := 0.0
var _catch_tail_whip_angle_degrees := 0.0
var _catch_tail_whip_phase := 0.0
var _catch_spine_curl_sign := 1.0
var _catch_spine_bend_power := 1.0


func configure(profile: FishingRodMountProfile) -> void:
	_profile = profile
	_build_visuals()


func set_rod_load(load_ratio: float) -> void:
	_target_load = clampf(load_ratio, 0.0, 1.0)


func get_current_rod_load_ratio() -> float:
	return _smoothed_load


func trigger_hook_strike() -> void:
	# A fast initial set plus a damped spring makes the hit readable in the
	# first few frames without teleporting the rod tip to its final bend.
	_smoothed_load = maxf(_smoothed_load, 0.54)
	_target_load = 1.0
	_tip_recoil_velocity += 1.85


func trigger_struggle_impulse(strength: float) -> void:
	_tip_recoil_velocity += clampf(strength, 0.0, 1.0) * 1.35


func set_reel_spin(speed_radians_per_second: float) -> void:
	_reel_spin_speed = speed_radians_per_second


func set_presentation_clock(time_scale: float, paused: bool) -> void:
	_presentation_time_scale = clampf(time_scale, 0.1, 4.0)
	_presentation_paused = paused


func reset_presentation_animation() -> void:
	_smoothed_load = 0.0
	_target_load = 0.0
	_tip_recoil_displacement = 0.0
	_tip_recoil_velocity = 0.0
	_animation_clock = 0.0
	_reel_spin_speed = 0.0
	_hanging_line_active = false
	_line_tension = 0.35
	_splash_elapsed = 10.0
	if _reel_rotating_assembly != null:
		_reel_rotating_assembly.rotation = Vector3(0.0, 0.0, PI * 0.5)
	set_reel_line_length(0.0)
	if _splash_ring != null:
		_splash_ring.visible = false
	if _splash_droplets != null:
		_splash_droplets.visible = false
	if _rod_multimesh != null:
		_update_rod_and_guides()
	_update_line()


func snap_rod_load_to_target() -> void:
	_smoothed_load = _target_load
	_tip_recoil_displacement = 0.0
	_tip_recoil_velocity = 0.0
	_update_rod_and_guides()


func set_line_active(active: bool) -> void:
	_line_active = active
	if not active:
		_hanging_line_active = false
	if _line_instance != null:
		_line_instance.visible = active


func is_line_active() -> bool:
	return _line_active


func set_line_points_world(water_entry: Vector3, end_point: Vector3) -> void:
	_hanging_line_active = false
	_line_water_entry_world = water_entry
	_line_end_world = end_point
	_update_line()


func set_hanging_line_world(mouth_point_world: Vector3) -> void:
	if _line_instance == null:
		return
	_line_active = true
	_hanging_line_active = true
	_line_end_world = mouth_point_world
	_line_instance.visible = true
	_update_line()


func set_line_tension(tension: float) -> void:
	_line_tension = clampf(tension, 0.0, 1.0)
	_update_line()


func get_rod_tip_local() -> Vector3:
	return _rod_point(1.0)


func get_rod_tip_world() -> Vector3:
	return to_global(get_rod_tip_local())


func get_catch_local_position() -> Vector3:
	return _catch_container.position if _catch_container != null else Vector3.ZERO


func get_catch_position_world() -> Vector3:
	return _catch_container.global_position if _catch_container != null else Vector3.ZERO


func has_catch_visual() -> bool:
	return _catch_container != null and is_instance_valid(_catch_container)


func get_catch_hook_point_world() -> Vector3:
	if not has_catch_visual():
		return Vector3.ZERO
	return _catch_container.to_global(get_catch_hook_local_offset())


func get_catch_hook_local_offset() -> Vector3:
	return Vector3(0.0, 0.0, -_catch_body_length_m * CATCH_HOOK_LENGTH_RATIO) + _catch_hook_wriggle_offset_local


func get_catch_body_length_m() -> float:
	return _catch_body_length_m


func get_catch_world_rotation() -> Quaternion:
	return _catch_container.global_transform.basis.get_rotation_quaternion() if has_catch_visual() else Quaternion.IDENTITY


func get_catch_tail_point_world() -> Vector3:
	if not has_catch_visual():
		return Vector3.ZERO
	return _catch_container.to_global(Vector3(0.0, 0.0, _catch_body_length_m * 0.55) + _catch_tail_wriggle_offset_local)


func set_catch_hanging_pose_world(mouth_point_world: Vector3, world_rotation: Quaternion) -> void:
	if not has_catch_visual():
		return
	var orientation := Basis(world_rotation).orthonormalized()
	var mouth_offset := orientation * get_catch_hook_local_offset()
	var center_world := mouth_point_world - mouth_offset
	_catch_container.global_transform = Transform3D(orientation, center_world)


## Sends a cumulative spine turn to the temporary fish's vertex shader.
## The shader integrates this tangent angle along the body, rotating each
## cross-section with the spine instead of offsetting vertices into a sharp S.
func set_catch_spine_curl(total_bend_degrees: float, tail_whip_degrees: float, tail_phase: float, curl_sign: float, bend_power: float) -> void:
	if not has_catch_visual() or _catch_deformation_surfaces.is_empty():
		return
	_catch_spine_bend_angle_degrees = clampf(total_bend_degrees, 0.0, 150.0)
	_catch_tail_whip_angle_degrees = clampf(tail_whip_degrees, 0.0, 65.0)
	_catch_tail_whip_phase = tail_phase
	_catch_spine_curl_sign = -1.0 if curl_sign < 0.0 else 1.0
	_catch_spine_bend_power = clampf(bend_power, 0.6, 2.5)
	_catch_hook_wriggle_offset_local = Vector3.ZERO
	for surface_data in _catch_deformation_surfaces:
		var material: ShaderMaterial = surface_data["material"]
		material.set_shader_parameter("spine_bend_angle", deg_to_rad(_catch_spine_bend_angle_degrees))
		material.set_shader_parameter("tail_whip_angle", deg_to_rad(_catch_tail_whip_angle_degrees))
		material.set_shader_parameter("tail_wave_phase", _catch_tail_whip_phase)
		material.set_shader_parameter("curl_sign", _catch_spine_curl_sign)
		material.set_shader_parameter("bend_power", _catch_spine_bend_power)
	if not _catch_deformation_surfaces.is_empty():
		var surface_data: Dictionary = _catch_deformation_surfaces[0]
		var tail_center := hanging_spine_centerline(1.0, _catch_spine_bend_angle_degrees, _catch_tail_whip_angle_degrees, _catch_tail_whip_phase, _catch_spine_curl_sign, _catch_spine_bend_power)
		var straight_span := _catch_body_length_m * absf(CATCH_BODY_CURVE_HOOK_U - CATCH_BODY_CURVE_TAIL_U)
		var body_axis: Vector3 = surface_data["body_axis_container"]
		var lateral_axis: Vector3 = surface_data["lateral_axis_container"]
		_catch_tail_wriggle_offset_local = body_axis * ((tail_center.x - 1.0) * straight_span) + lateral_axis * (tail_center.y * straight_span)
	else:
		_catch_tail_wriggle_offset_local = Vector3.ZERO


func get_catch_body_wriggle_probe_offsets() -> Dictionary:
	var points := {}
	var lateral_axis := Vector3.RIGHT
	var body_axis := Vector3.BACK
	if not _catch_deformation_surfaces.is_empty():
		lateral_axis = _catch_deformation_surfaces[0]["lateral_axis_container"]
		body_axis = _catch_deformation_surfaces[0]["body_axis_container"]
	var straight_span := _catch_body_length_m * absf(CATCH_BODY_CURVE_HOOK_U - CATCH_BODY_CURVE_TAIL_U)
	for key in ["front", "main_bend", "tail"]:
		var q := 0.25 if key == "front" else (0.62 if key == "main_bend" else 1.0)
		var center := hanging_spine_centerline(q, _catch_spine_bend_angle_degrees, _catch_tail_whip_angle_degrees, _catch_tail_whip_phase, _catch_spine_curl_sign, _catch_spine_bend_power)
		points[key] = body_axis * ((center.x - q) * straight_span) + lateral_axis * (center.y * straight_span)
	points["head"] = Vector3.ZERO
	points["tail_tangent_angle_degrees"] = hanging_spine_angle(1.0, _catch_spine_bend_angle_degrees, _catch_tail_whip_angle_degrees, _catch_tail_whip_phase, _catch_spine_curl_sign, _catch_spine_bend_power)
	return points


## CPU mirror of the shader's continuous, same-sign spine bend. q=0 is the
## line-pinned mouth and q=1 is the tail. Returned x/y are axial/lateral meters
## for unit body length; the GDScript probe scales them to natural body length.
static func hanging_spine_angle(q: float, body_angle_degrees: float, tail_angle_degrees: float, tail_phase: float, curl_sign: float, bend_power: float) -> float:
	var along := clampf(q, 0.0, 1.0)
	var body_ramp := pow(_smoothstep_range(along, 0.18, 0.82), maxf(bend_power, 0.6))
	var tail_ramp := _smoothstep_range(along, 0.72, 0.97)
	var tail_strike := sin(tail_phase)
	var angle := curl_sign * (body_angle_degrees * body_ramp + tail_angle_degrees * tail_ramp * tail_strike)
	return clampf(angle, -158.0, 158.0)


static func hanging_spine_centerline(q: float, body_angle_degrees: float, tail_angle_degrees: float, tail_phase: float, curl_sign: float, bend_power: float) -> Vector2:
	var steps := 32
	var step_size := clampf(q, 0.0, 1.0) / float(steps)
	var center := Vector2.ZERO
	for index in range(steps):
		var sample_q := (float(index) + 0.5) * step_size
		var angle := deg_to_rad(hanging_spine_angle(sample_q, body_angle_degrees, tail_angle_degrees, tail_phase, curl_sign, bend_power))
		center += Vector2(cos(angle), sin(angle)) * step_size
	return center


static func _smoothstep_range(value: float, edge0: float, edge1: float) -> float:
	var t := clampf((value - edge0) / maxf(edge1 - edge0, 0.0001), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func get_reel_spin_axis_rig_local() -> Vector3:
	return _reel_rotating_assembly.transform.basis * Vector3.UP if _reel_rotating_assembly != null else Vector3.ZERO


## P2's encounter point remains statistical and unchanged. This is only the
## visible lure trailing distance from the hull center.
func get_visual_trailing_distance_from_hull(hull: Node3D) -> float:
	if hull == null or _profile == null:
		return _profile.line_out_length_m if _profile != null else 0.0
	var tip_from_hull := hull.to_local(to_global(get_rod_tip_local()))
	return maxf(0.0, tip_from_hull.z) + _profile.line_out_length_m


func set_catch_visual(profile: FishSpeciesProfile, natural_length_m: float) -> bool:
	clear_catch_visual()
	if profile == null or profile.model_path.is_empty() or natural_length_m <= 0.0:
		return false
	var packed := ResourceLoader.load(profile.model_path) as PackedScene
	if packed == null:
		push_warning("Fishing catch model could not be loaded: %s" % profile.model_path)
		return false
	var source := packed.instantiate() as Node3D
	if source == null:
		push_warning("Fishing catch model root is not Node3D: %s" % profile.model_path)
		return false
	_catch_container = Node3D.new()
	_catch_container.name = "TemporaryCatchVisual"
	_catch_container.visible = false
	add_child(_catch_container)
	_catch_container.add_child(source)
	_catch_body_length_m = natural_length_m
	var bounds := _measure_model_bounds(source)
	if bounds.size.x <= 0.0001:
		push_warning("Fishing catch model has no measurable X-axis body length: %s" % profile.model_path)
		clear_catch_visual()
		return false
	var scale_factor := natural_length_m / bounds.size.x
	# Dragged fish face the boat's bow. Reuse the school renderer's axis mapping
	# so Positive-X and Negative-X GLBs agree with their ecological profiles.
	var orientation := FishSchoolRenderer.basis_for_model_heading(Vector3.FORWARD, profile.model_forward_axis)
	source.basis = orientation
	source.scale = Vector3.ONE * scale_factor
	source.position = -(orientation * bounds.get_center()) * scale_factor
	var mesh_nodes: Array[Node] = []
	if source is MeshInstance3D:
		mesh_nodes.append(source)
	mesh_nodes.append_array(source.find_children("*", "MeshInstance3D", true, false))
	for node in mesh_nodes:
		var mesh_node := node as MeshInstance3D
		if mesh_node == null:
			continue
		mesh_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_prepare_catch_deformation(mesh_node, source, profile.model_forward_axis)
	return true


func set_catch_position_world(position_world: Vector3, roll_radians: float = 0.0, yaw_radians: float = 0.0, pitch_radians: float = 0.0) -> void:
	if _catch_container == null:
		return
	_catch_container.position = to_local(position_world)
	_catch_container.rotation = Vector3(pitch_radians, yaw_radians, roll_radians)


func set_catch_visual_visible(visible: bool) -> void:
	if _catch_container != null:
		_catch_container.visible = visible


func clear_catch_visual() -> void:
	if _catch_container != null and is_instance_valid(_catch_container):
		_catch_container.queue_free()
	_catch_container = null
	_catch_body_length_m = 0.0
	_catch_deformation_surfaces.clear()
	_catch_hook_wriggle_offset_local = Vector3.ZERO
	_catch_tail_wriggle_offset_local = Vector3.ZERO
	_catch_spine_bend_angle_degrees = 0.0
	_catch_tail_whip_angle_degrees = 0.0
	_catch_tail_whip_phase = 0.0
	_catch_spine_curl_sign = 1.0
	_catch_spine_bend_power = 1.0


func _prepare_catch_deformation(mesh_node: MeshInstance3D, source_root: Node3D, model_forward_axis: int) -> void:
	var source_mesh := mesh_node.mesh as ArrayMesh
	if source_mesh == null or source_mesh.get_blend_shape_count() > 0:
		return
	var mesh_to_root := source_root.global_transform.affine_inverse() * mesh_node.global_transform
	var mesh_to_root_basis := mesh_to_root.basis
	var head_at_max_x := model_forward_axis != 1
	var body_axis_mesh := Vector3.LEFT if head_at_max_x else Vector3.RIGHT
	var lateral_axis_mesh := mesh_to_root_basis.inverse() * Vector3.BACK
	if lateral_axis_mesh.length_squared() < 0.0001:
		return
	lateral_axis_mesh = (lateral_axis_mesh - body_axis_mesh * lateral_axis_mesh.dot(body_axis_mesh)).normalized()
	if lateral_axis_mesh.length_squared() < 0.0001:
		var fallback_axis := Vector3.BACK if absf(body_axis_mesh.dot(Vector3.BACK)) < 0.9 else Vector3.UP
		lateral_axis_mesh = (fallback_axis - body_axis_mesh * fallback_axis.dot(body_axis_mesh)).normalized()
	var body_axis_container := (source_root.transform.basis * mesh_to_root_basis * body_axis_mesh).normalized()
	var lateral_axis_container := (source_root.transform.basis * mesh_to_root_basis * lateral_axis_mesh).normalized()
	var vertex_bounds := source_mesh.get_aabb()
	var local_spine_span := vertex_bounds.size.x * absf(CATCH_BODY_CURVE_HOOK_U - CATCH_BODY_CURVE_TAIL_U)
	var bounds_growth := Vector3(absf(lateral_axis_mesh.x), absf(lateral_axis_mesh.y), absf(lateral_axis_mesh.z)) * local_spine_span * 1.05
	bounds_growth += Vector3(absf(body_axis_mesh.x), absf(body_axis_mesh.y), absf(body_axis_mesh.z)) * local_spine_span * 0.12
	vertex_bounds.position -= bounds_growth
	vertex_bounds.size += bounds_growth * 2.0
	mesh_node.custom_aabb = vertex_bounds
	for surface_index in range(source_mesh.get_surface_count()):
		var source_material := source_mesh.surface_get_material(surface_index) as StandardMaterial3D
		var deformation_material := _create_catch_deformation_material(source_material)
		mesh_node.set_surface_override_material(surface_index, deformation_material)
		_catch_deformation_surfaces.append({
			"mesh": source_mesh,
			"mesh_node": mesh_node,
			"surface_index": surface_index,
			"material": deformation_material,
			"min_x": source_mesh.get_aabb().position.x,
			"x_range": maxf(source_mesh.get_aabb().size.x, 0.0001),
			"head_at_max_x": head_at_max_x,
			"body_axis_mesh": body_axis_mesh,
			"body_axis_container": body_axis_container,
			"lateral_axis_mesh": lateral_axis_mesh,
			"lateral_axis_container": lateral_axis_container,
			"body_center_y": source_mesh.get_aabb().get_center().y,
			"body_center_z": source_mesh.get_aabb().get_center().z,
		})
		deformation_material.set_shader_parameter("body_min_x", source_mesh.get_aabb().position.x)
		deformation_material.set_shader_parameter("body_range_x", maxf(source_mesh.get_aabb().size.x, 0.0001))
		deformation_material.set_shader_parameter("head_at_max_x", head_at_max_x)
		deformation_material.set_shader_parameter("body_center_y", source_mesh.get_aabb().get_center().y)
		deformation_material.set_shader_parameter("body_center_z", source_mesh.get_aabb().get_center().z)
		deformation_material.set_shader_parameter("lateral_axis_mesh", lateral_axis_mesh)
		deformation_material.set_shader_parameter("hook_u", CATCH_BODY_CURVE_HOOK_U)
		deformation_material.set_shader_parameter("tail_u", CATCH_BODY_CURVE_TAIL_U)


func _create_catch_deformation_material(source_material: StandardMaterial3D) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = CATCH_DEFORMATION_SHADER
	if source_material == null:
		return material
	material.set_shader_parameter("albedo_color", source_material.albedo_color)
	material.set_shader_parameter("albedo_texture", source_material.albedo_texture)
	material.set_shader_parameter("has_albedo_texture", source_material.albedo_texture != null)
	material.set_shader_parameter("use_vertex_color", source_material.vertex_color_use_as_albedo)
	material.set_shader_parameter("uv_scale", Vector2(source_material.uv1_scale.x, source_material.uv1_scale.y))
	material.set_shader_parameter("uv_offset", Vector2(source_material.uv1_offset.x, source_material.uv1_offset.y))
	material.set_shader_parameter("metallic", source_material.metallic)
	material.set_shader_parameter("metallic_texture", source_material.metallic_texture)
	material.set_shader_parameter("has_metallic_texture", source_material.metallic_texture != null)
	material.set_shader_parameter("metallic_texture_channel", source_material.metallic_texture_channel)
	material.set_shader_parameter("roughness", source_material.roughness)
	material.set_shader_parameter("roughness_texture", source_material.roughness_texture)
	material.set_shader_parameter("has_roughness_texture", source_material.roughness_texture != null)
	material.set_shader_parameter("roughness_texture_channel", source_material.roughness_texture_channel)
	material.set_shader_parameter("metallic_specular", source_material.metallic_specular)
	material.set_shader_parameter("normal_texture", source_material.normal_texture)
	material.set_shader_parameter("has_normal_texture", source_material.normal_texture != null)
	material.set_shader_parameter("normal_scale", source_material.normal_scale)
	return material


func trigger_splash(position_world: Vector3, intensity: float = 1.0) -> void:
	if _splash_ring == null:
		return
	_splash_origin_local = to_local(position_world)
	_splash_ring.position = _splash_origin_local
	_splash_ring.visible = true
	_splash_ring.scale = Vector3.ONE * 0.22
	_splash_strength = clampf(intensity, 0.5, 3.0)
	if _splash_droplets != null:
		_splash_droplets.visible = true
	_splash_elapsed = 0.0


func _process(delta: float) -> void:
	if not is_visible_in_tree() or _profile == null:
		return
	if _presentation_paused:
		return
	var visual_delta := delta * _presentation_time_scale
	_animation_clock += visual_delta
	_smoothed_load = move_toward(_smoothed_load, _target_load, visual_delta * (5.2 if _target_load > _smoothed_load else 1.45))
	_tip_recoil_velocity += -_tip_recoil_displacement * 58.0 * visual_delta
	_tip_recoil_velocity *= exp(-9.0 * visual_delta)
	_tip_recoil_displacement = clampf(_tip_recoil_displacement + _tip_recoil_velocity * visual_delta, -0.08, 0.30)
	_update_rod_and_guides()
	_update_line()
	if _reel_rotating_assembly != null:
		# Local Y follows the shared trolling reel's horizontal drum axle.
		var angular_delta := REEL_ROTATION_SIGN * _reel_spin_speed * visual_delta
		_reel_rotating_assembly.rotate_object_local(Vector3.UP, angular_delta)
	_update_splash(visual_delta)


func _build_visuals() -> void:
	if _profile == null or _rod_instance != null:
		return
	var segment_count := maxi(_profile.rod_segment_count, 8)
	var graphite := StandardMaterial3D.new()
	graphite.albedo_color = Color(0.045, 0.055, 0.064, 1.0)
	graphite.metallic = 0.24
	graphite.roughness = 0.34
	_rod_mesh = CylinderMesh.new()
	_rod_mesh.height = 1.0
	_rod_mesh.top_radius = 0.82
	_rod_mesh.bottom_radius = 1.0
	_rod_mesh.radial_segments = 8
	_rod_multimesh = _make_multimesh(_rod_mesh, segment_count)
	_rod_instance = _make_multimesh_instance("RodSegments", _rod_multimesh, graphite)

	var guide_mesh := TorusMesh.new()
	guide_mesh.outer_radius = 0.026
	guide_mesh.inner_radius = 0.020
	guide_mesh.ring_segments = 12
	guide_mesh.rings = 4
	var guide_material := StandardMaterial3D.new()
	guide_material.albedo_color = Color(0.50, 0.56, 0.58, 1.0)
	guide_material.metallic = 0.78
	guide_material.roughness = 0.30
	_guide_multimesh = _make_multimesh(guide_mesh, _profile.guide_count)
	_guide_instance = _make_multimesh_instance("LineGuides", _guide_multimesh, guide_material)

	var line_mesh := CylinderMesh.new()
	line_mesh.height = 1.0
	# Segment transforms already scale the unit cylinder to LINE_RADIUS_M. Keeping
	# the mesh itself unit-radius avoids accidentally applying the radius twice.
	line_mesh.top_radius = 1.0
	line_mesh.bottom_radius = 1.0
	line_mesh.radial_segments = 5
	_line_multimesh = _make_multimesh(line_mesh, _profile.guide_count + 7)
	_line_material = StandardMaterial3D.new()
	_line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# A fine warm filament reads separately from the dark graphite rod and stays
	# legible over blue water. The radius remains below the rod-tip radius.
	_line_material.albedo_color = Color(1.0, 0.84, 0.48, 1.0)
	_line_material.emission_enabled = true
	_line_material.emission = Color(0.36, 0.20, 0.035, 1.0)
	_line_material.emission_energy_multiplier = 0.28
	_line_material.roughness = 0.52
	# Keep depth testing active so the reel frame and hull occlude the line.
	_line_material.no_depth_test = false
	_line_instance = _make_multimesh_instance("TrollingLine", _line_multimesh, _line_material)
	_line_instance.visible = false

	_build_reel(graphite)
	_build_splash()
	_update_rod_and_guides()


func _make_multimesh(mesh: Mesh, count: int) -> MultiMesh:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = count
	return multimesh


func _make_multimesh_instance(instance_name: String, multimesh: MultiMesh, material: Material) -> MultiMeshInstance3D:
	var instance := MultiMeshInstance3D.new()
	instance.name = instance_name
	instance.multimesh = multimesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)
	return instance


func _build_reel(material: Material) -> void:
	var reel_parts := create_reel_assembly(material, material)
	add_child(reel_parts["root"])
	_reel_rotating_assembly = reel_parts["rotating_assembly"]
	_reel_spool_visual = reel_parts["spool"]
	_reel_winding_visual = reel_parts["winding_visual"]
	set_reel_line_length(0.0)


## Shared procedural reel used by both the hull-mounted trolling rod and the
## handheld Boat Fishing rod. Callers own placement and rotation state.
static func create_reel_assembly(
	body_material: Material,
	rotating_material: Material = null,
	handle_axial_side_sign: float = 1.0,
	stable_handheld_winding_surface: bool = false
) -> Dictionary:
	var moving_material := rotating_material if rotating_material != null else body_material
	var handle_side := -1.0 if handle_axial_side_sign < 0.0 else 1.0
	var root := Node3D.new()
	root.name = "FishingReelAssembly"
	var foot := MeshInstance3D.new()
	foot.name = "ReelSeat"
	var foot_mesh := BoxMesh.new()
	foot_mesh.size = Vector3(0.075, 0.035, 0.13)
	foot.mesh = foot_mesh
	foot.material_override = body_material
	foot.position = Vector3(0.0, 0.025, 0.18)
	root.add_child(foot)
	var frame := Node3D.new()
	frame.name = "ReelFrame"
	root.add_child(frame)
	var side_plate_mesh := CylinderMesh.new()
	side_plate_mesh.top_radius = 0.043
	side_plate_mesh.bottom_radius = 0.043
	side_plate_mesh.height = 0.006
	side_plate_mesh.radial_segments = 20
	for side in [-1.0, 1.0]:
		var side_plate := MeshInstance3D.new()
		side_plate.name = "ReelSidePlate%s" % ("Left" if side < 0.0 else "Right")
		side_plate.mesh = side_plate_mesh
		side_plate.material_override = body_material
		side_plate.position = Vector3(
			REEL_SPOOL_CENTER_LOCAL.x + side * (REEL_SPOOL_AXIAL_WIDTH_M * 0.5 + 0.004),
			REEL_SPOOL_CENTER_LOCAL.y,
			REEL_SPOOL_CENTER_LOCAL.z
		)
		side_plate.rotation.z = PI * 0.5
		side_plate.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		frame.add_child(side_plate)
	var frame_bridge := MeshInstance3D.new()
	frame_bridge.name = "ReelFrameBridge"
	var frame_bridge_mesh := BoxMesh.new()
	frame_bridge_mesh.size = Vector3(0.075, 0.008, 0.012)
	frame_bridge.mesh = frame_bridge_mesh
	frame_bridge.material_override = body_material
	frame_bridge.position = Vector3(REEL_SPOOL_CENTER_LOCAL.x, 0.020, REEL_SPOOL_CENTER_LOCAL.z - 0.005)
	frame_bridge.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	frame.add_child(frame_bridge)
	for side in [-1.0, 1.0]:
		var support := MeshInstance3D.new()
		support.name = "ReelFrameSupport%s" % ("Left" if side < 0.0 else "Right")
		var support_mesh := BoxMesh.new()
		support_mesh.size = Vector3(0.009, 0.036, 0.010)
		support.mesh = support_mesh
		support.material_override = body_material
		support.position = Vector3(REEL_SPOOL_CENTER_LOCAL.x + side * 0.030, 0.038, REEL_SPOOL_CENTER_LOCAL.z)
		support.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		frame.add_child(support)
	var spinner := Node3D.new()
	spinner.name = "ReelSpinningAssembly"
	spinner.position = REEL_SPOOL_CENTER_LOCAL
	spinner.rotation.z = PI * 0.5
	root.add_child(spinner)
	var spool := MeshInstance3D.new()
	spool.name = "ReelSpool"
	var spool_mesh := CylinderMesh.new()
	spool_mesh.top_radius = REEL_SPOOL_CORE_RADIUS_M
	spool_mesh.bottom_radius = REEL_SPOOL_CORE_RADIUS_M
	spool_mesh.height = REEL_SPOOL_AXIAL_WIDTH_M
	spool_mesh.radial_segments = 20
	spool.mesh = spool_mesh
	spool.material_override = body_material
	spinner.add_child(spool)
	var line_material: Material
	var winding_mesh: Mesh
	var winding_instance_count := REEL_WINDING_RING_COUNT
	if stable_handheld_winding_surface:
		var winding_shader := Shader.new()
		winding_shader.code = HANDHELD_WINDING_SHADER_CODE
		var winding_surface_material := ShaderMaterial.new()
		winding_surface_material.shader = winding_shader
		line_material = winding_surface_material
		var winding_cylinder := CylinderMesh.new()
		winding_cylinder.top_radius = REEL_WINDING_BASE_OUTER_RADIUS_M
		winding_cylinder.bottom_radius = REEL_WINDING_BASE_OUTER_RADIUS_M
		winding_cylinder.height = REEL_SPOOL_AXIAL_WIDTH_M * 0.96
		winding_cylinder.radial_segments = 48
		winding_mesh = winding_cylinder
		winding_instance_count = 1
	else:
		var winding_standard_material := StandardMaterial3D.new()
		winding_standard_material.albedo_color = Color(0.56, 0.63, 0.60, 1.0)
		winding_standard_material.metallic = 0.12
		winding_standard_material.roughness = 0.52
		line_material = winding_standard_material
		var winding_torus := TorusMesh.new()
		winding_torus.outer_radius = REEL_WINDING_BASE_OUTER_RADIUS_M
		winding_torus.inner_radius = REEL_WINDING_BASE_OUTER_RADIUS_M - 0.0012
		winding_torus.ring_segments = 5
		winding_torus.rings = 32
		winding_mesh = winding_torus
	var winding_multimesh := MultiMesh.new()
	winding_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	winding_multimesh.mesh = winding_mesh
	winding_multimesh.instance_count = winding_instance_count
	if stable_handheld_winding_surface:
		winding_multimesh.set_instance_transform(0, Transform3D.IDENTITY)
	else:
		for winding_index in range(REEL_WINDING_RING_COUNT):
			var across := float(winding_index) / float(REEL_WINDING_RING_COUNT - 1)
			var y := lerpf(-REEL_SPOOL_AXIAL_WIDTH_M * 0.5, REEL_SPOOL_AXIAL_WIDTH_M * 0.5, across)
			# TorusMesh is generated in the XZ plane, with local Y along its axle.
			# Keep the ring normal on the spool's local Y axis and pack each ring
			# across the drum width.
			winding_multimesh.set_instance_transform(winding_index, Transform3D(Basis.IDENTITY, Vector3(0.0, y, 0.0)))
	winding_multimesh.custom_aabb = AABB(Vector3(-0.043, -0.035, -0.043), Vector3(0.086, 0.070, 0.086))
	var winding := MultiMeshInstance3D.new()
	winding.name = "ReelWoundLine"
	winding.multimesh = winding_multimesh
	winding.material_override = line_material
	winding.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	spinner.add_child(winding)
	# Three spokes on each spool face make the rotation legible from either side.
	# The fixed side plates and supports remain on ReelFrame.
	for side in [-1.0, 1.0]:
		for spoke_index in range(3):
			var spoke := MeshInstance3D.new()
			spoke.name = "ReelSpoke%s%d" % ["L" if side < 0.0 else "R", spoke_index]
			var spoke_mesh := BoxMesh.new()
			spoke_mesh.size = Vector3(0.070, 0.004, 0.005)
			spoke.mesh = spoke_mesh
			spoke.material_override = moving_material
			spoke.position = Vector3(0.0, side * (REEL_SPOOL_AXIAL_WIDTH_M * 0.5 + 0.006), 0.0)
			spoke.rotation.y = TAU * float(spoke_index) / 3.0
			spoke.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			spinner.add_child(spoke)
	var hub := MeshInstance3D.new()
	hub.name = "ReelHub"
	var hub_mesh := CylinderMesh.new()
	hub_mesh.top_radius = 0.014
	hub_mesh.bottom_radius = 0.014
	hub_mesh.height = 0.012
	hub_mesh.radial_segments = 12
	hub.mesh = hub_mesh
	hub.material_override = moving_material
	hub.position.y = handle_side * (REEL_SPOOL_AXIAL_WIDTH_M * 0.5 + 0.006)
	spinner.add_child(hub)
	var handle_arm := MeshInstance3D.new()
	handle_arm.name = "ReelHandleArm"
	var handle_arm_mesh := BoxMesh.new()
	handle_arm_mesh.size = Vector3(0.050, 0.006, 0.007)
	handle_arm.mesh = handle_arm_mesh
	handle_arm.material_override = moving_material
	handle_arm.position = Vector3(0.026, handle_side * (REEL_SPOOL_AXIAL_WIDTH_M * 0.5 + 0.008), 0.0)
	spinner.add_child(handle_arm)
	var reel_handle := MeshInstance3D.new()
	reel_handle.name = "ReelHandleKnob"
	var handle_mesh := CylinderMesh.new()
	handle_mesh.top_radius = 0.0065
	handle_mesh.bottom_radius = 0.0065
	handle_mesh.height = 0.022
	handle_mesh.radial_segments = 8
	reel_handle.mesh = handle_mesh
	reel_handle.material_override = moving_material
	reel_handle.position = Vector3(0.052, handle_side * (REEL_SPOOL_AXIAL_WIDTH_M * 0.5 + 0.008), 0.0)
	spinner.add_child(reel_handle)
	var line_guide := MeshInstance3D.new()
	line_guide.name = "ReelLineGuide"
	var line_guide_mesh := TorusMesh.new()
	line_guide_mesh.outer_radius = 0.0048
	line_guide_mesh.inner_radius = 0.0032
	line_guide_mesh.ring_segments = 8
	line_guide_mesh.rings = 4
	line_guide.mesh = line_guide_mesh
	line_guide.material_override = moving_material
	line_guide.position = get_reel_line_guide_local()
	line_guide.rotation.x = PI * 0.5
	line_guide.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(line_guide)
	return {"root": root, "rotating_assembly": spinner, "spool": spool, "winding_visual": winding, "line_guide": line_guide}


func set_reel_line_length(line_length_m: float) -> float:
	_last_reel_line_length_m = maxf(line_length_m, 0.0) if is_finite(line_length_m) else 0.0
	return set_reel_winding_line_length_on_visual(_reel_winding_visual, _last_reel_line_length_m)


static func get_reel_winding_thickness_m(line_length_m: float) -> float:
	var safe_length := maxf(line_length_m, 0.0) if is_finite(line_length_m) else 0.0
	var progress := clampf(safe_length / REEL_LINE_VISUAL_RANGE_M, 0.0, 1.0)
	return lerpf(REEL_LINE_LAYER_MAX_THICKNESS_M, REEL_LINE_LAYER_MIN_THICKNESS_M, progress)


static func get_reel_spool_outer_radius_m(line_length_m: float) -> float:
	return REEL_SPOOL_CORE_RADIUS_M + get_reel_winding_thickness_m(line_length_m)


static func get_reel_line_exit_local(line_length_m: float) -> Vector3:
	# The drum axis is local X after the pivot's 90-degree Z installation.
	# The shared reel winds counter-clockwise when retrieving, so line pays out
	# from the lower radial tangent on both the trolling and handheld rods.
	var outer_radius := get_reel_spool_outer_radius_m(line_length_m)
	return Vector3(REEL_SPOOL_CENTER_LOCAL.x, REEL_SPOOL_CENTER_LOCAL.y - outer_radius, REEL_SPOOL_CENTER_LOCAL.z)


static func get_reel_line_guide_local() -> Vector3:
	return Vector3(
		REEL_SPOOL_CENTER_LOCAL.x,
		REEL_SPOOL_CENTER_LOCAL.y - REEL_SPOOL_CORE_RADIUS_M - REEL_LINE_LAYER_MAX_THICKNESS_M - 0.006,
		REEL_SPOOL_CENTER_LOCAL.z + 0.018
	)


static func set_reel_winding_line_length_on_visual(winding: MultiMeshInstance3D, line_length_m: float) -> float:
	var thickness := get_reel_winding_thickness_m(line_length_m)
	if winding == null or winding.multimesh == null:
		return thickness
	if winding.has_meta("line_layer_thickness_m"):
		var previous_thickness := float(winding.get_meta("line_layer_thickness_m"))
		if absf(previous_thickness - thickness) <= 0.000025:
			return thickness
	var radial_scale := get_reel_spool_outer_radius_m(line_length_m) / REEL_WINDING_BASE_OUTER_RADIUS_M
	var multimesh := winding.multimesh
	if multimesh.mesh is CylinderMesh:
		var shell_transform := multimesh.get_instance_transform(0)
		shell_transform.basis = Basis(Vector3(radial_scale, 0.0, 0.0), Vector3.UP, Vector3(0.0, 0.0, radial_scale))
		multimesh.set_instance_transform(0, shell_transform)
		winding.set_meta("line_layer_thickness_m", thickness)
		winding.visible = true
		return thickness
	for winding_index in range(multimesh.instance_count):
		var current := multimesh.get_instance_transform(winding_index)
		# TorusMesh's ring plane is XZ, so preserve the Y-axis axle and scale
		# only its two radial axes. Axial width and ring spacing stay fixed.
		current.basis = Basis(Vector3.RIGHT * radial_scale, Vector3.UP, Vector3.BACK * radial_scale)
		multimesh.set_instance_transform(winding_index, current)
	winding.set_meta("line_layer_thickness_m", thickness)
	winding.visible = true
	return thickness


func _build_splash() -> void:
	var torus := TorusMesh.new()
	torus.outer_radius = 0.36
	torus.inner_radius = 0.27
	torus.ring_segments = 16
	torus.rings = 4
	_splash_material = StandardMaterial3D.new()
	_splash_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_splash_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_splash_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_splash_material.albedo_color = Color(0.65, 0.88, 0.94, 0.75)
	_splash_material.no_depth_test = false
	_splash_ring = MeshInstance3D.new()
	_splash_ring.name = "CatchSplashRing"
	_splash_ring.mesh = torus
	_splash_ring.material_override = _splash_material
	_splash_ring.rotation.x = PI * 0.5
	_splash_ring.visible = false
	_splash_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_splash_ring)

	var droplet_mesh := SphereMesh.new()
	droplet_mesh.radius = 0.045
	droplet_mesh.height = 0.09
	droplet_mesh.radial_segments = 8
	droplet_mesh.rings = 4
	_splash_droplet_multimesh = _make_multimesh(droplet_mesh, 8)
	_splash_droplets = _make_multimesh_instance("CatchSplashDroplets", _splash_droplet_multimesh, _splash_material)
	_splash_droplets.visible = false


func _update_rod_and_guides() -> void:
	if _profile == null:
		return
	var segments := _rod_multimesh.instance_count
	for index in range(segments):
		var t0 := float(index) / float(segments)
		var t1 := float(index + 1) / float(segments)
		var start := _rod_point(t0)
		var end := _rod_point(t1)
		var segment_length := start.distance_to(end)
		var midpoint := (start + end) * 0.5
		var radius := lerpf(_profile.rod_root_diameter_m * 0.5, _profile.rod_tip_diameter_m * 0.5, (t0 + t1) * 0.5)
		var basis := _segment_basis(start, end, radius, segment_length * 1.04)
		_rod_multimesh.set_instance_transform(index, Transform3D(basis, midpoint))
	for index in range(_profile.guide_count):
		var t := float(index + 1) / float(_profile.guide_count + 1)
		var point := _rod_point(t)
		var tangent := (_rod_point(minf(t + 0.01, 1.0)) - _rod_point(maxf(t - 0.01, 0.0))).normalized()
		var side := Vector3.RIGHT
		var normal := tangent.cross(side).normalized()
		var guide_basis := Basis(side * 0.026, normal * 0.026, tangent * 0.026)
		_guide_multimesh.set_instance_transform(index, Transform3D(guide_basis, point))


func _update_line() -> void:
	if not _line_active or _line_multimesh == null:
		return
	var points: Array[Vector3] = [
		get_reel_line_exit_local(_last_reel_line_length_m),
		get_reel_line_guide_local(),
	]
	for index in range(_profile.guide_count):
		var t := float(index + 1) / float(_profile.guide_count + 1)
		points.append(_rod_point(t))
	var tip_local := get_rod_tip_local()
	points.append(tip_local)
	if _hanging_line_active:
		var hanging_end_local := to_local(_line_end_world)
		for fraction in [0.18, 0.40, 0.64, 0.86]:
			var bow := sin(PI * fraction)
			var point := tip_local.lerp(hanging_end_local, fraction)
			point.x += 0.012 * bow
			point.y -= 0.012 * bow
			points.append(point)
		points.append(hanging_end_local)
		for index in range(points.size() - 1):
			var start := points[index]
			var finish := points[index + 1]
			var length := start.distance_to(finish)
			var basis := _segment_basis(start, finish, LINE_RADIUS_M, maxf(length, 0.001))
			_line_multimesh.set_instance_transform(index, Transform3D(basis, (start + finish) * 0.5))
		return
	var water_entry_local := to_local(_line_water_entry_world)
	var end_local := to_local(_line_end_world)
	# A tension-controlled curve differentiates the fine line from a rigid rod
	# extension. Three control points keep the silhouette smooth with fixed topology.
	var sag := lerpf(0.20, 0.018, _line_tension)
	for fraction in [0.25, 0.5, 0.75]:
		var bow := sin(PI * fraction)
		var point := tip_local.lerp(water_entry_local, fraction)
		point.y -= sag * bow
		point.x += 0.035 * bow
		points.append(point)
	points.append(water_entry_local)
	points.append(end_local)
	for index in range(points.size() - 1):
		var start := points[index]
		var finish := points[index + 1]
		var length := start.distance_to(finish)
		var basis := _segment_basis(start, finish, LINE_RADIUS_M, maxf(length, 0.001))
		_line_multimesh.set_instance_transform(index, Transform3D(basis, (start + finish) * 0.5))


func _segment_basis(start: Vector3, finish: Vector3, radius: float, length: float) -> Basis:
	var tangent := (finish - start).normalized()
	if tangent.length_squared() < 0.5:
		tangent = Vector3.UP
	var side := Vector3.RIGHT
	if absf(tangent.dot(side)) > 0.94:
		side = Vector3.FORWARD
	var normal := side.cross(tangent).normalized()
	return Basis(side * radius, tangent * maxf(length, 0.001), normal * radius)


func _rod_point(t: float) -> Vector3:
	var clamped_t := clampf(t, 0.0, 1.0)
	if _profile == null:
		return Vector3.ZERO
	var length := _profile.rod_length_m
	var elevation := deg_to_rad(_profile.rod_elevation_degrees)
	var bend := _profile.maximum_hook_bend_m * _smoothed_load
	var ordinary_vibration := sin(_animation_clock * 5.1) * 0.008 * _smoothed_load
	var lateral_vibration := sin(_animation_clock * 3.7 + 0.6) * 0.006 * _smoothed_load
	var bend_shape := pow(clamped_t, 2.15)
	var tip_shape := pow(clamped_t, 2.65)
	var total_bend := clampf(bend * bend_shape + _tip_recoil_displacement * tip_shape, 0.0, _profile.maximum_hook_bend_m)
	var y := sin(elevation) * length * clamped_t - total_bend + ordinary_vibration * bend_shape
	var z := cos(elevation) * length * clamped_t
	return Vector3(lateral_vibration * tip_shape, y, z)


func _measure_model_bounds(root: Node3D) -> AABB:
	var bounds := AABB()
	var found := false
	var nodes: Array[Node] = []
	if root is MeshInstance3D:
		nodes.append(root)
	nodes.append_array(root.find_children("*", "MeshInstance3D", true, false))
	var root_inverse := root.global_transform.affine_inverse()
	for node in nodes:
		var mesh_node := node as MeshInstance3D
		if mesh_node == null or mesh_node.mesh == null:
			continue
		var local_mesh_transform := root_inverse * mesh_node.global_transform
		var mesh_bounds := local_mesh_transform * mesh_node.mesh.get_aabb()
		if not found:
			bounds = mesh_bounds
			found = true
		else:
			bounds = bounds.merge(mesh_bounds)
	return bounds if found else AABB()


func _update_splash(delta: float) -> void:
	if _splash_ring == null or not _splash_ring.visible:
		return
	_splash_elapsed += delta
	var progress := clampf(_splash_elapsed / 0.82, 0.0, 1.0)
	var envelope := sin(progress * PI)
	_splash_ring.scale = Vector3.ONE * lerpf(0.32, 2.35 * _splash_strength, progress)
	var color := _splash_material.albedo_color
	color.a = (1.0 - progress) * minf(0.95, 0.52 + 0.20 * _splash_strength)
	_splash_material.albedo_color = color
	if _splash_droplets != null and _splash_droplet_multimesh != null:
		for index in range(_splash_droplet_multimesh.instance_count):
			var angle := TAU * float(index) / float(_splash_droplet_multimesh.instance_count) + 0.28
			var radius := lerpf(0.12, 0.92 * _splash_strength, progress)
			var height := envelope * (0.32 + float(index % 3) * 0.11) * _splash_strength - progress * 0.12
			var position := _splash_origin_local + Vector3(cos(angle) * radius, height, sin(angle) * radius)
			var scale := (1.0 - progress) * (0.045 + float(index % 2) * 0.014) * _splash_strength
			_splash_droplet_multimesh.set_instance_transform(index, Transform3D(Basis.from_scale(Vector3.ONE * scale), position))
	if progress >= 1.0:
		_splash_ring.visible = false
		if _splash_droplets != null:
			_splash_droplets.visible = false
		color.a = 0.72
		_splash_material.albedo_color = color
