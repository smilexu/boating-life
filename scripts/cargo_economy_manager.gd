class_name CargoEconomyManager
extends Node

## Local authority for freight contracts and EUR balance. UI calls this API;
## cargo weight still flows exclusively through CargoLoadoutController.

signal state_changed
signal operation_message(message: String, success: bool)

const SAVE_SCHEMA_VERSION := 1
const LIVE_SAVE_PATH := "user://cargo_economy_state.json"
const DEVELOPMENT_SAVE_PATH := "user://cargo_economy_development.json"
const ACTIVE_CONTRACT_LIMIT := 2
const INITIAL_BALANCE_CENTS := 50000
const STATUS_AVAILABLE := "AVAILABLE"
const STATUS_ACCEPTED := "ACCEPTED"
const STATUS_IN_TRANSIT := "IN_TRANSIT"
const STATUS_COMPLETED := "COMPLETED"

@export_category("References")
@export_node_path("Node") var harbor_path := NodePath("../MalmoHarbor")
@export_node_path("Node3D") var boat_path := NodePath("../PlayerBoat/MotionRoot")
@export_node_path("Node") var cargo_loadout_path := NodePath("../PlayerBoat/MotionRoot/CargoLoadout")
@export var developer_tools_enabled := true

var _harbor: Node
var _boat: BoatController
var _loadout: CargoLoadoutController
var _definitions: Dictionary = {}
var _contract_states: Dictionary = {}
var _settled_contract_ids: Array[String] = []
var _wallet := EuroWallet.new()
var _instance_sequence := 1
var _save_path_override_for_testing := ""
var _last_error := ""
var _last_operation := ""


func _ready() -> void:
	_harbor = get_node_or_null(harbor_path)
	_boat = get_node_or_null(boat_path) as BoatController
	_loadout = get_node_or_null(cargo_loadout_path) as CargoLoadoutController
	_load_contract_definitions()
	_initialize_contract_states()
	if _harbor == null or _boat == null or _loadout == null:
		push_error("CargoEconomyManager requires a harbour, vessel and CargoLoadoutController.")
		return
	var save_path := _resolve_save_path()
	_recover_backup_if_needed(save_path)
	if FileAccess.file_exists(save_path):
		if not load_state(save_path):
			var backup_path := save_path + ".bak"
			if FileAccess.file_exists(backup_path) and load_state(backup_path):
				push_warning("Cargo economy recovered from its previous complete backup.")
			else:
				push_warning("Cargo economy save was invalid; using a clean local state.")


func get_balance_cents() -> int:
	return _wallet.get_balance_cents()


func get_balance_text() -> String:
	return _wallet.format_balance()


func get_contract_definition(contract_id: String) -> CargoContractDefinition:
	return _definitions.get(contract_id) as CargoContractDefinition


func get_contract_cargo_instances(contract_id: String) -> Array[Dictionary]:
	return _loadout.get_contract_cargo_instances(contract_id) if _loadout != null else []


func get_port_display_name(port_id: String) -> String:
	if _harbor != null and _harbor.has_method("get_service_config"):
		var port_config := _harbor.call("get_service_config") as PortServiceConfig
		if port_config != null and str(port_config.port_id) == port_id:
			return port_config.display_name
	for definition_value in _definitions.values():
		var definition := definition_value as CargoContractDefinition
		if definition == null:
			continue
		if str(definition.origin_port_id) == port_id and not definition.origin_port_display_name.is_empty():
			return definition.origin_port_display_name
		if str(definition.destination_port_id) == port_id and not definition.destination_port_display_name.is_empty():
			return definition.destination_port_display_name
	return port_id


func get_contract_state(contract_id: String) -> Dictionary:
	return (_contract_states.get(contract_id, {}) as Dictionary).duplicate(true)


func get_contract_cards(port_id: String, status_filter: String = "") -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for contract_id_variant in _definitions:
		var contract_id := str(contract_id_variant)
		var definition := _definitions[contract_id] as CargoContractDefinition
		var contract_status := str(_contract_states.get(contract_id, {}).get("status", STATUS_AVAILABLE))
		if status_filter != "" and contract_status != status_filter:
			continue
		if contract_status == STATUS_AVAILABLE and str(definition.origin_port_id) != port_id:
			continue
		result.append({"definition": definition, "state": get_contract_state(contract_id)})
	return result


