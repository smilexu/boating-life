class_name FishFinderDisplay
extends Control

## Player-facing 2D CHIRP-style view over the bounded FishFinderSensor history.

signal close_requested
signal display_mode_changed(mode: String)

const HISTORY_WINDOW_SECONDS := 60.0
const DEPTH_RANGES_M := [5.0, 10.0, 20.0, 30.0, 50.0]
const RANGE_SHRINK_HYSTERESIS := 0.70
const RANGE_SHRINK_HOLD_SECONDS := 3.0
const DEFAULT_MANUAL_GAIN_PERCENT := 50.0
const DEFAULT_AUTO_GAIN_PERCENT := 62.0
const AUTO_GAIN_REFERENCE_STRENGTH := 0.12
const AUTO_GAIN_LOOKBACK_SECONDS := 12.0
const AUTO_GAIN_SMOOTHING_SECONDS := 3.0
const DEBUG_PREVIEW_HISTORY_SECONDS := 60.0
const DEBUG_PREVIEW_DEFAULT_FREQUENCY_HZ := 3.0
const DEBUG_PREVIEW_CYCLE_SECONDS := 12.0
const DEBUG_PREVIEW_INITIAL_SEQUENCE_SECONDS := 4.0
const SONAR_CONTINUOUS_ECHO_GAP_SECONDS := 0.75
const FISH_SYMBOL_MIN_DISPLAY_STRENGTH := 0.22
const LAYOUT_SAFE_MARGIN_PX := 16.0
const BOTTOM_PROBE_MIN_CONTINUITY_DISTANCE_M := 3.0
const BOTTOM_PROBE_MAX_CONTINUITY_DISTANCE_M := 25.0

class SonarPlot extends Control:
	var samples: Array[Dictionary] = []
	var display_range_m := 10.0
	var gain_percent := FishFinderDisplay.DEFAULT_AUTO_GAIN_PERCENT
	var fish_symbols_enabled := false
	var now_runtime_seconds := 0.0
	var _redraw_elapsed := 0.0
	var _time_window_seconds := 60.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		clip_contents = true
		set_process(is_visible_in_tree())

	func _process(delta: float) -> void:
		if not is_visible_in_tree():
			return
		_redraw_elapsed += delta
		if _redraw_elapsed >= 1.0 / 18.0:
			_redraw_elapsed = fmod(_redraw_elapsed, 1.0 / 18.0)
			now_runtime_seconds = float(Time.get_ticks_usec()) / 1000000.0
			queue_redraw()

	func set_scan_data(value: Array[Dictionary], depth_range_m: float, clock_seconds: float, display_gain_percent: float, show_fish_symbols: bool = false) -> void:
		samples = value
		display_range_m = maxf(depth_range_m, 1.0)
		gain_percent = clampf(display_gain_percent, 0.0, 100.0)
		fish_symbols_enabled = show_fish_symbols
		now_runtime_seconds = clock_seconds
		queue_redraw()

	func visible_column_count(clock_seconds: float) -> int:
		var count := 0
		for sample in samples:
			var sample_time := float(sample.get("scan_runtime_seconds", -INF))
			if is_finite(sample_time) and clock_seconds - sample_time <= _time_window_seconds and clock_seconds >= sample_time:
				count += 1
		return count

	func _draw() -> void:
		var bounds := Rect2(Vector2.ZERO, size)
		draw_rect(bounds, Color("06141b"), true)
		if size.x < 80.0 or size.y < 60.0:
			return
		var chart := Rect2(Vector2(10.0, 8.0), Vector2(size.x - 54.0, size.y - 28.0))
		draw_rect(chart, Color("071e29"), true)
		_draw_grid(chart)
		_draw_bottom_echoes(chart)
		_draw_fish_echoes(chart)
		if fish_symbols_enabled:
			_draw_fish_symbols(chart)
		draw_rect(chart, Color(0.42, 0.65, 0.67, 0.8), false, 1.0)
		if samples.is_empty():
			var font := get_theme_default_font()
			draw_string(font, chart.position + chart.size * 0.5 + Vector2(-45.0, 4.0), tr("fish.finder.status.waiting"), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13, Color(0.65, 0.77, 0.79, 0.8))

	func _draw_grid(chart: Rect2) -> void:
		var font := get_theme_default_font()
		var depth_steps := 4
		for index in range(depth_steps + 1):
			var depth_m := display_range_m * float(index) / float(depth_steps)
			var y := FishFinderDisplay.depth_to_y(depth_m, display_range_m, chart.position.y, chart.size.y)
			draw_line(Vector2(chart.position.x, y), Vector2(chart.end.x, y), Color(0.35, 0.52, 0.57, 0.34), 1.0)
			var label := "%.0f m" % depth_m
			draw_string(font, Vector2(chart.end.x + 5.0, y + 4.0), label, HORIZONTAL_ALIGNMENT_LEFT, 45.0, 10, Color(0.70, 0.81, 0.82, 0.9))

		var time_step := 15.0
		var first_tick := floori(now_runtime_seconds / time_step)
		for tick in range(5):
			var tick_time := float(first_tick - tick) * time_step
			var age_seconds := now_runtime_seconds - tick_time
			var x := chart.end.x - age_seconds / _time_window_seconds * chart.size.x
			if x < chart.position.x or x > chart.end.x:
				continue
			draw_line(Vector2(x, chart.position.y), Vector2(x, chart.end.y), Color(0.35, 0.52, 0.57, 0.25), 1.0)
			var time_label := tr("fish.finder.now") if tick == 0 else "-%d %s" % [roundi(age_seconds), tr("fish.finder.seconds_short")]
			draw_string(font, Vector2(x - 16.0, chart.position.y + 13.0), time_label, HORIZONTAL_ALIGNMENT_CENTER, 40.0, 9, Color(0.63, 0.77, 0.79, 0.75))

	func _draw_bottom_echoes(chart: Rect2) -> void:
		var previous: Dictionary = {}
		var max_gap_seconds := FishFinderDisplay.SONAR_CONTINUOUS_ECHO_GAP_SECONDS
		for sample in samples:
			var sample_time := float(sample.get("scan_runtime_seconds", -INF))
			if not is_finite(sample_time) or now_runtime_seconds - sample_time > _time_window_seconds or sample_time > now_runtime_seconds:
				continue
			if not bool(sample.get("bottom_valid", false)):
				previous.clear()
				continue
			var depth_m := float(sample.get("bottom_depth_below_transducer_m", -1.0))
			if not FishFinderDisplay.is_depth_visible(depth_m, display_range_m) or depth_m <= 0.0:
				previous.clear()
				continue
			var x := FishFinderDisplay.scan_time_to_x(sample_time, now_runtime_seconds, _time_window_seconds, chart.position.x, chart.size.x)
			var y := FishFinderDisplay.depth_to_y(depth_m, display_range_m, chart.position.y, chart.size.y)
			if not previous.is_empty():
				var continuity := FishFinderDisplay.evaluate_bottom_sample_connection(previous["sample"], sample, max_gap_seconds)
				if bool(continuity["connect"]):
					var previous_x := float(previous["x"])
					var previous_y := float(previous["y"])
					var echo_thickness_px := minf(18.0, maxf(5.0, chart.size.y * 0.035))
					var warm_band := PackedVector2Array([
						Vector2(previous_x, previous_y), Vector2(x, y),
						Vector2(x, minf(y + echo_thickness_px, chart.end.y)),
						Vector2(previous_x, minf(previous_y + echo_thickness_px, chart.end.y)),
					])
					draw_colored_polygon(warm_band, Color(0.96, 0.25, 0.025, 0.64))
					var fade_band := PackedVector2Array([
						Vector2(previous_x, minf(previous_y + echo_thickness_px, chart.end.y)),
						Vector2(x, minf(y + echo_thickness_px, chart.end.y)),
						Vector2(x, minf(y + echo_thickness_px * 2.7, chart.end.y)),
						Vector2(previous_x, minf(previous_y + echo_thickness_px * 2.7, chart.end.y)),
					])
					draw_colored_polygon(fade_band, Color(0.60, 0.12, 0.035, 0.42))
					draw_line(Vector2(previous_x, previous_y), Vector2(x, y), Color(1.0, 0.77, 0.28, 0.98), 2.2, true)
			previous = {"time": sample_time, "x": x, "y": y, "sample": sample}

	func _draw_fish_echoes(chart: Rect2) -> void:
		var previous_by_school: Dictionary = {}
		var previous_column_time := -INF
		for sample in samples:
			var sample_time := float(sample.get("scan_runtime_seconds", -INF))
			if not is_finite(sample_time) or now_runtime_seconds - sample_time > _time_window_seconds or sample_time > now_runtime_seconds:
				previous_by_school.clear()
				continue
			if previous_column_time > -INF and (sample_time <= previous_column_time or sample_time - previous_column_time > FishFinderDisplay.SONAR_CONTINUOUS_ECHO_GAP_SECONDS):
				previous_by_school.clear()
			previous_column_time = sample_time
			var seen_this_column: Dictionary = {}
			for echo_variant in sample.get("echoes", []):
				if not echo_variant is Dictionary:
					continue
				var echo: Dictionary = echo_variant
				var school_id := str(echo.get("school_id", ""))
				var depth_m := float(echo.get("target_depth_below_transducer_m", -1.0))
				var raw_strength := clampf(float(echo.get("echo_strength", 0.0)), 0.0, 1.0)
				if school_id.is_empty() or not FishFinderDisplay.is_depth_visible(depth_m, display_range_m) or raw_strength <= 0.0:
					continue
				var display_strength := FishFinderDisplay.map_echo_strength(raw_strength, gain_percent)
				if display_strength <= 0.005:
					continue
				var x := FishFinderDisplay.scan_time_to_x(sample_time, now_runtime_seconds, _time_window_seconds, chart.position.x, chart.size.x)
				var y := FishFinderDisplay.depth_to_y(depth_m, display_range_m, chart.position.y, chart.size.y)
				var center := Vector2(x, y)
				var visual := FishFinderDisplay.echo_visual_parameters(echo, sample_time, display_strength, size, display_range_m)
				var current := {
					"time": sample_time,
					"center": center,
					"display_strength": display_strength,
					"radius_x": float(visual["radius_x"]),
					"radius_y": float(visual["radius_y"]),
					"phase": float(visual["phase"]),
					"signal_color": visual["signal_color"],
					"outer_color": visual["outer_color"],
					"body_alpha": float(visual["body_alpha"]),
					"outer_alpha": float(visual["outer_alpha"]),
				}
				if previous_by_school.has(school_id):
					var previous: Dictionary = previous_by_school[school_id]
					if sample_time - float(previous["time"]) <= FishFinderDisplay.SONAR_CONTINUOUS_ECHO_GAP_SECONDS:
						_draw_echo_ribbon(previous, current)
				_draw_echo_blob(center, visual)
				previous_by_school[school_id] = current
				seen_this_column[school_id] = true
			for previous_school_id in previous_by_school.keys():
				if not seen_this_column.has(previous_school_id):
					previous_by_school.erase(previous_school_id)

	func _draw_echo_ribbon(previous: Dictionary, current: Dictionary) -> void:
		var start: Vector2 = previous["center"]
		var finish: Vector2 = current["center"]
		var start_radius := float(previous["radius_y"])
		var finish_radius := float(current["radius_y"])
		var outer := PackedVector2Array([
			start + Vector2(0.0, -start_radius * 1.65),
			finish + Vector2(0.0, -finish_radius * 1.65),
			finish + Vector2(0.0, finish_radius * 1.65),
			start + Vector2(0.0, start_radius * 1.65),
		])
		var outer_color: Color = previous["outer_color"].lerp(current["outer_color"], 0.5)
		outer_color.a = (float(previous["outer_alpha"]) + float(current["outer_alpha"])) * 0.16
		draw_colored_polygon(outer, outer_color)
		var inner := PackedVector2Array([
			start + Vector2(0.0, -start_radius * 0.72),
			finish + Vector2(0.0, -finish_radius * 0.72),
			finish + Vector2(0.0, finish_radius * 0.72),
			start + Vector2(0.0, start_radius * 0.72),
		])
		var body_color: Color = previous["signal_color"].lerp(current["signal_color"], 0.5)
		body_color.a = (float(previous["body_alpha"]) + float(current["body_alpha"])) * 0.22
		draw_colored_polygon(inner, body_color)

	func _draw_echo_blob(center: Vector2, visual: Dictionary) -> void:
		var radius_x := float(visual["radius_x"])
		var radius_y := float(visual["radius_y"])
		var phase := float(visual["phase"])
		var outer: Color = visual["outer_color"]
		outer.a = float(visual["outer_alpha"])
		draw_colored_polygon(FishFinderDisplay.echo_blob_polygon(center, radius_x * 1.28, radius_y * 1.7, phase, 1.0), outer)
		var body_color: Color = visual["signal_color"]
		body_color.a = float(visual["body_alpha"])
		draw_colored_polygon(FishFinderDisplay.echo_blob_polygon(center, radius_x, radius_y, phase, 0.58), body_color)
		var core: Color = visual["core_color"]
		core.a = float(visual["core_alpha"])
		var core_offset := Vector2(cos(phase) * radius_x * 0.08, sin(phase * 1.7) * radius_y * 0.08)
		draw_colored_polygon(FishFinderDisplay.echo_blob_polygon(center + core_offset, radius_x * 0.40, radius_y * 0.43, phase + 0.4, 0.24), core)

	func _draw_fish_symbols(chart: Rect2) -> void:
		var anchors := FishFinderDisplay.collect_fish_symbol_anchors(samples, now_runtime_seconds, _time_window_seconds, display_range_m, gain_percent)
		for anchor in anchors:
			var sample_time := float(anchor["scan_runtime_seconds"])
			var depth_m := float(anchor["target_depth_below_transducer_m"])
			var center := Vector2(
				FishFinderDisplay.scan_time_to_x(sample_time, now_runtime_seconds, _time_window_seconds, chart.position.x, chart.size.x),
				FishFinderDisplay.depth_to_y(depth_m, display_range_m, chart.position.y, chart.size.y)
			)
			if not chart.has_point(center):
				continue
			_draw_fish_symbol(center, clampf(7.0 + float(anchor["display_strength"]) * 5.0, 8.0, 12.0))

	func _draw_fish_symbol(center: Vector2, width: float) -> void:
		var half_height := width * 0.28
		var tail := PackedVector2Array([
			center + Vector2(-width * 0.34, 0.0),
			center + Vector2(-width * 0.68, -half_height),
			center + Vector2(-width * 0.62, 0.0),
			center + Vector2(-width * 0.68, half_height),
		])
		draw_colored_polygon(tail, Color(0.62, 0.20, 0.055, 0.96))
		var body := PackedVector2Array([
			center + Vector2(-width * 0.40, 0.0),
			center + Vector2(-width * 0.24, -half_height * 0.72),
			center + Vector2(width * 0.10, -half_height),
			center + Vector2(width * 0.36, -half_height * 0.52),
			center + Vector2(width * 0.50, 0.0),
			center + Vector2(width * 0.36, half_height * 0.52),
			center + Vector2(width * 0.10, half_height),
			center + Vector2(-width * 0.24, half_height * 0.72),
		])
		draw_colored_polygon(body, Color(1.0, 0.87, 0.43, 0.98))
		draw_circle(center + Vector2(width * 0.28, -half_height * 0.12), 0.75, Color(0.12, 0.10, 0.07, 1.0))


