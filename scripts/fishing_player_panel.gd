class_name FishingPlayerPanel
extends PanelContainer

## Player facing trolling controls. Real encounter state remains authoritative.

signal close_requested
signal activity_state_changed(active: bool)

const RECENT_ECHO_MAX_AGE_SECONDS := 8.0
const RECENT_ECHO_MIN_STRENGTH := 0.07

var _manager: FishResourceManager
var _rod_system: FishingRodSystem
var _encounter: FishingEncounterSystem
var _lure_option: OptionButton
var _state_label: Label
var _detail_label: Label
var _speed_label: Label
var _echo_label: Label
var _match_label: Label
var _last_catch_label: Label
var _action_button: Button
var _feedback_label: Label
var _title_label: Label
var _last_catch_result: FishingCatchResult
var _feedback_key := ""
var _content: VBoxContainer
var _collapsed_label: Label
var _collapse_button: Button
var _close_button: Button
var _collapsed := false
var _last_active := false
var _refresh_elapsed := 0.0
var _echo_refresh_elapsed := 0.0
var _feedback_remaining := 0.0


func _ready() -> void:
	custom_minimum_size = Vector2(310.0, 0.0)
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
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 5)
	_title_label = Label.new()
	_title_label.text = tr("fishing.ui.title")
	_title_label.add_theme_font_size_override("font_size", 16)
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title_label)
	_collapse_button = Button.new()
	_collapse_button.name = "ActivityCollapseButton"
	_collapse_button.custom_minimum_size = Vector2(32.0, 28.0)
	_collapse_button.pressed.connect(func() -> void: set_collapsed(not _collapsed))
	header.add_child(_collapse_button)
	_close_button = Button.new()
	_close_button.name = "ConfigurationCloseButton"
	_close_button.text = "×"
	_close_button.custom_minimum_size = Vector2(32.0, 28.0)
	_close_button.pressed.connect(func() -> void: close_requested.emit())
	header.add_child(_close_button)
	layout.add_child(header)
	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 5)
	layout.add_child(_content)
	_lure_option = OptionButton.new()
	_lure_option.name = "LureSelector"
	_lure_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lure_option.item_selected.connect(_on_lure_selected)
	_content.add_child(_lure_option)
	_detail_label = _new_body_label()
	_content.add_child(_detail_label)
	_speed_label = _new_body_label()
	_speed_label.name = "TrollingSpeedSuitability"
	_content.add_child(_speed_label)
	_echo_label = _new_body_label()
	_echo_label.add_theme_color_override("font_color", Color(0.72, 0.84, 0.81, 1.0))
	_content.add_child(_echo_label)
	_match_label = _new_body_label()
	_content.add_child(_match_label)
	_last_catch_label = _new_body_label()
	_last_catch_label.name = "LastCatchSummary"
	_last_catch_label.add_theme_color_override("font_color", Color(0.58, 0.85, 0.78, 1.0))
	_last_catch_label.visible = false
	_content.add_child(_last_catch_label)
	var action_row := HBoxContainer.new()
	_state_label = Label.new()
	_state_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_state_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	action_row.add_child(_state_label)
	_action_button = Button.new()
	_action_button.name = "TrollingActionButton"
	_action_button.pressed.connect(_on_action_pressed)
	action_row.add_child(_action_button)
	_content.add_child(action_row)
	_collapsed_label = _new_body_label()
	_collapsed_label.visible = false
	layout.add_child(_collapsed_label)
	_feedback_label = _new_body_label()
	_feedback_label.add_theme_color_override("font_color", Color(1.0, 0.78, 0.35, 1.0))
	layout.add_child(_feedback_label)
	_refresh_localized_text()
	_update_panel()


func _new_body_label() -> Label:
	var label := Label.new()
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


func configure(manager: FishResourceManager, rod_system: FishingRodSystem) -> void:
	_manager = manager
	_rod_system = rod_system
	_resolve_encounter()
	_update_panel()
	_update_echo_summary()


func set_collapsed(collapsed: bool) -> void:
	if _collapsed == collapsed:
		return
	_collapsed = collapsed
	_apply_collapsed_state()


func is_trolling_active() -> bool:
	return _is_activity_active()


func refresh_localized_text() -> void:
	_refresh_localized_text()
	_update_panel()
	_update_echo_summary()
	_apply_collapsed_state()


