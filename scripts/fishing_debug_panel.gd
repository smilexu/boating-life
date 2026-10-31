extends ScrollContainer

## Developer-only controls for exercising the P2 APIs; this is not player UI.

var _manager: Node
var _encounter: FishingEncounterSystem
var _finder: FishFinderSensor
var _rod_system: FishingRodSystem
var _lure_option: OptionButton
var _trolling_start_button: Button
var _trolling_stop_button: Button
var _simulation_species_option: OptionButton
var _simulation_length_spin: SpinBox
var _hanging_struggle_intensity_spin: SpinBox
var _simulation_seed_spin: SpinBox
var _simulation_weight_label: Label
var _simulation_reason_label: Label
var _simulation_start_button: Button
var _simulation_stop_button: Button
var _simulation_replay_button: Button
var _simulation_pause_button: Button
var _simulation_speed_option: OptionButton
var _simulation_phase_option: OptionButton
var _simulation_seek_button: Button
var _advanced_toggle: Button
var _advanced_controls: VBoxContainer
var _seed_spin: SpinBox
var _status_label: Label
var _feedback_label: Label
var _refresh_elapsed := 0.0
var _simulation_species_ids: Array[String] = []


func _ready() -> void:
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	var content := VBoxContainer.new()
	content.name = "FishingDebugContent"
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 7)
	add_child(content)
	var title := Label.new()
	title.text = tr("fishing.debug.title")
	title.add_theme_font_size_override("font_size", 17)
	content.add_child(title)
	_add_section_heading(content, "fishing.debug.section.real_trolling")
	_lure_option = OptionButton.new()
	_lure_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lure_option.item_selected.connect(_on_lure_selected)
	content.add_child(_lure_option)
	var start_stop_row := HBoxContainer.new()
	_trolling_start_button = _add_button(start_stop_row, "fishing.debug.start", _on_start_pressed)
	_trolling_stop_button = _add_button(start_stop_row, "fishing.debug.stop", _on_stop_pressed)
	content.add_child(start_stop_row)

	_add_section_heading(content, "fishing.debug.section.simulation")
	_simulation_species_option = OptionButton.new()
	_simulation_species_option.name = "SimulatedCatchSpecies"
	_simulation_species_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_simulation_species_option.disabled = true
	_simulation_species_option.item_selected.connect(_on_simulation_species_selected)
	content.add_child(_simulation_species_option)
	var length_row := HBoxContainer.new()
	var length_label := Label.new()
	length_label.text = tr("fishing.debug.sim_length")
	length_row.add_child(length_label)
	_simulation_length_spin = SpinBox.new()
	_simulation_length_spin.name = "SimulatedFishLengthCm"
	_simulation_length_spin.min_value = 1.0
	_simulation_length_spin.max_value = 200.0
	_simulation_length_spin.step = 1.0
	_simulation_length_spin.suffix = tr("fishing.debug.unit.cm")
	_simulation_length_spin.value = 65.0
	_simulation_length_spin.value_changed.connect(_on_simulation_length_changed)
	length_row.add_child(_simulation_length_spin)
	content.add_child(length_row)
	var hanging_intensity_row := HBoxContainer.new()
	var hanging_intensity_label := Label.new()
	hanging_intensity_label.text = tr("fishing.debug.hanging_intensity")
	hanging_intensity_row.add_child(hanging_intensity_label)
	_hanging_struggle_intensity_spin = SpinBox.new()
	_hanging_struggle_intensity_spin.name = "HangingStruggleIntensity"
	_hanging_struggle_intensity_spin.min_value = 0.5
	_hanging_struggle_intensity_spin.max_value = 4.0
	_hanging_struggle_intensity_spin.step = 0.1
	_hanging_struggle_intensity_spin.value = 3.0
	_hanging_struggle_intensity_spin.suffix = "×"
	_hanging_struggle_intensity_spin.value_changed.connect(_on_hanging_struggle_intensity_changed)
	hanging_intensity_row.add_child(_hanging_struggle_intensity_spin)
	content.add_child(hanging_intensity_row)
	_simulation_weight_label = Label.new()
	content.add_child(_simulation_weight_label)
	_simulation_reason_label = Label.new()
	_simulation_reason_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_simulation_reason_label)
	var animation_seed_row := HBoxContainer.new()
	var animation_seed_label := Label.new()
	animation_seed_label.text = tr("fishing.debug.sim_seed")
	animation_seed_row.add_child(animation_seed_label)
	_simulation_seed_spin = SpinBox.new()
	_simulation_seed_spin.name = "SimulatedAnimationSeed"
	_simulation_seed_spin.min_value = 0
	_simulation_seed_spin.max_value = 2147483647
	_simulation_seed_spin.step = 1
	_simulation_seed_spin.value = 20261030
	animation_seed_row.add_child(_simulation_seed_spin)
	content.add_child(animation_seed_row)
	_simulation_start_button = _add_button(content, "fishing.debug.sim_start", _on_simulation_start_pressed)
	_simulation_start_button.name = "SimulatedCatchStart"
	var simulation_buttons := HBoxContainer.new()
	_simulation_stop_button = _add_button(simulation_buttons, "fishing.debug.sim_stop", _on_simulation_stop_pressed)
	_simulation_replay_button = _add_button(simulation_buttons, "fishing.debug.sim_replay", _on_simulation_replay_pressed)
	_simulation_stop_button.name = "SimulatedCatchStop"
	_simulation_replay_button.name = "SimulatedCatchReplay"
	content.add_child(simulation_buttons)
	var playback_row := HBoxContainer.new()
	_simulation_pause_button = _add_button(playback_row, "fishing.debug.sim_pause", _on_simulation_pause_pressed)
	_simulation_pause_button.name = "SimulatedCatchPause"
	_simulation_speed_option = OptionButton.new()
	_simulation_speed_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_simulation_speed_option.add_item(tr("fishing.debug.sim_speed.half"))
	_simulation_speed_option.set_item_metadata(0, 0.5)
	_simulation_speed_option.add_item(tr("fishing.debug.sim_speed.normal"))
	_simulation_speed_option.set_item_metadata(1, 1.0)
	_simulation_speed_option.add_item(tr("fishing.debug.sim_speed.double"))
	_simulation_speed_option.set_item_metadata(2, 2.0)
	_simulation_speed_option.select(1)
	_simulation_speed_option.item_selected.connect(_on_simulation_speed_selected)
	playback_row.add_child(_simulation_speed_option)
	content.add_child(playback_row)
	var seek_row := HBoxContainer.new()
	_simulation_phase_option = OptionButton.new()
	_simulation_phase_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_populate_simulation_phases()
	seek_row.add_child(_simulation_phase_option)
	_simulation_seek_button = _add_button(seek_row, "fishing.debug.sim_seek", _on_simulation_seek_pressed)
	_simulation_seek_button.name = "SimulatedCatchSeek"
	content.add_child(seek_row)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_status_label)
	_feedback_label = Label.new()
	_feedback_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_feedback_label)
	_advanced_toggle = Button.new()
	_advanced_toggle.text = tr("fishing.debug.advanced")
	_advanced_toggle.name = "AdvancedP2Toggle"
	_advanced_toggle.toggle_mode = true
	_advanced_toggle.toggled.connect(_on_advanced_toggled)
	content.add_child(_advanced_toggle)
	_advanced_controls = VBoxContainer.new()
	_advanced_controls.name = "AdvancedP2Controls"
	_advanced_controls.visible = false
	_advanced_controls.add_theme_constant_override("separation", 5)
	content.add_child(_advanced_controls)
	var seed_row := HBoxContainer.new()
	var seed_label := Label.new()
	seed_label.text = tr("fishing.debug.seed")
	seed_row.add_child(seed_label)
	_seed_spin = SpinBox.new()
	_seed_spin.min_value = 0
	_seed_spin.max_value = 2147483647
	_seed_spin.step = 1
	_seed_spin.value = 20261030
	_seed_spin.value_changed.connect(_on_seed_changed)
	seed_row.add_child(_seed_spin)
	_advanced_controls.add_child(seed_row)
	var encounter_row := HBoxContainer.new()
	_add_button(encounter_row, "fishing.debug.roll", _on_roll_pressed)
	_add_button(encounter_row, "fishing.debug.force_hook", _on_force_hook_pressed)
	_advanced_controls.add_child(encounter_row)
	var retrieval_row := HBoxContainer.new()
	_add_button(retrieval_row, "fishing.debug.begin_retrieval", _on_begin_retrieval_pressed)
	_add_button(retrieval_row, "fishing.debug.settle", _on_settle_pressed)
	_add_button(retrieval_row, "fishing.debug.cancel", _on_cancel_pressed)
	_advanced_controls.add_child(retrieval_row)
	_add_button(_advanced_controls, "fishing.debug.rod_reset", _on_rod_reset_pressed)
	_add_button(_advanced_controls, "fishing.debug.scan", _on_scan_pressed)
	_refresh_status()