var _manager: Node
var _speed_source: Node
var _sensor: FishFinderSensor
var _plot: SonarPlot
var _depth_value_label: Label
var _speed_value_label: Label
var _range_value_label: Label
var _range_title_label: Label
var _speed_title_label: Label
var _depth_title_label: Label
var _gain_title_label: Label
var _range_setting_title_label: Label
var _footer_label: Label
var _title_label: Label
var _preview_badge: Label
var _expand_button: Button
var _close_button: Button
var _settings_container: VBoxContainer
var _gain_mode_option: OptionButton
var _gain_slider: HSlider
var _gain_value_label: Label
var _range_mode_option: OptionButton
var _manual_range_option: OptionButton
var _fish_symbols_check: CheckBox
var _display_mode := "mini"
var _history: Array[Dictionary] = []
var _debug_preview_history: Array[Dictionary] = []
var _last_scan: Dictionary = {}
var _last_scan_id := -1
var _current_display_range_m := 10.0
var _active_display_range_m := 10.0
var _range_mode := "auto"
var _manual_display_range_m := 10.0
var _range_initialized := false
var _range_shrink_candidate_m := -1.0
var _range_shrink_started_at_seconds := -1.0
var _refresh_elapsed := 0.0
var _overlay_obstruction_rect := Rect2()
var _debug_preview_active := false
var _debug_preview_target_depth_m := 5.0
var _debug_preview_peak_strength := 0.8
var _debug_preview_size_band := "medium"
var _debug_preview_started_runtime_seconds := -1.0
var _debug_preview_last_sample_runtime_seconds := -1.0
var _gain_mode := "auto"
var _manual_gain_percent := DEFAULT_MANUAL_GAIN_PERCENT
var _auto_gain_percent := DEFAULT_AUTO_GAIN_PERCENT
var _auto_gain_last_update_runtime_seconds := -1.0
var _fish_symbols_enabled := false


