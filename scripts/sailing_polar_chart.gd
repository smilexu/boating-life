extends Control
## Lightweight, read-only Polar Diagram for the official Nordic 28 dataset.

const DATA_PATH := "res://resources/sailing/nordic28_polar.json"
const KNOTS_PER_MPS := 1.9438444924406
const COLORS_BY_TWS := {
	4.0: Color("#66c7bd"),
	8.0: Color("#86c967"),
	12.0: Color("#f0c45c"),
	16.0: Color("#f18c55"),
	20.0: Color("#e87578"),
}
const PANEL := Color(0.025, 0.085, 0.11, 0.96)
const GRID := Color(0.61, 0.76, 0.77, 0.25)
const LABEL := Color(0.86, 0.93, 0.92, 0.94)
const MUTED := Color(0.60, 0.74, 0.75, 0.94)
const CURRENT := Color(0.38, 0.91, 0.99, 1.0)

var _dataset: Dictionary = {}
var _measurement_index: Dictionary = {}
var _reference_series_cache: Dictionary = {}
var _current_curve_cache_key := ""
var _current_curve_cache: Dictionary = {}
var _recommendations_cache_key := ""
var _recommendations_cache: Dictionary = {}
var _snapshot: Dictionary = {}
var _deployment: Dictionary = {}
var _current_tws_kn := 0.0
var _current_twa_deg := 0.0
var _current_stw_kn := 0.0
var _target_tws_kn := 0.0
var _target_twa_deg := 0.0
var _target_stw_kn := 0.0
var _data_error := ""
var _detail_text := ""


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(780.0, 520.0)
	_load_dataset()
	set_process(true)


func set_current_state(snapshot: Dictionary) -> void:
	_snapshot = snapshot
	_deployment = snapshot.get("sail_deployment", {})
	_target_tws_kn = float(snapshot.get("true_wind_speed_mps", 0.0)) * KNOTS_PER_MPS if bool(snapshot.get("true_wind_valid", false)) else 0.0
	_target_twa_deg = float(snapshot.get("true_wind_from_relative_degrees", 0.0)) if bool(snapshot.get("true_wind_valid", false)) else 0.0
	# The runtime model has no current system; SOG is the boat's speed through water.
	_target_stw_kn = float(snapshot.get("sog_knots", 0.0))
	_refresh_detail_text()


func set_dataset_for_test(dataset: Dictionary) -> void:
	_dataset = dataset.duplicate(true)
	_data_error = ""
	_prepare_dataset_cache()
	queue_redraw()


func get_dataset_validation() -> Dictionary:
	return _validate_dataset(_dataset)


func get_current_detail_text() -> String:
	return _detail_text


func _process(delta: float) -> void:
	var blend := 1.0 - exp(-maxf(delta, 0.0) * 6.0)
	var changed := false
	var next_tws := lerpf(_current_tws_kn, _target_tws_kn, blend)
	var next_twa := lerpf(_current_twa_deg, _target_twa_deg, blend)
	var next_stw := lerpf(_current_stw_kn, _target_stw_kn, blend)
	changed = absf(next_tws - _current_tws_kn) > 0.01 or absf(next_twa - _current_twa_deg) > 0.05 or absf(next_stw - _current_stw_kn) > 0.01
	_current_tws_kn = next_tws
	_current_twa_deg = next_twa
	_current_stw_kn = next_stw
	if changed:
		queue_redraw()


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	draw_rect(rect, PANEL, true)
	if not _data_error.is_empty():
		_draw_message("Polar 数据不可用\n" + _data_error)
		return
	var validation := _validate_dataset(_dataset)
	if not bool(validation.get("valid", false)):
		_draw_message("Polar 数据校验失败\n" + str(validation.get("reason", "未知错误")))
		return
	var font := get_theme_default_font()
	if font == null:
		return
	var center := Vector2(size.x * 0.5, size.y * 0.53)
	var radius := minf(size.x * 0.405, size.y * 0.405)
	if radius < 80.0:
		return
	var max_speed := _maximum_valid_speed_kn()
	var radial_step := _radial_step(max_speed)
	var radial_max := ceilf(max_speed / radial_step) * radial_step
	var scale_radius := radius / maxf(radial_max, radial_step)
	_draw_grid(font, center, radius, radial_max, radial_step)
	_draw_reference_curves(center, scale_radius)
	_draw_current_wind_curve(center, scale_radius)
	_draw_current_marker(font, center, scale_radius)
	_draw_legend(font, center, radius)
	_draw_recommendations(font, center, scale_radius)


