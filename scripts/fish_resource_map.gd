class_name FishResourceMap
extends CanvasLayer

signal display_mode_changed(mode: String)

const MAP_CANVAS_SCRIPT := preload("res://scripts/fish_resource_map_canvas.gd")
const DEPTH_QUALITY_MAP_SCRIPT := preload("res://scripts/depth_quality_map_canvas.gd")
const ROUTE_EDITOR_SCRIPT := preload("res://scripts/route_editor_panel.gd")
const MAP_SETTINGS_PATH := "user://fish_resource_map_settings.cfg"
const MAP_SETTINGS_SECTION := "fish_tracking"
const MAP_SETTINGS_ENABLED_SPECIES_KEY := "enabled_species"
const MAP_SETTINGS_DOLPHINS_ENABLED_KEY := "enabled_dolphins"

@export_node_path("Node") var manager_path := NodePath("../FishResourceManager")
@export_node_path("Node") var bathymetry_path := NodePath("../BathymetryManager")
@export_node_path("Node3D") var boat_path := NodePath("../PlayerBoat/MotionRoot")

var _manager: FishResourceManager
var _bathymetry: BathymetryManager
var _georeference: GeoReference
var _boat: Node3D
var _dolphin_manager: Node
var _route_manager: PortRouteManager
var _economy_manager: CargoEconomyManager
var _compact_sea_chart: CanvasLayer
var _root: Control
var _background: ColorRect
var _map_panel: PanelContainer
var _map_outer: VBoxContainer
var _map_body: HBoxContainer
var _side_panel: PanelContainer
var _collapse_button: Button
var _hide_button: Button
var _map_host: Control
var _map_canvas: FishResourceMapCanvas
var _depth_quality_canvas: DepthQualityMapCanvas
var _map_tabs: TabContainer
var _selected_species: Array[String] = []
var _dolphins_enabled := true
var _species_buttons: Dictionary = {}
var _details_label: Label
var _summary_label: Label
var _route_label: Label
var _route_editor: RouteEditorPanel
var _route_editor_toggle: Button
var _footer_label: Label
var _title_label: Label
var _subtitle_label: Label
var _depth_quality_summary: Label
var _map_close_button: Button
var _fish_filter_heading: Label
var _fish_filter_hint: Label
var _dolphin_filter_button: CheckButton
var _detail_heading: Label
var _map_legend: Label
var _depth_heading: Label
var _depth_instructions: Label
var _depth_note: Label
var _depth_zoom_in_button: Button
var _depth_zoom_out_button: Button
var _depth_reset_button: Button
var _depth_quality_legend_labels: Array[Label] = []
var _map_settings := ConfigFile.new()
var _refresh_elapsed := 0.0
var _map_open := false
var _display_mode := "hidden"
var _route_refresh_elapsed := 0.0


func _ready() -> void:
	add_to_group("fish_resource_map")
	_manager = get_node_or_null(manager_path) as FishResourceManager
	_bathymetry = get_node_or_null(bathymetry_path) as BathymetryManager
	_boat = get_node_or_null(boat_path) as Node3D
	_dolphin_manager = get_node_or_null("../DolphinWorldManager")
	_compact_sea_chart = get_node_or_null("../DepthChartHUD") as CanvasLayer
	_route_manager = get_node_or_null("../PortRouteManager") as PortRouteManager
	_economy_manager = get_node_or_null("../CargoEconomyManager") as CargoEconomyManager
	_load_tracking_preferences()
	if _manager != null:
		_georeference = _manager.get_georeference()
		_build_ui()
	set_display_mode("mini")


func configure(manager: FishResourceManager, bathymetry: BathymetryManager, georeference: GeoReference, boat: Node3D, dolphin_manager: Node = null) -> void:
	_manager = manager
	_bathymetry = bathymetry
	_georeference = georeference
	_boat = boat
	if dolphin_manager != null:
		_dolphin_manager = dolphin_manager
	if is_node_ready():
		if _root == null:
			_build_ui()
		else:
			_map_canvas.configure(_manager, _bathymetry, _georeference, _boat, _dolphin_manager)
			_map_canvas.set_dolphins_enabled(_dolphins_enabled)
			if _depth_quality_canvas != null:
				_depth_quality_canvas.configure(_bathymetry, _georeference, _boat)
			if _display_mode == "expanded":
				refresh_data()


func is_map_open() -> bool:
	return _display_mode == "expanded"


func set_map_open(open: bool) -> void:
	set_display_mode("expanded" if open else "mini")


func get_display_mode() -> String:
	return _display_mode