func get_available_contracts(port_id: String) -> Array[Dictionary]:
	return get_contract_cards(port_id, STATUS_AVAILABLE)


func get_active_contracts() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for contract_id_variant in _definitions:
		var contract_id := str(contract_id_variant)
		var status := str(_contract_states.get(contract_id, {}).get("status", STATUS_AVAILABLE))
		if status == STATUS_ACCEPTED or status == STATUS_IN_TRANSIT:
			result.append({"definition": _definitions[contract_id], "state": get_contract_state(contract_id)})
	return result


func get_completed_contracts() -> Array[Dictionary]:
	return get_contract_cards("", STATUS_COMPLETED)


func accept_contract(contract_id: String, harbor: Node = null) -> Dictionary:
	var definition := get_contract_definition(contract_id)
	if definition == null:
		return _result(false, "unknown_contract", "找不到这份合同")
	var active_harbor := harbor if harbor != null else _harbor
	var location := _get_harbor_context(active_harbor)
	if not bool(location.get("at_port", false)) or str(location.get("port_id", "")) != str(definition.origin_port_id):
		return _result(false, "wrong_origin", "必须进入或停泊在起运港 %s 才能接单" % _get_port_display_name(str(definition.origin_port_id)))
	var state: Dictionary = _contract_states.get(contract_id, {})
	if str(state.get("status", STATUS_AVAILABLE)) != STATUS_AVAILABLE:
		return _result(false, "already_taken", "这份任务已被接受或完成")
	if _get_active_count() >= ACTIVE_CONTRACT_LIMIT:
		return _result(false, "contract_limit", "同时进行的货运任务最多为 %d 份" % ACTIVE_CONTRACT_LIMIT)
	var data_check := _validate_definition(definition)
	if not bool(data_check.get("valid", false)):
		return _result(false, "invalid_contract", str(data_check.get("reason", "合同数据无效")))
	if _loadout == null:
		return _result(false, "missing_loadout", "货舱系统尚未准备好")
	if _loadout.get_uncontracted_cargo_count() > 0:
		return _result(false, "unassigned_cargo_onboard", "请先清除未关联合同的测试货物，再接取运输任务")

	var previous_loadout := _loadout.get_cargo_instances_snapshot()
	var instance_ids := PackedStringArray()
	for _item in definition.cargo_items:
		instance_ids.append(_next_cargo_instance_id(contract_id))
	var load_result := _loadout.try_load_contract_items(contract_id, definition.cargo_items, instance_ids)
	if not bool(load_result.get("accepted", false)):
		return _result(false, str(load_result.get("code", "load_failed")), str(load_result.get("message", "货物装载失败")))

	_contract_states[contract_id] = {
		"status": STATUS_IN_TRANSIT,
		"cargo_instance_ids": load_result.get("cargo_instance_ids", []).duplicate(),
		"completed_unix": 0,
	}
	if not save_state():
		_contract_states[contract_id] = state
		_loadout.restore_cargo_instances(previous_loadout)
		return _result(false, "save_failed", "存档失败，接单和装货已回滚")
	_last_operation = "accepted:%s" % contract_id
	state_changed.emit()
	operation_message.emit("已接单：%s" % definition.display_name, true)
	return _result(true, "accepted", "已接单并装载 %s" % definition.display_name)


func deliver_contract(contract_id: String, harbor: Node = null) -> Dictionary:
	var location := _get_harbor_context(harbor if harbor != null else _harbor)
	return _complete_delivery(contract_id, str(location.get("port_id", "")), bool(location.get("at_port", false)))


func can_deliver_contract(contract_id: String, harbor: Node = null) -> Dictionary:
	var location := _get_harbor_context(harbor if harbor != null else _harbor)
	var validation := _validate_delivery(contract_id, str(location.get("port_id", "")), bool(location.get("at_port", false)))
	return {"can_deliver": bool(validation.get("valid", false)), "reason": str(validation.get("reason", ""))}