func configure(manager: Node, speed_source: Node) -> void:
	_manager = manager
	_speed_source = speed_source


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 18
	_build_ui()
	get_viewport().size_changed.connect(_update_layout)
	visibility_changed.connect(_on_visibility_changed)
	_update_layout()
	_refresh_sensor_data(true)
	set_process(is_visible_in_tree())


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_refresh_elapsed += delta
	if _refresh_elapsed >= 0.2:
		_refresh_elapsed = fmod(_refresh_elapsed, 0.2)
		_refresh_sensor_data(false)
	_update_speed_label()


func open_display() -> void:
	visible = true
	_refresh_sensor_data(true)


func close_display() -> void:
	visible = false
	close_requested.emit()


func set_expanded(expanded: bool) -> void:
	var next_mode := "expanded" if expanded else "mini"
	if next_mode == _display_mode:
		return
	_display_mode = next_mode
	_update_layout()
	_update_mode_controls()
	display_mode_changed.emit(_display_mode)


func get_display_mode() -> String:
	return "hidden" if not is_visible_in_tree() else _display_mode


func set_overlay_obstruction_rect(obstruction: Rect2) -> void:
	if _overlay_obstruction_rect == obstruction:
		return
	_overlay_obstruction_rect = obstruction
	_update_layout()


func set_gain_mode(mode: String) -> void:
	_gain_mode = "manual" if mode.to_lower() == "manual" else "auto"
	if _gain_mode == "auto":
		_auto_gain_last_update_runtime_seconds = -1.0
		_advance_auto_gain(_active_history(), _runtime_seconds())
	_sync_setting_controls()
	_refresh_plot_settings()
	_update_labels()


func set_manual_gain_percent(value: float) -> void:
	_manual_gain_percent = clampf(value, 0.0, 100.0)
	_sync_setting_controls()
	_refresh_plot_settings()
	_update_labels()


func set_fish_symbols_enabled(enabled: bool) -> void:
	_fish_symbols_enabled = enabled
	_sync_setting_controls()
	_refresh_plot_settings()


func set_range_mode(mode: String) -> void:
	var requested_mode := "manual" if mode.to_lower() == "manual" else "auto"
	if requested_mode == _range_mode:
		return
	if requested_mode == "manual":
		_manual_display_range_m = _nearest_depth_range(_active_display_range_m)
	else:
		_clear_shrink_candidate()
		if not _range_initialized and not _last_scan.is_empty():
			_update_auto_range(_last_scan)
	_range_mode = requested_mode
	_apply_current_history()
	_sync_setting_controls()
	_update_labels()


func set_manual_range_m(value: float) -> void:
	_manual_display_range_m = _nearest_depth_range(value)
	_apply_current_history()
	_sync_setting_controls()
	_update_labels()


func get_display_settings() -> Dictionary:
	return {
		"gain_mode": _gain_mode,
		"manual_gain_percent": _manual_gain_percent,
		"auto_gain_percent": _auto_gain_percent,
		"effective_gain_percent": _effective_gain_percent(),
		"range_mode": _range_mode,
		"manual_range_m": _manual_display_range_m,
		"display_range_m": _active_display_range_m,
		"fish_symbols_enabled": _fish_symbols_enabled,
	}


func refresh_localized_text() -> void:
	if _title_label != null:
		_title_label.text = tr("fish.finder.title")
	if _preview_badge != null:
		_preview_badge.text = tr("fish.finder.debug_preview")
	if _depth_title_label != null:
		_depth_title_label.text = tr("fish.finder.depth")
	if _speed_title_label != null:
		_speed_title_label.text = tr("fish.finder.speed")
	if _gain_title_label != null:
		_gain_title_label.text = tr("fish.finder.gain")
	if _range_setting_title_label != null:
		_range_setting_title_label.text = tr("fish.finder.range")
	if _close_button != null:
		_close_button.tooltip_text = tr("fish.finder.close")
	if _gain_mode_option != null:
		_gain_mode_option.set_item_text(0, tr("fish.finder.mode.auto"))
		_gain_mode_option.set_item_text(1, tr("fish.finder.mode.manual"))
	if _range_mode_option != null:
		_range_mode_option.set_item_text(0, tr("fish.finder.mode.auto"))
		_range_mode_option.set_item_text(1, tr("fish.finder.mode.manual"))
	if _manual_range_option != null:
		for index in range(DEPTH_RANGES_M.size()):
			_manual_range_option.set_item_text(index, tr("fish.finder.range_option") % float(DEPTH_RANGES_M[index]))
	if _fish_symbols_check != null:
		_fish_symbols_check.text = tr("fish.finder.fish_symbols")
	_update_mode_controls()
	_sync_setting_controls()
	_update_labels()
	if _plot != null:
		_plot.queue_redraw()


func get_diagnostic_snapshot() -> Dictionary:
	var active_scan: Dictionary = _debug_preview_history.back() if _debug_preview_active and not _debug_preview_history.is_empty() else _last_scan
	var echoes: Array = active_scan.get("echoes", [])
	var snapshot := {
		"mode": get_display_mode(),
		"source": "debug_preview" if _debug_preview_active else "real_sensor",
		"preview_active": _debug_preview_active,
		"drawn_columns": _plot.visible_column_count(float(Time.get_ticks_usec()) / 1000000.0) if _plot != null else 0,
		"display_range_m": _active_display_range_m,
		"echo_count": echoes.size(),
		"real_echo_count": _last_scan.get("echoes", []).size(),
		"bottom_valid": bool(_last_scan.get("bottom_valid", false)),
		"scan_runtime_seconds": float(_last_scan.get("scan_runtime_seconds", -1.0)),
		"preview_history_count": _debug_preview_history.size(),
		"preview_target_depth_m": _debug_preview_target_depth_m,
		"preview_peak_strength": _debug_preview_peak_strength,
		"preview_size_band": _debug_preview_size_band,
		"preview_elapsed_seconds": maxf(0.0, _runtime_seconds() - _debug_preview_started_runtime_seconds) if _debug_preview_active else 0.0,
		"bottom_history_diagnostic": analyze_bottom_history(_history),
		"latest_bottom_source": str(_last_scan.get("bathymetry_source", "")),
		"latest_bottom_datum": str(_last_scan.get("bathymetry_vertical_datum", "")),
		"latest_bottom_estimated": bool(_last_scan.get("bathymetry_estimated", false)),
		"latest_bottom_quality": float(_last_scan.get("bathymetry_quality", -1.0)),
		"latest_bottom_interpolated": bool(_last_scan.get("bathymetry_interpolated", false)),
	}
	snapshot.merge(get_display_settings(), true)
	return snapshot


func start_debug_preview(target_depth_m: float = 5.0, peak_strength: float = 0.8, size_band: String = "medium") -> bool:
	_refresh_sensor_data(true)
	set_debug_preview_parameters(target_depth_m, peak_strength, size_band)
	_debug_preview_active = true
	var now := _runtime_seconds()
	_debug_preview_started_runtime_seconds = now
	_debug_preview_last_sample_runtime_seconds = now
	_debug_preview_history.clear()
	var frequency := _debug_preview_frequency_hz()
	var capacity := _debug_preview_history_capacity(frequency)
	for index in range(capacity):
		var age_seconds := float(capacity - 1 - index) / frequency
		var sample_time := now - age_seconds
		var sequence_seconds := DEBUG_PREVIEW_INITIAL_SEQUENCE_SECONDS - age_seconds
		_debug_preview_history.append(_make_debug_preview_column(sample_time, sequence_seconds))
	_update_preview_badge()
	_apply_active_history_to_plot(now)
	_update_labels()
	return true


func stop_debug_preview() -> bool:
	if not _debug_preview_active:
		return false
	_debug_preview_active = false
	_debug_preview_history.clear()
	_debug_preview_started_runtime_seconds = -1.0
	_debug_preview_last_sample_runtime_seconds = -1.0
	_update_preview_badge()
	_refresh_sensor_data(true)
	return true


func set_debug_preview_parameters(target_depth_m: float, peak_strength: float, size_band: String) -> void:
	var maximum_depth := _sensor.maximum_water_depth_m if _sensor != null else 45.0
	_debug_preview_target_depth_m = clampf(target_depth_m, 0.25, maximum_depth)
	_debug_preview_peak_strength = clampf(peak_strength, 0.0, 1.0)
	_debug_preview_size_band = size_band if size_band in ["small", "medium", "large"] else "medium"
	if _debug_preview_active:
		_rebuild_debug_preview_history()
		_update_preview_badge()
		_apply_active_history_to_plot(_runtime_seconds())
		_update_labels()


