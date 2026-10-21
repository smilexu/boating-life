extends Control

## Read-only W2.2b viewer. It loads a local cache or bundled test fixture only;
## it never starts an HTTP request or changes formal game weather.

const CORE := preload("res://scripts/weather_data/weather_simulation_core.gd")
const CODEC := preload("res://scripts/weather_data/weather_forecast_codec.gd")
const ANALYSIS := preload("res://scripts/weather_data/weather_simulation_analysis.gd")
const CHART_SCRIPT := preload("res://scripts/weather_simulation_chart.gd")
const CACHE_STORE_SCRIPT := preload("res://scripts/weather_data/weather_file_cache_store.gd")
const FIXTURE_PATH := "res://tests/fixtures/weather_simulation_two_day_fixture.json"
const LIVE_CACHE_DIRECTORY := "res://.godot/weather_live_request_cache"
const REGION_ID := "oresund"

const COLOR_CLEAR := Color("72b9d3")
const COLOR_PARTLY := Color("8ebda5")
const COLOR_OVERCAST := Color("9ca9b1")
const COLOR_PRECIP := Color("6aadd0")
const COLOR_POSSIBLE := Color("c3b278")
const COLOR_UNKNOWN := Color("596c78")

var _source_mode := "fixture"
var _source_label := "TEST FIXTURE"
var _freshness_label := "N/A"
var _forecast_quality := "fresh"
var _forecast_document: Dictionary = {}
var _cache_envelope: Dictionary = {}
var _timeline: Dictionary = {}
var _forecast_stats: Dictionary = {}
var _generated_stats: Dictionary = {}
var _quality_report: Dictionary = {}
var _cycles_per_day := 24
var _simulation_seed := 177
var _selected_offset := 0.0
var _hover_offset := -1.0
var _selected_cycle_index := -1
var _chart_range_start := 0.0
var _chart_range_end := 24.0
var _updating_slider := false

var _date_input: LineEdit
var _seed_input: LineEdit
var _source_status: Label
var _metadata_label: Label
var _generation_status: Label
var _comparison_grid: GridContainer
var _comparison_caveat: Label
var _forecast_card_text: Label
var _generated_card_text: Label
var _timeline_row: HBoxContainer
var _timeline_scroll: ScrollContainer
var _cycle_slider: HSlider
var _detail_label: Label
var _export_status: Label
var _charts: Array[Control] = []


func _ready() -> void:
	_build_ui()
	_load_test_fixture()


func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var background := ColorRect.new()
	background.color = Color("0b1720")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var page_scroll := ScrollContainer.new()
	page_scroll.name = "PageScroll"
	page_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	page_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	add_child(page_scroll)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_bottom", 24)
	page_scroll.add_child(margin)
	var content := VBoxContainer.new()
	content.name = "LabContent"
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 12)
	margin.add_child(content)

	var title := Label.new()
	title.text = "WEATHER SIMULATION LAB  ·  W2.2b"
	title.add_theme_font_size_override("font_size", 24)
	content.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "逐时预报与确定性游戏时间线对照。只读本地数据；不联网、不控制主游戏天气。日期与横轴使用 UTC；Lab 内的 12/24 模式仅定义测试映射，不读取或修改 WorldTimeManager。"
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	subtitle.add_theme_font_size_override("font_size", 14)
	content.add_child(subtitle)

	var controls_panel := PanelContainer.new()
	controls_panel.name = "ControlsPanel"
	content.add_child(controls_panel)
	var controls_box := VBoxContainer.new()
	controls_box.add_theme_constant_override("separation", 8)
	controls_panel.add_child(controls_box)
	var source_row := HFlowContainer.new()
	source_row.add_theme_constant_override("h_separation", 8)
	source_row.add_theme_constant_override("v_separation", 6)
	controls_box.add_child(source_row)
	_add_button(source_row, "读取真实本地缓存", _load_live_cache, 160)
	_add_button(source_row, "使用测试 Fixture", _load_test_fixture, 150)
	var date_caption := _make_label("日期 UTC", 14)
	source_row.add_child(date_caption)
	_date_input = LineEdit.new()
	_date_input.name = "DateInput"
	_date_input.text = "2026-10-20"
	_date_input.placeholder_text = "YYYY-MM-DD"
	_date_input.custom_minimum_size.x = 132
	source_row.add_child(_date_input)
	var seed_caption := _make_label("种子", 14)
	source_row.add_child(seed_caption)
	_seed_input = LineEdit.new()
	_seed_input.name = "SeedInput"
	_seed_input.text = "177"
	_seed_input.custom_minimum_size.x = 86
	source_row.add_child(_seed_input)
	_add_button(source_row, "12 日轮", func() -> void: _set_cycles(12), 100)
	_add_button(source_row, "24 日轮", func() -> void: _set_cycles(24), 100)
	_add_button(source_row, "重新生成", _generate_timeline, 110)
	_add_button(source_row, "导出质量报告 JSON", _export_report, 180)
	_source_status = _make_label("来源尚未加载", 15)
	_source_status.name = "SourceStatus"
	_source_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	controls_box.add_child(_source_status)
	_metadata_label = _make_label("", 13)
	_metadata_label.name = "ForecastMetadata"
	_metadata_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	controls_box.add_child(_metadata_label)
	_generation_status = _make_label("", 14)
	_generation_status.name = "GenerationStatus"
	_generation_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	controls_box.add_child(_generation_status)

	var comparison_title := _make_label("REAL FORECAST  ↔  GENERATED GAME WEATHER", 18)
	comparison_title.add_theme_font_size_override("font_size", 19)
	content.add_child(comparison_title)
	var card_row := HBoxContainer.new()
	card_row.add_theme_constant_override("separation", 10)
	content.add_child(card_row)
	_forecast_card_text = _make_stat_card(card_row, "真实预报基准", "Forecast baseline")
	_generated_card_text = _make_stat_card(card_row, "游戏生成结果", "Generated timeline")
	_comparison_grid = GridContainer.new()
	_comparison_grid.name = "ComparisonGrid"
	_comparison_grid.columns = 4
	_comparison_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(_comparison_grid)
	_comparison_caveat = _make_label("", 12)
	_comparison_caveat.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_comparison_caveat)

	var timeline_title := _make_label("游戏日轮天气分布", 18)
	content.add_child(timeline_title)
	var timeline_note := _make_label("每格代表一个游戏昼夜；选择后将图表放大到对应区间。雨量统计不把预报概率当作降水量。", 13)
	timeline_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(timeline_note)
	_timeline_scroll = ScrollContainer.new()
	_timeline_scroll.name = "TimelineScroll"
	_timeline_scroll.custom_minimum_size.y = 124
	_timeline_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_timeline_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.add_child(_timeline_scroll)
	_timeline_row = HBoxContainer.new()
	_timeline_row.name = "TimelineCycles"
	_timeline_row.add_theme_constant_override("separation", 6)
	_timeline_scroll.add_child(_timeline_row)

	var slider_caption := _make_label("统一时间游标（游戏日轮偏移）", 14)
	content.add_child(slider_caption)
	_cycle_slider = HSlider.new()
	_cycle_slider.name = "CycleSlider"
	_cycle_slider.min_value = 0.0
	_cycle_slider.max_value = 24.0
	_cycle_slider.step = 0.01
	_cycle_slider.value_changed.connect(_on_slider_changed)
	content.add_child(_cycle_slider)

	var chart_heading := _make_label("连续气象曲线", 18)
	content.add_child(chart_heading)
	_add_chart(content, "wind", "A · 风速", "m/s · 实线为平均风，浅线为预报阵风，橙线为生成平均风，粉线为生成平均风 + 阵风目标")
	_add_chart(content, "cloud_precip", "B · 云量与降水", "左轴：云量 % · 右轴：降水 mm/h · 降水总量按最短有效重叠窗口积分")
	_add_chart(content, "direction", "C · 风向", "气象来向 · 真北顺时针 · 使用最短角度路径展开，北向跨 0° 时保持连续")

	var detail_title := _make_label("选中时间详情", 18)
	content.add_child(detail_title)
	_detail_label = _make_label("暂无采样。", 15)
	_detail_label.name = "SampleDetail"
	_detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_label.custom_minimum_size.y = 94
	content.add_child(_detail_label)
	_export_status = _make_label("", 13)
	_export_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_export_status)


