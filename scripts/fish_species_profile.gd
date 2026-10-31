class_name FishSpeciesProfile
extends Resource

## Shared ecological and visual tuning for one fish species.
## Habitat ranges are game suitability estimates, not survey observations.

@export_group("Identity")
## Stable save/network identity. Never derive this from localized display text.
@export var species_id := ""
## Reassignable profile ordering field. It is not a persistent identity or ecology hash salt.
@export_range(0, 1024, 1) var species_index := 0
@export var scientific_name := ""
@export var name_key := ""
@export var description_key := ""
## Natural fish body length range in metres; distinct from rendered model length.
@export var body_length_range_m := Vector2(0.05, 0.5)

@export_group("Ecology")
## Seafloor chart depth below LAT, not swimming depth below the water surface.
@export_range(0.0, 60.0, 0.1) var minimum_depth_m := 0.0
@export_range(0.0, 60.0, 0.1) var maximum_depth_m := 60.0
@export_range(0.0, 60.0, 0.1) var preferred_depth_min_m := 0.0
@export_range(0.0, 60.0, 0.1) var preferred_depth_max_m := 60.0
## Per-cell generation probability before habitat suitability is applied.
@export_range(0.0, 1.0, 0.01) var spawn_chance := 0.1
@export_range(0.0, 2.0, 0.05) var eelgrass_spawn_boost := 0.0
@export_enum("additive", "edge_preference") var vegetation_spawn_mode := "additive"

@export_group("Behavior")
## High-level movement algorithm family. Values preserve old per-species behavior.
@export_enum("free_swim", "fast_pelagic", "schooling_pelagic", "coastal_benthic") var behavior_type := "free_swim"
## Empty means the existing uniform population_min/max draw. Optional bands select
## one weighted size range before drawing its integer school size.
@export var school_size_ranges: Array[Vector2i] = []
@export var school_size_band_weights: PackedFloat32Array = PackedFloat32Array()
@export_range(1, 200, 1) var population_min := 1
@export_range(1, 400, 1) var population_max := 10
@export_range(0.01, 8.0, 0.01) var movement_speed_min_mps := 0.2
@export_range(0.01, 8.0, 0.01) var movement_speed_max_mps := 1.0
@export_enum("surface", "midwater", "near_bottom") var vertical_layer := "midwater"
@export var surface_activity_cycle_enabled := false
@export_range(0.0, 1.0, 0.01) var surface_activity_time_share := 0.0
@export var surface_activity_depth_m := Vector2(0.5, 2.0)
@export var deep_activity_depth_m := Vector2(7.0, 20.0)
@export var surface_activity_duration_seconds := Vector2(30.0, 90.0)
@export_range(0.05, 1.5, 0.05) var activity_vertical_speed_mps := 0.5
@export_range(0.0, 2.0, 0.01) var initial_speed_factor := 0.38
@export_range(0.0, 1.0, 0.01) var group_forward_bias := 0.08
@export_range(0.1, 30.0, 0.1) var school_wander_radius_m := 2.4
@export_range(0.0, 8.0, 0.01) var school_separation_distance_m := 0.48
@export_range(0.0, 20.0, 0.1) var school_alignment_radius_m := 1.65
@export_range(0.0, 2.0, 0.01) var school_cohesion_strength := 0.13
@export_range(0.0, 2.0, 0.01) var school_alignment_strength := 0.10
@export_range(0.0, 50.0, 0.5) var flee_radius_m := 24.0
## Speed multiplier used only while the fish is in the startled/fleeing state.
@export_range(0.0, 4.0, 0.01) var flee_speed_factor := 2.5
@export_range(0.0, 4.0, 0.01) var scatter_radius_extension_factor := 1.0
@export_range(0.0, 4.0, 0.01) var escape_acceleration_factor := 1.55
@export_range(0.05, 5.0, 0.01) var turn_rate_radians_per_second := 2.2
@export_range(0.0, 1.0, 0.01) var ordinary_acceleration_response := 1.0
## Used by coastal behavior families that choose individual depth targets.
@export var preferred_swim_depth_m := Vector2(0.45, 1.5)
@export var flee_swim_depth_m := Vector2(0.4, 0.9)
@export_range(0.05, 1.0, 0.01) var vertical_move_speed_mps := 0.28
@export_range(0.0, 1.0, 0.01) var near_surface_visit_probability := 0.18
@export var near_surface_depth_m := Vector2(0.3, 0.6)
@export_range(0.5, 12.0, 0.1) var school_activity_radius_m := 4.2
@export_range(0.4, 6.0, 0.05) var minimum_water_column_m := 0.85

@export_group("Visual")
@export_file("*.glb") var model_path := ""
@export_enum("Positive X", "Negative X") var model_forward_axis := 0
@export_range(-1.0, 1.0, 0.01) var model_head_x := 0.5
@export var visual_enabled := true
## Schools deeper than this remain authoritative/map-visible but are not rendered.
@export_range(0.0, 100.0, 0.25) var logical_depth_threshold_m := 6.0
## Target display length. This is deliberately distinct from natural fish length.
@export_range(0.03, 2.0, 0.01) var target_visual_length_m := 0.35
## Rendering allocation weight only; never used by ecology or population logic.
@export_range(0.0, 1.0, 0.01) var render_budget_share := 0.18
## Optional client-side visual size variation. A zero range keeps the target size.
@export var visual_length_range_m := Vector2.ZERO
## Rendering-only scale. It must never be used as the ecological body length.
@export_range(0.25, 4.0, 0.05) var visual_scale_multiplier := 1.0
## PBR roughness for the fish material. No emission is used for visibility.
@export_range(0.05, 1.0, 0.01) var visual_roughness := 0.68
@export_range(0.0, 0.1, 0.001) var body_wave_amplitude_m := 0.02
@export_range(0.1, 8.0, 0.01) var tail_frequency_hz := 1.5
@export var map_color := Color(0.8, 0.8, 0.8, 1.0)

@export_group("Fishing")
@export var supported_fishing_methods: PackedStringArray = PackedStringArray()
@export var compatible_lure_tags: PackedStringArray = PackedStringArray()
@export_range(0.0, 4.0, 0.05) var relative_bite_tendency := 1.0
## Per-species speed response; the vessel's own cruise cap is applied separately.
@export_range(0.1, 12.0, 0.1) var trolling_speed_optimum_mps := 1.5
@export_range(0.1, 8.0, 0.1) var trolling_speed_falloff_mps := 1.0
## Game estimate: kilograms = coefficient × body_length_m³.
@export_range(0.1, 100.0, 0.1) var estimated_weight_coefficient_kg_per_m3 := 10.0


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