func set_display_mode(mode: String) -> void:
	var next_mode := mode if mode in ["hidden", "mini", "expanded"] else "mini"
	if _display_mode == next_mode and _root != null:
		_update_layout()
		return
	_display_mode = next_mode
	_map_open = _display_mode == "expanded"
	if _display_mode == "hidden" and _route_editor != null:
		_route_editor.set_editor_open(false)
		if _route_editor_toggle != null:
			_route_editor_toggle.text = tr("fish.map.route_editor_open")
	set_process(_display_mode == "expanded")
	if _root != null:
		_root.visible = _display_mode == "expanded"
		_root.mouse_filter = Control.MOUSE_FILTER_STOP if _display_mode == "expanded" else Control.MOUSE_FILTER_IGNORE
	if _background != null:
		_background.visible = _display_mode == "expanded"
	if _map_panel != null:
		_map_panel.mouse_filter = Control.MOUSE_FILTER_STOP if _display_mode == "expanded" else Control.MOUSE_FILTER_IGNORE
	if _map_body != null:
		_map_body.mouse_filter = Control.MOUSE_FILTER_PASS
	if _side_panel != null:
		_side_panel.visible = _display_mode == "expanded"
	if _subtitle_label != null:
		_subtitle_label.visible = _display_mode == "expanded"
	if _footer_label != null:
		_footer_label.visible = _display_mode == "expanded"
	if _collapse_button != null:
		_collapse_button.text = tr("fish.map.collapse") if _display_mode == "expanded" else tr("fish.map.expand")
	if _hide_button != null:
		_hide_button.visible = _display_mode == "expanded"
	_update_layout()
	if _display_mode == "expanded":
		refresh_data()
		_refresh_route_overlay()
	if _display_mode == "expanded":
		get_viewport().set_input_as_handled()
	display_mode_changed.emit(_display_mode)


func refresh_data() -> void:
	if _map_canvas != null:
		_map_canvas.set_species_filter(_selected_species)
		_update_summary_label()
		if _footer_label != null and _manager != null:
			_update_footer_label()
	_update_depth_quality_summary()
	_refresh_route_overlay()


func _process(delta: float) -> void:
	if _display_mode != "expanded":
		return
	_route_refresh_elapsed += delta
	if _route_refresh_elapsed >= 1.0:
		_route_refresh_elapsed = fmod(_route_refresh_elapsed, 1.0)
		if _map_canvas != null:
			_map_canvas.refresh_dolphin_data()
			_update_summary_label()
		_refresh_route_overlay()


func _update_summary_label() -> void:
	if _summary_label == null or _map_canvas == null:
		return
	_summary_label.text = tr("fish.map.summary") % [
		_map_canvas.get_school_count(),
		_map_canvas.get_dolphin_count(),
	]


func _refresh_route_overlay() -> void:
	if _map_tabs != null and _map_tabs.current_tab != 1:
		if _map_canvas != null:
			_map_canvas.set_route_overlay(null, _georeference)
		if _route_label != null:
			_route_label.text = tr("fish.map.route.select_tab")
		return
	if _route_editor != null and _route_editor.is_editor_open():
		var edited_route := _route_editor.get_selected_route()
		_map_canvas.set_route_overlay(edited_route, _georeference)
		if _route_label != null:
			_route_label.text = tr("fish.map.route.dev_preview") % [edited_route.display_name, edited_route.validation_status, edited_route.waypoints.size()] if edited_route != null else tr("fish.map.route.dev_empty")
		return
	if _map_canvas == null or _route_manager == null or _economy_manager == null:
		if _map_canvas != null:
			_map_canvas.set_route_overlay(null, _georeference)
		if _route_label != null:
			_route_label.text = tr("fish.map.route.none")
		return
	var active_contracts := _economy_manager.get_active_contracts()
	var chosen_route: RouteDefinition
	for card in active_contracts:
		var definition := card.get("definition") as CargoContractDefinition
		if definition == null:
			continue
		chosen_route = _route_manager.get_route_between(str(definition.origin_port_id), str(definition.destination_port_id))
		if chosen_route != null:
			break
	_map_canvas.set_route_overlay(chosen_route, _georeference)
	if _route_label == null:
		return
	if chosen_route == null:
		_route_label.text = tr("fish.map.route.no_contract_route")
		return
	var cruise_speed := 0.0
	if _boat is BoatController and _boat.draft_profile != null:
		cruise_speed = _boat.draft_profile.cruise_speed_mps
	var summary := _route_manager.get_route_summary(chosen_route, cruise_speed)
	var remaining := chosen_route.get_remaining_distance_m(_boat.global_position, _georeference) if _boat != null else float(summary.get("distance_m", 0.0))
	var eta_seconds := float(summary.get("estimated_seconds", -1.0))
	var eta_text := tr("fish.map.unknown") if eta_seconds < 0.0 else _format_duration(eta_seconds)
	var validation_text := tr("fish.map.route.validated") if chosen_route.validation_status == RouteDefinition.STATUS_VALIDATED else tr("fish.map.route.unvalidated")
	var route_key := "hud.autopilot.route.%s" % chosen_route.route_id
	var route_name := tr(route_key) if tr(route_key) != route_key else chosen_route.display_name
	_route_label.text = tr("fish.map.route.summary") % [
		route_name, float(summary.get("distance_m", 0.0)) / 1000.0,
		remaining / 1000.0, cruise_speed, eta_text,
		validation_text,
		tr("fish.map.route.cruise_eligible") if _route_manager.is_route_cruise_eligible(chosen_route) else tr("fish.map.route.cruise_unavailable"),
	]