func is_debug_preview_active() -> bool:
	return _debug_preview_active


static func range_for_bottom_depth(bottom_depth_m: float) -> float:
	if not is_finite(bottom_depth_m) or bottom_depth_m <= 0.0:
		return -1.0
	var required_range := bottom_depth_m + maxf(1.0, bottom_depth_m * 0.08)
	for range_m in DEPTH_RANGES_M:
		if float(range_m) >= required_range:
			return float(range_m)
	return DEPTH_RANGES_M.back()


static func depth_to_y(depth_m: float, display_range_m: float, top: float, height: float) -> float:
	var safe_range := maxf(display_range_m, 0.001)
	return top + clampf(depth_m / safe_range, 0.0, 1.0) * height


static func is_depth_visible(depth_m: float, display_range_m: float) -> bool:
	return is_finite(depth_m) and depth_m >= 0.0 and depth_m <= maxf(display_range_m, 0.0)


static func scan_time_to_x(scan_time_seconds: float, now_seconds: float, window_seconds: float, left: float, width: float) -> float:
	var safe_window := maxf(window_seconds, 0.001)
	return left + width - ((now_seconds - scan_time_seconds) / safe_window) * width


## Stable display-only geometry and colors derived from one real aggregate echo.
static func echo_visual_parameters(echo: Dictionary, sample_time: float, display_strength: float, chart_size: Vector2, display_range_m: float) -> Dictionary:
	var signal_strength := clampf(display_strength, 0.0, 1.0)
	var width_proxy := clampf(float(echo.get("echo_width_m", 0.25)) / 2.5, 0.0, 1.0)
	var width_factor := sqrt(width_proxy)
	var horizontal_scale := clampf(chart_size.x / 320.0, 0.55, 1.45)
	var vertical_scale := clampf(chart_size.y / 160.0, 0.62, 1.5)
	var radius_x := clampf((2.4 + width_factor * 4.4 + sqrt(signal_strength) * 1.2) * horizontal_scale, 3.0, minf(11.0, maxf(3.0, chart_size.x * 0.04)))
	var radius_y := clampf((2.0 + width_factor * 5.0 + sqrt(signal_strength) * 1.1) * vertical_scale, 2.4, minf(13.0, maxf(2.4, chart_size.y * 0.09)))
	var phase := _stable_echo_phase(echo, sample_time)
	var dark_red := Color(0.50, 0.045, 0.026)
	var red_orange := Color(0.91, 0.17, 0.025)
	var orange := Color(1.0, 0.42, 0.035)
	var gold := Color(1.0, 0.70, 0.10)
	var pale_yellow := Color(1.0, 0.92, 0.56)
	var signal_color := dark_red.lerp(red_orange, smoothstep(0.0, 0.42, signal_strength))
	signal_color = signal_color.lerp(orange, smoothstep(0.22, 0.58, signal_strength) * 0.78)
	signal_color = signal_color.lerp(gold, smoothstep(0.48, 0.82, signal_strength) * 0.84)
	signal_color = signal_color.lerp(pale_yellow, smoothstep(0.76, 1.0, signal_strength) * 0.66)
	var core_color := orange.lerp(pale_yellow, smoothstep(0.28, 0.96, signal_strength) * 0.88)
	return {
		"radius_x": radius_x,
		"radius_y": radius_y,
		"phase": phase,
		"signal_color": signal_color,
		"outer_color": dark_red.lerp(red_orange, 0.26 + signal_strength * 0.22),
		"core_color": core_color,
		"outer_alpha": clampf(0.15 + sqrt(signal_strength) * 0.20, 0.15, 0.37),
		"body_alpha": clampf(0.30 + sqrt(signal_strength) * 0.42, 0.30, 0.72),
		"core_alpha": clampf(0.34 + signal_strength * 0.48, 0.34, 0.82),
		"display_strength": signal_strength,
		"display_range_m": maxf(display_range_m, 0.001),
	}


