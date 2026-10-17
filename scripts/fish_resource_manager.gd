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

var _bathymetry: BathymetryManager
var _shallow_seabed_manager: ShallowSeabedManager
var _georeference: GeoReference
var _boat: Node3D
var _wave_sampler: WaveSampler
var _authority: FishAuthorityAdapter
var _renderer: FishSchoolRenderer
var _map_layer: FishResourceMap
var _last_revision := -1
var _map_refresh_elapsed := 0.0


func _ready() -> void:
	add_to_group("fish_resource_manager")
	_bathymetry = get_node_or_null(bathymetry_manager_path) as BathymetryManager
	_shallow_seabed_manager = get_node_or_null(shallow_seabed_manager_path) as ShallowSeabedManager
	_boat = get_node_or_null(boat_path) as Node3D
	_wave_sampler = get_node_or_null(wave_sampler_path) as WaveSampler
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
	_last_revision = _authority.get_state_revision()
	resources_ready.emit()
	resources_changed.emit(_last_revision)


func _process(delta: float) -> void:
	if _authority == null:
		return
	_authority.update(delta)
	var revision := _authority.get_state_revision()
	if revision != _last_revision:
		_last_revision = revision
		resources_changed.emit(revision)
	_map_refresh_elapsed += delta
	if _map_refresh_elapsed >= 2.0:
		_map_refresh_elapsed = fmod(_map_refresh_elapsed, 2.0)
		if _map_layer != null and _map_layer.is_map_open():
			_map_layer.refresh_data()


func _unhandled_key_input(event: InputEvent) -> void:
	if event is not InputEventKey or not event.pressed or event.echo:
		return
	if event.physical_keycode == KEY_F4 and _map_layer != null:
		_map_layer.set_map_open(not _map_layer.is_map_open())
		get_viewport().set_input_as_handled()


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


func get_schools_near(world_position: Vector3, radius_m: float) -> Array[Dictionary]:
	return _authority.get_schools_near(world_position, radius_m) if _authority != null else []


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
	if species_id not in ["needlefish", "herring"]:
		return "visual"
	return "visual" if float(school.get("activity_depth_m", INF)) <= 6.0 else "logical"


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
	var result := _authority.request_population_change(school_id, population_delta)
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


## A server adapter can pass one shared ship-threat snapshot to all clients.
## In the current local-authority prototype, the renderer samples the player
## boat and nodes in its configured disturbance-source group instead.
func set_authoritative_disturbance_snapshot(sources: Array[Dictionary]) -> bool:
	if _renderer == null:
		return false
	_renderer.set_authoritative_disturbance_snapshot(sources)
	return true


func use_local_disturbance_sources() -> void:
	if _renderer != null:
		_renderer.use_local_disturbance_sources()


func _load_default_profiles() -> void:
	for path in [
		"res://resources/fish_species/needlefish.tres",
		"res://resources/fish_species/herring.tres",
		"res://resources/fish_species/three_spined_stickleback.tres",
	]:
		var profile := ResourceLoader.load(path) as FishSpeciesProfile
		if profile != null:
			species_profiles.append(profile)


func _initialize_authority(adapter: FishAuthorityAdapter) -> void:
	adapter.initialize(world_seed, _bathymetry, _georeference, species_profiles)
