class_name FishLocalAuthority
extends "res://scripts/fish_authority_adapter.gd"

## Single-player implementation of the future server authority adapter.
## Initial placement depends only on world seed, habitat data, and layout version.

const LAYOUT_VERSION := 5
const SNAPSHOT_SCHEMA_VERSION := 3
const DEFAULT_WORLD_SEED := 20261016
const POPULATION_RECOVERY_RATE_PER_GAME_HOUR := 0.006
const SECONDS_PER_GAME_HOUR := 3600.0
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
var _species_seed_salt_by_id: Dictionary = {}
var _ordered_species_profiles: Array[FishSpeciesProfile] = []
var _schools: Dictionary = {}
var _schools_by_cell: Dictionary = {}
var _pending_school_ids: Array[String] = []
var _school_update_cursor := 0
var _pending_batch_changed := false
var _step_accumulator := 0.0
var _simulation_seconds := 0.0
var _current_game_time_seconds := 0.0
var _state_revision := 1


func authority_source_name() -> String:
	return "Local"


func initialize(seed: int, bathymetry: BathymetryManager, georeference: GeoReference, profiles: Array[FishSpeciesProfile], initial_game_time_seconds: float = 0.0) -> void:
	_seed = seed
	_current_game_time_seconds = maxf(0.0, initial_game_time_seconds) if is_finite(initial_game_time_seconds) else 0.0
	_bathymetry = bathymetry
	_georeference = georeference
	_profiles_by_id.clear()
	_species_seed_salt_by_id.clear()
	_ordered_species_profiles.clear()
	_schools_by_cell.clear()
	_pending_school_ids.clear()
	_school_update_cursor = 0
	_pending_batch_changed = false
	for profile in profiles:
		_profiles_by_id[profile.species_id] = profile
		_species_seed_salt_by_id[profile.species_id] = _stable_species_hash(profile.species_id)
		_ordered_species_profiles.append(profile)
	_ordered_species_profiles.sort_custom(func(a: FishSpeciesProfile, b: FishSpeciesProfile) -> bool:
		if a.species_index == b.species_index:
			return a.species_id < b.species_id
		return a.species_index < b.species_index
	)
	_generate_initial_schools()


func update(delta: float, game_time_seconds: float = -1.0) -> void:
	if is_finite(game_time_seconds) and game_time_seconds >= 0.0:
		_current_game_time_seconds = game_time_seconds
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


func request_population_change(school_id: String, population_delta: int, game_time_seconds: float = -1.0) -> Dictionary:
	if is_finite(game_time_seconds) and game_time_seconds >= 0.0:
		_current_game_time_seconds = game_time_seconds
	if population_delta >= 0:
		return {"accepted": false, "reason": "Local resource updates only permit population reductions."}
	var state: FishSchoolState = _schools.get(school_id)
	if state == null or state.resource_state != "available":
		return {"accepted": false, "reason": "School is unavailable."}
	var effective_population := float(state.population) + state.recovery_fractional_population
	effective_population = clampf(effective_population + float(population_delta), 0.0, float(state.baseline_population))
	state.population = floori(effective_population)
	state.recovery_fractional_population = effective_population - float(state.population)
	if state.population == 0:
		state.resource_state = "depleted"
	else:
		state.resource_state = "available"
	state.last_population_update_game_time_seconds = _current_game_time_seconds
	state.last_updated_unix = int(Time.get_unix_time_from_system())
	_state_revision += 1
	return {"accepted": true, "population": state.population, "state_revision": _state_revision}


func create_snapshot() -> Dictionary:
	var schools: Array[Dictionary] = []
	for state in _schools.values():
		schools.append((state as FishSchoolState).to_dictionary())
	return {
		"schema_version": SNAPSHOT_SCHEMA_VERSION,
		"layout_version": LAYOUT_VERSION,
		"species_profile_signature": _species_profile_signature(),
		"world_seed": _seed,
		"state_revision": _state_revision,
		"simulation_seconds": _simulation_seconds,
		"current_game_time_seconds": _current_game_time_seconds,
		"schools": schools,
	}