func simulate_delivery_for_development(contract_id: String) -> Dictionary:
	if not _is_developer_build() or not developer_tools_enabled:
		return _result(false, "developer_only", "该交货模拟仅在开发构建中可用")
	var definition := get_contract_definition(contract_id)
	if definition == null:
		return _result(false, "unknown_contract", "找不到这份合同")
	# This synthetic context is passed to the exact delivery validator/settlement
	# path. The live harbour's port_id/docked state is never changed.
	var result := _complete_delivery(
		contract_id,
		str(definition.destination_port_id),
		true,
		"开发测试交货完成（未修改当前港口定位）"
	)
	if bool(result.get("accepted", false)):
		_last_operation = "dev_simulated_delivery:%s" % contract_id
	return result


func simulate_first_active_delivery_for_development() -> Dictionary:
	if not _is_developer_build() or not developer_tools_enabled:
		return _result(false, "developer_only", "该交货模拟仅在开发构建中可用")
	var active := get_active_contracts()
	if active.is_empty():
		return _result(false, "no_active_contract", "没有可测试交货的进行中合同")
	var definition := active[0]["definition"] as CargoContractDefinition
	return simulate_delivery_for_development(str(definition.contract_id))


func save_state(path: String = "") -> bool:
	var resolved_path := path if not path.is_empty() else _resolve_save_path()
	_recover_backup_if_needed(resolved_path)
	var payload := _make_save_payload()
	var temporary_path := resolved_path + ".tmp"
	var backup_path := resolved_path + ".bak"
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		_last_error = "无法创建存档临时文件：%s" % FileAccess.get_open_error()
		return false
	file.store_string(JSON.stringify(payload, "\t"))
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		_last_error = "写入货运存档失败：%s" % error_string(write_error)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary_path))
		return false
	var final_absolute := ProjectSettings.globalize_path(resolved_path)
	var temp_absolute := ProjectSettings.globalize_path(temporary_path)
	var backup_absolute := ProjectSettings.globalize_path(backup_path)
	if FileAccess.file_exists(backup_path):
		DirAccess.remove_absolute(backup_absolute)
	var had_previous := FileAccess.file_exists(resolved_path)
	if had_previous and DirAccess.rename_absolute(final_absolute, backup_absolute) != OK:
		_last_error = "无法轮换旧存档"
		DirAccess.remove_absolute(temp_absolute)
		return false
	if DirAccess.rename_absolute(temp_absolute, final_absolute) != OK:
		_last_error = "无法提交新存档"
		if had_previous:
			DirAccess.rename_absolute(backup_absolute, final_absolute)
		DirAccess.remove_absolute(temp_absolute)
		return false
	if had_previous and FileAccess.file_exists(backup_path):
		DirAccess.remove_absolute(backup_absolute)
	_last_error = ""
	return true


