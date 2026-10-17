class_name PortServiceController
extends CanvasLayer

## Reusable overlay for port services. It owns only menu state and presentation;
## docking validation and vessel movement stay in the harbour/boat controllers.

enum PortState { SAILING, DOCKED, PORT_MENU }

signal state_changed(state_name: String)

@export_node_path("Node3D") var harbor_path := NodePath("..")
@export_node_path("Node3D") var boat_path := NodePath("../../PlayerBoat/MotionRoot")
@export_node_path("Node3D") var camera_rig_path := NodePath("../../PlayerBoat/FollowCameraRig")
@export_node_path("Node") var economy_manager_path := NodePath("../../CargoEconomyManager")

const MENU_LAYER := 24
const SERVICE_CARGO := "cargo_exchange"
const SERVICE_FUEL := "fuel"
const SERVICE_SHIPYARD := "shipyard"
const SERVICE_MARKET := "ship_market"

var _state := PortState.SAILING
var _harbor: Node
var _boat: BoatController
var _camera_rig: Node3D
var _economy_manager: CargoEconomyManager
var _config: PortServiceConfig
var _overlay: ColorRect
var _panel: PanelContainer
var _port_title: Label
var _status_label: Label
var _body: VBoxContainer
var _footer: HBoxContainer
var _current_service_id := ""


func _ready() -> void:
	layer = MENU_LAYER
	_harbor = get_node_or_null(harbor_path)
	_boat = get_node_or_null(boat_path) as BoatController
	_camera_rig = get_node_or_null(camera_rig_path) as Node3D
	_economy_manager = get_node_or_null(economy_manager_path) as CargoEconomyManager
	if _harbor == null or _boat == null:
		push_error("PortServiceController requires its harbour and boat references.")
		set_process_unhandled_input(false)
		return
	if _harbor.has_method("get_service_config"):
		_config = _harbor.call("get_service_config") as PortServiceConfig
	if _config == null:
		push_error("PortServiceController requires a PortServiceConfig on its harbour.")
		set_process_unhandled_input(false)
		return
	if _harbor.has_signal("port_docked"):
		_harbor.connect("port_docked", _on_port_docked)
	if _harbor.has_signal("port_undocked"):
		_harbor.connect("port_undocked", _on_port_undocked)
	if _harbor.has_signal("port_services_requested"):
		_harbor.connect("port_services_requested", _on_port_services_requested)
	if _economy_manager != null and _economy_manager.has_signal("state_changed"):
		_economy_manager.state_changed.connect(_on_economy_state_changed)
	_build_ui()
	_set_state(PortState.SAILING)


func is_menu_open() -> bool:
	return _state == PortState.PORT_MENU


func is_docked() -> bool:
	return _state != PortState.SAILING


func get_state_name() -> String:
	match _state:
		PortState.SAILING:
			return "SAILING"
		PortState.DOCKED:
			return "DOCKED"
		PortState.PORT_MENU:
			return "PORT_MENU"
	return "SAILING"


func get_current_service_id() -> String:
	return _current_service_id


func get_menu_visible() -> bool:
	return _overlay != null and _overlay.visible


func open_main_menu() -> bool:
	if _harbor == null or not bool(_harbor.call("is_docked")):
		return false
	_current_service_id = ""
	_populate_main_page()
	_overlay.visible = true
	_set_state(PortState.PORT_MENU)
	_set_ui_input_active(true)
	var first_service_button := _body.find_child("ServiceButton_*", true, false) as Button
	if first_service_button != null:
		first_service_button.grab_focus()
	return true


func close_menu() -> void:
	if not is_menu_open():
		return
	_current_service_id = ""
	_overlay.visible = false
	_set_state(PortState.DOCKED)
	_set_ui_input_active(false)


func return_to_main_menu() -> void:
	if not is_menu_open():
		return
	_current_service_id = ""
	_populate_main_page()


func open_service(service_id: String) -> bool:
	if not is_menu_open() or not _config.available_services.has(service_id):
		return false
	_current_service_id = service_id
	_populate_service_page(service_id)
	return true


func _unhandled_key_input(event: InputEvent) -> void:
	if not is_menu_open() or not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.physical_keycode != KEY_ESCAPE and event.keycode != KEY_ESCAPE:
		return
	if not _current_service_id.is_empty():
		return_to_main_menu()
	else:
		close_menu()
	get_viewport().set_input_as_handled()


func _on_port_docked(_port_id: String) -> void:
	_set_state(PortState.DOCKED)
	open_main_menu()


