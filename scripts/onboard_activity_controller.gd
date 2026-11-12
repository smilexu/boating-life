class_name OnboardActivityController
extends Node3D

## Hull-local first-person movement for configured deck activities. It does not
## own an activity state machine beyond activation and never depends on fishing.

signal activity_ended

# Dedicated layer 6; later cast/interaction queries should omit this bit.
const PLAYER_COLLISION_LAYER := 1 << 5
const GRAVITY_FALLBACK_MPS2 := 9.8
const MAX_WALK_SPEED_MPS := 4.0
const PRESENTATION_PITCH_TRACK_RESPONSE := 7.0

@export var profile: OnboardActivityProfile
@export_node_path("Node") var boat_controller_path := NodePath("../..")

var _boat_controller: BoatController
var _player: CharacterBody3D
var _player_camera: Camera3D
var _head_pivot: Node3D
var _deck_proxy: AnimatableBody3D
var _debug_boundary_nodes: Array[MeshInstance3D] = []
var _activity_active := false
var _first_person_active := false
var _movement_locked := false
var _grounded := false
var _spawned_once := false
var _player_local_position := Vector3.ZERO
var _player_local_yaw := 0.0
var _look_pitch := 0.0
var _fight_view_constraint_active := false
var _fight_view_yaw_base := 0.0
var _fight_view_yaw_half_range_rad := 0.0
var _fight_view_pitch_min_rad := -deg_to_rad(55.0)
var _fight_view_pitch_max_rad := deg_to_rad(35.0)
var _fishing_rod_view_pitch_constraint_active := false
var _fishing_rod_view_pitch_min_rad := -deg_to_rad(65.0)
var _fishing_rod_view_pitch_max_rad := deg_to_rad(35.0)
var _fight_presentation_tracking_active := false
var _fight_presentation_pitch_target_rad := 0.0
var _fight_presentation_pitch_offset_rad := 0.0
var _fight_presentation_pitch_manual_range_rad := deg_to_rad(8.0)
var _fight_presentation_has_pitch_target := false
var _jump_action_was_pressed := false
var _movement_lock_position := Vector3.ZERO
var _walkable_polygon_signed_area := 0.0


func _ready() -> void:
	_boat_controller = get_node_or_null(boat_controller_path) as BoatController
	_walkable_polygon_signed_area = _get_walkable_polygon_signed_area()
	_build_deck_collision()
	_build_player()
	set_physics_process(false)


func is_supported() -> bool:
	return (
		profile != null
		and _boat_controller != null
		and not _boat_controller.is_sailing_active()
		and _has_valid_walkable_area()
	)


func is_activity_active() -> bool:
	return _activity_active


func is_first_person_active() -> bool:
	return _first_person_active


func is_movement_locked() -> bool:
	return _movement_locked


func is_player_grounded() -> bool:
	return _grounded


func is_player_inside_walkable_area() -> bool:
	return _player != null and _is_position_inside_walkable_area(_player.position)


func begin_activity() -> bool:
	if not is_supported():
		return false
	if _activity_active:
		return true
	end_fishing_fight_view()
	if not _spawned_once:
		_player_local_position = profile.safe_spawn_position
		_player_local_yaw = 0.0
		_look_pitch = 0.0
		_head_pivot.rotation.x = 0.0
		_spawned_once = true
	_grounded = _player_local_position.y <= profile.deck_height_m + 0.02
	_activity_active = true
	_set_player_transform_from_hull()
	_set_deck_collision_active(true)
	_set_player_collision_enabled(true)
	_player.set_physics_process(true)
	set_physics_process(true)
	return true


func end_activity() -> void:
	if not _activity_active:
		return
	_activity_active = false
	_fishing_rod_view_pitch_constraint_active = false
	end_fishing_fight_view()
	set_debug_bounds_visible(false)
	_movement_locked = false
	set_first_person_active(false)
	activity_ended.emit()
	# Returning to the driving view while airborne must not leave a hidden
	# CharacterBody falling through the hull. End on the configured deck plane.
	if not _grounded:
		_player_local_position.y = profile.deck_height_m
		_player.position = _player_local_position
		_player.velocity = Vector3.ZERO
		_grounded = true
	_set_player_collision_enabled(false)
	_set_deck_collision_active(false)
	_player.set_physics_process(false)
	set_physics_process(false)