func _draw_grid(font: Font, center: Vector2, radius: float, radial_max: float, radial_step: float) -> void:
	var ring_value := radial_step
	while ring_value <= radial_max + 0.001:
		var ring_radius := radius * ring_value / radial_max
		draw_arc(center, ring_radius, 0.0, TAU, 96, GRID, 1.0, true)
		draw_string(font, center + Vector2(5.0, -ring_radius + 14.0), "%.0f kn" % ring_value, HORIZONTAL_ALIGNMENT_LEFT, 54.0, 11, MUTED)
		ring_value += radial_step
	for angle in [30.0, 60.0, 90.0, 120.0, 150.0]:
		var direction := _direction_for_twa(angle)
		draw_line(center, center + direction * radius, GRID, 1.0, true)
		var mirror := _direction_for_twa(-angle)
		draw_line(center, center + mirror * radius, GRID, 1.0, true)
	draw_line(center + Vector2(0.0, -radius), center + Vector2(0.0, radius), GRID, 1.0, true)
	var labels := [
		[Vector2(center.x, center.y - radius - 8.0), "0° 迎风", HORIZONTAL_ALIGNMENT_CENTER],
		[Vector2(center.x + radius + 6.0, center.y + 4.0), "+90°", HORIZONTAL_ALIGNMENT_LEFT],
		[Vector2(center.x, center.y + radius + 20.0), "180° 顺风", HORIZONTAL_ALIGNMENT_CENTER],
		[Vector2(center.x - radius - 6.0, center.y + 4.0), "−90°", HORIZONTAL_ALIGNMENT_RIGHT],
	]
	for item in labels:
		draw_string(font, item[0], item[1], item[2], 110.0, 12, LABEL)


func _draw_reference_curves(center: Vector2, scale_radius: float) -> void:
	var wind_grid: Array = _dataset.get("tws_grid_kn", [])
	for wind_value in wind_grid:
		var tws := float(wind_value)
		var color: Color = COLORS_BY_TWS.get(tws, Color.WHITE)
		var cached: Dictionary = _reference_series_cache.get(tws, {})
		for points in [cached.get("positive", []), cached.get("negative", [])]:
			_draw_contiguous_series(center, scale_radius, points, color, 2.0, false)


func _draw_current_wind_curve(center: Vector2, scale_radius: float) -> void:
	if _current_tws_kn <= 0.0:
		return
	_ensure_current_curve_cache()
	for points in [_current_curve_cache.get("positive", []), _current_curve_cache.get("negative", [])]:
		_draw_contiguous_series(center, scale_radius, points, CURRENT, 1.4, true)


func _draw_contiguous_series(center: Vector2, scale_radius: float, samples: Array[Dictionary], color: Color, width: float, dashed: bool) -> void:
	var previous := Vector2.ZERO
	var previous_angle := -999.0
	var has_previous := false
	for sample in samples:
		if not bool(sample.get("valid", false)):
			has_previous = false
			continue
		var angle := float(sample.get("signed_twa_deg", 0.0))
		var speed := float(sample.get("sog_kn", NAN))
		if not is_finite(speed) or speed <= 0.0:
			has_previous = false
			continue
		var position := center + _direction_for_twa(angle) * speed * scale_radius
		if has_previous and absf(absf(angle) - absf(previous_angle)) <= 10.01:
			if not dashed:
				draw_line(previous, position, color, width, true)
			else:
				_draw_dashed_line(previous, position, color, width)
		draw_circle(position, 2.8 if not dashed else 1.8, color)
		previous = position
		previous_angle = angle
		has_previous = true