func _on_port_undocked(_port_id: String) -> void:
	_current_service_id = ""
	if _overlay != null:
		_overlay.visible = false
	_set_ui_input_active(false)
	_set_state(PortState.SAILING)


func _on_port_services_requested(_port_id: String) -> void:
	open_main_menu()


func _set_state(next_state: int) -> void:
	if _state == next_state:
		return
	_state = next_state
	state_changed.emit(get_state_name())


func _set_ui_input_active(active: bool) -> void:
	if active:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		if _camera_rig != null and _camera_rig.has_method("release_mouse_look"):
			_camera_rig.call("release_mouse_look")
	else:
		get_viewport().gui_release_focus()
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _build_ui() -> void:
	_overlay = ColorRect.new()
	_overlay.name = "PortServiceOverlay"
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.color = Color(0.008, 0.02, 0.03, 0.42)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.visible = false
	add_child(_overlay)

	_panel = PanelContainer.new()
	_panel.name = "PortServicePanel"
	_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_panel.offset_left = -360.0
	_panel.offset_top = -275.0
	_panel.offset_right = 360.0
	_panel.offset_bottom = 275.0
	_panel.custom_minimum_size = Vector2(720.0, 550.0)
	_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.035, 0.085, 0.105, 0.97)))
	_overlay.add_child(_panel)

	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 12)
	_panel.add_child(layout)

	var heading := HBoxContainer.new()
	var title_stack := VBoxContainer.new()
	_port_title = Label.new()
	_port_title.add_theme_font_size_override("font_size", 28)
	_port_title.add_theme_color_override("font_color", Color(0.88, 0.94, 0.91))
	title_stack.add_child(_port_title)
	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 15)
	_status_label.add_theme_color_override("font_color", Color(0.60, 0.80, 0.79))
	title_stack.add_child(_status_label)
	heading.add_child(title_stack)
	heading.add_spacer(false)
	var close_button := _make_button("×", Color(0.20, 0.31, 0.33))
	close_button.custom_minimum_size = Vector2(42.0, 38.0)
	close_button.pressed.connect(close_menu)
	heading.add_child(close_button)
	layout.add_child(heading)

	var separator := HSeparator.new()
	layout.add_child(separator)
	_body = VBoxContainer.new()
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 12)
	layout.add_child(_body)
	_footer = HBoxContainer.new()
	_footer.add_theme_constant_override("separation", 10)
	layout.add_child(_footer)
	_populate_main_page()


func _populate_main_page() -> void:
	if _port_title == null or _body == null:
		return
	_port_title.text = _config.display_name
	_status_label.text = "已靠泊  ·  %s" % _get_vessel_display_name()
	_clear_children(_body)
	var intro := Label.new()
	intro.text = "选择一项港口服务。港口与海面仍在当前世界中持续运行。"
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.add_theme_color_override("font_color", Color(0.78, 0.85, 0.83))
	_body.add_child(intro)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	for service_id in _config.available_services:
		var service_name := _config.get_service_display_name(service_id)
		var enabled := _config.is_service_available(service_id)
		var button := _make_button(service_name + ("" if enabled else " · 暂未开放"), Color(0.10, 0.20, 0.23))
		button.name = "ServiceButton_%s" % service_id
		button.custom_minimum_size = Vector2(0.0, 86.0)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.disabled = not enabled
		button.pressed.connect(open_service.bind(service_id))
		grid.add_child(button)
	_body.add_child(grid)
	_build_footer(true)


func _populate_service_page(service_id: String) -> void:
	_port_title.text = _config.get_service_display_name(service_id)
	_status_label.text = "%s  ·  %s" % [_config.display_name, _get_vessel_display_name()]
	_clear_children(_body)
	if not _config.is_service_available(service_id):
		_add_info_block("服务暂不可用", "该港口当前没有开放这项服务。")
		_build_footer(false)
		return
	match service_id:
		SERVICE_CARGO:
			_populate_cargo_exchange_page()
		SERVICE_FUEL:
			_add_info_block("燃油状态", "油箱容量：尚未接入\n当前燃油量：尚未接入")
			_add_info_block("燃油补给", "燃油资源与补给流程尚未接入。此面板不会创建余额或扣款。")
			_add_disabled_action("补给入口 · 燃油系统尚未接入")
		SERVICE_SHIPYARD:
			_add_info_block("船舶状态", "当前耐久度：尚未接入\n最大耐久度：尚未接入")
			_add_info_block("维修服务", "船体耐久和维修流程尚未接入。此面板不会收取维修费用。")
			_add_disabled_action("维修入口 · 耐久系统尚未接入")
		SERVICE_MARKET:
			_add_info_block("当前船舶", _get_vessel_display_name())
			_add_info_block("可购买船舶", "暂无可购买船舶。船型展示与购买流程尚未接入。")
			_add_info_block("船舶基础属性", "暂无可展示的正式船型数据。")
		_:
			_add_info_block("服务信息", "此服务尚未配置内容。")
	_build_footer(false)