func configure(manager: Node, rod_system: FishingRodSystem = null) -> void:
	_manager = manager
	_rod_system = rod_system
	if _hanging_struggle_intensity_spin != null and _rod_system != null:
		_hanging_struggle_intensity_spin.set_value_no_signal(_rod_system.get_hanging_struggle_intensity())
	if _manager != null and _manager.has_signal("resources_ready") and not _manager.is_node_ready():
		_manager.connect("resources_ready", _on_manager_resources_ready, CONNECT_ONE_SHOT)
	_resolve_systems()
	_populate_simulation_species()
	_populate_simulation_phases()
	_refresh_status()


func _on_manager_resources_ready() -> void:
	_resolve_systems()
	_refresh_status()


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_refresh_elapsed += delta
	if _refresh_elapsed >= 0.5:
		_refresh_elapsed = 0.0
		_resolve_systems()
		_refresh_status()


func _resolve_systems() -> void:
	_populate_simulation_species()
	if _manager == null:
		return
	var resolved_encounter := _manager.call("get_fishing_encounter_system") as FishingEncounterSystem
	var resolved_finder := _manager.call("get_fish_finder_sensor") as FishFinderSensor
	if resolved_encounter != _encounter:
		_encounter = resolved_encounter
		_populate_lures()
	_finder = resolved_finder