func _draw_current_marker(font: Font, center: Vector2, scale_radius: float) -> void:
	if _target_tws_kn <= 0.1:
		return
	var point := center + _direction_for_twa(_current_twa_deg) * _current_stw_kn * scale_radius
	draw_circle(point, 7.0, Color(0.02, 0.08, 0.1, 1.0))
	draw_arc(point, 8.5, 0.0, TAU, 32, CURRENT, 2.0, true)
	draw_line(point + Vector2(-5, 0), point + Vector2(5, 0), CURRENT, 1.4)
	draw_line(point + Vector2(0, -5), point + Vector2(0, 5), CURRENT, 1.4)
	draw_string(font, point + Vector2(10.0, -8.0), "当前", HORIZONTAL_ALIGNMENT_LEFT, 46.0, 11, CURRENT)


func _draw_legend(font: Font, center: Vector2, radius: float) -> void:
	var x := maxf(14.0, center.x - radius)
	var y := size.y - 36.0
	var wind_grid: Array = _dataset.get("tws_grid_kn", [])
	for index in range(wind_grid.size()):
		var tws := float(wind_grid[index])
		var color: Color = COLORS_BY_TWS.get(tws, Color.WHITE)
		var item_x := x + float(index) * 82.0
		draw_line(Vector2(item_x, y), Vector2(item_x + 20.0, y), color, 3.0, true)
		draw_string(font, Vector2(item_x + 25.0, y + 4.0), "%.0f kn" % tws, HORIZONTAL_ALIGNMENT_LEFT, 50.0, 11, LABEL)
	var current_x := x + 5.0 * 82.0
	draw_line(Vector2(current_x, y), Vector2(current_x + 20.0, y), CURRENT, 2.0, true)
	draw_string(font, Vector2(current_x + 25.0, y + 4.0), "当前风速插值", HORIZONTAL_ALIGNMENT_LEFT, 110.0, 11, LABEL)


func _draw_recommendations(font: Font, center: Vector2, scale_radius: float) -> void:
	var recommendations := _current_recommendations()
	var fastest: Dictionary = recommendations.get("fastest", {})
	if not fastest.is_empty():
		var marker := center + _direction_for_twa(float(fastest["angle"])) * float(fastest["speed"]) * scale_radius
		_draw_diamond(marker, Color(1.0, 0.96, 0.78, 0.98), 5.5)
	var upwind: Dictionary = recommendations.get("upwind", {})
	var downwind: Dictionary = recommendations.get("downwind", {})
	var y := 22.0
	var text := "当前风速参考"
	if not fastest.is_empty():
		text += "  ·  最快 %.2f kn @ %+.0f°" % [float(fastest["speed"]), float(fastest["angle"])]
	if not upwind.is_empty():
		text += "  ·  迎风 VMG %.2f kn @ %+.0f°" % [float(upwind["vmg"]), float(upwind["angle"])]
	if not downwind.is_empty():
		text += "  ·  顺风 VMG %.2f kn @ %+.0f°" % [float(downwind["vmg"]), float(downwind["angle"])]
	draw_string(font, Vector2(14.0, y), text, HORIZONTAL_ALIGNMENT_LEFT, size.x - 28.0, 12, CURRENT)


func _draw_message(message: String) -> void:
	var font := get_theme_default_font()
	if font != null:
		draw_string(font, Vector2(22.0, 40.0), message, HORIZONTAL_ALIGNMENT_LEFT, size.x - 44.0, 16, Color(1.0, 0.75, 0.58, 1.0))


func _draw_dashed_line(from: Vector2, to: Vector2, color: Color, width: float) -> void:
	var distance := from.distance_to(to)
	if distance <= 0.001:
		return
	var direction := (to - from) / distance
	var along := 0.0
	while along < distance:
		var end := minf(along + 7.0, distance)
		draw_line(from + direction * along, from + direction * end, color, width, true)
		along += 12.0