func restore_snapshot(snapshot: Dictionary) -> bool:
	if int(snapshot.get("schema_version", -1)) != SNAPSHOT_SCHEMA_VERSION or int(snapshot.get("layout_version", -1)) != LAYOUT_VERSION:
		return false
	if str(snapshot.get("species_profile_signature", "")) != _species_profile_signature():
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
	var saved_game_time := float(snapshot.get("current_game_time_seconds", _current_game_time_seconds))
	if is_finite(saved_game_time) and saved_game_time >= 0.0:
		_current_game_time_seconds = saved_game_time
	return true


func get_state_revision() -> int:
	return _state_revision


func _species_profile_signature() -> String:
	var rows: Array[String] = []
	var signature_profiles := _ordered_species_profiles.duplicate()
	signature_profiles.sort_custom(func(a: FishSpeciesProfile, b: FishSpeciesProfile) -> bool:
		return a.species_id < b.species_id
	)
	for profile in signature_profiles:
		var fields := PackedStringArray()
		fields.append(profile.species_id)
		fields.append(str(profile.minimum_depth_m))
		fields.append(str(profile.maximum_depth_m))
		fields.append(str(profile.preferred_depth_min_m))
		fields.append(str(profile.preferred_depth_max_m))
		fields.append(str(profile.spawn_chance))
		fields.append(str(profile.eelgrass_spawn_boost))
		fields.append(profile.vegetation_spawn_mode)
		fields.append(str(profile.population_min))
		fields.append(str(profile.population_max))
		fields.append(str(profile.school_size_ranges))
		fields.append(str(profile.school_size_band_weights))
		fields.append(str(profile.movement_speed_min_mps))
		fields.append(str(profile.movement_speed_max_mps))
		fields.append(profile.behavior_type)
		fields.append(str(profile.vertical_layer))
		fields.append(str(profile.surface_activity_cycle_enabled))
		fields.append(str(profile.surface_activity_time_share))
		fields.append(str(profile.surface_activity_depth_m))
		fields.append(str(profile.deep_activity_depth_m))
		fields.append(str(profile.surface_activity_duration_seconds))
		fields.append(str(profile.activity_vertical_speed_mps))
		fields.append(str(profile.preferred_swim_depth_m))
		fields.append(str(profile.flee_swim_depth_m))
		fields.append(str(profile.vertical_move_speed_mps))
		fields.append(str(profile.near_surface_visit_probability))
		fields.append(str(profile.near_surface_depth_m))
		fields.append(str(profile.school_activity_radius_m))
		fields.append(str(profile.minimum_water_column_m))
		fields.append(str(profile.initial_speed_factor))
		fields.append(str(profile.group_forward_bias))
		fields.append(str(profile.school_wander_radius_m))
		fields.append(str(profile.school_separation_distance_m))
		fields.append(str(profile.school_alignment_radius_m))
		fields.append(str(profile.school_cohesion_strength))
		fields.append(str(profile.school_alignment_strength))
		fields.append(str(profile.flee_radius_m))
		fields.append(str(profile.flee_speed_factor))
		fields.append(str(profile.scatter_radius_extension_factor))
		fields.append(str(profile.escape_acceleration_factor))
		fields.append(str(profile.turn_rate_radians_per_second))
		fields.append(str(profile.ordinary_acceleration_response))
		rows.append("|".join(fields))
	return "\n".join(PackedStringArray(rows))