func _make_stat_card(parent: HBoxContainer, heading: String, _subtitle: String) -> Label:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	panel.add_child(box)
	var title := _make_label(heading, 17)
	box.add_child(title)
	var body := _make_label("等待数据", 14)
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size.y = 112
	box.add_child(body)
	return body


func _add_chart(parent: VBoxContainer, kind: String, title: String, subtitle: String) -> void:
	var chart := CHART_SCRIPT.new() as Control
	chart.name = "Chart_%s" % kind
	chart.time_changed.connect(_on_chart_time_changed)
	chart.set_chart_data(kind, title, subtitle, [], 0.0, 24.0, 0.0)
	parent.add_child(chart)
	_charts.append(chart)


func _add_button(parent: Control, title: String, callback: Callable, min_width: float = 0.0) -> Button:
	var button := Button.new()
	button.text = title
	button.custom_minimum_size = Vector2(min_width, 36)
	button.pressed.connect(callback)
	parent.add_child(button)
	return button


func _make_label(value: String, font_size: int) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", font_size)
	return label


func _load_test_fixture() -> void:
	_source_mode = "fixture"
	_cache_envelope.clear()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE_PATH))
	if not parsed is Dictionary:
		_set_unavailable("Fixture 读取失败")
		return
	var validation := CODEC.validate_standardized_document(parsed)
	if not bool(validation.get("ok", false)):
		_set_unavailable("Fixture 校验失败：%s" % str(validation.get("error", "unknown")))
		return
	_forecast_document = parsed
	_source_label = "TEST FIXTURE"
	_freshness_label = "N/A · 合成数据"
	_forecast_quality = "fresh"
	_refresh_source_metadata()
	_generate_timeline()


func _load_live_cache() -> void:
	_source_mode = "live_cache"
	_forecast_document.clear()
	_cache_envelope.clear()
	var store = CACHE_STORE_SCRIPT.new()
	store.base_directory = LIVE_CACHE_DIRECTORY
	var loaded: Dictionary = store.load_envelope(REGION_ID)
	if not bool(loaded.get("ok", false)):
		_set_unavailable("真实本地缓存不可用（%s）；没有发起网络请求，也没有回退到 Fixture。" % str(loaded.get("status", "cache_miss")))
		return
	var envelope: Dictionary = loaded.get("envelope", {})
	var document: Variant = envelope.get("standardized_forecast", null)
	if not document is Dictionary:
		_set_unavailable("缓存没有标准化预报文档")
		return
	var validation := CODEC.validate_standardized_document(document)
	if not bool(validation.get("ok", false)) or str(document.get("region_id", "")) != REGION_ID:
		_set_unavailable("缓存预报无效或区域不匹配：%s" % str(validation.get("error", "region_mismatch")))
		return
	_forecast_document = document
	_cache_envelope = envelope
	_source_label = "LIVE CACHE"
	var expiry := int(envelope.get("expires_at_unix", 0))
	var now := int(Time.get_unix_time_from_system())
	_freshness_label = cache_freshness_label(expiry, now)
	_forecast_quality = "stale" if _freshness_label == "STALE CACHE" else "fresh"
	_refresh_source_metadata()
	_generate_timeline()


