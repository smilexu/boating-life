extends CanvasLayer

## Non-pausing ESC menu. It blocks manual vessel input while leaving world time,
## waves, weather, and autopilot running as they were.

@export_node_path("Node3D") var boat_controller_path := NodePath("../PlayerBoat/MotionRoot")
@export_node_path("Node3D") var camera_rig_path := NodePath("../PlayerBoat/FollowCameraRig")
@export_node_path("Node") var music_manager_path := NodePath("../../MusicManager")
@export_node_path("Node") var environment_audio_manager_path := NodePath("../EnvironmentAudioManager")
@export_node_path("Node") var boat_audio_controller_path := NodePath("../BoatAudioController")
@export_node_path("Node") var quality_manager_path := NodePath("../QualityManager")
@export_node_path("Node") var fish_map_path := NodePath("../FishResourceMap")
@export_node_path("Node") var malmo_port_services_path := NodePath("../MalmoHarbor/PortServiceController")
@export_node_path("Node") var copenhagen_port_services_path := NodePath("../CopenhagenHarbor/PortServiceController")

const MENU_LAYER := 100
const GRAPHICS_SETTINGS_PAGE_SCRIPT := preload("res://scripts/graphics_settings_page.gd")
const SETTINGS_SCROLL_WHEEL_STEP := 96

var _boat: Node3D
var _camera_rig: Node3D
var _music_manager: Node
var _environment_audio_manager: Node
var _boat_audio_controller: Node
var _quality_manager: Node
var _localization_manager: Node
var _fish_map: Node
var _port_services: Array[Node] = []
var _background: ColorRect
var _panel: PanelContainer
var _main_page: VBoxContainer
var _settings_page: VBoxContainer
var _graphics_page: VBoxContainer
var _menu_title: Label
var _menu_subtitle: Label
var _settings_title: Label
var _playlist_hint: Label
var _music_toggle: CheckButton
var _language_option: OptionButton
var _ui_scale_option: OptionButton
var _navigation_detail_option: OptionButton
var _graphics_settings_button: Button
var _back_button: Button
var _mix_sliders: Dictionary = {}
var _menu_open := false
var _settings_open := false
var _graphics_open := false


func _ready() -> void:
	layer = MENU_LAYER
	_boat = get_node_or_null(boat_controller_path) as Node3D
	_camera_rig = get_node_or_null(camera_rig_path) as Node3D
	_music_manager = get_node_or_null(music_manager_path)
	_environment_audio_manager = get_node_or_null(environment_audio_manager_path)
	_boat_audio_controller = get_node_or_null(boat_audio_controller_path)
	_quality_manager = get_node_or_null(quality_manager_path)
	_localization_manager = get_node_or_null("/root/LocalizationManager")
	_fish_map = get_node_or_null(fish_map_path)
	var malmo_services := get_node_or_null(malmo_port_services_path)
	var copenhagen_services := get_node_or_null(copenhagen_port_services_path)
	if malmo_services != null:
		_port_services.append(malmo_services)
	if copenhagen_services != null:
		_port_services.append(copenhagen_services)
	_build_ui()
	if _localization_manager != null and _localization_manager.has_signal("locale_changed"):
		_localization_manager.connect("locale_changed", _on_locale_changed)
	get_viewport().size_changed.connect(_update_panel_layout)
	if _quality_manager != null and _quality_manager.has_signal("settings_changed"):
		_quality_manager.connect("settings_changed", _sync_interface_settings)
	_update_panel_layout()
	_refresh_localized_text()
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
		if _graphics_open:
			_graphics_page.call("_cancel_draft")
		else:
			_show_main_page()
	else:
		_close_menu()
	get_viewport().set_input_as_handled()


