class_name FishLocalAuthority
extends "res://scripts/fish_authority_adapter.gd"

## Single-player implementation of the future server authority adapter.
## Initial placement depends only on world seed, habitat data, and layout version.

const LAYOUT_VERSION := 3
const DEFAULT_WORLD_SEED := 20261016
const RESOURCE_CELL_M := 700.0
const SIMULATION_STEP_SECONDS := 8.0
const SCHOOL_UPDATES_PER_FRAME := 96
const SEAGRASS_GENERATOR := preload("res://scripts/shallow_seagrass_generator.gd")
const SEAGRASS_SEED := 771903
const SEAGRASS_PATCH_CELL_M := 22.0

var _seed := DEFAULT_WORLD_SEED
var _bathymetry: BathymetryManager
var _georeference: GeoReference
var _profiles_by_id: Dictionary = {}
var _schools: Dictionary = {}
var _schools_by_cell: Dictionary = {}
var _pending_school_ids: Array[String] = []
var _school_update_cursor := 0
var _pending_batch_changed := false
var _step_accumulator := 0.0
var _simulation_seconds := 0.0
var _state_revision := 1


func authority_source_name() -> String:
	return "Local"


func initialize(seed: int, bathymetry: BathymetryManager, georeference: GeoReference, profiles: Array[FishSpeciesProfile]) -> void:
	_seed = seed
	_bathymetry = bathymetry
	_georeference = georeference
	_profiles_by_id.clear()
	_schools_by_cell.clear()
	_pending_school_ids.clear()
	_school_update_cursor = 0
	_pending_batch_changed = false
	for profile in profiles:
		_profiles_by_id[profile.species_id] = profile
	_generate_initial_schools()


func update(delta: float) -> void:
	_step_accumulator += maxf(delta, 0.0)
	if _pending_school_ids.is_empty() and _step_accumulator >= SIMULATION_STEP_SECONDS:
		_step_accumulator -= SIMULATION_STEP_SECONDS
		_simulation_seconds += SIMULATION_STEP_SECONDS
		for school_id in _schools.keys():
			_pending_school_ids.append(str(school_id))
		_school_update_cursor = 0
		_pending_batch_changed = false
	if not _pending_school_ids.is_empty():
		_advance_schools(SIMULATION_STEP_SECONDS)


func get_school(school_id: String) -> Dictionary:
	var state: FishSchoolState = _schools.get(school_id)
	return state.to_dictionary() if state != null else {}


func get_all_school_snapshots() -> Array[Dictionary]:
	var snapshots: Array[Dictionary] = []
	for school_id in _schools.keys():
		var state: FishSchoolState = _schools[school_id]
		if state.population > 0 and state.resource_state == "available":
			snapshots.append(state.to_dictionary())
	return snapshots


func get_schools_near(world_position: Vector3, radius_m: float) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var radius_squared := radius_m * radius_m
	var center_cell := _position_cell(world_position)
	var cell_range := ceili(radius_m / RESOURCE_CELL_M)
	for north_offset in range(-cell_range, cell_range + 1):
		for east_offset in range(-cell_range, cell_range + 1):
			var cell := center_cell + Vector2i(east_offset, north_offset)
			for school_id in _schools_by_cell.get(cell, []):
				var state: FishSchoolState = _schools.get(school_id)
				if state == null or state.population <= 0 or state.resource_state != "available":
					continue
				var dx := state.world_position.x - world_position.x
				var dz := state.world_position.z - world_position.z
				if dx * dx + dz * dz <= radius_squared:
					result.append(state.to_dictionary())
	return result


func get_map_snapshot(species_ids: Array[String] = []) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var filter_enabled := not species_ids.is_empty()
	for snapshot in get_all_school_snapshots():
		if not filter_enabled or species_ids.has(str(snapshot["species_id"])):
			result.append(snapshot)
	return result


func request_population_change(school_id: String, population_delta: int) -> Dictionary:
	if population_delta >= 0:
		return {"accepted": false, "reason": "Local resource updates only permit population reductions."}
	var state: FishSchoolState = _schools.get(school_id)
	if state == null or state.resource_state != "available":
		return {"accepted": false, "reason": "School is unavailable."}
	state.population = maxi(0, state.population + population_delta)
	if state.population == 0:
		state.resource_state = "depleted"
	state.last_updated_unix = int(Time.get_unix_time_from_system())
	_state_revision += 1
	return {"accepted": true, "population": state.population, "state_revision": _state_revision}


