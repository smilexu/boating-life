class_name BoatFollowCamera
extends Node3D

## Existing smooth follow/God camera. During a catch the same Camera3D can
## temporarily use a hull-local Fight Camera anchor in the O-key cycle.

enum CameraMode { FOLLOW, GOD, FIGHT_CAMERA }
const NORMAL_FOV := 58.0

@export_node_path("Node3D") var target_path := NodePath("../MotionRoot")
@export_range(4.0, 18.0, 0.5) var follow_distance := 14.0
@export_range(14.0, 24.0, 0.5) var sailing_follow_distance := 18.0
@export_range(0.5, 4.0, 0.1) var zoom_step_m := 1.5
@export_range(18.0, 50.0, 1.0) var maximum_follow_distance := 36.0
@export_range(16.0, 60.0, 1.0) var god_view_distance := 60.0
@export_range(1.0, 8.0, 0.1) var follow_smoothing := 5.5
@export_range(0.05, 1.5, 0.01) var mouse_sensitivity := 0.4
@export_range(0.0, 2.0, 0.1) var look_height := 0.9
@export_range(25.0, 55.0, 1.0) var god_view_elevation_degrees := 42.0

var orbit_yaw := 0.0
var orbit_elevation := deg_to_rad(16.0)
var _mouse_look_active := false
var _camera_mode := CameraMode.FOLLOW
var _mode_before_fight := CameraMode.FOLLOW
var _fight_camera_active := false
var _fight_camera_anchor: Node3D
var _fight_camera_offset_local := Vector3(0.45, 1.15, -1.6)
var _fight_camera_focus_local := Vector3(0.0, -0.35, 5.8)
var _fight_camera_approach_focus_adjustment_local := Vector3(0.0, -0.15, 0.35)
var _fight_camera_focus_progress := 0.0
var _fight_camera_fov := 55.0
var _fight_camera_smoothing := 6.0
var _fight_camera_impulse_strength_m := 0.035
var _fight_camera_impulse_offset := Vector2.ZERO
var _fight_camera_impulse_velocity := Vector2.ZERO
var _saved_orbit_yaw := 0.0
var _saved_orbit_elevation := 0.0
var _smoothed_focus := Vector3.ZERO
var _zoom_offset_m := 0.0
var _current_fov := NORMAL_FOV

@onready var _target: Node3D = get_node_or_null(target_path) as Node3D
@onready var _camera: Camera3D = $Camera3D


func _ready() -> void:
	if _target == null:
		push_error("Boat follow camera could not find its target at %s." % target_path)
		return
	_smoothed_focus = _get_focus_position()
	global_position = _get_desired_position()
	_camera.make_current()
	_camera.look_at(_smoothed_focus, Vector3.UP)


func _process(delta: float) -> void:
	if _target == null:
		return
	if _camera_mode == CameraMode.FIGHT_CAMERA:
		if not _fight_camera_active or not is_instance_valid(_fight_camera_anchor):
			end_fight_camera()
		else:
			_update_fight_camera(delta)
			return
	_update_follow_camera(delta)
	_current_fov = lerpf(_current_fov, NORMAL_FOV, 1.0 - exp(-follow_smoothing * delta))
	_camera.fov = _current_fov


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("god_view_toggle") and not event.is_echo():
		cycle_camera_view()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_mouse_look_active = event.pressed
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED if _mouse_look_active else Input.MOUSE_MODE_VISIBLE)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _mouse_look_active:
		orbit_yaw += event.relative.x * mouse_sensitivity * 0.01
		var minimum_elevation := deg_to_rad(2.0)
		var maximum_elevation := deg_to_rad(88.0) if _camera_mode == CameraMode.GOD else deg_to_rad(84.0)
		orbit_elevation = clampf(
			orbit_elevation - event.relative.y * mouse_sensitivity * 0.01,
			minimum_elevation,
			maximum_elevation
		)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed and _camera_mode != CameraMode.FIGHT_CAMERA:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and _camera_mode != CameraMode.GOD:
			_zoom_offset_m = maxf(_zoom_offset_m - zoom_step_m, 4.0 - _get_vessel_follow_distance())
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and _camera_mode != CameraMode.GOD:
			_zoom_offset_m = minf(_zoom_offset_m + zoom_step_m, maximum_follow_distance - _get_vessel_follow_distance())
			get_viewport().set_input_as_handled()


