class_name FishResourceMap
extends CanvasLayer

const MAP_CANVAS_SCRIPT := preload("res://scripts/fish_resource_map_canvas.gd")

@export_node_path("Node") var manager_path := NodePath("../FishResourceManager")
@export_node_path("Node") var bathymetry_path := NodePath("../BathymetryManager")
@export_node_path("Node3D") var boat_path := NodePath("../PlayerBoat/MotionRoot")

var _manager: FishResourceManager
var _bathymetry: BathymetryManager
var _georeference: GeoReference
var _boat: Node3D
var _root: Control
var _map_canvas: FishResourceMapCanvas
var _selected_species: Array[String] = []
var _species_buttons: Dictionary = {}
var _details_label: Label
var _summary_label: Label
var _footer_label: Label
var _refresh_elapsed := 0.0
var _map_open := false


func _ready() -> void:
	_manager = get_node_or_null(manager_path) as FishResourceManager
	_bathymetry = get_node_or_null(bathymetry_path) as BathymetryManager
	_boat = get_node_or_null(boat_path) as Node3D
	if _manager != null:
		_georeference = _manager.get_georeference()
		_build_ui()
	set_map_open(false)


func configure(manager: FishResourceManager, bathymetry: BathymetryManager, georeference: GeoReference, boat: Node3D) -> void:
	_manager = manager
	_bathymetry = bathymetry
	_georeference = georeference
	_boat = boat
	if is_node_ready():
		if _root == null:
			_build_ui()
		else:
			_map_canvas.configure(_manager, _bathymetry, _georeference, _boat)
			refresh_data()


func is_map_open() -> bool:
	return _map_open


func set_map_open(open: bool) -> void:
	_map_open = open
	if _root != null:
		_root.visible = open
	if _map_canvas != null:
		_map_canvas.set_raster_build_enabled(open)
		_map_canvas.set_boat_pulse_enabled(open)
	if open:
		if _map_canvas != null:
			_map_canvas.ensure_raster()
		refresh_data()
		get_viewport().set_input_as_handled()


func refresh_data() -> void:
	if _map_canvas != null:
		_map_canvas.set_species_filter(_selected_species)
		var count := _map_canvas.get_school_count()
		if _summary_label != null:
			_summary_label.text = "当前筛选：%d 个稳定资源点" % count
		if _footer_label != null and _manager != null:
			_footer_label.text = "%s Authority · Seed %d · Revision %d · 预测栖息区，不是实测鱼群" % [_manager.get_authority_source(), _manager.get_world_seed(), _manager.get_state_revision()]


func _unhandled_key_input(event: InputEvent) -> void:
	if not _map_open or event is not InputEventKey or not event.pressed or event.echo:
		return
	if event.physical_keycode == KEY_ESCAPE:
		set_map_open(false)
		get_viewport().set_input_as_handled()


