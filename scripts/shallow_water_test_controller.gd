extends Node

## Standalone visual validation harness for the production sea shader.
## It substitutes only a local, controlled RG8 bathymetry texture at runtime.

const TEST_BOUNDS := Vector4(-22.0, -14.0, 22.0, 14.0)
const TEST_TEXTURE_SIZE := Vector2i(512, 128)
const DEPTH_DRAW_MODES := ["depth_draw_always", "depth_prepass_alpha", "depth_draw_never"]
const DEPTH_DRAW_LABELS := ["always (current)", "prepass_alpha", "never"]

@onready var _main: Node3D = get_node("../Main")

var _water_material: ShaderMaterial
var _test_shader: Shader
var _base_shader_code := ""
var _depth_texture: ImageTexture
var _depth_draw_index := 0
var _transparency_enabled := true
var _mask_visible := false
var _top_camera: Camera3D
var _oblique_camera: Camera3D
var _info_label: Label


func _ready() -> void:
	await get_tree().process_frame
	_prepare_main_scene()
	_build_test_geometry()
	_build_controlled_depth_texture()
	_prepare_test_material()
	_build_cameras()
	_build_overlay()
	_apply_material_to_runtime_owners()
	_set_transparency_enabled(true)
	_set_depth_draw_mode(0)
	_set_time_of_day(false)
	_update_overlay()


func _process(_delta: float) -> void:
	_update_overlay()


func _unhandled_key_input(event: InputEvent) -> void:
	if event is not InputEventKey or not event.pressed or event.echo:
		return
	match event.physical_keycode:
		KEY_1:
			_top_camera.make_current()
		KEY_2:
			_oblique_camera.make_current()
		KEY_P:
			_set_transparency_enabled(not _transparency_enabled)
		KEY_D:
			_set_depth_draw_mode((_depth_draw_index + 1) % DEPTH_DRAW_MODES.size())
		KEY_V:
			_mask_visible = not _mask_visible
			_water_material.set_shader_parameter("water_diagnostic_mode", 13 if _mask_visible else 0)
		KEY_F5:
			_set_time_of_day(false)
		KEY_F6:
			_set_time_of_day(true)
		KEY_ESCAPE:
			get_tree().quit()
	_update_overlay()


func _prepare_main_scene() -> void:
	# This harness runs the real project environment, weather, day/night,
	# bathymetry loader, ocean and boat scene without the far OSM terrain obscuring
	# the controlled seabed patches.
	var terrain := _main.get_node_or_null("OresundRegion")
	if terrain != null:
		terrain.set("visible", false)
		terrain.set_process(false)
	var depth_hud := _main.get_node_or_null("DepthChartHUD")
	if depth_hud != null:
		depth_hud.set("visible", false)
	var boat := _main.get_node("PlayerBoat") as Node3D
	boat.global_position = Vector3(0.0, 0.0, 29.0)
	boat.rotation = Vector3.ZERO
	var boat_controller := _main.get_node("PlayerBoat/MotionRoot")
	boat_controller.set("is_motion_paused", true)
	var boat_camera := _main.get_node("PlayerBoat/FollowCameraRig/Camera3D") as Camera3D
	boat_camera.current = false
	var boat_hud := _main.get_node_or_null("PlayerBoat/BoatHUD")
	if boat_hud != null:
		boat_hud.set("visible", false)
	var weather := _main.get_node("WeatherController")
	weather.call("set_weather_by_index", 0)
	var time_manager := get_node_or_null("/root/WorldTimeManager")
	if time_manager != null:
		time_manager.set("autosave_enabled", false)
		time_manager.call("pause_time")
	var ocean := _main.get_node("Ocean")
	ocean.set("far_edge", 4000.0)
	ocean.set("outermost_resolution", 12)
	ocean.set("levels_of_detail", 4)
	ocean.call_deferred("build_meshes")