func _input(event: InputEvent) -> void:
	if not is_settings_open() or _graphics_open:
		return
	var settings_scroll := _settings_page.get_node_or_null("SettingsScroll") as ScrollContainer
	if settings_scroll == null or not settings_scroll.get_global_rect().has_point(get_viewport().get_mouse_position()):
		return
	var scroll_delta := 0.0
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			scroll_delta = -SETTINGS_SCROLL_WHEEL_STEP
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			scroll_delta = SETTINGS_SCROLL_WHEEL_STEP
	elif event is InputEventPanGesture:
		scroll_delta = -event.delta.y
	if is_zero_approx(scroll_delta):
		return
	# Handle scrolling before child controls consume the wheel (for example, an OptionButton).
	settings_scroll.scroll_vertical += roundi(scroll_delta)
	get_viewport().set_input_as_handled()


func _open_menu() -> void:
	_menu_open = true
	_settings_open = false
	_graphics_open = false
	visible = true
	_main_page.visible = true
	_settings_page.visible = false
	_graphics_page.visible = false
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
	_graphics_open = false
	visible = false
	_set_manual_input_enabled(true)
	get_viewport().gui_release_focus()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _show_main_page() -> void:
	_settings_open = false
	_graphics_open = false
	_main_page.visible = true
	_settings_page.visible = false
	_graphics_page.visible = false
	var settings_button := _main_page.get_node_or_null("SettingsButton") as Button
	if settings_button != null:
		settings_button.grab_focus()


func _show_settings_page() -> void:
	_settings_open = true
	_graphics_open = false
	_main_page.visible = false
	_settings_page.visible = true
	_graphics_page.visible = false
	if _music_manager != null and _music_manager.has_method("is_music_enabled"):
		_music_toggle.set_pressed_no_signal(bool(_music_manager.call("is_music_enabled")))
	_refresh_mix_sliders()
	_sync_interface_settings()
	_music_toggle.grab_focus()


func _show_graphics_page() -> void:
	_settings_open = true
	_graphics_open = true
	_main_page.visible = false
	_settings_page.visible = false
	_graphics_page.visible = true
	_graphics_page.call("open_page")


func _return_from_graphics_page() -> void:
	_show_settings_page()


func _has_existing_overlay_open() -> bool:
	if is_instance_valid(_fish_map) and _fish_map.has_method("is_map_open") and bool(_fish_map.call("is_map_open")):
		return true
	for services in _port_services:
		if is_instance_valid(services) and services.has_method("is_menu_open") and bool(services.call("is_menu_open")):
			return true
	return false