func set_first_person_active(active: bool) -> bool:
	if active and (not _activity_active or not is_supported()):
		return false
	if _first_person_active == active:
		return true
	_first_person_active = active
	if _boat_controller != null:
		_boat_controller.set_onboard_activity_input_suppressed(active)
	if active:
		_player_camera.make_current()
	else:
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		_player_camera.current = false
	return true


func set_movement_locked(locked: bool) -> void:
	if locked == _movement_locked:
		return
	_movement_locked = locked
	if locked and _player != null:
		# A cast can begin during the last few frames of a jump. Settle at the
		# same hull-local footprint before locking so the player cannot hang in
		# mid-air while gravity is disabled by the lock.
		_movement_lock_position = _constrain_player_local_position(_player.position, _player_local_position)
		_movement_lock_position.y = profile.deck_height_m if profile != null else _movement_lock_position.y
		_player.position = _movement_lock_position
		_player_local_position = _movement_lock_position
		_player.velocity = Vector3.ZERO
		_grounded = true


func apply_mouse_look(relative: Vector2) -> void:
	if not _first_person_active or profile == null:
		return
	var yaw_delta := -relative.x * profile.mouse_sensitivity * 0.01
	if _fight_view_constraint_active:
		var yaw_offset := wrapf(_player_local_yaw + yaw_delta - _fight_view_yaw_base, -PI, PI)
		_player_local_yaw = _fight_view_yaw_base + clampf(yaw_offset, -_fight_view_yaw_half_range_rad, _fight_view_yaw_half_range_rad)
	else:
		_player_local_yaw += yaw_delta
	var pitch_delta := -relative.y * profile.mouse_sensitivity * 0.01
	if _fight_view_constraint_active and _fight_presentation_tracking_active:
		_fight_presentation_pitch_offset_rad = clampf(
			_fight_presentation_pitch_offset_rad + pitch_delta,
			-_fight_presentation_pitch_manual_range_rad,
			_fight_presentation_pitch_manual_range_rad
		)
		_look_pitch = clampf(
			_fight_presentation_pitch_target_rad + _fight_presentation_pitch_offset_rad,
			_fight_view_pitch_min_rad,
			_fight_view_pitch_max_rad
		)
	else:
		var pitch_min := -deg_to_rad(profile.pitch_limit_degrees)
		var pitch_max := deg_to_rad(profile.pitch_limit_degrees)
		if _fight_view_constraint_active:
			pitch_min = _fight_view_pitch_min_rad
			pitch_max = _fight_view_pitch_max_rad
		elif _fishing_rod_view_pitch_constraint_active:
			pitch_min = _fishing_rod_view_pitch_min_rad
			pitch_max = _fishing_rod_view_pitch_max_rad
		_look_pitch = clampf(_look_pitch + pitch_delta, pitch_min, pitch_max)
	_head_pivot.rotation.x = _look_pitch
	_set_player_transform_from_hull()


func set_fishing_rod_view_pitch_constraint(active: bool, minimum_degrees: float, maximum_degrees: float) -> void:
	_fishing_rod_view_pitch_constraint_active = active
	_fishing_rod_view_pitch_min_rad = deg_to_rad(minf(minimum_degrees, maximum_degrees))
	_fishing_rod_view_pitch_max_rad = deg_to_rad(maxf(minimum_degrees, maximum_degrees))
	if active and not _fight_view_constraint_active:
		_look_pitch = clampf(_look_pitch, _fishing_rod_view_pitch_min_rad, _fishing_rod_view_pitch_max_rad)
		if _head_pivot != null:
			_head_pivot.rotation.x = _look_pitch
		_set_player_transform_from_hull()


func begin_fishing_fight_view(
	yaw_half_range_degrees: float,
	pitch_min_degrees: float,
	pitch_max_degrees: float,
	presentation_pitch_manual_range_degrees: float
) -> void:
	if _fight_view_constraint_active:
		return
	_fight_view_constraint_active = true
	_fight_view_yaw_base = _player_local_yaw
	_fight_view_yaw_half_range_rad = deg_to_rad(maxf(0.0, yaw_half_range_degrees))
	_fight_view_pitch_min_rad = deg_to_rad(minf(pitch_min_degrees, pitch_max_degrees))
	_fight_view_pitch_max_rad = deg_to_rad(maxf(pitch_min_degrees, pitch_max_degrees))
	_fight_presentation_pitch_manual_range_rad = deg_to_rad(maxf(0.0, presentation_pitch_manual_range_degrees))
	_fight_presentation_pitch_offset_rad = 0.0
	_fight_presentation_tracking_active = false
	_fight_presentation_has_pitch_target = false
	_look_pitch = clampf(_look_pitch, _fight_view_pitch_min_rad, _fight_view_pitch_max_rad)
	_head_pivot.rotation.x = _look_pitch
	_set_player_transform_from_hull()


