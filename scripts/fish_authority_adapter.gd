class_name FishAuthorityAdapter
extends RefCounted

## Minimal world-resource authority contract. The renderer and map consume only
## snapshots from this interface; a future network client can forward mutating
## requests to its server adapter without changing either presentation layer.


func authority_source_name() -> String:
	return "Unconfigured"


func initialize(_seed: int, _bathymetry: BathymetryManager, _georeference: GeoReference, _profiles: Array[FishSpeciesProfile]) -> void:
	push_error("FishAuthorityAdapter.initialize must be implemented by an authority adapter.")


func update(_delta: float) -> void:
	pass


func get_school(_school_id: String) -> Dictionary:
	return {}


func get_all_school_snapshots() -> Array[Dictionary]:
	return []


func get_schools_near(_world_position: Vector3, _radius_m: float) -> Array[Dictionary]:
	return []


func get_map_snapshot(_species_ids: Array[String] = []) -> Array[Dictionary]:
	return []


func request_population_change(_school_id: String, _population_delta: int) -> Dictionary:
	return {"accepted": false, "reason": "Authority adapter does not allow client-side resource mutation."}


func create_snapshot() -> Dictionary:
	return {}


func restore_snapshot(_snapshot: Dictionary) -> bool:
	return false


func get_state_revision() -> int:
	return 0


func get_world_seed() -> int:
	return 0