func _format_duration(seconds: float) -> String:
	var minutes := int(round(seconds / 60.0))
	return tr("fish.map.duration.hours") % [int(minutes / 60), minutes % 60] if minutes >= 60 else tr("fish.map.duration.minutes") % minutes


func _unhandled_key_input(event: InputEvent) -> void:
	if event is not InputEventKey or not event.pressed or event.echo:
		return
	if event.is_action_pressed("map_toggle") and not event.shift_pressed and not event.ctrl_pressed and not event.alt_pressed and not event.meta_pressed:
		var focus_owner := get_viewport().gui_get_focus_owner()
		if focus_owner is LineEdit or focus_owner is TextEdit:
			return
		set_display_mode("mini" if _display_mode == "expanded" else "expanded")
		get_viewport().set_input_as_handled()
		return
	if _display_mode != "expanded":
		return
	if event.physical_keycode == KEY_ESCAPE:
		set_display_mode("mini")
		get_viewport().set_input_as_handled()


func _build_ui() -> void:
	if _root != null or _manager == null or _bathymetry == null or _georeference == null:
		return
	layer = 25
	_root = Control.new()
	_root.name = "FishResourceMapRoot"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_background = ColorRect.new()
	_background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_background.color = Color(0.025, 0.055, 0.075, 0.94)
	_background.visible = false
	_root.add_child(_background)
	_map_panel = PanelContainer.new()
	_map_panel.name = "MapPanel"
	_map_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_map_panel.offset_left = 42.0
	_map_panel.offset_top = 34.0
	_map_panel.offset_right = -42.0
	_map_panel.offset_bottom = -34.0
	_map_panel.add_theme_stylebox_override("panel", _panel_style())
	_root.add_child(_map_panel)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 12)
	_map_outer = outer
	_map_panel.add_child(outer)
	var header := HBoxContainer.new()
	outer.add_child(header)
	var title := Label.new()
	title.name = "MapTitle"
	title.text = tr("fish.map.title")
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color("#dce9dc"))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_title_label = title
	var actions := HBoxContainer.new()
	_collapse_button = Button.new()
	_collapse_button.pressed.connect(func() -> void: set_display_mode("mini" if _display_mode == "expanded" else "expanded"))
	actions.add_child(_collapse_button)
	_hide_button = Button.new()
	_hide_button.text = tr("fish.map.hide")
	_hide_button.pressed.connect(func() -> void: set_display_mode("hidden"))
	actions.add_child(_hide_button)
	var close_button := Button.new()
	_map_close_button = close_button
	close_button.text = "×"
	close_button.tooltip_text = tr("fish.map.hide")
	close_button.pressed.connect(func() -> void: set_display_mode("hidden"))
	actions.add_child(close_button)
	header.add_child(actions)
	var subtitle := Label.new()
	subtitle.name = "MapSubtitle"
	subtitle.text = tr("fish.map.subtitle")
	subtitle.add_theme_color_override("font_color", Color("#9db8b6"))
	outer.add_child(subtitle)
	_subtitle_label = subtitle
	var body := HBoxContainer.new()
	_map_body = body
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 16)
	outer.add_child(body)
	_map_host = Control.new()
	_map_host.name = "MapCanvasHost"
	_map_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_map_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_map_host.mouse_filter = Control.MOUSE_FILTER_PASS
	body.add_child(_map_host)
	_map_canvas = MAP_CANVAS_SCRIPT.new() as FishResourceMapCanvas
	_map_canvas.name = "ResourceDistributionMap"
	_map_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_map_canvas.configure(_manager, _bathymetry, _georeference, _boat, _dolphin_manager)
	_map_canvas.set_dolphins_enabled(_dolphins_enabled)
	_map_canvas.school_selected.connect(_on_school_selected)
	_map_canvas.school_hovered.connect(_on_school_hovered)
	_map_host.add_child(_map_canvas)
	_depth_quality_canvas = DEPTH_QUALITY_MAP_SCRIPT.new() as DepthQualityMapCanvas
	_depth_quality_canvas.name = "DepthQualityMap"
	_depth_quality_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_depth_quality_canvas.configure(_bathymetry, _georeference, _boat)
	_depth_quality_canvas.visible = true
	_map_host.add_child(_depth_quality_canvas)
	var side := PanelContainer.new()
	_side_panel = side
	side.custom_minimum_size = Vector2(318.0, 0.0)
	side.add_theme_stylebox_override("panel", _side_style())
	body.add_child(side)
	_map_tabs = TabContainer.new()
	_map_tabs.name = "MapDataTabs"
	_map_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_map_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_map_tabs.tab_changed.connect(_on_map_tab_changed)
	side.add_child(_map_tabs)
	var fish_tab := ScrollContainer.new()
	fish_tab.name = "FishResourcesTab"
	fish_tab.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	fish_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fish_tab.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_map_tabs.add_child(fish_tab)
	_map_tabs.set_tab_title(_map_tabs.get_tab_count() - 1, tr("fish.map.tab.fish_resources"))
	var fish_layout := VBoxContainer.new()
	fish_layout.add_theme_constant_override("separation", 9)
	fish_layout.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fish_tab.add_child(fish_layout)
	var route_tab := ScrollContainer.new()
	route_tab.name = "航路编辑"
	route_tab.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	route_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	route_tab.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_map_tabs.add_child(route_tab)
	var route_layout := VBoxContainer.new()
	route_layout.add_theme_constant_override("separation", 9)
	route_layout.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	route_tab.add_child(route_layout)
	var depth_tab := ScrollContainer.new()
	depth_tab.name = "水深图"
	depth_tab.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	depth_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	depth_tab.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_map_tabs.add_child(depth_tab)
	var depth_layout := VBoxContainer.new()
	depth_layout.add_theme_constant_override("separation", 10)
	depth_layout.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	depth_tab.add_child(depth_layout)
	_map_tabs.current_tab = 0
	_map_canvas.set_resource_overlay_enabled(true)
	_depth_quality_canvas.set_chart_active(false)
	_fish_filter_heading = Label.new()
	_fish_filter_heading.text = tr("fish.map.species_heading")
	_fish_filter_heading.add_theme_font_size_override("font_size", 17)
	_fish_filter_heading.add_theme_color_override("font_color", Color("#dce9dc"))
	fish_layout.add_child(_fish_filter_heading)
	_fish_filter_hint = Label.new()
	_fish_filter_hint.text = tr("fish.map.filter_hint")
	_fish_filter_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_fish_filter_hint.add_theme_color_override("font_color", Color("#9db8b6"))
	fish_layout.add_child(_fish_filter_hint)
	for profile in _manager.get_species_profiles():
		var species_id := profile.species_id
		var check := CheckButton.new()
		check.text = tr("fish.map.species_filter") % [tr(profile.name_key), profile.scientific_name]
		check.button_pressed = _selected_species.has(species_id)
		check.add_theme_color_override("font_color", profile.map_color.lightened(0.18))
		check.toggled.connect(func(pressed: bool) -> void: _set_species_enabled(species_id, pressed))
		fish_layout.add_child(check)
		_species_buttons[species_id] = check
	_dolphin_filter_button = CheckButton.new()
	_dolphin_filter_button.name = "DolphinTracking"
	_dolphin_filter_button.text = tr("fish.map.dolphin_filter")
	_dolphin_filter_button.button_pressed = _dolphins_enabled
	_dolphin_filter_button.add_theme_color_override("font_color", Color("#a9e5df"))
	_dolphin_filter_button.toggled.connect(_set_dolphins_enabled)
	fish_layout.add_child(_dolphin_filter_button)
	_summary_label = Label.new()
	_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary_label.add_theme_color_override("font_color", Color("#a6c1bc"))
	fish_layout.add_child(_summary_label)
	_route_label = Label.new()
	_route_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_route_label.add_theme_color_override("font_color", Color("#f0d39a"))
	_route_label.text = tr("fish.map.route.select_tab")
	route_layout.add_child(_route_label)
	if _route_manager != null and (OS.has_feature("editor") or OS.has_feature("debug")):
		_route_editor_toggle = Button.new()
		_route_editor_toggle.text = tr("fish.map.route_editor_open")
		route_layout.add_child(_route_editor_toggle)
		_route_editor = ROUTE_EDITOR_SCRIPT.new() as RouteEditorPanel
		_route_editor.name = "RouteEditorPanel"
		_route_editor.visible = false
		_route_editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_route_editor.configure(_route_manager, _map_canvas, _georeference)
		route_layout.add_child(_route_editor)
		_route_editor_toggle.pressed.connect(func() -> void:
			_route_editor.set_editor_open(not _route_editor.is_editor_open())
			_route_editor_toggle.text = tr("fish.map.route_editor_close") if _route_editor.is_editor_open() else tr("fish.map.route_editor_open")
			_refresh_route_overlay()
		)
	_detail_heading = Label.new()
	_detail_heading.text = tr("fish.map.detail_heading")
	_detail_heading.add_theme_font_size_override("font_size", 17)
	_detail_heading.add_theme_color_override("font_color", Color("#dce9dc"))
	fish_layout.add_child(_detail_heading)
	_details_label = Label.new()
	_details_label.text = tr("fish.map.detail_prompt")
	_details_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_details_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_details_label.add_theme_color_override("font_color", Color("#b2c5c1"))
	fish_layout.add_child(_details_label)
	_map_legend = Label.new()
	var species_legend := PackedStringArray()
	for profile in _manager.get_species_profiles():
		species_legend.append(tr("fish.map.legend.species") % tr(profile.name_key))
	_map_legend.text = "%s  %s\n%s\n%s" % ["  ".join(species_legend), tr("fish.map.legend.dolphins"), tr("fish.map.legend.visual_logical"), tr("fish.map.legend.depth_source")]
	_map_legend.add_theme_color_override("font_color", Color("#98b0ae"))
	fish_layout.add_child(_map_legend)
	_depth_heading = Label.new()
	_depth_heading.text = tr("fish.map.depth_quality_heading")
	_depth_heading.add_theme_font_size_override("font_size", 17)
	_depth_heading.add_theme_color_override("font_color", Color("#dce9dc"))
	depth_layout.add_child(_depth_heading)
	_depth_instructions = Label.new()
	_depth_instructions.text = tr("fish.map.depth_quality_instructions")
	_depth_instructions.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_depth_instructions.add_theme_color_override("font_color", Color("#b2c5c1"))
	depth_layout.add_child(_depth_instructions)
	_depth_quality_summary = Label.new()
	_depth_quality_summary.name = "DepthQualitySummary"
	_depth_quality_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_depth_quality_summary.add_theme_color_override("font_color", Color("#dce9dc"))
	depth_layout.add_child(_depth_quality_summary)
	depth_layout.add_child(_quality_legend_row(Color("#ffd166"), "fish.map.depth_quality.estimated"))
	depth_layout.add_child(_quality_legend_row(Color("#ff5964"), "fish.map.depth_quality.unknown"))
	_depth_note = Label.new()
	_depth_note.text = tr("fish.map.depth_quality.note")
	_depth_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_depth_note.add_theme_color_override("font_color", Color("#9db8b6"))
	depth_layout.add_child(_depth_note)
	var depth_controls := HBoxContainer.new()
	depth_controls.add_theme_constant_override("separation", 6)
	depth_layout.add_child(depth_controls)
	var zoom_in_button := Button.new()
	_depth_zoom_in_button = zoom_in_button
	zoom_in_button.text = tr("fish.map.zoom_in")
	zoom_in_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	zoom_in_button.pressed.connect(func() -> void: _depth_quality_canvas.zoom_in())
	depth_controls.add_child(zoom_in_button)
	var zoom_out_button := Button.new()
	_depth_zoom_out_button = zoom_out_button
	zoom_out_button.text = tr("fish.map.zoom_out")
	zoom_out_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	zoom_out_button.pressed.connect(func() -> void: _depth_quality_canvas.zoom_out())
	depth_controls.add_child(zoom_out_button)
	var reset_button := Button.new()
	_depth_reset_button = reset_button
	reset_button.text = tr("fish.map.reset_view")
	reset_button.pressed.connect(func() -> void: _depth_quality_canvas.reset_view())
	depth_controls.add_child(reset_button)
	_footer_label = Label.new()
	_footer_label.add_theme_color_override("font_color", Color("#809b9b"))
	outer.add_child(_footer_label)
	get_viewport().size_changed.connect(_update_layout)
	_update_layout()
	set_display_mode("mini")
	_update_depth_quality_summary()


