@tool
class_name FishingRodMount
extends Marker3D

@export var mount_profile: FishingRodMountProfile:
	set(value):
		mount_profile = value
		_apply_profile()


func _ready() -> void:
	_apply_profile()


func _apply_profile() -> void:
	if mount_profile == null:
		return
	position = mount_profile.mount_position_m
	rotation_degrees = mount_profile.mount_rotation_degrees