## Polygon points are deterministic for the same recorded echo and never alter scan data.
static func echo_blob_polygon(center: Vector2, radius_x: float, radius_y: float, phase: float, irregularity: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	const POINT_COUNT := 10
	var wobble := clampf(irregularity, 0.0, 0.25)
	for index in range(POINT_COUNT):
		var angle := TAU * float(index) / float(POINT_COUNT)
		var edge := 1.0 + wobble * sin(phase + angle * 2.0) + wobble * 0.42 * sin(phase * 1.73 + angle * 3.0 + 0.6)
		points.append(center + Vector2(cos(angle) * radius_x, sin(angle) * radius_y) * edge)
	return points


## Returns at most one marker anchor for each uninterrupted school echo segment.
static func collect_fish_symbol_anchors(samples: Array[Dictionary], now_seconds: float, window_seconds: float, display_range_m: float, gain_percent: float) -> Array[Dictionary]:
	var anchors: Array[Dictionary] = []
	var active_runs: Dictionary = {}
	var previous_column_time := -INF
	for sample in samples:
		var sample_time := float(sample.get("scan_runtime_seconds", -INF))
		if not is_finite(sample_time) or sample_time > now_seconds or now_seconds - sample_time > window_seconds:
			_append_finished_symbol_runs(active_runs, anchors)
			previous_column_time = -INF
			continue
		if previous_column_time > -INF and (sample_time <= previous_column_time or sample_time - previous_column_time > SONAR_CONTINUOUS_ECHO_GAP_SECONDS):
			_append_finished_symbol_runs(active_runs, anchors)
		previous_column_time = sample_time
		var seen_this_column: Dictionary = {}
		for echo_variant in sample.get("echoes", []):
			if not echo_variant is Dictionary:
				continue
			var echo: Dictionary = echo_variant
			var school_id := str(echo.get("school_id", ""))
			var depth_m := float(echo.get("target_depth_below_transducer_m", -1.0))
			var raw_strength := float(echo.get("echo_strength", 0.0))
			if school_id.is_empty() or not is_depth_visible(depth_m, display_range_m) or not is_finite(raw_strength) or raw_strength <= 0.0:
				continue
			var display_strength := map_echo_strength(raw_strength, gain_percent)
			seen_this_column[school_id] = true
			if not active_runs.has(school_id):
				active_runs[school_id] = {"best": {}}
			if display_strength < FISH_SYMBOL_MIN_DISPLAY_STRENGTH:
				continue
			var run: Dictionary = active_runs[school_id]
			var best: Dictionary = run.get("best", {})
			if best.is_empty() or display_strength > float(best.get("display_strength", 0.0)):
				run["best"] = {
					"school_id": school_id,
					"scan_runtime_seconds": sample_time,
					"target_depth_below_transducer_m": depth_m,
					"display_strength": display_strength,
				}
				active_runs[school_id] = run
		for active_school_id in active_runs.keys():
			if not seen_this_column.has(active_school_id):
				_append_symbol_anchor(active_runs[active_school_id], anchors)
				active_runs.erase(active_school_id)
	_append_finished_symbol_runs(active_runs, anchors)
	return anchors


static func _append_finished_symbol_runs(active_runs: Dictionary, anchors: Array[Dictionary]) -> void:
	for school_id in active_runs.keys():
		_append_symbol_anchor(active_runs[school_id], anchors)
	active_runs.clear()


static func _append_symbol_anchor(run: Dictionary, anchors: Array[Dictionary]) -> void:
	var best: Dictionary = run.get("best", {})
	if not best.is_empty():
		anchors.append(best)


static func _stable_echo_phase(echo: Dictionary, sample_time: float) -> float:
	var identity := str(echo.get("echo_id", ""))
	if identity.is_empty():
		identity = "%s|%d" % [str(echo.get("school_id", "")), roundi(sample_time * 3.0)]
	var hash_value := 17
	for index in range(identity.length()):
		hash_value = int((hash_value * 31 + identity.unicode_at(index)) % 2147483647)
	return fposmod(float(hash_value) * 0.61803398875, 1.0) * TAU


## Maps an unchanged sensor echo strength to display-only intensity.
static func map_echo_strength(raw_strength: float, gain_percent: float) -> float:
	if not is_finite(raw_strength) or not is_finite(gain_percent):
		return 0.0
	var strength := clampf(raw_strength, 0.0, 1.0)
	if strength <= 0.0:
		return 0.0
	var gain := clampf(gain_percent, 0.0, 100.0) / 100.0
	var threshold := lerpf(0.045, 0.008, gain)
	var gate := smoothstep(threshold, minf(threshold + 0.04, 1.0), strength)
	var exponent := lerpf(0.95, 0.38, gain)
	return clampf(pow(strength, exponent) * gate, 0.0, 1.0)


## Estimates a bounded gain from recent nonzero echoes. It never normalizes the
## strongest echo to full brightness; empty history returns the supplied value.
static func estimate_auto_gain_percent(history: Array[Dictionary], fallback_percent: float = DEFAULT_AUTO_GAIN_PERCENT) -> float:
	if history.is_empty():
		return clampf(fallback_percent, 0.0, 100.0)
	var latest_time := float(history.back().get("scan_runtime_seconds", -INF))
	if not is_finite(latest_time):
		return clampf(fallback_percent, 0.0, 100.0)
	var strengths: Array[float] = []
	for sample in history:
		var sample_time := float(sample.get("scan_runtime_seconds", -INF))
		if not is_finite(sample_time) or latest_time - sample_time > AUTO_GAIN_LOOKBACK_SECONDS:
			continue
		for echo_variant in sample.get("echoes", []):
			if not echo_variant is Dictionary:
				continue
			var strength := float(echo_variant.get("echo_strength", 0.0))
			if is_finite(strength) and strength > 0.0:
				strengths.append(clampf(strength, 0.0, 1.0))
	if strengths.is_empty():
		return clampf(fallback_percent, 0.0, 100.0)
	strengths.sort()
	var median_strength := strengths[int(strengths.size() / 2)]
	return clampf(62.0 + (AUTO_GAIN_REFERENCE_STRENGTH - median_strength) * 75.0, 35.0, 75.0)


static func _nearest_depth_range(value: float) -> float:
	var nearest := float(DEPTH_RANGES_M[0])
	var difference := absf(value - nearest)
	for candidate in DEPTH_RANGES_M.slice(1):
		var candidate_difference := absf(value - float(candidate))
		if candidate_difference < difference:
			nearest = float(candidate)
			difference = candidate_difference
	return nearest


func _build_ui() -> void:
	var panel := PanelContainer.new()
	panel.name = "FishFinderPanel"
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.018, 0.065, 0.085, 0.96)
	panel_style.border_color = Color(0.24, 0.54, 0.58, 0.92)
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(8)
	panel_style.content_margin_left = 9.0
	panel_style.content_margin_right = 9.0
	panel_style.content_margin_top = 7.0
	panel_style.content_margin_bottom = 7.0
	panel.add_theme_stylebox_override("panel", panel_style)
	add_child(panel)
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 4)
	panel.add_child(layout)
	var title_row := HBoxContainer.new()
	_title_label = Label.new()
	_title_label.name = "FishFinderTitle"
	_title_label.text = tr("fish.finder.title")
	_title_label.add_theme_font_size_override("font_size", 15)
	_title_label.add_theme_color_override("font_color", Color(0.58, 0.83, 0.82))
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(_title_label)
	_preview_badge = Label.new()
	_preview_badge.text = tr("fish.finder.debug_preview")
	_preview_badge.add_theme_font_size_override("font_size", 10)
	_preview_badge.add_theme_color_override("font_color", Color(1.0, 0.76, 0.35))
	_preview_badge.visible = false
	title_row.add_child(_preview_badge)
	_expand_button = Button.new()
	_expand_button.name = "ExpandCollapseButton"
	_expand_button.focus_mode = Control.FOCUS_NONE
	_expand_button.custom_minimum_size = Vector2(36.0, 28.0)
	_expand_button.pressed.connect(func() -> void: set_expanded(_display_mode == "mini"))
	title_row.add_child(_expand_button)
	_close_button = Button.new()
	_close_button.name = "CloseFishFinderButton"
	_close_button.text = "×"
	_close_button.tooltip_text = tr("fish.finder.close")
	_close_button.focus_mode = Control.FOCUS_NONE
	_close_button.custom_minimum_size = Vector2(32.0, 28.0)
	_close_button.pressed.connect(close_display)
	title_row.add_child(_close_button)
	layout.add_child(title_row)

	var status_row := HBoxContainer.new()
	status_row.add_theme_constant_override("separation", 12)
	var depth_group := VBoxContainer.new()
	depth_group.add_theme_constant_override("separation", 0)
	_depth_title_label = Label.new()
	_depth_title_label.text = tr("fish.finder.depth")
	_depth_title_label.add_theme_font_size_override("font_size", 10)
	_depth_title_label.add_theme_color_override("font_color", Color(0.57, 0.72, 0.75))
	depth_group.add_child(_depth_title_label)
	_depth_value_label = Label.new()
	_depth_value_label.text = "--"
	_depth_value_label.add_theme_font_size_override("font_size", 22)
	_depth_value_label.add_theme_color_override("font_color", Color(0.98, 0.83, 0.49))
	depth_group.add_child(_depth_value_label)
	status_row.add_child(depth_group)
	var speed_group := _make_status_group(tr("fish.finder.speed"), "-- kn", Color(0.88, 0.94, 0.91))
	_speed_title_label = speed_group.get_node("Title") as Label
	_speed_value_label = speed_group.get_node("Value") as Label
	status_row.add_child(speed_group)
	var range_group := _make_status_group(tr("fish.finder.range"), "10 m", Color(0.88, 0.94, 0.91))
	_range_title_label = range_group.get_node("Title") as Label
	_range_value_label = range_group.get_node("Value") as Label
	status_row.add_child(range_group)
	layout.add_child(status_row)
	_build_settings_controls(layout)

	_plot = SonarPlot.new()
	_plot.name = "SonarHistoryPlot"
	_plot.custom_minimum_size = Vector2(0.0, 125.0)
	_plot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_plot.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(_plot)
	_footer_label = Label.new()
	_footer_label.add_theme_font_size_override("font_size", 10)
	_footer_label.add_theme_color_override("font_color", Color(0.66, 0.79, 0.79))
	_footer_label.text = tr("fish.finder.status.waiting")
	layout.add_child(_footer_label)
	_update_mode_controls()


func _make_status_group(title_text: String, initial_value: String, color: Color) -> VBoxContainer:
	var group := VBoxContainer.new()
	group.add_theme_constant_override("separation", 1)
	var title := Label.new()
	title.name = "Title"
	title.text = title_text
	title.add_theme_font_size_override("font_size", 10)
	title.add_theme_color_override("font_color", Color(0.57, 0.72, 0.75))
	group.add_child(title)
	var value := Label.new()
	value.name = "Value"
	value.text = initial_value
	value.add_theme_font_size_override("font_size", 14)
	value.add_theme_color_override("font_color", color)
	group.add_child(value)
	return group


func _build_settings_controls(parent: VBoxContainer) -> void:
	_settings_container = VBoxContainer.new()
	_settings_container.name = "FishFinderDisplaySettings"
	_settings_container.add_theme_constant_override("separation", 3)
	_settings_container.visible = false
	parent.add_child(_settings_container)

	var gain_row := HBoxContainer.new()
	gain_row.add_theme_constant_override("separation", 6)
	_gain_title_label = Label.new()
	_gain_title_label.text = tr("fish.finder.gain")
	_gain_title_label.custom_minimum_size.x = 46.0
	gain_row.add_child(_gain_title_label)
	_gain_mode_option = OptionButton.new()
	_gain_mode_option.name = "GainModeOption"
	_gain_mode_option.custom_minimum_size.x = 105.0
	_add_mode_option(_gain_mode_option)
	_gain_mode_option.item_selected.connect(_on_gain_mode_selected)
	gain_row.add_child(_gain_mode_option)
	_gain_slider = HSlider.new()
	_gain_slider.name = "ManualGainSlider"
	_gain_slider.min_value = 0.0
	_gain_slider.max_value = 100.0
	_gain_slider.step = 1.0
	_gain_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_gain_slider.focus_mode = Control.FOCUS_NONE
	_gain_slider.value_changed.connect(_on_manual_gain_changed)
	gain_row.add_child(_gain_slider)
	_gain_value_label = Label.new()
	_gain_value_label.custom_minimum_size.x = 62.0
	_gain_value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	gain_row.add_child(_gain_value_label)
	_settings_container.add_child(gain_row)

	var range_row := HBoxContainer.new()
	range_row.add_theme_constant_override("separation", 6)
	_range_setting_title_label = Label.new()
	_range_setting_title_label.text = tr("fish.finder.range")
	_range_setting_title_label.custom_minimum_size.x = 46.0
	range_row.add_child(_range_setting_title_label)
	_range_mode_option = OptionButton.new()
	_range_mode_option.name = "RangeModeOption"
	_range_mode_option.custom_minimum_size.x = 105.0
	_add_mode_option(_range_mode_option)
	_range_mode_option.item_selected.connect(_on_range_mode_selected)
	range_row.add_child(_range_mode_option)
	_manual_range_option = OptionButton.new()
	_manual_range_option.name = "ManualRangeOption"
	_manual_range_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_manual_range_option.focus_mode = Control.FOCUS_NONE
	for depth_range in DEPTH_RANGES_M:
		_manual_range_option.add_item(tr("fish.finder.range_option") % float(depth_range))
		_manual_range_option.set_item_metadata(_manual_range_option.item_count - 1, float(depth_range))
	_manual_range_option.item_selected.connect(_on_manual_range_selected)
	range_row.add_child(_manual_range_option)
	_settings_container.add_child(range_row)

	_fish_symbols_check = CheckBox.new()
	_fish_symbols_check.name = "FishSymbolsToggle"
	_fish_symbols_check.text = tr("fish.finder.fish_symbols")
	_fish_symbols_check.focus_mode = Control.FOCUS_NONE
	_fish_symbols_check.toggled.connect(set_fish_symbols_enabled)
	_settings_container.add_child(_fish_symbols_check)
	_sync_setting_controls()