func _update_layout() -> void:
	if _root != null:
		_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if _map_panel != null and get_viewport() != null:
		if _display_mode == "expanded":
			_map_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			_map_panel.offset_left = 42.0
			_map_panel.offset_top = 34.0
			_map_panel.offset_right = -42.0
			_map_panel.offset_bottom = -34.0
			_map_panel.custom_minimum_size = Vector2.ZERO
			if _map_outer != null:
				_map_outer.add_theme_constant_override("separation", 12)
			if _map_canvas != null:
				_map_canvas.custom_minimum_size = Vector2(640.0, 480.0)
			if _depth_quality_canvas != null:
				_depth_quality_canvas.custom_minimum_size = Vector2(640.0, 480.0)
		else:
			var viewport_size := get_viewport().get_visible_rect().size
			var mini_width := minf(360.0, maxf(260.0, viewport_size.x * 0.31))
			var mini_height := minf(252.0, maxf(190.0, viewport_size.y * 0.34))
			_map_panel.anchor_left = 0.0
			_map_panel.anchor_right = 0.0
			_map_panel.anchor_top = 1.0
			_map_panel.anchor_bottom = 1.0
			_map_panel.offset_left = 18.0
			_map_panel.offset_right = 18.0 + mini_width
			_map_panel.offset_top = -18.0 - mini_height
			_map_panel.offset_bottom = -18.0
			_map_panel.custom_minimum_size = Vector2(mini_width, mini_height)
			if _map_outer != null:
				_map_outer.add_theme_constant_override("separation", 4)
			if _map_canvas != null:
				_map_canvas.custom_minimum_size = Vector2.ZERO
			if _depth_quality_canvas != null:
				_depth_quality_canvas.custom_minimum_size = Vector2.ZERO
		if _map_body != null:
			_map_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
			_map_body.add_theme_constant_override("separation", 6 if _display_mode == "mini" else 16)
		if _map_host != null:
			_map_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_map_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	if _title_label != null:
		_title_label.text = tr("fish.map.title") if _display_mode == "expanded" else tr("fish.map.mini_title")
	if _collapse_button != null:
		_collapse_button.text = tr("fish.map.collapse") if _display_mode == "expanded" else tr("fish.map.expand")
	_sync_compact_sea_chart()
	_sync_canvas_activity()
	if _map_canvas != null and _map_canvas.visible:
		_map_canvas.queue_redraw()
	if _depth_quality_canvas != null and _depth_quality_canvas.visible:
		_depth_quality_canvas.queue_redraw()


