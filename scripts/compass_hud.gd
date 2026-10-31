extends Control

## Compact heading ribbon. The fixed pointer marks the boat's current heading;
## compass bearings slide beneath it as the boat turns.

const CARDINAL_KEYS := [
	"hud.direction.short.north", "hud.direction.short.northeast", "hud.direction.short.east", "hud.direction.short.southeast",
	"hud.direction.short.south", "hud.direction.short.southwest", "hud.direction.short.west", "hud.direction.short.northwest",
]
const RIBBON_HALF_ANGLE_DEGREES := 70.0

var _controller: BoatController
var _heading_degrees := 0.0
var _panel_style: StyleBoxFlat
var _quality_manager: Node


func configure(controller: BoatController) -> void:
	_controller = controller
	queue_redraw()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(400.0, 86.0)
	size = custom_minimum_size
	_panel_style = StyleBoxFlat.new()
	_panel_style.bg_color = Color(0.035, 0.12, 0.16, 0.84)
	_panel_style.set_corner_radius_all(10)
	_panel_style.content_margin_left = 10.0
	_panel_style.content_margin_right = 10.0
	_panel_style.content_margin_top = 5.0
	_panel_style.content_margin_bottom = 5.0
	_update_screen_position()
	get_viewport().size_changed.connect(_update_screen_position)
	_quality_manager = get_tree().current_scene.get_node_or_null("QualityManager") if get_tree().current_scene != null else null
	if _quality_manager != null and _quality_manager.has_signal("settings_changed"):
		_quality_manager.connect("settings_changed", _update_screen_position)
	set_process(true)


func _process(_delta: float) -> void:
	if _controller == null:
		return
	var forward := -_controller.global_transform.basis.z
	var heading := fposmod(rad_to_deg(atan2(forward.x, -forward.z)), 360.0)
	if absf(wrapf(heading - _heading_degrees, -180.0, 180.0)) >= 0.1:
		_heading_degrees = heading
		queue_redraw()


func _draw() -> void:
	if _panel_style != null:
		draw_style_box(_panel_style, Rect2(Vector2.ZERO, size))
	var font := get_theme_default_font()
	var center_x := size.x * 0.5
	var scale_y := 50.0
	var pixels_per_degree := (size.x - 64.0) / (RIBBON_HALF_ANGLE_DEGREES * 2.0)
	var tick_color := Color(0.78, 0.88, 0.88, 0.78)
	var label_color := Color(0.9, 0.95, 0.93, 0.96)

	for tick_bearing in range(0, 360, 5):
		var relative_bearing := wrapf(float(tick_bearing) - _heading_degrees, -180.0, 180.0)
		if absf(relative_bearing) > RIBBON_HALF_ANGLE_DEGREES:
			continue
		var x := center_x + relative_bearing * pixels_per_degree
		var is_cardinal := tick_bearing % 45 == 0
		var is_major := tick_bearing % 15 == 0
		var tick_height := 12.0 if is_cardinal else (8.0 if is_major else 4.0)
		draw_line(Vector2(x, scale_y - tick_height), Vector2(x, scale_y), tick_color, 1.4 if is_major else 1.0, true)
		if is_cardinal:
			var cardinal_index := int(tick_bearing / 45) % CARDINAL_KEYS.size()
			var color := Color(1.0, 0.68, 0.42, 1.0) if cardinal_index == 0 else label_color
			draw_string(font, Vector2(x - 22.0, 25.0), tr(CARDINAL_KEYS[cardinal_index]), HORIZONTAL_ALIGNMENT_CENTER, 44.0, 13, color)

	var pointer := PackedVector2Array([
		Vector2(center_x, 30.0),
		Vector2(center_x - 7.0, 41.0),
		Vector2(center_x + 7.0, 41.0),
	])
	draw_colored_polygon(pointer, Color(1.0, 0.62, 0.34, 1.0))
	draw_line(Vector2(18.0, scale_y), Vector2(size.x - 18.0, scale_y), Color(0.7, 0.82, 0.83, 0.32), 1.0, true)
	var heading_text := tr("hud.compass.heading_unknown")
	if _controller != null:
		var rounded_heading := int(round(_heading_degrees)) % 360
		var cardinal_index := int(round(_heading_degrees / 45.0)) % CARDINAL_KEYS.size()
		heading_text = tr("hud.compass.heading_format") % [rounded_heading, tr(CARDINAL_KEYS[cardinal_index])]
	draw_string(font, Vector2(0.0, 75.0), heading_text, HORIZONTAL_ALIGNMENT_CENTER, size.x, 16, label_color)


func _update_screen_position() -> void:
	var layout := compute_layout_rect(get_viewport_rect().size, _get_ui_scale())
	position = layout.position
	size = layout.size
	queue_redraw()


func _get_ui_scale() -> float:
	return clampf(float(_quality_manager.call("get_ui_scale_factor")), 0.9, 1.75) if _quality_manager != null and _quality_manager.has_method("get_ui_scale_factor") else 1.0


static func compute_layout_rect(viewport_size: Vector2, ui_scale: float) -> Rect2:
	var width := maxf(viewport_size.x, 1.0)
	var scale := clampf(ui_scale, 0.9, 1.75)
	var margin := 18.0 * scale
	var left_reserved := minf(300.0 * scale, width * 0.30) + margin + 12.0 * scale
	var right_reserved := minf(220.0 * scale, width * 0.24) + margin + 12.0 * scale
	var lane_left := minf(left_reserved, width * 0.48)
	var lane_right := maxf(width - right_reserved, lane_left)
	var lane_width := maxf(lane_right - lane_left, 1.0)
	var widget_width := minf(400.0 * scale, lane_width)
	var widget_height := 86.0 * scale
	return Rect2(Vector2(lane_left + (lane_width - widget_width) * 0.5, margin), Vector2(widget_width, widget_height))