static func _stable_species_hash(species_id: String) -> int:
	var value: int = 2166136261
	for byte_value in species_id.to_utf8_buffer():
		value = int((value ^ int(byte_value)) * 16777619) & 0x7fffffff
	return value


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
			for profile in _ordered_species_profiles:
				var suitability: float = profile.suitability_for_depth(depth)
				if suitability <= 0.04:
					continue
				var seagrass_weight := 0.0
				if profile.eelgrass_spawn_boost > 0.0:
					seagrass_weight = _seagrass_weight_at(east, north)
				var vegetation_factor: float
				if profile.vegetation_spawn_mode == "edge_preference":
					var edge_suitability := 1.0 - absf(seagrass_weight - 0.46) / 0.54
					vegetation_factor = 0.76 + clampf(edge_suitability, 0.0, 1.0) * profile.eelgrass_spawn_boost
				else:
					vegetation_factor = 1.0 + seagrass_weight * profile.eelgrass_spawn_boost
				var species_salt := int(_species_seed_salt_by_id.get(profile.species_id, 0))
				var roll := hash01(cell.x, cell.y, _seed + 1009 + species_salt * 9973)
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
	var species_salt := int(_species_seed_salt_by_id.get(profile.species_id, 0))
	state.seed = hash32(cell.x, cell.y, _seed + species_salt * 8191)
	var rng := RandomNumberGenerator.new()
	rng.seed = state.seed
	state.population = _initial_population_for_species(profile, rng)
	state.baseline_population = state.population
	state.last_population_update_game_time_seconds = _current_game_time_seconds
	state.direction_radians = rng.randf_range(-PI, PI)
	state.movement_speed_mps = rng.randf_range(profile.movement_speed_min_mps, profile.movement_speed_max_mps)
	state.movement_state = "schooling" if profile.behavior_type == "schooling_pelagic" else "cruise"
	if profile.surface_activity_cycle_enabled:
		_initialize_surface_activity(state, profile, rng)
	state.resource_state = "available"
	state.last_updated_unix = int(Time.get_unix_time_from_system())
	return state


func _initial_population_for_species(profile: FishSpeciesProfile, rng: RandomNumberGenerator) -> int:
	if profile.school_size_ranges.is_empty() or profile.school_size_band_weights.is_empty():
		return rng.randi_range(profile.population_min, profile.population_max)
	var total_weight := 0.0
	for weight in profile.school_size_band_weights:
		total_weight += maxf(0.0, weight)
	if total_weight <= 0.0:
		return rng.randi_range(profile.population_min, profile.population_max)
	var selection := rng.randf() * total_weight
	for index in range(profile.school_size_ranges.size()):
		var weight := maxf(0.0, profile.school_size_band_weights[index]) if index < profile.school_size_band_weights.size() else 0.0
		selection -= weight
		if selection <= 0.0:
			var band := profile.school_size_ranges[index]
			return rng.randi_range(maxi(profile.population_min, band.x), mini(profile.population_max, band.y))
	return rng.randi_range(profile.population_min, profile.population_max)


func _advance_schools(step: float) -> void:
	if _bathymetry == null:
		return
	var changed := false
	var end_cursor := mini(_school_update_cursor + SCHOOL_UPDATES_PER_FRAME, _pending_school_ids.size())
	for cursor in range(_school_update_cursor, end_cursor):
		var state: FishSchoolState = _schools.get(_pending_school_ids[cursor])
		if state == null:
			continue
		changed = _recover_school_population(state) or changed
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


