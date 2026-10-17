class_name CargoLoadoutController
extends Node

## Stores the vessel's manifest and mounts pooled visuals on configured deck slots.
## The BoatController's cargo weight remains the single input to VesselDraftProfile.

signal loadout_changed(snapshot: Dictionary)

const STANDARD_CONTAINER_ASSET_ID: StringName = &"standard_container"

@export_category("References")
@export_node_path("Node3D") var vessel_controller_path := NodePath("..")
@export var slot_paths: Array[NodePath] = []
@export var container_scene: PackedScene
@export var test_cargo_item: CargoItemDefinition

@export_category("Developer test")
@export var developer_tools_enabled := true

var _boat: BoatController
var _slots: Array[Marker3D] = []
var _visuals: Array[Node3D] = []
var _manifest: Array[CargoItemDefinition] = []
var _cargo_instances: Array[Dictionary] = []
var _instance_counter := 1


func _ready() -> void:
	_boat = get_node_or_null(vessel_controller_path) as BoatController
	if _boat == null:
		push_error("CargoLoadoutController: vessel controller was not found.")
		set_process_unhandled_key_input(false)
		return
	var model := get_node_or_null("../VisualRoot/BoatModelFrame/FirstBoatModel")
	_set_visual_layers(model, 2)
	for slot_path in slot_paths:
		var slot := get_node_or_null(slot_path) as Marker3D
		if slot == null:
			push_error("CargoLoadoutController: cargo slot was not found at %s." % slot_path)
			continue
		_slots.append(slot)
		if container_scene != null:
			var visual := container_scene.instantiate() as Node3D
			if visual != null:
				visual.name = "CargoContainerVisual"
				slot.add_child(visual)
				_set_visual_layers(visual, 2)
				_set_visual_tree_visible(visual, false)
				_visuals.append(visual)
	if container_scene == null:
		push_error("CargoLoadoutController: standard cargo container scene is not configured.")
	_sync_vessel_weight()
	_sync_slot_visuals()


func get_loaded_items() -> Array[CargoItemDefinition]:
	return _manifest.duplicate()


func get_cargo_instances_snapshot() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for instance in _cargo_instances:
		result.append(instance.duplicate(true))
	return result


