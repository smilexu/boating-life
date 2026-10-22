extends PanelContainer

signal vessel_selected(sailing: bool)

const PREVIEW_SIZE := Vector2i(420, 250)
const EXCLUDED_ANCESTOR_NAMES := [
	"CargoSlots",
	"WakeSystem",
	"ExhaustSmokeSystem",
	"BoatSkyFill",
	"RudderAngleMarker",
]

var _is_sailing := false
var _source_root: Node3D
var _viewport: SubViewport
var _preview_root: Node3D
var _select_button: Button
var _preview_notice: Label
var _preview_enabled := false


func _ready() -> void:
	set_process(false)
	var camera := _viewport.get_node_or_null("PreviewCamera") as Camera3D if _viewport != null else null
	if camera != null:
		camera.make_current()


func configure(
	sailing: bool,
	vessel_name: String,
	vessel_type: String,
	details: String,
	source_root: Node3D
) -> void:
	_is_sailing = sailing
	_source_root = source_root
	custom_minimum_size = Vector2(370.0, 440.0)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_build_card(vessel_name, vessel_type, details)
	_refresh_preview()
	set_current(false)


func set_current(current: bool) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.055, 0.12, 0.15, 0.96) if current else Color(0.075, 0.15, 0.18, 0.96)
	style.border_color = Color(0.44, 0.76, 0.69, 0.95) if current else Color(0.25, 0.39, 0.42, 0.9)
	style.set_border_width_all(2 if current else 1)
	style.set_corner_radius_all(9)
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 12.0
	style.content_margin_bottom = 12.0
	add_theme_stylebox_override("panel", style)
	if _select_button != null:
		_select_button.disabled = current
		_select_button.text = "当前驾驶中" if current else "选择这艘船"


func is_sailing_vessel() -> bool:
	return _is_sailing


func set_preview_enabled(enabled: bool) -> void:
	_preview_enabled = enabled
	set_process(enabled)
	if _viewport == null:
		return
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if enabled else SubViewport.UPDATE_DISABLED
	if enabled:
		_refresh_preview()


func _process(delta: float) -> void:
	if _preview_enabled and _preview_root != null:
		_preview_root.rotate_y(delta * 0.22)


func _build_card(vessel_name: String, vessel_type: String, details: String) -> void:
	var layout := VBoxContainer.new()
	layout.name = "CardLayout"
	layout.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layout.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_theme_constant_override("separation", 8)
	add_child(layout)

	var preview_frame := PanelContainer.new()
	preview_frame.custom_minimum_size = Vector2(0.0, 220.0)
	var preview_style := StyleBoxFlat.new()
	preview_style.bg_color = Color(0.035, 0.085, 0.105, 1.0)
	preview_style.set_corner_radius_all(6)
	preview_style.content_margin_left = 0.0
	preview_style.content_margin_right = 0.0
	preview_style.content_margin_top = 0.0
	preview_style.content_margin_bottom = 0.0
	preview_frame.add_theme_stylebox_override("panel", preview_style)
	layout.add_child(preview_frame)
	var preview_content := Control.new()
	preview_content.name = "PreviewContent"
	preview_content.custom_minimum_size = Vector2(0.0, 220.0)
	preview_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview_frame.add_child(preview_content)
	var preview_container := SubViewportContainer.new()
	preview_container.name = "ModelPreviewContainer"
	preview_container.stretch = true
	preview_container.mouse_filter = Control.MOUSE_FILTER_STOP
	preview_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	preview_content.add_child(preview_container)
	_viewport = SubViewport.new()
	_viewport.name = "ModelPreviewViewport"
	_viewport.size = PREVIEW_SIZE
	_viewport.own_world_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	preview_container.add_child(_viewport)
	_build_preview_world()

	_preview_notice = Label.new()
	_preview_notice.text = "模型预览不可用"
	_preview_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_preview_notice.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_preview_notice.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_preview_notice.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview_notice.visible = false
	preview_content.add_child(_preview_notice)

	var type_label := Label.new()
	type_label.name = "VesselTypeLabel"
	type_label.text = vessel_type
	type_label.add_theme_font_size_override("font_size", 13)
	type_label.add_theme_color_override("font_color", Color(0.52, 0.79, 0.75))
	layout.add_child(type_label)
	var name_label := Label.new()
	name_label.name = "VesselNameLabel"
	name_label.text = vessel_name
	name_label.add_theme_font_size_override("font_size", 20)
	name_label.add_theme_color_override("font_color", Color(0.95, 0.97, 0.94))
	layout.add_child(name_label)
	var detail_label := Label.new()
	detail_label.name = "VesselDetailsLabel"
	detail_label.text = details
	detail_label.custom_minimum_size.y = 84.0
	detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail_label.add_theme_font_size_override("font_size", 14)
	detail_label.add_theme_color_override("font_color", Color(0.80, 0.87, 0.86))
	layout.add_child(detail_label)
	_select_button = Button.new()
	_select_button.name = "SelectButton"
	_select_button.custom_minimum_size.y = 40.0
	_select_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_select_button.pressed.connect(func() -> void: vessel_selected.emit(_is_sailing))
	layout.add_child(_select_button)


