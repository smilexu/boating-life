class_name FishAuthorityAdapter
extends RefCounted

## Minimal world-resource authority contract. The renderer and map consume only
## snapshots from this interface; a future network client can forward mutating
## requests to its server adapter without changing either presentation layer.


func authority_source_name() -> String:
	return "Unconfigured"


func initialize(_seed: int, _bathymetry: BathymetryManager, _georeference: GeoReference, _profiles: Array[FishSpeciesProfile], _initial_game_time_seconds: float = 0.0) -> void:
	push_error("FishAuthorityAdapter.initialize must be implemented by an authority adapter.")


func update(_delta: float, _game_time_seconds: float = -1.0) -> void:
	pass


func get_school(_school_id: String) -> Dictionary:
	return {}


func get_all_school_snapshots() -> Array[Dictionary]:
	return []


func get_schools_near(_world_position: Vector3, _radius_m: float, _include_unavailable: bool = false) -> Array[Dictionary]:
	return []


## Ambient fish are transient authoritative individuals, not fish schools or
## persistent population. Network adapters must forward these mutations to
## their server rather than fabricating a local school identity.
func evaluate_ambient_fishing_candidates(_context: Dictionary) -> Dictionary:
	return {"candidates": [], "reason": "ambient_authority_unavailable", "environment_quality": 0.0}


func request_ambient_fish_encounter(_context: Dictionary) -> Dictionary:
	return {"accepted": false, "reason": "ambient_authority_unavailable"}


func get_ambient_fish_encounter(_ambient_fish_id: String) -> Dictionary:
	return {}


func confirm_ambient_fish_encounter(_ambient_fish_id: String, _fishing_session_id: String, _hook_index: int) -> bool:
	return false


func release_ambient_fish_encounter(_ambient_fish_id: String, _reason: String = "cancelled") -> bool:
	return false


func release_ambient_fishing_session(_fishing_session_id: String, _reason: String = "session_ended") -> int:
	return 0


func settle_ambient_fish_encounter(_ambient_fish_id: String) -> Dictionary:
	return {"accepted": false, "reason": "ambient_authority_unavailable"}


func settle_boat_fishing_catch_batch(_school_changes: Dictionary, _ambient_fish_ids: Array[String], _game_time_seconds: float = -1.0) -> Dictionary:
	return {"accepted": false, "reason": "boat_catch_batch_authority_unavailable"}


func get_ambient_fish_session_snapshot(_fishing_session_id: String) -> Array[Dictionary]:
	return []


func get_map_snapshot(_species_ids: Array[String] = []) -> Array[Dictionary]:
	return []


func request_population_change(_school_id: String, _population_delta: int, _game_time_seconds: float = -1.0) -> Dictionary:
	return {"accepted": false, "reason": "Authority adapter does not allow client-side resource mutation."}


func request_population_changes(_changes: Dictionary, _game_time_seconds: float = -1.0) -> Dictionary:
	return {"accepted": false, "reason": "Authority adapter does not support atomic batch resource mutation."}


func create_snapshot() -> Dictionary:
	return {}


func restore_snapshot(_snapshot: Dictionary) -> bool:
	return false


func get_state_revision() -> int:
	return 0


func get_world_seed() -> int:
	return 0