func _set_manual_input_enabled(enabled: bool) -> void:
	if is_instance_valid(_boat):
		if _boat.has_method("set_sailing_manual_controls_enabled"):
			_boat.call("set_sailing_manual_controls_enabled", enabled)
		else:
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
	title.name = "GameTitle"
	_menu_title = title
	title.text = tr("menu.game_title")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color("#e5efea"))
	pages.add_child(title)
	var subtitle := Label.new()
	subtitle.name = "GameSubtitle"
	_menu_subtitle = subtitle
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
	_add_button(_main_page, tr("menu.continue"), "ContinueButton", _close_menu)
	_add_button(_main_page, tr("menu.settings"), "SettingsButton", _show_settings_page)
	_add_button(_main_page, tr("menu.quit"), "ExitButton", func() -> void: get_tree().quit())
	_add_page_spacer(_main_page)

	_settings_page = VBoxContainer.new()
	_settings_page.name = "SettingsPage"
	_settings_page.add_theme_constant_override("separation", 14)
	_settings_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_settings_page.visible = false
	pages.add_child(_settings_page)
	var settings_title := Label.new()
	settings_title.name = "SettingsTitle"
	_settings_title = settings_title
	settings_title.text = tr("menu.settings")
	settings_title.add_theme_font_size_override("font_size", 24)
	settings_title.add_theme_color_override("font_color", Color("#e5efea"))
	_settings_page.add_child(settings_title)
	var settings_scroll := ScrollContainer.new()
	settings_scroll.name = "SettingsScroll"
	settings_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	settings_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_settings_page.add_child(settings_scroll)
	var settings_controls := VBoxContainer.new()
	settings_controls.name = "SettingsControls"
	settings_controls.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	settings_controls.add_theme_constant_override("separation", 10)
	settings_scroll.add_child(settings_controls)
	_music_toggle = CheckButton.new()
	_music_toggle.name = "MusicEnabledToggle"
	_music_toggle.text = tr("menu.music")
	_music_toggle.add_theme_font_size_override("font_size", 19)
	_music_toggle.toggled.connect(_on_music_toggled)
	settings_controls.add_child(_music_toggle)
	var playlist_hint := Label.new()
	playlist_hint.name = "PlaylistHint"
	_playlist_hint = playlist_hint
	playlist_hint.text = tr("menu.music_hint")
	playlist_hint.add_theme_font_size_override("font_size", 14)
	playlist_hint.add_theme_color_override("font_color", Color("#9db9b8"))
	settings_controls.add_child(playlist_hint)
	var language_options: Array[String] = []
	if _localization_manager != null and _localization_manager.has_method("get_locale_labels"):
		for language_label in _localization_manager.call("get_locale_labels"):
			language_options.append(str(language_label))
	else:
		language_options = ["简体中文", "English"]
	_language_option = _add_settings_option_row(settings_controls, tr("menu.language"), language_options)
	_language_option.name = "LanguageOption"
	_language_option.item_selected.connect(_on_language_selected)
	_ui_scale_option = _add_settings_option_row(settings_controls, tr("menu.ui_scale"), ["Small · 90%", "Standard · 100%", "Large · 125%", "Extra large · 150%", "Maximum · 175%"])
	_ui_scale_option.name = "UIScaleOption"
	_ui_scale_option.item_selected.connect(_on_ui_scale_selected)
	_navigation_detail_option = _add_settings_option_row(settings_controls, tr("menu.navigation_detail"), ["Compact", "Detailed"])
	_navigation_detail_option.name = "NavigationDetailOption"
	_navigation_detail_option.item_selected.connect(_on_navigation_detail_selected)
	_graphics_settings_button = _add_button(settings_controls, tr("menu.graphics"), "GraphicsSettingsButton", _show_graphics_page)
	_add_volume_slider(settings_controls, tr("menu.weather_audio"), "weather", 68.0)
	_add_volume_slider(settings_controls, tr("menu.ocean_audio"), "ocean", 72.0)
	_add_volume_slider(settings_controls, tr("menu.engine_audio"), "engine", 62.0)
	_back_button = _add_button(_settings_page, tr("menu.back"), "BackButton", _show_main_page)

	_graphics_page = GRAPHICS_SETTINGS_PAGE_SCRIPT.new() as VBoxContainer
	_graphics_page.visible = false
	pages.add_child(_graphics_page)
	_graphics_page.call("setup", _quality_manager)
	_graphics_page.connect("back_requested", _return_from_graphics_page)
	_refresh_localized_text()


func _on_locale_changed(_locale_id: String) -> void:
	_refresh_localized_text()
	_sync_interface_settings()
	if _graphics_page != null and _graphics_page.has_method("refresh_localized_text"):
		_graphics_page.call("refresh_localized_text")
	_update_panel_layout()


