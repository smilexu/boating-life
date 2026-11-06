class_name FishResourceManager
extends Node3D

## Holds the world-level fish resource state. Render instances are owned by the
## child renderer and are never the source of truth.

signal resources_ready
signal resources_changed(state_revision: int)

const LOCAL_AUTHORITY_SCRIPT := preload("res://scripts/fish_local_authority.gd")

@export_category("World resources")
@export var world_seed := FishLocalAuthority.DEFAULT_WORLD_SEED
@export var species_profiles: Array[FishSpeciesProfile] = []
@export_node_path("Node") var bathymetry_manager_path := NodePath("../BathymetryManager")
@export_node_path("Node3D") var shallow_seabed_manager_path := NodePath("../ShallowSeabedManager")
@export_node_path("Node3D") var boat_path := NodePath("../PlayerBoat/MotionRoot")
@export_node_path("Node") var wave_sampler_path := NodePath("../WaveSampler")
@export_node_path("Node") var map_layer_path := NodePath("../FishResourceMap")

@export_category("School vessel disturbance")
@export_range(20.0, 80.0, 1.0) var disturbance_query_radius_m := 48.0
@export_range(2.0, 40.0, 0.5) var disturbance_horizontal_falloff_m := 12.0
@export_range(1.0, 12.0, 0.25) var disturbance_vertical_falloff_m := 3.5
@export_range(0.05, 15.0, 0.1) var disturbance_rise_time_constant_s := 3.0
@export_range(0.1, 60.0, 0.5) var disturbance_fall_time_constant_s := 12.0
@export_range(0.0, 1.0, 0.01) var disturbance_alert_enter_level := 0.20
@export_range(0.0, 1.0, 0.01) var disturbance_alert_exit_level := 0.12
@export_range(0.0, 1.0, 0.01) var disturbance_flee_enter_level := 0.65
@export_range(0.0, 1.0, 0.01) var disturbance_flee_exit_level := 0.45
@export_range(0.1, 10.0, 0.1) var disturbance_flee_duration_s := 1.5
@export_range(0.0, 1.0, 0.01) var disturbance_bite_willingness_calm := 1.0
@export_range(0.0, 1.0, 0.01) var disturbance_bite_willingness_alert := 0.80
@export_range(0.0, 1.0, 0.01) var disturbance_bite_willingness_fleeing := 0.25
@export_range(0.01, 1.0, 0.01) var engine_off_stationary_disturbance := 0.08
@export_range(0.01, 1.0, 0.01) var engine_off_drift_disturbance := 0.12
@export_range(0.05, 1.0, 0.01) var engine_off_max_movement_disturbance := 0.50
@export_range(0.01, 1.0, 0.01) var engine_idle_disturbance := 0.30
@export_range(0.01, 1.0, 0.01) var engine_low_speed_disturbance := 0.50
@export_range(0.01, 1.0, 0.01) var engine_cruise_disturbance := 0.80
@export_range(0.01, 1.0, 0.01) var engine_high_speed_disturbance := 1.0
@export_range(0.0, 1.0, 0.01) var engine_idle_speed_mps := 0.25
@export_range(0.1, 4.0, 0.1) var engine_low_speed_end_mps := 1.5
@export_range(1.0, 12.0, 0.1) var engine_cruise_speed_end_mps := 5.5
@export_range(2.0, 20.0, 0.1) var engine_high_speed_end_mps := 8.0
@export_range(0.1, 15.0, 0.1) var engine_off_full_movement_speed_mps := 6.0
@export_range(0.01, 1.0, 0.01) var disturbance_still_speed_mps := 0.08

var _bathymetry: BathymetryManager
var _shallow_seabed_manager: ShallowSeabedManager
var _georeference: GeoReference
var _boat: Node3D
var _wave_sampler: WaveSampler
var _authority: FishAuthorityAdapter
var _renderer: FishSchoolRenderer
var _map_layer: FishResourceMap
var _fishing_encounter_system: FishingEncounterSystem
var _fish_finder_sensor: FishFinderSensor
var _world_time_manager: Node
var _last_revision := -1
var _map_refresh_elapsed := 0.0


