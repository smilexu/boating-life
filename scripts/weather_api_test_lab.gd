extends Control

const PROVIDER_SCRIPT := preload("res://scripts/weather_data/weather_data_provider.gd")
const HTTP_ADAPTER_SCRIPT := preload("res://scripts/weather_data/met_norway_http_adapter.gd")
const CACHE_STORE_SCRIPT := preload("res://scripts/weather_data/weather_file_cache_store.gd")
const CLOCK_SCRIPT := preload("res://scripts/weather_data/weather_clock_adapter.gd")
const SCHEDULER_SCRIPT := preload("res://scripts/weather_data/weather_retry_scheduler.gd")
const SETTINGS_SCRIPT := preload("res://scripts/weather_data/weather_user_agent_settings.gd")
const REGION: WeatherRegion = preload("res://resources/weather_region_oresund.tres")
const FIXTURE_PATH := "res://tests/fixtures/met_norway_complete_fixture.json"
const MOCK_CONTACT := "https://offline-test.invalid/weather-lab"


class ManualMockTransport extends RefCounted:
	var mode := "fixture"
	var fixture_body := PackedByteArray()
	var request_count := 0
	var last_request: Dictionary = {}

	func request(request_data: Dictionary, callback: Callable) -> void:
		request_count += 1
		last_request = request_data.duplicate(true)
		var response: Dictionary
		match mode:
			"offline":
				response = {"transport_result": HTTPRequest.RESULT_CANT_CONNECT, "status_code": 0, "headers": PackedStringArray(), "body": PackedByteArray()}
			"timeout":
				response = {"transport_result": HTTPRequest.RESULT_TIMEOUT, "status_code": 0, "headers": PackedStringArray(), "body": PackedByteArray()}
			"not_modified":
				response = {"transport_result": HTTPRequest.RESULT_SUCCESS, "status_code": 304, "headers": PackedStringArray(["Cache-Control: max-age=120", "Last-Modified: Tue, 20 Oct 2026 12:00:00 GMT"]), "body": PackedByteArray()}
			"invalid_json":
				response = {"transport_result": HTTPRequest.RESULT_SUCCESS, "status_code": 200, "headers": PackedStringArray(["Cache-Control: max-age=60"]), "body": "{broken".to_utf8_buffer()}
			_:
				response = {
					"transport_result": HTTPRequest.RESULT_SUCCESS,
					"status_code": 200,
					"headers": PackedStringArray(["Cache-Control: max-age=0", "Last-Modified: Tue, 20 Oct 2026 12:00:00 GMT", "ETag: \"lab-fixture\""]),
					"body": fixture_body,
				}
		callback.call_deferred(response)


var _provider: WeatherDataProvider
var _http_adapter: MetNorwayHttpAdapter
var _mock_transport := ManualMockTransport.new()
var _live_cache_store: WeatherFileCacheStore
var _mock_cache_store: WeatherFileCacheStore
var _contact_input: LineEdit
var _status_label: Label
var _summary_label: Label
var _forecast_text: RichTextLabel
var _request_info_label: Label
var _request_in_flight := false


func _ready() -> void:
	_mock_transport.fixture_body = FileAccess.get_file_as_string(FIXTURE_PATH).to_utf8_buffer()
	_live_cache_store = CACHE_STORE_SCRIPT.new() as WeatherFileCacheStore
	_live_cache_store.base_directory = "res://.godot/weather_live_request_cache"
	_mock_cache_store = CACHE_STORE_SCRIPT.new() as WeatherFileCacheStore
	_mock_cache_store.base_directory = "res://.godot/weather_api_lab_mock_cache"
	_http_adapter = HTTP_ADAPTER_SCRIPT.new() as MetNorwayHttpAdapter
	_http_adapter.name = "MetNorwayHttpAdapter"
	add_child(_http_adapter)
	_build_ui()
	_contact_input.text = SETTINGS_SCRIPT.load_contact()
	_configure_provider(_http_adapter, _contact_input.text)
	_set_status("就绪。不会自动发起网络请求。", Color(0.63, 0.82, 0.76))
	_show_result(_provider.read_forecast(REGION.region_id))


