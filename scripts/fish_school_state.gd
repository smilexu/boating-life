class_name FishSchoolState
extends RefCounted

## Compact logical school state. Client-only fish transforms are kept elsewhere.

var school_id := ""
var species_id := ""
var world_position := Vector3.ZERO
var population := 0
var habitat_region := ""
var movement_state := "cruise"
var resource_state := "available"
var last_updated_unix := 0
var depth_m := 0.0
## Fish swimming depth below the mean water plane. `depth_m` remains chart depth.
var activity_depth_m := 0.0
var activity_depth_target_m := 0.0
var surface_activity_state := "inactive"
var surface_activity_remaining_seconds := 0.0
var surface_activity_cycle_index := 0
## Real-time timestamp of the last Authority checkpoint for the activity depth.
var activity_depth_state_timestamp_seconds := 0.0
var direction_radians := 0.0
var movement_speed_mps := 0.0
var seed := 0
## Original school capacity. Recovery never exceeds this value.
var baseline_population := 0
## Absolute WorldTimeManager cycle seconds at the last recovery calculation.
var last_population_update_game_time_seconds := 0.0
## Fractional fish accumulated by the continuous recovery curve; always [0, 1).
var recovery_fractional_population := 0.0
## Authoritative vessel-disturbance state. This is transient behavior state,
## persisted with a school snapshot so reloads do not create a fresh alert.
var disturbance_level := 0.0
var disturbance_target := 0.0
var disturbance_state := "CALM"
var strong_disturbance_duration_seconds := 0.0
var disturbance_horizontal_distance_m := -1.0
var disturbance_vertical_below_hull_m := -1.0
var vessel_disturbance := 0.0
var bite_willingness_multiplier := 1.0


func to_dictionary() -> Dictionary:
	return {
		"schema_version": 4,
		"school_id": school_id,
		"species_id": species_id,
		"world_position": [world_position.x, world_position.y, world_position.z],
		"population": population,
		"habitat_region": habitat_region,
		"movement_state": movement_state,
		"resource_state": resource_state,
		"last_updated_unix": last_updated_unix,
		"depth_m": depth_m,
		"activity_depth_m": activity_depth_m,
		"activity_depth_target_m": activity_depth_target_m,
		"surface_activity_state": surface_activity_state,
		"surface_activity_remaining_seconds": surface_activity_remaining_seconds,
		"surface_activity_cycle_index": surface_activity_cycle_index,
		"activity_depth_state_timestamp_seconds": activity_depth_state_timestamp_seconds,
		"direction_radians": direction_radians,
		"movement_speed_mps": movement_speed_mps,
		"seed": seed,
		"baseline_population": baseline_population,
		"last_population_update_game_time_seconds": last_population_update_game_time_seconds,
		"recovery_fractional_population": recovery_fractional_population,
		"disturbance_level": disturbance_level,
		"disturbance_target": disturbance_target,
		"disturbance_state": disturbance_state,
		"strong_disturbance_duration_seconds": strong_disturbance_duration_seconds,
		"disturbance_horizontal_distance_m": disturbance_horizontal_distance_m,
		"disturbance_vertical_below_hull_m": disturbance_vertical_below_hull_m,
		"vessel_disturbance": vessel_disturbance,
		"bite_willingness_multiplier": bite_willingness_multiplier,
	}


static func from_dictionary(data: Dictionary) -> FishSchoolState:
	var schema_version := int(data.get("schema_version", -1))
	if schema_version not in [3, 4]:
		return null
	var position: Variant = data.get("world_position", [])
	if not position is Array or position.size() != 3:
		return null
	var school := FishSchoolState.new()
	school.school_id = str(data.get("school_id", ""))
	school.species_id = str(data.get("species_id", ""))
	school.world_position = Vector3(float(position[0]), float(position[1]), float(position[2]))
	if not is_finite(school.world_position.x) or not is_finite(school.world_position.y) or not is_finite(school.world_position.z):
		return null
	school.population = maxi(0, int(data.get("population", 0)))
	school.habitat_region = str(data.get("habitat_region", ""))
	school.movement_state = str(data.get("movement_state", "cruise"))
	school.resource_state = str(data.get("resource_state", "available"))
	school.last_updated_unix = int(data.get("last_updated_unix", 0))
	school.depth_m = maxf(0.0, float(data.get("depth_m", 0.0)))
	school.activity_depth_m = maxf(0.0, float(data.get("activity_depth_m", maxf(1.0, school.depth_m * 0.30))))
	school.activity_depth_target_m = maxf(0.0, float(data.get("activity_depth_target_m", school.activity_depth_m)))
	school.surface_activity_state = str(data.get("surface_activity_state", "deep"))
	school.surface_activity_remaining_seconds = maxf(0.0, float(data.get("surface_activity_remaining_seconds", 0.0)))
	school.surface_activity_cycle_index = maxi(0, int(data.get("surface_activity_cycle_index", 0)))
	school.activity_depth_state_timestamp_seconds = maxf(0.0, float(data.get("activity_depth_state_timestamp_seconds", -1.0)))
	school.direction_radians = float(data.get("direction_radians", 0.0))
	school.movement_speed_mps = maxf(0.0, float(data.get("movement_speed_mps", 0.0)))
	school.seed = int(data.get("seed", 0))
	school.baseline_population = maxi(0, int(data.get("baseline_population", -1)))
	school.last_population_update_game_time_seconds = float(data.get("last_population_update_game_time_seconds", -1.0))
	school.recovery_fractional_population = float(data.get("recovery_fractional_population", -1.0))
	school.disturbance_level = clampf(_finite_number(data.get("disturbance_level", 0.0), 0.0), 0.0, 1.0)
	school.disturbance_target = clampf(_finite_number(data.get("disturbance_target", 0.0), 0.0), 0.0, 1.0)
	school.disturbance_state = str(data.get("disturbance_state", "CALM"))
	if school.disturbance_state not in ["CALM", "ALERT", "FLEEING"]:
		school.disturbance_state = "CALM"
	school.strong_disturbance_duration_seconds = maxf(0.0, _finite_number(data.get("strong_disturbance_duration_seconds", 0.0), 0.0))
	school.disturbance_horizontal_distance_m = _diagnostic_distance(data.get("disturbance_horizontal_distance_m", -1.0))
	school.disturbance_vertical_below_hull_m = _diagnostic_distance(data.get("disturbance_vertical_below_hull_m", -1.0))
	school.vessel_disturbance = clampf(_finite_number(data.get("vessel_disturbance", 0.0), 0.0), 0.0, 1.0)
	school.bite_willingness_multiplier = clampf(_finite_number(data.get("bite_willingness_multiplier", 1.0), 1.0), 0.0, 1.0)
	if school.school_id.is_empty() or school.species_id.is_empty():
		return null
	if school.baseline_population < school.population:
		return null
	if not is_finite(school.last_population_update_game_time_seconds) or school.last_population_update_game_time_seconds < 0.0:
		return null
	if not is_finite(school.recovery_fractional_population) or school.recovery_fractional_population < 0.0 or school.recovery_fractional_population >= 1.0:
		return null
	return school


static func _finite_number(value: Variant, fallback: float) -> float:
	var number := float(value)
	return number if is_finite(number) else fallback


static func _diagnostic_distance(value: Variant) -> float:
	var distance := _finite_number(value, -1.0)
	return -1.0 if distance < 0.0 else distance