func create_snapshot() -> Dictionary:
	var schools: Array[Dictionary] = []
	for state in _schools.values():
		schools.append((state as FishSchoolState).to_dictionary())
	return {
		"schema_version": 1,
		"layout_version": LAYOUT_VERSION,
		"world_seed": _seed,
		"state_revision": _state_revision,
		"simulation_seconds": _simulation_seconds,
		"schools": schools,
	}


func restore_snapshot(snapshot: Dictionary) -> bool:
	if int(snapshot.get("schema_version", -1)) != 1 or int(snapshot.get("layout_version", -1)) != LAYOUT_VERSION:
		return false
	if int(snapshot.get("world_seed", _seed)) != _seed:
		return false
	var saved_schools: Variant = snapshot.get("schools", [])
	if not saved_schools is Array:
		return false
	var restored: Dictionary = {}
	for data in saved_schools:
		if not data is Dictionary:
			return false
		var state := FishSchoolState.from_dictionary(data)
		if state == null or not _profiles_by_id.has(state.species_id):
			return false
		restored[state.school_id] = state
	_schools = restored
	_rebuild_spatial_index()
	_pending_school_ids.clear()
	_school_update_cursor = 0
	_pending_batch_changed = false
	_simulation_seconds = maxf(0.0, float(snapshot.get("simulation_seconds", 0.0)))
	_state_revision = maxi(1, int(snapshot.get("state_revision", 1)))
	return true


func get_state_revision() -> int:
	return _state_revision


func get_world_seed() -> int:
	return _seed


func _generate_initial_schools() -> void:
	_schools.clear()
	if _bathymetry == null or _georeference == null or not _bathymetry.data_available:
		return
	var bounds := _georeference.region_bounds_east_north()
	var first_cell := Vector2i(floori(bounds.position.x / RESOURCE_CELL_M), floori(bounds.position.y / RESOURCE_CELL_M))
	var last_cell := Vector2i(floori(bounds.end.x / RESOURCE_CELL_M), floori(bounds.end.y / RESOURCE_CELL_M))
	for cell_north in range(first_cell.y, last_cell.y + 1):
		for cell_east in range(first_cell.x, last_cell.x + 1):
			var cell := Vector2i(cell_east, cell_north)
			var east := (float(cell.x) + 0.5 + (hash01(cell.x, cell.y, _seed + 17) - 0.5) * 0.58) * RESOURCE_CELL_M
			var north := (float(cell.y) + 0.5 + (hash01(cell.x, cell.y, _seed + 29) - 0.5) * 0.58) * RESOURCE_CELL_M
			var world_position := Vector3(east, 0.0, -north)
			var sample := _bathymetry.get_depth_at_world_position(world_position)
			if not bool(sample.get("valid", false)):
				continue
			var depth := float(sample.get("depth_m", 0.0))
			for profile_value in _profiles_by_id.values():
				var profile := profile_value as FishSpeciesProfile
				var suitability: float = profile.suitability_for_depth(depth)
				if suitability <= 0.04:
					continue
				var seagrass_weight := 0.0
				if profile.eelgrass_spawn_boost > 0.0:
					seagrass_weight = _seagrass_weight_at(east, north)
				var vegetation_factor: float
				if profile.species_id == "three_spined_stickleback":
					# Sticklebacks use the vegetation edge as cover but are less likely
					# to spawn in the densest canopy where the school is hard to see.
					var edge_suitability := 1.0 - absf(seagrass_weight - 0.46) / 0.54
					vegetation_factor = 0.76 + clampf(edge_suitability, 0.0, 1.0) * profile.eelgrass_spawn_boost
				else:
					vegetation_factor = 1.0 + seagrass_weight * profile.eelgrass_spawn_boost
				var roll := hash01(cell.x, cell.y, _seed + 1009 + profile.species_index * 9973)
				if roll > profile.spawn_chance * suitability * vegetation_factor:
					continue
				var state := _create_school(cell, east, north, depth, profile, seagrass_weight)
				_schools[state.school_id] = state
	_rebuild_spatial_index()
	_state_revision = 1
	print("[FishResourceManager] Local authority generated %d deterministic schools (seed %d, layout v%d)." % [_schools.size(), _seed, LAYOUT_VERSION])


