extends Resource
class_name CloudWeatherProfiles

## Weather presets for the Sunshine Clouds 2 compositor effect.

@export_group("Clear")
@export_range(0.0, 1.0, 0.01) var clear_coverage := 0.57
@export_range(0.0, 20.0, 0.01) var clear_density := 0.95
@export_range(0.0, 10.0, 0.01) var clear_lighting_density := 0.7
@export var clear_ambient_color := Color(0.98, 0.96, 0.91, 1.0)
@export var clear_ambient_tint := Color(0.3, 0.39, 0.48, 1.0)

@export_group("Partly Cloudy")
@export_range(0.0, 1.0, 0.01) var partly_coverage := 0.68
@export_range(0.0, 20.0, 0.01) var partly_density := 0.95
@export_range(0.0, 10.0, 0.01) var partly_lighting_density := 0.7
@export var partly_ambient_color := Color(0.98, 0.96, 0.92, 1.0)
@export var partly_ambient_tint := Color(0.34, 0.42, 0.5, 1.0)

@export_group("Overcast")
@export_range(0.0, 1.0, 0.01) var overcast_coverage := 0.91
@export_range(0.0, 20.0, 0.01) var overcast_density := 0.78
@export_range(0.0, 10.0, 0.01) var overcast_lighting_density := 0.48
@export var overcast_ambient_color := Color(0.78, 0.83, 0.88, 1.0)
@export var overcast_ambient_tint := Color(0.52, 0.59, 0.66, 1.0)


func state_for_weather(weather_index: int) -> Dictionary:
	match weather_index:
		0:
			return _state(clear_coverage, clear_density, clear_lighting_density, clear_ambient_color, clear_ambient_tint)
		1:
			return _state(partly_coverage, partly_density, partly_lighting_density, partly_ambient_color, partly_ambient_tint)
		_:
			return _state(overcast_coverage, overcast_density, overcast_lighting_density, overcast_ambient_color, overcast_ambient_tint)


func _state(coverage: float, density: float, light_density: float, ambient: Color, tint: Color) -> Dictionary:
	return {
		"cloud_coverage": coverage,
		"clouds_coverage": coverage,
		"clouds_density": density,
		"lighting_density": light_density,
		"cloud_ambient_color": ambient,
		"cloud_ambient_tint": tint,
	}
