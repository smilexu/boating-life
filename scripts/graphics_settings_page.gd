extends VBoxContainer

signal back_requested

const PRESET_PERFORMANCE := 0
const PRESET_BALANCED := 1
const PRESET_HIGH := 2
const PRESET_ULTRA := 3
const PRESET_CUSTOM := 4

var _manager: Node
var _draft: Dictionary = {}
var _advanced_open := false
var _building_controls := false
var _extra_3d_scale_manually_edited := false
var _upscaler_manually_edited := false
var _status_label: Label
var _confirmation_bar: HBoxContainer
var _confirmation_label: Label
var _display_mode: OptionButton
var _vsync: CheckButton
var _frame_limit: OptionButton
var _render_resolution: OptionButton
var _resolution_info: Label
var _preset: OptionButton
var _shadows: CheckButton
var _ssr: CheckButton
var _ssao: CheckButton
var _cloud_quality: OptionButton
var _ocean_quality: OptionButton
var _shadow_distance: HSlider
var _vegetation_density: HSlider
var _advanced_button: Button
var _advanced_content: VBoxContainer
var _extra_scale: OptionButton
var _upscaler: OptionButton
var _sharpness: HSlider
var _advanced_info: Label
var _localized_controls: Dictionary = {}
var _localized_options: Dictionary = {}
var _status_key := ""
var _display_confirmation_seconds := 0


func setup(manager: Node) -> void:
	_manager = manager
	_build_page()
	if _manager != null and _manager.has_signal("display_confirmation_changed"):
		_manager.connect("display_confirmation_changed", _on_display_confirmation_changed)
	if _manager != null and _manager.has_signal("settings_changed"):
		_manager.connect("settings_changed", _on_manager_settings_changed)
	if get_viewport() != null:
		get_viewport().size_changed.connect(_update_resolution_info)
	_refresh_from_manager()


func open_page() -> void:
	_extra_3d_scale_manually_edited = false
	_upscaler_manually_edited = false
	_refresh_from_manager()
	if _display_mode != null:
		_display_mode.grab_focus()


func refresh_localized_text() -> void:
	for control_variant in _localized_controls.keys():
		var control := control_variant as Control
		if is_instance_valid(control):
			control.set("text", tr(str(_localized_controls[control_variant])))
	for option_variant in _localized_options.keys():
		var option := option_variant as OptionButton
		if not is_instance_valid(option):
			continue
		var keys: Array = _localized_options[option_variant]
		for index in range(mini(option.item_count, keys.size())):
			option.set_item_text(index, tr(str(keys[index])))
	if _advanced_button != null:
		_advanced_button.text = tr("menu.graphics.advanced_open" if _advanced_open else "menu.graphics.advanced_closed")
	_update_resolution_info()
	_update_advanced_info()
	if _status_label != null and not _status_key.is_empty():
		_status_label.text = tr(_status_key)
	if _confirmation_label != null and _confirmation_bar.visible:
		_confirmation_label.text = tr("menu.graphics.confirm_display") % _display_confirmation_seconds


