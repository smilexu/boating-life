class_name FishingRodMountProfile
extends Resource

## Visual-only stern rod mount. Coordinates are local to the hull's visual root.

@export_group("Mount")
@export var mount_position_m := Vector3.ZERO
@export var mount_rotation_degrees := Vector3.ZERO

@export_group("Rod geometry")
@export_range(2.1, 2.4, 0.01) var rod_length_m := 2.25
@export_range(0.018, 0.030, 0.001) var rod_root_diameter_m := 0.024
@export_range(0.003, 0.005, 0.001) var rod_tip_diameter_m := 0.004
@export_range(6, 8, 1) var guide_count := 7
@export_range(8, 16, 1) var rod_segment_count := 12
@export_range(25.0, 40.0, 1.0) var rod_elevation_degrees := 34.0
@export_range(0.15, 1.2, 0.01) var maximum_hook_bend_m := 0.96
@export_range(3.0, 15.0, 0.1) var line_out_length_m := 9.0

@export_group("Catch display")
## Fish starts appearing during the last part of retrieval, still below the surface.
@export_range(3.0, 8.0, 0.1) var catch_approach_start_distance_m := 5.8
## Aft distance from the hull root for the surface struggle.
@export_range(1.5, 4.0, 0.1) var catch_surface_distance_m := 2.7
## Final visible line length from the dynamically bent rod tip to the fish mouth.
@export_range(0.35, 0.55, 0.01) var landing_min_line_length_m := 0.45
## Minimum desired clearance for the hanging fish tail above sampled water.
@export_range(0.0, 0.4, 0.01) var hanging_clearance_margin_m := 0.10
## Per-hull cap for the final short hanging sway.
@export_range(0.0, 25.0, 1.0) var hanging_sway_max_degrees := 12.0

@export_group("Fight camera")
## Camera position is relative to this mount; negative Z is inboard toward the bow.
@export var fight_camera_offset_from_mount_local_m := Vector3(0.45, 1.15, -1.6)
## Aim covers the full rod and water aft of the stern.
@export var fight_camera_look_target_from_mount_local_m := Vector3(0.0, -0.35, 5.8)
@export var fight_camera_approach_focus_adjustment_local_m := Vector3(0.0, -0.15, 0.5)
@export_range(40.0, 65.0, 1.0) var fight_camera_fov_degrees := 55.0
@export_range(1.0, 12.0, 0.1) var fight_camera_follow_smoothing := 6.0
@export_range(0.0, 0.1, 0.005) var fight_camera_impulse_strength_m := 0.035
