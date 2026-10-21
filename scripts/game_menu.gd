extends CanvasLayer

## Non-pausing ESC menu. It blocks manual vessel input while leaving world time,
## waves, weather, and autopilot running as they were.

@export_node_path("Node3D") var boat_controller_path := NodePath("../PlayerBoat/MotionRoot")
@export_node_path("Node3D") var camera_rig_path := NodePath("../PlayerBoat/FollowCameraRig")
@export_node_path("Node") var music_manager_path := NodePath("../../MusicManager")
@export_node_path("Node") var environment_audio_manager_path := NodePath("../EnvironmentAudioManager")
@export_node_path("Node") var boat_audio_controller_path := NodePath("../BoatAudioController")
@export_node_path("Node") var fish_map_path := NodePath("../FishResourceMap")
@export_node_path("Node") var malmo_port_services_path := NodePath("../MalmoHarbor/PortServiceController")
@export_node_path("Node") var copenhagen_port_services_path := NodePath("../CopenhagenHarbor/PortServiceController")

const MENU_LAYER := 100

var _boat: Node3D
var _camera_rig: Node3D
var _music_manager: Node
var _environment_audio_manager: Node
var _boat_audio_controller: Node
var _fish_map: Node
var _port_services: Array[Node] = []
var _background: ColorRect
var _panel: PanelContainer
var _main_page: VBoxContainer
var _settings_page: VBoxContainer
var _music_toggle: CheckButton
var _mix_sliders: Dictionary = {}
var _menu_open := false
var _settings_open := false


func _ready() -> void:
	layer = MENU_LAYER
	_boat = get_node_or_null(boat_controller_path) as Node3D
	_camera_rig = get_node_or_null(camera_rig_path) as Node3D
	_music_manager = get_node_or_null(music_manager_path)
	_environment_audio_manager = get_node_or_null(environment_audio_manager_path)
	_boat_audio_controller = get_node_or_null(boat_audio_controller_path)
	_fish_map = get_node_or_null(fish_map_path)
	var malmo_services := get_node_or_null(malmo_port_services_path)
	var copenhagen_services := get_node_or_null(copenhagen_port_services_path)
	if malmo_services != null:
		_port_services.append(malmo_services)
	if copenhagen_services != null:
		_port_services.append(copenhagen_services)
	_build_ui()
	visible = false


func is_menu_open() -> bool:
	return _menu_open


func is_settings_open() -> bool:
	return _menu_open and _settings_open


func _unhandled_key_input(event: InputEvent) -> void:
	if event is not InputEventKey or not event.pressed or event.echo:
		return
	if event.physical_keycode != KEY_ESCAPE and event.keycode != KEY_ESCAPE:
		return
	if _has_existing_overlay_open():
		return
	if not _menu_open:
		_open_menu()
	elif _settings_open:
		_show_main_page()
	else:
		_close_menu()
	get_viewport().set_input_as_handled()


func _open_menu() -> void:
	_menu_open = true
	_settings_open = false
	visible = true
	_main_page.visible = true
	_settings_page.visible = false
	_set_manual_input_enabled(false)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	if _camera_rig != null and _camera_rig.has_method("release_mouse_look"):
		_camera_rig.call("release_mouse_look")
	var continue_button := _main_page.get_node_or_null("ContinueButton") as Button
	if continue_button != null:
		continue_button.grab_focus()


func _close_menu() -> void:
	_menu_open = false
	_settings_open = false
	visible = false
	_set_manual_input_enabled(true)
	get_viewport().gui_release_focus()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _show_main_page() -> void:
	_settings_open = false
	_main_page.visible = true
	_settings_page.visible = false
	var settings_button := _main_page.get_node_or_null("SettingsButton") as Button
	if settings_button != null:
		settings_button.grab_focus()


func _show_settings_page() -> void:
	_settings_open = true
	_main_page.visible = false
	_settings_page.visible = true
	if _music_manager != null and _music_manager.has_method("is_music_enabled"):
		_music_toggle.set_pressed_no_signal(bool(_music_manager.call("is_music_enabled")))
	_refresh_mix_sliders()
	_music_toggle.grab_focus()