func set_fishing_presentation_tracking(active: bool) -> void:
	if not _fight_view_constraint_active or active == _fight_presentation_tracking_active:
		return
	_fight_presentation_tracking_active = active
	_fight_presentation_pitch_offset_rad = 0.0
	_fight_presentation_has_pitch_target = false
	_fight_presentation_pitch_target_rad = _look_pitch


func update_fishing_presentation_focus(world_positions: Array, delta: float) -> void:
	if not _fight_view_constraint_active or not _fight_presentation_tracking_active or _player == null or world_positions.is_empty():
		return
	var eye_height := profile.eye_height_m if profile != null else 1.55
	var camera_origin_local := _player.to_local(_player_camera.global_position) if _player_camera != null else Vector3(0.0, eye_height, 0.0)
	var minimum_pitch := INF
	var maximum_pitch := -INF
	for world_position_variant in world_positions:
		if not (world_position_variant is Vector3):
			continue
		var world_position: Vector3 = world_position_variant
		if not world_position.is_finite():
			continue
		var direction_local := _player.to_local(world_position) - camera_origin_local
		# Measure elevation against the view's horizontal forward axis. Radial
		# XZ distance would under-pitch a target that is far to either side.
		var forward_distance := -direction_local.z
		if forward_distance <= 0.05:
			# A hooked fish can move behind the fight-start heading. It cannot be
			# centered by pitch alone, but retain a stable elevation target while
			# the player turns within the bounded yaw range.
			forward_distance = Vector2(direction_local.x, direction_local.z).length()
		var target_pitch := atan2(direction_local.y, forward_distance)
		minimum_pitch = minf(minimum_pitch, target_pitch)
		maximum_pitch = maxf(maximum_pitch, target_pitch)
	if not is_finite(minimum_pitch) or not is_finite(maximum_pitch):
		return
	var target_center_pitch := clampf(
		(minimum_pitch + maximum_pitch) * 0.5,
		_fight_view_pitch_min_rad,
		_fight_view_pitch_max_rad
	)
	if not _fight_presentation_has_pitch_target:
		_fight_presentation_pitch_target_rad = target_center_pitch
		_fight_presentation_has_pitch_target = true
	else:
		var target_blend := 1.0 - exp(-PRESENTATION_PITCH_TRACK_RESPONSE * maxf(delta, 0.0))
		_fight_presentation_pitch_target_rad = lerpf(_fight_presentation_pitch_target_rad, target_center_pitch, target_blend)
	var desired_pitch := clampf(
		_fight_presentation_pitch_target_rad + _fight_presentation_pitch_offset_rad,
		_fight_view_pitch_min_rad,
		_fight_view_pitch_max_rad
	)
	var pitch_blend := 1.0 - exp(-PRESENTATION_PITCH_TRACK_RESPONSE * maxf(delta, 0.0))
	_look_pitch = lerpf(_look_pitch, desired_pitch, pitch_blend)
	_head_pivot.rotation.x = _look_pitch


func end_fishing_fight_view() -> void:
	_fight_view_constraint_active = false
	_fight_presentation_tracking_active = false
	_fight_presentation_has_pitch_target = false
	_fight_presentation_pitch_offset_rad = 0.0


func is_fishing_fight_view_active() -> bool:
	return _fight_view_constraint_active


func set_debug_bounds_visible(visible: bool) -> void:
	var should_show := visible and _activity_active and OS.is_debug_build()
	if should_show and _debug_boundary_nodes.is_empty():
		_build_debug_boundaries()
	for boundary in _debug_boundary_nodes:
		if is_instance_valid(boundary):
			boundary.visible = should_show