static func cache_freshness_label(expires_at_unix: int, now_unix: int) -> String:
	return "STALE CACHE" if expires_at_unix <= now_unix else "FRESH CACHE"


func _refresh_source_metadata() -> void:
	if _forecast_document.is_empty():
		return
	var samples: Array = _forecast_document.get("timeseries", [])
	var source_meta: Dictionary = _forecast_document.get("source_metadata", {})
	var fetched := str(_cache_envelope.get("fetched_at_utc", "N/A")) if _source_mode == "live_cache" else "N/A"
	var expires := str(_cache_envelope.get("expires_header", "N/A")) if _source_mode == "live_cache" else "N/A"
	var status_code := str(source_meta.get("http_status_code", "N/A")) if _source_mode == "live_cache" else "N/A"
	var origin_note := "MET Norway 本地缓存" if _source_mode == "live_cache" else "合成测试数据，不是观测/预报"
	var interval_note := _interval_histogram(samples)
	_source_status.text = "来源：%s  ·  新鲜度：%s  ·  数据质量由有效时间覆盖另行计算\n%s" % [_source_label, _freshness_label, origin_note]
	_metadata_label.text = "区域 %s（%.4f, %.4f） · 原始预报样本 %d · 有效时间 %s → %s\n预报发布时间 %s · 获取时间 %s · 缓存过期 %s · HTTP %s" % [
		str(_forecast_document.get("region_id", REGION_ID)), float(_forecast_document.get("latitude", 0.0)), float(_forecast_document.get("longitude", 0.0)), samples.size(),
		str(_forecast_document.get("valid_from_utc", "N/A")), str(_forecast_document.get("valid_until_utc", "N/A")),
		str(_forecast_document.get("forecast_issued_at_utc", "N/A")), fetched, expires, status_code,
	]
	_metadata_label.text += "\n预报间隔：%s" % interval_note


func _set_unavailable(reason: String) -> void:
	_forecast_document.clear()
	_timeline.clear()
	_forecast_stats.clear()
	_generated_stats.clear()
	_quality_report.clear()
	_source_label = "UNAVAILABLE"
	_freshness_label = "N/A"
	_source_status.text = "来源：UNAVAILABLE  ·  %s" % reason
	_metadata_label.text = "没有可用的本地数据。Lab 不会自动发起网络请求。"
	_generation_status.text = "请加载 Fixture，或先在 Weather API Lab 中手动获取并保存真实缓存。"
	_render_empty_results()


func _set_cycles(cycles: int) -> void:
	_cycles_per_day = cycles
	_generate_timeline()


func _generate_timeline() -> void:
	if _forecast_document.is_empty():
		return
	var date_text := _date_input.text.strip_edges()
	if not _is_date_text_valid(date_text):
		_generation_status.text = "日期格式无效；请使用 YYYY-MM-DD（UTC）。"
		return
	_simulation_seed = int(_seed_input.text) if _seed_input.text.is_valid_int() else 177
	if _simulation_seed < 0:
		_generation_status.text = "随机种子必须为非负整数。"
		return
	var start_utc := "%sT00:00:00Z" % date_text
	var start_unix := CODEC.parse_utc_timestamp_to_unix(start_utc)
	if start_unix < 0:
		_generation_status.text = "日期无效。"
		return
	var end_utc := CODEC._utc_iso_from_unix(start_unix + 86400)
	var request := {
		"schema_version": 1,
		"request_id": "weather_lab_%s_%d_%d" % [date_text, _cycles_per_day, _simulation_seed],
		"region_id": REGION_ID,
		"requested_start_utc": start_utc,
		"requested_end_utc": end_utc,
		"generated_at_utc": str(_forecast_document.get("retrieved_at_utc", _forecast_document.get("forecast_issued_at_utc", start_utc))),
		"simulation_seed": _simulation_seed,
		"cycles_per_real_day": _cycles_per_day,
		"resolution_per_cycle": 4,
		"forecast_quality": _forecast_quality,
		"forecast_documents": [_forecast_document],
		"simulation_anchor": {
			"day_cycle_index": 100,
			"cycle_seconds": 0.0,
			"authoritative_timestamp_utc": start_utc,
			"time_scale": float(_cycles_per_day),
			"paused": false,
			"authority_session_id": "weather-simulation-lab",
			"authority_snapshot_sequence": 1,
		},
	}
	var generated := CORE.generate_timeline(request)
	if not bool(generated.get("ok", false)):
		_generation_status.text = "时间线生成失败：%s" % str(generated.get("error", "unknown"))
		return
	_timeline = generated["timeline"]
	_forecast_stats = ANALYSIS.analyze_forecast(_forecast_document, start_utc, end_utc)
	_generated_stats = ANALYSIS.analyze_timeline(_timeline, _forecast_document)
	if bool(_forecast_stats.get("ok", false)) and bool(_generated_stats.get("ok", false)):
		_quality_report = ANALYSIS.build_quality_report(_forecast_document, _timeline, _forecast_stats, _generated_stats)
		_quality_report["data_source_classification"] = {
			"source_kind": _source_label,
			"cache_freshness": _freshness_label,
			"is_live_weather": _source_mode == "live_cache",
			"note": "source_data_quality describes timeline coverage/staleness; it is not a substitute for source kind or local cache freshness.",
		}
	else:
		_quality_report.clear()
	_selected_offset = 0.0
	_hover_offset = -1.0
	_selected_cycle_index = -1
	_chart_range_start = 0.0
	_chart_range_end = float(_cycles_per_day)
	_cycle_slider.min_value = 0.0
	_cycle_slider.max_value = float(_cycles_per_day)
	_updating_slider = true
	_cycle_slider.value = 0.0
	_updating_slider = false
	var data_quality := str(_timeline.get("source_data_quality", "unknown"))
	_generation_status.text = "模拟日期 %s UTC · %d 个游戏日轮 · 生成关键帧 %d（每轮 4 段）· 时间覆盖质量 %s · 种子 %d" % [
		date_text, _cycles_per_day, _timeline.get("keyframes", []).size(), data_quality, _simulation_seed,
	]
	_refresh_source_metadata()
	_render_analysis()
	_render_timeline()
	_render_charts()
	_update_details(0.0)