func _has_existing_overlay_open() -> bool:
	if is_instance_valid(_fish_map) and _fish_map.has_method("is_map_open") and bool(_fish_map.call("is_map_open")):
		return true
	for services in _port_services:
		if is_instance_valid(services) and services.has_method("is_menu_open") and bool(services.call("is_menu_open")):
			return true
	return false


func _set_manual_input_enabled(enabled: bool) -> void:
	if is_instance_valid(_boat):
		_boat.set("manual_input_enabled", enabled)


func _on_music_toggled(enabled: bool) -> void:
	if is_instance_valid(_music_manager) and _music_manager.has_method("set_music_enabled"):
		_music_manager.call("set_music_enabled", enabled)


func _build_ui() -> void:
	var root := Control.new()
	root.name = "GameMenuRoot"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)

	_background = ColorRect.new()
	_background.name = "DimBackground"
	_background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_background.color = Color(0.012, 0.035, 0.047, 0.68)
	_background.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(_background)

	_panel = PanelContainer.new()
	_panel.name = "GameMenuPanel"
	_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_panel.offset_left = -235.0
	_panel.offset_top = -280.0
	_panel.offset_right = 235.0
	_panel.offset_bottom = 280.0
	_panel.custom_minimum_size = Vector2(470.0, 560.0)
	_panel.add_theme_stylebox_override("panel", _make_panel_style())
	root.add_child(_panel)

	var pages := VBoxContainer.new()
	pages.add_theme_constant_override("separation", 12)
	_panel.add_child(pages)

	var title := Label.new()
	title.text = "航海生活模拟器"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color("#e5efea"))
	pages.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "SEA PROTOTYPE  ·  ØRESUND"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 13)
	subtitle.add_theme_color_override("font_color", Color("#91b7b7"))
	pages.add_child(subtitle)

	_main_page = VBoxContainer.new()
	_main_page.name = "MainPage"
	_main_page.add_theme_constant_override("separation", 12)
	_main_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pages.add_child(_main_page)
	_add_page_spacer(_main_page)
	_add_button(_main_page, "继续游戏", "ContinueButton", _close_menu)
	_add_button(_main_page, "设置", "SettingsButton", _show_settings_page)
	_add_button(_main_page, "退出游戏", "ExitButton", func() -> void: get_tree().quit())
	_add_page_spacer(_main_page)

	_settings_page = VBoxContainer.new()
	_settings_page.name = "SettingsPage"
	_settings_page.add_theme_constant_override("separation", 14)
	_settings_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_settings_page.visible = false
	pages.add_child(_settings_page)
	_add_page_spacer(_settings_page)
	var settings_title := Label.new()
	settings_title.text = "设置"
	settings_title.add_theme_font_size_override("font_size", 24)
	settings_title.add_theme_color_override("font_color", Color("#e5efea"))
	_settings_page.add_child(settings_title)
	_music_toggle = CheckButton.new()
	_music_toggle.name = "MusicEnabledToggle"
	_music_toggle.text = "背景音乐"
	_music_toggle.add_theme_font_size_override("font_size", 19)
	_music_toggle.toggled.connect(_on_music_toggled)
	_settings_page.add_child(_music_toggle)
	var playlist_hint := Label.new()
	playlist_hint.text = "bgm1 与 bgm2 按顺序播放"
	playlist_hint.add_theme_font_size_override("font_size", 14)
	playlist_hint.add_theme_color_override("font_color", Color("#9db9b8"))
	_settings_page.add_child(playlist_hint)
	_add_volume_slider(_settings_page, "天气音效", "weather", 68.0)
	_add_volume_slider(_settings_page, "海浪与船体音效", "ocean", 72.0)
	_add_volume_slider(_settings_page, "发动机音量", "engine", 62.0)
	_add_page_spacer(_settings_page)
	_add_button(_settings_page, "返回", "BackButton", _show_main_page)
	_add_page_spacer(_settings_page)