func _sync_canvas_activity() -> void:
	var tab_index := _map_tabs.current_tab if _map_tabs != null else 0
	var expanded := _display_mode == "expanded"
	var resource_map_active := expanded and tab_index != 2
	var depth_chart_active := expanded and tab_index == 2
	if _map_canvas != null:
		_map_canvas.set_raster_build_enabled(false)
		_map_canvas.set_boat_pulse_enabled(false)
		_map_canvas.visible = resource_map_active
		_map_canvas.set_resource_overlay_enabled(resource_map_active and tab_index == 0)
		_map_canvas.set_raster_build_enabled(resource_map_active)
		_map_canvas.set_boat_pulse_enabled(resource_map_active)
		if resource_map_active:
			_map_canvas.ensure_raster()
	if _depth_quality_canvas != null:
		_depth_quality_canvas.set_chart_active(false)
		_depth_quality_canvas.visible = depth_chart_active
		_depth_quality_canvas.mouse_filter = Control.MOUSE_FILTER_STOP if expanded else Control.MOUSE_FILTER_IGNORE
		_depth_quality_canvas.set_compact_mode(_display_mode == "mini")
		_depth_quality_canvas.set_chart_active(depth_chart_active)


func _sync_compact_sea_chart() -> void:
	if _compact_sea_chart == null:
		return
	var chart_visible := _display_mode == "mini"
	_compact_sea_chart.visible = chart_visible
	_compact_sea_chart.set_process(chart_visible)
	var chart_view := _compact_sea_chart.find_child("Chart", true, false) as Control
	if chart_view != null:
		chart_view.set_process(chart_visible)


