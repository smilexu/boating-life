extends Camera3D

## Test-only keyboard look controls for checking cloud reprojection while turning.

@export_range(30.0, 360.0, 5.0) var turn_speed_degrees_per_second := 150.0
@export_range(20.0, 80.0, 5.0) var maximum_pitch_degrees := 45.0
@export_range(90.0, 360.0, 15.0) var auto_turn_degrees_per_second := 240.0

var _yaw := 0.0
var _pitch := 0.0
var _auto_turn_enabled := false


func _ready() -> void:
	_yaw = rotation.y
	_pitch = rotation.x


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_F1:
		_auto_turn_enabled = not _auto_turn_enabled
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if _auto_turn_enabled:
		_yaw += deg_to_rad(auto_turn_degrees_per_second) * delta

	var turn_axis := float(Input.is_key_pressed(KEY_RIGHT)) - float(Input.is_key_pressed(KEY_LEFT))
	var pitch_axis := float(Input.is_key_pressed(KEY_DOWN)) - float(Input.is_key_pressed(KEY_UP))
	_yaw -= deg_to_rad(turn_speed_degrees_per_second) * turn_axis * delta
	_pitch = clampf(
		_pitch + deg_to_rad(turn_speed_degrees_per_second) * pitch_axis * delta,
		-deg_to_rad(maximum_pitch_degrees),
		deg_to_rad(maximum_pitch_degrees)
	)
	rotation = Vector3(_pitch, _yaw, 0.0)