func _draw_diamond(center: Vector2, color: Color, extent: float) -> void:
	var points := PackedVector2Array([
		center + Vector2(0.0, -extent), center + Vector2(extent, 0.0),
		center + Vector2(0.0, extent), center + Vector2(-extent, 0.0),
	])
	draw_colored_polygon(points, color)


func _direction_for_twa(twa_deg: float) -> Vector2:
	var radians := deg_to_rad(twa_deg)
	return Vector2(sin(radians), -cos(radians))


func _series_for_tws_and_side(tws: float, side: float) -> Array[Dictionary]:
	var samples: Array[Dictionary] = []
	for angle in range(0, 181, 10):
		var signed_angle := 0.0 if angle == 0 or angle == 180 else -float(angle) * side
		var result := _measurement_for_angle(tws, signed_angle)
		if result.is_empty():
			samples.append({"valid": false})
		else:
			result["valid"] = _is_valid_polar_point(result)
			result["signed_twa_deg"] = signed_angle
			samples.append(result)
	return samples


func _find_measurement(tws: float, signed_twa: float) -> Dictionary:
	var indexed: Variant = _measurement_index.get(_measurement_key(tws, signed_twa), null)
	if indexed is Dictionary:
		return indexed.duplicate(true)
	var measurements: Array = _dataset.get("measurements", [])
	for row in measurements:
		if not row is Dictionary:
			continue
		if absf(float(row.get("target_tws_kn", -1000.0)) - tws) < 0.01 and absf(float(row.get("target_twa_deg_signed", row.get("target_twa_deg", 999.0))) - signed_twa) < 0.01:
			return row.duplicate(true)
	return {}


func _measurement_for_angle(tws: float, signed_twa: float) -> Dictionary:
	var result := _find_measurement(tws, signed_twa)
	if result.is_empty() and _mirror_allowed():
		result = _find_measurement(tws, -signed_twa)
	return result


func _interpolated_point(tws: float, signed_twa: float) -> Dictionary:
	var low_tws := -INF
	var high_tws := INF
	var wind_grid: Array = _dataset.get("tws_grid_kn", [])
	for wind_value in wind_grid:
		var value := float(wind_value)
		if value <= tws + 0.001:
			low_tws = maxf(low_tws, value)
		if value >= tws - 0.001:
			high_tws = minf(high_tws, value)
	if not is_finite(low_tws) or not is_finite(high_tws):
		return {}
	var low := _interpolated_angle_point(low_tws, signed_twa)
	if low.is_empty():
		return {}
	if is_equal_approx(low_tws, high_tws):
		return low
	var high := _interpolated_angle_point(high_tws, signed_twa)
	if high.is_empty():
		return {}
	var amount := inverse_lerp(low_tws, high_tws, tws)
	return {
		"valid": true,
		"sog_kn": lerpf(float(low["sog_kn"]), float(high["sog_kn"]), amount),
		"vmg_upwind_kn": lerpf(float(low["vmg_upwind_kn"]), float(high["vmg_upwind_kn"]), amount),
		"vmg_downwind_kn": lerpf(float(low["vmg_downwind_kn"]), float(high["vmg_downwind_kn"]), amount),
		"signed_twa_deg": signed_twa,
	}


func _interpolated_angle_point(tws: float, signed_twa: float) -> Dictionary:
	var exact := _measurement_for_angle(tws, signed_twa)
	if not exact.is_empty():
		return exact if _is_valid_polar_point(exact) else {}
	var angle_abs := absf(signed_twa)
	var lower := floorf(angle_abs / 10.0) * 10.0
	var upper := ceilf(angle_abs / 10.0) * 10.0
	if is_equal_approx(lower, upper):
		return {}
	var sign := -1.0 if signed_twa < 0.0 else 1.0
	var first := _measurement_for_angle(tws, sign * lower)
	var second := _measurement_for_angle(tws, sign * upper)
	if first.is_empty() or second.is_empty() or not _is_valid_polar_point(first) or not _is_valid_polar_point(second):
		return {}
	var amount := inverse_lerp(lower, upper, angle_abs)
	return {
		"sog_kn": lerpf(float(first["sog_kn"]), float(second["sog_kn"]), amount),
		"vmg_upwind_kn": lerpf(float(first.get("vmg_upwind_kn", 0.0)), float(second.get("vmg_upwind_kn", 0.0)), amount),
		"vmg_downwind_kn": lerpf(float(first.get("vmg_downwind_kn", 0.0)), float(second.get("vmg_downwind_kn", 0.0)), amount),
		"valid": true,
	}


