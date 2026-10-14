extends Resource
class_name CloudWeatherProfiles

## One Inspector-editable source for the prototype's cloud layers in each weather.

@export_group("Clear")
@export var clear_main: CloudLayerProfile
@export var clear_detail: CloudLayerProfile

@export_group("Partly Cloudy")
@export var partly_main: CloudLayerProfile
@export var partly_detail: CloudLayerProfile

@export_group("Overcast")
@export var overcast_layer: CloudLayerProfile


func state_for_weather(weather_index: int) -> Dictionary:
	var main_layer: CloudLayerProfile
	var detail_layer: CloudLayerProfile
	var sheet_layer: CloudLayerProfile = overcast_layer
	match weather_index:
		0:
			main_layer = clear_main
			detail_layer = clear_detail
		1:
			main_layer = partly_main
			detail_layer = partly_detail
		_:
			main_layer = _empty_layer()
			detail_layer = _empty_layer()
	return {
		"main_cloud_coverage": main_layer.coverage,
		"main_cloud_density": main_layer.density,
		"main_cloud_scale": main_layer.scale,
		"main_cloud_softness": main_layer.softness,
		"main_cloud_brightness": main_layer.brightness,
		"main_cloud_bottom_darkness": main_layer.bottom_darkness,
		"main_cloud_speed": main_layer.speed,
		"main_cloud_direction": main_layer.direction,
		"detail_cloud_coverage": detail_layer.coverage,
		"detail_cloud_density": detail_layer.density,
		"detail_cloud_scale": detail_layer.scale,
		"detail_cloud_softness": detail_layer.softness,
		"detail_cloud_brightness": detail_layer.brightness,
		"detail_cloud_bottom_darkness": detail_layer.bottom_darkness,
		"detail_cloud_speed": detail_layer.speed,
		"detail_cloud_direction": detail_layer.direction,
		"overcast_coverage": sheet_layer.coverage,
		"overcast_density": sheet_layer.density,
		"overcast_scale": sheet_layer.scale,
		"overcast_softness": sheet_layer.softness,
		"overcast_brightness": sheet_layer.brightness,
		"overcast_bottom_darkness": sheet_layer.bottom_darkness,
		"overcast_speed": sheet_layer.speed,
		"overcast_direction": sheet_layer.direction,
		"overcast_grayness": sheet_layer.grayness,
	}


func _empty_layer() -> CloudLayerProfile:
	var layer := CloudLayerProfile.new()
	layer.coverage = 0.0
	layer.density = 0.0
	return layer