func _build_page() -> void:
	name = "GraphicsSettingsPage"
	add_theme_constant_override("separation", 8)
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	var header := HBoxContainer.new()
	add_child(header)
	var title := Label.new()
	_localize_control(title, "menu.graphics")
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color("#e5efea"))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var back := Button.new()
	_localize_control(back, "menu.back")
	back.pressed.connect(_cancel_draft)
	header.add_child(back)

	var scroll := ScrollContainer.new()
	scroll.name = "GraphicsSettingsScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 8)
	scroll.add_child(content)

	_add_section_title(content, "menu.graphics.display")
	_display_mode = _add_option_row(content, "menu.graphics.display_mode", ["menu.graphics.windowed", "menu.graphics.borderless", "menu.graphics.fullscreen"])
	_display_mode.item_selected.connect(_on_display_mode_selected)
	_vsync = CheckButton.new()
	_localize_control(_vsync, "menu.graphics.vsync")
	_vsync.toggled.connect(_on_vsync_toggled)
	content.add_child(_vsync)
	_frame_limit = _add_option_row(content, "menu.graphics.frame_limit", ["menu.graphics.fps_30", "menu.graphics.fps_60", "menu.graphics.unlimited"])
	_frame_limit.item_selected.connect(_on_frame_limit_selected)

	_add_section_title(content, "menu.graphics.render_resolution")
	_render_resolution = _add_option_row(content, "menu.graphics.overall_scale", ["menu.graphics.resolution.native", "menu.graphics.resolution.high", "menu.graphics.resolution.balanced", "menu.graphics.resolution.performance", "menu.graphics.resolution.ultra_performance"])
	_render_resolution.item_selected.connect(_on_render_resolution_selected)
	_resolution_info = _make_info_label()
	content.add_child(_resolution_info)

	_add_section_title(content, "menu.graphics.quality")
	_preset = _add_option_row(content, "menu.graphics.preset", ["menu.graphics.preset.performance", "menu.graphics.preset.balanced", "menu.graphics.preset.high", "menu.graphics.preset.ultra", "menu.graphics.preset.custom"])
	_preset.item_selected.connect(_on_preset_selected)
	_shadows = _add_check(content, "menu.graphics.directional_shadows", "shadows_enabled")
	_ssr = _add_check(content, "menu.graphics.ssr", "ssr_enabled")
	_ssao = _add_check(content, "menu.graphics.ssao", "ssao_enabled")
	_cloud_quality = _add_option_row(content, "menu.graphics.cloud_quality", ["menu.graphics.preset.performance", "menu.graphics.preset.balanced", "menu.graphics.preset.high"])
	_cloud_quality.item_selected.connect(_on_cloud_quality_selected)
	_ocean_quality = _add_option_row(content, "menu.graphics.ocean_quality", ["menu.graphics.preset.performance", "menu.graphics.preset.balanced", "menu.graphics.preset.high"])
	_ocean_quality.item_selected.connect(_on_ocean_quality_selected)
	_shadow_distance = _add_slider_row(content, "menu.graphics.shadow_distance", 40.0, 1000.0, 10.0)
	_shadow_distance.value_changed.connect(_on_shadow_distance_changed)
	_vegetation_density = _add_slider_row(content, "menu.graphics.vegetation_density", 0.0, 1.5, 0.05)
	_vegetation_density.value_changed.connect(_on_vegetation_density_changed)

	_advanced_button = Button.new()
	_localize_control(_advanced_button, "menu.graphics.advanced_closed")
	_advanced_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_advanced_button.pressed.connect(_toggle_advanced)
	content.add_child(_advanced_button)
	_advanced_content = VBoxContainer.new()
	_advanced_content.add_theme_constant_override("separation", 8)
	_advanced_content.visible = false
	content.add_child(_advanced_content)
	_extra_scale = _add_option_row(_advanced_content, "menu.graphics.extra_3d_scale", ["menu.graphics.scale.100", "menu.graphics.scale.85", "menu.graphics.scale.75", "menu.graphics.scale.67", "menu.graphics.scale.55", "menu.graphics.scale.50"])
	_extra_scale.item_selected.connect(_on_extra_scale_selected)
	_upscaler = _add_option_row(_advanced_content, "menu.graphics.upscaling", ["menu.graphics.upscaling.auto", "menu.graphics.upscaling.fsr2", "menu.graphics.upscaling.fsr1", "menu.graphics.upscaling.bilinear"])
	_upscaler.item_selected.connect(_on_upscaler_selected)
	_sharpness = _add_slider_row(_advanced_content, "menu.graphics.sharpness", 0.0, 2.0, 0.05)
	_sharpness.value_changed.connect(_on_sharpness_changed)
	_advanced_info = _make_info_label()
	_advanced_content.add_child(_advanced_info)

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 8)
	add_child(footer)
	var apply_button := Button.new()
	_localize_control(apply_button, "menu.apply")
	apply_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	apply_button.pressed.connect(_apply_draft)
	footer.add_child(apply_button)
	var defaults_button := Button.new()
	_localize_control(defaults_button, "menu.graphics.restore_defaults")
	defaults_button.pressed.connect(_restore_defaults)
	footer.add_child(defaults_button)
	var cancel_button := Button.new()
	_localize_control(cancel_button, "menu.cancel")
	cancel_button.pressed.connect(_cancel_draft)
	footer.add_child(cancel_button)

	_confirmation_bar = HBoxContainer.new()
	_confirmation_bar.name = "DisplayConfirmation"
	_confirmation_bar.visible = false
	add_child(_confirmation_bar)
	_confirmation_label = Label.new()
	_confirmation_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_confirmation_bar.add_child(_confirmation_label)
	var keep_button := Button.new()
	_localize_control(keep_button, "menu.graphics.keep")
	keep_button.pressed.connect(_keep_display_settings)
	_confirmation_bar.add_child(keep_button)
	var revert_button := Button.new()
	_localize_control(revert_button, "menu.graphics.revert")
	revert_button.pressed.connect(_revert_display_settings)
	_confirmation_bar.add_child(revert_button)

	_status_label = _make_info_label()
	add_child(_status_label)