func refresh_localized_text() -> void:
	if _map_tabs != null:
		_map_tabs.set_tab_title(0, tr("fish.map.tab.fish_resources"))
		_map_tabs.set_tab_title(1, tr("fish.map.route_tab"))
		_map_tabs.set_tab_title(2, tr("fish.map.depth_tab"))
	if _title_label != null:
		_title_label.text = tr("fish.map.title") if _display_mode == "expanded" else tr("fish.map.mini_title")
	if _collapse_button != null:
		_collapse_button.text = tr("fish.map.collapse") if _display_mode == "expanded" else tr("fish.map.expand")
	if _hide_button != null:
		_hide_button.text = tr("fish.map.hide")
	if _map_close_button != null:
		_map_close_button.tooltip_text = tr("fish.map.hide")
	if _subtitle_label != null:
		_subtitle_label.text = _localized_map_subtitle(_map_tabs.current_tab if _map_tabs != null else 0)
	if _fish_filter_heading != null:
		_fish_filter_heading.text = tr("fish.map.species_heading")
	if _fish_filter_hint != null:
		_fish_filter_hint.text = tr("fish.map.filter_hint")
	if _dolphin_filter_button != null:
		_dolphin_filter_button.text = tr("fish.map.dolphin_filter")
	if _manager != null:
		for profile in _manager.get_species_profiles():
			var species_button := _species_buttons.get(profile.species_id) as CheckButton
			if species_button != null:
				species_button.text = tr("fish.map.species_filter") % [tr(profile.name_key), profile.scientific_name]
	if _detail_heading != null:
		_detail_heading.text = tr("fish.map.detail_heading")
	if _map_legend != null:
		var species_legend := PackedStringArray()
		for profile in _manager.get_species_profiles():
			species_legend.append(tr("fish.map.legend.species") % tr(profile.name_key))
		_map_legend.text = "%s  %s\n%s\n%s" % ["  ".join(species_legend), tr("fish.map.legend.dolphins"), tr("fish.map.legend.visual_logical"), tr("fish.map.legend.depth_source")]
	if _depth_heading != null:
		_depth_heading.text = tr("fish.map.depth_quality_heading")
	if _depth_instructions != null:
		_depth_instructions.text = tr("fish.map.depth_quality_instructions")
	if _depth_note != null:
		_depth_note.text = tr("fish.map.depth_quality.note")
	if _depth_quality_legend_labels.size() >= 2:
		_depth_quality_legend_labels[0].text = tr("fish.map.depth_quality.estimated")
		_depth_quality_legend_labels[1].text = tr("fish.map.depth_quality.unknown")
	if _depth_zoom_in_button != null:
		_depth_zoom_in_button.text = tr("fish.map.zoom_in")
	if _depth_zoom_out_button != null:
		_depth_zoom_out_button.text = tr("fish.map.zoom_out")
	if _depth_reset_button != null:
		_depth_reset_button.text = tr("fish.map.reset_view")
	if _route_editor_toggle != null:
		_route_editor_toggle.text = tr("fish.map.route_editor_close") if _route_editor != null and _route_editor.is_editor_open() else tr("fish.map.route_editor_open")
	_update_footer_label()
	_update_summary_label()
	_refresh_route_overlay()
	_update_depth_quality_summary()