func get_debug_snapshot() -> Dictionary:
	return {
		"supported": is_supported(),
		"activity_active": _activity_active,
		"first_person_active": _first_person_active,
		"movement_locked": _movement_locked,
		"player_local_position": get_player_local_position(),
		"fishing_rod_view_pitch_constraint_active": _fishing_rod_view_pitch_constraint_active,
		"fishing_rod_view_pitch_degrees": rad_to_deg(_look_pitch),
		"fishing_rod_view_pitch_min_degrees": rad_to_deg(_fishing_rod_view_pitch_min_rad),
		"fishing_rod_view_pitch_max_degrees": rad_to_deg(_fishing_rod_view_pitch_max_rad),
		"fishing_fight_view_active": _fight_view_constraint_active,
		"fishing_fight_yaw_base_degrees": rad_to_deg(_fight_view_yaw_base),
		"fishing_fight_yaw_offset_degrees": rad_to_deg(wrapf(_player_local_yaw - _fight_view_yaw_base, -PI, PI)) if _fight_view_constraint_active else 0.0,
		"fishing_fight_yaw_half_range_degrees": rad_to_deg(_fight_view_yaw_half_range_rad),
		"fishing_fight_pitch_degrees": rad_to_deg(_look_pitch),
		"fishing_presentation_tracking_active": _fight_presentation_tracking_active,
		"fishing_presentation_pitch_target_valid": _fight_presentation_has_pitch_target,
		"fishing_presentation_pitch_target_degrees": rad_to_deg(_fight_presentation_pitch_target_rad),
		"grounded": _grounded,
		"inside_walkable_area": is_player_inside_walkable_area(),
		"walkable_area_polygon_count": 1 if profile != null and profile.walkable_polygon_xz.size() >= 3 else 0,
	}


func get_player_local_position() -> Vector3:
	if _player == null:
		return _player_local_position
	return _player.position


func get_player_local_yaw() -> float:
	return _player_local_yaw


func get_camera_pitch() -> float:
	return _look_pitch


func get_activity_camera() -> Camera3D:
	return _player_camera


func _physics_process(delta: float) -> void:
	if _player == null or profile == null:
		return
	var up := _player.global_basis.y.normalized()
	if up.length_squared() < 0.5:
		up = Vector3.UP
	_player.up_direction = up
	var local_position_before_motion := _player_local_position
	var vertical_speed := _player.velocity.dot(up)
	if _movement_locked:
		_player.position = _movement_lock_position
		_player_local_position = _movement_lock_position
		_player.velocity = Vector3.ZERO
		_grounded = true
		return
	if _grounded and vertical_speed < 0.0:
		vertical_speed = 0.0
	var movement_allowed := _activity_active and _first_person_active and not _movement_locked
	var horizontal_velocity := Vector3.ZERO
	var input_vector := Vector2.ZERO
	var jump_pressed := Input.is_action_pressed("boat_pause")
	var jump_just_pressed := jump_pressed and not _jump_action_was_pressed
	_jump_action_was_pressed = jump_pressed
	if movement_allowed:
		input_vector = Input.get_vector("boat_turn_left", "boat_turn_right", "boat_accelerate", "boat_brake")
		var forward := -_player.global_basis.z
		var right := _player.global_basis.x
		var direction := right * input_vector.x + forward * -input_vector.y
		if direction.length_squared() > 1.0:
			direction = direction.normalized()
		horizontal_velocity = direction * minf(profile.move_speed_mps, MAX_WALK_SPEED_MPS)
		if jump_just_pressed and _grounded:
			vertical_speed = sqrt(2.0 * _get_gravity() * profile.jump_height_m)
	vertical_speed -= _get_gravity() * delta
	_player.velocity = horizontal_velocity + up * vertical_speed
	_player.move_and_slide()
	var moved_local_position := _player.position
	if input_vector.is_zero_approx():
		# CharacterBody3D can receive a small platform correction while its
		# AnimatableBody deck proxy is being synchronized. With no player input,
		# keep horizontal pose in the hull frame and retain only collision-resolved
		# vertical movement (jump/fall/landing).
		moved_local_position.x = local_position_before_motion.x
		moved_local_position.z = local_position_before_motion.z
	moved_local_position = _constrain_player_local_position(moved_local_position, local_position_before_motion)
	if moved_local_position.y <= profile.deck_height_m + 0.02 and vertical_speed <= 0.0:
		moved_local_position.y = profile.deck_height_m
		_player.velocity = up * 0.0
		_grounded = true
	else:
		_grounded = false
	_player.position = moved_local_position
	_player_local_position = moved_local_position


