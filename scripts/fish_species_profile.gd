class_name FishSpeciesProfile
extends Resource

## Shared ecological and visual tuning for one fish species.
## Habitat ranges are game suitability estimates, not survey observations.

@export var species_id := ""
@export var species_index := 0
@export var display_name := ""
@export var english_name := ""
@export_multiline var habitat_description := ""
@export_file("*.glb") var model_path := ""
@export_enum("Positive X", "Negative X") var model_forward_axis := 0
@export_range(-1.0, 1.0, 0.01) var model_head_x := 0.5
@export_range(0.0, 60.0, 0.1) var minimum_depth_m := 0.0
@export_range(0.0, 60.0, 0.1) var maximum_depth_m := 60.0
@export_range(0.0, 60.0, 0.1) var preferred_depth_min_m := 0.0
@export_range(0.0, 60.0, 0.1) var preferred_depth_max_m := 60.0
@export_range(0.0, 1.0, 0.01) var spawn_chance := 0.1
@export_range(0.0, 2.0, 0.05) var eelgrass_spawn_boost := 0.0
@export_range(1, 200, 1) var population_min := 1
@export_range(1, 400, 1) var population_max := 10
@export_range(0.01, 8.0, 0.01) var movement_speed_min_mps := 0.2
@export_range(0.01, 8.0, 0.01) var movement_speed_max_mps := 1.0
@export_enum("surface", "midwater", "near_bottom") var vertical_layer := "midwater"
@export_range(0.03, 2.0, 0.01) var target_visual_length_m := 0.35
## Optional client-side visual size variation. A zero range keeps the target size.
@export var visual_length_range_m := Vector2.ZERO
## Rendering-only scale. It must never be used as the ecological body length.
@export_range(0.25, 4.0, 0.05) var visual_scale_multiplier := 1.0
## PBR roughness for the fish material. No emission is used for visibility.
@export_range(0.05, 1.0, 0.01) var visual_roughness := 0.68
## Target fraction of time a school spends in the near-surface activity layer.
@export_range(0.0, 1.0, 0.01) var surface_activity_time_share := 0.0
@export var surface_activity_depth_m := Vector2(0.5, 2.0)
@export var deep_activity_depth_m := Vector2(7.0, 20.0)
@export var surface_activity_duration_seconds := Vector2(30.0, 90.0)
@export_range(0.05, 1.5, 0.05) var activity_vertical_speed_mps := 0.5
## Used by small coastal fish with a configured near-surface activity layer.
@export var preferred_swim_depth_m := Vector2(0.45, 1.5)
@export var flee_swim_depth_m := Vector2(0.4, 0.9)
@export_range(0.05, 1.0, 0.01) var vertical_move_speed_mps := 0.28
@export_range(0.0, 1.0, 0.01) var near_surface_visit_probability := 0.18
@export var near_surface_depth_m := Vector2(0.3, 0.6)
@export_range(0.5, 12.0, 0.1) var school_activity_radius_m := 4.2
@export_range(0.4, 6.0, 0.05) var minimum_water_column_m := 0.85
@export_range(0.0, 0.1, 0.001) var body_wave_amplitude_m := 0.02
@export_range(0.1, 8.0, 0.01) var tail_frequency_hz := 1.5
@export var map_color := Color(0.8, 0.8, 0.8, 1.0)


func suitability_for_depth(depth_m: float) -> float:
	if depth_m < minimum_depth_m or depth_m > maximum_depth_m:
		return 0.0
	var edge_width := maxf(0.25, (maximum_depth_m - minimum_depth_m) * 0.12)
	var edge_in := smoothstep(minimum_depth_m, minimum_depth_m + edge_width, depth_m)
	var edge_out := 1.0 - smoothstep(maximum_depth_m - edge_width, maximum_depth_m, depth_m)
	var preferred := 1.0
	if depth_m < preferred_depth_min_m:
		preferred = 0.25 + 0.75 * smoothstep(minimum_depth_m, preferred_depth_min_m, depth_m)
	elif depth_m > preferred_depth_max_m:
		preferred = 1.0 - 0.75 * smoothstep(preferred_depth_max_m, maximum_depth_m, depth_m)
	return clampf(edge_in * edge_out * preferred, 0.0, 1.0)