func _localize_control(control: Control, key: String) -> void:
	control.set("text", tr(key))
	_localized_controls[control] = key


func _add_section_title(parent: VBoxContainer, key: String) -> void:
	var label := Label.new()
	_localize_control(label, key)
	label.add_theme_font_size_override("font_size", 17)
	label.add_theme_color_override("font_color", Color("#91b7b7"))
	parent.add_child(label)


func _add_option_row(parent: VBoxContainer, title_key: String, option_keys: Array[String]) -> OptionButton:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var title := Label.new()
	_localize_control(title, title_key)
	title.custom_minimum_size.x = 142.0
	title.add_theme_color_override("font_color", Color("#d8e5e0"))
	row.add_child(title)
	var option := OptionButton.new()
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for key in option_keys:
		option.add_item(tr(key))
	_localized_options[option] = option_keys.duplicate()
	row.add_child(option)
	parent.add_child(row)
	return option


func _add_check(parent: VBoxContainer, text_key: String, setting_key: String) -> CheckButton:
	var check := CheckButton.new()
	_localize_control(check, text_key)
	check.toggled.connect(_on_visual_toggle.bind(setting_key))
	parent.add_child(check)
	return check


func _add_slider_row(parent: VBoxContainer, title_key: String, low: float, high: float, step_value: float) -> HSlider:
	var group := VBoxContainer.new()
	group.add_theme_constant_override("separation", 2)
	var label := Label.new()
	_localize_control(label, title_key)
	label.add_theme_color_override("font_color", Color("#d8e5e0"))
	group.add_child(label)
	var slider := HSlider.new()
	slider.min_value = low
	slider.max_value = high
	slider.step = step_value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	group.add_child(slider)
	parent.add_child(group)
	return slider


func _make_info_label() -> Label:
	var label := Label.new()
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color("#9db9b8"))
	return label


func _names(method_name: String, fallback: PackedStringArray) -> PackedStringArray:
	if _manager != null and _manager.has_method(method_name):
		var result: Variant = _manager.call(method_name)
		if result is PackedStringArray:
			return result
	return fallback


func _refresh_from_manager() -> void:
	if _manager == null or not _manager.has_method("get_graphics_settings"):
		return
	_draft = _manager.call("get_graphics_settings")
	_sync_controls()
	if _manager.has_method("is_display_confirmation_pending") and bool(_manager.call("is_display_confirmation_pending")):
		_on_display_confirmation_changed(true, int(_manager.call("get_display_confirmation_seconds_remaining")), "")
	else:
		_on_display_confirmation_changed(false, 0, "")


func _sync_controls() -> void:
	_building_controls = true
	_display_mode.select(int(_draft.get("display_mode", 0)))
	_vsync.set_pressed_no_signal(bool(_draft.get("vsync_enabled", true)))
	_frame_limit.select(int(_draft.get("frame_limit", 1)))
	_render_resolution.select(int(_draft.get("render_resolution", 0)))
	_preset.select(int(_draft.get("graphics_preset", PRESET_HIGH)))
	var values: Dictionary = _draft.get("visual_values", {})
	_shadows.set_pressed_no_signal(bool(values.get("shadows_enabled", true)))
	_ssr.set_pressed_no_signal(bool(values.get("ssr_enabled", true)))
	_ssao.set_pressed_no_signal(bool(values.get("ssao_enabled", true)))
	_cloud_quality.select(int(_manager.call("get_cloud_quality_index", values)) if _manager.has_method("get_cloud_quality_index") else 1)
	_ocean_quality.select(int(_manager.call("get_ocean_quality_index", values)) if _manager.has_method("get_ocean_quality_index") else 1)
	_shadow_distance.value = float(values.get("shadow_distance", 200.0))
	_vegetation_density.value = float(values.get("vegetation_density", 0.85))
	_extra_scale.select(_find_scale_index(float(_draft.get("extra_3d_scale", 1.0))))
	_upscaler.select(int(_draft.get("upscaler", 0)))
	_sharpness.value = float(_draft.get("fsr_sharpness", 0.2))
	_update_resolution_info()
	_update_advanced_info()
	_building_controls = false