func _add_mode_option(option: OptionButton) -> void:
	option.add_item(tr("fish.finder.mode.auto"))
	option.set_item_metadata(0, "auto")
	option.add_item(tr("fish.finder.mode.manual"))
	option.set_item_metadata(1, "manual")
	option.focus_mode = Control.FOCUS_NONE


func _on_gain_mode_selected(index: int) -> void:
	if _gain_mode_option == null or index < 0:
		return
	set_gain_mode(str(_gain_mode_option.get_item_metadata(index)))


func _on_manual_gain_changed(value: float) -> void:
	set_manual_gain_percent(value)


func _on_range_mode_selected(index: int) -> void:
	if _range_mode_option == null or index < 0:
		return
	set_range_mode(str(_range_mode_option.get_item_metadata(index)))


func _on_manual_range_selected(index: int) -> void:
	if _manual_range_option == null or index < 0:
		return
	set_manual_range_m(float(_manual_range_option.get_item_metadata(index)))


func _sync_setting_controls() -> void:
	if _gain_mode_option != null:
		_gain_mode_option.select(1 if _gain_mode == "manual" else 0)
	if _gain_slider != null:
		_gain_slider.set_value_no_signal(_manual_gain_percent)
		_gain_slider.editable = _gain_mode == "manual"
	if _gain_value_label != null:
		_gain_value_label.text = tr("fish.finder.gain_value_manual") % _manual_gain_percent if _gain_mode == "manual" else tr("fish.finder.gain_value_auto") % _auto_gain_percent
	if _range_mode_option != null:
		_range_mode_option.select(1 if _range_mode == "manual" else 0)
	if _manual_range_option != null:
		var range_index := DEPTH_RANGES_M.find(_manual_display_range_m)
		_manual_range_option.select(maxi(range_index, 0))
		_manual_range_option.disabled = _range_mode != "manual"
	if _fish_symbols_check != null:
		_fish_symbols_check.set_pressed_no_signal(_fish_symbols_enabled)
	if _settings_container != null:
		_settings_container.visible = _display_mode == "expanded"
	if _range_title_label != null:
		_range_title_label.text = "%s · %s" % [tr("fish.finder.range"), tr("fish.finder.mode_short." + _range_mode)]


func _update_mode_controls() -> void:
	if _expand_button != null:
		var expand := _display_mode == "mini"
		_expand_button.text = "+" if expand else "−"
		_expand_button.tooltip_text = tr("fish.finder.expand") if expand else tr("fish.finder.collapse")
	if _settings_container != null:
		_settings_container.visible = _display_mode == "expanded"


func _on_visibility_changed() -> void:
	set_process(is_visible_in_tree())
	if is_visible_in_tree():
		_refresh_sensor_data(true)
		if _plot != null:
			_plot.set_process(true)
	elif _plot != null:
		_plot.set_process(false)


func _update_layout() -> void:
	if get_viewport() == null:
		return
	var viewport_size := get_viewport().get_visible_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	var layout := compute_layout_rect(viewport_size, _display_mode, _overlay_obstruction_rect)
	position = layout.position
	size = layout.size
	if _plot != null:
		_plot.queue_redraw()


func _refresh_sensor_data(force: bool) -> void:
	if _manager != null and _manager.has_method("get_fish_finder_sensor"):
		_sensor = _manager.call("get_fish_finder_sensor") as FishFinderSensor
	var real_history_changed := false
	if _sensor == null:
		_last_scan = {}
		_history.clear()
		_last_scan_id = -1
		real_history_changed = true
	else:
		var last := _sensor.get_last_scan()
		var scan_id := int(last.get("scan_id", -1))
		if force or scan_id != _last_scan_id:
			_history = _sensor.get_scan_history()
			_last_scan = last
			_last_scan_id = scan_id
			_update_auto_range(last)
			real_history_changed = true
	var now := _runtime_seconds()
	if _debug_preview_active:
		var preview_changed := _append_debug_preview_columns_until(now)
		if preview_changed:
			_advance_auto_gain(_debug_preview_history, now)
		if force or real_history_changed or preview_changed:
			_apply_active_history_to_plot(now)
	elif force or real_history_changed:
		if real_history_changed:
			_advance_auto_gain(_history, now)
		_apply_current_history(now)
	_update_labels()


func _append_debug_preview_columns_until(now_seconds: float) -> bool:
	if not _debug_preview_active:
		return false
	var frequency := _debug_preview_frequency_hz()
	var interval := 1.0 / frequency
	if _debug_preview_last_sample_runtime_seconds < 0.0:
		_debug_preview_last_sample_runtime_seconds = now_seconds
		return false
	var changed := false
	var capacity := _debug_preview_history_capacity(frequency)
	while now_seconds - _debug_preview_last_sample_runtime_seconds >= interval:
		_debug_preview_last_sample_runtime_seconds += interval
		var sequence_seconds := DEBUG_PREVIEW_INITIAL_SEQUENCE_SECONDS + (_debug_preview_last_sample_runtime_seconds - _debug_preview_started_runtime_seconds)
		_debug_preview_history.append(_make_debug_preview_column(_debug_preview_last_sample_runtime_seconds, sequence_seconds))
		while _debug_preview_history.size() > capacity:
			_debug_preview_history.pop_front()
		changed = true
	return changed


func _make_debug_preview_column(sample_time: float, sequence_seconds: float) -> Dictionary:
	var phase := fposmod(sequence_seconds, DEBUG_PREVIEW_CYCLE_SECONDS) / DEBUG_PREVIEW_CYCLE_SECONDS
	var envelope := 0.15
	if phase < 0.28:
		envelope = lerpf(0.15, 1.0, smoothstep(0.0, 0.28, phase))
	elif phase < 0.50:
		envelope = 1.0
	else:
		envelope = lerpf(1.0, 0.15, smoothstep(0.50, 1.0, phase))
	var population := _debug_preview_population()
	var echo_strength := clampf(_debug_preview_peak_strength * envelope, 0.0, 1.0)
	var echo := {
		"echo_id": "debug_preview_%d" % roundi(sample_time * _debug_preview_frequency_hz()),
		"school_id": "debug_preview_school",
		"species_id": "",
		"target_depth_below_transducer_m": _debug_preview_target_depth_m,
		"depth_below_surface_m": _debug_preview_target_depth_m,
		"echo_strength": echo_strength,
		"group_intensity": envelope,
		"group_population": population,
		"echo_width_m": clampf(sqrt(float(population)) * 0.22, 0.25, 2.5),
		"echo_width_is_visual_proxy": true,
		"estimated_group_size_band": _debug_preview_size_band,
		"aggregation_method": "debug_preview_only",
	}
	return {
		"scan_runtime_seconds": sample_time,
		"debug_preview": true,
		"bottom_valid": false,
		"bottom_depth_below_transducer_m": -1.0,
		"echoes": [echo],
	}


func _debug_preview_population() -> int:
	match _debug_preview_size_band:
		"small": return 5
		"large": return 64
		_: return 18


func _rebuild_debug_preview_history() -> void:
	for index in range(_debug_preview_history.size()):
		var previous_sample := _debug_preview_history[index]
		var sample_time := float(previous_sample.get("scan_runtime_seconds", _runtime_seconds()))
		var sequence_seconds := DEBUG_PREVIEW_INITIAL_SEQUENCE_SECONDS + sample_time - _debug_preview_started_runtime_seconds
		_debug_preview_history[index] = _make_debug_preview_column(sample_time, sequence_seconds)


func _debug_preview_frequency_hz() -> float:
	return maxf(_sensor.scan_frequency_hz, 0.1) if _sensor != null else DEBUG_PREVIEW_DEFAULT_FREQUENCY_HZ