func _refresh_localized_text() -> void:
	if _title_label != null:
		_title_label.text = tr("fishing.ui.title")
	if _lure_option != null:
		_populate_lures()
	if _close_button != null:
		_close_button.tooltip_text = tr("fishing.ui.close_setup")
	if not _feedback_key.is_empty() and _feedback_label != null and _feedback_remaining > 0.0:
		_feedback_label.text = tr(_feedback_key)
	_refresh_last_catch_summary()


func _process(delta: float) -> void:
	_refresh_elapsed += delta
	if _refresh_elapsed >= 0.2:
		_refresh_elapsed = fmod(_refresh_elapsed, 0.2)
		_resolve_encounter()
		_update_panel()
	_echo_refresh_elapsed += delta
	if _echo_refresh_elapsed >= 1.0:
		_echo_refresh_elapsed = fmod(_echo_refresh_elapsed, 1.0)
		_update_echo_summary()
	if _feedback_remaining > 0.0:
		_feedback_remaining = maxf(0.0, _feedback_remaining - delta)
		if _feedback_remaining <= 0.0 and _feedback_label != null:
			_feedback_label.text = ""
			_feedback_key = ""


func _resolve_encounter() -> void:
	if _manager == null or not _manager.has_method("get_fishing_encounter_system"):
		return
	var found := _manager.get_fishing_encounter_system() as FishingEncounterSystem
	if found == _encounter:
		return
	if _encounter != null:
		if _encounter.catch_succeeded.is_connected(_on_catch_succeeded): _encounter.catch_succeeded.disconnect(_on_catch_succeeded)
		if _encounter.fish_hooked.is_connected(_on_fish_hooked): _encounter.fish_hooked.disconnect(_on_fish_hooked)
		if _encounter.catch_cancelled.is_connected(_on_catch_cancelled): _encounter.catch_cancelled.disconnect(_on_catch_cancelled)
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
	var selected_id := _encounter.selected_lure_id if _encounter != null else ""
	_lure_option.clear()
	if _encounter == null:
		_lure_option.add_item(tr("fishing.ui.unavailable"))
		_lure_option.disabled = true
		return
	_lure_option.disabled = false
	for lure in _encounter.get_lure_profiles():
		_lure_option.add_item("%s · %.1f–%.1f m" % [tr(lure.name_key), lure.work_depth_range_m.x, lure.work_depth_range_m.y])
		_lure_option.set_item_metadata(_lure_option.item_count - 1, lure.lure_id)
		if lure.lure_id == selected_id:
			_lure_option.select(_lure_option.item_count - 1)


func _on_lure_selected(index: int) -> void:
	if _encounter == null or index < 0 or index >= _lure_option.item_count:
		return
	if not _encounter.select_lure(str(_lure_option.get_item_metadata(index))):
		_show_feedback("fishing.ui.lure_locked")
	_update_panel()
	_update_echo_summary()


func _on_action_pressed() -> void:
	if _encounter == null:
		return
	var active := _is_activity_active()
	if active:
		if _rod_system != null:
			_rod_system.stop_trolling()
		else:
			_encounter.stop_trolling()
	else:
		var accepted := _rod_system.start_trolling() if _rod_system != null else _encounter.start_trolling()
		if not accepted:
			_show_feedback("fishing.ui.start_rejected")
	_update_panel()


func _on_fish_hooked(_pending: FishingPendingCatch) -> void:
	_show_feedback("fishing.ui.hooked")


func _on_catch_succeeded(result: FishingCatchResult) -> void:
	if result == null:
		return
	_last_catch_result = result
	_refresh_last_catch_summary()
	_update_panel()


func _on_catch_cancelled(_catch_id: String, _reason: String) -> void:
	_show_feedback("fishing.ui.cancelled")
	_update_panel()


func _show_feedback(message_key: String, duration: float = 2.5) -> void:
	_feedback_key = message_key
	_feedback_label.text = tr(message_key)
	_feedback_remaining = duration


func _refresh_last_catch_summary() -> void:
	if _last_catch_label == null:
		return
	if _last_catch_result == null:
		_last_catch_label.visible = false
		return
	var profile := _manager.get_species_profile(_last_catch_result.species_id) if _manager != null else null
	var species_name := tr(profile.name_key) if profile != null else tr("fishing.ui.unknown_fish")
	_last_catch_label.text = tr("fishing.ui.last_catch_format") % [species_name, _last_catch_result.length_m * 100.0, _last_catch_result.estimated_weight_kg]
	_last_catch_label.visible = true


