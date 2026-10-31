class_name FishingPlayerPanel
extends PanelContainer

## Compact player control surface. Bite diagnostics remain in F3.

var _manager: FishResourceManager
var _rod_system: FishingRodSystem
var _encounter: FishingEncounterSystem
var _lure_option: OptionButton
var _state_label: Label
var _detail_label: Label
var _last_catch_label: Label
var _action_button: Button
var _feedback_label: Label
var _refresh_elapsed := 0.0
var _feedback_remaining := 0.0


func _ready() -> void:
	custom_minimum_size = Vector2(356.0, 0.0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.035, 0.12, 0.16, 0.88)
	style.border_color = Color(0.28, 0.52, 0.55, 0.72)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 9.0
	style.content_margin_bottom = 9.0
	add_theme_stylebox_override("panel", style)
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 5)
	add_child(layout)
	var title := Label.new()
	title.text = tr("fishing.ui.title")
	title.add_theme_font_size_override("font_size", 16)
	layout.add_child(title)
	_lure_option = OptionButton.new()
	_lure_option.name = "LureSelector"
	_lure_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lure_option.item_selected.connect(_on_lure_selected)
	layout.add_child(_lure_option)
	_detail_label = Label.new()
	_detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(_detail_label)
	_last_catch_label = Label.new()
	_last_catch_label.name = "LastCatchSummary"
	_last_catch_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_last_catch_label.add_theme_color_override("font_color", Color(0.58, 0.85, 0.78, 1.0))
	_last_catch_label.visible = false
	layout.add_child(_last_catch_label)
	var action_row := HBoxContainer.new()
	_state_label = Label.new()
	_state_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_state_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	action_row.add_child(_state_label)
	_action_button = Button.new()
	_action_button.name = "TrollingActionButton"
	_action_button.pressed.connect(_on_action_pressed)
	action_row.add_child(_action_button)
	layout.add_child(action_row)
	_feedback_label = Label.new()
	_feedback_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_feedback_label.add_theme_color_override("font_color", Color(1.0, 0.78, 0.35, 1.0))
	layout.add_child(_feedback_label)
	_update_panel()


func configure(manager: FishResourceManager, rod_system: FishingRodSystem) -> void:
	_manager = manager
	_rod_system = rod_system
	_resolve_encounter()
	_update_panel()


func _process(delta: float) -> void:
	_refresh_elapsed += delta
	if _refresh_elapsed >= 0.2:
		_refresh_elapsed = 0.0
		_resolve_encounter()
		_update_panel()
	if _feedback_remaining > 0.0:
		_feedback_remaining = maxf(0.0, _feedback_remaining - delta)
		if _feedback_remaining <= 0.0 and _feedback_label != null:
			_feedback_label.text = ""


func _resolve_encounter() -> void:
	if _manager == null or not _manager.has_method("get_fishing_encounter_system"):
		return
	var found := _manager.get_fishing_encounter_system() as FishingEncounterSystem
	if found == _encounter:
		return
	_encounter = found
	if _encounter == null:
		return
	_encounter.catch_succeeded.connect(_on_catch_succeeded)
	_encounter.fish_hooked.connect(_on_fish_hooked)
	_encounter.catch_cancelled.connect(_on_catch_cancelled)
	_populate_lures()


func _populate_lures() -> void:
	if _lure_option == null:
		return
	_lure_option.clear()
	if _encounter == null:
		_lure_option.add_item(tr("fishing.ui.unavailable"))
		_lure_option.disabled = true
		return
	_lure_option.disabled = false
	for lure in _encounter.get_lure_profiles():
		_lure_option.add_item("%s · %.1f–%.1f m" % [tr(lure.name_key), lure.work_depth_range_m.x, lure.work_depth_range_m.y])
		_lure_option.set_item_metadata(_lure_option.item_count - 1, lure.lure_id)
		if lure.lure_id == _encounter.selected_lure_id:
			_lure_option.select(_lure_option.item_count - 1)


func _on_lure_selected(index: int) -> void:
	if _encounter == null or index < 0 or index >= _lure_option.item_count:
		return
	if not _encounter.select_lure(str(_lure_option.get_item_metadata(index))):
		_show_feedback(tr("fishing.ui.lure_locked"))
	_update_panel()


func _on_action_pressed() -> void:
	if _encounter == null:
		return
	var visual_active := _rod_system != null and _rod_system.get_visual_state_name() != "IDLE"
	if _encounter.state in [FishingEncounterSystem.State.TROLLING, FishingEncounterSystem.State.HOOKED, FishingEncounterSystem.State.RETRIEVING] or visual_active:
		if _rod_system != null:
			_rod_system.stop_trolling()
		else:
			_encounter.stop_trolling()
	else:
		var accepted := _rod_system.start_trolling() if _rod_system != null else _encounter.start_trolling()
		if not accepted:
			_show_feedback(tr("fishing.ui.start_rejected"))
	_update_panel()


func _on_fish_hooked(_pending: FishingPendingCatch) -> void:
	_show_feedback(tr("fishing.ui.hooked"))


func _on_catch_succeeded(result: FishingCatchResult) -> void:
	if result == null:
		return
	var profile := _manager.get_species_profile(result.species_id) if _manager != null else null
	var species_name := tr(profile.name_key) if profile != null else tr("fishing.ui.unknown_fish")
	_last_catch_label.text = tr("fishing.ui.last_catch_format") % [species_name, result.length_m * 100.0, result.estimated_weight_kg]
	_last_catch_label.visible = true
	_update_panel()


func _on_catch_cancelled(_catch_id: String, _reason: String) -> void:
	_show_feedback(tr("fishing.ui.cancelled"))
	_update_panel()


func _show_feedback(message: String, duration: float = 2.5) -> void:
	_feedback_label.text = message
	_feedback_remaining = duration


func _update_panel() -> void:
	if _state_label == null or _detail_label == null or _action_button == null:
		return
	_resolve_encounter()
	if _encounter == null:
		_state_label.text = tr("fishing.ui.unavailable")
		_detail_label.text = ""
		_action_button.text = tr("fishing.ui.start")
		_action_button.disabled = true
		return
	var lure := _encounter.get_selected_lure()
	if lure != null:
		_detail_label.text = tr("fishing.ui.depth") % [lure.work_depth_range_m.x, lure.work_depth_range_m.y]
	var state_name := _rod_system.get_visual_state_name() if _rod_system != null else _encounter.get_state_name()
	_state_label.text = _localized_state(state_name)
	var active := state_name != "IDLE"
	_action_button.text = tr("fishing.ui.stop") if active else tr("fishing.ui.start")
	_action_button.disabled = false


func _localized_state(state_name: String) -> String:
	var key := "fishing.ui.state.ready"
	match state_name:
		"CASTING": key = "fishing.ui.state.deploying"
		"TROLLING": key = "fishing.ui.state.trolling"
		"HOOKED": key = "fishing.ui.state.hooked"
		"REELING": key = "fishing.ui.state.reeling"
		"PRESENTATION": key = "fishing.ui.state.catch"
		"SIMULATING": key = "fishing.ui.state.simulation_preview"
	return tr(key)

