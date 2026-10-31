extends Control
## Read-only, boat-relative navigation instrument for SailboatLab.

const NAV_MATH := preload("res://scripts/sailboat_navigation_math.gd")
const REFRESH_INTERVAL_S := 0.10

const COLOR_PANEL := Color(0.025, 0.085, 0.11, 0.91)
const COLOR_BORDER := Color(0.28, 0.52, 0.55, 0.72)
const COLOR_TEXT := Color(0.88, 0.94, 0.93, 0.98)
const COLOR_MUTED := Color(0.59, 0.73, 0.75, 0.96)
const COLOR_TRUE_WIND := Color(0.22, 0.81, 0.73, 1.0)
const COLOR_APPARENT_WIND := Color(1.0, 0.62, 0.29, 1.0)
const COLOR_COURSE := Color(0.36, 0.87, 0.53, 1.0)
const COLOR_SAIL := Color(0.39, 0.75, 0.98, 1.0)
const COLOR_HEADSAIL := Color(0.95, 0.77, 0.36, 1.0)
const COLOR_RUDDER := Color(1.0, 0.82, 0.28, 1.0)

var _boat: Node
var _snapshot: Dictionary = {}
var _panel_style: StyleBoxFlat
var _refresh_elapsed := 0.0
var _embedded_in_sailing_panel := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	_panel_style = StyleBoxFlat.new()
	_panel_style.bg_color = COLOR_PANEL
	_panel_style.border_color = COLOR_BORDER
	_panel_style.set_border_width_all(1)
	_panel_style.set_corner_radius_all(10)
	_panel_style.content_margin_left = 11.0
	_panel_style.content_margin_right = 11.0
	_panel_style.content_margin_top = 9.0
	_panel_style.content_margin_bottom = 9.0
	custom_minimum_size = Vector2(270.0, 408.0)
	get_viewport().size_changed.connect(_update_screen_position)
	_update_screen_position()
	refresh_data()


func configure(boat: Node, embedded_in_sailing_panel: bool = false) -> void:
	_boat = boat
	_embedded_in_sailing_panel = embedded_in_sailing_panel
	set_process(not _embedded_in_sailing_panel)
	_update_screen_position()
	refresh_data()


func _process(delta: float) -> void:
	_refresh_elapsed += delta
	if _refresh_elapsed < REFRESH_INTERVAL_S:
		return
	_refresh_elapsed = 0.0
	refresh_data()


func refresh_data() -> void:
	if _boat == null or not _boat.has_method("get_navigation_snapshot"):
		return
	set_snapshot(_boat.call("get_navigation_snapshot"))


func set_snapshot(snapshot: Dictionary) -> void:
	_snapshot = snapshot
	queue_redraw()