func _populate_cargo_exchange_page() -> void:
	if _economy_manager == null:
		_add_info_block("货运交易所", "本地货运管理器尚未加载。")
		return
	var scroll := ScrollContainer.new()
	scroll.name = "CargoExchangeScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 9)
	scroll.add_child(content)
	var wallet_label := Label.new()
	wallet_label.text = "钱包余额  %s" % _economy_manager.get_balance_text()
	wallet_label.add_theme_font_size_override("font_size", 18)
	wallet_label.add_theme_color_override("font_color", Color(0.84, 0.91, 0.76))
	content.add_child(wallet_label)
	var loadout := _boat.get_node_or_null("CargoLoadout") as CargoLoadoutController
	var load_snapshot := loadout.get_debug_snapshot() if loadout != null else {}
	var draft_text := "船舱占用 %d/%d 格 · 载重 %.0f/%.0f kg · 吃水 %.2f m" % [
		int(load_snapshot.get("used_space_units", 0)), int(load_snapshot.get("space_capacity_units", 0)),
		float(load_snapshot.get("cargo_weight_kg", 0.0)), float(load_snapshot.get("max_cargo_weight_kg", 0.0)),
		float(load_snapshot.get("current_draft_m", -1.0)),
	]
	_add_inline_note(content, draft_text)
	_add_section_title(content, "可领取任务")
	var offers := _economy_manager.get_available_contracts(str(_config.port_id))
	if offers.is_empty():
		_add_inline_note(content, "当前港口没有可领取任务。")
	else:
		for card in offers:
			_add_contract_card(content, card, false)
	_add_section_title(content, "进行中任务")
	var active := _economy_manager.get_active_contracts()
	if active.is_empty():
		_add_inline_note(content, "当前没有进行中的货运任务。")
	else:
		for card in active:
			_add_contract_card(content, card, true)
	_add_section_title(content, "历史记录")
	var completed := _economy_manager.get_completed_contracts()
	if completed.is_empty():
		_add_inline_note(content, "暂无已完成合同。")
	else:
		for card in completed:
			_add_contract_card(content, card, false, true)


func _add_contract_card(parent: VBoxContainer, card: Dictionary, active: bool, completed: bool = false) -> void:
	var definition := card.get("definition") as CargoContractDefinition
	if definition == null:
		return
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style(Color(0.055, 0.12, 0.14, 0.96)))
	parent.add_child(panel)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 5)
	panel.add_child(stack)
	var title := Label.new()
	title.text = definition.display_name
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(0.86, 0.93, 0.88))
	stack.add_child(title)
	var status := "已完成" if completed else "运输中" if active else "可接取"
	var details := Label.new()
	details.text = "%s → %s · %s · %.0f kg · %d 格 · 奖励 %s · %s" % [
		_get_port_name(str(definition.origin_port_id)), _get_port_name(str(definition.destination_port_id)),
		definition.cargo_type, definition.total_weight_kg, definition.required_space,
		definition.get_reward_eur_text(), status,
	]
	details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	details.add_theme_color_override("font_color", Color(0.70, 0.80, 0.77))
	stack.add_child(details)
	if active:
		var load_label := Label.new()
		var actual_contract_cargo := _economy_manager.get_contract_cargo_instances(str(definition.contract_id))
		var actual_weight := 0.0
		var actual_space := 0
		for cargo_instance in actual_contract_cargo:
			actual_weight += float(cargo_instance.get("weight_kg", 0.0))
			actual_space += int(cargo_instance.get("space_units", 0))
		load_label.text = "本合同已装载 %.0f kg · %d/%d 格 · 奖励 %s" % [actual_weight, actual_space, definition.required_space, definition.get_reward_eur_text()]
		load_label.add_theme_font_size_override("font_size", 14)
		load_label.add_theme_color_override("font_color", Color(0.62, 0.74, 0.72))
		stack.add_child(load_label)
		var action := _make_button("交付货物", Color(0.12, 0.25, 0.28))
		var validation := _economy_manager.can_deliver_contract(str(definition.contract_id), _harbor)
		action.disabled = not bool(validation.get("can_deliver", false))
		action.tooltip_text = str(validation.get("reason", ""))
		action.pressed.connect(_on_deliver_contract_pressed.bind(str(definition.contract_id)))
		stack.add_child(action)
	elif not completed:
		var action := _make_button("接受并装货", Color(0.12, 0.25, 0.28))
		action.pressed.connect(_on_accept_contract_pressed.bind(str(definition.contract_id)))
		stack.add_child(action)