func _ready() -> void:
	add_to_group("fish_resource_manager")
	_bathymetry = get_node_or_null(bathymetry_manager_path) as BathymetryManager
	_shallow_seabed_manager = get_node_or_null(shallow_seabed_manager_path) as ShallowSeabedManager
	_boat = get_node_or_null(boat_path) as Node3D
	_wave_sampler = get_node_or_null(wave_sampler_path) as WaveSampler
	_world_time_manager = get_node_or_null("/root/WorldTimeManager")
	if _bathymetry != null:
		_georeference = _bathymetry.georeference
	if species_profiles.is_empty():
		_load_default_profiles()
	if _bathymetry == null or _georeference == null or not _bathymetry.data_available:
		push_warning("FishResourceManager disabled: valid local bathymetry and GeoReference are required.")
		return
	if _authority == null:
		_authority = LOCAL_AUTHORITY_SCRIPT.new() as FishAuthorityAdapter
	_initialize_authority(_authority)
	_renderer = get_node_or_null("FishSchoolRenderer") as FishSchoolRenderer
	if _renderer != null:
		_renderer.configure(self, _bathymetry, _boat, _wave_sampler, species_profiles, _shallow_seabed_manager)
	_map_layer = get_node_or_null(map_layer_path) as FishResourceMap
	if _map_layer != null:
		_map_layer.configure(self, _bathymetry, _georeference, _boat)
	_fishing_encounter_system = FishingEncounterSystem.new()
	_fishing_encounter_system.name = "FishingEncounterSystem"
	_fishing_encounter_system.configure(self, _boat)
	add_child(_fishing_encounter_system)
	_fish_finder_sensor = FishFinderSensor.new()
	_fish_finder_sensor.name = "FishFinderSensor"
	_fish_finder_sensor.configure(self, _boat, _bathymetry, _wave_sampler)
	add_child(_fish_finder_sensor)
	_last_revision = _authority.get_state_revision()
	resources_ready.emit()
	resources_changed.emit(_last_revision)


func _process(delta: float) -> void:
	if _authority == null:
		return
	_authority.update(delta, _world_game_time_seconds())
	_update_authoritative_disturbance(delta)
	var revision := _authority.get_state_revision()
	if revision != _last_revision:
		_last_revision = revision
		resources_changed.emit(revision)
	_map_refresh_elapsed += delta
	if _map_refresh_elapsed >= 2.0:
		_map_refresh_elapsed = fmod(_map_refresh_elapsed, 2.0)
		if _map_layer != null and _map_layer.is_map_open():
			_map_layer.refresh_data()


func _update_authoritative_disturbance(delta_real_seconds: float) -> void:
	if _authority == null or _boat == null or not is_instance_valid(_boat) or not _boat.is_inside_tree():
		return
	var boat_position := _boat.global_position
	if not _is_finite_vector3(boat_position):
		return
	var wave_time := float(_wave_sampler.get("wave_time_seconds")) if _wave_sampler != null else _world_game_time_seconds()
	var boat_surface_y := boat_position.y
	if _wave_sampler != null:
		var boat_surface_sample := _wave_sampler.sample_physics_surface(Vector3(boat_position.x, 0.0, boat_position.z), wave_time)
		boat_surface_y = _finite_or(float(boat_surface_sample.get("height", boat_position.y)), boat_position.y)
	var draft := -1.0
	if _boat.has_method("get_current_draft_m"):
		draft = float(_boat.call("get_current_draft_m"))
	if not is_finite(draft) or draft <= 0.0:
		draft = 0.8
	var engine_data_available := _boat.has_method("has_engine") and _boat.has_method("get_engine_audio_state")
	var engine_running := false
	var throttle_demand := 0.0
	if engine_data_available:
		var engine_state: Dictionary = _boat.call("get_engine_audio_state")
		throttle_demand = _finite_or(float(engine_state.get("throttle_demand", 0.0)), 0.0)
		# TEMP: powered boats do not yet expose an explicit ignition state. Treat
		# zero throttle as engine-off for disturbance; replace this proxy when the
		# boat controller gains an authoritative engine start/stop state.
		engine_running = (
			_finite_bool(engine_state.get("running", false))
			and bool(_boat.call("has_engine"))
			and throttle_demand > 0.0
		)
	var speed_mps := absf(_numeric_property(_boat, "speed_mps", 0.0))
	var vessel_snapshot := {
		"world_position": boat_position,
		"hull_bottom_world_y": boat_surface_y - draft,
		"surface_height_m": boat_surface_y,
		"engine_data_available": engine_data_available,
		"engine_running": engine_running,
		"throttle_demand": throttle_demand,
		"speed_mps": speed_mps,
	}
	var samples_by_id: Dictionary = {}
	var schools := get_schools_near(boat_position, disturbance_query_radius_m, true)
	if _authority.has_method("get_disturbed_school_ids"):
		for school_id_variant in _authority.call("get_disturbed_school_ids"):
			var school_id := str(school_id_variant)
			if not school_id.is_empty() and not samples_by_id.has(school_id):
				var school := get_school(school_id)
				if not school.is_empty():
					schools.append(school)
	for school in schools:
		var school_id := str(school.get("school_id", ""))
		if school_id.is_empty() or samples_by_id.has(school_id):
			continue
		var position := _position_from_school(school)
		if not _is_finite_vector3(position):
			continue
		var surface_y := boat_surface_y
		if _wave_sampler != null:
			var surface_sample := _wave_sampler.sample_physics_surface(Vector3(position.x, 0.0, position.z), wave_time)
			surface_y = _finite_or(float(surface_sample.get("height", boat_surface_y)), boat_surface_y)
		samples_by_id[school_id] = {
			"school_id": school_id,
			"surface_height_m": surface_y,
			"effective_activity_depth_m": float(school.get("effective_activity_depth_m", school.get("activity_depth_m", 0.0))),
		}
	var samples: Array[Dictionary] = []
	for sample_variant in samples_by_id.values():
		samples.append(sample_variant)
	if _authority.has_method("update_school_disturbance"):
		_authority.call("update_school_disturbance", vessel_snapshot, samples, delta_real_seconds, _disturbance_config())


