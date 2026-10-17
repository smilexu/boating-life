class_name DolphinVisual
extends Node3D

const SWIM_SHADER := preload("res://shaders/dolphin_swim.gdshader")
const LEAP_TRAJECTORY_SCRIPT := preload("res://scripts/dolphin_leap_trajectory.gd")
const SOURCE_LENGTH_M := 1.1874
const LEAP_GRAVITY_MPS2 := 9.81 * 0.8
const LEAP_START_DEPTH_M := 0.62
const SURFACE_SWIM_CENTER_DEPTH_M := 0.36

@export_range(2.2, 3.0, 0.05) var target_length_m := 2.65
@export_range(0.2, 2.0, 0.05) var swim_frequency := 0.9
@export_range(0.0, 0.12, 0.005) var body_bend := 0.06

var dolphin_id := ""
var _model_root: Node3D
var _swim_material: ShaderMaterial
var _body_half_height_m := 0.0
var _body_bounds_local := AABB()
var _visual_position := Vector3.ZERO
var _visual_basis := Basis.IDENTITY
var _has_position := false
var _has_basis := false
var _animation_time := 0.0
var _phase := 0.0
var _latest_snapshot: Dictionary = {}
var _predicted_age := 0.0
var _smoothed_water_height := 0.0
var _has_water_height := false
var _leap_dive_recovery := false
var _debug_leap_phase := ""
var _debug_leap_elapsed := 0.0
var _debug_leap_vertical_speed := 0.0
var _debug_surface_y := 0.0
var _debug_world_y := 0.0
var _debug_transform_writer := "DolphinVisual.advance_visual"


func configure(dolphin_scene: PackedScene, snapshot: Dictionary, visual_length_m: float, animation_phase: float) -> bool:
	if dolphin_scene == null:
		return false
	dolphin_id = str(snapshot.get("dolphin_id", ""))
	target_length_m = clampf(visual_length_m, 2.2, 3.0)
	_phase = animation_phase
	_model_root = dolphin_scene.instantiate() as Node3D
	if _model_root == null:
		return false
	_model_root.name = "DolphinModel"
	_model_root.rotation.y = -PI * 0.5 # GLB nose faces -X; pivot forward is -Z.
	_model_root.scale = Vector3.ONE * (target_length_m / SOURCE_LENGTH_M)
	add_child(_model_root)
	var mesh_instance := _find_mesh(_model_root)
	if mesh_instance == null:
		push_warning("Dolphin visual has no MeshInstance3D: %s" % dolphin_id)
		return false
	_center_model_on_body()
	var source_material: StandardMaterial3D
	if mesh_instance.mesh != null and mesh_instance.mesh.get_surface_count() > 0:
		source_material = mesh_instance.mesh.surface_get_material(0) as StandardMaterial3D
	if source_material == null:
		source_material = mesh_instance.material_override as StandardMaterial3D
	_swim_material = ShaderMaterial.new()
	_swim_material.shader = SWIM_SHADER
	if source_material != null:
		if source_material.albedo_texture != null:
			_swim_material.set_shader_parameter("albedo_texture", source_material.albedo_texture)
		if source_material.normal_texture != null:
			_swim_material.set_shader_parameter("normal_texture", source_material.normal_texture)
			_swim_material.set_shader_parameter("use_normal_texture", true)
		if source_material.roughness_texture != null:
			_swim_material.set_shader_parameter("roughness_texture", source_material.roughness_texture)
			_swim_material.set_shader_parameter("use_roughness_texture", true)
	mesh_instance.material_override = _swim_material
	_swim_material.set_shader_parameter("swim_frequency", swim_frequency)
	_swim_material.set_shader_parameter("body_bend", body_bend)
	_swim_material.set_shader_parameter("animation_phase", _phase)
	_update_snapshot(snapshot)
	return true


func set_snapshot(snapshot: Dictionary) -> void:
	if str(snapshot.get("dolphin_id", "")) == dolphin_id:
		_update_snapshot(snapshot)