func _find_scale_index(value: float) -> int:
	var scales := [1.0, 0.85, 0.75, 0.67, 0.55, 0.50]
	var best := 0
	var delta := INF
	for index in range(scales.size()):
		var next_delta := absf(value - scales[index])
		if next_delta < delta:
			delta = next_delta
			best = index
	return best


func _update_resolution_info() -> void:
	if _resolution_info == null or _manager == null:
		return
	var preview: Dictionary = _manager.call("get_render_resolution_preview", int(_draft.get("render_resolution", 0)), float(_draft.get("extra_3d_scale", 1.0)), int(_draft.get("display_mode", 0)))
	var output: Vector2i = preview.get("output_size", Vector2i.ZERO)
	var root_size: Vector2i = preview.get("root_viewport_size", Vector2i.ZERO)
	var internal_size: Vector2i = preview.get("three_d_internal_size_estimate", Vector2i.ZERO)
	var render_index := int(_draft.get("render_resolution", 0))
	_resolution_info.text = tr("menu.graphics.resolution_info") % [output.x, output.y, root_size.x, root_size.y, internal_size.x, internal_size.y]
	if render_index == 0:
		_resolution_info.text += "\n" + tr("menu.graphics.resolution_native_note")
	else:
		_resolution_info.text += "\n" + tr("menu.graphics.resolution_scaled_note")
		if not _extra_3d_scale_manually_edited and float(_draft.get("extra_3d_scale", 1.0)) >= 0.999:
			_resolution_info.text += tr("menu.graphics.resolution_extra_scale_note")


func _update_advanced_info() -> void:
	if _advanced_info == null:
		return
	var scale_value := float(_draft.get("extra_3d_scale", 1.0))
	var root_scale: float = [1.0, 0.85, 0.70, 0.55, 0.45][clampi(int(_draft.get("render_resolution", 0)), 0, 4)]
	var text_value := tr("menu.graphics.upscaler_status") % [scale_value, _effective_upscaler_name()]
	var upscaler_index := int(_draft.get("upscaler", 0))
	if upscaler_index == 0:
		upscaler_index = 1 if scale_value < 0.999 else 3
	_sharpness.editable = upscaler_index == 1 or upscaler_index == 2
	if root_scale < 0.999 and scale_value < 0.999:
		text_value += "\n" + tr("menu.graphics.upscaler_double_scale_note")
	elif scale_value >= 0.999:
		text_value += "\n" + tr("menu.graphics.upscaler_native_note")
	var preview: Dictionary = _manager.call("get_render_resolution_preview", int(_draft.get("render_resolution", 0)), scale_value, int(_draft.get("display_mode", 0)))
	var size: Vector2i = preview.get("three_d_internal_size_estimate", Vector2i.ZERO)
	_advanced_info.text = text_value + "\n" + (tr("menu.graphics.internal_size_info") % [size.x, size.y])


func _effective_upscaler_name() -> String:
	var index := int(_draft.get("upscaler", 0))
	if index == 0:
		index = 1 if float(_draft.get("extra_3d_scale", 1.0)) < 0.999 else 3
	return tr(["menu.graphics.upscaling.auto", "menu.graphics.upscaling.fsr2", "menu.graphics.upscaling.fsr1", "menu.graphics.upscaling.bilinear"][clampi(index, 0, 3)])


func _on_display_mode_selected(index: int) -> void:
	if not _building_controls:
		_draft["display_mode"] = index
		_update_resolution_info()
		_update_advanced_info()


func _on_vsync_toggled(enabled: bool) -> void:
	if not _building_controls:
		_draft["vsync_enabled"] = enabled


func _on_frame_limit_selected(index: int) -> void:
	if not _building_controls:
		_draft["frame_limit"] = index


func _on_render_resolution_selected(index: int) -> void:
	if _building_controls:
		return
	_draft["render_resolution"] = index
	if index > 0 and not _extra_3d_scale_manually_edited:
		_draft["extra_3d_scale"] = 1.0
		if not _upscaler_manually_edited:
			_draft["upscaler"] = 0
			_upscaler.select(0)
		_extra_scale.select(0)
	_update_resolution_info()
	_update_advanced_info()


