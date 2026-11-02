class_name OnboardActivityProfile
extends Resource

## Hull-local walkable area and movement tuning for a supported onboard activity.

@export_category("Walkable Area")
## Convex aft open-deck footprint in hull-local X/Z metres; deliberately not
## the vessel's full bounding box. Use separate profiles for other vessel types.
@export var walkable_polygon_xz := PackedVector2Array([
	Vector2(-0.62, 0.12),
	Vector2(0.62, 0.12),
	Vector2(0.90, 0.42),
	Vector2(0.90, 3.10),
	Vector2(0.70, 3.36),
	Vector2(-0.70, 3.36),
	Vector2(-0.90, 3.10),
	Vector2(-0.90, 0.42),
])
@export var deck_height_m := 0.58
@export var safe_spawn_position := Vector3(0.0, 0.58, 1.28)
@export_range(0.12, 0.4, 0.01) var boundary_thickness_m := 0.20
@export_range(1.0, 2.8, 0.05) var boundary_height_m := 2.25
@export_range(0.05, 0.3, 0.01) var deck_collision_thickness_m := 0.16

@export_category("Player")
@export_range(1.0, 4.0, 0.1) var move_speed_mps := 2.4
@export_range(0.2, 0.9, 0.05) var jump_height_m := 0.42
@export_range(1.2, 2.0, 0.05) var capsule_height_m := 1.68
@export_range(0.2, 0.4, 0.01) var capsule_radius_m := 0.28
@export_range(1.3, 1.8, 0.01) var eye_height_m := 1.55
@export_range(50.0, 100.0, 1.0) var first_person_fov_degrees := 76.0
@export_range(0.1, 1.0, 0.05) var mouse_sensitivity := 0.45
@export_range(5.0, 35.0, 1.0) var pitch_limit_degrees := 85.0
@export_range(2.0, 20.0, 0.1) var gravity_mps2 := 9.8