func _get_gravity() -> float:
	return profile.gravity_mps2 if profile != null else GRAVITY_FALLBACK_MPS2


func _set_player_transform_from_hull() -> void:
	if _player == null:
		return
	_player_local_position = _constrain_player_local_position(_player_local_position, profile.safe_spawn_position if profile != null else Vector3.ZERO)
	_player.position = _player_local_position
	_player.rotation = Vector3(0.0, _player_local_yaw, 0.0)


func _build_player() -> void:
	_player = CharacterBody3D.new()
	_player.name = "OnboardActivityPlayer"
	_player.collision_layer = 0
	_player.collision_mask = PLAYER_COLLISION_LAYER
	_player.motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	_player.floor_snap_length = 0.16
	_player.floor_max_angle = deg_to_rad(55.0)
	# The player is already parented to the animated hull. Prevent Godot from
	# applying the same deck platform velocity a second time in move_and_slide().
	_player.platform_floor_layers = 0
	_player.safe_margin = 0.002
	_player.set_physics_process(false)
	add_child(_player)
	var shape_node := CollisionShape3D.new()
	shape_node.name = "PlayerCapsule"
	var capsule := CapsuleShape3D.new()
	capsule.radius = profile.capsule_radius_m if profile != null else 0.28
	capsule.height = profile.capsule_height_m if profile != null else 1.68
	shape_node.shape = capsule
	shape_node.position.y = capsule.height * 0.5
	_player.add_child(shape_node)
	_head_pivot = Node3D.new()
	_head_pivot.name = "HeadPivot"
	_head_pivot.position.y = profile.eye_height_m if profile != null else 1.55
	_player.add_child(_head_pivot)
	_player_camera = Camera3D.new()
	_player_camera.name = "OnboardActivityCamera"
	_player_camera.current = false
	_player_camera.fov = profile.first_person_fov_degrees if profile != null else 76.0
	_player_camera.near = 0.08
	_player_camera.far = 12000.0
	_head_pivot.add_child(_player_camera)


func _build_deck_collision() -> void:
	if profile == null or profile.walkable_polygon_xz.size() < 3:
		return
	_deck_proxy = AnimatableBody3D.new()
	_deck_proxy.name = "OnboardActivityCollisionProxy"
	_deck_proxy.sync_to_physics = false
	_deck_proxy.collision_layer = 0
	_deck_proxy.collision_mask = 0
	add_child(_deck_proxy)
	_add_deck_floor_collision()
	for index in range(profile.walkable_polygon_xz.size()):
		var start := profile.walkable_polygon_xz[index]
		var finish := profile.walkable_polygon_xz[(index + 1) % profile.walkable_polygon_xz.size()]
		_add_boundary_collision(index, start, finish)


func _add_deck_floor_collision() -> void:
	var points := PackedVector3Array()
	var bottom_y := profile.deck_height_m - profile.deck_collision_thickness_m
	for point in profile.walkable_polygon_xz:
		points.append(Vector3(point.x, bottom_y, point.y))
		points.append(Vector3(point.x, profile.deck_height_m, point.y))
	var shape := ConvexPolygonShape3D.new()
	shape.points = points
	var shape_node := CollisionShape3D.new()
	shape_node.name = "WalkableDeckFloor"
	shape_node.shape = shape
	_deck_proxy.add_child(shape_node)


func _add_boundary_collision(index: int, start: Vector2, finish: Vector2) -> void:
	var edge := finish - start
	var length := edge.length()
	if length <= 0.01:
		return
	var thickness := profile.boundary_thickness_m
	var wall_height := maxf(profile.boundary_height_m, profile.jump_height_m + 0.25)
	var center_xz := (start + finish) * 0.5
	var wall_center := Vector3(center_xz.x, profile.deck_height_m + wall_height * 0.5, center_xz.y)
	var wall_rotation_y := atan2(-edge.y, edge.x)
	var wall_size := Vector3(length + thickness, wall_height, thickness)
	var shape_node := CollisionShape3D.new()
	shape_node.name = "WalkableBoundary_%02d" % index
	var shape := BoxShape3D.new()
	shape.size = wall_size
	shape_node.shape = shape
	shape_node.position = wall_center
	shape_node.rotation.y = wall_rotation_y
	_deck_proxy.add_child(shape_node)