func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var background := ColorRect.new()
	background.color = Color("101e29")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_bottom", 18)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	var title := Label.new()
	title.text = "MET Norway · Weather Data Provider Lab"
	title.add_theme_font_size_override("font_size", 24)
	root.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "离线模拟与真实 API 请求分离；所有网络操作均由按钮手动触发。此场景不会连接正式天气系统。"
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(subtitle)

	var contact_row := HBoxContainer.new()
	contact_row.add_theme_constant_override("separation", 8)
	root.add_child(contact_row)
	var contact_caption := Label.new()
	contact_caption.text = "User-Agent 联系方式"
	contact_caption.custom_minimum_size.x = 165
	contact_row.add_child(contact_caption)
	_contact_input = LineEdit.new()
	_contact_input.placeholder_text = "MET_NORWAY_CONTACT 或本地配置"
	_contact_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	contact_row.add_child(_contact_input)
	_add_button(contact_row, "保存本机配置", _save_contact)
	_add_button(contact_row, "重载环境/配置", _reload_contact)

	var button_scroll := ScrollContainer.new()
	button_scroll.custom_minimum_size.y = 78
	button_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	button_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(button_scroll)
	var actions := HFlowContainer.new()
	actions.add_theme_constant_override("h_separation", 8)
	actions.add_theme_constant_override("v_separation", 6)
	button_scroll.add_child(actions)
	_add_button(actions, "读取真实 API 缓存", _read_cache)
	_add_button(actions, "读取模拟缓存", _read_mock_cache)
	_add_button(actions, "加载离线 Fixture", _load_fixture)
	_add_button(actions, "模拟 HTTP 200 + 缓存", _simulate_fixture_response)
	_add_button(actions, "模拟 HTTP 304", _simulate_not_modified)
	_add_button(actions, "模拟断网", _simulate_offline)
	_add_button(actions, "模拟超时", _simulate_timeout)
	_add_button(actions, "模拟损坏 JSON", _simulate_invalid_json)
	_add_button(actions, "损坏模拟缓存", _corrupt_cache)
	_add_button(actions, "清除模拟缓存", _clear_mock_cache)
	_add_button(actions, "清除真实 API 缓存", _clear_live_cache)
	_add_button(actions, "真实 API：手动请求", _request_live)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_status_label)
	_request_info_label = Label.new()
	_request_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_request_info_label)
	_summary_label = Label.new()
	_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_summary_label)

	var forecast_scroll := ScrollContainer.new()
	forecast_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	forecast_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(forecast_scroll)
	_forecast_text = RichTextLabel.new()
	_forecast_text.bbcode_enabled = false
	_forecast_text.fit_content = true
	_forecast_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_forecast_text.custom_minimum_size.x = 880
	forecast_scroll.add_child(_forecast_text)

	var attribution := Label.new()
	attribution.text = "数据来源：MET Norway · CC BY 4.0 / NLOD 2.0 · https://api.met.no/doc/TermsOfService"
	attribution.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(attribution)


func _configure_provider(adapter: Object, contact: String, use_mock_cache: bool = false) -> void:
	if _provider != null and _request_in_flight:
		return
	_provider = PROVIDER_SCRIPT.new() as WeatherDataProvider
	var active_cache := _mock_cache_store if use_mock_cache else _live_cache_store
	_provider.configure([REGION], adapter, active_cache, CLOCK_SCRIPT.new(), SCHEDULER_SCRIPT.new(self), contact)
	_provider.max_retries = 0