func _exit_tree() -> void:
	if _mouse_look_active:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func release_mouse_look() -> void:
	_mouse_look_active = false
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


## Called by FishingRodSystem when the active hull/mount changes. This only
## registers the current anchor; O does not include Fight Camera until a hook.
func set_fight_camera_target(anchor: Node3D, mount_profile: FishingRodMountProfile) -> void:
	_fight_camera_anchor = anchor
	if mount_profile == null:
		_fight_camera_anchor = null
		if _fight_camera_active:
			end_fight_camera()
		return
	_fight_camera_offset_local = mount_profile.fight_camera_offset_from_mount_local_m
	_fight_camera_focus_local = mount_profile.fight_camera_look_target_from_mount_local_m
	_fight_camera_approach_focus_adjustment_local = mount_profile.fight_camera_approach_focus_adjustment_local_m
	_fight_camera_fov = mount_profile.fight_camera_fov_degrees
	_fight_camera_smoothing = mount_profile.fight_camera_follow_smoothing
	_fight_camera_impulse_strength_m = mount_profile.fight_camera_impulse_strength_m
	if _fight_camera_active and _camera_mode == CameraMode.FIGHT_CAMERA and _fight_camera_anchor == null:
		end_fight_camera()


func begin_fight_camera(auto_switch: bool = true) -> bool:
	if not is_instance_valid(_fight_camera_anchor):
		return false
	if not _fight_camera_active:
		_mode_before_fight = _camera_mode if _camera_mode != CameraMode.FIGHT_CAMERA else CameraMode.FOLLOW
		_fight_camera_active = true
	if auto_switch:
		_set_camera_mode(CameraMode.FIGHT_CAMERA)
	return true


func end_fight_camera() -> void:
	if not _fight_camera_active:
		return
	_fight_camera_active = false
	_fight_camera_impulse_offset = Vector2.ZERO
	_fight_camera_impulse_velocity = Vector2.ZERO
	if _camera_mode == CameraMode.FIGHT_CAMERA:
		_set_camera_mode(_mode_before_fight if _mode_before_fight != CameraMode.FIGHT_CAMERA else CameraMode.FOLLOW)


func trigger_fight_camera_impulse(strength: float = 1.0) -> void:
	if not _fight_camera_active or _camera_mode != CameraMode.FIGHT_CAMERA:
		return
	var impulse := _fight_camera_impulse_strength_m * clampf(strength, 0.0, 1.0)
	_fight_camera_impulse_velocity += Vector2(0.45, -1.0) * impulse * 9.5


func set_fight_camera_focus_progress(progress: float) -> void:
	_fight_camera_focus_progress = clampf(progress, 0.0, 1.0)


func cycle_camera_view() -> String:
	var modes: Array[int] = [CameraMode.FOLLOW, CameraMode.GOD]
	if _fight_camera_active and is_instance_valid(_fight_camera_anchor):
		modes.append(CameraMode.FIGHT_CAMERA)
	var current_index := modes.find(_camera_mode)
	var next_index := (current_index + 1) % modes.size() if current_index >= 0 else 0
	_set_camera_mode(modes[next_index])
	return get_camera_mode_name()


## Kept for callers that explicitly want the old two-state toggle behavior.
func toggle_god_view() -> bool:
	_set_camera_mode(CameraMode.FOLLOW if _camera_mode == CameraMode.GOD else CameraMode.GOD)
	return _camera_mode == CameraMode.GOD


func is_god_view_enabled() -> bool:
	return _camera_mode == CameraMode.GOD


func get_camera_mode_name() -> String:
	match _camera_mode:
		CameraMode.GOD:
			return "god"
		CameraMode.FIGHT_CAMERA:
			return "fight_camera"
		_:
			return "follow"


func get_camera_mode_label() -> String:
	return tr("camera.mode." + get_camera_mode_name())


func is_fight_camera_active() -> bool:
	return _fight_camera_active