func _build_debug_boundaries() -> void:
	if profile == null or profile.walkable_polygon_xz.size() < 3:
		return
	_add_debug_walkable_surface()
	_add_debug_boundary_wireframe()
	_add_debug_player_capsule()
	for boundary in _debug_boundary_nodes:
		boundary.visible = true


func _add_debug_walkable_surface() -> void:
	var triangle_indices := Geometry2D.triangulate_polygon(profile.walkable_polygon_xz)
	if triangle_indices.is_empty():
		return
	var vertices := PackedVector3Array()
	for triangle_index in triangle_indices:
		var point: Vector2 = profile.walkable_polygon_xz[triangle_index]
		vertices.append(Vector3(point.x, profile.deck_height_m + 0.025, point.y))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var polygon_mesh := ArrayMesh.new()
	polygon_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "OnboardActivityDebugWalkableArea"
	mesh_instance.mesh = polygon_mesh
	mesh_instance.material_override = _make_debug_material(Color(0.12, 0.86, 0.48, 0.12))
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mesh_instance)
	_debug_boundary_nodes.append(mesh_instance)


func _add_debug_boundary_wireframe() -> void:
	var wall_height := maxf(profile.boundary_height_m, profile.jump_height_m + 0.25)
	var bottom_y := profile.deck_height_m + 0.01
	var top_y := bottom_y + wall_height
	var material := _make_debug_material(Color(1.0, 0.22, 0.12, 0.95))
	var line_mesh := ImmediateMesh.new()
	line_mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	for index in range(profile.walkable_polygon_xz.size()):
		var start := profile.walkable_polygon_xz[index]
		var finish := profile.walkable_polygon_xz[(index + 1) % profile.walkable_polygon_xz.size()]
		line_mesh.surface_add_vertex(Vector3(start.x, bottom_y, start.y))
		line_mesh.surface_add_vertex(Vector3(finish.x, bottom_y, finish.y))
		line_mesh.surface_add_vertex(Vector3(start.x, top_y, start.y))
		line_mesh.surface_add_vertex(Vector3(finish.x, top_y, finish.y))
		line_mesh.surface_add_vertex(Vector3(start.x, bottom_y, start.y))
		line_mesh.surface_add_vertex(Vector3(start.x, top_y, start.y))
	line_mesh.surface_end()
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "OnboardActivityDebugForbiddenBoundary"
	mesh_instance.mesh = line_mesh
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mesh_instance)
	_debug_boundary_nodes.append(mesh_instance)


func _add_debug_player_capsule() -> void:
	if _player == null:
		return
	var wire_mesh := ImmediateMesh.new()
	var material := _make_debug_material(Color(0.18, 0.74, 1.0, 0.95))
	wire_mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	var ring_levels: Array[Vector2] = []
	var radius := profile.capsule_radius_m
	var height := profile.capsule_height_m
	for step in range(5):
		var angle := -PI * 0.5 + float(step) * PI * 0.125
		var y := radius + radius * sin(angle)
		ring_levels.append(Vector2(y, maxf(0.0, radius * cos(angle))))
	ring_levels.append(Vector2(height - radius, radius))
	for step in range(1, 5):
		var angle := float(step) * PI * 0.125
		var y := height - radius + radius * sin(angle)
		ring_levels.append(Vector2(y, maxf(0.0, radius * cos(angle))))
	const RING_SEGMENTS := 12
	var rings: Array[PackedVector3Array] = []
	for level in ring_levels:
		var ring := PackedVector3Array()
		for segment in range(RING_SEGMENTS):
			var angle := TAU * float(segment) / float(RING_SEGMENTS)
			ring.append(Vector3(cos(angle) * level.y, level.x, sin(angle) * level.y))
		for segment in range(RING_SEGMENTS):
			wire_mesh.surface_add_vertex(ring[segment])
			wire_mesh.surface_add_vertex(ring[(segment + 1) % RING_SEGMENTS])
		rings.append(ring)
	for level_index in range(rings.size() - 1):
		for segment in range(0, RING_SEGMENTS, 3):
			wire_mesh.surface_add_vertex(rings[level_index][segment])
			wire_mesh.surface_add_vertex(rings[level_index + 1][segment])
	wire_mesh.surface_end()
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "OnboardActivityDebugPlayerCapsule"
	mesh_instance.mesh = wire_mesh
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_player.add_child(mesh_instance)
	_debug_boundary_nodes.append(mesh_instance)