func _populate_lures() -> void:
	if _lure_option == null:
		return
	_lure_option.clear()
	if _encounter == null:
		_lure_option.add_item(tr("fishing.debug.unavailable"))
		_lure_option.disabled = true
		return
	_lure_option.disabled = false
	for lure in _encounter.get_lure_profiles():
		_lure_option.add_item("%s · %.1f–%.1f m" % [tr(lure.name_key), lure.work_depth_range_m.x, lure.work_depth_range_m.y])
		_lure_option.set_item_metadata(_lure_option.item_count - 1, lure.lure_id)
		if lure.lure_id == _encounter.selected_lure_id:
			_lure_option.select(_lure_option.item_count - 1)


func _add_section_heading(parent: Control, key: String) -> void:
	var heading := Label.new()
	heading.text = tr(key)
	heading.add_theme_font_size_override("font_size", 14)
	parent.add_child(heading)


func _add_button(parent: Control, key: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = tr(key)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(callback)
	parent.add_child(button)
	return button


func _populate_simulation_species() -> void:
	if _simulation_species_option == null or _manager == null:
		return
	var available_profiles: Array[FishSpeciesProfile] = []
	for species_id in ["sea_trout", "needlefish"]:
		var profile := _manager.call("get_species_profile", species_id) as FishSpeciesProfile
		if profile != null:
			available_profiles.append(profile)
	var next_species_ids: Array[String] = []
	for profile in available_profiles:
		next_species_ids.append(profile.species_id)
	if next_species_ids == _simulation_species_ids and (not next_species_ids.is_empty() or _simulation_species_option.item_count == 1):
		return
	var previous_species_id := _selected_simulation_species_id()
	_simulation_species_option.clear()
	_simulation_species_ids = next_species_ids
	if available_profiles.is_empty():
		_simulation_species_option.add_item(tr("fishing.debug.unavailable"))
		_simulation_species_option.select(0)
		_simulation_species_option.disabled = true
		_update_simulation_weight_preview()
		_refresh_controls()
		return
	_simulation_species_option.disabled = false
	var selected_index := 0
	for profile in available_profiles:
		_simulation_species_option.add_item(tr(profile.name_key))
		_simulation_species_option.set_item_metadata(_simulation_species_option.item_count - 1, profile.species_id)
		if profile.species_id == previous_species_id:
			selected_index = _simulation_species_option.item_count - 1
	_simulation_species_option.select(selected_index)
	_on_simulation_species_selected(selected_index)
	_refresh_controls()


func _selected_simulation_species_id() -> String:
	if _simulation_species_option == null:
		return ""
	var index := _simulation_species_option.selected
	if index < 0 or index >= _simulation_species_option.item_count:
		return ""
	var metadata: Variant = _simulation_species_option.get_item_metadata(index)
	return str(metadata) if metadata != null else ""


func _get_simulation_species_profile(species_id: String) -> FishSpeciesProfile:
	if species_id.is_empty():
		return null
	var profile := _manager.call("get_species_profile", species_id) as FishSpeciesProfile if _manager != null else null
	if profile == null and _rod_system != null:
		profile = _rod_system.get_debug_species_profile(species_id)
	return profile


func _populate_simulation_phases() -> void:
	var keys := [
		"fishing.debug.phase.hook_strike",
		"fishing.debug.phase.fish_struggle",
		"fishing.debug.phase.progressive_retrieval",
		"fishing.debug.phase.surface_landing",
		"fishing.debug.phase.catch_presentation",
	]
	_simulation_phase_option.clear()
	for index in range(keys.size()):
		var seconds: float = _rod_system.get_debug_simulation_phase_start_seconds(index) if _rod_system != null else [0.0, 3.0, 18.0, 40.0, 48.0][index]
		_simulation_phase_option.add_item(tr("fishing.debug.phase_start_format") % [tr(keys[index]), seconds])
		_simulation_phase_option.set_item_metadata(index, index)
	_simulation_phase_option.select(0)


func _on_lure_selected(index: int) -> void:
	if _encounter == null or index < 0 or index >= _lure_option.item_count:
		return
	var accepted := _encounter.select_lure(str(_lure_option.get_item_metadata(index)))
	_show_feedback(tr("fishing.debug.lure_selected") if accepted else tr("fishing.debug.lure_rejected"))
	_refresh_status()


func _on_seed_changed(value: float) -> void:
	if _encounter != null:
		_encounter.set_random_seed(int(value))
		_show_feedback(tr("fishing.debug.seed_applied") % int(value))


func _on_start_pressed() -> void:
	var accepted := _rod_system.start_trolling() if _rod_system != null else (_encounter.start_trolling() if _encounter != null else false)
	_show_feedback(_result_text(accepted))
	_refresh_status()


func _on_stop_pressed() -> void:
	if _rod_system != null:
		_rod_system.stop_trolling()
	elif _encounter != null:
		_encounter.stop_trolling()
	_show_feedback(tr("fishing.debug.stopped"))
	_refresh_status()


func _on_roll_pressed() -> void:
	var result := _encounter.debug_roll_bite_once() if _encounter != null else {"accepted": false}
	_show_feedback(tr("fishing.debug.roll_result") % [bool(result.get("hooked", false)), float(result.get("probability", 0.0)) * 100.0])
	_refresh_status()


func _on_force_hook_pressed() -> void:
	var result := _encounter.debug_force_hook_valid_candidate() if _encounter != null else {"accepted": false, "reason": "unavailable"}
	_show_feedback(tr("fishing.debug.action_result") % [bool(result.get("accepted", false)), _localized_reason(str(result.get("reason", "hooked")))])
	_refresh_status()


func _on_begin_retrieval_pressed() -> void:
	var accepted := _encounter.begin_retrieval() if _encounter != null else false
	_show_feedback(tr("fishing.debug.retrieval_started") if accepted else tr("fishing.debug.action_not_ready"))
	_refresh_status()


func _on_settle_pressed() -> void:
	var result: Dictionary
	if _rod_system != null:
		result = _rod_system.debug_complete_retrieval_now()
	else:
		result = _encounter.complete_retrieval() if _encounter != null else {"accepted": false, "reason": "unavailable"}
	_show_feedback(tr("fishing.debug.action_result") % [bool(result.get("accepted", false)), _localized_reason(str(result.get("reason", "settled")))])
	_refresh_status()


func _on_cancel_pressed() -> void:
	var accepted := _encounter.cancel_pending_catch() if _encounter != null else false
	_show_feedback(tr("fishing.debug.cancel_result") % accepted)
	_refresh_status()


func _on_rod_reset_pressed() -> void:
	if _rod_system != null:
		_rod_system.debug_reset_visual()
		_show_feedback(tr("fishing.debug.rod_reset_done"))
	else:
		_show_feedback(tr("fishing.debug.unavailable"))
	_refresh_status()


func _on_scan_pressed() -> void:
	var result := _finder.scan(true) if _finder != null else {"accepted": false, "reason": "unavailable"}
	_show_feedback(tr("fishing.debug.scan_result") % [bool(result.get("accepted", false)), result.get("echoes", []).size(), _localized_reason(str(result.get("reason", "")))])
	_refresh_status()


func _on_simulation_species_selected(index: int) -> void:
	if _simulation_species_option == null or index < 0 or index >= _simulation_species_option.item_count:
		return
	var species_id := str(_simulation_species_option.get_item_metadata(index))
	var profile := _get_simulation_species_profile(species_id)
	if profile == null:
		return
	_simulation_length_spin.min_value = ceilf(profile.body_length_range_m.x * 100.0)
	_simulation_length_spin.max_value = floorf(profile.body_length_range_m.y * 100.0)
	var default_cm := 65.0 if species_id == "sea_trout" else 60.0
	_simulation_length_spin.set_value_no_signal(clampf(default_cm, _simulation_length_spin.min_value, _simulation_length_spin.max_value))
	_update_simulation_weight_preview()


func _on_simulation_length_changed(_value: float) -> void:
	_update_simulation_weight_preview()


func _update_simulation_weight_preview() -> void:
	if _simulation_weight_label == null or _simulation_species_option == null:
		return
	var species_id := _selected_simulation_species_id()
	var profile := _get_simulation_species_profile(species_id)
	var length_m := _simulation_length_spin.value / 100.0 if _simulation_length_spin != null else 0.0
	if profile == null:
		_simulation_weight_label.text = tr("fishing.debug.unavailable")
		return
	var weight_kg := profile.estimated_weight_coefficient_kg_per_m3 * pow(length_m, 3.0)
	_simulation_weight_label.text = tr("fishing.debug.sim_weight") % weight_kg


func _on_simulation_start_pressed() -> void:
	if _rod_system == null or _simulation_species_option == null:
		_show_feedback(tr("fishing.debug.unavailable"))
		return
	var species_id := _selected_simulation_species_id()
	if species_id.is_empty():
		_show_feedback(tr("fishing.debug.unavailable"))
		return
	var result := _rod_system.start_debug_simulated_catch(species_id, _simulation_length_spin.value, int(_simulation_seed_spin.value))
	var reason := str(result.get("reason", "valid"))
	_show_feedback(tr("fishing.debug.sim_result") % [bool(result.get("accepted", false)), _localized_reason(reason)])
	_refresh_status()


func _on_simulation_stop_pressed() -> void:
	var accepted := _rod_system.debug_stop_simulated_catch() if _rod_system != null else false
	_show_feedback(tr("fishing.debug.sim_stopped") if accepted else tr("fishing.debug.action_not_ready"))
	_refresh_status()


func _on_simulation_replay_pressed() -> void:
	var accepted := _rod_system.debug_replay_simulated_catch() if _rod_system != null else false
	_show_feedback(tr("fishing.debug.sim_replayed") if accepted else tr("fishing.debug.action_not_ready"))
	_refresh_status()


func _on_simulation_pause_pressed() -> void:
	if _rod_system == null:
		return
	var snapshot := _rod_system.get_presentation_snapshot()
	var next_paused := not bool(snapshot.get("simulation_paused", false))
	_rod_system.debug_set_simulation_paused(next_paused)
	_refresh_status()


func _on_simulation_speed_selected(index: int) -> void:
	if _simulation_speed_option == null or _rod_system == null or index < 0:
		return
	_rod_system.debug_set_simulation_speed(float(_simulation_speed_option.get_item_metadata(index)))


func _on_hanging_struggle_intensity_changed(value: float) -> void:
	if _rod_system != null:
		_rod_system.debug_set_hanging_struggle_intensity(value)


func _on_simulation_seek_pressed() -> void:
	if _simulation_phase_option == null or _rod_system == null:
		return
	var index := _simulation_phase_option.selected
	var accepted := _rod_system.debug_seek_simulation_phase(int(_simulation_phase_option.get_item_metadata(index))) if index >= 0 else false
	_show_feedback(tr("fishing.debug.sim_seek_done") if accepted else tr("fishing.debug.action_not_ready"))
	_refresh_status()


func _on_advanced_toggled(expanded: bool) -> void:
	if _advanced_controls != null:
		_advanced_controls.visible = expanded


func _refresh_status() -> void:
	if _status_label == null:
		return
	_refresh_controls()
	if _encounter == null:
		_status_label.text = tr("fishing.debug.unavailable")
		return
	var diagnostics := _encounter.get_diagnostics()
	var lure: FishingLure = _encounter.get_selected_lure()
	var context: Dictionary = diagnostics.get("lure_context", {})
	var pending: Dictionary = diagnostics.get("pending_catch", {})
	var candidates: Array[Dictionary] = diagnostics.get("candidate_schools", [])
	var valid_count := int(diagnostics.get("valid_candidate_count", 0))
	var rate := float(diagnostics.get("total_event_rate_per_game_hour", 0.0))
	var speed := float(diagnostics.get("boat_speed_mps", 0.0))
	var depth_min := float(diagnostics.get("effective_lure_min_depth_m", lure.work_depth_range_m.x if lure != null else 0.0))
	var depth_max := float(context.get("effective_lure_max_depth_m", lure.work_depth_range_m.y if lure != null else 0.0))
	var lines := [
		tr("fishing.debug.state") % _localized_state(_encounter.get_state_name()),
		tr("fishing.debug.current_lure") % (tr(lure.name_key) if lure != null else tr("fishing.debug.unavailable")),
		tr("fishing.debug.speed") % speed,
		tr("fishing.debug.work_depth") % [depth_min, depth_max],
		tr("fishing.debug.candidates") % [valid_count, candidates.size()],
		tr("fishing.debug.rate") % [rate, float(diagnostics.get("probability_per_game_minute", 0.0)) * 100.0],
		tr("fishing.debug.pending") % (str(pending.get("catch_id", "—")) if not pending.is_empty() else "—"),
	]
	if _rod_system != null:
		lines.append(tr("fishing.debug.rod_visual_state") % tr("fishing.debug.visual." + _rod_system.get_visual_state_name().to_lower()))
		var presentation := _rod_system.get_presentation_snapshot()
		var source_name := str(presentation.get("source", "NONE"))
		if source_name != "NONE":
			lines.append(tr("fishing.debug.presentation_source") % tr("fishing.debug.source." + source_name.to_lower()))
			var species_profile := _manager.call("get_species_profile", str(presentation.get("species_id", ""))) as FishSpeciesProfile if _manager != null else null
			var presentation_species := tr(species_profile.name_key) if species_profile != null else str(presentation.get("species_id", ""))
			if source_name == "DEBUG_SIMULATION":
				lines.append(tr("fishing.debug.sim_status") % [presentation_species, float(presentation.get("body_length_cm", 0.0)), float(presentation.get("estimated_weight_kg", 0.0)), int(presentation.get("simulation_seed", 0))])
			else:
				lines.append(tr("fishing.debug.presentation_catch") % [presentation_species, float(presentation.get("body_length_cm", 0.0)), float(presentation.get("estimated_weight_kg", 0.0))])
		var phase_key := "fishing.debug.phase." + str(presentation.get("phase", "none")).to_lower()
		var line_key := "fishing.debug.line_state." + str(presentation.get("line_state", "out")).to_lower()
		var fish_key := "fishing.debug.fish_stage." + str(presentation.get("fish_stage", "hidden")).to_lower()
		var camera_key := "camera.mode." + str(presentation.get("camera_mode", "unavailable"))
		lines.append(tr("fishing.debug.presentation_status") % [tr(phase_key), float(presentation.get("phase_remaining_seconds", 0.0)), float(presentation.get("total_progress", 0.0)) * 100.0])
		lines.append(tr("fishing.debug.presentation_load") % [float(presentation.get("rod_load_ratio", 0.0)) * 100.0, tr(line_key), float(presentation.get("line_distance_m", 0.0)), tr(fish_key)])
		var camera_label := tr(camera_key) if camera_key != "camera.mode.unavailable" else tr("fishing.debug.unavailable")
		var auto_switch_label := tr("fishing.debug.auto_on") if bool(presentation.get("auto_fight_camera", false)) else tr("fishing.debug.auto_off")
		lines.append(tr("fishing.debug.presentation_camera") % [camera_label, auto_switch_label])
		var simulation_active := str(presentation.get("source", "NONE")) == "DEBUG_SIMULATION"
		if simulation_active:
			_simulation_reason_label.text = tr("fishing.debug.sim_preview_only")
		elif _encounter.pending_catch != null or _encounter.state in [FishingEncounterSystem.State.HOOKED, FishingEncounterSystem.State.RETRIEVING]:
			_simulation_reason_label.text = tr("fishing.debug.sim_blocked_pending")
		else:
			_simulation_reason_label.text = tr("fishing.debug.sim_no_school_required")
	if not candidates.is_empty():
		var brief: Array[String] = []
		for candidate in candidates.slice(0, mini(4, candidates.size())):
			var profile := _manager.call("get_species_profile", str(candidate.get("species_id", ""))) as FishSpeciesProfile
			var species_name := tr(profile.name_key) if profile != null else str(candidate.get("species_id", ""))
			brief.append(tr("fishing.debug.candidate_row") % [species_name, str(candidate.get("school_id", "")), float(candidate.get("activity_depth_m", 0.0)), float(candidate.get("depth_weight", 0.0)), float(candidate.get("speed_efficiency", 0.0)), float(candidate.get("event_rate_per_game_hour", 0.0)), _localized_reason(str(candidate.get("rejection_reason", "")))])
		lines.append("\n".join(brief))
	var result: Dictionary = diagnostics.get("last_catch_result", {})
	if not result.is_empty():
		var profile := _manager.call("get_species_profile", str(result.get("species_id", ""))) as FishSpeciesProfile
		lines.append(tr("fishing.debug.last_catch") % [tr(profile.name_key) if profile != null else str(result.get("species_id", "")), float(result.get("length_m", 0.0)) * 100.0, float(result.get("estimated_weight_kg", 0.0)), int(result.get("population_before", 0)), int(result.get("population_after", 0))])
	var scan := _finder.get_last_scan() if _finder != null else {}
	lines.append(tr("fishing.debug.finder") % [int(scan.get("scan_id", 0)), scan.get("echoes", []).size(), _localized_reason(str(scan.get("reason", "not_scanned")))])
	if not scan.is_empty():
		var echoes: Array = scan.get("echoes", [])
		var nearest_depth := float(echoes[0].get("depth_below_surface_m", 0.0)) if not echoes.is_empty() else -1.0
		var nearest_strength := float(echoes[0].get("echo_strength", 0.0)) if not echoes.is_empty() else 0.0
		lines.append(tr("fishing.debug.finder_detail") % [float(scan.get("chart_depth_lat_m", 0.0)), float(scan.get("water_column_below_surface_m", 0.0)), nearest_depth, nearest_strength])
	_status_label.text = "\n".join(lines)
	_update_simulation_weight_preview()


func _refresh_controls() -> void:
	var simulation_active := _rod_system != null and _rod_system.presentation_source == FishingRodSystem.PresentationSource.DEBUG_SIMULATION
	var has_species := not _selected_simulation_species_id().is_empty()
	var can_simulate := _rod_system != null and _rod_system.can_start_debug_simulation() and has_species
	if _trolling_start_button != null:
		_trolling_start_button.disabled = _rod_system != null and (simulation_active or _rod_system.visual_state != FishingRodSystem.VisualState.IDLE)
	if _trolling_stop_button != null:
		_trolling_stop_button.disabled = _encounter == null or (_encounter.state == FishingEncounterSystem.State.IDLE and not simulation_active)
	if _simulation_start_button != null:
		_simulation_start_button.disabled = not can_simulate
	if _simulation_stop_button != null:
		_simulation_stop_button.disabled = not simulation_active
	if _simulation_replay_button != null:
		_simulation_replay_button.disabled = _rod_system == null or not (_rod_system.has_debug_simulation_replay() and (simulation_active or can_simulate))
	if _simulation_pause_button != null:
		_simulation_pause_button.disabled = not simulation_active
		_simulation_pause_button.text = tr("fishing.debug.sim_continue") if simulation_active and _rod_system.get_presentation_snapshot().get("simulation_paused", false) else tr("fishing.debug.sim_pause")
	if _simulation_speed_option != null:
		_simulation_speed_option.disabled = not simulation_active
	if _simulation_phase_option != null:
		_simulation_phase_option.disabled = not simulation_active
	if _simulation_seek_button != null:
		_simulation_seek_button.disabled = not simulation_active
	if _simulation_species_option != null:
		_simulation_species_option.disabled = simulation_active or _simulation_species_option.item_count == 0 or not has_species
	if _simulation_length_spin != null:
		_simulation_length_spin.editable = not simulation_active
	if _simulation_seed_spin != null:
		_simulation_seed_spin.editable = not simulation_active
	if _hanging_struggle_intensity_spin != null:
		_hanging_struggle_intensity_spin.editable = simulation_active
		if _rod_system != null:
			_hanging_struggle_intensity_spin.set_value_no_signal(_rod_system.get_hanging_struggle_intensity())
	if _advanced_controls != null:
		_set_advanced_controls_disabled(_advanced_controls, simulation_active)


func _set_advanced_controls_disabled(container: Control, disabled: bool) -> void:
	for child in container.get_children():
		if child is BaseButton:
			(child as BaseButton).disabled = disabled
		elif child is OptionButton:
			(child as OptionButton).disabled = disabled
		elif child is SpinBox:
			(child as SpinBox).editable = not disabled
		if child is Control and child.get_child_count() > 0:
			_set_advanced_controls_disabled(child, disabled)


func _show_feedback(message: String) -> void:
	if _feedback_label != null:
		_feedback_label.text = message


func _result_text(accepted: bool) -> String:
	return tr("fishing.debug.started") if accepted else tr("fishing.debug.action_not_ready")


func _localized_reason(reason: String) -> String:
	var normalized := reason if not reason.is_empty() else "valid"
	var key := "fishing.debug.reason.%s" % normalized
	var translated := tr(key)
	return translated if translated != key else tr("fishing.debug.reason.other")


func _localized_state(state_name: String) -> String:
	var key := "fishing.debug.state.%s" % state_name.to_lower()
	var translated := tr(key)
	return translated if translated != key else tr("fishing.debug.reason.other")