func _recover_school_population(state: FishSchoolState) -> bool:
	if state.population >= state.baseline_population and state.recovery_fractional_population <= 0.0 and state.resource_state == "available":
		return false
	if _current_game_time_seconds < state.last_population_update_game_time_seconds:
		state.last_population_update_game_time_seconds = _current_game_time_seconds
		return true
	var elapsed_seconds := _current_game_time_seconds - state.last_population_update_game_time_seconds
	if elapsed_seconds <= 0.0:
		return false
	var elapsed_game_hours := elapsed_seconds / SECONDS_PER_GAME_HOUR
	var continuous_population := float(state.population) + state.recovery_fractional_population
	var baseline := float(state.baseline_population)
	var recovered_population := baseline - (baseline - continuous_population) * exp(-POPULATION_RECOVERY_RATE_PER_GAME_HOUR * elapsed_game_hours)
	recovered_population = clampf(recovered_population, continuous_population, baseline)
	if baseline - recovered_population <= 0.000001:
		recovered_population = baseline
	var new_population := mini(state.baseline_population, floori(recovered_population))
	var new_fraction := recovered_population - float(new_population)
	if new_population >= state.baseline_population:
		new_fraction = 0.0
	var old_population := state.population
	var old_fraction := state.recovery_fractional_population
	var old_resource_state := state.resource_state
	state.population = new_population
	state.recovery_fractional_population = clampf(new_fraction, 0.0, 0.999999999)
	state.resource_state = "available" if state.population > 0 else "depleted"
	state.last_population_update_game_time_seconds = _current_game_time_seconds
	return old_population != state.population or not is_equal_approx(old_fraction, state.recovery_fractional_population) or old_resource_state != state.resource_state or elapsed_seconds > 0.0


func _advance_school(state: FishSchoolState, step: float) -> bool:
	var profile: FishSpeciesProfile = _profiles_by_id[state.species_id]
	if profile.surface_activity_cycle_enabled:
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
		if not (profile.vegetation_spawn_mode == "edge_preference" and candidate_depth <= 6.0 and state.habitat_region in ["coastal_eelgrass_edge", "coastal_eelgrass_proxy"]):
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
	var species_salt := int(_species_seed_salt_by_id.get(profile.species_id, 0))
	var value := hash01(seed, cycle, _seed + species_salt * 104729 + 31)
	return minf(lerpf(profile.surface_activity_depth_m.x, profile.surface_activity_depth_m.y, value), max_depth)


func _deep_depth_for_cycle(profile: FishSpeciesProfile, seed: int, cycle: int, max_depth: float) -> float:
	var species_salt := int(_species_seed_salt_by_id.get(profile.species_id, 0))
	var value := hash01(seed, cycle, _seed + species_salt * 104729 + 67)
	return minf(lerpf(profile.deep_activity_depth_m.x, profile.deep_activity_depth_m.y, value), max_depth)


func _sample_surface_depth(profile: FishSpeciesProfile, rng: RandomNumberGenerator, max_depth: float) -> float:
	return minf(rng.randf_range(profile.surface_activity_depth_m.x, profile.surface_activity_depth_m.y), max_depth)


func _sample_deep_depth(profile: FishSpeciesProfile, rng: RandomNumberGenerator, max_depth: float) -> float:
	return minf(rng.randf_range(profile.deep_activity_depth_m.x, profile.deep_activity_depth_m.y), max_depth)


func _surface_duration(profile: FishSpeciesProfile, seed: int, cycle: int) -> float:
	var species_salt := int(_species_seed_salt_by_id.get(profile.species_id, 0))
	var value := hash01(seed, cycle, _seed + species_salt * 65537 + 101)
	return lerpf(profile.surface_activity_duration_seconds.x, profile.surface_activity_duration_seconds.y, value)


func _deep_duration(profile: FishSpeciesProfile, seed: int, cycle: int) -> float:
	var surface_duration := _surface_duration(profile, seed, cycle)
	var share := clampf(profile.surface_activity_time_share, 0.05, 0.95)
	var species_salt := int(_species_seed_salt_by_id.get(profile.species_id, 0))
	var variation := lerpf(0.82, 1.18, hash01(seed, cycle, _seed + species_salt * 65537 + 131))
	return surface_duration * ((1.0 - share) / share) * variation


func _set_activity_movement_label(state: FishSchoolState, profile: FishSpeciesProfile) -> void:
	var prefix := "surface_schooling" if profile.behavior_type == "schooling_pelagic" else "surface_cruise"
	var suffix := "deep_schooling" if profile.behavior_type == "schooling_pelagic" else "deep_cruise"
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
