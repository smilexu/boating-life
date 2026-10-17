extends Node3D

## Smooth orbit camera positioned behind the boat's local -Z bow direction.
## Hold and drag the right mouse button to look around.

@export_node_path("Node3D") var target_path := NodePath("../MotionRoot")
@export_range(4.0, 18.0, 0.5) var follow_distance := 14.0
@export_range(1.0, 8.0, 0.1) var follow_smoothing := 5.5
@export_range(0.05, 1.0, 0.01) var mouse_sensitivity := 0.28
@export_range(0.0, 2.0, 0.1) var look_height := 0.9

var orbit_yaw := 0.0
var orbit_elevation := deg_to_rad(16.0)
var _mouse_look_active := false
var _smoothed_focus := Vector3.ZERO

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

	var weight := 1.0 - exp(-follow_smoothing * delta)
	var focus := _get_focus_position()
	global_position = global_position.lerp(_get_desired_position(), weight)
	_smoothed_focus = _smoothed_focus.lerp(focus, weight)
	_camera.look_at(_smoothed_focus, Vector3.UP)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_mouse_look_active = event.pressed
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED if _mouse_look_active else Input.MOUSE_MODE_VISIBLE)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _mouse_look_active:
		orbit_yaw += event.relative.x * mouse_sensitivity * 0.01
		orbit_elevation = clampf(
			orbit_elevation - event.relative.y * mouse_sensitivity * 0.01,
			deg_to_rad(8.0),
			deg_to_rad(55.0)
		)
		get_viewport().set_input_as_handled()


func _exit_tree() -> void:
	if _mouse_look_active:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func release_mouse_look() -> void:
	_mouse_look_active = false
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _get_focus_position() -> Vector3:
	var target_transform := _target.global_transform
	return target_transform.origin + Vector3.UP * look_height


func _get_desired_position() -> Vector3:
	var target_transform := _target.global_transform
	var heading := target_transform.basis.get_euler().y + orbit_yaw
	var planar_distance := follow_distance * cos(orbit_elevation)
	var offset := Vector3(
		sin(heading) * planar_distance,
		sin(orbit_elevation) * follow_distance,
		cos(heading) * planar_distance
	)
	return target_transform.origin + Vector3.UP * look_height + offset