func load_state(path: String = "") -> bool:
	var resolved_path := path if not path.is_empty() else _resolve_save_path()
	if not FileAccess.file_exists(resolved_path):
		return false
	var file := FileAccess.open(resolved_path, FileAccess.READ)
	if file == null:
		_last_error = "无法读取存档：%s" % FileAccess.get_open_error()
		return false
	var parser := JSON.new()
	var parse_error := parser.parse(file.get_as_text())
	file.close()
	if parse_error != OK or not parser.data is Dictionary:
		_last_error = "存档不是有效 JSON 对象"
		return false
	var payload: Dictionary = parser.data
	if str(payload.get("save_format", "")) != "cargo_economy_state" or int(payload.get("schema_version", -1)) != SAVE_SCHEMA_VERSION:
		_last_error = "不支持的货运存档版本"
		return false
	if str(payload.get("currency", "")) != "EUR":
		_last_error = "存档货币不是 EUR"
		return false
	var balance_variant: Variant = payload.get("wallet_balance_cents", null)
	if not (balance_variant is int or balance_variant is float) or not is_finite(float(balance_variant)):
		_last_error = "存档余额无效"
		return false
	var balance := int(balance_variant)
	if balance < 0 or balance > 2147483647 or not is_equal_approx(float(balance_variant), float(balance)):
		_last_error = "存档余额超出有效范围"
		return false
	if str(payload.get("vessel_id", "")) != _get_current_vessel_id():
		_last_error = "存档船型与当前船舶不一致"
		return false
	var cargo_value: Variant = payload.get("cargo_instances", null)
	var saved_states_value: Variant = payload.get("contracts", null)
	var settled_value: Variant = payload.get("settled_contract_ids", null)
	if not cargo_value is Array or not saved_states_value is Dictionary or not settled_value is Array:
		_last_error = "存档缺少合同或货物数据"
		return false
	var cargo_instances: Array = cargo_value
	var saved_states: Dictionary = saved_states_value
	var settled_ids: Array[String] = []
	var settled_seen := {}
	for value in settled_value:
		var settled_id := str(value)
		if settled_id.is_empty() or settled_seen.has(settled_id):
			_last_error = "存档结算合同 ID 无效或重复"
			return false
		settled_seen[settled_id] = true
		settled_ids.append(settled_id)
	var candidate_states := _build_candidate_states(saved_states, settled_ids)
	if candidate_states.is_empty() and not _definitions.is_empty():
		_last_error = "合同状态无效"
		return false
	var active_in_save := 0
	for saved_state_value in candidate_states.values():
		var status := str(saved_state_value.get("status", ""))
		if status == STATUS_ACCEPTED or status == STATUS_IN_TRANSIT:
			active_in_save += 1
	if active_in_save > ACTIVE_CONTRACT_LIMIT:
		_last_error = "存档进行中合同超过限制"
		return false
	var total_weight := _sum_snapshot_weight(cargo_instances)
	if not is_finite(total_weight) or total_weight < 0.0:
		_last_error = "存档货物重量无效"
		return false
	var saved_weight := float(payload.get("current_cargo_weight_kg", -1.0))
	if not is_finite(saved_weight) or absf(saved_weight - total_weight) > 0.01:
		_last_error = "存档载重与货物清单不一致"
		return false
	if not _validate_saved_contract_cargo(candidate_states, cargo_instances):
		_last_error = "存档合同与船上货物关联不一致"
		return false
	if _loadout == null or not _loadout.restore_cargo_instances(cargo_instances):
		_last_error = "存档货物无法安全恢复"
		return false
	if not _wallet.restore_balance_cents(balance):
		_last_error = "存档余额无法恢复"
		_loadout.restore_cargo_instances([])
		return false
	_contract_states = candidate_states
	_settled_contract_ids = settled_ids
	_instance_sequence = maxi(int(payload.get("next_cargo_instance_sequence", 1)), 1)
	state_changed.emit()
	_last_error = ""
	return true


func get_debug_snapshot() -> Dictionary:
	return {
		"wallet_balance_cents": get_balance_cents(),
		"wallet_balance_text": get_balance_text(),
		"vessel_id": _get_current_vessel_id(),
		"active_contract_count": _get_active_count(),
		"active_contract_limit": ACTIVE_CONTRACT_LIMIT,
		"cargo_instances": _loadout.get_cargo_instances_snapshot() if _loadout != null else [],
		"settled_contract_ids": _settled_contract_ids.duplicate(),
		"save_path": _resolve_save_path(),
		"last_error": _last_error,
		"last_operation": _last_operation,
		"development_mode": _is_developer_build(),
	}


func set_save_path_override_for_testing(path: String) -> bool:
	if not _is_developer_build() or path.is_empty():
		return false
	_save_path_override_for_testing = path
	return true


func reset_runtime_state_for_testing() -> bool:
	if not _is_developer_build() or _loadout == null:
		return false
	if not _loadout.restore_cargo_instances([]):
		return false
	_wallet.restore_balance_cents(INITIAL_BALANCE_CENTS)
	_settled_contract_ids.clear()
	_contract_states.clear()
	_initialize_contract_states()
	_instance_sequence = 1
	state_changed.emit()
	return true