func _draw() -> void:
	if _embedded_in_sailing_panel:
		_draw_embedded_instrument()
		return
	if _panel_style != null:
		draw_style_box(_panel_style, Rect2(Vector2.ZERO, size))
	var font := get_theme_default_font()
	if font == null:
		return
	var width := size.x
	var label_color := COLOR_TEXT
	draw_string(font, Vector2(12.0, 24.0), tr("hud.sailing_instrument.title"), HORIZONTAL_ALIGNMENT_LEFT, width - 24.0, 15, label_color)

	var heading := float(_snapshot.get("heading_degrees", 0.0))
	var speed := float(_snapshot.get("sog_mps", 0.0))
	var sog_knots := float(_snapshot.get("sog_knots", 0.0))
	var cog_valid := bool(_snapshot.get("cog_valid", false))
	var cog := float(_snapshot.get("cog_degrees", 0.0))
	var cog_delta := float(_snapshot.get("cog_minus_heading_degrees", 0.0)) if cog_valid else 0.0
	var cog_text := "%03.0f° · %+.0f°" % [cog, cog_delta] if cog_valid else tr("hud.sailing_instrument.cog_unreliable")
	draw_string(font, Vector2(12.0, 45.0), tr("hud.sailing_instrument.heading_format") % [heading, cog_text], HORIZONTAL_ALIGNMENT_LEFT, width - 24.0, 13, label_color)
	draw_string(font, Vector2(12.0, 63.0), tr("hud.sailing_instrument.speed_heel_format") % [sog_knots, speed, float(_snapshot.get("heel_degrees", 0.0))], HORIZONTAL_ALIGNMENT_LEFT, width - 24.0, 12, COLOR_MUTED)

	var center := Vector2(width * 0.5, 190.0)
	var true_speed := float(_snapshot.get("true_wind_speed_mps", 0.0))
	var apparent_speed := float(_snapshot.get("apparent_wind_speed_mps", 0.0))
	var true_valid := bool(_snapshot.get("true_wind_valid", false))
	var apparent_valid := bool(_snapshot.get("apparent_wind_valid", false))
	var true_relative := float(_snapshot.get("true_wind_from_relative_degrees", 0.0))
	var apparent_relative := float(_snapshot.get("apparent_wind_from_relative_degrees", 0.0))
	var true_world_bearing := float(_snapshot.get("true_wind_from_degrees", 0.0))
	var apparent_world_bearing := float(_snapshot.get("apparent_wind_from_degrees", 0.0))
	var course_relative := cog_delta

	for ring_radius in [49.0, 78.0]:
		draw_arc(center, ring_radius, 0.0, TAU, 64, Color(0.66, 0.79, 0.8, 0.2), 1.0, true)
	_draw_wind_arrow(font, center, true_valid, true_relative, 88.0, COLOR_TRUE_WIND, "T")
	_draw_wind_arrow(font, center, apparent_valid, apparent_relative, 72.0, COLOR_APPARENT_WIND, "A")
	if cog_valid:
		var course_direction := NAV_MATH.compass_bearing_to_screen_direction(course_relative)
		_draw_arrow(center + course_direction * 24.0, center + course_direction * 83.0, COLOR_COURSE, 2.7)

	_draw_hull_outline(center)
	_draw_sail_and_boom(center)
	_draw_headsail(center)
	_draw_rudder(center)
	draw_string(font, Vector2(center.x - 25.0, center.y - 50.0), tr("hud.sailing_instrument.bow"), HORIZONTAL_ALIGNMENT_CENTER, 50.0, 10, COLOR_MUTED)
	draw_string(font, Vector2(center.x - 29.0, center.y + 58.0), tr("hud.sailing_instrument.stern"), HORIZONTAL_ALIGNMENT_CENTER, 58.0, 10, COLOR_MUTED)
	draw_string(font, Vector2(10.0, center.y + 3.0), tr("hud.sailing_instrument.port"), HORIZONTAL_ALIGNMENT_LEFT, 38.0, 9, COLOR_MUTED)
	draw_string(font, Vector2(width - 48.0, center.y + 3.0), tr("hud.sailing_instrument.starboard"), HORIZONTAL_ALIGNMENT_RIGHT, 38.0, 9, COLOR_MUTED)

	var sail_angle := rad_to_deg(float(_snapshot.get("actual_sail_angle_rad", 0.0)))
	var sail_target := rad_to_deg(float(_snapshot.get("target_sail_angle_rad", 0.0)))
	var headsail_angle := rad_to_deg(float(_snapshot.get("actual_headsail_angle_rad", 0.0)))
	var headsail_target := rad_to_deg(float(_snapshot.get("target_headsail_angle_rad", 0.0)))
	var rudder_angle := rad_to_deg(float(_snapshot.get("actual_rudder_angle_rad", 0.0)))
	var rudder_limit := rad_to_deg(float(_snapshot.get("max_rudder_angle_rad", 0.0)))
	var rudder_side_key := "hud.sailing_instrument.starboard" if rudder_angle > 0.05 else "hud.sailing_instrument.port" if rudder_angle < -0.05 else "hud.sailing_instrument.center"
	draw_string(font, Vector2(12.0, 292.0), tr("hud.sailing_instrument.sail_format") % [sail_angle, sail_target], HORIZONTAL_ALIGNMENT_LEFT, width - 24.0, 12, COLOR_SAIL)
	draw_string(font, Vector2(12.0, 310.0), tr("hud.sailing_instrument.jib_format") % [tr("hud.sailing_instrument.on") if bool(_snapshot.get("headsail_enabled", false)) else tr("hud.sailing_instrument.off"), headsail_angle, headsail_target], HORIZONTAL_ALIGNMENT_LEFT, width - 24.0, 12, COLOR_HEADSAIL)
	draw_string(font, Vector2(12.0, 328.0), tr("hud.sailing_instrument.rudder_format") % [rudder_angle, tr(rudder_side_key), rudder_limit], HORIZONTAL_ALIGNMENT_LEFT, width - 24.0, 12, COLOR_RUDDER)
	draw_string(font, Vector2(12.0, 350.0), _wind_summary(tr("hud.sailing_instrument.true_wind"), true_valid, true_speed, true_world_bearing, true_relative), HORIZONTAL_ALIGNMENT_LEFT, width - 24.0, 11, COLOR_TRUE_WIND)
	draw_string(font, Vector2(12.0, 368.0), _wind_summary(tr("hud.sailing_instrument.apparent_wind"), apparent_valid, apparent_speed, apparent_world_bearing, apparent_relative), HORIZONTAL_ALIGNMENT_LEFT, width - 24.0, 11, COLOR_APPARENT_WIND)
	var keel_slip := rad_to_deg(float(_snapshot.get("keel_side_slip_angle_rad", 0.0)))
	draw_string(font, Vector2(12.0, 389.0), tr("hud.sailing_instrument.slip_format") % [cog_delta, keel_slip], HORIZONTAL_ALIGNMENT_LEFT, width - 24.0, 11, COLOR_TEXT if cog_valid else COLOR_MUTED)
	var trim: Dictionary = _snapshot.get("auto_sail_trim", {})
	var trim_mode := tr("hud.navigation.auto_trim_on") if bool(_snapshot.get("auto_sail_trim_enabled", false)) else tr("hud.navigation.auto_trim_off")
	var trim_status := tr("hud.sailing_instrument.no_go") if bool(trim.get("no_go", false)) else tr("hud.sailing_instrument.trim_ready") if bool(_snapshot.get("auto_sail_trim_enabled", false)) else tr("hud.sailing_instrument.trim_manual")
	draw_string(font, Vector2(12.0, 410.0), tr("hud.sailing_instrument.trim_legend") % [trim_mode, trim_status], HORIZONTAL_ALIGNMENT_LEFT, width - 24.0, 10, COLOR_APPARENT_WIND if bool(trim.get("no_go", false)) else COLOR_MUTED)