func advance_visual(delta: float, simulation_clock: float, water_height: float) -> void:
	if _latest_snapshot.is_empty():
		return
	_animation_time += delta
	if not _has_water_height:
		_smoothed_water_height = water_height
		_has_water_height = true
	else:
		_smoothed_water_height = lerpf(_smoothed_water_height, water_height, 1.0 - exp(-delta * 2.2))
	_predicted_age = clampf(simulation_clock - float(_latest_snapshot.get("last_updated", simulation_clock)), 0.0, 0.24)
	var position_values: Array = _latest_snapshot.get("world_position", [])
	var direction_values: Array = _latest_snapshot.get("direction", [])
	if position_values.size() < 3 or direction_values.size() < 2:
		return
	var horizontal_direction := Vector2(float(direction_values[0]), float(direction_values[1])).normalized()
	var speed := maxf(0.0, float(_latest_snapshot.get("movement_speed_mps", 0.0)))
	var behavior := str(_latest_snapshot.get("behavior_state", "swim"))
	var depth := maxf(0.0, float(_latest_snapshot.get("activity_depth_m", 3.0)))
	var target_position := Vector3(
		float(position_values[0]) + horizontal_direction.x * speed * _predicted_age,
		_smoothed_water_height - depth,
		float(position_values[2]) + horizontal_direction.y * speed * _predicted_age
	)
	var direction_3d := Vector3(horizontal_direction.x, 0.0, horizontal_direction.y).normalized()
	var target_basis := Basis.looking_at(direction_3d, Vector3.UP)
	var trajectory_velocity := Vector3.ZERO
	_debug_leap_phase = ""
	_debug_leap_elapsed = 0.0
	_debug_leap_vertical_speed = 0.0
	_debug_surface_y = _smoothed_water_height
	if behavior == "surface":
		# The visual root is centered on the body. Keep the body center below
		# the sampled water plane so only the back and dorsal fin emerge.
		target_position.y = _smoothed_water_height - maxf(depth, SURFACE_SWIM_CENTER_DEPTH_M)
	elif behavior == "leap":
		var leap_duration := maxf(0.05, float(_latest_snapshot.get("leap_duration_s", 0.9)))
		var leap_start_time := float(_latest_snapshot.get("leap_started_at", simulation_clock - float(_latest_snapshot.get("state_elapsed", 0.0))))
		var leap_elapsed := clampf(simulation_clock - leap_start_time, 0.0, leap_duration)
		var origin_values: Variant = _latest_snapshot.get("leap_origin_xz", [float(position_values[0]), float(position_values[2])])
		var origin_xz := _array_to_vector2(origin_values, Vector2(float(position_values[0]), float(position_values[2])))
		var leap_direction := _array_to_vector2(_latest_snapshot.get("leap_direction", direction_values), horizontal_direction).normalized()
		var horizontal_speed := maxf(0.1, float(_latest_snapshot.get("leap_horizontal_speed_mps", speed)))
		var horizontal_position: Vector2 = LEAP_TRAJECTORY_SCRIPT.horizontal_position_at(origin_xz, leap_direction, horizontal_speed, leap_elapsed)
		var start_world_y := float(_latest_snapshot.get("leap_start_world_y", _smoothed_water_height - LEAP_START_DEPTH_M))
		var initial_vertical_speed := float(_latest_snapshot.get("leap_initial_velocity_mps", 4.0))
		target_position = Vector3(
			horizontal_position.x,
			LEAP_TRAJECTORY_SCRIPT.height_at(start_world_y, initial_vertical_speed, LEAP_GRAVITY_MPS2, leap_elapsed),
			horizontal_position.y
		)
		var vertical_speed: float = LEAP_TRAJECTORY_SCRIPT.vertical_speed_at(initial_vertical_speed, LEAP_GRAVITY_MPS2, leap_elapsed)
		trajectory_velocity = Vector3(leap_direction.x * horizontal_speed, vertical_speed, leap_direction.y * horizontal_speed)
		direction_3d = trajectory_velocity.normalized()
		target_basis = Basis.looking_at(direction_3d, Vector3.UP)
		_debug_leap_elapsed = leap_elapsed
		_debug_leap_vertical_speed = vertical_speed
		_debug_surface_y = float(_latest_snapshot.get("surface_height_y", _smoothed_water_height))
		var apex_time := initial_vertical_speed / LEAP_GRAVITY_MPS2
		_debug_leap_phase = "上升" if leap_elapsed < apex_time - 0.025 else ("下降" if leap_elapsed > apex_time + 0.025 else "弧顶")
	elif behavior == "diving" and _leap_dive_recovery:
		var dive_elapsed := maxf(0.0, float(_latest_snapshot.get("state_elapsed", 0.0)) + _predicted_age)
		var dive_rate := 0.9
		target_position.y = _smoothed_water_height - minf(depth, 0.08 + dive_elapsed * dive_rate)
		direction_3d.y = -dive_rate / maxf(speed, 2.8)
		target_basis = Basis.looking_at(direction_3d.normalized(), Vector3.UP)
		if dive_elapsed >= 0.8:
			_leap_dive_recovery = false
	if not _has_position:
		_visual_position = target_position
		_has_position = true
	else:
		var position_response := 24.0 if behavior in ["leap", "diving"] else 11.0
		var position_blend := 1.0 - exp(-delta * position_response)
		if behavior == "leap":
			# Leap is an absolute trajectory, not a smoothed target. This prevents
			# the apex and landing from becoming a visually level glide.
			_visual_position = target_position
		else:
			_visual_position = _visual_position.lerp(target_position, position_blend)
	var orientation_response := 18.0 if behavior == "leap" else (9.0 if behavior == "diving" and _leap_dive_recovery else 4.5)
	var orientation_blend := 1.0 - exp(-delta * orientation_response)
	if not _has_basis:
		_visual_basis = target_basis.orthonormalized()
		_has_basis = true
	else:
		_visual_basis = _visual_basis.slerp(target_basis.orthonormalized(), orientation_blend).orthonormalized()
	global_transform = Transform3D(_visual_basis, _visual_position)
	_debug_world_y = global_position.y
	if _swim_material != null:
		_swim_material.set_shader_parameter("swim_time", _animation_time)
		var speed_ratio := clampf(speed / 3.5, 0.6, 1.55)
		_swim_material.set_shader_parameter("swim_frequency", swim_frequency * speed_ratio)


