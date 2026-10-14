class_name GeoReference
extends Resource

## Local WGS84 East-North-Up tangent frame for the Øresund prototype.
## Godot uses X=east, Y=up, Z=south; one world unit equals one metre.

const WGS84_SEMI_MAJOR_M := 6378137.0
const WGS84_FLATTENING := 1.0 / 298.257223563
const WGS84_ECCENTRICITY_SQUARED := WGS84_FLATTENING * (2.0 - WGS84_FLATTENING)

@export_category("Local origin (WGS84)")
@export_range(-90.0, 90.0, 0.000001) var origin_latitude_deg := 55.7
@export_range(-180.0, 180.0, 0.000001) var origin_longitude_deg := 12.75
@export var origin_altitude_m := 0.0

@export_category("Region bounds (WGS84)")
@export_range(-90.0, 90.0, 0.0001) var south_latitude_deg := 55.35
@export_range(-90.0, 90.0, 0.0001) var north_latitude_deg := 56.1
@export_range(-180.0, 180.0, 0.0001) var west_longitude_deg := 12.25
@export_range(-180.0, 180.0, 0.0001) var east_longitude_deg := 13.22


## Convert WGS84 geodetic coordinates to the origin-relative Godot world frame.
func geodetic_to_world(latitude_deg: float, longitude_deg: float, altitude_m: float = 0.0) -> Vector3:
	var origin_ecef := _geodetic_to_ecef(origin_latitude_deg, origin_longitude_deg, origin_altitude_m)
	var point_ecef := _geodetic_to_ecef(latitude_deg, longitude_deg, altitude_m)
	var delta := point_ecef - origin_ecef
	var latitude := deg_to_rad(origin_latitude_deg)
	var longitude := deg_to_rad(origin_longitude_deg)
	var sin_lat := sin(latitude)
	var cos_lat := cos(latitude)
	var sin_lon := sin(longitude)
	var cos_lon := cos(longitude)
	var east := -sin_lon * delta.x + cos_lon * delta.y
	var north := -sin_lat * cos_lon * delta.x - sin_lat * sin_lon * delta.y + cos_lat * delta.z
	var up := cos_lat * cos_lon * delta.x + cos_lat * sin_lon * delta.y + sin_lat * delta.z
	return Vector3(east, up, -north)


## Convert a local Godot position to (latitude degrees, longitude degrees, altitude metres).
func world_to_geodetic(world_position: Vector3) -> Vector3:
	var east := world_position.x
	var north := -world_position.z
	var up := world_position.y
	var latitude0 := deg_to_rad(origin_latitude_deg)
	var longitude0 := deg_to_rad(origin_longitude_deg)
	var sin_lat := sin(latitude0)
	var cos_lat := cos(latitude0)
	var sin_lon := sin(longitude0)
	var cos_lon := cos(longitude0)
	var delta := Vector3(
		-sin_lon * east - sin_lat * cos_lon * north + cos_lat * cos_lon * up,
		cos_lon * east - sin_lat * sin_lon * north + cos_lat * sin_lon * up,
		cos_lat * north + sin_lat * up
	)
	var ecef := _geodetic_to_ecef(origin_latitude_deg, origin_longitude_deg, origin_altitude_m) + delta
	return _ecef_to_geodetic(ecef)


func region_bounds_east_north() -> Rect2:
	var corners := [
		geodetic_to_world(south_latitude_deg, west_longitude_deg),
		geodetic_to_world(south_latitude_deg, east_longitude_deg),
		geodetic_to_world(north_latitude_deg, west_longitude_deg),
		geodetic_to_world(north_latitude_deg, east_longitude_deg),
	]
	var min_east := INF
	var max_east := -INF
	var min_north := INF
	var max_north := -INF
	for corner in corners:
		min_east = minf(min_east, corner.x)
		max_east = maxf(max_east, corner.x)
		var north: float = -float(corner.z)
		min_north = minf(min_north, north)
		max_north = maxf(max_north, north)
	return Rect2(Vector2(min_east, min_north), Vector2(max_east - min_east, max_north - min_north))


func _geodetic_to_ecef(latitude_deg: float, longitude_deg: float, altitude_m: float) -> Vector3:
	var latitude := deg_to_rad(latitude_deg)
	var longitude := deg_to_rad(longitude_deg)
	var sin_lat := sin(latitude)
	var cos_lat := cos(latitude)
	var prime_vertical_radius := WGS84_SEMI_MAJOR_M / sqrt(1.0 - WGS84_ECCENTRICITY_SQUARED * sin_lat * sin_lat)
	return Vector3(
		(prime_vertical_radius + altitude_m) * cos_lat * cos(longitude),
		(prime_vertical_radius + altitude_m) * cos_lat * sin(longitude),
		(prime_vertical_radius * (1.0 - WGS84_ECCENTRICITY_SQUARED) + altitude_m) * sin_lat
	)


func _ecef_to_geodetic(ecef: Vector3) -> Vector3:
	var longitude := atan2(ecef.y, ecef.x)
	var horizontal_distance := sqrt(ecef.x * ecef.x + ecef.y * ecef.y)
	var latitude := atan2(ecef.z, horizontal_distance * (1.0 - WGS84_ECCENTRICITY_SQUARED))
	var altitude := 0.0
	for _iteration in range(8):
		var sin_lat := sin(latitude)
		var prime_vertical_radius := WGS84_SEMI_MAJOR_M / sqrt(1.0 - WGS84_ECCENTRICITY_SQUARED * sin_lat * sin_lat)
		altitude = horizontal_distance / maxf(absf(cos(latitude)), 0.000001) - prime_vertical_radius
		latitude = atan2(
			ecef.z,
			horizontal_distance * (1.0 - WGS84_ECCENTRICITY_SQUARED * prime_vertical_radius / (prime_vertical_radius + altitude))
		)
	return Vector3(rad_to_deg(latitude), rad_to_deg(longitude), altitude)