func _draw_embedded_instrument() -> void:
	var font := get_theme_default_font()
	if font == null:
		return
	var width := size.x
	var height := size.y
	var center := Vector2(width * 0.5, height * 0.46)
	var radius := minf(width * 0.38, (height - 30.0) * 0.4)
	for ring_radius in [radius * 0.56, radius * 0.9]:
		draw_arc(center, ring_radius, 0.0, TAU, 48, Color(0.66, 0.79, 0.8, 0.24), 1.0, true)

	var true_valid := bool(_snapshot.get("true_wind_valid", false))
	var apparent_valid := bool(_snapshot.get("apparent_wind_valid", false))
	var true_relative := float(_snapshot.get("true_wind_from_relative_degrees", 0.0))
	var apparent_relative := float(_snapshot.get("apparent_wind_from_relative_degrees", 0.0))
	_draw_wind_arrow(font, center, true_valid, true_relative, radius, COLOR_TRUE_WIND, "T")
	_draw_wind_arrow(font, center, apparent_valid, apparent_relative, radius * 0.83, COLOR_APPARENT_WIND, "A")
	if bool(_snapshot.get("cog_valid", false)):
		var course_direction := NAV_MATH.compass_bearing_to_screen_direction(float(_snapshot.get("cog_minus_heading_degrees", 0.0)))
		_draw_arrow(center + course_direction * radius * 0.34, center + course_direction * radius * 0.91, COLOR_COURSE, 2.2)
	_draw_hull_outline(center, radius / 66.0)
	_draw_sail_and_boom(center, radius / 66.0)
	_draw_headsail(center, radius / 66.0)
	_draw_rudder(center, radius / 66.0)
	draw_string(font, Vector2(0.0, height - 4.0), tr("hud.sailing_instrument.legend"), HORIZONTAL_ALIGNMENT_CENTER, width, 11, COLOR_MUTED)


func _draw_wind_arrow(font: Font, center: Vector2, valid: bool, relative_from_degrees: float, radius: float, color: Color, marker: String) -> void:
	if not valid:
		return
	var from_direction := NAV_MATH.compass_bearing_to_screen_direction(relative_from_degrees)
	var start := center + from_direction * radius
	var end := center + from_direction * minf(48.0, radius * 0.72)
	_draw_arrow(start, end, color, 2.6)
	draw_circle(start, 3.0, color)
	draw_string(font, start + Vector2(-4.0, 4.0), marker, HORIZONTAL_ALIGNMENT_CENTER, 8.0, 9, color)


