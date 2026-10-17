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
var direction_radians := 0.0
var movement_speed_mps := 0.0
var seed := 0


func to_dictionary() -> Dictionary:
	return {
		"schema_version": 1,
		"school_id": school_id,
		"species_id": species_id,
		"world_position": [world_position.x, world_position.y, world_position.z],
		"population": population,
		"habitat_region": habitat_region,
		"movement_state": movement_state,
		"resource_state": resource_state,
		"last_updated_unix": last_updated_unix,
		"depth_m": depth_m,
		"direction_radians": direction_radians,
		"movement_speed_mps": movement_speed_mps,
		"seed": seed,
	}


static func from_dictionary(data: Dictionary) -> FishSchoolState:
	if int(data.get("schema_version", -1)) != 1:
		return null
	var position: Variant = data.get("world_position", [])
	if not position is Array or position.size() != 3:
		return null
	var school := FishSchoolState.new()
	school.school_id = str(data.get("school_id", ""))
	school.species_id = str(data.get("species_id", ""))
	school.world_position = Vector3(float(position[0]), float(position[1]), float(position[2]))
	school.population = maxi(0, int(data.get("population", 0)))
	school.habitat_region = str(data.get("habitat_region", ""))
	school.movement_state = str(data.get("movement_state", "cruise"))
	school.resource_state = str(data.get("resource_state", "available"))
	school.last_updated_unix = int(data.get("last_updated_unix", 0))
	school.depth_m = maxf(0.0, float(data.get("depth_m", 0.0)))
	school.direction_radians = float(data.get("direction_radians", 0.0))
	school.movement_speed_mps = maxf(0.0, float(data.get("movement_speed_mps", 0.0)))
	school.seed = int(data.get("seed", 0))
	if school.school_id.is_empty() or school.species_id.is_empty():
		return null
	return school
