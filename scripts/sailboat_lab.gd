extends Node3D
## Entry point for the standalone calm-water sailboat prototype.

@onready var _boat: Node3D = $SailboatBody
@onready var _camera: Camera3D = $Camera3D
@onready var _dynamic_water: MeshInstance3D = $WaterSurface
@onready var _static_water: MeshInstance3D = $WaterSurfaceStatic


func _ready() -> void:
	_camera.look_at(_boat.global_position + Vector3(0.0, 0.45, 0.0), Vector3.UP)
	_static_water.visible = false


func set_dynamic_waves_enabled(enabled: bool) -> void:
	_boat.call("set_dynamic_waves_enabled", enabled)
	_dynamic_water.visible = enabled
	_static_water.visible = not enabled
