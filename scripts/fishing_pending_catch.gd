class_name FishingPendingCatch
extends RefCounted

## A hook event awaiting explicit retrieval completion. It does not own fish stock.

var catch_id := ""
var species_id := ""
var school_id := ""
var lure_id := ""
var hooked_game_time_seconds := 0.0
## Rolled when the hook event is created so the temporary display fish and the
## eventual authoritative CatchResult always use the same natural body length.
var body_length_m := 0.0


func to_dictionary() -> Dictionary:
	return {
		"catch_id": catch_id,
		"species_id": species_id,
		"school_id": school_id,
		"lure_id": lure_id,
		"hooked_game_time_seconds": hooked_game_time_seconds,
		"body_length_m": body_length_m,
	}
