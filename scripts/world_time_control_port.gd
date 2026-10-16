extends RefCounted
class_name WorldTimeControlPort

## UI-facing contract. Multiplayer implementations can replace the local adapter;
## permission decisions must be enforced by the server, never by F3 visibility.

func get_snapshot() -> Dictionary:
	return {}


func get_authority_label() -> String:
	return "Unavailable"


func can_modify() -> bool:
	return false


func request_set_cycle_time(_hour: int, _minute: int) -> bool:
	return false


func request_set_time_scale(_scale: float) -> bool:
	return false


func request_set_paused(_paused: bool) -> bool:
	return false


func request_set_calendar_override(_year: int, _month: int, _day: int) -> bool:
	return false


func request_clear_calendar_override() -> bool:
	return false
