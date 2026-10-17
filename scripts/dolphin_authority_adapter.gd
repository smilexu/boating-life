class_name DolphinAuthorityAdapter
extends RefCounted

## Snapshot contract for local or future server-authoritative dolphin state.

func authority_source_name() -> String:
	return "Unconfigured"


func initialize(_bathymetry: BathymetryManager, _georeference: GeoReference, _seed: int) -> bool:
	return false


func update(_delta: float, _boat_position: Vector3, _boat_forward: Vector3, _boat_speed_mps: float) -> void:
	pass


func set_surface_height_reference(_dolphin_id: String, _height_y: float) -> void:
	pass


func get_dolphin_snapshots() -> Array[Dictionary]:
	return []


func get_map_snapshot() -> Array[Dictionary]:
	return []


func request_follow_event(_boat_position: Vector3, _boat_forward: Vector3, _duration_seconds: float = 60.0, _debug: bool = false) -> bool:
	return false


func request_leap(_dolphin_id: String = "") -> bool:
	return false


func create_snapshot() -> Dictionary:
	return {}


func restore_snapshot(_snapshot: Dictionary) -> bool:
	return false


func get_state_revision() -> int:
	return 0


func set_natural_encounter_probability(_probability: float) -> void:
	pass


func configure_follow_motion(_max_catchup_bonus_mps: float, _catchup_full_distance_m: float, _acceleration_mps2: float) -> void:
	pass


func is_following() -> bool:
	return false


func get_follow_remaining() -> float:
	return 0.0


func get_follow_mode() -> String:
	return "inactive"