func _complete_delivery(contract_id: String, port_id: String, at_port: bool, success_message_override: String = "") -> Dictionary:
	var validation := _validate_delivery(contract_id, port_id, at_port)
	if not bool(validation.get("valid", false)):
		return _result(false, str(validation.get("code", "delivery_rejected")), str(validation.get("reason", "无法交货")))
	var definition := get_contract_definition(contract_id)
	var previous_loadout := _loadout.get_cargo_instances_snapshot()
	var previous_state: Dictionary = _contract_states[contract_id].duplicate(true)
	var previous_balance := _wallet.get_balance_cents()
	var previous_settled := _settled_contract_ids.duplicate()
	var unload_result := _loadout.remove_contract_cargo(contract_id)
	if not bool(unload_result.get("accepted", false)):
		return _result(false, "unload_failed", "合同货物无法完整卸载")
	if _settled_contract_ids.has(contract_id):
		_loadout.restore_cargo_instances(previous_loadout)
		return _result(false, "already_settled", "该合同已经结算")
	if not _wallet.credit_reward(definition.reward_cents):
		_loadout.restore_cargo_instances(previous_loadout)
		return _result(false, "wallet_limit", "余额超出当前钱包可保存范围")
	_settled_contract_ids.append(contract_id)
	_contract_states[contract_id] = {"status": STATUS_COMPLETED, "cargo_instance_ids": [], "completed_unix": Time.get_unix_time_from_system()}
	if not save_state():
		_wallet.restore_balance_cents(previous_balance)
		_settled_contract_ids = previous_settled
		_contract_states[contract_id] = previous_state
		_loadout.restore_cargo_instances(previous_loadout)
		return _result(false, "save_failed", "存档失败，交货和奖励已回滚")
	_last_operation = "delivered:%s" % contract_id
	state_changed.emit()
	var message := success_message_override if not success_message_override.is_empty() else "已交付 %s · 奖励 %s" % [definition.display_name, definition.get_reward_eur_text()]
	operation_message.emit(message, true)
	return _result(true, "completed", message)


func _validate_delivery(contract_id: String, port_id: String, at_port: bool) -> Dictionary:
	var definition := get_contract_definition(contract_id)
	if definition == null:
		return {"valid": false, "code": "unknown_contract", "reason": "找不到这份合同"}
	if not at_port:
		return {"valid": false, "code": "not_at_port", "reason": "必须进入或停泊在港口后才能交货"}
	if port_id != str(definition.destination_port_id):
		return {"valid": false, "code": "wrong_destination", "reason": "当前港口不是合同目的港 %s" % _get_port_display_name(str(definition.destination_port_id))}
	var state: Dictionary = _contract_states.get(contract_id, {})
	if str(state.get("status", "")) != STATUS_IN_TRANSIT:
		return {"valid": false, "code": "not_in_transit", "reason": "合同不处于运输中"}
	if _settled_contract_ids.has(contract_id):
		return {"valid": false, "code": "already_settled", "reason": "该合同已经结算"}
	if _loadout == null or not _contract_cargo_matches(contract_id, definition, state):
		return {"valid": false, "code": "cargo_missing_or_mismatched", "reason": "合同对应货物缺失或重量、空间、关联信息不匹配"}
	return {"valid": true}


func _contract_cargo_matches(contract_id: String, definition: CargoContractDefinition, state: Dictionary) -> bool:
	var cargo_ids_value: Variant = state.get("cargo_instance_ids", null)
	if not cargo_ids_value is Array or cargo_ids_value.size() != definition.cargo_items.size():
		return false
	var actual := _loadout.get_contract_cargo_instances(contract_id)
	return _contract_cargo_matches_entries(contract_id, definition, cargo_ids_value, actual)


func _contract_cargo_matches_entries(contract_id: String, definition: CargoContractDefinition, expected_instance_ids: Array, actual: Array) -> bool:
	if actual.size() != definition.cargo_items.size() or expected_instance_ids.size() != actual.size():
		return false
	var expected_id_set := {}
	for id_value in expected_instance_ids:
		var id := str(id_value)
		if id.is_empty() or expected_id_set.has(id):
			return false
		expected_id_set[id] = true
	var actual_id_set := {}
	for instance in actual:
		var id := str(instance.get("cargo_instance_id", ""))
		if not expected_id_set.has(id) or actual_id_set.has(id) or str(instance.get("contract_id", "")) != contract_id:
			return false
		actual_id_set[id] = true
	var used := PackedByteArray()
	used.resize(actual.size())
	for expected_item in definition.cargo_items:
		var found := false
		for index in range(actual.size()):
			if used[index] != 0:
				continue
			var instance: Dictionary = actual[index]
			if str(instance.get("cargo_item_id", "")) != str(expected_item.cargo_id):
				continue
			if not is_equal_approx(float(instance.get("weight_kg", -1.0)), expected_item.weight_kg):
				continue
			if int(instance.get("space_units", -1)) != expected_item.space_units:
				continue
			if str(instance.get("visual_asset_id", "")) != str(expected_item.visual_asset_id):
				continue
			used[index] = 1
			found = true
			break
		if not found:
			return false
	return true


