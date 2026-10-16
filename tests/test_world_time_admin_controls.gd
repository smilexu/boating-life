extends SceneTree

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIME_MANAGER_SCRIPT = preload("res://scripts/world_time_manager.gd")
const UI_SAVE_PATH := "user://world_time_admin_controls_test.json"

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	_run_ui_flow.call_deferred()


func _run_ui_flow() -> void:
	var manager: Node = root.get_node_or_null("WorldTimeManager")
	if manager == null:
		manager = load("res://scripts/world_time_manager.gd").new()
		manager.name = "WorldTimeManager"
		root.add_child(manager)
		await process_frame
	var original_snapshot: Dictionary = manager.call("create_snapshot")
	var main: Node = MAIN_SCENE.instantiate()
	root.add_child(main)
	await process_frame
	var hud := main.get_node("PlayerBoat/BoatHUD")
	var debug_panel := hud.get_node_or_null("DebugPanel") as PanelContainer
	if debug_panel == null:
		push_error("The existing F3 debug panel did not initialize.")
		main.queue_free()
		quit(1)
		return
	_check(not debug_panel.visible, "F3 panel starts hidden")
	var f3 := InputEventKey.new()
	f3.pressed = true
	f3.physical_keycode = KEY_F3
	hud.call("_unhandled_key_input", f3)
	_check(debug_panel.visible, "F3 opens the existing debug panel")
	var time_status := _find_node(hud, "WorldTimeStatus") as Label
	_check(time_status.text.contains("权威来源：Local"), "panel displays Local authority")
	_check(time_status.text.contains("日期调试覆盖：关闭"), "panel displays calendar override status")
	_check(hud.get("_fps_label") is Label, "existing FPS label remains in the same HUD")

	var quick_6 := _find_node(hud, "QuickTime_06_00") as Button
	quick_6.pressed.emit()
	var cycle: Dictionary = manager.call("get_cycle_time_dictionary")
	_check(int(cycle["hour"]) == 6 and int(cycle["minute"]) == 0, "quick time jumps to 06:00 through the control port")
	var scale_option := _find_node(hud, "TimeScaleOption") as OptionButton
	scale_option.item_selected.emit(0)
	_check(is_equal_approx(float(manager.call("get_time_state").time_scale), 1.0), "multiplier option sets 1x through the control port")
	var pause_toggle := _find_node(hud, "PauseToggle") as CheckButton
	pause_toggle.toggled.emit(true)
	_check(bool(manager.call("get_time_state").paused), "pause control pauses the day-cycle")
	pause_toggle.toggled.emit(false)
	_check(not bool(manager.call("get_time_state").paused), "pause control resumes the day-cycle")
	for scale_index in range(1, 5):
		scale_option.item_selected.emit(scale_index)
	var expected_scales := [1.0, 6.0, 12.0, 24.0, 60.0]
	_check(is_equal_approx(float(manager.call("get_time_state").time_scale), expected_scales[4]), "multiplier option supports 6x/12x/24x/60x")
	(_find_node(hud, "DefaultTimeScale") as Button).pressed.emit()
	_check(is_equal_approx(float(manager.call("get_time_state").time_scale), 24.0), "default multiplier button restores 24x")

	var hour_spin := _find_node(hud, "CycleHour") as SpinBox
	var minute_spin := _find_node(hud, "CycleMinute") as SpinBox
	hour_spin.value = 5
	minute_spin.value = 35
	(_find_node(hud, "ApplyCycleTime") as Button).pressed.emit()
	cycle = manager.call("get_cycle_time_dictionary")
	_check(int(cycle["hour"]) == 5 and int(cycle["minute"]) == 35, "manual hour/minute fields apply a time jump")

	var actual_date_before: Dictionary = manager.call("get_real_calendar_date")
	(_find_node(hud, "CalendarYear") as SpinBox).value = 2028
	(_find_node(hud, "CalendarMonth") as SpinBox).value = 2
	(_find_node(hud, "CalendarDay") as SpinBox).value = 29
	(_find_node(hud, "ApplyCalendarOverride") as Button).pressed.emit()
	var state_after_override: WorldTimeState = manager.call("get_time_state")
	_check(state_after_override.calendar_date == {"year": 2028, "month": 2, "day": 29}, "date controls apply a valid leap-day override")
	_check(state_after_override.real_calendar_date == actual_date_before, "date override leaves the real weather calendar unchanged")
	(_find_node(hud, "ClearCalendarOverride") as Button).pressed.emit()
	_check(not bool(manager.call("get_time_state").calendar_override_enabled), "clear button removes the date override")
	_check(manager.call("get_time_state").calendar_date == manager.call("get_real_calendar_date"), "clear button restores the real date")

	hud.call("_unhandled_key_input", f3)
	_check(not debug_panel.visible, "F3 closes the existing debug panel")
	cycle = manager.call("get_cycle_time_dictionary")
	_check(int(cycle["hour"]) == 5 and int(cycle["minute"]) == 35, "time settings remain active when F3 is closed")
	_check(manager.call("save_state", UI_SAVE_PATH), "time setting can be saved after UI changes")
	var restored_manager: Node = TIME_MANAGER_SCRIPT.new()
	restored_manager.set("autosave_enabled", false)
	restored_manager.call("initialize_runtime", false)
	_check(bool(restored_manager.call("load_state", UI_SAVE_PATH)), "saved settings reload into a new manager instance")
	var restored_state: WorldTimeState = restored_manager.call("get_time_state")
	_check(is_equal_approx(restored_state.time_scale, 24.0), "reload restores the multiplier selected through F3")
	var restored_cycle: Dictionary = restored_manager.call("get_cycle_time_dictionary")
	_check(int(restored_cycle["hour"]) == 5 and int(restored_cycle["minute"]) == 35, "reload restores the time selected through F3")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(UI_SAVE_PATH))
	restored_manager.free()
	manager.call("restore_snapshot", original_snapshot)
	main.queue_free()
	await process_frame
	if _failures.is_empty():
		print("World time F3 controls: %d checks passed." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _check(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("FAILED: " + description)


func _find_node(parent: Node, node_name: String) -> Node:
	return parent.find_child(node_name, true, false)