func _add_section_title(parent: VBoxContainer, text_value: String) -> void:
	var label := Label.new()
	label.text = text_value
	label.add_theme_font_size_override("font_size", 17)
	label.add_theme_color_override("font_color", Color(0.69, 0.84, 0.80))
	parent.add_child(label)


func _add_inline_note(parent: VBoxContainer, text_value: String) -> void:
	var label := Label.new()
	label.text = text_value
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", Color(0.67, 0.75, 0.73))
	parent.add_child(label)


func _on_accept_contract_pressed(contract_id: String) -> void:
	var result := _economy_manager.accept_contract(contract_id, _harbor)
	_show_cargo_result(result)


func _on_deliver_contract_pressed(contract_id: String) -> void:
	var result := _economy_manager.deliver_contract(contract_id, _harbor)
	_show_cargo_result(result)


func _show_cargo_result(result: Dictionary) -> void:
	var message := str(result.get("message", "操作失败"))
	_status_label.text = message
	_populate_service_page(SERVICE_CARGO)
	_status_label.text = message


func _on_economy_state_changed() -> void:
	if is_menu_open() and _current_service_id == SERVICE_CARGO:
		_populate_service_page(SERVICE_CARGO)


func _get_port_name(port_id: String) -> String:
	return _economy_manager.get_port_display_name(port_id) if _economy_manager != null else port_id


func _build_footer(main_page: bool) -> void:
	_clear_children(_footer)
	if not main_page:
		var back_button := _make_button("返回服务菜单", Color(0.12, 0.25, 0.28))
		back_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		back_button.pressed.connect(return_to_main_menu)
		_footer.add_child(back_button)
	else:
		var close_button := _make_button("关闭菜单", Color(0.12, 0.25, 0.28))
		close_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		close_button.pressed.connect(close_menu)
		_footer.add_child(close_button)
	var leave_button := _make_button("离港", Color(0.40, 0.19, 0.15))
	leave_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	leave_button.pressed.connect(_on_leave_port_pressed)
	_footer.add_child(leave_button)


func _on_leave_port_pressed() -> void:
	if _harbor != null and _harbor.has_method("request_undock"):
		_harbor.call("request_undock")


func _add_info_block(title_text: String, body_text: String) -> void:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _panel_style(Color(0.055, 0.12, 0.14, 0.96)))
	_body.add_child(card)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 6)
	card.add_child(stack)
	var title := Label.new()
	title.text = title_text
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(0.81, 0.90, 0.87))
	stack.add_child(title)
	var body := Label.new()
	body.text = body_text
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_theme_font_size_override("font_size", 16)
	body.add_theme_color_override("font_color", Color(0.69, 0.79, 0.78))
	stack.add_child(body)


func _add_disabled_action(label_text: String) -> void:
	var action := _make_button(label_text, Color(0.10, 0.18, 0.20))
	action.disabled = true
	action.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(action)


func _get_vessel_display_name() -> String:
	if _boat != null and _boat.draft_profile != null:
		return _boat.draft_profile.vessel_display_name
	return "测试船"


func _make_button(text_value: String, color: Color) -> Button:
	var button := Button.new()
	button.text = text_value
	button.add_theme_font_size_override("font_size", 17)
	button.add_theme_color_override("font_color", Color(0.91, 0.95, 0.92))
	button.add_theme_stylebox_override("normal", _panel_style(color))
	button.add_theme_stylebox_override("hover", _panel_style(color.lightened(0.12)))
	button.add_theme_stylebox_override("pressed", _panel_style(color.darkened(0.08)))
	button.add_theme_stylebox_override("disabled", _panel_style(color.darkened(0.2)))
	return button


func _panel_style(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(8)
	style.content_margin_left = 16.0
	style.content_margin_right = 16.0
	style.content_margin_top = 12.0
	style.content_margin_bottom = 12.0
	return style


func _clear_children(parent: Node) -> void:
	for child in parent.get_children():
		parent.remove_child(child)
		child.queue_free()