func _debug_preview_history_capacity(frequency: float) -> int:
	if _sensor != null:
		return clampi(maxi(_sensor.get_effective_history_capacity(), ceili(frequency * DEBUG_PREVIEW_HISTORY_SECONDS)), 1, 12000)
	return ceili(frequency * DEBUG_PREVIEW_HISTORY_SECONDS)


func _apply_active_history_to_plot(now_seconds: float) -> void:
	if _plot == null:
		return
	var real_bottom_depth := float(_last_scan.get("bottom_depth_below_transducer_m", -1.0)) if bool(_last_scan.get("bottom_valid", false)) else -1.0
	var required_range := maxf(real_bottom_depth, _debug_preview_target_depth_m + 1.0)
	var preview_range := range_for_bottom_depth(required_range)
	if _range_mode == "manual":
		_active_display_range_m = _manual_display_range_m
	else:
		_active_display_range_m = maxf(_current_display_range_m, preview_range) if preview_range > 0.0 else _current_display_range_m
	_plot.set_scan_data(_debug_preview_history, _active_display_range_m, now_seconds, _effective_gain_percent(), _fish_symbols_enabled)


func _apply_current_history(now_seconds: float = -1.0) -> void:
	var now := now_seconds if now_seconds >= 0.0 else _runtime_seconds()
	if _debug_preview_active:
		_apply_active_history_to_plot(now)
		return
	_active_display_range_m = _manual_display_range_m if _range_mode == "manual" else _current_display_range_m
	if _plot != null:
		_plot.set_scan_data(_history, _active_display_range_m, now, _effective_gain_percent(), _fish_symbols_enabled)
		_plot.queue_redraw()


func _refresh_plot_settings() -> void:
	_apply_current_history()


func _active_history() -> Array[Dictionary]:
	return _debug_preview_history if _debug_preview_active else _history


func _effective_gain_percent() -> float:
	return _manual_gain_percent if _gain_mode == "manual" else _auto_gain_percent


func _advance_auto_gain(history: Array[Dictionary], now_seconds: float) -> void:
	if _gain_mode != "auto":
		_auto_gain_last_update_runtime_seconds = now_seconds
		return
	var target := estimate_auto_gain_percent(history, _auto_gain_percent)
	if is_equal_approx(target, _auto_gain_percent):
		_auto_gain_last_update_runtime_seconds = now_seconds
		return
	if _auto_gain_last_update_runtime_seconds < 0.0:
		_auto_gain_last_update_runtime_seconds = now_seconds
		return
	var elapsed := clampf(now_seconds - _auto_gain_last_update_runtime_seconds, 0.0, 1.0)
	_auto_gain_last_update_runtime_seconds = now_seconds
	if elapsed <= 0.0:
		return
	var blend := 1.0 - exp(-elapsed / AUTO_GAIN_SMOOTHING_SECONDS)
	_auto_gain_percent = lerpf(_auto_gain_percent, target, blend)
	_sync_setting_controls()


func _update_preview_badge() -> void:
	if _preview_badge != null:
		_preview_badge.visible = _debug_preview_active


func _update_auto_range(scan: Dictionary) -> void:
	if not bool(scan.get("bottom_valid", false)):
		return
	var bottom_depth := float(scan.get("bottom_depth_below_transducer_m", -1.0))
	var desired := range_for_bottom_depth(bottom_depth)
	if desired <= 0.0:
		return
	var scan_time := float(scan.get("scan_runtime_seconds", _runtime_seconds()))
	if not _range_initialized:
		_current_display_range_m = desired
		_range_initialized = true
		_clear_shrink_candidate()
		return
	if desired > _current_display_range_m:
		_current_display_range_m = desired
		_clear_shrink_candidate()
		return
	if desired < _current_display_range_m and bottom_depth < _current_display_range_m * RANGE_SHRINK_HYSTERESIS:
		if not is_equal_approx(_range_shrink_candidate_m, desired):
			_range_shrink_candidate_m = desired
			_range_shrink_started_at_seconds = scan_time
		elif scan_time - _range_shrink_started_at_seconds >= RANGE_SHRINK_HOLD_SECONDS:
			_current_display_range_m = desired
			_clear_shrink_candidate()
		return
	_clear_shrink_candidate()


func _clear_shrink_candidate() -> void:
	_range_shrink_candidate_m = -1.0
	_range_shrink_started_at_seconds = -1.0


static func compute_layout_rect(viewport_size: Vector2, display_mode: String, obstruction: Rect2 = Rect2()) -> Rect2:
	var safe_size := Vector2(maxf(viewport_size.x - LAYOUT_SAFE_MARGIN_PX * 2.0, 1.0), maxf(viewport_size.y - LAYOUT_SAFE_MARGIN_PX * 2.0, 1.0))
	var safe_rect := Rect2(Vector2(LAYOUT_SAFE_MARGIN_PX, LAYOUT_SAFE_MARGIN_PX), safe_size)
	var expanded := display_mode == "expanded"
	var target_size := Vector2.ZERO
	if expanded:
		target_size = Vector2(minf(viewport_size.x * 0.60, safe_size.x), minf(viewport_size.y * 0.62, safe_size.y))
		target_size.x = minf(safe_size.x, maxf(target_size.x, minf(360.0, safe_size.x)))
		target_size.y = minf(safe_size.y, maxf(target_size.y, minf(300.0, safe_size.y)))
	else:
		target_size = Vector2(
			clampf(viewport_size.x * 0.34, minf(300.0, safe_size.x), minf(560.0, safe_size.x)),
			clampf(viewport_size.y * 0.32, minf(250.0, safe_size.y), minf(400.0, safe_size.y))
		)
	var preferred := Rect2(Vector2(safe_rect.position.x, safe_rect.end.y - target_size.y), target_size) if not expanded else Rect2((viewport_size - target_size) * 0.5, target_size)
	if obstruction.size.x <= 0.0 or obstruction.size.y <= 0.0 or not preferred.intersects(obstruction):
		return _clamp_layout_rect(preferred, viewport_size)
	if not expanded:
		var corner_candidates: Array[Rect2] = [
			preferred,
			Rect2(Vector2(safe_rect.end.x - target_size.x, safe_rect.end.y - target_size.y), target_size),
			Rect2(Vector2(safe_rect.end.x - target_size.x, safe_rect.position.y), target_size),
			Rect2(safe_rect.position, target_size),
		]
		for corner in corner_candidates:
			if not corner.intersects(obstruction):
				return _clamp_layout_rect(corner, viewport_size)

	var free_regions: Array[Rect2] = []
	var left_width := maxf(obstruction.position.x - safe_rect.position.x - LAYOUT_SAFE_MARGIN_PX, 0.0)
	var right_x := obstruction.end.x + LAYOUT_SAFE_MARGIN_PX
	var right_width := maxf(safe_rect.end.x - right_x, 0.0)
	var top_height := maxf(obstruction.position.y - safe_rect.position.y - LAYOUT_SAFE_MARGIN_PX, 0.0)
	var bottom_y := obstruction.end.y + LAYOUT_SAFE_MARGIN_PX
	var bottom_height := maxf(safe_rect.end.y - bottom_y, 0.0)
	if left_width > 0.0:
		free_regions.append(Rect2(safe_rect.position, Vector2(left_width, safe_rect.size.y)))
	if right_width > 0.0:
		free_regions.append(Rect2(Vector2(right_x, safe_rect.position.y), Vector2(right_width, safe_rect.size.y)))
	if top_height > 0.0:
		free_regions.append(Rect2(safe_rect.position, Vector2(safe_rect.size.x, top_height)))
	if bottom_height > 0.0:
		free_regions.append(Rect2(Vector2(safe_rect.position.x, bottom_y), Vector2(safe_rect.size.x, bottom_height)))

	var best := Rect2(Vector2.ZERO, Vector2.ZERO)
	var best_area := -1.0
	for region in free_regions:
		var candidate_size := Vector2(minf(target_size.x, region.size.x), minf(target_size.y, region.size.y))
		if candidate_size.x < minf(240.0, safe_size.x) or candidate_size.y < minf(180.0, safe_size.y):
			continue
		var candidate := Rect2(region.position + (region.size - candidate_size) * 0.5, candidate_size)
		var area := candidate_size.x * candidate_size.y
		if not candidate.intersects(obstruction) and area > best_area:
			best = candidate
			best_area = area
	if best_area >= 0.0:
		return _clamp_layout_rect(best, viewport_size)
	return _clamp_layout_rect(preferred, viewport_size)