func get_fight_camera_anchor() -> Node3D:
	return _fight_camera_anchor


func get_available_camera_modes() -> Array[String]:
	var result: Array[String] = ["follow", "god"]
	if _fight_camera_active and is_instance_valid(_fight_camera_anchor):
		result.append("fight_camera")
	return result


func _set_camera_mode(next_mode: int) -> void:
	if next_mode == CameraMode.FIGHT_CAMERA and (not _fight_camera_active or not is_instance_valid(_fight_camera_anchor)):
		return
	if _camera_mode == next_mode:
		return
	var was_god := _camera_mode == CameraMode.GOD
	if _camera_mode == CameraMode.FIGHT_CAMERA and next_mode != CameraMode.FIGHT_CAMERA:
		_fight_camera_impulse_offset = Vector2.ZERO
		_fight_camera_impulse_velocity = Vector2.ZERO
	_camera_mode = next_mode
	if next_mode == CameraMode.GOD and not was_god:
		_saved_orbit_yaw = orbit_yaw
		_saved_orbit_elevation = orbit_elevation
		orbit_elevation = deg_to_rad(god_view_elevation_degrees)
	elif was_god and next_mode != CameraMode.GOD:
		orbit_yaw = _saved_orbit_yaw
		orbit_elevation = _saved_orbit_elevation
	if next_mode == CameraMode.FIGHT_CAMERA:
		_current_fov = _camera.fov if _camera != null else NORMAL_FOV


func _update_follow_camera(delta: float) -> void:
	var weight := 1.0 - exp(-follow_smoothing * delta)
	var focus := _get_focus_position()
	global_position = global_position.lerp(_get_desired_position(), weight)
	_smoothed_focus = _smoothed_focus.lerp(focus, weight)
	_camera.look_at(_smoothed_focus, Vector3.UP)


func _update_fight_camera(delta: float) -> void:
	var position_target := _fight_camera_anchor.to_global(_fight_camera_offset_local)
	var focus_local := _fight_camera_focus_local + _fight_camera_approach_focus_adjustment_local * _fight_camera_focus_progress
	var focus_target := _fight_camera_anchor.to_global(focus_local)
	var weight := 1.0 - exp(-maxf(_fight_camera_smoothing, 0.1) * delta)
	_fight_camera_impulse_velocity += -_fight_camera_impulse_offset * 90.0 * delta
	_fight_camera_impulse_velocity *= exp(-10.0 * delta)
	_fight_camera_impulse_offset += _fight_camera_impulse_velocity * delta
	_fight_camera_impulse_offset = _fight_camera_impulse_offset.limit_length(0.1)
	var impulse_world := _camera.global_basis.x * _fight_camera_impulse_offset.x + _camera.global_basis.y * _fight_camera_impulse_offset.y
	global_position = global_position.lerp(position_target + impulse_world, weight)
	_smoothed_focus = _smoothed_focus.lerp(focus_target, weight)
	_current_fov = lerpf(_current_fov, _fight_camera_fov, weight)
	_camera.fov = _current_fov
	_camera.look_at(_smoothed_focus, Vector3.UP)


func _get_focus_position() -> Vector3:
	var target_transform := _target.global_transform
	return target_transform.origin + Vector3.UP * look_height


func _get_desired_position() -> Vector3:
	var target_transform := _target.global_transform
	var heading := target_transform.basis.get_euler().y + orbit_yaw
	var camera_distance := god_view_distance if _camera_mode == CameraMode.GOD else _get_vessel_follow_distance() + _zoom_offset_m
	var planar_distance := camera_distance * cos(orbit_elevation)
	var offset := Vector3(
		sin(heading) * planar_distance,
		sin(orbit_elevation) * camera_distance,
		cos(heading) * planar_distance
	)
	return _get_focus_position() + offset


func _get_vessel_follow_distance() -> float:
	var distance := follow_distance
	if _target != null and _target.has_method("supports_sail_trim") and bool(_target.call("supports_sail_trim")):
		distance = maxf(distance, sailing_follow_distance)
	return clampf(distance, 4.0, maximum_follow_distance)