func _load_contract_definitions() -> void:
	var definitions: Array[CargoContractDefinition] = []
	if _harbor != null and _harbor.has_method("get_service_config"):
		var config := _harbor.call("get_service_config") as PortServiceConfig
		if config != null:
			definitions = config.cargo_contract_definitions
	for definition in definitions:
		if definition == null or str(definition.contract_id).is_empty():
			continue
		var contract_id := str(definition.contract_id)
		if _definitions.has(contract_id):
			push_warning("CargoEconomyManager: duplicate contract ID %s was ignored." % contract_id)
			continue
		_definitions[contract_id] = definition


func _initialize_contract_states() -> void:
	for contract_id_variant in _definitions:
		var contract_id := str(contract_id_variant)
		if not _contract_states.has(contract_id):
			_contract_states[contract_id] = {"status": STATUS_AVAILABLE, "cargo_instance_ids": [], "completed_unix": 0}


func _validate_definition(definition: CargoContractDefinition) -> Dictionary:
	if definition.cargo_items.is_empty() or definition.required_space <= 0 or definition.reward_cents <= 0:
		return {"valid": false, "reason": "合同缺少货物、空间或奖励配置"}
	var space := 0
	var weight := 0.0
	for item in definition.cargo_items:
		if item == null or item.cargo_id.is_empty() or item.space_units <= 0 or not is_finite(item.weight_kg) or item.weight_kg < 0.0:
			return {"valid": false, "reason": "合同货物配置无效"}
		space += item.space_units
		weight += item.weight_kg
	if space != definition.required_space or not is_equal_approx(weight, definition.total_weight_kg):
		return {"valid": false, "reason": "合同总重量或空间与货物清单不一致"}
	return {"valid": true}


func _get_active_count() -> int:
	var count := 0
	for state_value in _contract_states.values():
		if state_value is Dictionary:
			var status := str(state_value.get("status", ""))
			if status == STATUS_ACCEPTED or status == STATUS_IN_TRANSIT:
				count += 1
	return count


func _get_harbor_context(harbor: Node) -> Dictionary:
	if harbor == null:
		return {"at_port": false, "port_id": ""}
	var at_port := bool(harbor.call("is_docked")) if harbor.has_method("is_docked") else false
	if not at_port and harbor.has_method("is_port_entered"):
		at_port = bool(harbor.call("is_port_entered"))
	var port_value: Variant = harbor.get("port_id")
	return {"at_port": at_port, "port_id": str(port_value) if port_value != null else ""}


func _get_port_display_name(port_id: String) -> String:
	return get_port_display_name(port_id)


func _get_current_vessel_id() -> String:
	if _boat != null and _boat.draft_profile != null and not str(_boat.draft_profile.vessel_id).is_empty():
		return str(_boat.draft_profile.vessel_id)
	return "unknown_vessel"


func _next_cargo_instance_id(contract_id: String) -> String:
	var result := "%s-cargo-%06d" % [contract_id, _instance_sequence]
	_instance_sequence += 1
	return result


func _make_save_payload() -> Dictionary:
	return {
		"save_format": "cargo_economy_state",
		"schema_version": SAVE_SCHEMA_VERSION,
		"currency": "EUR",
		"wallet_balance_cents": _wallet.get_balance_cents(),
		"vessel_id": _get_current_vessel_id(),
		"contracts": _contract_states.duplicate(true),
		"cargo_instances": _loadout.get_cargo_instances_snapshot() if _loadout != null else [],
		"settled_contract_ids": _settled_contract_ids.duplicate(),
		"current_cargo_weight_kg": _loadout.get_total_weight_kg() if _loadout != null else 0.0,
		"next_cargo_instance_sequence": _instance_sequence,
	}