func _on_preset_selected(index: int) -> void:
	if _building_controls or _manager == null:
		return
	_draft = _manager.call("get_graphics_settings_for_preset", _draft, index)
	_sync_controls()


func _on_visual_toggle(enabled: bool, key: String) -> void:
	if _building_controls:
		return
	var values: Dictionary = _draft.get("visual_values", {}).duplicate(true)
	values[key] = enabled
	_draft["visual_values"] = values
	_draft["graphics_preset"] = PRESET_CUSTOM
	_preset.select(PRESET_CUSTOM)


func _on_cloud_quality_selected(index: int) -> void:
	if _building_controls or _manager == null:
		return
	_draft = _manager.call("set_cloud_quality_in_settings", _draft, index)
	_preset.select(PRESET_CUSTOM)


func _on_ocean_quality_selected(index: int) -> void:
	if _building_controls or _manager == null:
		return
	_draft = _manager.call("set_ocean_quality_in_settings", _draft, index)
	_preset.select(PRESET_CUSTOM)


func _on_shadow_distance_changed(value: float) -> void:
	if _building_controls:
		return
	_update_visual_float("shadow_distance", value)


func _on_vegetation_density_changed(value: float) -> void:
	if _building_controls:
		return
	_update_visual_float("vegetation_density", value)


func _update_visual_float(key: String, value: float) -> void:
	var values: Dictionary = _draft.get("visual_values", {}).duplicate(true)
	values[key] = value
	_draft["visual_values"] = values
	_draft["graphics_preset"] = PRESET_CUSTOM
	_preset.select(PRESET_CUSTOM)


func _on_extra_scale_selected(index: int) -> void:
	if _building_controls:
		return
	_extra_3d_scale_manually_edited = true
	var scales := [1.0, 0.85, 0.75, 0.67, 0.55, 0.50]
	_draft["extra_3d_scale"] = scales[clampi(index, 0, scales.size() - 1)]
	_update_resolution_info()
	_update_advanced_info()


func _on_upscaler_selected(index: int) -> void:
	if not _building_controls:
		_upscaler_manually_edited = true
		_draft["upscaler"] = index
		_update_advanced_info()


func _on_sharpness_changed(value: float) -> void:
	if not _building_controls:
		_draft["fsr_sharpness"] = value


func _toggle_advanced() -> void:
	_advanced_open = not _advanced_open
	_advanced_content.visible = _advanced_open
	_advanced_button.text = tr("menu.graphics.advanced_open" if _advanced_open else "menu.graphics.advanced_closed")


func _apply_draft() -> void:
	if _manager == null:
		return
	var result: Dictionary = _manager.call("apply_graphics_settings", _draft)
	_status_key = "menu.graphics.applied"
	_status_label.text = tr(_status_key)
	if not bool(result.get("confirmation_required", false)):
		_refresh_from_manager()


func _restore_defaults() -> void:
	if _manager == null:
		return
	_draft = _manager.call("get_default_graphics_settings")
	_sync_controls()
	_status_key = "menu.graphics.defaults_loaded"
	_status_label.text = tr(_status_key)


func _cancel_draft() -> void:
	if _manager != null and _manager.has_method("is_display_confirmation_pending") and bool(_manager.call("is_display_confirmation_pending")):
		_manager.call("revert_graphics_settings")
	_refresh_from_manager()
	back_requested.emit()


func _keep_display_settings() -> void:
	if _manager != null:
		_manager.call("confirm_graphics_settings")
	_refresh_from_manager()


func _revert_display_settings() -> void:
	if _manager != null:
		_manager.call("revert_graphics_settings")
	_refresh_from_manager()


func _on_display_confirmation_changed(active: bool, seconds_remaining: int, _message: String) -> void:
	if _confirmation_bar == null:
		return
	_confirmation_bar.visible = active
	_display_confirmation_seconds = seconds_remaining
	_confirmation_label.text = (tr("menu.graphics.confirm_display") % seconds_remaining) if active else ""


func _on_manager_settings_changed() -> void:
	if _manager != null and not bool(_manager.call("is_display_confirmation_pending")):
		_update_resolution_info()
