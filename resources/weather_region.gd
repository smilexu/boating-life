extends Resource
class_name WeatherRegion

## A provider-neutral forecast location. Coordinates are WGS84 degrees.

@export var region_id := "oresund"
@export var display_name := "Øresund"
@export var latitude := 55.64
@export var longitude := 12.78
@export var altitude_m: int = 0
@export var use_altitude := false


func to_dictionary() -> Dictionary:
	return {
		"region_id": region_id,
		"display_name": display_name,
		"latitude": latitude,
		"longitude": longitude,
		"altitude_m": altitude_m,
		"use_altitude": use_altitude,
	}