func _set_species_enabled(species_id: String, enabled: bool) -> void:
	if enabled and not _selected_species.has(species_id):
		_selected_species.append(species_id)
	elif not enabled:
		_selected_species.erase(species_id)
	_save_tracking_preferences()
	refresh_data()


func _set_dolphins_enabled(enabled: bool) -> void:
	_dolphins_enabled = enabled
	if _map_canvas != null:
		_map_canvas.set_dolphins_enabled(enabled)
	_save_tracking_preferences()
	_update_summary_label()


func _on_map_tab_changed(tab_index: int) -> void:
	_sync_canvas_activity()
	if _title_label != null:
		_title_label.text = [tr("fish.map.title"), tr("fish.map.route_tab"), tr("fish.map.depth_tab")][clampi(tab_index, 0, 2)]
	if _subtitle_label != null:
		_subtitle_label.text = _localized_map_subtitle(tab_index)
	if tab_index != 1 and _route_editor != null and _route_editor.is_editor_open():
		_route_editor.set_editor_open(false)
		if _route_editor_toggle != null:
			_route_editor_toggle.text = tr("fish.map.route_editor_open")
	_refresh_route_overlay()
	_update_footer_label()
	_update_depth_quality_summary()


func _localized_map_subtitle(tab_index: int) -> String:
	match clampi(tab_index, 0, 2):
		1: return tr("fish.map.route_subtitle")
		2: return tr("fish.map.depth_subtitle")
	return tr("fish.map.subtitle")