func _is_date_text_valid(value: String) -> bool:
	if value.length() != 10 or value[4] != "-" or value[7] != "-":
		return false
	var unix := CODEC.parse_utc_timestamp_to_unix(value + "T00:00:00Z")
	return unix >= 0 and CODEC._utc_iso_from_unix(unix).begins_with(value)


func _render_analysis() -> void:
	if _quality_report.is_empty():
		_forecast_card_text.text = "数据覆盖不足，当前日期无法计算统计。"
		_generated_card_text.text = "N/A"
		for child in _comparison_grid.get_children():
			child.queue_free()
		_comparison_caveat.text = "统计需要在所选 UTC 日期内有可插值预报覆盖；缓存新鲜度与覆盖率是两个独立状态。"
		return
	_forecast_card_text.text = _format_stats(_forecast_stats, true)
	_generated_card_text.text = _format_stats(_generated_stats, false)
	for child in _comparison_grid.get_children():
		child.queue_free()
	for heading in ["指标", "真实预报", "游戏生成", "差值（生成−预报）"]:
		var label := _make_label(heading, 13)
		label.add_theme_color_override("font_color", Color("efcf9c"))
		_comparison_grid.add_child(label)
	var rows := [
		["平均风速", "mean_wind_speed_mps", "m/s"],
		["风速 P90", "wind_speed_p90_mps", "m/s"],
		["最大风速", "max_wind_speed_mps", "m/s"],
		["主导风向", "dominant_wind_from_deg", "°"],
		["平均云量", "mean_cloud_fraction", "%"],
		["明确降水占全天（只计已知时段）", "explicit_precipitation_day_fraction", "%"],
		["可能降水占全天（只计已知时段）", "possible_precipitation_day_fraction", "%"],
		["明确降水占降水证据时段†", "explicit_precipitation_time_share_fraction", "%"],
		["可能降水占降水证据时段†", "possible_precipitation_time_share_fraction", "%"],
		["预报降水总量估算", "expected_precipitation_total_mm", "mm"],
	]
	for row in rows:
		var metric: String = row[1]
		var real_value: Variant = _forecast_stats.get("metrics", {}).get(metric, null)
		var game_value: Variant = _generated_stats.get("metrics", {}).get(metric, null)
		var real_label := _make_label(_format_stat_value(metric, real_value), 13)
		var game_label := _make_label(_format_stat_value(metric, game_value), 13)
		var difference: Variant = _quality_report.get("comparison", {}).get(metric, {}).get("difference", null)
		if metric == "dominant_wind_from_deg":
			difference = _quality_report.get("comparison", {}).get("dominant_wind_direction", {}).get("shortest_signed_difference_deg", null)
		var diff_label := _make_label(_format_stat_value(metric, difference, true), 13)
		for label in [real_label, game_label, diff_label]:
			label.clip_text = true
			label.custom_minimum_size.x = 100
		var row_title := "%s (%s)" % [str(row[0]), str(row[2])] if not str(row[2]).is_empty() else str(row[0])
		_comparison_grid.add_child(_make_label(row_title, 13))
		_comparison_grid.add_child(real_label)
		_comparison_grid.add_child(game_label)
		_comparison_grid.add_child(diff_label)
	_comparison_caveat.text = "全天占比只计有符号或降水窗口证据的小时，未覆盖时间保持未知；† 条件占比以有降水证据的时长为分母。查看降水窗口覆盖率与分辨率判断代表性。雨量按最短且含雨量值的有效窗口估算，不使用概率换算雨量。"


