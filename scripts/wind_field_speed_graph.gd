extends Control

@export_range(10.0, 600.0, 1.0) var window_seconds := 120.0
@export_range(5.0, 60.0, 1.0) var displayed_max_speed_mps := 30.0

var _samples: Array[Dictionary] = []
var _latest_time_seconds := 0.0
var _mean_speed_mps := 0.0


func append_sample(simulation_time_seconds: float, speed_mps: float, mean_speed_mps: float) -> void:
	if not is_finite(simulation_time_seconds) or not is_finite(speed_mps) or not is_finite(mean_speed_mps):
		return
	if not _samples.is_empty() and simulation_time_seconds < float(_samples.back()["time"]):
		_samples.clear()
	_latest_time_seconds = simulation_time_seconds
	_mean_speed_mps = maxf(mean_speed_mps, 0.0)
	_samples.append({
		"time": simulation_time_seconds,
		"speed": maxf(speed_mps, 0.0),
		"mean": _mean_speed_mps,
	})
	var oldest_allowed := _latest_time_seconds - window_seconds
	while not _samples.is_empty() and float(_samples.front()["time"]) < oldest_allowed:
		_samples.pop_front()
	queue_redraw()


func get_statistics() -> Dictionary:
	if _samples.is_empty():
		return {"current": 0.0, "minimum": 0.0, "maximum": 0.0, "mean": _mean_speed_mps}
	var minimum := INF
	var maximum := -INF
	for sample in _samples:
		var speed := float(sample["speed"])
		minimum = minf(minimum, speed)
		maximum = maxf(maximum, speed)
	return {
		"current": float(_samples.back()["speed"]),
		"minimum": minimum,
		"maximum": maximum,
		"mean": _mean_speed_mps,
	}


func _draw() -> void:
	var bounds := Rect2(Vector2.ZERO, size)
	draw_rect(bounds, Color(0.025, 0.065, 0.085, 0.96), true)
	var chart := Rect2(Vector2(42.0, 14.0), Vector2(maxf(size.x - 52.0, 32.0), maxf(size.y - 42.0, 28.0)))
	var font := ThemeDB.fallback_font
	var y_step := chart.size.y / 4.0
	for index in range(5):
		var y := chart.position.y + y_step * float(index)
		var speed_label := displayed_max_speed_mps * float(4 - index) / 4.0
		draw_line(Vector2(chart.position.x, y), Vector2(chart.end.x, y), Color(0.23, 0.34, 0.39, 0.8), 1.0, true)
		draw_string(font, Vector2(3.0, y + 4.0), "%.0f" % speed_label, HORIZONTAL_ALIGNMENT_LEFT, 36.0, 11, Color(0.70, 0.80, 0.82))
	var mean_y := chart.end.y - clampf(_mean_speed_mps / maxf(displayed_max_speed_mps, 1.0), 0.0, 1.0) * chart.size.y
	draw_line(Vector2(chart.position.x, mean_y), Vector2(chart.end.x, mean_y), Color(0.96, 0.70, 0.34, 0.85), 1.5, true)
	draw_string(font, Vector2(chart.position.x + 4.0, mean_y - 4.0), "平均", HORIZONTAL_ALIGNMENT_LEFT, 36.0, 10, Color(0.98, 0.77, 0.44))
	draw_string(font, Vector2(chart.position.x, size.y - 5.0), "t−120 s", HORIZONTAL_ALIGNMENT_LEFT, 72.0, 10, Color(0.70, 0.80, 0.82))
	draw_string(font, Vector2(chart.end.x - 44.0, size.y - 5.0), "现在", HORIZONTAL_ALIGNMENT_RIGHT, 44.0, 10, Color(0.70, 0.80, 0.82))
	if _samples.size() < 2:
		return
	var points := PackedVector2Array()
	var oldest_visible := _latest_time_seconds - window_seconds
	for sample in _samples:
		var normalized_time := clampf((float(sample["time"]) - oldest_visible) / window_seconds, 0.0, 1.0)
		var normalized_speed := clampf(float(sample["speed"]) / maxf(displayed_max_speed_mps, 1.0), 0.0, 1.0)
		points.append(Vector2(
			chart.position.x + chart.size.x * normalized_time,
			chart.end.y - normalized_speed * chart.size.y
		))
	draw_polyline(points, Color(0.80, 0.91, 0.55), 2.5, true)