func _update_panel() -> void:
	if _state_label == null or _detail_label == null or _action_button == null:
		return
	_resolve_encounter()
	var active := _is_activity_active()
	if _encounter == null:
		_state_label.text = tr("fishing.ui.unavailable")
		_detail_label.text = ""
		_speed_label.text = tr("fishing.activity.speed_format") % [tr("fishing.activity.speed.unavailable"), 0.0, 0.0]
		_action_button.text = tr("fishing.ui.start")
		_action_button.disabled = true
		return
	var lure := _encounter.get_selected_lure()
	if lure != null:
		_detail_label.text = tr("fishing.ui.depth") % [lure.work_depth_range_m.x, lure.work_depth_range_m.y]
	var speed_status := get_trolling_speed_status(_encounter, _manager, lure)
	_speed_label.text = tr("fishing.activity.speed_format") % [
		tr("fishing.activity.speed." + str(speed_status.get("status", "unavailable"))),
		float(speed_status.get("speed_mps", 0.0)) * 1.94384,
		float(speed_status.get("efficiency", 0.0)) * 100.0,
	]
	var state_name := _rod_system.get_visual_state_name() if _rod_system != null else _encounter.get_state_name()
	_state_label.text = _localized_state(state_name)
	_action_button.text = tr("fishing.ui.stop") if active else tr("fishing.ui.start")
	_action_button.disabled = false
	_close_button.visible = not active
	_collapsed_label.text = tr("fishing.ui.collapsed_format") % [tr("fishing.ui.state.trolling"), tr(lure.name_key) if lure != null else tr("fishing.ui.unavailable")]
	_apply_collapsed_state()
	if _last_active != active:
		_last_active = active
		activity_state_changed.emit(active)


func _is_activity_active() -> bool:
	if _encounter != null and _encounter.state in [FishingEncounterSystem.State.TROLLING, FishingEncounterSystem.State.HOOKED, FishingEncounterSystem.State.RETRIEVING]:
		return true
	if _rod_system != null:
		return _rod_system.get_visual_state_name() in ["CASTING", "TROLLING", "HOOKED", "REELING", "PRESENTATION"]
	return false


func _apply_collapsed_state() -> void:
	if _content == null or _collapsed_label == null:
		return
	_content.visible = not _collapsed
	_collapsed_label.visible = _collapsed
	_collapse_button.text = "+" if _collapsed else "−"
	_collapse_button.tooltip_text = tr("fishing.ui.expand_activity") if _collapsed else tr("fishing.ui.collapse_activity")
	_close_button.visible = not _is_activity_active()


func _update_echo_summary() -> void:
	if _echo_label == null or _match_label == null:
		return
	var echo := get_recent_echo_summary(_manager, RECENT_ECHO_MAX_AGE_SECONDS, RECENT_ECHO_MIN_STRENGTH)
	var lure := _encounter.get_selected_lure() if _encounter != null else null
	if not bool(echo.get("valid", false)):
		_echo_label.text = tr("fishing.activity.no_recent_echoes")
		_match_label.text = tr("fishing.activity.match_unknown")
		return
	_echo_label.text = tr("fishing.activity.recent_echo_format") % [float(echo["depth_m"]), float(echo["age_seconds"])]
	if lure == null:
		_match_label.text = tr("fishing.activity.match_unknown")
		return
	var match_state := classify_lure_depth(float(echo["depth_m"]), lure.work_depth_range_m)
	var match_key := "fishing.activity.match_unknown"
	if match_state == "match":
		match_key = "fishing.activity.match_ok"
	elif match_state == "too_shallow":
		match_key = "fishing.activity.lure_too_shallow"
	elif match_state == "too_deep":
		match_key = "fishing.activity.lure_too_deep"
	_match_label.text = tr(match_key)