func _format_stats(stats: Dictionary, is_forecast: bool) -> String:
	if not bool(stats.get("ok", false)):
		return "统计不可用：%s" % str(stats.get("error", "unknown"))
	var metrics: Dictionary = stats.get("metrics", {})
	var shares: Dictionary = metrics.get("weather_type_share_percent", {})
	var direction := _format_stat_value("dominant_wind_from_deg", metrics.get("dominant_wind_from_deg", null))
	var coverage := float(stats.get("coverage", {}).get("wind", 0.0)) * 100.0
	var precip_coverage := float(metrics.get("precipitation_evidence_coverage_fraction", 0.0)) * 100.0
	var explicit_share: Variant = metrics.get("explicit_precipitation_time_share_fraction", null)
	var possible_share: Variant = metrics.get("possible_precipitation_time_share_fraction", null)
	var lines := [
		"%s · 覆盖 %.1f%% · %d 个输入点/关键帧" % ["原始预报" if is_forecast else "生成时间线", coverage, int(stats.get("sample_or_keyframe_count", 0))],
		"平均风速 %s · P90 %s · 最大风速 %s" % [_format_stat_value("mean_wind_speed_mps", metrics.get("mean_wind_speed_mps", null)), _format_stat_value("wind_speed_p90_mps", metrics.get("wind_speed_p90_mps", null)), _format_stat_value("max_wind_speed_mps", metrics.get("max_wind_speed_mps", null))],
		"明确降水占全天（有证据）%s · 可能降水占全天（有证据）%s" % [_format_stat_value("explicit_precipitation_day_fraction", metrics.get("explicit_precipitation_day_fraction", null)), _format_stat_value("possible_precipitation_day_fraction", metrics.get("possible_precipitation_day_fraction", null))],
		"主导来向 %s · 平均云量 %s · 降水证据时段内明确 %s / 可能 %s" % [direction, _format_stat_value("mean_cloud_fraction", metrics.get("mean_cloud_fraction", null)), _format_stat_value("explicit_precipitation_time_share_fraction", explicit_share), _format_stat_value("possible_precipitation_time_share_fraction", possible_share)],
		"雨量估算 %s · 天气类型：%s" % [_format_stat_value("expected_precipitation_total_mm", metrics.get("expected_precipitation_total_mm", null)), _format_type_shares(shares)],
		"降水窗口覆盖 %.1f%% (%s) · 分辨率 %s–%s h · 最长明确降水 %.2f h" % [precip_coverage, str(metrics.get("precipitation_evidence_coverage_status", "unavailable")), _format_stat_value("precipitation_time_resolution_min_hours", metrics.get("precipitation_time_resolution_min_hours", null)), _format_stat_value("precipitation_time_resolution_max_hours", metrics.get("precipitation_time_resolution_max_hours", null)), float(metrics.get("max_continuous_precipitation_signal_hours", 0.0))],
	]
	if is_forecast:
		lines.append("阵风峰值 %s · 气温 %s–%s · 气压 %s–%s hPa" % [
			_format_stat_value("max_forecast_gust_mps", metrics.get("max_forecast_gust_mps", null)),
			_format_stat_value("temperature_min_c", metrics.get("temperature_min_c", null)), _format_stat_value("temperature_max_c", metrics.get("temperature_max_c", null)),
			_format_stat_value("pressure_min_hpa", metrics.get("pressure_min_hpa", null)), _format_stat_value("pressure_max_hpa", metrics.get("pressure_max_hpa", null)),
		])
	lines.append("最长可能降水 %.2f h · 分类依据 %s" % [float(metrics.get("max_continuous_possible_precipitation_hours", 0.0)), "生成天气状态" if not is_forecast else "符号/降水窗口/云量，详见所选时刻"])
	if not is_forecast:
		lines.append("天气切换 %d 次 · 最长晴天 %.2f h" % [int(metrics.get("state_transition_count", 0)), float(metrics.get("max_continuous_clear_hours", 0.0))])
	return "\n".join(lines)


func _format_type_shares(shares: Dictionary) -> String:
	if shares.is_empty():
		return "N/A"
	var labels: Array[String] = []
	var keys: Array = shares.keys()
	keys.sort_custom(func(a: Variant, b: Variant) -> bool: return float(shares[a]) > float(shares[b]))
	for kind in keys:
		labels.append("%s %.0f%%" % [_weather_label(str(kind)), float(shares[kind])])
	return " / ".join(labels)


func _format_stat_value(metric: String, value: Variant, is_difference: bool = false) -> String:
	if value == null or not (value is int or value is float) or not is_finite(float(value)):
		return "N/A"
	var number := float(value)
	match metric:
		"mean_wind_speed_mps", "wind_speed_p90_mps", "max_wind_speed_mps", "max_forecast_gust_mps": return "%+.2f m/s" % number if is_difference else "%.2f m/s" % number
		"temperature_min_c", "temperature_max_c": return "%+.2f°C" % number if is_difference else "%.2f°C" % number
		"mean_cloud_fraction", "precipitation_signal_share", "explicit_precipitation_time_share_fraction", "possible_precipitation_time_share_fraction": return "%+.1f%%" % (number * 100.0) if is_difference else "%.1f%%" % (number * 100.0)
		"expected_precipitation_total_mm": return "%+.2f mm" % number if is_difference else "%.2f mm" % number
		"dominant_wind_from_deg": return "%+.1f°" % number if is_difference else "%03.0f°" % fposmod(number, 360.0)
		_: return "%+.2f" % number if is_difference else "%.2f" % number


func _dominant_category(shares: Dictionary) -> String:
	var best := "N/A"
	var best_share := -1.0
	for kind in shares:
		if float(shares[kind]) > best_share:
			best = _weather_label(str(kind))
			best_share = float(shares[kind])
	return best


func _interval_histogram(samples: Array) -> String:
	if samples.size() < 2:
		return "N/A（不足两个样本）"
	var ordered: Array[Dictionary] = []
	for sample in samples:
		if sample is Dictionary:
			ordered.append(sample)
	ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return CODEC.parse_utc_timestamp_to_unix(str(a.get("valid_time_utc", ""))) < CODEC.parse_utc_timestamp_to_unix(str(b.get("valid_time_utc", "")))
	)
	var counts := {}
	for index in range(ordered.size() - 1):
		var start := CODEC.parse_utc_timestamp_to_unix(str(ordered[index].get("valid_time_utc", "")))
		var finish := CODEC.parse_utc_timestamp_to_unix(str(ordered[index + 1].get("valid_time_utc", "")))
		if start >= 0 and finish > start:
			var gap_hours := int(round(float(finish - start) / 3600.0))
			counts[gap_hours] = int(counts.get(gap_hours, 0)) + 1
	var labels: Array[String] = []
	var gaps := counts.keys()
	gaps.sort()
	for gap in gaps:
		labels.append("%dh×%d" % [int(gap), int(counts[gap])])
	return ", ".join(labels)


