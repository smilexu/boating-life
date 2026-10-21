extends Control

signal time_changed(cycle_offset: float, committed: bool)

var chart_kind := "wind"
var title_text := ""
var subtitle_text := ""
var series: Array[Dictionary] = []
var range_start_cycle := 0.0
var range_end_cycle := 24.0
var selected_cycle := 0.0
var hover_cycle := -1.0
var hover_position := Vector2.ZERO

const PANEL := Color("101e29")
const GRID := Color(0.25, 0.37, 0.43, 0.8)
const TEXT := Color("c9d5dc")
const MUTED := Color("90a5b0")


func _ready() -> void:
	custom_minimum_size = Vector2(600, 250)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_STOP
	queue_redraw()


func set_chart_data(kind: String, title: String, subtitle: String, chart_series: Array, range_start: float, range_end: float, selected: float) -> void:
	chart_kind = kind
	title_text = title
	subtitle_text = subtitle
	series.clear()
	for line in chart_series:
		if line is Dictionary:
			series.append(line.duplicate(true))
	range_start_cycle = range_start
	range_end_cycle = maxf(range_start + 0.001, range_end)
	selected_cycle = selected
	queue_redraw()


func set_selected_cycle(value: float) -> void:
	selected_cycle = value
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), PANEL, true)
	draw_string(ThemeDB.fallback_font, Vector2(16, 26), title_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 17, TEXT)
	draw_string(ThemeDB.fallback_font, Vector2(16, 45), subtitle_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, MUTED)
	var plot := _plot_rect()
	if plot.size.x <= 1.0 or plot.size.y <= 1.0:
		return
	var y_range := _value_range()
	var y_min := float(y_range.x)
	var y_max := float(y_range.y)
	for step in range(5):
		var fraction := float(step) / 4.0
		var y := plot.position.y + plot.size.y * fraction
		draw_line(Vector2(plot.position.x, y), Vector2(plot.end.x, y), GRID, 1.0)
		var axis_value := lerpf(y_max, y_min, fraction)
		var axis_text := _format_axis(axis_value)
		draw_string(ThemeDB.fallback_font, Vector2(4, y + 4), axis_text, HORIZONTAL_ALIGNMENT_LEFT, 72, 11, MUTED)
	if chart_kind == "cloud_precip":
		var right_max := _right_axis_max()
		draw_string(ThemeDB.fallback_font, Vector2(size.x - 72, plot.position.y + 10), "%.1f" % right_max, HORIZONTAL_ALIGNMENT_RIGHT, 66, 11, Color("efb988"))
		draw_string(ThemeDB.fallback_font, Vector2(size.x - 72, plot.end.y), "0 mm/h", HORIZONTAL_ALIGNMENT_RIGHT, 66, 11, Color("efb988"))
	_draw_x_axis(plot)
	for line in series:
		_draw_series(plot, line, y_min, y_max)
	var focus := hover_cycle if hover_cycle >= range_start_cycle and hover_cycle <= range_end_cycle else selected_cycle
	var focus_x := _cycle_to_x(plot, focus)
	draw_line(Vector2(focus_x, plot.position.y), Vector2(focus_x, plot.end.y), Color(1.0, 0.91, 0.67, 0.72), 1.4)
	_draw_hover_tooltip(plot)
	_draw_legend()


func _draw_series(plot: Rect2, line: Dictionary, y_min: float, y_max: float) -> void:
	var points_value: Variant = line.get("points", [])
	if not points_value is Array:
		return
	var axis := str(line.get("axis", "left"))
	var line_min := 0.0
	var line_max := _right_axis_max() if axis == "right" and chart_kind == "cloud_precip" else y_max
	if axis != "right":
		line_min = y_min
		line_max = y_max
	var polyline := PackedVector2Array()
	for value in points_value:
		if not value is Dictionary or value.get("value", null) == null:
			if polyline.size() > 1:
				draw_polyline(polyline, line.get("color", TEXT), float(line.get("width", 2.2)), true)
			polyline.clear()
			continue
		var cycle := float(value.get("cycle", range_start_cycle))
		if cycle < range_start_cycle or cycle > range_end_cycle:
			continue
		var number := float(value["value"])
		var fraction := clampf((number - line_min) / maxf(0.001, line_max - line_min), 0.0, 1.0)
		var x := _cycle_to_x(plot, cycle)
		var y := plot.end.y - fraction * plot.size.y
		polyline.append(Vector2(x, y))
	if polyline.size() > 1:
		draw_polyline(polyline, line.get("color", TEXT), float(line.get("width", 2.2)), true)