static func get_recent_echo_summary(manager: Node, max_age_seconds: float = RECENT_ECHO_MAX_AGE_SECONDS, min_strength: float = RECENT_ECHO_MIN_STRENGTH) -> Dictionary:
	if manager == null or not manager.has_method("get_fish_finder_sensor"):
		return {"valid": false}
	var sensor := manager.call("get_fish_finder_sensor") as FishFinderSensor
	if sensor == null:
		return {"valid": false}
	var now := float(Time.get_ticks_usec()) / 1000000.0
	var best: Dictionary = {}
	var best_score := -1.0
	for scan in sensor.get_scan_history():
		var sample_time := float(scan.get("scan_runtime_seconds", -INF))
		var age := now - sample_time
		if not is_finite(age) or age < 0.0 or age > max_age_seconds:
			continue
		for echo_variant in scan.get("echoes", []):
			if not echo_variant is Dictionary:
				continue
			var echo: Dictionary = echo_variant
			var strength := clampf(float(echo.get("echo_strength", 0.0)), 0.0, 1.0)
			var depth := echo_depth_below_surface_m(scan, echo)
			if strength < min_strength or not is_finite(depth) or depth <= 0.0:
				continue
			var score := strength * (1.0 - 0.35 * age / maxf(max_age_seconds, 0.1))
			if score > best_score:
				best_score = score
				best = {"valid": true, "depth_m": depth, "age_seconds": age, "strength": strength, "school_id": str(echo.get("school_id", ""))}
	return best if not best.is_empty() else {"valid": false}


static func echo_depth_below_surface_m(scan: Dictionary, echo: Dictionary) -> float:
	var surface_y := float(scan.get("surface_height_world_y_m", NAN))
	if not bool(scan.get("surface_valid", false)) or not is_finite(surface_y):
		return NAN
	var target_variant: Variant = echo.get("target_world_position", Vector3(NAN, NAN, NAN))
	if target_variant is Vector3:
		var target := target_variant as Vector3
		if is_finite(target.x) and is_finite(target.y) and is_finite(target.z):
			return surface_y - target.y
	var probe_variant: Variant = scan.get("probe_world_position", Vector3(NAN, NAN, NAN))
	if probe_variant is Vector3:
		var probe := probe_variant as Vector3
		var relative_depth := float(echo.get("target_depth_below_transducer_m", NAN))
		if is_finite(probe.y) and is_finite(relative_depth):
			return surface_y - probe.y + relative_depth
	return float(echo.get("depth_below_surface_m", NAN))


static func classify_lure_depth(echo_depth_m: float, lure_range_m: Vector2) -> String:
	if not is_finite(echo_depth_m) or echo_depth_m <= 0.0 or lure_range_m.y < lure_range_m.x:
		return "unknown"
	if echo_depth_m < lure_range_m.x:
		return "too_deep"
	if echo_depth_m > lure_range_m.y:
		return "too_shallow"
	return "match"


static func get_trolling_speed_status(encounter: FishingEncounterSystem, manager: FishResourceManager, lure: FishingLure) -> Dictionary:
	if encounter == null or manager == null or lure == null:
		return {"status": "unavailable", "speed_mps": 0.0, "efficiency": 0.0}
	var speed_mps := float(encounter.call("_boat_speed_mps"))
	var cruise_cap_mps := float(encounter.call("_boat_cruise_speed_cap_mps"))
	var minimum_speed_mps := float(encounter.get("minimum_effective_trolling_speed_mps"))
	return classify_trolling_speed(speed_mps, cruise_cap_mps, minimum_speed_mps, manager.get_species_profiles(), lure)


static func classify_trolling_speed(speed_mps: float, cruise_cap_mps: float, minimum_speed_mps: float, profiles: Array[FishSpeciesProfile], lure: FishingLure) -> Dictionary:
	if lure == null:
		return {"status": "unavailable", "speed_mps": speed_mps, "efficiency": 0.0}
	var best_efficiency := 0.0
	var best_profile: FishSpeciesProfile
	for profile in profiles:
		if not FishingEncounterSystem.lure_matches_profile(profile, lure, "trolling"):
			continue
		var efficiency := FishingEncounterSystem.speed_efficiency(speed_mps, cruise_cap_mps, profile, minimum_speed_mps)
		if efficiency > best_efficiency:
			best_efficiency = efficiency
			best_profile = profile
	if best_profile == null or best_efficiency <= 0.0:
		return {"status": "unavailable", "speed_mps": speed_mps, "efficiency": 0.0}
	var suitable_efficiency := exp(-0.5)
	var status := "suitable" if best_efficiency >= suitable_efficiency else "slow" if speed_mps < best_profile.trolling_speed_optimum_mps else "fast"
	return {"status": status, "speed_mps": speed_mps, "efficiency": best_efficiency}


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