func _refresh_localized_text() -> void:
	if _menu_title != null:
		_menu_title.text = tr("menu.game_title")
	if _menu_subtitle != null:
		_menu_subtitle.text = tr("menu.game_subtitle")
	if _settings_title != null:
		_settings_title.text = tr("menu.settings")
	if _music_toggle != null:
		_music_toggle.text = tr("menu.music")
	if _playlist_hint != null:
		_playlist_hint.text = tr("menu.music_hint")
	if _main_page != null:
		(_main_page.get_node("ContinueButton") as Button).text = tr("menu.continue")
		(_main_page.get_node("SettingsButton") as Button).text = tr("menu.settings")
		(_main_page.get_node("ExitButton") as Button).text = tr("menu.quit")
	if _settings_page != null:
		var language_label := _language_option.get_parent().get_child(0) as Label if _language_option != null else null
		if language_label != null:
			language_label.text = tr("menu.language")
		var scale_label := _ui_scale_option.get_parent().get_child(0) as Label if _ui_scale_option != null else null
		if scale_label != null:
			scale_label.text = tr("menu.ui_scale")
		var detail_label := _navigation_detail_option.get_parent().get_child(0) as Label if _navigation_detail_option != null else null
		if detail_label != null:
			detail_label.text = tr("menu.navigation_detail")
		if _ui_scale_option != null:
			var scales := ["menu.scale.small", "menu.scale.standard", "menu.scale.large", "menu.scale.extra_large", "menu.scale.maximum"]
			for index in range(mini(scales.size(), _ui_scale_option.item_count)):
				_ui_scale_option.set_item_text(index, tr(scales[index]))
		if _navigation_detail_option != null:
			_navigation_detail_option.set_item_text(0, tr("menu.detail.compact"))
			_navigation_detail_option.set_item_text(1, tr("menu.detail.detailed"))
		if _graphics_settings_button != null:
			_graphics_settings_button.text = tr("menu.graphics")
		if _back_button != null:
			_back_button.text = tr("menu.back")
		for channel in ["weather", "ocean", "engine"]:
			var key := "menu.weather_audio" if channel == "weather" else "menu.ocean_audio" if channel == "ocean" else "menu.engine_audio"
			var label := get_node_or_null("GameMenuRoot/GameMenuPanel/SettingsPage/SettingsScroll/SettingsControls/%sVolumeControl/LabelRow" % channel.capitalize())
			if label != null and label.get_child_count() > 0:
				(label.get_child(0) as Label).text = tr(key)
	if _graphics_page != null and _graphics_page.has_method("refresh_localized_text"):
		_graphics_page.call("refresh_localized_text")


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


func _add_settings_option_row(parent: VBoxContainer, label_text: String, options: Array[String]) -> OptionButton:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = 130.0
	label.add_theme_font_size_override("font_size", 16)
	row.add_child(label)
	var option := OptionButton.new()
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	option.custom_minimum_size.y = 42.0
	for item in options:
		option.add_item(item)
	row.add_child(option)
	parent.add_child(row)
	return option


func _sync_interface_settings() -> void:
	if _language_option != null:
		if _localization_manager != null and _localization_manager.has_method("get_locale_index"):
			_language_option.disabled = false
			_language_option.select(int(_localization_manager.call("get_locale_index")))
		else:
			_language_option.disabled = true
	if _quality_manager == null:
		if _ui_scale_option != null:
			_ui_scale_option.disabled = true
		if _navigation_detail_option != null:
			_navigation_detail_option.disabled = true
		return
	if _ui_scale_option != null and _quality_manager.has_method("get_ui_scale_index"):
		_ui_scale_option.select(int(_quality_manager.call("get_ui_scale_index")))
	if _navigation_detail_option != null and _quality_manager.has_method("get_navigation_detail_enabled"):
		_navigation_detail_option.select(1 if bool(_quality_manager.call("get_navigation_detail_enabled")) else 0)
	_update_panel_layout()


func _update_panel_layout() -> void:
	if _panel == null or not is_inside_tree():
		return
	var viewport_size := get_viewport().get_visible_rect().size
	var ui_scale := float(_quality_manager.call("get_ui_scale_factor")) if _quality_manager != null and _quality_manager.has_method("get_ui_scale_factor") else 1.0
	var width := minf(520.0, maxf(300.0, (viewport_size.x - 32.0) / ui_scale))
	var height := minf(680.0, maxf(360.0, (viewport_size.y - 32.0) / ui_scale))
	_panel.custom_minimum_size = Vector2(width, height)
	_panel.offset_left = -width * 0.5
	_panel.offset_right = width * 0.5
	_panel.offset_top = -height * 0.5
	_panel.offset_bottom = height * 0.5


func _on_ui_scale_selected(index: int) -> void:
	if _quality_manager != null and _quality_manager.has_method("set_ui_scale_index"):
		_quality_manager.call("set_ui_scale_index", index)


func _on_language_selected(index: int) -> void:
	if _localization_manager != null and _localization_manager.has_method("set_locale_index"):
		_localization_manager.call("set_locale_index", index)


func _on_navigation_detail_selected(index: int) -> void:
	if _quality_manager != null and _quality_manager.has_method("set_navigation_detail_enabled"):
		_quality_manager.call("set_navigation_detail_enabled", index == 1)


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