func get_behavior_state() -> String:
	return str(_latest_snapshot.get("behavior_state", "unknown"))


func get_motion_debug() -> Dictionary:
	var body_bounds := get_body_world_y_bounds()
	return {
		"dolphin_id": dolphin_id,
		"behavior": get_behavior_state(),
		"leap_phase": _debug_leap_phase,
		"leap_elapsed": _debug_leap_elapsed,
		"leap_duration": float(_latest_snapshot.get("leap_duration_s", 0.0)),
		"vertical_speed": _debug_leap_vertical_speed,
		"world_y": _debug_world_y,
		"surface_y": _debug_surface_y,
		"height_above_surface": _debug_world_y - _debug_surface_y,
		"body_half_height_m": _body_half_height_m,
		"body_top_height_above_surface": body_bounds.y - _debug_surface_y,
		"body_bottom_height_above_surface": body_bounds.x - _debug_surface_y,
		"transform_writer": _debug_transform_writer,
	}


func get_body_world_y_bounds() -> Vector2:
	if _body_bounds_local.size == Vector3.ZERO:
		return Vector2(global_position.y, global_position.y)
	var minimum_y := INF
	var maximum_y := -INF
	for x in [_body_bounds_local.position.x, _body_bounds_local.end.x]:
		for y in [_body_bounds_local.position.y, _body_bounds_local.end.y]:
			for z in [_body_bounds_local.position.z, _body_bounds_local.end.z]:
				var world_point := global_transform * Vector3(x, y, z)
				minimum_y = minf(minimum_y, world_point.y)
				maximum_y = maxf(maximum_y, world_point.y)
	return Vector2(minimum_y, maximum_y)


func get_body_front_world_point() -> Vector3:
	if _body_bounds_local.size == Vector3.ZERO:
		return global_position
	var forward := -global_basis.z.normalized()
	var leading_point := global_position
	var leading_distance := -INF
	for x in [_body_bounds_local.position.x, _body_bounds_local.end.x]:
		for y in [_body_bounds_local.position.y, _body_bounds_local.end.y]:
			for z in [_body_bounds_local.position.z, _body_bounds_local.end.z]:
				var world_point := global_transform * Vector3(x, y, z)
				var distance := (world_point - global_position).dot(forward)
				if distance > leading_distance:
					leading_distance = distance
					leading_point = world_point
	return leading_point


func _update_snapshot(snapshot: Dictionary) -> void:
	var previous_behavior := str(_latest_snapshot.get("behavior_state", ""))
	var next_behavior := str(snapshot.get("behavior_state", ""))
	if previous_behavior == "leap" and next_behavior == "diving":
		_leap_dive_recovery = true
	elif next_behavior != "diving":
		_leap_dive_recovery = false
	_latest_snapshot = snapshot.duplicate(true)
	if next_behavior == "leap" and previous_behavior != "leap":
		_leap_dive_recovery = false
		_debug_surface_y = float(snapshot.get("surface_height_y", _smoothed_water_height))


func _array_to_vector2(value: Variant, fallback: Vector2) -> Vector2:
	if not value is Array or value.size() < 2:
		return fallback
	return Vector2(float(value[0]), float(value[1]))


func _find_mesh(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node as MeshInstance3D
	for child in node.get_children():
		var found := _find_mesh(child)
		if found != null:
			return found
	return null


func _center_model_on_body() -> void:
	var bounds_state := {"valid": false, "bounds": AABB()}
	_collect_model_bounds(_model_root, Transform3D.IDENTITY, bounds_state)
	if not bool(bounds_state["valid"]):
		return
	var bounds: AABB = bounds_state["bounds"]
	var vertical_center := bounds.position.y + bounds.size.y * 0.5
	_body_bounds_local = bounds
	_body_bounds_local.position.y -= vertical_center
	_model_root.position.y -= vertical_center
	_body_half_height_m = bounds.size.y * 0.5


func _collect_model_bounds(node: Node, parent_transform: Transform3D, state: Dictionary) -> void:
	var relative_transform := parent_transform
	if node is Node3D:
		relative_transform = parent_transform * (node as Node3D).transform
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh != null:
			var transformed_bounds := _transform_aabb(mesh_instance.get_aabb(), relative_transform)
			if not bool(state["valid"]):
				state["bounds"] = transformed_bounds
				state["valid"] = true
			else:
				var existing_bounds: AABB = state["bounds"]
				state["bounds"] = existing_bounds.merge(transformed_bounds)
	for child in node.get_children():
		_collect_model_bounds(child, relative_transform, state)


func _transform_aabb(bounds: AABB, transform: Transform3D) -> AABB:
	var first := transform * bounds.position
	var result := AABB(first, Vector3.ZERO)
	for x in [bounds.position.x, bounds.end.x]:
		for y in [bounds.position.y, bounds.end.y]:
			for z in [bounds.position.z, bounds.end.z]:
				result = result.expand(transform * Vector3(x, y, z))
	return result
