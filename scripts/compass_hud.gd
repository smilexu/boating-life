extends Control

## Compact heading ribbon. The fixed pointer marks the boat's current heading;
## compass bearings slide beneath it as the boat turns.

const CARDINALS := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
const RIBBON_HALF_ANGLE_DEGREES := 70.0

var _controller: BoatController
var _heading_degrees := 0.0
var _panel_style: StyleBoxFlat


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
			var cardinal_index := int(tick_bearing / 45) % CARDINALS.size()
			var color := Color(1.0, 0.68, 0.42, 1.0) if cardinal_index == 0 else label_color
			draw_string(font, Vector2(x - 20.0, 25.0), CARDINALS[cardinal_index], HORIZONTAL_ALIGNMENT_CENTER, 40.0, 13, color)

	var pointer := PackedVector2Array([
		Vector2(center_x, 30.0),
		Vector2(center_x - 7.0, 41.0),
		Vector2(center_x + 7.0, 41.0),
	])
	draw_colored_polygon(pointer, Color(1.0, 0.62, 0.34, 1.0))
	draw_line(Vector2(18.0, scale_y), Vector2(size.x - 18.0, scale_y), Color(0.7, 0.82, 0.83, 0.32), 1.0, true)
	var heading_text := "航向  --"
	if _controller != null:
		var rounded_heading := int(round(_heading_degrees)) % 360
		var cardinal_index := int(round(_heading_degrees / 45.0)) % CARDINALS.size()
		heading_text = "航向  %03d°  %s" % [rounded_heading, CARDINALS[cardinal_index]]
	draw_string(font, Vector2(0.0, 75.0), heading_text, HORIZONTAL_ALIGNMENT_CENTER, size.x, 16, label_color)


func _update_screen_position() -> void:
	var viewport_width := get_viewport_rect().size.x
	var widget_width := minf(400.0, maxf(280.0, viewport_width - 48.0))
	size = Vector2(widget_width, 86.0)
	if viewport_width >= 1400.0:
		position = Vector2((viewport_width - widget_width) * 0.5, 18.0)
	else:
		position = Vector2(24.0, 162.0)
	queue_redraw()