func _build_test_geometry() -> void:
	var sand_shallow := _make_ground_material(Color("#d5c19c"))
	var sand_middle := _make_ground_material(Color("#a89b80"))
	var sand_deep := _make_ground_material(Color("#6f7d80"))
	var no_data_ground := _make_ground_material(Color("#c8b88e"))
	_add_bed("Seabed_2m", Vector3(-17.0, -2.12, 0.0), Vector3(8.0, 0.24, 27.0), sand_shallow)
	_add_bed("Seabed_5m", Vector3(-5.0, -5.12, 0.0), Vector3(8.0, 0.24, 27.0), sand_middle)
	_add_bed("Seabed_9m_opaque_control", Vector3(6.5, -9.12, 0.0), Vector3(8.0, 0.24, 27.0), sand_deep)
	_add_bed("Seabed_NoData_opaque_control", Vector3(17.5, -2.12, 0.0), Vector3(8.0, 0.24, 27.0), no_data_ground)

	var rock_material := _make_ground_material(Color("#717a7d"))
	_add_rock("Rock_Large", Vector3(-17.4, -1.48, -1.2), Vector3(1.85, 1.05, 1.50), rock_material)
	_add_rock("Rock_Small", Vector3(-15.6, -1.66, 2.2), Vector3(1.10, 0.72, 0.92), rock_material)
	_add_rock("Rock_Flat", Vector3(-18.6, -1.78, 3.4), Vector3(1.20, 0.48, 1.38), _make_ground_material(Color("#81898a")))


func _add_bed(node_name: String, position: Vector3, size: Vector3, material: Material) -> void:
	var floor := MeshInstance3D.new()
	floor.name = node_name
	var mesh := BoxMesh.new()
	mesh.size = size
	floor.mesh = mesh
	floor.position = position
	floor.material_override = material
	floor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(floor)


func _add_rock(node_name: String, position: Vector3, size: Vector3, material: Material) -> void:
	var rock := MeshInstance3D.new()
	rock.name = node_name
	var mesh := SphereMesh.new()
	mesh.radius = 0.5
	mesh.height = 1.0
	mesh.radial_segments = 14
	mesh.rings = 8
	rock.mesh = mesh
	rock.position = position
	rock.scale = size
	rock.material_override = material
	rock.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(rock)


func _make_ground_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.96
	material.metallic = 0.0
	return material


func _build_controlled_depth_texture() -> void:
	var image := Image.create(TEST_TEXTURE_SIZE.x, TEST_TEXTURE_SIZE.y, false, Image.FORMAT_RG8)
	for y in range(TEST_TEXTURE_SIZE.y):
		for x in range(TEST_TEXTURE_SIZE.x):
			var east := lerpf(TEST_BOUNDS.x, TEST_BOUNDS.z, (float(x) + 0.5) / float(TEST_TEXTURE_SIZE.x))
			var depth_m := 9.0
			var valid := 1.0
			if east < -12.0:
				depth_m = 2.0
			elif east < -9.0:
				depth_m = lerpf(2.0, 5.0, (east + 12.0) / 3.0)
			elif east < -1.0:
				depth_m = 5.0
			elif east < 2.0:
				depth_m = lerpf(5.0, 9.0, (east + 1.0) / 3.0)
			elif east < 12.0:
				depth_m = 9.0
			elif east < 14.0:
				depth_m = 9.0
				valid = 1.0 - (east - 12.0) / 2.0
			else:
				valid = 0.0
			image.set_pixel(x, y, Color(clampf(depth_m / 64.0, 0.0, 1.0), clampf(valid, 0.0, 1.0), 0.0, 1.0))
	_depth_texture = ImageTexture.create_from_image(image)


func _prepare_test_material() -> void:
	var ocean := _main.get_node("Ocean")
	var original := ocean.get("material") as ShaderMaterial
	if original == null or original.shader == null:
		push_error("ShallowWaterTest requires the project's ShaderMaterial on Ocean.")
		return
	_water_material = original.duplicate(true) as ShaderMaterial
	_test_shader = original.shader.duplicate() as Shader
	_base_shader_code = _test_shader.code
	_water_material.shader = _test_shader
	_water_material.set_shader_parameter("bathymetry_depth_texture", _depth_texture)
	_water_material.set_shader_parameter("bathymetry_bounds_east_north", TEST_BOUNDS)
	# Disable depth tint in this harness so the local texture bounds do not show
	# as a colored rectangle; the same RG depth/coverage sampling still drives
	# transmission, while the production material retains depth tint unchanged.
	_water_material.set_shader_parameter("enable_depth_color", false)
	_water_material.set_shader_parameter("shallow_transparency_enabled", true)
	_water_material.set_shader_parameter("shallow_max_depth", 6.0)
	_water_material.set_shader_parameter("shallow_fade_start", 4.0)
	_water_material.set_shader_parameter("shallow_min_alpha", 0.62)
	_water_material.set_shader_parameter("shallow_transmission_strength", 0.60)
	_water_material.set_shader_parameter("shallow_absorption_per_meter", 0.06)
	_water_material.set_shader_parameter("shallow_bottom_depth_padding", 1.5)
	_water_material.set_shader_parameter("water_diagnostic_mode", 0)


