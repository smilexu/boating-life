extends CanvasLayer
class_name WeatherRuntimeDiagnostics

## Compact developer-only readout; it does not consume F3 or F12 shortcuts.

@export_node_path("Node") var authority_path := NodePath("../WeatherRuntimeAuthority")
@export_node_path("Node") var world_time_manager_path := NodePath("../../WorldTimeManager")
@export_node_path("Node") var weather_state_controller_path := NodePath("../WeatherStateController")
@export_node_path("Node") var wind_field_path := NodePath("../WindField")
@export_node_path("Node") var wind_field_debug_panel_path := NodePath("../WindFieldDebugPanel")
@export var show_in_debug_builds := true

var _authority: Node
var _world_time_manager: Node
var _weather_state_controller: Node
var _wind_field: Node
var _wind_field_debug_panel: Node
var _label: Label
var _elapsed := 0.0


func _ready() -> void:
	layer = 30
	visible = show_in_debug_builds and OS.is_debug_build()
	_authority = get_node_or_null(authority_path)
	_world_time_manager = get_node_or_null(world_time_manager_path)
	_weather_state_controller = get_node_or_null(weather_state_controller_path)
	_wind_field = get_node_or_null(wind_field_path)
	_wind_field_debug_panel = get_node_or_null(wind_field_debug_panel_path)
	_build_panel()
	_refresh_text()


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < 0.1:
		return
	_elapsed = 0.0
	var should_show := show_in_debug_builds and OS.is_debug_build()
	if should_show and _wind_field_debug_panel != null and _wind_field_debug_panel.has_method("is_panel_open"):
		should_show = not bool(_wind_field_debug_panel.call("is_panel_open"))
	if visible != should_show:
		visible = should_show
	_refresh_text()


func _build_panel() -> void:
	var panel := PanelContainer.new()
	panel.name = "WeatherRuntimePanel"
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	panel.offset_left = -332.0
	panel.offset_top = 18.0
	panel.offset_right = -18.0
	panel.offset_bottom = 154.0
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.025, 0.065, 0.085, 0.86)
	style.border_color = Color(0.28, 0.56, 0.62, 0.75)
	style.set_border_width_all(1)
	style.set_corner_radius_all(7)
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 8.0
	style.content_margin_bottom = 8.0
	panel.add_theme_stylebox_override("panel", style)
	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 13)
	_label.add_theme_color_override("font_color", Color(0.83, 0.94, 0.95, 1.0))
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(_label)
	add_child(panel)


func _refresh_text() -> void:
	if _label == null or not visible:
		return
	if _authority == null:
		_label.text = "WEATHER · runtime authority unavailable"
		return
	var mode := "AUTO"
	if _weather_state_controller != null:
		mode = str(_weather_state_controller.call("get_operating_mode_name"))
	var region := str(_authority.get("region_id"))
	var source := str(_authority.get("data_source_status"))
	var quality := str(_authority.get("forecast_data_quality"))
	var mapping := str(_authority.get("mapping_status"))
	var cycle := 0
	var date_text := "N/A"
	if _world_time_manager != null:
		var world: Dictionary = _world_time_manager.call("get_authoritative_state")
		cycle = int(world.get("day_cycle_index", 0))
		date_text = _date_label(_world_time_manager.call("get_real_calendar_date"))
	var state: Dictionary = _authority.get("current_sample")	
	var weather := str(state.get("weather_type", "manual / waiting"))
	var timeline_wind := "N/A"
	if state.has("mean_wind_speed_mps") and state.has("wind_from_direction_deg"):
		timeline_wind = "%.1f m/s · %.0f° from" % [float(state["mean_wind_speed_mps"]), float(state["wind_from_direction_deg"])]
	var effective_wind := "N/A"
	var override_state := "formal"
	if _wind_field != null:
		var settings: Dictionary = _wind_field.call("get_effective_wind_settings")
		effective_wind = "%.1f m/s · %.0f° from" % [
			float(settings.get("mean_wind_speed_mps", 0.0)),
			float(settings.get("mean_wind_from_degrees", 0.0)),
		]
		override_state = str(_wind_field.call("get_debug_override_state"))
	var refresh := str(_authority.get("last_refresh_status"))
	var provider_error := str(_authority.get("provider_error"))
	var error_line := ""
	if not provider_error.is_empty():
		error_line = "\n%s" % provider_error.left(72)
	var effective_label := "Effective wind"
	if override_state == "active":
		effective_label = "F12 override effective"
	elif override_state == "restoring":
		effective_label = "Effective wind (restoring)"
	_label.text = "%s · %s · %s / %s\n%s · Stockholm %s · cycle %d\nFormal timeline wind %s · refresh %s\n%s %s\nMapping %s%s" % [
		mode, region, source, quality, weather, date_text, cycle, timeline_wind, refresh,
		effective_label, effective_wind, mapping, error_line,
	]


func _date_label(date: Dictionary) -> String:
	if date.is_empty():
		return "N/A"
	return "%04d-%02d-%02d" % [int(date.get("year", 0)), int(date.get("month", 0)), int(date.get("day", 0))]