func _render_timeline() -> void:
	for child in _timeline_row.get_children():
		child.queue_free()
	if _timeline.is_empty():
		return
	for cycle_index in range(_cycles_per_day):
		var cycle_stats: Dictionary = ANALYSIS.analyze_timeline(_timeline, _forecast_document, float(cycle_index), float(cycle_index + 1))
		var metrics: Dictionary = cycle_stats.get("metrics", {})
		var category := _dominant_category(metrics.get("weather_type_share_percent", {}))
		var wind: Variant = metrics.get("mean_wind_speed_mps", null)
		var max_wind: Variant = metrics.get("max_wind_speed_mps", null)
		var precip: Variant = metrics.get("explicit_precipitation_time_share_fraction", null)
		var possible_precip: Variant = metrics.get("possible_precipitation_time_share_fraction", null)
		var button := Button.new()
		button.name = "Cycle_%02d" % (cycle_index + 1)
		button.custom_minimum_size = Vector2(104, 102)
		button.text = "%02d  %s\n风 %s / 峰 %s\n明确 %s · 可能 %s" % [
			cycle_index + 1, category,
			("%.1f" % float(wind)) if _is_number(wind) else "N/A",
			("%.1f" % float(max_wind)) if _is_number(max_wind) else "N/A",
			("%.0f%%" % (float(precip) * 100.0)) if _is_number(precip) else "N/A",
			("%.0f%%" % (float(possible_precip) * 100.0)) if _is_number(possible_precip) else "N/A",
		]
		button.tooltip_text = "覆盖 %.1f / %.1f h · 选中后放大该日轮" % [float(cycle_stats.get("covered_hours", 0.0)), float(cycle_stats.get("range_hours", 0.0))]
		button.add_theme_color_override("font_color", Color("f0f2ee"))
		button.add_theme_stylebox_override("normal", _timeline_style(_weather_color(category)))
		button.pressed.connect(_select_cycle.bind(cycle_index))
		_timeline_row.add_child(button)