func _build_candidate_states(saved_states: Dictionary, settled_ids: Array[String]) -> Dictionary:
	var candidate: Dictionary = {}
	for contract_id_variant in _definitions:
		var contract_id := str(contract_id_variant)
		var saved_value: Variant = saved_states.get(contract_id, {"status": STATUS_AVAILABLE, "cargo_instance_ids": [], "completed_unix": 0})
		if not saved_value is Dictionary:
			return {}
		var status := str(saved_value.get("status", ""))
		if not [STATUS_AVAILABLE, STATUS_ACCEPTED, STATUS_IN_TRANSIT, STATUS_COMPLETED].has(status):
			return {}
		var ids_value: Variant = saved_value.get("cargo_instance_ids", [])
		if not ids_value is Array:
			return {}
		var ids: Array[String] = []
		for id_value in ids_value:
			if str(id_value).is_empty():
				return {}
			ids.append(str(id_value))
		candidate[contract_id] = {
			"status": status,
			"cargo_instance_ids": ids,
			"completed_unix": int(saved_value.get("completed_unix", 0)),
		}
		if status == STATUS_COMPLETED and not settled_ids.has(contract_id):
			return {}
	for settled_id in settled_ids:
		if not _definitions.has(settled_id) or str(candidate[settled_id]["status"]) != STATUS_COMPLETED:
			return {}
	return candidate


func _validate_saved_contract_cargo(states: Dictionary, cargo_instances: Array) -> bool:
	var instance_ids := {}
	for item_value in cargo_instances:
		if not item_value is Dictionary:
			return false
		var instance_id := str(item_value.get("cargo_instance_id", ""))
		if instance_id.is_empty() or instance_ids.has(instance_id):
			return false
		instance_ids[instance_id] = item_value
	for contract_id_variant in states:
		var contract_id := str(contract_id_variant)
		var state: Dictionary = states[contract_id]
		var status := str(state["status"])
		var ids: Array = state["cargo_instance_ids"]
		if status == STATUS_AVAILABLE or status == STATUS_COMPLETED:
			if not ids.is_empty():
				return false
			continue
		var definition := get_contract_definition(contract_id)
		if definition == null or ids.size() != definition.cargo_items.size():
			return false
		for instance_id_variant in ids:
			var instance_id := str(instance_id_variant)
			if not instance_ids.has(instance_id) or str(instance_ids[instance_id].get("contract_id", "")) != contract_id:
				return false
	for item_value in cargo_instances:
		var contract_id := str(item_value.get("contract_id", ""))
		if contract_id.is_empty():
			continue
		if not states.has(contract_id) or not [STATUS_ACCEPTED, STATUS_IN_TRANSIT].has(str(states[contract_id]["status"])):
			return false
	for contract_id_variant in states:
		var contract_id := str(contract_id_variant)
		var state: Dictionary = states[contract_id]
		if str(state["status"]) != STATUS_ACCEPTED and str(state["status"]) != STATUS_IN_TRANSIT:
			continue
		var contract_cargo: Array = []
		for item_value in cargo_instances:
			if str(item_value.get("contract_id", "")) == contract_id:
				contract_cargo.append(item_value)
		if not _contract_cargo_matches_entries(contract_id, get_contract_definition(contract_id), state["cargo_instance_ids"], contract_cargo):
			return false
	return true


func _sum_snapshot_weight(cargo_instances: Array) -> float:
	var total := 0.0
	for item_value in cargo_instances:
		if not item_value is Dictionary:
			return NAN
		var weight := float(item_value.get("weight_kg", NAN))
		if not is_finite(weight) or weight < 0.0:
			return NAN
		total += weight
	return total


func _resolve_save_path() -> String:
	if not _save_path_override_for_testing.is_empty():
		return _save_path_override_for_testing
	return DEVELOPMENT_SAVE_PATH if _is_developer_build() and developer_tools_enabled else LIVE_SAVE_PATH


func _recover_backup_if_needed(path: String) -> void:
	var backup_path := path + ".bak"
	if FileAccess.file_exists(path) or not FileAccess.file_exists(backup_path):
		return
	var restore_error := DirAccess.rename_absolute(ProjectSettings.globalize_path(backup_path), ProjectSettings.globalize_path(path))
	if restore_error != OK:
		push_warning("Cargo economy could not restore its previous save snapshot.")


func _is_developer_build() -> bool:
	return OS.has_feature("editor") or OS.has_feature("debug")


func _result(accepted: bool, code: String, message: String) -> Dictionary:
	_last_error = "" if accepted else message
	return {
		"accepted": accepted,
		"code": code,
		"message": message,
		"balance_cents": get_balance_cents(),
		"balance_text": get_balance_text(),
		"active_contract_count": _get_active_count(),
	}