func _build_ui() -> void:
	if _root != null or _manager == null or _bathymetry == null or _georeference == null:
		return
	layer = 25
	_root = Control.new()
	_root.name = "FishResourceMapRoot"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	var background := ColorRect.new()
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.color = Color(0.025, 0.055, 0.075, 0.94)
	_root.add_child(background)
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 42.0
	panel.offset_top = 34.0
	panel.offset_right = -42.0
	panel.offset_bottom = -34.0
	panel.add_theme_stylebox_override("panel", _panel_style())
	_root.add_child(panel)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 12)
	panel.add_child(outer)
	var header := HBoxContainer.new()
	outer.add_child(header)
	var title := Label.new()
	title.text = "FISH RESOURCES  ·  ØRESUND"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color("#dce9dc"))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_button := Button.new()
	close_button.text = "关闭  ·  F4 / Esc"
	close_button.pressed.connect(func() -> void: set_map_open(false))
	header.add_child(close_button)
	var subtitle := Label.new()
	subtitle.text = "鱼类可能出现区域 · 由真实 EMODnet 水深与 OSM 海岸掩膜约束的本地生态预测"
	subtitle.add_theme_color_override("font_color", Color("#9db8b6"))
	outer.add_child(subtitle)
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 16)
	outer.add_child(body)
	_map_canvas = MAP_CANVAS_SCRIPT.new() as FishResourceMapCanvas
	_map_canvas.name = "ResourceDistributionMap"
	_map_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_map_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_map_canvas.configure(_manager, _bathymetry, _georeference, _boat)
	_map_canvas.school_selected.connect(_on_school_selected)
	_map_canvas.school_hovered.connect(_on_school_hovered)
	body.add_child(_map_canvas)
	var side := PanelContainer.new()
	side.custom_minimum_size = Vector2(318.0, 0.0)
	side.add_theme_stylebox_override("panel", _side_style())
	body.add_child(side)
	var side_layout := VBoxContainer.new()
	side_layout.add_theme_constant_override("separation", 9)
	side.add_child(side_layout)
	var species_heading := Label.new()
	species_heading.text = "鱼种筛选"
	species_heading.add_theme_font_size_override("font_size", 17)
	species_heading.add_theme_color_override("font_color", Color("#dce9dc"))
	side_layout.add_child(species_heading)
	for profile in _manager.get_species_profiles():
		_selected_species.append(profile.species_id)
		var species_id := profile.species_id
		var check := CheckButton.new()
		check.text = "%s  ·  %s" % [profile.display_name, profile.english_name]
		check.button_pressed = true
		check.add_theme_color_override("font_color", profile.map_color.lightened(0.18))
		check.toggled.connect(func(pressed: bool) -> void: _set_species_enabled(species_id, pressed))
		side_layout.add_child(check)
		_species_buttons[species_id] = check
	_summary_label = Label.new()
	_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary_label.add_theme_color_override("font_color", Color("#a6c1bc"))
	side_layout.add_child(_summary_label)
	var detail_heading := Label.new()
	detail_heading.text = "区域信息"
	detail_heading.add_theme_font_size_override("font_size", 17)
	detail_heading.add_theme_color_override("font_color", Color("#dce9dc"))
	side_layout.add_child(detail_heading)
	_details_label = Label.new()
	_details_label.text = "点击地图上的资源点查看鱼种、预测深度与群体规模。"
	_details_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_details_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_details_label.add_theme_color_override("font_color", Color("#b2c5c1"))
	side_layout.add_child(_details_label)
	var legend := Label.new()
	legend.text = "● 针鱼  ● 鲱鱼  ● 三刺鱼\n底图：EMODnet DTM 2024 / LAT\n海岸线：现有 OSM land mask"
	legend.add_theme_color_override("font_color", Color("#98b0ae"))
	side_layout.add_child(legend)
	_footer_label = Label.new()
	_footer_label.add_theme_color_override("font_color", Color("#809b9b"))
	outer.add_child(_footer_label)
	get_viewport().size_changed.connect(_update_layout)
	_update_layout()
	refresh_data()


func _update_layout() -> void:
	if _root != null:
		_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if _map_canvas != null:
		_map_canvas.queue_redraw()


func _set_species_enabled(species_id: String, enabled: bool) -> void:
	if enabled and not _selected_species.has(species_id):
		_selected_species.append(species_id)
	elif not enabled:
		_selected_species.erase(species_id)
	refresh_data()


func _on_school_selected(school: Dictionary) -> void:
	if school.is_empty():
		_details_label.text = "该位置没有当前筛选的预测资源点。"
		return
	_update_school_details(school)


func _on_school_hovered(school: Dictionary) -> void:
	if not school.is_empty():
		_update_school_details(school)


func _update_school_details(school: Dictionary) -> void:
	var profile := _manager.get_species_profile(str(school.get("species_id", "")))
	if profile == null:
		return
	_details_label.text = "%s / %s\n典型生境：%s\n预测水深：%.1f m\n群体规模：%s（%d 条模拟个体）\n资源状态：%s · 预测生态资源点" % [
		profile.display_name,
		profile.english_name,
		profile.habitat_description,
		float(school.get("depth_m", 0.0)),
		_population_band(int(school.get("population", 0))),
		int(school.get("population", 0)),
		str(school.get("resource_state", "available")),
	]


func _population_band(population: int) -> String:
	if population < 12:
		return "小"
	if population < 45:
		return "中"
	return "大"


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.035, 0.08, 0.10, 0.98)
	style.border_color = Color(0.23, 0.48, 0.50, 0.92)
	style.set_border_width_all(1)
	style.set_corner_radius_all(14)
	style.content_margin_left = 20.0
	style.content_margin_right = 20.0
	style.content_margin_top = 18.0
	style.content_margin_bottom = 14.0
	return style


func _side_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.14, 0.16, 0.96)
	style.border_color = Color(0.22, 0.42, 0.44, 0.72)
	style.set_border_width_all(1)
	style.set_corner_radius_all(9)
	style.content_margin_left = 14.0
	style.content_margin_right = 14.0
	style.content_margin_top = 14.0
	style.content_margin_bottom = 12.0
	return style