func _draw_hull_outline(center: Vector2, scale: float = 1.0) -> void:
	var hull := PackedVector2Array([
		center + Vector2(0.0, -46.0) * scale,
		center + Vector2(13.0, -25.0) * scale,
		center + Vector2(17.0, 6.0) * scale,
		center + Vector2(20.0, 32.0) * scale,
		center + Vector2(18.0, 42.0) * scale,
		center + Vector2(-18.0, 42.0) * scale,
		center + Vector2(-20.0, 32.0) * scale,
		center + Vector2(-17.0, 6.0) * scale,
		center + Vector2(-13.0, -25.0) * scale,
	])
	draw_colored_polygon(hull, Color(0.74, 0.81, 0.79, 0.95))
	for index in range(hull.size()):
		draw_line(hull[index], hull[(index + 1) % hull.size()], Color(0.95, 0.98, 0.96, 0.98), 1.5, true)
	draw_line(center + Vector2(-17.0, 8.0), center + Vector2(17.0, 8.0), Color(0.23, 0.38, 0.4, 0.8), 1.0, true)


func _draw_sail_and_boom(center: Vector2, scale: float = 1.0) -> void:
	var angle := float(_snapshot.get("actual_sail_angle_rad", 0.0))
	var mast := center + Vector2(0.0, -11.0) * scale
	var direction := NAV_MATH.boom_direction_from_sail_angle(angle)
	var endpoint := mast + Vector2(direction.x, direction.y) * 31.0 * scale
	draw_line(mast, endpoint, COLOR_SAIL, maxf(1.5, 4.0 * scale), true)
	draw_circle(mast, 3.0, Color(0.11, 0.28, 0.38, 1.0))
	draw_circle(endpoint, 2.5, COLOR_SAIL)


func _draw_headsail(center: Vector2, scale: float = 1.0) -> void:
	if not bool(_snapshot.get("headsail_enabled", false)):
		return
	var angle := float(_snapshot.get("actual_headsail_angle_rad", 0.0))
	var head := center + Vector2(0.0, -10.0) * scale
	var tack := center + Vector2(0.0, -43.0) * scale
	var clew := center + Vector2(sin(angle) * 18.0, -14.0) * scale
	draw_colored_polygon(PackedVector2Array([head, tack, clew]), Color(COLOR_HEADSAIL.r, COLOR_HEADSAIL.g, COLOR_HEADSAIL.b, 0.22))
	draw_line(head, tack, COLOR_HEADSAIL.darkened(0.15), maxf(1.0, 1.4 * scale), true)
	draw_line(tack, clew, COLOR_HEADSAIL, maxf(1.2, 2.6 * scale), true)
	draw_circle(clew, maxf(1.5, 2.2 * scale), COLOR_HEADSAIL)


func _draw_rudder(center: Vector2, scale: float = 1.0) -> void:
	var angle := float(_snapshot.get("actual_rudder_angle_rad", 0.0))
	var direction := NAV_MATH.boom_direction_from_sail_angle(angle)
	var pivot := center + Vector2(0.0, 34.0) * scale
	var endpoint := pivot + Vector2(direction.x, direction.y) * 21.0 * scale
	draw_line(pivot, endpoint, COLOR_RUDDER, maxf(1.5, 4.0 * scale), true)
	draw_circle(pivot, maxf(1.5, 2.8 * scale), Color(0.14, 0.19, 0.18, 1.0))


func _draw_arrow(start: Vector2, end: Vector2, color: Color, line_width: float) -> void:
	draw_line(start, end, color, line_width, true)
	var direction := (end - start).normalized()
	var perpendicular := Vector2(-direction.y, direction.x)
	var head_length := 8.0 if line_width >= 2.5 else 6.0
	var head_width := 4.5 if line_width >= 2.5 else 3.5
	var head := PackedVector2Array([
		end,
		end - direction * head_length + perpendicular * head_width,
		end - direction * head_length - perpendicular * head_width,
	])
	draw_colored_polygon(head, color)


func _wind_summary(label: String, valid: bool, speed: float, world_bearing: float, relative_bearing: float) -> String:
	if not valid:
		return tr("hud.sailing_instrument.wind_calm_format") % label
	return tr("hud.sailing_instrument.wind_format") % [label, speed, world_bearing, relative_bearing]


func _update_screen_position() -> void:
	if not is_inside_tree():
		return
	if _embedded_in_sailing_panel:
		custom_minimum_size = Vector2(150.0, 164.0)
		size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		queue_redraw()
		return
	var viewport_size := get_viewport_rect().size
	var panel_width := clampf(viewport_size.x * 0.235, 270.0, 320.0)
	size = Vector2(panel_width, 430.0)
	position = Vector2(viewport_size.x - panel_width - 16.0, 16.0)
	queue_redraw()
