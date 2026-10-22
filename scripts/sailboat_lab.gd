extends Node3D
## Entry point for the standalone calm-water sailboat prototype.

@onready var _boat: Node3D = $SailboatBody
@onready var _camera: Camera3D = $Camera3D
@onready var _dynamic_water: MeshInstance3D = $WaterSurface
@onready var _static_water: MeshInstance3D = $WaterSurfaceStatic

const CAMERA_FOLLOW_RESPONSE := 7.0
const CAMERA_FOCUS_OFFSET := Vector3(0.0, 1.8, 0.0)

var _camera_follow_enabled := true
var _camera_follow_offset_world := Vector3.ZERO
var _fixed_camera_global_transform := Transform3D.IDENTITY


func _ready() -> void:
	_camera_follow_offset_world = _camera.global_position - _boat.global_position
	_camera.look_at(_boat.global_position + CAMERA_FOCUS_OFFSET, Vector3.UP)
	_fixed_camera_global_transform = _camera.global_transform
	_static_water.visible = false


func _process(delta: float) -> void:
	if not _camera_follow_enabled or _boat == null or _camera == null:
		return
	# Follow the interpolated render transform so camera motion does not inherit
	# fixed-step jitter from the RigidBody3D. This is presentation-only.
	var boat_transform := _boat.get_global_transform_interpolated()
	var target_position := boat_transform.origin + _camera_follow_offset_world
	var blend := 1.0 - exp(-CAMERA_FOLLOW_RESPONSE * maxf(delta, 0.0))
	_camera.global_position = _camera.global_position.lerp(target_position, blend)
	_camera.look_at(boat_transform.origin + CAMERA_FOCUS_OFFSET, Vector3.UP)


func _input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo or key_event.alt_pressed or key_event.ctrl_pressed or key_event.meta_pressed:
		return
	if key_event.physical_keycode == KEY_C and not key_event.shift_pressed:
		set_camera_follow_enabled(not _camera_follow_enabled)
		_mark_shortcut_handled()
	elif key_event.physical_keycode == KEY_BACKSPACE and not key_event.shift_pressed:
		# Reloading the standalone lab restores the boat, local wind and wave test
		# controls, camera mode, and UI to their scene-start values together.
		get_tree().reload_current_scene()
		_mark_shortcut_handled()


func _mark_shortcut_handled() -> void:
	var viewport := get_viewport()
	if viewport != null:
		viewport.set_input_as_handled()


func set_camera_follow_enabled(enabled: bool) -> void:
	_camera_follow_enabled = enabled
	if not _camera_follow_enabled and _camera != null:
		_camera.global_transform = _fixed_camera_global_transform


func is_camera_follow_enabled() -> bool:
	return _camera_follow_enabled


func set_dynamic_waves_enabled(enabled: bool) -> void:
	_boat.call("set_dynamic_waves_enabled", enabled)
	_dynamic_water.visible = enabled
	_static_water.visible = not enabled