static func _clamp_layout_rect(rect: Rect2, viewport_size: Vector2) -> Rect2:
	var safe_size := Vector2(maxf(viewport_size.x - LAYOUT_SAFE_MARGIN_PX * 2.0, 1.0), maxf(viewport_size.y - LAYOUT_SAFE_MARGIN_PX * 2.0, 1.0))
	var panel_size := Vector2(minf(rect.size.x, safe_size.x), minf(rect.size.y, safe_size.y))
	var panel_position := Vector2(
		clampf(rect.position.x, LAYOUT_SAFE_MARGIN_PX, LAYOUT_SAFE_MARGIN_PX + safe_size.x - panel_size.x),
		clampf(rect.position.y, LAYOUT_SAFE_MARGIN_PX, LAYOUT_SAFE_MARGIN_PX + safe_size.y - panel_size.y)
	)
	return Rect2(panel_position, panel_size)


static func evaluate_bottom_sample_connection(previous: Dictionary, current: Dictionary, maximum_gap_seconds: float = SONAR_CONTINUOUS_ECHO_GAP_SECONDS) -> Dictionary:
	var previous_time := float(previous.get("scan_runtime_seconds", NAN))
	var current_time := float(current.get("scan_runtime_seconds", NAN))
	var delta_time := current_time - previous_time
	var result := {
		"connect": false,
		"reason": "invalid_sample",
		"delta_time_seconds": delta_time,
		"delta_depth_m": float(current.get("bottom_depth_below_transducer_m", NAN)) - float(previous.get("bottom_depth_below_transducer_m", NAN)),
		"horizontal_displacement_m": -1.0,
		"previous_scan_id": int(previous.get("scan_id", -1)),
		"current_scan_id": int(current.get("scan_id", -1)),
		"previous_bottom_valid": bool(previous.get("bottom_valid", false)),
		"current_bottom_valid": bool(current.get("bottom_valid", false)),
		"previous_vessel_id": str(previous.get("active_vessel_id", "")),
		"current_vessel_id": str(current.get("active_vessel_id", "")),
		"previous_source": str(previous.get("bathymetry_source", "")),
		"current_source": str(current.get("bathymetry_source", "")),
	}
	if not bool(result["previous_bottom_valid"]) or not bool(result["current_bottom_valid"]):
		result["reason"] = "invalid_bottom"
		return result
	if not is_finite(previous_time) or not is_finite(current_time) or delta_time <= 0.0:
		result["reason"] = "non_monotonic_time"
		return result
	if delta_time > maxf(maximum_gap_seconds, 0.0):
		result["reason"] = "scan_gap"
		return result
	if str(result["previous_vessel_id"]) != str(result["current_vessel_id"]):
		result["reason"] = "vessel_changed"
		return result
	if str(result["previous_source"]) != str(result["current_source"]):
		result["reason"] = "bathymetry_source_changed"
		return result
	var previous_probe: Variant = previous.get("probe_world_position")
	var current_probe: Variant = current.get("probe_world_position")
	if previous_probe is Vector3 and current_probe is Vector3:
		var displacement := Vector2(current_probe.x - previous_probe.x, current_probe.z - previous_probe.z).length()
		result["horizontal_displacement_m"] = displacement
		var speed := maxf(float(previous.get("boat_speed_mps", 0.0)), float(current.get("boat_speed_mps", 0.0)))
		var plausible_distance := clampf(speed * delta_time * 2.5 + 1.0, BOTTOM_PROBE_MIN_CONTINUITY_DISTANCE_M, BOTTOM_PROBE_MAX_CONTINUITY_DISTANCE_M)
		if displacement > plausible_distance:
			result["reason"] = "probe_discontinuity"
			return result
	elif (previous_probe is Vector3) != (current_probe is Vector3):
		result["reason"] = "probe_metadata_missing"
		return result
	result["connect"] = true
	result["reason"] = "continuous"
	return result


static func analyze_bottom_history(history: Array[Dictionary]) -> Dictionary:
	var best := {"available": false, "max_delta_depth_m": -1.0, "delta_time_seconds": -1.0, "horizontal_displacement_m": -1.0}
	for index in range(1, history.size()):
		var previous := history[index - 1]
		var current := history[index]
		if not bool(previous.get("bottom_valid", false)) or not bool(current.get("bottom_valid", false)):
			continue
		var connection := evaluate_bottom_sample_connection(previous, current)
		var previous_depth := float(previous.get("bottom_depth_below_transducer_m", NAN))
		var current_depth := float(current.get("bottom_depth_below_transducer_m", NAN))
		if not is_finite(previous_depth) or not is_finite(current_depth):
			continue
		var previous_probe: Variant = previous.get("probe_world_position")
		var current_probe: Variant = current.get("probe_world_position")
		var probe_vertical_delta := -1.0
		if previous_probe is Vector3 and current_probe is Vector3:
			probe_vertical_delta = current_probe.y - previous_probe.y
		var absolute_delta := absf(current_depth - previous_depth)
		if not bool(best["available"]) or absolute_delta > float(best["max_delta_depth_m"]):
			best = {
				"available": true,
				"max_delta_depth_m": absolute_delta,
				"previous_depth_m": previous_depth,
				"current_depth_m": current_depth,
				"delta_time_seconds": float(connection["delta_time_seconds"]),
				"horizontal_displacement_m": float(connection["horizontal_displacement_m"]),
				"connected_for_display": bool(connection["connect"]),
				"reason": str(connection["reason"]),
				"previous_scan_id": int(connection["previous_scan_id"]),
				"current_scan_id": int(connection["current_scan_id"]),
				"previous_vessel_id": str(connection["previous_vessel_id"]),
				"current_vessel_id": str(connection["current_vessel_id"]),
				"previous_source": str(connection["previous_source"]),
				"current_source": str(connection["current_source"]),
				"previous_probe_world_position": previous.get("probe_world_position", Vector3(NAN, NAN, NAN)),
				"current_probe_world_position": current.get("probe_world_position", Vector3(NAN, NAN, NAN)),
				"previous_chart_depth_lat_m": float(previous.get("chart_depth_lat_m", -1.0)),
				"current_chart_depth_lat_m": float(current.get("chart_depth_lat_m", -1.0)),
			"chart_depth_delta_m": float(current.get("chart_depth_lat_m", NAN)) - float(previous.get("chart_depth_lat_m", NAN)),
				"probe_vertical_displacement_m": probe_vertical_delta,
			"previous_surface_height_world_y_m": float(previous.get("surface_height_world_y_m", NAN)),
			"current_surface_height_world_y_m": float(current.get("surface_height_world_y_m", NAN)),
				"previous_bottom_valid": true,
				"current_bottom_valid": true,
			}
	return best


func _update_labels() -> void:
	if _depth_value_label == null:
		return
	var echoes: Array = _last_scan.get("echoes", [])
	var bottom_valid := bool(_last_scan.get("bottom_valid", false))
	var reason := str(_last_scan.get("reason", ""))
	if _title_label != null:
		_title_label.text = "%s · %s" % [tr("fish.finder.title"), tr("fish.finder.gain_mode_status." + _gain_mode)]
	_update_preview_badge()
	if _last_scan.is_empty():
		_depth_value_label.text = "--"
		_footer_label.text = tr("fish.finder.status.waiting") if _sensor != null else tr("fish.finder.status.unavailable")
	elif bottom_valid:
		_depth_value_label.text = "%.1f m" % float(_last_scan.get("bottom_depth_below_transducer_m", -1.0))
		if echoes.is_empty():
			_footer_label.text = tr("fish.finder.status.empty") % [minf(_sensor.get_history_coverage_seconds(), HISTORY_WINDOW_SECONDS)]
		else:
			_footer_label.text = tr("fish.finder.status.live") % [echoes.size(), minf(_sensor.get_history_coverage_seconds(), HISTORY_WINDOW_SECONDS)]
	else:
		_depth_value_label.text = "--"
		_footer_label.text = tr("fish.finder.status.unavailable") if reason == "dependencies_unavailable" or reason == "authority_query_unavailable" else tr("fish.finder.status.no_bottom")
	if _range_value_label != null:
		_range_value_label.text = "%.0f m" % _active_display_range_m
	if _debug_preview_active:
		_footer_label.text = tr("fish.finder.preview_footer") % [1, _debug_preview_target_depth_m, _debug_preview_peak_strength, tr("fishing.debug.finder_preview_size." + _debug_preview_size_band)]
	_sync_setting_controls()
	_update_speed_label()


func _update_speed_label() -> void:
	if _speed_value_label == null:
		return
	var speed_mps := 0.0
	if _speed_source != null and is_instance_valid(_speed_source):
		var value: Variant = _speed_source.get("speed_mps")
		if value != null and is_finite(float(value)):
			speed_mps = float(value)
	_speed_value_label.text = "%.1f kn" % (speed_mps * 1.94384)


func _runtime_seconds() -> float:
	return float(Time.get_ticks_usec()) / 1000000.0