func _make_debug_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


func _is_position_inside_walkable_area(local_position: Vector3) -> bool:
	if profile == null or profile.walkable_polygon_xz.size() < 3:
		return false
	var point := Vector2(local_position.x, local_position.z)
	if not Geometry2D.is_point_in_polygon(point, profile.walkable_polygon_xz):
		return false
	var required_clearance := profile.capsule_radius_m + profile.boundary_thickness_m * 0.5 - 0.025
	for index in range(profile.walkable_polygon_xz.size()):
		var start := profile.walkable_polygon_xz[index]
		var finish := profile.walkable_polygon_xz[(index + 1) % profile.walkable_polygon_xz.size()]
		var nearest := Geometry2D.get_closest_point_to_segment(point, start, finish)
		if point.distance_to(nearest) < required_clearance:
			return false
	return true


func _constrain_player_local_position(candidate: Vector3, fallback: Vector3) -> Vector3:
	if profile == null or profile.walkable_polygon_xz.size() < 3 or absf(_walkable_polygon_signed_area) < 0.01:
		return Vector3(profile.safe_spawn_position.x, candidate.y, profile.safe_spawn_position.z) if profile != null else fallback
	var point := Vector2(candidate.x, candidate.z)
	var required_clearance := maxf(0.0, profile.capsule_radius_m + profile.boundary_thickness_m * 0.5 - 0.025)
	var orientation := 1.0 if _walkable_polygon_signed_area >= 0.0 else -1.0
	# The authored walkable polygon is convex. Project against each inset edge
	# plane so the capsule remains inside even if a moving hull or fast step
	# outruns the physics boundary for a frame. This slides toward the nearest
	# safe point instead of resetting the player to the spawn point.
	for _pass in range(8):
		var moved := false
		for index in range(profile.walkable_polygon_xz.size()):
			var start := profile.walkable_polygon_xz[index]
			var finish := profile.walkable_polygon_xz[(index + 1) % profile.walkable_polygon_xz.size()]
			var edge := finish - start
			if edge.length_squared() <= 0.0001:
				continue
			var inward := Vector2(-edge.y, edge.x).normalized() * orientation
			var signed_distance := (point - start).dot(inward)
			if signed_distance < required_clearance:
				point += inward * (required_clearance - signed_distance + 0.0005)
				moved = true
		if not moved:
			break
	var constrained := Vector3(point.x, candidate.y, point.y)
	if _is_position_inside_walkable_area(constrained):
		return constrained
	if _is_position_inside_walkable_area(fallback):
		return Vector3(fallback.x, candidate.y, fallback.z)
	var safe_spawn := profile.safe_spawn_position
	return Vector3(safe_spawn.x, candidate.y, safe_spawn.z)


func _get_walkable_polygon_signed_area() -> float:
	if profile == null or profile.walkable_polygon_xz.size() < 3:
		return 0.0
	var twice_area := 0.0
	for index in range(profile.walkable_polygon_xz.size()):
		var current := profile.walkable_polygon_xz[index]
		var next := profile.walkable_polygon_xz[(index + 1) % profile.walkable_polygon_xz.size()]
		twice_area += current.x * next.y - next.x * current.y
	return twice_area * 0.5


func _has_valid_walkable_area() -> bool:
	if profile == null or profile.walkable_polygon_xz.size() < 3 or absf(_walkable_polygon_signed_area) < 0.01:
		return false
	return _is_position_inside_walkable_area(profile.safe_spawn_position)


func _set_player_collision_enabled(enabled: bool) -> void:
	if _player == null:
		return
	_player.collision_layer = 0
	_player.collision_mask = PLAYER_COLLISION_LAYER if enabled else 0


func _set_deck_collision_active(active: bool) -> void:
	if _deck_proxy == null:
		return
	_deck_proxy.collision_layer = PLAYER_COLLISION_LAYER if active else 0
	_deck_proxy.sync_to_physics = active