func _create_school(cell: Vector2i, east: float, north: float, depth: float, profile: FishSpeciesProfile, seagrass_weight: float) -> FishSchoolState:
	var state := FishSchoolState.new()
	state.school_id = "%s_v%d_%d_%d" % [profile.species_id, LAYOUT_VERSION, cell.x, cell.y]
	state.species_id = profile.species_id
	state.world_position = Vector3(east, 0.0, -north)
	state.depth_m = depth
	state.habitat_region = _habitat_region_for_depth(depth, seagrass_weight)
	state.seed = hash32(cell.x, cell.y, _seed + profile.species_index * 8191)
	var rng := RandomNumberGenerator.new()
	rng.seed = state.seed
	state.population = _initial_population_for_species(profile, rng)
	state.direction_radians = rng.randf_range(-PI, PI)
	state.movement_speed_mps = rng.randf_range(profile.movement_speed_min_mps, profile.movement_speed_max_mps)
	state.movement_state = "schooling" if profile.species_id == "herring" else "cruise"
	if profile.species_id in ["needlefish", "herring"]:
		_initialize_surface_activity(state, profile, rng)
	state.resource_state = "available"
	state.last_updated_unix = int(Time.get_unix_time_from_system())
	return state


func _initial_population_for_species(profile: FishSpeciesProfile, rng: RandomNumberGenerator) -> int:
	if profile.species_id != "three_spined_stickleback":
		return rng.randi_range(profile.population_min, profile.population_max)
	# Most stickleback resources are small-to-medium schools; a smaller fraction
	# are sparse groups or larger shoals. The same cell seed always gives the same
	# population on the local authority and a future server implementation.
	var tier := rng.randf()
	if tier < 0.15:
		return rng.randi_range(5, 10)
	if tier < 0.90:
		return rng.randi_range(12, 25)
	return rng.randi_range(26, 40)


func _advance_schools(step: float) -> void:
	if _bathymetry == null:
		return
	var changed := false
	var end_cursor := mini(_school_update_cursor + SCHOOL_UPDATES_PER_FRAME, _pending_school_ids.size())
	for cursor in range(_school_update_cursor, end_cursor):
		var state: FishSchoolState = _schools.get(_pending_school_ids[cursor])
		if state == null:
			continue
		if state.population <= 0 or state.resource_state != "available":
			continue
		changed = _advance_school(state, step) or changed
	_school_update_cursor = end_cursor
	_pending_batch_changed = _pending_batch_changed or changed
	if _school_update_cursor >= _pending_school_ids.size():
		_pending_school_ids.clear()
		_school_update_cursor = 0
		if _pending_batch_changed:
			_state_revision += 1
		_pending_batch_changed = false


func _advance_school(state: FishSchoolState, step: float) -> bool:
	var profile: FishSpeciesProfile = _profiles_by_id[state.species_id]
	if state.species_id in ["needlefish", "herring"]:
		_advance_surface_activity(state, profile, step)
	var target_heading: float = state.direction_radians + sin(_simulation_seconds * 0.012 + float(state.seed & 1023)) * 0.025
	var drift_speed: float = state.movement_speed_mps * 0.16
	var direction := Vector2(cos(target_heading), sin(target_heading))
	var candidate: Vector3 = state.world_position + Vector3(direction.x, 0.0, -direction.y) * drift_speed * step
	var sample := _bathymetry.get_depth_at_world_position(candidate)
	var candidate_depth := float(sample.get("depth_m", 0.0))
	if bool(sample.get("valid", false)) and profile.suitability_for_depth(candidate_depth) > 0.025:
		var old_cell := _position_cell(state.world_position)
		state.world_position = candidate
		var new_cell := _position_cell(candidate)
		if old_cell != new_cell:
			_move_school_to_cell(state.school_id, old_cell, new_cell)
		state.depth_m = candidate_depth
		if not (state.species_id == "three_spined_stickleback" and candidate_depth <= 6.0 and state.habitat_region in ["coastal_eelgrass_edge", "coastal_eelgrass_proxy"]):
			state.habitat_region = _habitat_region_for_depth(candidate_depth)
		state.direction_radians = lerp_angle(state.direction_radians, target_heading, 0.18)
	else:
		state.direction_radians = wrapf(state.direction_radians + (0.9 + hash01(state.seed, int(_simulation_seconds), _seed) * 1.8), -PI, PI)
	state.last_updated_unix = int(Time.get_unix_time_from_system())
	return true


