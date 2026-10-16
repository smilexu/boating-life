extends "res://scripts/world_time_control_port.gd"
class_name LocalWorldTimeControl

## Single-player development adapter. Replace this adapter at the HUD boundary for multiplayer.

var _manager: Node


func _init(manager: Node = null) -> void:
	_manager = manager


func get_snapshot() -> Dictionary:
	if _manager == null:
		return {}
	return _manager.call("get_authoritative_state")


func get_authority_label() -> String:
	if _manager == null:
		return "Unavailable"
	var source := str(_manager.get("authority_name"))
	return "Server" if source.to_lower().contains("server") else "Local"


func can_modify() -> bool:
	# Current Sea Prototype is local developer mode. A network adapter must consult
	# authenticated server permissions rather than infer permission from this panel.
	return _manager != null


func request_set_cycle_time(hour: int, minute: int) -> bool:
	return bool(_manager.call("set_day_cycle_time", hour, minute, 0.0)) if _manager != null else false


func request_set_time_scale(scale: float) -> bool:
	return bool(_manager.call("set_time_scale", scale)) if _manager != null else false


func request_set_paused(paused: bool) -> bool:
	if _manager == null:
		return false
	if paused:
		_manager.call("pause_time")
	else:
		_manager.call("resume_time")
	return true


func request_set_calendar_override(year: int, month: int, day: int) -> bool:
	return bool(_manager.call("set_calendar_date", year, month, day)) if _manager != null else false


func request_clear_calendar_override() -> bool:
	if _manager == null:
		return false
	_manager.call("clear_calendar_override")
	return true