func get_contract_cargo_instances(contract_id: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for instance in _cargo_instances:
		if str(instance.get("contract_id", "")) == contract_id:
			result.append(instance.duplicate(true))
	return result


func get_instance_ids_for_contract(contract_id: String) -> Array[String]:
	var result: Array[String] = []
	for instance in _cargo_instances:
		if str(instance.get("contract_id", "")) == contract_id:
			result.append(str(instance.get("cargo_instance_id", "")))
	return result


func get_uncontracted_cargo_count() -> int:
	var count := 0
	for instance in _cargo_instances:
		if str(instance.get("contract_id", "")).is_empty():
			count += 1
	return count


func get_used_space_units() -> int:
	var used := 0
	for item in _manifest:
		if item != null:
			used += maxi(item.space_units, 0)
	return used


func get_total_weight_kg() -> float:
	var total := 0.0
	for item in _manifest:
		if item != null:
			total += maxf(item.weight_kg, 0.0)
	return total


func try_load_cargo(item: CargoItemDefinition) -> Dictionary:
	if item == null:
		return _result(false, "invalid_item", "未提供货物定义")
	var instance_id := "debug-cargo-%06d" % _instance_counter
	_instance_counter += 1
	var result := try_load_contract_items("", [item], PackedStringArray([instance_id]))
	if not bool(result.get("accepted", false)):
		return result
	return _result(true, "loaded", "已装载 %s" % item.display_name)


func try_load_contract_items(contract_id: String, items: Array[CargoItemDefinition], instance_ids: PackedStringArray) -> Dictionary:
	if _boat == null or _boat.draft_profile == null:
		return _result(false, "missing_vessel_profile", "船型货舱配置未提供")
	if items.is_empty() or items.size() != instance_ids.size():
		return _result(false, "invalid_manifest", "货物清单或实例 ID 无效")
	var added_space := 0
	var added_weight := 0.0
	var requested_visual_count := 0
	var seen_ids := {}
	for index in range(items.size()):
		var item := items[index]
		if item == null or item.space_units <= 0 or not is_finite(item.weight_kg) or item.weight_kg < 0.0:
			return _result(false, "invalid_item_data", "货物重量或空间数据无效")
		var instance_id := str(instance_ids[index])
		if instance_id.is_empty() or seen_ids.has(instance_id) or _has_instance_id(instance_id):
			return _result(false, "duplicate_instance_id", "货物实例 ID 重复或为空")
		seen_ids[instance_id] = true
		added_space += item.space_units
		added_weight += item.weight_kg
		if item.visual_asset_id == STANDARD_CONTAINER_ASSET_ID:
			requested_visual_count += 1
	if get_used_space_units() + added_space > _boat.draft_profile.cargo_capacity_space_units:
		return _result(false, "space_limit", "货舱空间不足")
	if get_total_weight_kg() + added_weight > _boat.draft_profile.max_cargo_weight_kg:
		return _result(false, "weight_limit", "超过船舶最大载重量")
	var free_slots := _get_free_slot_ids()
	if requested_visual_count > mini(free_slots.size(), _visuals.size()):
		return _result(false, "no_visual_slot", "没有足够的可用货柜挂载点")
	var cargo_instance_ids: Array[String] = []
	var visual_slot_index := 0
	for index in range(items.size()):
		var item := items[index]
		var assigned_slot_id := ""
		if item.visual_asset_id == STANDARD_CONTAINER_ASSET_ID:
			assigned_slot_id = free_slots[visual_slot_index]
			visual_slot_index += 1
		_manifest.append(item)
		_cargo_instances.append({
			"cargo_instance_id": str(instance_ids[index]),
			"contract_id": contract_id,
			"cargo_item_id": str(item.cargo_id),
			"display_name": item.display_name,
			"weight_kg": item.weight_kg,
			"space_units": item.space_units,
			"visual_asset_id": str(item.visual_asset_id),
			"assigned_slot_id": assigned_slot_id,
		})
		cargo_instance_ids.append(str(instance_ids[index]))
	_commit_loadout()
	return {
		"accepted": true,
		"code": "loaded",
		"message": "货物清单已装载",
		"cargo_instance_ids": cargo_instance_ids,
		"used_space_units": get_used_space_units(),
		"cargo_weight_kg": get_total_weight_kg(),
	}


func try_unload_last_cargo() -> Dictionary:
	if _manifest.is_empty():
		return _result(false, "empty", "当前没有货物")
	if not str(_cargo_instances.back().get("contract_id", "")).is_empty():
		return _result(false, "contract_cargo_requires_delivery", "合同货物必须通过目的港交付")
	_manifest.pop_back()
	_cargo_instances.pop_back()
	_commit_loadout()
	return _result(true, "unloaded", "已卸载一件货物")


func remove_contract_cargo(contract_id: String) -> Dictionary:
	var removed_ids: Array[String] = []
	for index in range(_cargo_instances.size() - 1, -1, -1):
		if str(_cargo_instances[index].get("contract_id", "")) != contract_id:
			continue
		removed_ids.append(str(_cargo_instances[index].get("cargo_instance_id", "")))
		_cargo_instances.remove_at(index)
		_manifest.remove_at(index)
	if removed_ids.is_empty():
		return _result(false, "cargo_not_found", "船上没有该合同的货物")
	_commit_loadout()
	return {"accepted": true, "code": "unloaded", "removed_instance_ids": removed_ids}


func restore_cargo_instances(snapshot: Array) -> bool:
	if _boat == null or _boat.draft_profile == null:
		return false
	var next_manifest: Array[CargoItemDefinition] = []
	var next_instances: Array[Dictionary] = []
	var used_slots := {}
	var seen_ids := {}
	var total_space := 0
	var total_weight := 0.0
	for value in snapshot:
		if not value is Dictionary:
			return false
		var entry: Dictionary = value
		var instance_id := str(entry.get("cargo_instance_id", ""))
		var cargo_item_id := str(entry.get("cargo_item_id", ""))
		var weight := float(entry.get("weight_kg", NAN))
		var space := int(entry.get("space_units", 0))
		var visual_id := str(entry.get("visual_asset_id", ""))
		var slot_id := str(entry.get("assigned_slot_id", ""))
		if instance_id.is_empty() or cargo_item_id.is_empty() or seen_ids.has(instance_id):
			return false
		if not is_finite(weight) or weight < 0.0 or space <= 0:
			return false
		seen_ids[instance_id] = true
		if visual_id == str(STANDARD_CONTAINER_ASSET_ID):
			if not _slot_id_exists(slot_id) or used_slots.has(slot_id):
				return false
			used_slots[slot_id] = true
		elif not slot_id.is_empty():
			if not _slot_id_exists(slot_id) or used_slots.has(slot_id):
				return false
			used_slots[slot_id] = true
		var item := CargoItemDefinition.new()
		item.cargo_id = StringName(cargo_item_id)
		item.display_name = str(entry.get("display_name", "货物"))
		item.weight_kg = weight
		item.space_units = space
		item.visual_asset_id = StringName(visual_id)
		next_manifest.append(item)
		next_instances.append(entry.duplicate(true))
		total_space += space
		total_weight += weight
	if total_space > _boat.draft_profile.cargo_capacity_space_units or total_weight > _boat.draft_profile.max_cargo_weight_kg:
		return false
	if used_slots.size() > mini(_slots.size(), _visuals.size()):
		return false
	_manifest = next_manifest
	_cargo_instances = next_instances
	_commit_loadout()
	return true


func cycle_debug_test_loadout() -> Dictionary:
	if not developer_tools_enabled:
		return _result(false, "developer_tools_disabled", "开发测试装载已关闭")
	if test_cargo_item == null:
		return _result(false, "missing_test_item", "测试货物未配置")
	if _has_contract_cargo():
		return _result(false, "contract_cargo_loaded", "合同货物在船时不能切换开发测试货柜")
	var next_count := (_manifest.size() + 1) % (mini(_slots.size(), 2) + 1)
	_manifest.clear()
	_cargo_instances.clear()
	if next_count == 0:
		_commit_loadout()
		return _result(true, "test_loadout_changed", "开发测试装载：0 个货柜")
	for _index in range(next_count):
		var result := try_load_cargo(test_cargo_item)
		if not bool(result.get("accepted", false)):
			_manifest.clear()
			_commit_loadout()
			return result
	return _result(true, "test_loadout_changed", "开发测试装载：%d 个货柜" % _manifest.size())


func set_debug_test_loadout(container_count: int) -> Dictionary:
	if not developer_tools_enabled:
		return _result(false, "developer_tools_disabled", "开发测试装载已关闭")
	if test_cargo_item == null:
		return _result(false, "missing_test_item", "测试货物未配置")
	if _has_contract_cargo():
		return _result(false, "contract_cargo_loaded", "合同货物在船时不能覆盖开发测试装载")
	var requested_count := clampi(container_count, 0, mini(_slots.size(), 2))
	_manifest.clear()
	_cargo_instances.clear()
	if requested_count == 0:
		_commit_loadout()
		return _result(true, "test_loadout_changed", "开发测试装载：0 个货柜")
	for _index in range(requested_count):
		var result := try_load_cargo(test_cargo_item)
		if not bool(result.get("accepted", false)):
			_manifest.clear()
			_commit_loadout()
			return result
	return _result(true, "test_loadout_changed", "开发测试装载：%d 个货柜" % _manifest.size())


func get_debug_snapshot() -> Dictionary:
	var profile: VesselDraftProfile = _boat.draft_profile if _boat != null else null
	var dimensions := _get_model_dimensions_m()
	var buoyancy := _boat.get_node_or_null("VisualRoot") if _boat != null else null
	return {
		"vessel_name": profile.vessel_display_name if profile != null else "未配置船型",
		"model_dimensions_m": dimensions,
		"container_count": _manifest.size(),
		"contract_cargo_instance_count": _get_contract_cargo_count(),
		"used_space_units": get_used_space_units(),
		"space_capacity_units": profile.cargo_capacity_space_units if profile != null else 0,
		"cargo_weight_kg": get_total_weight_kg(),
		"controller_cargo_weight_kg": _boat.current_cargo_weight_kg if _boat != null else 0.0,
		"max_cargo_weight_kg": profile.max_cargo_weight_kg if profile != null else 0.0,
		"current_draft_m": _boat.get_current_draft_m() if _boat != null else -1.0,
		"visual_cargo_sink_m": float(buoyancy.call("get_visual_cargo_sink_m")) if buoyancy != null else 0.0,
		"slot_count": _slots.size(),
		"visible_container_count": _get_visible_container_count(),
	}


func _unhandled_key_input(event: InputEvent) -> void:
	if not developer_tools_enabled or not (OS.has_feature("editor") or OS.has_feature("debug")):
		return
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	if not event.is_action_pressed("cargo_debug_cycle"):
		return
	var result := cycle_debug_test_loadout()
	if bool(result.get("accepted", false)):
		print("[CargoLoadout] %s · %d kg · 吃水 %.2f m" % [
			str(result.get("message", "")), get_total_weight_kg(), _boat.get_current_draft_m(),
		])
	else:
		push_warning("[CargoLoadout] %s" % str(result.get("message", "装载失败")))
	get_viewport().set_input_as_handled()


func _commit_loadout() -> void:
	_sync_vessel_weight()
	_sync_slot_visuals()
	loadout_changed.emit(get_debug_snapshot())


func _sync_vessel_weight() -> void:
	if _boat != null:
		_boat.current_cargo_weight_kg = get_total_weight_kg()


func _sync_slot_visuals() -> void:
	for visual in _visuals:
		_set_visual_tree_visible(visual, false)
	for instance in _cargo_instances:
		if str(instance.get("visual_asset_id", "")) != str(STANDARD_CONTAINER_ASSET_ID):
			continue
		var slot_index := _find_slot_index(str(instance.get("assigned_slot_id", "")))
		if slot_index >= 0 and slot_index < _visuals.size():
			_set_visual_tree_visible(_visuals[slot_index], true)


func _get_free_slot_ids() -> Array[String]:
	var used := {}
	for instance in _cargo_instances:
		var slot_id := str(instance.get("assigned_slot_id", ""))
		if not slot_id.is_empty():
			used[slot_id] = true
	var result: Array[String] = []
	for slot in _slots:
		if is_instance_valid(slot) and not used.has(slot.name):
			result.append(str(slot.name))
	return result


func _slot_id_exists(slot_id: String) -> bool:
	return _find_slot_index(slot_id) >= 0


func _find_slot_index(slot_id: String) -> int:
	for index in range(_slots.size()):
		if is_instance_valid(_slots[index]) and str(_slots[index].name) == slot_id:
			return index
	return -1


func _has_instance_id(instance_id: String) -> bool:
	for instance in _cargo_instances:
		if str(instance.get("cargo_instance_id", "")) == instance_id:
			return true
	return false


func _has_contract_cargo() -> bool:
	for instance in _cargo_instances:
		if not str(instance.get("contract_id", "")).is_empty():
			return true
	return false


func _get_contract_cargo_count() -> int:
	var count := 0
	for instance in _cargo_instances:
		if not str(instance.get("contract_id", "")).is_empty():
			count += 1
	return count


func _get_visible_container_count() -> int:
	var visible_count := 0
	for visual in _visuals:
		if is_instance_valid(visual) and _has_visible_geometry(visual):
			visible_count += 1
	return visible_count


func _set_visual_tree_visible(node: Node, visible: bool) -> void:
	if node is VisualInstance3D:
		(node as VisualInstance3D).visible = visible
	for child in node.get_children():
		_set_visual_tree_visible(child, visible)


func _set_visual_layers(node: Node, layer_mask: int) -> void:
	if node == null:
		return
	if node is VisualInstance3D:
		(node as VisualInstance3D).layers = layer_mask
	for child in node.get_children():
		_set_visual_layers(child, layer_mask)


func _has_visible_geometry(node: Node) -> bool:
	if node is VisualInstance3D and (node as VisualInstance3D).visible:
		return true
	for child in node.get_children():
		if _has_visible_geometry(child):
			return true
	return false


func _get_model_dimensions_m() -> Vector3:
	var model_frame := get_node_or_null("../VisualRoot/BoatModelFrame") as Node3D
	var model := get_node_or_null("../VisualRoot/BoatModelFrame/FirstBoatModel") as Node3D
	if model_frame == null or model == null:
		return _boat.get_vessel_dimensions_m() if _boat != null else Vector3.ZERO
	var state := {"has_bounds": false, "bounds": AABB()}
	_collect_model_bounds(model, model_frame.transform, state)
	if not bool(state["has_bounds"]):
		return _boat.get_vessel_dimensions_m() if _boat != null else Vector3.ZERO
	var bounds: AABB = state["bounds"]
	# The corrected local boat forward axis is -Z, its beam is X, and Y is up.
	return Vector3(bounds.size.z, bounds.size.x, bounds.size.y)


func _collect_model_bounds(node: Node, parent_transform: Transform3D, state: Dictionary) -> void:
	var transform := parent_transform
	if node is Node3D:
		transform = parent_transform * (node as Node3D).transform
	if node is MeshInstance3D:
		var mesh := (node as MeshInstance3D).mesh
		if mesh != null:
			var transformed := _transform_aabb(mesh.get_aabb(), transform)
			if not bool(state["has_bounds"]):
				state["bounds"] = transformed
			else:
				var existing_bounds: AABB = state["bounds"]
				state["bounds"] = existing_bounds.merge(transformed)
			state["has_bounds"] = true
	for child in node.get_children():
		_collect_model_bounds(child, transform, state)


func _transform_aabb(bounds: AABB, transform: Transform3D) -> AABB:
	var first := transform * bounds.position
	var result := AABB(first, Vector3.ZERO)
	for x in [bounds.position.x, bounds.end.x]:
		for y in [bounds.position.y, bounds.end.y]:
			for z in [bounds.position.z, bounds.end.z]:
				result = result.expand(transform * Vector3(x, y, z))
	return result


func _result(accepted: bool, code: String, message: String) -> Dictionary:
	return {
		"accepted": accepted,
		"code": code,
		"message": message,
		"container_count": _manifest.size(),
		"used_space_units": get_used_space_units(),
		"cargo_weight_kg": get_total_weight_kg(),
		"current_draft_m": _boat.get_current_draft_m() if _boat != null else -1.0,
	}
