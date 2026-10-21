extends Control

var wind_vector := Vector3.ZERO


func set_wind_vector(value: Vector3) -> void:
	wind_vector = value
	queue_redraw()


func _draw() -> void:
	var center := size * 0.5
	var radius := minf(size.x, size.y) * 0.34
	draw_circle(center, radius, Color(0.035, 0.10, 0.14, 0.9))
	draw_arc(center, radius, 0.0, TAU, 64, Color(0.38, 0.56, 0.61), 1.5, true)
	var font := ThemeDB.fallback_font
	var label_color := Color(0.82, 0.91, 0.90)
	draw_string(font, center + Vector2(-4.0, -radius - 8.0), "N", HORIZONTAL_ALIGNMENT_CENTER, -1, 13, label_color)
	draw_string(font, center + Vector2(radius + 7.0, 4.0), "E", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, label_color)
	draw_string(font, center + Vector2(-4.0, radius + 19.0), "S", HORIZONTAL_ALIGNMENT_CENTER, -1, 13, label_color)
	draw_string(font, center + Vector2(-radius - 16.0, 4.0), "W", HORIZONTAL_ALIGNMENT_RIGHT, -1, 13, label_color)
	var horizontal := Vector2(wind_vector.x, wind_vector.z)
	if horizontal.length_squared() < 0.000001:
		draw_circle(center, 4.0, Color(0.78, 0.84, 0.85))
		return
	# Canvas Y points down, matching world south (+Z); this depicts air-flow TO, not FROM.
	var direction := Vector2(horizontal.x, horizontal.y).normalized()
	var tip := center + direction * radius * 0.78
	var tail := center - direction * radius * 0.38
	draw_line(tail, tip, Color(0.88, 0.78, 0.37), 3.0, true)
	var side := Vector2(-direction.y, direction.x)
	var head := PackedVector2Array([tip, tip - direction * 13.0 + side * 6.5, tip - direction * 13.0 - side * 6.5])
	draw_colored_polygon(head, Color(0.98, 0.86, 0.42))
