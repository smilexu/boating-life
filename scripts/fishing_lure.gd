class_name FishingLure
extends Resource

## A simple preset-depth lure. Its depth is relative to the local water surface;
## it does not model line length, sink rate, ballast, or hydrodynamic drag.

@export var lure_id := ""
@export var name_key := ""
@export var lure_tags: PackedStringArray = PackedStringArray()
@export var work_depth_range_m := Vector2(0.0, 1.0)
@export_range(0.0, 30.0, 0.1) var preferred_depth_m := 0.5
@export_range(0.05, 20.0, 0.05) var depth_falloff_m := 0.5


func depth_match_weight(fish_depth_m: float, effective_max_depth_m: float = INF) -> float:
	if not is_finite(fish_depth_m) or fish_depth_m < work_depth_range_m.x:
		return 0.0
	var effective_max := minf(work_depth_range_m.y, effective_max_depth_m)
	if effective_max < work_depth_range_m.x or fish_depth_m > effective_max:
		return 0.0
	var optimum := clampf(preferred_depth_m, work_depth_range_m.x, effective_max)
	var normalized_offset := (fish_depth_m - optimum) / maxf(depth_falloff_m, 0.05)
	return exp(-0.5 * normalized_offset * normalized_offset)