func _build_preview_world() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.035, 0.105, 0.13, 1.0)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.66, 0.78, 0.82)
	environment.ambient_light_energy = 0.72
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	_viewport.add_child(world_environment)

	_preview_root = Node3D.new()
	_preview_root.name = "PreviewModelRoot"
	_viewport.add_child(_preview_root)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-38.0, -32.0, 0.0)
	light.light_color = Color(1.0, 0.93, 0.80)
	light.light_energy = 1.15
	light.shadow_enabled = false
	_viewport.add_child(light)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-18.0, 145.0, 0.0)
	fill.light_color = Color(0.48, 0.68, 0.85)
	fill.light_energy = 0.42
	fill.shadow_enabled = false
	_viewport.add_child(fill)
	var camera := Camera3D.new()
	camera.name = "PreviewCamera"
	camera.fov = 38.0
	camera.near = 0.05
	camera.far = 100.0
	camera.current = true
	_viewport.add_child(camera)


func _refresh_preview() -> void:
	if _viewport == null or _preview_root == null:
		return
	for child in _preview_root.get_children():
		_preview_root.remove_child(child)
		child.queue_free()
	_preview_root.position = Vector3.ZERO
	_preview_root.rotation = Vector3.ZERO
	_preview_notice.visible = true
	if not is_instance_valid(_source_root):
		return

	var source_inverse := _source_root.global_transform.affine_inverse()
	var bounds_min := Vector3(INF, INF, INF)
	var bounds_max := Vector3(-INF, -INF, -INF)
	var mesh_count := 0
	for source_mesh in _source_root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := source_mesh as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null or not _is_visible_to_source_root(mesh_instance):
			continue
		var copy := MeshInstance3D.new()
		copy.name = mesh_instance.name
		copy.mesh = mesh_instance.mesh
		copy.transform = source_inverse * mesh_instance.global_transform
		copy.material_override = mesh_instance.material_override
		copy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		copy.layers = 1
		for surface_index in range(mesh_instance.mesh.get_surface_count()):
			var surface_material := mesh_instance.get_surface_override_material(surface_index)
			if surface_material == null:
				surface_material = mesh_instance.mesh.surface_get_material(surface_index)
			if surface_material != null:
				copy.set_surface_override_material(surface_index, surface_material)
		_preview_root.add_child(copy)
		mesh_count += 1
		var mesh_aabb := mesh_instance.get_aabb()
		for corner in _aabb_corners(mesh_aabb):
			var point := copy.transform * corner
			bounds_min = bounds_min.min(point)
			bounds_max = bounds_max.max(point)

	if mesh_count == 0:
		return
	_preview_notice.visible = false
	var bounds_size := bounds_max - bounds_min
	var center := (bounds_min + bounds_max) * 0.5
	_preview_root.position = -center
	var radius := maxf(bounds_size.length() * 0.5, 0.75)
	var camera := _viewport.get_node("PreviewCamera") as Camera3D
	if camera != null:
		var distance := radius * 3.15
		camera.position = Vector3(distance * 0.48, distance * 0.33, -distance * 0.82)
		camera.look_at_from_position(camera.position, Vector3.ZERO, Vector3.UP)
	_preview_root.rotation.y = deg_to_rad(-16.0)


func _is_visible_to_source_root(node: Node) -> bool:
	var cursor: Node = node
	while cursor != null:
		if cursor == _source_root:
			return true
		if cursor is Node3D and not (cursor as Node3D).visible:
			return false
		if EXCLUDED_ANCESTOR_NAMES.has(String(cursor.name)):
			return false
		cursor = cursor.get_parent()
	return false


func _aabb_corners(bounds: AABB) -> Array[Vector3]:
	var corners: Array[Vector3] = []
	for x_value in [bounds.position.x, bounds.position.x + bounds.size.x]:
		for y_value in [bounds.position.y, bounds.position.y + bounds.size.y]:
			for z_value in [bounds.position.z, bounds.position.z + bounds.size.z]:
				corners.append(Vector3(float(x_value), float(y_value), float(z_value)))
	return corners
