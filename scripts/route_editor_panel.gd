class_name RouteEditorPanel
extends VBoxContainer

## Developer-only editor for gameplay route data. Screen positions are never
## stored: map clicks are converted back through the active GeoReference.

const OP_ADD := "ADD"
const OP_INSERT := "INSERT"
const OP_DRAG := "DRAG"

var _route_manager: PortRouteManager
var _map_canvas: FishResourceMapCanvas
var _georeference: GeoReference
var _open := false
var _route: RouteDefinition
var _validation_hit_world_position := Vector3.ZERO
var _validation_hit_label := ""
var _has_validation_hit := false
var _selected_waypoint_index := -1
var _operation := OP_ADD
var _drag_dirty := false
var _refreshing := false

var _route_option: OptionButton
var _origin_option: OptionButton
var _destination_option: OptionButton
var _route_id_edit: LineEdit
var _route_name_edit: LineEdit
var _operation_option: OptionButton
var _waypoint_list: ItemList
var _waypoint_name_edit: LineEdit
var _waypoint_radius_input: SpinBox
var _waypoint_speed_input: SpinBox
var _summary_label: Label
var _message_label: Label


func configure(route_manager: PortRouteManager, map_canvas: FishResourceMapCanvas, georeference: GeoReference) -> void:
	_route_manager = route_manager
	_map_canvas = map_canvas
	_georeference = georeference
	if is_node_ready():
		_refresh_routes()


func set_editor_open(open: bool) -> void:
	_open = open and _is_development_build()
	visible = _open
	if _map_canvas != null:
		_map_canvas.set_route_editing(_route, _georeference, _open, _operation, _selected_waypoint_index)
		if not _open:
			_map_canvas.set_route_overlay(_route, _georeference)
	if _open:
		_refresh_routes()
		_update_summary()


func is_editor_open() -> bool:
	return _open


func get_selected_route() -> RouteDefinition:
	return _route


func _ready() -> void:
	if not _is_development_build():
		visible = false
		return
	_build_ui()
	if _map_canvas != null:
		_map_canvas.route_edit_map_clicked.connect(_on_map_clicked)
		_map_canvas.route_waypoint_selected.connect(_on_map_waypoint_selected)
		_map_canvas.route_waypoint_moved.connect(_on_map_waypoint_moved)
	if _route_manager != null and not _route_manager.routes_changed.is_connected(_on_routes_changed):
		_route_manager.routes_changed.connect(_on_routes_changed)
	_refresh_routes()