func _initialize_surface_activity(state: FishSchoolState, profile: FishSpeciesProfile, rng: RandomNumberGenerator) -> void:
	state.surface_activity_cycle_index = 0
	var max_depth := maxf(0.5, state.depth_m - 1.0)
	var surface_depth := _sample_surface_depth(profile, rng, max_depth)
	var deep_depth := _sample_deep_depth(profile, rng, max_depth)
	if rng.randf() < profile.surface_activity_time_share:
		state.surface_activity_state = "near_surface"
		state.activity_depth_m = surface_depth
		state.activity_depth_target_m = surface_depth
		state.surface_activity_remaining_seconds = _surface_duration(profile, state.seed, 0)
	else:
		state.surface_activity_state = "deep"
		state.activity_depth_m = deep_depth
		state.activity_depth_target_m = deep_depth
		state.surface_activity_remaining_seconds = _deep_duration(profile, state.seed, 0)
	_set_activity_movement_label(state, profile)


func _advance_surface_activity(state: FishSchoolState, profile: FishSpeciesProfile, step: float) -> void:
	var max_depth := maxf(0.5, state.depth_m - 0.8)
	state.activity_depth_target_m = minf(state.activity_depth_target_m, max_depth)
	state.activity_depth_m = minf(state.activity_depth_m, max_depth)
	var activity_state := state.surface_activity_state
	state.surface_activity_remaining_seconds = maxf(0.0, state.surface_activity_remaining_seconds - step)
	if activity_state == "near_surface" and state.surface_activity_remaining_seconds <= 0.0:
		state.surface_activity_state = "descending"
		state.activity_depth_target_m = _deep_depth_for_cycle(profile, state.seed, state.surface_activity_cycle_index, max_depth)
	elif activity_state == "deep" and state.surface_activity_remaining_seconds <= 0.0:
		state.surface_activity_cycle_index += 1
		state.surface_activity_state = "ascending"
		state.activity_depth_target_m = _surface_depth_for_cycle(profile, state.seed, state.surface_activity_cycle_index, max_depth)
	var transition_speed := profile.activity_vertical_speed_mps * step
	state.activity_depth_m = move_toward(state.activity_depth_m, state.activity_depth_target_m, transition_speed)
	if state.surface_activity_state == "ascending" and absf(state.activity_depth_m - state.activity_depth_target_m) <= 0.05:
		state.surface_activity_state = "near_surface"
		state.surface_activity_remaining_seconds = _surface_duration(profile, state.seed, state.surface_activity_cycle_index)
	elif state.surface_activity_state == "descending" and absf(state.activity_depth_m - state.activity_depth_target_m) <= 0.05:
		state.surface_activity_state = "deep"
		state.surface_activity_remaining_seconds = _deep_duration(profile, state.seed, state.surface_activity_cycle_index)
	_set_activity_movement_label(state, profile)


func _surface_depth_for_cycle(profile: FishSpeciesProfile, seed: int, cycle: int, max_depth: float) -> float:
	var value := hash01(seed, cycle, _seed + profile.species_index * 104729 + 31)
	return minf(lerpf(profile.surface_activity_depth_m.x, profile.surface_activity_depth_m.y, value), max_depth)


func _deep_depth_for_cycle(profile: FishSpeciesProfile, seed: int, cycle: int, max_depth: float) -> float:
	var value := hash01(seed, cycle, _seed + profile.species_index * 104729 + 67)
	return minf(lerpf(profile.deep_activity_depth_m.x, profile.deep_activity_depth_m.y, value), max_depth)


func _sample_surface_depth(profile: FishSpeciesProfile, rng: RandomNumberGenerator, max_depth: float) -> float:
	return minf(rng.randf_range(profile.surface_activity_depth_m.x, profile.surface_activity_depth_m.y), max_depth)