func _timeline_style(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(color.r * 0.26, color.g * 0.28, color.b * 0.30, 0.92)
	style.border_color = color
	style.set_border_width_all(1)
	style.set_corner_radius_all(5)
	style.set_content_margin_all(5)
	return style


func _select_cycle(cycle_index: int) -> void:
	_selected_cycle_index = cycle_index
	_chart_range_start = float(cycle_index)
	_chart_range_end = float(cycle_index + 1)
	_set_selected_offset(float(cycle_index) + 0.5)
	_render_charts()


func _render_charts() -> void:
	if _timeline.is_empty() or _forecast_document.is_empty():
		return
	var raw_wind: Array[Dictionary] = []
	var raw_gust: Array[Dictionary] = []
	var generated_wind: Array[Dictionary] = []
	var generated_peak: Array[Dictionary] = []
	var raw_cloud: Array[Dictionary] = []
	var generated_cloud: Array[Dictionary] = []
	var raw_precip: Array[Dictionary] = []
	var generated_precip: Array[Dictionary] = []
	var raw_direction: Array[Dictionary] = []
	var generated_direction: Array[Dictionary] = []
	var start_unix := CODEC.parse_utc_timestamp_to_unix(str(_timeline["real_start_utc"]))
	var day_duration := float(CODEC.parse_utc_timestamp_to_unix(str(_timeline["real_end_utc"])) - start_unix)
	for sample in _forecast_document.get("timeseries", []):
		var at := CODEC.parse_utc_timestamp_to_unix(str(sample.get("valid_time_utc", "")))
		if at < 0:
			continue
		var cycle := float(at - start_unix) / day_duration * float(_cycles_per_day)
		raw_wind.append(_chart_point(cycle, sample.get("wind_speed_mps", null)))
		raw_gust.append(_chart_point(cycle, sample.get("wind_gust_mps", null)))
		raw_cloud.append(_chart_point(cycle, float(sample["cloud_fraction"]) * 100.0 if sample.has("cloud_fraction") else null))
		raw_precip.append(_chart_point(cycle, ANALYSIS.precipitation_rate_for_document(_forecast_document, float(at))))
		raw_direction.append(_chart_point(cycle, sample.get("wind_from_direction_deg", null)))
	for frame in _timeline.get("keyframes", []):
		var cycle := float(frame.get("cycle_offset", 0.0))
		var wind: Variant = frame.get("mean_wind_speed_mps", null)
		var gust_strength: Variant = frame.get("gust_target", {}).get("gust_strength_mps", null) if frame.get("gust_target", {}) is Dictionary else null
		generated_wind.append(_chart_point(cycle, wind))
		generated_peak.append(_chart_point(cycle, float(wind) + float(gust_strength) if _is_number(wind) and _is_number(gust_strength) else null))
		generated_cloud.append(_chart_point(cycle, float(frame["cloud_fraction"]) * 100.0 if frame.has("cloud_fraction") else null))
		generated_precip.append(_chart_point(cycle, frame.get("precipitation_intensity_mm_per_hour", null)))
		generated_direction.append(_chart_point(cycle, frame.get("wind_from_direction_deg", null)))
	var wind_series: Array[Dictionary] = [
		{"name":"预报平均风", "color":Color("81c9e0"), "points":raw_wind},
		{"name":"预报阵风", "color":Color("b4d9cb"), "points":raw_gust},
		{"name":"生成平均风", "color":Color("f2bd78"), "points":generated_wind, "width":2.8},
		{"name":"生成风速+阵风目标", "color":Color("e88678"), "points":generated_peak, "width":2.2},
	]
	var cloud_series: Array[Dictionary] = [
		{"name":"预报云量 %", "color":Color("74c6da"), "points":raw_cloud},
		{"name":"生成云量 %", "color":Color("e9c27d"), "points":generated_cloud, "width":2.8},
		{"name":"预报降水 mm/h", "color":Color("90bbd4"), "points":raw_precip, "axis":"right"},
		{"name":"生成降水 mm/h", "color":Color("e88e78"), "points":generated_precip, "axis":"right", "width":2.8},
	]
	var direction_series: Array[Dictionary] = [
		{"name":"预报来向", "color":Color("7cc4db"), "points":_unwrap_points(raw_direction)},
		{"name":"生成来向", "color":Color("efbd7a"), "points":_unwrap_points(generated_direction), "width":2.8},
	]
	var series_by_chart := [wind_series, cloud_series, direction_series]
	var titles := ["A · 风速与阵风", "B · 云量与降水", "C · 气象来向"]
	var subtitles := ["单位：m/s · 生成阵风曲线为平均风速加 WindField 阵风强度目标", "左轴：云量 % · 右轴：降水 mm/h", "气象来向 0–360° · 纵轴按圆周连续展开并标出 N / E / S / W"]
	for index in range(_charts.size()):
		_charts[index].set_chart_data(["wind", "cloud_precip", "direction"][index], titles[index], subtitles[index], series_by_chart[index], _chart_range_start, _chart_range_end, _selected_offset)


func _chart_point(cycle: float, value: Variant) -> Dictionary:
	return {"cycle": cycle, "value": value}


func _unwrap_points(points: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var previous_raw: Variant = null
	var previous_unwrapped := 0.0
	for point in points:
		var copy := point.duplicate(true)
		var value: Variant = copy.get("value", null)
		if not _is_number(value):
			previous_raw = null
			result.append(copy)
			continue
		var normalized := fposmod(float(value), 360.0)
		if previous_raw == null:
			previous_unwrapped = normalized
		else:
			var delta := fposmod(normalized - float(previous_raw) + 180.0, 360.0) - 180.0
			previous_unwrapped += delta
		copy["value"] = previous_unwrapped
		previous_raw = normalized
		result.append(copy)
	return result


func _select_chart_range_for_cycle(cycle_index: int) -> void:
	_selected_cycle_index = cycle_index
	_chart_range_start = float(cycle_index)
	_chart_range_end = float(cycle_index + 1)


func _on_chart_time_changed(cycle_offset: float, committed: bool) -> void:
	_hover_offset = -1.0 if committed else cycle_offset
	if committed:
		_set_selected_offset(cycle_offset)
	else:
		_update_details(cycle_offset)


func _on_slider_changed(value: float) -> void:
	if _updating_slider:
		return
	_set_selected_offset(value)


func _set_selected_offset(value: float) -> void:
	_selected_offset = clampf(value, 0.0, float(_cycles_per_day))
	_updating_slider = true
	if _cycle_slider != null:
		_cycle_slider.value = _selected_offset
	_updating_slider = false
	for chart in _charts:
		chart.set_selected_cycle(_selected_offset)
	_update_details(_selected_offset)


func _update_details(cycle_offset: float) -> void:
	if _timeline.is_empty():
		_detail_label.text = "无天气采样可显示。"
		return
	var sampled := CORE.sample_weather(_timeline, {"elapsed_cycles": cycle_offset})
	if not bool(sampled.get("ok", false)):
		_detail_label.text = "采样失败：%s" % str(sampled.get("error", "unknown"))
		return
	var state: Dictionary = sampled["state"]
	var valid_time_utc := str(state.get("valid_time_utc", "N/A"))
	var forecast_sample := ANALYSIS.sample_forecast_at_utc(_forecast_document, valid_time_utc)
	var raw_fields: Dictionary = forecast_sample.get("fields", {})
	var raw_precipitation: Dictionary = forecast_sample.get("precipitation", {})
	var wind := _format_unit(state.get("mean_wind_speed_mps", null), "m/s")
	var direction := _format_direction(state.get("wind_from_direction_deg", null))
	var gust := "N/A"
	if state.get("gust_target", null) is Dictionary:
		gust = _format_unit(state["gust_target"].get("gust_strength_mps", null), "m/s（强度目标）")
	var cloud := _format_percent(state.get("cloud_fraction", null))
	var precipitation := _format_unit(state.get("precipitation_intensity_mm_per_hour", null), "mm/h")
	var temperature := _format_unit(state.get("air_temperature_c", null), "°C")
	var pressure := _format_unit(state.get("air_pressure_hpa", null), "hPa")
	var forecast_quality := str(state.get("data_quality", "unknown"))
	var cycle_index := mini(_cycles_per_day - 1, maxi(0, floori(cycle_offset)))
	var progress := fposmod(cycle_offset, 1.0) * 100.0
	var raw_precipitation_text := _format_unit(raw_precipitation.get("rate_mm_per_hour", null), "mm/h")
	var raw_precipitation_probability := _format_percent(raw_precipitation.get("probability", null))
	var raw_symbol := str(forecast_sample.get("weather_symbol", "N/A")) if bool(forecast_sample.get("supported", false)) else "N/A（时段未覆盖）"
	var symbol_window: Dictionary = forecast_sample.get("weather_symbol_window", {})
	var symbol_window_text := "N/A"
	if not symbol_window.is_empty():
		symbol_window_text = "%s → %s · %s / %dh" % [str(symbol_window.get("period_start_utc", "")), str(symbol_window.get("period_end_utc", "")), str(symbol_window.get("source_period_key", "")), int(symbol_window.get("duration_hours", 0))]
	var amount_window_text := "N/A"
	if raw_precipitation.has("amount_period_start_utc"):
		amount_window_text = "%s → %s · %s / %dh" % [str(raw_precipitation.get("amount_period_start_utc", "")), str(raw_precipitation.get("amount_period_end_utc", "")), str(raw_precipitation.get("amount_source_period_key", "")), int(raw_precipitation.get("amount_window_hours", 0))]
	var probability_window_text := "N/A"
	if raw_precipitation.has("probability_period_start_utc"):
		probability_window_text = "%s → %s · %s / %dh" % [str(raw_precipitation.get("probability_period_start_utc", "")), str(raw_precipitation.get("probability_period_end_utc", "")), str(raw_precipitation.get("probability_source_period_key", "")), int(raw_precipitation.get("probability_window_hours", 0))]
	var forecast_line := "原始预报：风 %s · 来向 %s · 阵风峰值 %s · 云量 %s · 降水率 %s · 降水概率 %s · 符号 %s" % [
		_format_unit(raw_fields.get("wind_speed_mps", null), "m/s"),
		_format_direction(raw_fields.get("wind_from_direction_deg", null)),
		_format_unit(raw_fields.get("wind_gust_mps", null), "m/s"),
		_format_percent(raw_fields.get("cloud_fraction", null)),
		raw_precipitation_text,
		raw_precipitation_probability,
		raw_symbol,
	]
	var generated_probability := _format_percent(state.get("precipitation_probability", null))
	_detail_label.text = "日轮 %d / %d · 日轮内进度 %.1f%% · 对应 UTC %s\n" % [cycle_index + 1, _cycles_per_day, progress, valid_time_utc] \
		+ forecast_line + "\n" \
		+ "分类依据：%s · 符号窗口：%s\n" % [_classification_basis_label(str(forecast_sample.get("classification_basis", "insufficient_evidence"))), symbol_window_text] \
		+ "降水量窗口：%s\n降水概率窗口：%s\n" % [amount_window_text, probability_window_text] \
		+ "生成天气：风 %s · 来向 %s · 阵风强度目标 %s · 云量 %s · 降水强度 %s · 降水概率 %s\n" % [wind, direction, gust, cloud, precipitation, generated_probability] \
		+ "生成气温 %s · 气压 %s · 类型 %s（依据 %s）· 视觉预设 %s\n" % [temperature, pressure, _weather_label(str(state.get("weather_type", "Unknown"))), _classification_basis_label(str(state.get("weather_classification_basis", "insufficient_evidence"))), str(state.get("visual_weather_id", "Unknown"))] \
		+ "来源 %s · 缓存新鲜度 %s · 时间覆盖质量 %s · 时间线版本 %s" % [_source_label, _freshness_label, forecast_quality, str(state.get("timeline_version", ""))]


func _classification_basis_label(value: String) -> String:
	match value:
		"weather_symbol_period": return "天气符号时间窗"
		"precipitation_amount_period": return "明确降水量时间窗"
		"precipitation_probability_only_possible": return "仅降水概率（可能降水）"
		"precipitation_probability_and_cloud": return "降水概率与云量"
		"instant_cloud_fraction": return "瞬时云量"
		"insufficient_evidence": return "证据不足"
		_: return value if not value.is_empty() else "N/A"


func _render_empty_results() -> void:
	_forecast_card_text.text = "不可用"
	_generated_card_text.text = "不可用"
	for child in _comparison_grid.get_children():
		child.queue_free()
	for chart in _charts:
		chart.set_chart_data("wind", "", "", [], 0.0, 1.0, 0.0)
	for child in _timeline_row.get_children():
		child.queue_free()
	_comparison_caveat.text = ""
	_detail_label.text = "没有数据。"


func _export_report() -> void:
	if _quality_report.is_empty():
		_export_status.text = "无法导出：尚无有效质量报告。"
		return
	var path := "user://weather_simulation_quality_report.json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_export_status.text = "写入失败：%s" % error_string(FileAccess.get_open_error())
		return
	file.store_string(JSON.stringify(_quality_report, "\t", true, true))
	file.close()
	_export_status.text = "质量报告已导出到 %s" % ProjectSettings.globalize_path(path)


func _weather_label(kind: String) -> String:
	match kind:
		"Clear": return "晴"
		"PartlyCloudy": return "多云"
		"Overcast": return "阴"
		"Precipitation": return "降水"
		"PrecipitationPossible": return "有降水可能"
		"ThunderstormForecast": return "雷暴预报"
	return "未知"


func _weather_color(label: String) -> Color:
	if label == "晴": return COLOR_CLEAR
	if label == "多云": return COLOR_PARTLY
	if label == "阴": return COLOR_OVERCAST
	if label == "降水": return COLOR_PRECIP
	if label == "有降水可能": return COLOR_POSSIBLE
	return COLOR_UNKNOWN


func _format_unit(value: Variant, suffix: String) -> String:
	return "N/A" if not _is_number(value) else "%.2f %s" % [float(value), suffix]


func _format_percent(value: Variant) -> String:
	return "N/A" if not _is_number(value) else "%.1f%%" % (float(value) * 100.0)


func _format_direction(value: Variant) -> String:
	if not _is_number(value):
		return "N/A"
	var bearing := fposmod(float(value), 360.0)
	var names := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
	return "%03.0f° %s（气象来向）" % [bearing, names[int(round(bearing / 45.0)) % names.size()]]


func _is_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))