func _apply_material_to_runtime_owners() -> void:
	if _water_material == null:
		return
	_main.get_node("Ocean").set("material", _water_material)
	_main.get_node("WaveSampler").set("water_material", _water_material)
	_main.get_node("BathymetryManager").set("water_material", _water_material)
	_main.get_node("WeatherController").set("water_material", _water_material)
	_main.get_node("QualityManager").set("water_material", _water_material)
	_main.get_node("DayNightVisualController").set("_water_material", _water_material)


func _build_cameras() -> void:
	_top_camera = Camera3D.new()
	_top_camera.name = "TopDownTestCamera"
	_top_camera.fov = 58.0
	_top_camera.near = 0.05
	_top_camera.far = 4000.0
	_top_camera.position = Vector3(0.0, 48.0, 0.0)
	add_child(_top_camera)
	_top_camera.look_at(Vector3(0.0, -4.0, 0.0), Vector3(0.0, 0.0, -1.0))

	_oblique_camera = Camera3D.new()
	_oblique_camera.name = "ObliqueTestCamera"
	_oblique_camera.fov = 58.0
	_oblique_camera.near = 0.05
	_oblique_camera.far = 4000.0
	_oblique_camera.position = Vector3(0.0, 26.0, 55.0)
	add_child(_oblique_camera)
	_oblique_camera.look_at(Vector3(0.0, -2.0, 0.0), Vector3.UP)
	_oblique_camera.make_current()


func _build_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.name = "ShallowWaterTestOverlay"
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(14.0, 14.0)
	panel.custom_minimum_size = Vector2(650.0, 112.0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.025, 0.07, 0.09, 0.90)
	style.border_color = Color(0.39, 0.72, 0.78, 0.8)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(10.0)
	panel.add_theme_stylebox_override("panel", style)
	layer.add_child(panel)
	_info_label = Label.new()
	_info_label.add_theme_color_override("font_color", Color(0.88, 0.94, 0.94))
	_info_label.add_theme_font_size_override("font_size", 14)
	panel.add_child(_info_label)


func _set_transparency_enabled(enabled: bool) -> void:
	_transparency_enabled = enabled
	_water_material.set_shader_parameter("shallow_transparency_enabled", enabled)
	if not enabled:
		_mask_visible = false
		_water_material.set_shader_parameter("water_diagnostic_mode", 0)


func _set_depth_draw_mode(index: int) -> void:
	_depth_draw_index = index
	var replacement := _base_shader_code.replace("depth_draw_always", DEPTH_DRAW_MODES[index])
	_test_shader.code = replacement


func _set_time_of_day(night: bool) -> void:
	var time_manager := get_node_or_null("/root/WorldTimeManager")
	if time_manager == null:
		return
	time_manager.call("pause_time")
	if night:
		# A known full-moon date makes the moonlit material comparison visible.
		time_manager.call("set_calendar_date", 2026, 10, 26)
	else:
		time_manager.call("clear_calendar_override")
	time_manager.call("set_cycle_time", 23 if night else 12, 0, 0.0)


func _update_overlay() -> void:
	if _info_label == null or _water_material == null:
		return
	var mode_name := "transmission mask" if _mask_visible else "normal surface"
	var day_name := "night" if float(_water_material.get_shader_parameter("night_visual_weight")) > 0.5 else "day"
	_info_label.text = "SHALLOW WATER VALIDATION  ·  %s  ·  %s\n" % [day_name, mode_name]
	_info_label.text += "Depth Draw: %s     Transparency: %s     Depth mask: 2 m / 5 m / 9 m / no-data (test tint off)\n" % [
		DEPTH_DRAW_LABELS[_depth_draw_index], "ON" if _transparency_enabled else "OFF"
	]
	_info_label.text += "1 top · 2 oblique · P transparency · D depth mode · V mask · F5 noon · F6 night · Esc quit"


func select_camera_preset(preset: int) -> void:
	if preset == 1:
		_top_camera.make_current()
	else:
		_oblique_camera.make_current()


func set_test_transparency(enabled: bool) -> void:
	_set_transparency_enabled(enabled)


func set_test_depth_draw_mode(index: int) -> void:
	_set_depth_draw_mode(clampi(index, 0, DEPTH_DRAW_MODES.size() - 1))


func set_test_mask_visible(visible: bool) -> void:
	_mask_visible = visible
	_water_material.set_shader_parameter("water_diagnostic_mode", 13 if visible else 0)


func set_test_time_of_day(night: bool) -> void:
	_set_time_of_day(night)
