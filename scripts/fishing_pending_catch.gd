class_name FishingPendingCatch
extends RefCounted

## A hook event awaiting explicit retrieval completion. It does not own fish stock.

var catch_id := ""
var species_id := ""
var school_id := ""
## Provenance is "school", "ambient", or "debug". Ambient fish are held by
## FishAuthorityAdapter and deliberately have no fabricated school_id.
var source_type := "school"
var ambient_fish_id := ""
var lure_id := ""
var fishing_method := "trolling"
var debug_spawned := false
var rig_id := "single_jig"
var hook_index := -1
var hook_confirmed := false
var hooked_game_time_seconds := 0.0
## Rolled when the hook event is created so the temporary display fish and the
## eventual authoritative CatchResult always use the same natural body length.
var body_length_m := 0.0


func to_dictionary() -> Dictionary:
	return {
		"catch_id": catch_id,
		"species_id": species_id,
		"school_id": school_id,
		"source_type": source_type,
		"ambient_fish_id": ambient_fish_id,
		"lure_id": lure_id,
		"fishing_method": fishing_method,
		"debug_spawned": debug_spawned,
		"rig_id": rig_id,
		"hook_index": hook_index,
		"hook_confirmed": hook_confirmed,
		"hooked_game_time_seconds": hooked_game_time_seconds,
		"body_length_m": body_length_m,
	}