func _add_button(parent: Node, text: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 38
	button.pressed.connect(callback)
	parent.add_child(button)


func _save_contact() -> void:
	var saved: Dictionary = SETTINGS_SCRIPT.save_contact(_contact_input.text)
	if bool(saved.get("ok", false)):
		_configure_provider(_http_adapter, _contact_input.text)
		_set_status("已保存到本机 user://weather_data/provider_settings.json。环境变量 MET_NORWAY_CONTACT 优先级更高。", Color(0.63, 0.82, 0.76))
	else:
		_set_status("本地配置未保存：%s" % str(saved.get("error", "unknown")), Color(1.0, 0.55, 0.45))


func _reload_contact() -> void:
	_contact_input.text = SETTINGS_SCRIPT.load_contact()
	_configure_provider(_http_adapter, _contact_input.text)
	_set_status("已从环境变量或本机配置重载联系信息。", Color(0.63, 0.82, 0.76))


func _read_cache() -> void:
	_configure_provider(_http_adapter, _contact_input.text)
	_show_result(_provider.read_forecast(REGION.region_id))


func _read_mock_cache() -> void:
	_configure_provider(_mock_transport, MOCK_CONTACT, true)
	_show_result(_provider.read_forecast(REGION.region_id))


func _load_fixture() -> void:
	var result := _provider.parse_response_for_region(REGION.region_id, _parse_fixture(), {"http_status_code": 200, "fixture": true})
	if bool(result.get("ok", false)):
		_show_result({"status": "offline_fixture", "has_data": true, "data": result["data"], "cache_hit": false, "refresh_due": false})
	else:
		_set_status("离线 Fixture 解析失败：%s" % str(result.get("error", "unknown")), Color(1.0, 0.55, 0.45))


func _simulate_fixture_response() -> void:
	_mock_transport.mode = "fixture"
	_run_mock_request("模拟 Fixture HTTP 200")


func _simulate_not_modified() -> void:
	_mock_transport.mode = "not_modified"
	_run_mock_request("模拟 HTTP 304")


func _simulate_offline() -> void:
	_mock_transport.mode = "offline"
	_run_mock_request("模拟断网")


func _simulate_timeout() -> void:
	_mock_transport.mode = "timeout"
	_run_mock_request("模拟网络超时")


func _simulate_invalid_json() -> void:
	_mock_transport.mode = "invalid_json"
	_run_mock_request("模拟损坏响应")


func _run_mock_request(label: String) -> void:
	if _request_in_flight:
		_set_status("已有请求正在完成，请稍候。", Color(0.92, 0.78, 0.48))
		return
	_configure_provider(_mock_transport, MOCK_CONTACT, true)
	_expire_mock_cache_for_test()
	_request_in_flight = true
	_set_status("%s：本次仅使用内存模拟传输，不会访问网络。" % label, Color(0.92, 0.78, 0.48))
	var response: Dictionary = _provider.refresh_region(REGION.region_id, _on_refresh_completed)
	_request_info_label.text = "请求状态：%s · 模拟请求次数：%d" % [str(response.get("status", "")), _mock_transport.request_count]


func _request_live() -> void:
	if _request_in_flight:
		_set_status("已有请求正在完成，请稍候。", Color(0.92, 0.78, 0.48))
		return
	_configure_provider(_http_adapter, _contact_input.text)
	_request_in_flight = true
	_set_status("正在手动发起一次真实 API 请求。在线结果只进入本地缓存预览，不接入正式天气。", Color(0.95, 0.78, 0.40))
	var response: Dictionary = _provider.refresh_region(REGION.region_id, _on_refresh_completed)
	_request_info_label.text = "请求状态：%s · URL：%s" % [str(response.get("status", "")), str(response.get("request_url", "未启动"))]
	if str(response.get("status", "")) != "request_started":
		_request_in_flight = false
		_show_result(response)


func _on_refresh_completed(result: Dictionary) -> void:
	_request_in_flight = false
	_show_result(result)


func _corrupt_cache() -> void:
	_configure_provider(_mock_transport, MOCK_CONTACT, true)
	var success: bool = _mock_cache_store.write_corrupt_for_test(REGION.region_id)
	_provider.clear_memory_cache(REGION.region_id)
	_set_status("模拟缓存已写入损坏 JSON。点击“读取模拟缓存”查看恢复提示；真实 API 缓存不会受影响。" if success else "无法写入模拟缓存文件。", Color(0.92, 0.78, 0.48) if success else Color(1.0, 0.55, 0.45))


func _clear_mock_cache() -> void:
	_configure_provider(_mock_transport, MOCK_CONTACT, true)
	_provider.clear_memory_cache(REGION.region_id)
	_mock_cache_store.remove_region(REGION.region_id)
	_set_status("已清除模拟缓存。", Color(0.63, 0.82, 0.76))
	_show_result(_provider.read_forecast(REGION.region_id))


func _clear_live_cache() -> void:
	_configure_provider(_http_adapter, _contact_input.text)
	_provider.clear_memory_cache(REGION.region_id)
	_live_cache_store.remove_region(REGION.region_id)
	_set_status("已清除真实 API 缓存。", Color(0.63, 0.82, 0.76))
	_show_result(_provider.read_forecast(REGION.region_id))


func _expire_mock_cache_for_test() -> void:
	var loaded: Dictionary = _mock_cache_store.load_envelope(REGION.region_id)
	if not bool(loaded.get("ok", false)):
		return
	var envelope: Dictionary = loaded["envelope"].duplicate(true)
	envelope["expires_at_unix"] = int(CLOCK_SCRIPT.new().now_unix_seconds()) - 1
	_mock_cache_store.save_envelope(REGION.region_id, envelope)


func _show_result(result: Dictionary) -> void:
	var status := str(result.get("status", "unavailable"))
	var color := Color(0.63, 0.82, 0.76) if bool(result.get("has_data", false)) else Color(1.0, 0.55, 0.45)
	if status == "configuration_required":
		color = Color(0.92, 0.78, 0.48)
	_set_status("数据状态：%s · 来源：%s · 陈旧数据：%s · 刷新到期：%s · 错误：%s" % [status, str(result.get("cache_source", "fixture/network/none")), str(result.get("stale", false)), str(result.get("refresh_due", false)), str(result.get("error", "无"))], color)
	var document: Dictionary = result.get("data", {})
	if document.is_empty():
		_summary_label.text = "当前没有可用预报。缓存诊断：%s" % JSON.stringify(_provider.get_cache_diagnostic(REGION.region_id))
		_forecast_text.text = ""
		return
	var series: Array = document.get("timeseries", [])
	var current: Dictionary = series[0] if not series.is_empty() else {}
	var cloud_text := "%.0f" % (float(current.get("cloud_fraction", 0.0)) * 100.0) if current.has("cloud_fraction") else "缺失"
	_summary_label.text = "region=%s · 位置 %.4f, %.4f · 发布 %s · 获取 %s\n当前样本：温度 %s°C · 湿度 %s%% · 气压 %s hPa · 风速 %s m/s · 气象来向 %s° · 阵风 %s m/s · 云量 %s%%" % [str(document.get("region_id", "")), float(document.get("latitude", 0.0)), float(document.get("longitude", 0.0)), str(document.get("forecast_issued_at_utc", "")), str(document.get("retrieved_at_utc", "")), str(current.get("air_temperature_c", "缺失")), str(current.get("relative_humidity_percent", "缺失")), str(current.get("air_pressure_hpa", "缺失")), str(current.get("wind_speed_mps", "缺失")), str(current.get("wind_from_direction_deg", "缺失")), str(current.get("wind_gust_mps", "缺失")), cloud_text]
	var lines := PackedStringArray(["UTC 时间 | 风速 m/s | 来向 ° | 阵风 m/s | 云量 % | 降水时间窗"])
	for sample_value in series.slice(0, mini(48, series.size())):
		var sample: Dictionary = sample_value
		var precip_text := "无"
		if sample.has("precipitation_periods"):
			var descriptions: PackedStringArray = []
			for period_value in sample["precipitation_periods"]:
				var period: Dictionary = period_value
				var probability := "%.0f" % (float(period.get("precipitation_probability", 0.0)) * 100.0) if period.has("precipitation_probability") else "缺失"
				var amount := "%.1fmm" % float(period["precipitation_amount_mm"]) if period.has("precipitation_amount_mm") else "缺失 mm"
				descriptions.append("%dh %s/概率%s%% [%s → %s]" % [int(period["duration_hours"]), amount, probability, str(period["period_start_utc"]), str(period["period_end_utc"])])
			precip_text = "; ".join(descriptions)
		var sample_cloud := "%.0f" % (float(sample.get("cloud_fraction", 0.0)) * 100.0) if sample.has("cloud_fraction") else "—"
		lines.append("%s | %s | %s | %s | %s | %s" % [str(sample.get("valid_time_utc", "")), str(sample.get("wind_speed_mps", "—")), str(sample.get("wind_from_direction_deg", "—")), str(sample.get("wind_gust_mps", "—")), sample_cloud, precip_text])
	_forecast_text.text = "\n".join(lines)


func _set_status(message: String, color: Color) -> void:
	if _status_label == null:
		return
	_status_label.text = message
	_status_label.add_theme_color_override("font_color", color)


func _parse_fixture() -> Dictionary:
	var parser := JSON.new()
	if parser.parse(FileAccess.get_file_as_string(FIXTURE_PATH)) != OK or not parser.data is Dictionary:
		return {}
	return parser.data
