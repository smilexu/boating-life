class_name FishingCatchResult
extends RefCounted

## Session-level result for P3 consumers; inventory and sales are out of scope.

var catch_id := ""
var batch_id := ""
var batch_count := 1
var rig_id := ""
var hook_index := -1
var species_id := ""
var school_id := ""
var lure_id := ""
var fishing_method := "trolling"
var length_m := 0.0
var estimated_weight_kg := 0.0
var captured_game_time_seconds := 0.0
var population_before := 0
var population_after := 0
var debug_spawned := false


func to_dictionary() -> Dictionary:
	return {
		"catch_id": catch_id,
		"batch_id": batch_id,
		"batch_count": batch_count,
		"rig_id": rig_id,
		"hook_index": hook_index,
		"species_id": species_id,
		"school_id": school_id,
		"lure_id": lure_id,
		"fishing_method": fishing_method,
		"length_m": length_m,
		"estimated_weight_kg": estimated_weight_kg,
		"captured_game_time_seconds": captured_game_time_seconds,
		"population_before": population_before,
		"population_after": population_after,
		"debug_spawned": debug_spawned,
	}