func _current_recommendations() -> Dictionary:
	var cache_key := _current_wind_bucket_key()
	if cache_key == _recommendations_cache_key:
		return _recommendations_cache
	var wind_grid: Array = _dataset.get("tws_grid_kn", [])
	if wind_grid.is_empty() or _current_tws_kn < float(wind_grid[0]) or _current_tws_kn > float(wind_grid[-1]):
		_recommendations_cache_key = cache_key
		_recommendations_cache = {}
		return _recommendations_cache
	var points: Array[Dictionary] = []
	for signed_angle in range(-180, 181, 10):
		var point := _interpolated_point(_current_tws_kn, float(signed_angle))
		if point.is_empty():
			continue
		point["signed_twa_deg"] = float(signed_angle)
		points.append(point)
	var fastest: Dictionary = {}
	var upwind: Dictionary = {}
	var downwind: Dictionary = {}
	var upwind_count := 0
	var downwind_count := 0
	for point in points:
		var angle := float(point["signed_twa_deg"])
		if fastest.is_empty() or float(point["sog_kn"]) > float(fastest["speed"]):
			fastest = {"angle": angle, "speed": float(point["sog_kn"])}
		if absf(angle) <= 90.0:
			upwind_count += 1
			var vmg := float(point.get("vmg_upwind_kn", 0.0))
			if vmg > 0.0 and (upwind.is_empty() or vmg > float(upwind["vmg"])):
				upwind = {"angle": angle, "vmg": vmg}
		if absf(angle) >= 90.0:
			downwind_count += 1
			var vmg := float(point.get("vmg_downwind_kn", 0.0))
			if vmg > 0.0 and (downwind.is_empty() or vmg > float(downwind["vmg"])):
				downwind = {"angle": angle, "vmg": vmg}
	if upwind_count < 2:
		upwind.clear()
	if downwind_count < 2:
		downwind.clear()
	_recommendations_cache_key = cache_key
	_recommendations_cache = {"fastest": fastest, "upwind": upwind, "downwind": downwind}
	return _recommendations_cache


func _refresh_detail_text() -> void:
	var reefed := float(_deployment.get("main_current_deployment", 1.0)) < 0.995 or float(_deployment.get("jib_current_deployment", 1.0)) < 0.995
	var current_text := "TWS %.1f kn  ·  实际 TWA %+.0f°  ·  STW≈SOG %.2f kn" % [_target_tws_kn, _target_twa_deg, _target_stw_kn]
	current_text += "  ·  主帆 %.0f%% / 前帆 %.0f%%" % [float(_deployment.get("main_current_deployment", 1.0)) * 100.0, float(_deployment.get("jib_current_deployment", 1.0)) * 100.0]
	if reefed:
		current_text += "\n当前已缩帆，曲线为 Nordic 28 满帆参考性能。"
	elif not bool(_dataset.get("release_eligible", false)):
		current_text += "\n注意：参考数据未通过完整数据质量门。"
	_detail_text = current_text
	queue_redraw()


func _load_dataset() -> void:
	if not FileAccess.file_exists(DATA_PATH):
		_data_error = "缺少 %s" % DATA_PATH
		return
	var json := JSON.new()
	var error := json.parse(FileAccess.get_file_as_string(DATA_PATH))
	if error != OK or not json.data is Dictionary:
		_data_error = "JSON 解析失败：%s" % json.get_error_message()
		return
	_dataset = json.data
	var validation := _validate_dataset(_dataset)
	if not bool(validation.get("valid", false)):
		_data_error = str(validation.get("reason", "结构无效"))
		return
	_prepare_dataset_cache()