func get_school_disturbance_config() -> Dictionary:
	return _disturbance_config()


func _disturbance_config() -> Dictionary:
	return {
		"horizontal_falloff_m": disturbance_horizontal_falloff_m,
		"vertical_falloff_m": disturbance_vertical_falloff_m,
		"rise_time_constant_s": disturbance_rise_time_constant_s,
		"fall_time_constant_s": disturbance_fall_time_constant_s,
		"alert_enter_level": disturbance_alert_enter_level,
		"alert_exit_level": disturbance_alert_exit_level,
		"flee_enter_level": disturbance_flee_enter_level,
		"flee_exit_level": disturbance_flee_exit_level,
		"flee_strong_duration_s": disturbance_flee_duration_s,
		"bite_willingness_calm": disturbance_bite_willingness_calm,
		"bite_willingness_alert": disturbance_bite_willingness_alert,
		"bite_willingness_fleeing": disturbance_bite_willingness_fleeing,
		"engine_off_stationary": engine_off_stationary_disturbance,
		"engine_off_drifting": engine_off_drift_disturbance,
		"engine_off_movement_max": engine_off_max_movement_disturbance,
		"engine_idle": engine_idle_disturbance,
		"engine_low_speed": engine_low_speed_disturbance,
		"engine_cruise": engine_cruise_disturbance,
		"engine_high_speed": engine_high_speed_disturbance,
		"engine_idle_speed_mps": engine_idle_speed_mps,
		"engine_low_speed_end_mps": engine_low_speed_end_mps,
		"engine_cruise_speed_end_mps": engine_cruise_speed_end_mps,
		"engine_high_speed_end_mps": engine_high_speed_end_mps,
		"engine_off_full_movement_speed_mps": engine_off_full_movement_speed_mps,
		"off_still_speed_mps": disturbance_still_speed_mps,
	}


func _position_from_school(school: Dictionary) -> Vector3:
	var values: Variant = school.get("world_position", [])
	if values is Array and values.size() >= 3:
		var position := Vector3(float(values[0]), float(values[1]), float(values[2]))
		if _is_finite_vector3(position):
			return position
	return Vector3(NAN, NAN, NAN)


func _is_finite_vector3(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)


func _numeric_property(object: Object, property_name: String, fallback: float) -> float:
	for property_info in object.get_property_list():
		if str(property_info.get("name", "")) == property_name:
			return _finite_or(float(object.get(property_name)), fallback)
	return fallback


func _finite_or(value: float, fallback: float) -> float:
	return value if is_finite(value) else fallback


func _finite_bool(value: Variant) -> bool:
	return bool(value) if typeof(value) == TYPE_BOOL else false


func get_species_profiles() -> Array[FishSpeciesProfile]:
	return species_profiles.duplicate()


## A future network bootstrap may install a server-backed adapter here. The
## renderer and map keep using the same snapshot/query interface.
func set_authority_adapter(adapter: FishAuthorityAdapter) -> bool:
	if adapter == null or _bathymetry == null or _georeference == null:
		return false
	_authority = adapter
	_initialize_authority(_authority)
	_last_revision = _authority.get_state_revision()
	resources_changed.emit(_last_revision)
	return true