func _draw_legend() -> void:
	var x := 92.0
	var y := 16.0
	for line in series:
		var color: Color = line.get("color", TEXT)
		draw_line(Vector2(x, y), Vector2(x + 18.0, y), color, 2.6)
		draw_string(ThemeDB.fallback_font, Vector2(x + 23.0, y + 4.0), str(line.get("name", "")), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, TEXT)
		x += 30.0 + float(str(line.get("name", "")).length()) * 7.4


func _draw_hover_tooltip(plot: Rect2) -> void:
	if hover_cycle < range_start_cycle or hover_cycle > range_end_cycle:
		return
	var lines: Array[Dictionary] = []
	for line in series:
		var value: Variant = _sample_line_at(line.get("points", []), hover_cycle)
		lines.append({"line": line, "value": value})
	var box_width := 304.0
	var box_height := 34.0 + float(lines.size()) * 19.0
	var box_position := hover_position + Vector2(14.0, 14.0)
	box_position.x = clampf(box_position.x, 4.0, maxf(4.0, size.x - box_width - 4.0))
	box_position.y = clampf(box_position.y, plot.position.y + 2.0, maxf(plot.position.y + 2.0, plot.end.y - box_height))
	draw_rect(Rect2(box_position, Vector2(box_width, box_height)), Color(0.035, 0.075, 0.105, 0.97), true)
	draw_rect(Rect2(box_position, Vector2(box_width, box_height)), Color(0.38, 0.55, 0.62, 0.95), false, 1.0)
	draw_string(ThemeDB.fallback_font, box_position + Vector2(9.0, 18.0), "日轮偏移 %.2f" % hover_cycle, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, TEXT)
	for index in range(lines.size()):
		var entry: Dictionary = lines[index]
		var line: Dictionary = entry["line"]
		var value: Variant = entry["value"]
		var text := "%s  %s" % [str(line.get("name", "")), _format_tooltip_value(value, str(line.get("axis", "left")))]
		draw_string(ThemeDB.fallback_font, box_position + Vector2(9.0, 37.0 + float(index) * 19.0), text, HORIZONTAL_ALIGNMENT_LEFT, box_width - 18.0, 12, line.get("color", TEXT))


func _sample_line_at(points_value: Variant, cycle: float) -> Variant:
	if not points_value is Array:
		return null
	var previous: Dictionary = {}
	for point_value in points_value:
		if not point_value is Dictionary or point_value.get("value", null) == null:
			previous.clear()
			continue
		var point: Dictionary = point_value
		var point_cycle := float(point.get("cycle", range_start_cycle))
		if absf(point_cycle - cycle) < 0.0001:
			return float(point["value"])
		if point_cycle < cycle:
			previous = point
			continue
		if previous.is_empty():
			return null
		var previous_cycle := float(previous.get("cycle", range_start_cycle))
		var span := point_cycle - previous_cycle
		if span <= 0.0:
			return float(point["value"])
		return lerpf(float(previous["value"]), float(point["value"]), clampf((cycle - previous_cycle) / span, 0.0, 1.0))
	return float(previous["value"]) if not previous.is_empty() else null


func _format_tooltip_value(value: Variant, axis: String) -> String:
	if value == null or not (value is int or value is float) or not is_finite(float(value)):
		return "N/A"
	var number := float(value)
	if chart_kind == "direction":
		var bearing := fposmod(number, 360.0)
		return "%03.0f° %s" % [bearing, _compass_quadrant(bearing)]
	if chart_kind == "cloud_precip":
		return "%.1f %s" % [number, "mm/h" if axis == "right" else "%"]
	return "%.2f m/s" % number