func _build_ui() -> void:
	add_theme_constant_override("separation", 5)
	var heading := Label.new()
	heading.text = "开发者航线编辑器"
	heading.add_theme_color_override("font_color", Color("#a6e2d8"))
	heading.add_theme_font_size_override("font_size", 16)
	add_child(heading)

	_route_option = OptionButton.new()
	_route_option.item_selected.connect(_on_route_option_selected)
	add_child(_route_option)

	var identity_row := HBoxContainer.new()
	add_child(identity_row)
	_route_id_edit = LineEdit.new()
	_route_id_edit.placeholder_text = "route_id"
	_route_id_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	identity_row.add_child(_route_id_edit)
	var new_button := Button.new()
	new_button.text = "新建"
	new_button.pressed.connect(_create_route)
	identity_row.add_child(new_button)

	_route_name_edit = LineEdit.new()
	_route_name_edit.placeholder_text = "航线名称"
	_route_name_edit.text_submitted.connect(func(_text: String) -> void: _apply_route_name())
	add_child(_route_name_edit)
	var rename_button := Button.new()
	rename_button.text = "应用航线名称"
	rename_button.pressed.connect(_apply_route_name)
	add_child(rename_button)

	var ports_row := HBoxContainer.new()
	add_child(ports_row)
	_origin_option = OptionButton.new()
	_origin_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_origin_option.item_selected.connect(_on_origin_port_selected)
	ports_row.add_child(_origin_option)
	_destination_option = OptionButton.new()
	_destination_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_destination_option.item_selected.connect(_on_destination_port_selected)
	ports_row.add_child(_destination_option)
	_populate_port_options()

	_operation_option = OptionButton.new()
	_operation_option.add_item("地图点击：追加航点")
	_operation_option.add_item("地图点击：插入到所选航点后")
	_operation_option.add_item("拖动所选航点")
	_operation_option.item_selected.connect(_on_operation_selected)
	add_child(_operation_option)

	var list_heading := Label.new()
	list_heading.text = "中间航路点（端点由港口定义）"
	list_heading.add_theme_color_override("font_color", Color("#dce9dc"))
	add_child(list_heading)
	_waypoint_list = ItemList.new()
	_waypoint_list.custom_minimum_size = Vector2(0.0, 116.0)
	_waypoint_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_waypoint_list.allow_reselect = true
	_waypoint_list.item_selected.connect(_on_waypoint_item_selected)
	add_child(_waypoint_list)

	var waypoint_parameters := HBoxContainer.new()
	add_child(waypoint_parameters)
	var radius_column := VBoxContainer.new()
	radius_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	waypoint_parameters.add_child(radius_column)
	var radius_label := Label.new()
	radius_label.text = "到达半径 m"
	radius_column.add_child(radius_label)
	_waypoint_radius_input = SpinBox.new()
	_waypoint_radius_input.min_value = 1.0
	_waypoint_radius_input.max_value = 5000.0
	_waypoint_radius_input.step = 1.0
	radius_column.add_child(_waypoint_radius_input)
	var speed_column := VBoxContainer.new()
	speed_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	waypoint_parameters.add_child(speed_column)
	var speed_label := Label.new()
	speed_label.text = "速度限制 m/s（-1=无）"
	speed_column.add_child(speed_label)
	_waypoint_speed_input = SpinBox.new()
	_waypoint_speed_input.min_value = -1.0
	_waypoint_speed_input.max_value = 30.0
	_waypoint_speed_input.step = 0.1
	_waypoint_speed_input.value = -1.0
	speed_column.add_child(_waypoint_speed_input)
	var apply_parameters_button := Button.new()
	apply_parameters_button.text = "应用航点参数"
	apply_parameters_button.pressed.connect(_apply_selected_waypoint_parameters)
	add_child(apply_parameters_button)

	var waypoint_name_row := HBoxContainer.new()
	add_child(waypoint_name_row)
	_waypoint_name_edit = LineEdit.new()
	_waypoint_name_edit.placeholder_text = "所选航点名称"
	_waypoint_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	waypoint_name_row.add_child(_waypoint_name_edit)
	var rename_waypoint_button := Button.new()
	rename_waypoint_button.text = "改名"
	rename_waypoint_button.pressed.connect(_rename_selected_waypoint)
	waypoint_name_row.add_child(rename_waypoint_button)

	var order_row := HBoxContainer.new()
	add_child(order_row)
	var up_button := Button.new()
	up_button.text = "上移"
	up_button.pressed.connect(func() -> void: _move_selected_waypoint(-1))
	order_row.add_child(up_button)
	var down_button := Button.new()
	down_button.text = "下移"
	down_button.pressed.connect(func() -> void: _move_selected_waypoint(1))
	order_row.add_child(down_button)
	var delete_button := Button.new()
	delete_button.text = "删除所选"
	delete_button.pressed.connect(_delete_selected_waypoint)
	order_row.add_child(delete_button)

	_summary_label = Label.new()
	_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary_label.add_theme_color_override("font_color", Color("#c3d9d0"))
	add_child(_summary_label)

	var persistence_row := HBoxContainer.new()
	add_child(persistence_row)
	_add_button(persistence_row, "保存草稿", _save_draft)
	_add_button(persistence_row, "加载草稿", _load_draft)
	_add_button(persistence_row, "导出 JSON", _export_route)
	var validation_row := HBoxContainer.new()
	add_child(validation_row)
	_add_button(validation_row, "校验路线", _validate_route)
	_add_button(validation_row, "标记游戏内已验证", _approve_route)

	_message_label = Label.new()
	_message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message_label.add_theme_color_override("font_color", Color("#e7c98a"))
	_message_label.text = "开发草稿保存于 user://route_drafts。自动校验不代表海事安全。"
	add_child(_message_label)