func get_species_profile(species_id: String) -> FishSpeciesProfile:
	for profile in species_profiles:
		if profile.species_id == species_id:
			return profile
	return null


func get_school(school_id: String) -> Dictionary:
	return _authority.get_school(school_id) if _authority != null else {}


func get_all_school_snapshots() -> Array[Dictionary]:
	return _authority.get_all_school_snapshots() if _authority != null else []


func get_schools_near(world_position: Vector3, radius_m: float, include_unavailable: bool = false) -> Array[Dictionary]:
	return _authority.get_schools_near(world_position, radius_m, include_unavailable) if _authority != null else []


func evaluate_ambient_fishing_candidates(context: Dictionary) -> Dictionary:
	if _authority == null:
		return {"candidates": [], "reason": "fish_authority_unavailable", "environment_quality": 0.0}
	return _authority.evaluate_ambient_fishing_candidates(context)


func request_ambient_fish_encounter(context: Dictionary) -> Dictionary:
	if _authority == null:
		return {"accepted": false, "reason": "fish_authority_unavailable"}
	var result := _authority.request_ambient_fish_encounter(context)
	if bool(result.get("accepted", false)):
		_last_revision = _authority.get_state_revision()
		resources_changed.emit(_last_revision)
	return result


func get_ambient_fish_encounter(ambient_fish_id: String) -> Dictionary:
	return _authority.get_ambient_fish_encounter(ambient_fish_id) if _authority != null else {}


func confirm_ambient_fish_encounter(ambient_fish_id: String, fishing_session_id: String, hook_index: int) -> bool:
	if _authority == null:
		return false
	var accepted := _authority.confirm_ambient_fish_encounter(ambient_fish_id, fishing_session_id, hook_index)
	if accepted:
		_last_revision = _authority.get_state_revision()
		resources_changed.emit(_last_revision)
	return accepted


func release_ambient_fish_encounter(ambient_fish_id: String, reason: String = "cancelled") -> bool:
	if _authority == null:
		return false
	var released := _authority.release_ambient_fish_encounter(ambient_fish_id, reason)
	if released:
		_last_revision = _authority.get_state_revision()
		resources_changed.emit(_last_revision)
	return released


func release_ambient_fishing_session(fishing_session_id: String, reason: String = "session_ended") -> int:
	if _authority == null or fishing_session_id.is_empty():
		return 0
	var released := _authority.release_ambient_fishing_session(fishing_session_id, reason)
	if released > 0:
		_last_revision = _authority.get_state_revision()
		resources_changed.emit(_last_revision)
	return released


func settle_ambient_fish_encounter(ambient_fish_id: String) -> Dictionary:
	if _authority == null:
		return {"accepted": false, "reason": "fish_authority_unavailable"}
	var result := _authority.settle_ambient_fish_encounter(ambient_fish_id)
	if bool(result.get("accepted", false)):
		_last_revision = _authority.get_state_revision()
		resources_changed.emit(_last_revision)
	return result


func settle_boat_fishing_catch_batch(school_changes: Dictionary, ambient_fish_ids: Array[String]) -> Dictionary:
	if _authority == null:
		return {"accepted": false, "reason": "fish_authority_unavailable"}
	var result := _authority.settle_boat_fishing_catch_batch(school_changes, ambient_fish_ids, _world_game_time_seconds())
	if bool(result.get("accepted", false)):
		_last_revision = _authority.get_state_revision()
		resources_changed.emit(_last_revision)
	return result


func get_ambient_fish_session_snapshot(fishing_session_id: String) -> Array[Dictionary]:
	return _authority.get_ambient_fish_session_snapshot(fishing_session_id) if _authority != null else []


## Map visibility is intentionally labelled as an ecological prediction.
## There is no exploration/sonar system in this prototype.
func get_map_distribution(species_ids: Array[String] = []) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if _authority != null:
		result = _authority.get_map_snapshot(species_ids)
	for item in result:
		item["visibility"] = "predicted"
		item["render_state"] = get_school_render_state(item)
	return result


func get_school_render_state(school: Dictionary) -> String:
	var species_id := str(school.get("species_id", ""))
	var profile := get_species_profile(species_id)
	if profile == null:
		return "visual"
	if not profile.visual_enabled:
		return "logical"
	if not profile.surface_activity_cycle_enabled:
		return "visual"
	return "visual" if float(school.get("effective_activity_depth_m", school.get("activity_depth_m", INF))) <= profile.logical_depth_threshold_m else "logical"