func _draw_x_axis(plot: Rect2) -> void:
	var tick_count := 4
	for index in range(tick_count + 1):
		var fraction := float(index) / float(tick_count)
		var cycle := lerpf(range_start_cycle, range_end_cycle, fraction)
		var x := plot.position.x + plot.size.x * fraction
		draw_line(Vector2(x, plot.end.y), Vector2(x, plot.end.y + 4.0), MUTED, 1.0)
		draw_string(ThemeDB.fallback_font, Vector2(x - 22.0, plot.end.y + 18.0), "%.1f" % cycle, HORIZONTAL_ALIGNMENT_CENTER, 44, 11, MUTED)
	draw_string(ThemeDB.fallback_font, Vector2(plot.end.x - 116.0, size.y - 5.0), "游戏日轮偏移", HORIZONTAL_ALIGNMENT_RIGHT, 112, 11, MUTED)


func _format_axis(value: float) -> String:
	match chart_kind:
		"wind": return "%.0f m/s" % value
		"cloud_precip": return "%.0f%%" % value
		"direction":
			var bearing := fposmod(value, 360.0)
			return "%03.0f° %s" % [bearing, _compass_quadrant(bearing)]
	return "%.1f" % value


func _compass_quadrant(degrees: float) -> String:
	var dirs := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
	return dirs[int(round(fposmod(degrees, 360.0) / 45.0)) % dirs.size()]


func _value_range() -> Vector2:
	if chart_kind == "cloud_precip":
		return Vector2(0.0, 100.0)
	var minimum := INF
	var maximum := -INF
	for line in series:
		if str(line.get("axis", "left")) == "right":
			continue
		for point in line.get("points", []):
			if not point is Dictionary or point.get("value", null) == null:
				continue
			var cycle := float(point.get("cycle", range_start_cycle))
			if cycle < range_start_cycle or cycle > range_end_cycle:
				continue
			var value := float(point["value"])
			minimum = minf(minimum, value)
			maximum = maxf(maximum, value)
	if not is_finite(minimum) or not is_finite(maximum):
		return Vector2(0.0, 1.0)
	if chart_kind == "wind":
		minimum = 0.0
		maximum = maxf(5.0, ceil(maximum / 5.0) * 5.0)
	else:
		var padding := maxf(8.0, (maximum - minimum) * 0.12)
		minimum -= padding
		maximum += padding
	return Vector2(minimum, maximum)


func _right_axis_max() -> float:
	var maximum := 0.0
	for line in series:
		if str(line.get("axis", "left")) != "right":
			continue
		for point in line.get("points", []):
			if point is Dictionary and point.get("value", null) != null:
				maximum = maxf(maximum, float(point["value"]))
	return maxf(1.0, ceil(maximum * 1.2 * 2.0) / 2.0)


func _plot_rect() -> Rect2:
	return Rect2(Vector2(84, 54), Vector2(maxf(1.0, size.x - 162), maxf(1.0, size.y - 94)))


func _cycle_to_x(plot: Rect2, cycle: float) -> float:
	return plot.position.x + clampf((cycle - range_start_cycle) / maxf(0.001, range_end_cycle - range_start_cycle), 0.0, 1.0) * plot.size.x


func _gui_input(event: InputEvent) -> void:
	var plot := _plot_rect()
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if plot.has_point(motion.position):
			hover_cycle = range_start_cycle + (motion.position.x - plot.position.x) / plot.size.x * (range_end_cycle - range_start_cycle)
			hover_position = motion.position
			time_changed.emit(hover_cycle, false)
		else:
			hover_cycle = -1.0
		queue_redraw()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed and plot.has_point(event.position):
		var cycle: float = range_start_cycle + (event.position.x - plot.position.x) / plot.size.x * (range_end_cycle - range_start_cycle)
		selected_cycle = cycle
		hover_cycle = cycle
		hover_position = event.position
		time_changed.emit(cycle, true)
		queue_redraw()
