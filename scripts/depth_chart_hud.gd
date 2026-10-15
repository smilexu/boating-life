extends CanvasLayer

## Compact, north-up depth chart HUD. It uses the shared BathymetryManager and
## the active boat transform; it does not touch navigation or the ocean.

const DEPTH_CHART_VIEW_SCRIPT := preload("res://scripts/depth_chart_view.gd")

@export_node_path("Node") var bathymetry_manager_path := NodePath("../BathymetryManager")
@export_node_path("Node3D") var boat_path := NodePath("../PlayerBoat/MotionRoot")

var _manager: BathymetryManager
var _boat: Node3D
var _panel: PanelContainer
var _depth_value: Label
var _quality_label: Label
var _chart_view: DepthChartView
var _refresh_elapsed := 0.0


func _ready() -> void:
	_manager = get_node_or_null(bathymetry_manager_path) as BathymetryManager
	_boat = get_node_or_null(boat_path) as Node3D
	if _manager == null or _boat == null:
		push_error("DepthChartHUD needs BathymetryManager and PlayerBoat/MotionRoot references.")
		return
	_build_panel()
	_update_layout()
	get_viewport().size_changed.connect(_update_layout)


func _process(delta: float) -> void:
	_refresh_elapsed += delta
	if _refresh_elapsed >= 0.5:
		_refresh_elapsed = fmod(_refresh_elapsed, 0.5)
		_update_depth_readout()


func _build_panel() -> void:
	_panel = PanelContainer.new()
	_panel.name = "DepthChartPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.custom_minimum_size = Vector2(356.0, 0.0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.025, 0.085, 0.11, 0.93)
	style.border_color = Color(0.36, 0.63, 0.67, 0.78)
	style.set_border_width_all(1)
	style.set_corner_radius_all(9)
	style.content_margin_left = 13.0
	style.content_margin_right = 13.0
	style.content_margin_top = 10.0
	style.content_margin_bottom = 10.0
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)

	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 4)
	_panel.add_child(layout)

	var heading := HBoxContainer.new()
	layout.add_child(heading)
	var title := Label.new()
	title.text = "SEA CHART  ·  ØRESUND"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_color_override("font_color", Color(0.69, 0.86, 0.83, 1.0))
	title.add_theme_font_size_override("font_size", 13)
	heading.add_child(title)
	var north_tag := Label.new()
	north_tag.text = "N ↑"
	north_tag.add_theme_color_override("font_color", Color(0.85, 0.91, 0.86, 0.92))
	north_tag.add_theme_font_size_override("font_size", 12)
	heading.add_child(north_tag)

	var depth_row := HBoxContainer.new()
	depth_row.alignment = BoxContainer.ALIGNMENT_BEGIN
	layout.add_child(depth_row)
	_depth_value = Label.new()
	_depth_value.text = "-- m"
	_depth_value.add_theme_color_override("font_color", Color(0.96, 0.98, 0.91, 1.0))
	_depth_value.add_theme_font_size_override("font_size", 29)
	var depth_font := SystemFont.new()
	depth_font.font_names = PackedStringArray(["Menlo", "Consolas", "Courier New", "monospace"])
	_depth_value.add_theme_font_override("font", depth_font)
	depth_row.add_child(_depth_value)
	_quality_label = Label.new()
	_quality_label.text = "估算海图深度 · LAT"
	_quality_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_quality_label.add_theme_color_override("font_color", Color(0.66, 0.78, 0.78, 1.0))
	_quality_label.add_theme_font_size_override("font_size", 11)
	depth_row.add_child(_quality_label)

	_chart_view = DEPTH_CHART_VIEW_SCRIPT.new() as DepthChartView
	_chart_view.name = "Chart"
	_chart_view.configure(_manager, _boat)
	layout.add_child(_chart_view)

	var attribution := Label.new()
	attribution.text = "EMODnet DTM 2024 · LAT  |  不作安全导航用途"
	attribution.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	attribution.add_theme_color_override("font_color", Color(0.60, 0.73, 0.73, 0.9))
	attribution.add_theme_font_size_override("font_size", 10)
	layout.add_child(attribution)


func _update_layout() -> void:
	if _panel == null:
		return
	_panel.anchor_left = 0.0
	_panel.anchor_top = 1.0
	_panel.anchor_right = 0.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = 24.0
	_panel.offset_top = -431.0
	_panel.offset_right = 380.0
	_panel.offset_bottom = -22.0


func _update_depth_readout() -> void:
	if _manager == null or _boat == null or _chart_view == null:
		return
	var result := _manager.get_depth_at_world_position(_boat.global_position)
	if not bool(result.get("valid", false)):
		_depth_value.text = "-- m"
		var reason := str(result.get("reason", ""))
		if reason.begins_with("Outside"):
			_quality_label.text = "OUTSIDE DTM COVERAGE"
		elif reason.begins_with("Land"):
			_quality_label.text = "LAND / NO DATA"
		else:
			_quality_label.text = "DATA UNAVAILABLE"
		return
	_depth_value.text = "%.1f m" % float(result["depth_m"])
	if bool(result.get("interpolated", false)):
		_quality_label.text = "估算值 · DTM 插值 · LAT"
	else:
		var samples := int(result.get("quality", -1.0))
		_quality_label.text = "估算值 · LAT" if samples < 0 else "估算值 · %d 个输入值 · LAT" % samples