func get_resource_density_at(world_position: Vector3, species_id: String = "") -> Dictionary:
	var depth_data := _bathymetry.get_depth_at_world_position(world_position) if _bathymetry != null else {"valid": false}
	if not bool(depth_data.get("valid", false)):
		return {"valid": false, "density": 0.0, "reason": str(depth_data.get("reason", "No bathymetry"))}
	var matching := 0
	var population := 0
	for school in get_schools_near(world_position, 1200.0):
		if not species_id.is_empty() and str(school["species_id"]) != species_id:
			continue
		matching += 1
		population += int(school["population"])
	return {"valid": true, "density": matching, "population": population, "depth_m": float(depth_data["depth_m"]), "source": str(depth_data.get("source", ""))}


## Resource changes route through the active authority adapter. A future client
## adapter must turn this call into a server request instead of mutating state.
func request_population_change(school_id: String, population_delta: int) -> Dictionary:
	if _authority == null:
		return {"accepted": false, "reason": "No active fish authority."}
	var result := _authority.request_population_change(school_id, population_delta, _world_game_time_seconds())
	if bool(result.get("accepted", false)):
		_last_revision = _authority.get_state_revision()
		resources_changed.emit(_last_revision)
	return result


func request_population_changes(changes: Dictionary) -> Dictionary:
	if _authority == null:
		return {"accepted": false, "reason": "No active fish authority."}
	var result := _authority.request_population_changes(changes, _world_game_time_seconds())
	if bool(result.get("accepted", false)):
		_last_revision = _authority.get_state_revision()
		resources_changed.emit(_last_revision)
	return result


func create_authority_snapshot() -> Dictionary:
	if _authority == null:
		return {}
	var snapshot := _authority.create_snapshot()
	snapshot["authority_source"] = _authority.authority_source_name()
	snapshot["authoritative_timestamp"] = int(Time.get_unix_time_from_system())
	return snapshot


func apply_authority_snapshot(snapshot: Dictionary) -> bool:
	if _authority == null or not ["Local", "Server"].has(str(snapshot.get("authority_source", ""))):
		return false
	if int(snapshot.get("state_revision", -1)) < _last_revision:
		return false
	if not _authority.restore_snapshot(snapshot):
		return false
	_last_revision = _authority.get_state_revision()
	resources_changed.emit(_last_revision)
	return true


func get_state_revision() -> int:
	return _authority.get_state_revision() if _authority != null else 0


func get_world_seed() -> int:
	return _authority.get_world_seed() if _authority != null else world_seed


func get_authority_source() -> String:
	return _authority.authority_source_name() if _authority != null else "Unavailable"


func get_bathymetry_manager() -> BathymetryManager:
	return _bathymetry


func get_georeference() -> GeoReference:
	return _georeference


func get_boat() -> Node3D:
	return _boat


func get_wave_sampler() -> WaveSampler:
	return _wave_sampler


func get_fishing_encounter_system() -> FishingEncounterSystem:
	return _fishing_encounter_system


func get_fish_finder_sensor() -> FishFinderSensor:
	return _fish_finder_sensor


## Absolute simulation time in game seconds. Fishing cadence uses this instead
## of render delta, so pause and time acceleration follow the shared world clock.
func get_world_game_time_seconds() -> float:
	return _world_game_time_seconds()


func _load_default_profiles() -> void:
	for path in [
		"res://resources/fish_species/needlefish.tres",
		"res://resources/fish_species/herring.tres",
		"res://resources/fish_species/three_spined_stickleback.tres",
		"res://resources/fish_species/sea_trout.tres",
	]:
		var profile := ResourceLoader.load(path) as FishSpeciesProfile
		if profile != null:
			species_profiles.append(profile)


func _initialize_authority(adapter: FishAuthorityAdapter) -> void:
	adapter.initialize(world_seed, _bathymetry, _georeference, species_profiles, _world_game_time_seconds())


func _world_game_time_seconds() -> float:
	if _world_time_manager == null:
		return 0.0
	var time_state: Variant = _world_time_manager.get("state")
	if time_state == null:
		return 0.0
	return maxf(0.0, float(time_state.get("day_cycle_index")) * 86400.0 + float(time_state.get("cycle_seconds")))