func _sample_deep_depth(profile: FishSpeciesProfile, rng: RandomNumberGenerator, max_depth: float) -> float:
	return minf(rng.randf_range(profile.deep_activity_depth_m.x, profile.deep_activity_depth_m.y), max_depth)


func _surface_duration(profile: FishSpeciesProfile, seed: int, cycle: int) -> float:
	var value := hash01(seed, cycle, _seed + profile.species_index * 65537 + 101)
	return lerpf(profile.surface_activity_duration_seconds.x, profile.surface_activity_duration_seconds.y, value)


func _deep_duration(profile: FishSpeciesProfile, seed: int, cycle: int) -> float:
	var surface_duration := _surface_duration(profile, seed, cycle)
	var share := clampf(profile.surface_activity_time_share, 0.05, 0.95)
	var variation := lerpf(0.82, 1.18, hash01(seed, cycle, _seed + profile.species_index * 65537 + 131))
	return surface_duration * ((1.0 - share) / share) * variation


func _set_activity_movement_label(state: FishSchoolState, profile: FishSpeciesProfile) -> void:
	var prefix := "surface_schooling" if profile.species_id == "herring" else "surface_cruise"
	var suffix := "deep_schooling" if profile.species_id == "herring" else "deep_cruise"
	if state.surface_activity_state in ["near_surface", "ascending"]:
		state.movement_state = prefix if state.surface_activity_state == "near_surface" else "ascending"
	else:
		state.movement_state = suffix if state.surface_activity_state == "deep" else "descending"


func _habitat_region_for_depth(depth: float, seagrass_weight: float = 0.0) -> String:
	if depth <= 6.0 and seagrass_weight >= 0.18:
		if seagrass_weight < 0.62:
			return "coastal_eelgrass_edge"
		return "coastal_eelgrass_proxy"
	if depth <= 5.0:
		return "coastal_shallow"
	if depth <= 20.0:
		return "nearshore_shelf"
	return "open_shelf"


func _seagrass_weight_at(east: float, north: float) -> float:
	# Reuse the exact world-space meadow layout used by ShallowSeabedManager,
	# but build only the small neighborhood needed by this resource candidate.
	const SEARCH_RADIUS_M := 55.0
	var patches := SEAGRASS_GENERATOR.build_patch_centers(
		east - SEARCH_RADIUS_M, north - SEARCH_RADIUS_M,
		east + SEARCH_RADIUS_M, north + SEARCH_RADIUS_M,
		SEAGRASS_PATCH_CELL_M, SEAGRASS_SEED, 1.0
	)
	var lookup := SEAGRASS_GENERATOR.build_patch_lookup(patches)
	return SEAGRASS_GENERATOR.patch_weight(east, north, lookup, SEAGRASS_PATCH_CELL_M, 1.0)


func _position_cell(position: Vector3) -> Vector2i:
	return Vector2i(floori(position.x / RESOURCE_CELL_M), floori(-position.z / RESOURCE_CELL_M))


func _rebuild_spatial_index() -> void:
	_schools_by_cell.clear()
	for school_id in _schools.keys():
		_add_school_to_cell(str(school_id), _position_cell((_schools[school_id] as FishSchoolState).world_position))


func _move_school_to_cell(school_id: String, old_cell: Vector2i, new_cell: Vector2i) -> void:
	var old_schools: Array = _schools_by_cell.get(old_cell, [])
	old_schools.erase(school_id)
	if old_schools.is_empty():
		_schools_by_cell.erase(old_cell)
	else:
		_schools_by_cell[old_cell] = old_schools
	_add_school_to_cell(school_id, new_cell)


func _add_school_to_cell(school_id: String, cell: Vector2i) -> void:
	if not _schools_by_cell.has(cell):
		_schools_by_cell[cell] = []
	var cell_schools: Array = _schools_by_cell[cell]
	cell_schools.append(school_id)


static func hash01(x: int, y: int, seed: int) -> float:
	return float(hash32(x, y, seed)) / 2147483647.0


static func hash32(x: int, y: int, seed: int) -> int:
	var value: int = (x * 374761393 + y * 668265263 + seed * 1442695041) & 0x7fffffff
	value = ((value ^ (value >> 13)) * 1274126177) & 0x7fffffff
	return (value ^ (value >> 16)) & 0x7fffffff