func _quality_legend_row(color: Color, key: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var swatch := ColorRect.new()
	swatch.color = color
	swatch.custom_minimum_size = Vector2(15.0, 15.0)
	row.add_child(swatch)
	var label := Label.new()
	label.text = tr(key)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_color_override("font_color", color.lightened(0.2))
	row.add_child(label)
	_depth_quality_legend_labels.append(label)
	return row


func _update_depth_quality_summary() -> void:
	if _depth_quality_summary == null or _depth_quality_canvas == null:
		return
	_depth_quality_summary.text = tr("fish.map.depth_quality.summary") % [
		_format_count(_depth_quality_canvas.get_estimated_cell_count()),
		_format_count(_depth_quality_canvas.get_unresolved_cell_count()),
	]


func _format_count(value: int) -> String:
	return "%d,%03d" % [int(value / 1000), value % 1000] if value >= 1000 else "%d" % value


func _update_footer_label() -> void:
	if _footer_label == null:
		return
	if _map_tabs != null and _map_tabs.current_tab == 2:
		_footer_label.text = tr("fish.map.depth_quality.footer")
	elif _manager != null:
		_footer_label.text = tr("fish.map.footer") % [_manager.get_authority_source(), _manager.get_world_seed(), _manager.get_state_revision()]


func _load_tracking_preferences() -> void:
	var error := _map_settings.load(MAP_SETTINGS_PATH)
	if error == ERR_FILE_NOT_FOUND:
		return
	if error != OK:
		push_warning("Could not load fish map tracking preferences: %s" % error_string(error))
		return
	var saved: Variant = _map_settings.get_value(MAP_SETTINGS_SECTION, MAP_SETTINGS_ENABLED_SPECIES_KEY, PackedStringArray())
	if saved is PackedStringArray or saved is Array:
		for item in saved:
			var species_id := str(item)
			if not species_id.is_empty() and not _selected_species.has(species_id):
				_selected_species.append(species_id)
	_dolphins_enabled = bool(_map_settings.get_value(MAP_SETTINGS_SECTION, MAP_SETTINGS_DOLPHINS_ENABLED_KEY, true))


func _save_tracking_preferences() -> void:
	var enabled_species := PackedStringArray()
	for species_id in _selected_species:
		enabled_species.append(species_id)
	_map_settings.set_value(MAP_SETTINGS_SECTION, MAP_SETTINGS_ENABLED_SPECIES_KEY, enabled_species)
	_map_settings.set_value(MAP_SETTINGS_SECTION, MAP_SETTINGS_DOLPHINS_ENABLED_KEY, _dolphins_enabled)
	var error := _map_settings.save(MAP_SETTINGS_PATH)
	if error != OK:
		push_warning("Could not save fish map tracking preferences: %s" % error_string(error))


func _on_school_selected(school: Dictionary) -> void:
	if school.is_empty():
		_details_label.text = tr("fish.map.empty_selection")
		return
	_update_school_details(school)


func _on_school_hovered(school: Dictionary) -> void:
	if not school.is_empty():
		_update_school_details(school)


func _update_school_details(school: Dictionary) -> void:
	if bool(school.get("is_dolphin", false)):
		var position_data: Array = school.get("world_position", [])
		var gps_text := tr("fish.map.position_unknown")
		if position_data.size() >= 3 and _georeference != null:
			var geodetic := _georeference.world_to_geodetic(Vector3(float(position_data[0]), 0.0, float(position_data[2])))
			gps_text = tr("fish.map.gps_format") % [absf(geodetic.x), tr("hud.direction.short.north") if geodetic.x >= 0.0 else tr("hud.direction.short.south"), absf(geodetic.y), tr("hud.direction.short.east") if geodetic.y >= 0.0 else tr("hud.direction.short.west")]
		_details_label.text = tr("fish.map.dolphin_details") % [
			str(school.get("pod_id", "")),
			int(school.get("population", 0)),
			tr("fish.map.dolphin_following") if bool(school.get("is_following", false)) else tr("fish.map.dolphin_not_following"),
			tr("fish.map.dolphin_state.%s" % str(school.get("movement_state_id", "cruise"))),
			float(school.get("activity_depth_m", 0.0)),
			float(school.get("last_updated", 0.0)),
			gps_text,
		]
		return
	var profile := _manager.get_species_profile(str(school.get("species_id", "")))
	if profile == null:
		return
	var render_state := str(school.get("render_state", "visual"))
	var surface_species := profile.surface_activity_cycle_enabled
	var render_key := "fish.map.render.visual_layer" if render_state == "visual" else "fish.map.render.logical_layer"
	var render_label := tr(render_key) % profile.logical_depth_threshold_m if surface_species else tr("fish.map.render.resource_point")
	var position_data: Array = school.get("world_position", [])
	var gps_text := tr("fish.map.position_unknown")
	var behavior_text := _localized_school_activity(profile, school)
	var depth_value := float(school.get("activity_depth_m", 0.0)) if surface_species else float(school.get("depth_m", 0.0))
	var depth_label := tr("fish.map.activity_depth") if surface_species else tr("fish.map.chart_depth")
	var habitat_text := _localized_habitat(str(school.get("habitat_region", "unknown")))
	if position_data.size() >= 3 and _georeference != null:
		var geodetic := _georeference.world_to_geodetic(Vector3(float(position_data[0]), 0.0, float(position_data[2])))
		gps_text = tr("fish.map.gps_format") % [absf(geodetic.x), tr("hud.direction.short.north") if geodetic.x >= 0.0 else tr("hud.direction.short.south"), absf(geodetic.y), tr("hud.direction.short.east") if geodetic.y >= 0.0 else tr("hud.direction.short.west")]
	_details_label.text = tr("fish.map.details.format") % [
		tr(profile.name_key),
		profile.scientific_name,
		render_label,
		tr(profile.description_key),
		depth_label,
		depth_value,
		tr("fish.map.chart_depth"),
		float(school.get("depth_m", 0.0)),
		tr("fish.map.habitat_label"),
		habitat_text,
		tr("fish.map.location_label"),
		gps_text,
		_population_band(int(school.get("population", 0))),
		int(school.get("population", 0)),
		tr("fish.map.activity_label"),
		behavior_text,
		tr("fish.map.resource_label"),
		tr("fish.map.resource.%s" % str(school.get("resource_state", "available"))),
	]


func _localized_school_activity(profile: FishSpeciesProfile, school: Dictionary) -> String:
	var state_id := str(school.get("surface_activity_state", "inactive")) if profile.surface_activity_cycle_enabled else str(school.get("movement_state", "cruise"))
	var key := "fish.map.activity.%s" % state_id
	var translated := tr(key)
	return translated if translated != key else tr("fish.map.activity.unknown")


func _localized_habitat(habitat_id: String) -> String:
	var key := "fish.map.habitat.%s" % habitat_id
	var translated := tr(key)
	return translated if translated != key else tr("fish.map.habitat.unknown")


func _population_band(population: int) -> String:
	if population < 12:
		return tr("fish.map.population.small")
	if population < 45:
		return tr("fish.map.population.medium")
	return tr("fish.map.population.large")


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