func _add_button(parent: HBoxContainer, text: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(callback)
	parent.add_child(button)


func _populate_port_options() -> void:
	if _origin_option == null or _destination_option == null or _route_manager == null:
		return
	_origin_option.clear()
	_destination_option.clear()
	for port in _route_manager.get_registered_ports():
		_origin_option.add_item("%s · %s" % [port.display_name, port.port_id])
		_origin_option.set_item_metadata(_origin_option.item_count - 1, str(port.port_id))
		_destination_option.add_item("%s · %s" % [port.display_name, port.port_id])
		_destination_option.set_item_metadata(_destination_option.item_count - 1, str(port.port_id))
	if _destination_option.item_count > 1:
		_destination_option.select(1)


func _refresh_routes(preferred_route_id: String = "") -> void:
	if _route_option == null or _route_manager == null:
		return
	_refreshing = true
	_route_option.clear()
	var routes := _route_manager.get_routes()
	var selected_index := -1
	for route in routes:
		_route_option.add_item("%s · %s" % [route.display_name, route.validation_status])
		_route_option.set_item_metadata(_route_option.item_count - 1, str(route.route_id))
		if str(route.route_id) == preferred_route_id or (preferred_route_id.is_empty() and _route == route):
			selected_index = _route_option.item_count - 1
	if selected_index < 0 and _route_option.item_count > 0:
		selected_index = 0
	if selected_index >= 0:
		_route_option.select(selected_index)
		_route = _route_manager.get_route(str(_route_option.get_item_metadata(selected_index)))
	_refreshing = false
	if _route != null:
		_route_id_edit.text = str(_route.route_id)
		_route_name_edit.text = _route.display_name
		_sync_port_options()
	_refresh_waypoint_list()
	_refresh_map()
	_update_summary()


func _sync_port_options() -> void:
	if _route == null:
		return
	var was_refreshing := _refreshing
	_refreshing = true
	for index in range(_origin_option.item_count):
		if str(_origin_option.get_item_metadata(index)) == str(_route.origin_port_id):
			_origin_option.select(index)
		if str(_destination_option.get_item_metadata(index)) == str(_route.destination_port_id):
			_destination_option.select(index)
	_refreshing = was_refreshing


func _on_route_option_selected(index: int) -> void:
	if _refreshing or index < 0:
		return
	_clear_validation_hit()
	_route = _route_manager.get_route(str(_route_option.get_item_metadata(index)))
	_selected_waypoint_index = -1
	_route_dirty = false
	_refresh_routes(str(_route.route_id) if _route != null else "")


var _route_dirty := false
var _route_change_signal_pending := false


func _on_operation_selected(index: int) -> void:
	_operation = [OP_ADD, OP_INSERT, OP_DRAG][clampi(index, 0, 2)]
	_refresh_map()


func _create_route() -> void:
	if _route_manager == null or _origin_option.item_count < 2:
		_show_message("当前没有两个可用港口")
		return
	var route_id := _route_id_edit.text.strip_edges()
	var route_name := _route_name_edit.text.strip_edges()
	var origin_id := str(_origin_option.get_item_metadata(_origin_option.selected))
	var destination_id := str(_destination_option.get_item_metadata(_destination_option.selected))
	var created := _route_manager.create_route_draft(origin_id, destination_id, route_id, route_name)
	if created == null:
		_show_message("新建失败：请确认 ID 唯一、起终港不同且路线运行在开发版本")
		return
	_clear_validation_hit()
	_route = created
	_selected_waypoint_index = 0 if not created.waypoints.is_empty() else -1
	_route_dirty = false
	_refresh_routes(str(created.route_id))
	_show_message("已创建草稿。请在地图上添加中间航点并校验路线。")


func _on_origin_port_selected(index: int) -> void:
	if _refreshing or _route == null or index < 0:
		return
	_update_route_ports(str(_origin_option.get_item_metadata(index)), str(_route.destination_port_id))


func _on_destination_port_selected(index: int) -> void:
	if _refreshing or _route == null or index < 0:
		return
	_update_route_ports(str(_route.origin_port_id), str(_destination_option.get_item_metadata(index)))


func _update_route_ports(origin_port_id: String, destination_port_id: String) -> void:
	if _route != null and str(_route.origin_port_id) == origin_port_id and str(_route.destination_port_id) == destination_port_id:
		return
	if origin_port_id == destination_port_id:
		_show_message("起点港和终点港必须不同。")
		_sync_port_options()
		return
	var result := _route_manager.update_route_ports(str(_route.route_id), origin_port_id, destination_port_id)
	if not bool(result.get("accepted", false)):
		_show_message(str(result.get("reason", "港口设置更新失败。")))
		_sync_port_options()
		return
	_clear_validation_hit()
	_route_dirty = true
	_refresh_routes(str(_route.route_id))
	_show_message("起终点港已更新，航线已标记为待验证。")


func _apply_route_name() -> void:
	if _route == null:
		return
	var new_name := _route_name_edit.text.strip_edges()
	if new_name.is_empty() or _route.display_name == new_name:
		return
	_mark_route_edited()
	_route.display_name = new_name
	_refresh_routes(str(_route.route_id))
	_show_message("名称已更新，路线需要重新验证。")


func _on_waypoint_item_selected(index: int) -> void:
	_selected_waypoint_index = index
	if _route != null and index >= 0 and index < _route.waypoints.size():
		_load_selected_waypoint_fields()
	_refresh_map()


func _on_map_waypoint_selected(index: int) -> void:
	_selected_waypoint_index = index
	_drag_dirty = false
	_refresh_waypoint_list()
	_refresh_map()


func _on_map_clicked(world_position: Vector3, is_inside_map: bool, is_land: bool) -> void:
	if not _open or _route == null:
		return
	if not is_inside_map:
		_show_message("地图外或当前地图范围外，未添加航点。")
		return
	if is_land:
		_show_message("该位置属于已知陆地，未添加航点。")
		return
	if _operation == OP_DRAG:
		_show_message("拖动模式：请直接按住地图上的中间航点拖动。")
		return
	if _operation == OP_ADD or _route.waypoints.is_empty():
		_append_waypoint(world_position)
	else:
		_insert_waypoint(world_position)


func _append_waypoint(world_position: Vector3) -> void:
	var waypoint := _waypoint_from_world_position(world_position, _route.waypoints.size())
	_mark_route_edited()
	_route.waypoints.append(waypoint)
	_selected_waypoint_index = _route.waypoints.size() - 1
	_after_waypoint_edit("已在航线末端追加航点。")


func _insert_waypoint(world_position: Vector3) -> void:
	var insert_index := clampi(_selected_waypoint_index + 1, 0, _route.waypoints.size())
	var waypoint := _waypoint_from_world_position(world_position, insert_index)
	_mark_route_edited()
	_route.waypoints.insert(insert_index, waypoint)
	_selected_waypoint_index = insert_index
	_after_waypoint_edit("已在所选航点之后插入航点。")


func _waypoint_from_world_position(world_position: Vector3, index: int) -> RouteWaypoint:
	var waypoint := RouteWaypoint.new()
	waypoint.waypoint_id = StringName("%s_wp_%03d" % [str(_route.route_id), _next_waypoint_number()])
	waypoint.display_name = "航路点 %02d" % (index + 1)
	var geodetic := _georeference.world_to_geodetic(Vector3(world_position.x, 0.0, world_position.z))
	waypoint.latitude_deg = geodetic.x
	waypoint.longitude_deg = geodetic.y
	return waypoint


func _next_waypoint_number() -> int:
	var highest := _route.waypoints.size()
	for waypoint in _route.waypoints:
		var suffix := str(waypoint.waypoint_id).get_slice("_wp_", 1)
		if suffix.is_valid_int():
			highest = maxi(highest, int(suffix))
	return highest + 1


func _on_map_waypoint_moved(index: int, world_position: Vector3, is_inside_map: bool, is_land: bool) -> void:
	if not _open or _route == null or index < 0 or index >= _route.waypoints.size():
		return
	if not is_inside_map or is_land:
		return
	if not _drag_dirty:
		_mark_route_edited()
		_drag_dirty = true
	var geodetic := _georeference.world_to_geodetic(Vector3(world_position.x, 0.0, world_position.z))
	_route.waypoints[index].latitude_deg = geodetic.x
	_route.waypoints[index].longitude_deg = geodetic.y
	_update_summary()
	refresh_waypoint_list_only()
	_refresh_map()


func refresh_waypoint_list_only() -> void:
	if _waypoint_list == null or _route == null:
		return
	_refreshing = true
	_waypoint_list.clear()
	for index in range(_route.waypoints.size()):
		var waypoint := _route.waypoints[index]
		_waypoint_list.add_item("%02d  %s" % [index + 1, waypoint.display_name])
	if _selected_waypoint_index >= 0 and _selected_waypoint_index < _route.waypoints.size():
		_waypoint_list.select(_selected_waypoint_index)
	_refreshing = false


func _rename_selected_waypoint() -> void:
	if _route == null or _selected_waypoint_index < 0 or _selected_waypoint_index >= _route.waypoints.size():
		return
	var new_name := _waypoint_name_edit.text.strip_edges()
	if new_name.is_empty():
		_show_message("航点名称不能为空。")
		return
	if _route.waypoints[_selected_waypoint_index].display_name == new_name:
		return
	_mark_route_edited()
	_route.waypoints[_selected_waypoint_index].display_name = new_name
	_after_waypoint_edit("航点名称已更新。")


func _apply_selected_waypoint_parameters() -> void:
	if _route == null or _selected_waypoint_index < 0 or _selected_waypoint_index >= _route.waypoints.size():
		_show_message("请先选择一个中间航点。")
		return
	var waypoint := _route.waypoints[_selected_waypoint_index]
	var radius := _waypoint_radius_input.value
	var speed_limit := _waypoint_speed_input.value
	if is_equal_approx(waypoint.arrival_radius_m, radius) and is_equal_approx(waypoint.optional_speed_limit_mps, speed_limit):
		return
	_mark_route_edited()
	waypoint.arrival_radius_m = radius
	waypoint.optional_speed_limit_mps = speed_limit
	_after_waypoint_edit("航点半径与速度限制已更新。")


func _load_selected_waypoint_fields() -> void:
	if _route == null or _selected_waypoint_index < 0 or _selected_waypoint_index >= _route.waypoints.size():
		return
	var waypoint := _route.waypoints[_selected_waypoint_index]
	_waypoint_name_edit.text = waypoint.display_name
	_waypoint_radius_input.value = waypoint.arrival_radius_m
	_waypoint_speed_input.value = waypoint.optional_speed_limit_mps


func _move_selected_waypoint(direction: int) -> void:
	if _route == null or _selected_waypoint_index < 0 or _selected_waypoint_index >= _route.waypoints.size():
		return
	var target_index := _selected_waypoint_index + direction
	if target_index < 0 or target_index >= _route.waypoints.size():
		return
	_mark_route_edited()
	var waypoint := _route.waypoints[_selected_waypoint_index]
	_route.waypoints[_selected_waypoint_index] = _route.waypoints[target_index]
	_route.waypoints[target_index] = waypoint
	_selected_waypoint_index = target_index
	_after_waypoint_edit("航点顺序已更新。")


func _delete_selected_waypoint() -> void:
	if _route == null or _selected_waypoint_index < 0 or _selected_waypoint_index >= _route.waypoints.size():
		_show_message("请先选择一个中间航点。")
		return
	_mark_route_edited()
	_route.waypoints.remove_at(_selected_waypoint_index)
	_selected_waypoint_index = mini(_selected_waypoint_index, _route.waypoints.size() - 1)
	_after_waypoint_edit("所选航点已删除。")


func _after_waypoint_edit(message: String) -> void:
	_refresh_waypoint_list()
	_refresh_map()
	_update_summary()
	_show_message(message)


func _mark_route_edited() -> void:
	if _route == null:
		return
	_clear_validation_hit()
	if not _route_dirty:
		_route.invalidate_for_edit()
		_route_dirty = true
	_schedule_route_change_notification()


func _schedule_route_change_notification() -> void:
	if _route_change_signal_pending or _route_manager == null:
		return
	_route_change_signal_pending = true
	call_deferred("_emit_route_change_notification")


func _emit_route_change_notification() -> void:
	_route_change_signal_pending = false
	if is_instance_valid(_route_manager):
		_route_manager.routes_changed.emit()


func _save_draft() -> void:
	if _route == null:
		_show_message("请先选择一条路线。")
		return
	var result := _route_manager.save_route_draft(str(_route.route_id))
	_show_message("已保存：%s" % result.get("path", "") if bool(result.get("accepted", false)) else str(result.get("reason", "保存失败")))
	_route_dirty = false


func _load_draft() -> void:
	if _route == null:
		_show_message("请先选择要加载的路线 ID。")
		return
	var route_id := str(_route.route_id)
	var result := _route_manager.load_route_draft(route_id)
	if bool(result.get("accepted", false)):
		_clear_validation_hit()
		_route = result.get("route") as RouteDefinition
		_selected_waypoint_index = -1
		_route_dirty = false
		_refresh_routes(route_id)
		_show_message("已从 user://route_drafts 加载草稿。")
	else:
		_show_message(str(result.get("reason", "加载失败")))


func _export_route() -> void:
	if _route == null:
		return
	var result := _route_manager.export_route_draft(str(_route.route_id))
	_show_message("已导出：%s" % result.get("path", "") if bool(result.get("accepted", false)) else str(result.get("reason", "导出失败")))


func _validate_route() -> void:
	if _route == null:
		return
	var result := _route_manager.validate_route(str(_route.route_id))
	var validation_hit: Variant = result.get("validation_hit_world_position", null)
	if validation_hit is Vector3:
		_validation_hit_world_position = validation_hit
		_validation_hit_label = "陆地掩膜命中" if str(result.get("validation_hit_kind", "")) == "land" else "浅水命中"
		_has_validation_hit = true
	else:
		_clear_validation_hit()
	var parts := PackedStringArray()
	for error in result.get("errors", PackedStringArray()):
		parts.append("错误：%s" % error)
	for warning in result.get("warnings", PackedStringArray()):
		parts.append("提示：%s" % warning)
	var saved := _route_manager.save_route_draft(str(_route.route_id))
	if bool(saved.get("accepted", false)):
		parts.append("校验状态已保存到本机航线草稿。")
	else:
		parts.append("校验状态未能持久化：%s" % saved.get("reason", "写入失败"))
	parts.append("航线仍为待人工复核状态；自动校验不构成海事安全认证。")
	_route_dirty = true
	_refresh_routes(str(_route.route_id))
	_show_message("\n".join(parts))


func _approve_route() -> void:
	if _route == null:
		return
	var result := _route_manager.mark_route_validated_for_gameplay(str(_route.route_id))
	if bool(result.get("accepted", false)):
		_route_dirty = false
		_refresh_routes(str(_route.route_id))
		_show_message("已标记并保存为游戏内验证路线，可供普通自动巡航使用。此状态不是现实海事安全认证。")
	else:
		_show_message(str(result.get("reason", "无法批准路线")))


func _refresh_waypoint_list() -> void:
	refresh_waypoint_list_only()
	if _route != null and _selected_waypoint_index >= 0 and _selected_waypoint_index < _route.waypoints.size():
		_load_selected_waypoint_fields()
	elif _waypoint_name_edit != null:
		_waypoint_name_edit.clear()


func _refresh_map() -> void:
	if _map_canvas != null:
		_map_canvas.set_route_overlay(_route, _georeference)
		_map_canvas.set_route_editing(_route, _georeference, _open, _operation, _selected_waypoint_index)
		_map_canvas.set_route_validation_hit(_validation_hit_world_position, _validation_hit_label, _has_validation_hit)


func _clear_validation_hit() -> void:
	_has_validation_hit = false
	_validation_hit_label = ""
	if _map_canvas != null:
		_map_canvas.set_route_validation_hit(_validation_hit_world_position, "", false)


func _update_summary() -> void:
	if _summary_label == null:
		return
	if _route == null or _route_manager == null:
		_summary_label.text = "未选择路线。"
		return
	var summary := _route_manager.get_route_summary(_route, 0.0)
	var total_distance := float(summary.get("distance_m", 0.0))
	_summary_label.text = "%s · %d 个中间点\n距离 %.2f km · 版本 %d\n状态 %s%s\n接入时仍按路线方向前进。未知水深需保守核查。" % [
		_route.route_id, _route.waypoints.size(), total_distance / 1000.0, _route.updated_version,
		_route.validation_status, " · 可巡航" if _route.cruise_allowed else " · 禁止巡航",
	]


func _on_routes_changed() -> void:
	var route_id := str(_route.route_id) if _route != null else ""
	_refresh_routes(route_id)


func _show_message(message: String) -> void:
	if _message_label != null:
		_message_label.text = message


func _is_development_build() -> bool:
	return OS.has_feature("editor") or OS.has_feature("debug")