func _add_page_spacer(parent: VBoxContainer) -> void:
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(spacer)


func _add_button(parent: VBoxContainer, label: String, node_name: String, callback: Callable) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = label
	button.custom_minimum_size = Vector2(320.0, 46.0)
	button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	button.add_theme_font_size_override("font_size", 18)
	button.pressed.connect(callback)
	parent.add_child(button)
	return button


func _add_volume_slider(parent: VBoxContainer, label_text: String, channel: String, initial_value: float) -> void:
	var group := VBoxContainer.new()
	group.name = channel.capitalize() + "VolumeControl"
	group.add_theme_constant_override("separation", 4)
	parent.add_child(group)
	var row := HBoxContainer.new()
	row.name = "LabelRow"
	group.add_child(row)
	var label := Label.new()
	label.text = label_text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Color("#d8e5e0"))
	row.add_child(label)
	var value_label := Label.new()
	value_label.name = "PercentLabel"
	value_label.text = "%d%%" % roundi(initial_value)
	value_label.custom_minimum_size.x = 48.0
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.add_theme_font_size_override("font_size", 15)
	value_label.add_theme_color_override("font_color", Color("#91b7b7"))
	row.add_child(value_label)
	var slider := HSlider.new()
	slider.name = channel.capitalize() + "VolumeSlider"
	slider.min_value = 0.0
	slider.max_value = 100.0
	slider.step = 1.0
	slider.value = initial_value
	slider.custom_minimum_size = Vector2(340.0, 24.0)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(_on_mix_volume_changed.bind(channel, value_label))
	group.add_child(slider)
	_mix_sliders[channel] = slider


func _refresh_mix_sliders() -> void:
	var values := {
		"weather": _read_mix_volume(_environment_audio_manager, "get_weather_volume", 0.68),
		"ocean": _read_mix_volume(_environment_audio_manager, "get_ocean_volume", 0.72),
		"engine": _read_mix_volume(_boat_audio_controller, "get_engine_volume", 0.62),
	}
	for channel in values.keys():
		var slider := _mix_sliders.get(channel) as HSlider
		if slider != null:
			slider.set_value_no_signal(float(values[channel]) * 100.0)
			var value_label := slider.get_parent().get_node_or_null("LabelRow/PercentLabel") as Label
			if value_label != null:
				value_label.text = "%d%%" % roundi(slider.value)


func _read_mix_volume(manager: Node, method_name: String, fallback: float) -> float:
	if manager != null and manager.has_method(method_name):
		return clampf(float(manager.call(method_name)), 0.0, 1.0)
	return fallback


func _on_mix_volume_changed(value: float, channel: String, value_label: Label) -> void:
	value_label.text = "%d%%" % roundi(value)
	var normalized := clampf(value / 100.0, 0.0, 1.0)
	match channel:
		"weather":
			if _environment_audio_manager != null and _environment_audio_manager.has_method("set_weather_volume"):
				_environment_audio_manager.call("set_weather_volume", normalized)
		"ocean":
			if _environment_audio_manager != null and _environment_audio_manager.has_method("set_ocean_volume"):
				_environment_audio_manager.call("set_ocean_volume", normalized)
		"engine":
			if _boat_audio_controller != null and _boat_audio_controller.has_method("set_engine_volume"):
				_boat_audio_controller.call("set_engine_volume", normalized)


func _make_panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.025, 0.075, 0.092, 0.97)
	style.border_color = Color(0.25, 0.54, 0.58, 0.9)
	style.set_border_width_all(1)
	style.set_corner_radius_all(12)
	style.content_margin_left = 32.0
	style.content_margin_right = 32.0
	style.content_margin_top = 28.0
	style.content_margin_bottom = 28.0
	return style


func _exit_tree() -> void:
	if _menu_open:
		_set_manual_input_enabled(true)
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