func _prepare_dataset_cache() -> void:
	_measurement_index.clear()
	_reference_series_cache.clear()
	_current_curve_cache.clear()
	_current_curve_cache_key = ""
	_recommendations_cache.clear()
	_recommendations_cache_key = ""
	for row in _dataset.get("measurements", []):
		if not row is Dictionary:
			continue
		var key := _measurement_key(float(row.get("target_tws_kn", 0.0)), float(row.get("target_twa_deg_signed", row.get("target_twa_deg", 0.0))))
		_measurement_index[key] = row
	for wind_value in _dataset.get("tws_grid_kn", []):
		var tws := float(wind_value)
		_reference_series_cache[tws] = {
			"positive": _series_for_tws_and_side(tws, 1.0),
			"negative": _series_for_tws_and_side(tws, -1.0),
		}


func _measurement_key(tws: float, signed_twa: float) -> String:
	return "%0.3f|%+.3f" % [tws, signed_twa]


func _current_wind_bucket_key() -> String:
	return "%0.1f" % (roundf(_current_tws_kn * 10.0) / 10.0)


func _ensure_current_curve_cache() -> void:
	var cache_key := _current_wind_bucket_key()
	if cache_key == _current_curve_cache_key:
		return
	_current_curve_cache_key = cache_key
	var curve_tws := float(cache_key)
	var positive: Array[Dictionary] = []
	var negative: Array[Dictionary] = []
	for angle in range(0, 181, 10):
		for side in [-1.0, 1.0]:
			var signed_angle: float = -float(angle) * float(side)
			var point := _interpolated_point(curve_tws, signed_angle)
			if point.is_empty():
				point = {"valid": false}
			else:
				point["signed_twa_deg"] = signed_angle
			if side < 0.0:
				positive.append(point)
			else:
				negative.append(point)
	_current_curve_cache = {"positive": positive, "negative": negative}


func _validate_dataset(data: Dictionary) -> Dictionary:
	var rows: Variant = data.get("measurements", null)
	var winds: Variant = data.get("tws_grid_kn", null)
	var angles: Variant = data.get("absolute_twa_grid_deg", null)
	if not (rows is Array) or not (winds is Array) or not (angles is Array):
		return {"valid": false, "reason": "缺少 measurements、tws_grid_kn 或 absolute_twa_grid_deg"}
	if winds.is_empty() or angles.is_empty():
		return {"valid": false, "reason": "风速或风角网格为空"}
	for row in rows:
		if not row is Dictionary:
			return {"valid": false, "reason": "存在非对象测量行"}
		if not row.has("status") or not row.has("target_tws_kn") or not row.has("target_twa_deg_signed"):
			return {"valid": false, "reason": "测量行缺少状态或目标工况"}
	return {"valid": true, "measurement_count": rows.size()}


func _is_valid_polar_point(row: Dictionary) -> bool:
	return str(row.get("status", "")) == "STABLE" and float(row.get("sog_kn", 0.0)) > 0.0 and float(row.get("mean_longitudinal_velocity_mps", 0.2)) > 0.10


func _mirror_allowed() -> bool:
	var symmetry: Dictionary = _dataset.get("symmetry_validation", {})
	return bool(symmetry.get("passed", false))


func _maximum_valid_speed_kn() -> float:
	var maximum := 1.0
	for row in _dataset.get("measurements", []):
		if row is Dictionary and _is_valid_polar_point(row):
			maximum = maxf(maximum, float(row.get("sog_kn", 0.0)))
	return maximum


func _display_max_speed() -> float:
	return maxf(_maximum_valid_speed_kn(), 1.0)


func _radial_step(maximum: float) -> float:
	if maximum <= 4.0:
		return 0.5
	if maximum <= 8.0:
		return 1.0
	return 2.0


