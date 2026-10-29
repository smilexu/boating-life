extends Node3D
## Entry point for the standalone calm-water sailboat prototype.

enum CameraMode { FOLLOW, FIXED, UNDERWATER }
enum WaterDisplayMode { NORMAL, TRANSLUCENT, HIDDEN }

const CAMERA_FOLLOW_RESPONSE := 7.0
const CAMERA_FOCUS_OFFSET := Vector3(0.0, 1.8, 0.0)
const INSPECTION_FOLLOW_RESPONSE := 6.0
const INSPECTION_RADIUS_MIN_M := 3.0
const INSPECTION_RADIUS_MAX_M := 12.0
const INSPECTION_PAN_SENSITIVITY := 0.0015
const INSPECTION_PAN_LIMIT_M := 8.0

@onready var _boat: Node3D = $SailboatBody
@onready var _camera: Camera3D = $Camera3D
@onready var _dynamic_water: MeshInstance3D = $WaterSurface
@onready var _static_water: MeshInstance3D = $WaterSurfaceStatic
@onready var _wave_sampler: WaveSampler = $WaveSampler
@onready var _bathymetry_manager: BathymetryManager = $BathymetryManager

var _camera_mode := CameraMode.FOLLOW
var _camera_follow_offset_world := Vector3.ZERO
var _fixed_camera_global_transform := Transform3D.IDENTITY
var _inspection_yaw_rad := 0.0
var _inspection_pitch_rad := -0.25
var _inspection_radius_m := 6.5
var _inspection_orbit_dragging := false
var _inspection_pan_dragging := false
var _inspection_pan_local := Vector3.ZERO

var _water_display_mode := WaterDisplayMode.NORMAL
var _dynamic_water_selected := true
var _lab_water_material: ShaderMaterial
var _lab_static_material: BaseMaterial3D
var _normal_static_albedo := Color.WHITE
var _normal_static_transparency := BaseMaterial3D.TRANSPARENCY_DISABLED


func _ready() -> void:
	_camera_follow_offset_world = _camera.global_position - _boat.global_position
	_camera.look_at(_boat.global_position + CAMERA_FOCUS_OFFSET, Vector3.UP)
	_fixed_camera_global_transform = _camera.global_transform
	_isolate_lab_water_materials()
	var snapshot: Dictionary = _boat.call("get_debug_snapshot")
	_dynamic_water_selected = bool(snapshot.get("dynamic_waves_enabled", true))
	_apply_water_display_mode()
	var polar_runner := get_node_or_null("PolarTestRunner") as PolarTestRunner
	if polar_runner != null:
		polar_runner.boat_scene_change_requested.connect(_on_polar_boat_scene_change_requested)
		polar_runner.set_boat_instance(_boat)


func _process(delta: float) -> void:
	if _boat == null or _camera == null:
		return
	match _camera_mode:
		CameraMode.FOLLOW:
			_update_follow_camera(delta)
		CameraMode.FIXED:
			pass
		CameraMode.UNDERWATER:
			_update_underwater_camera(delta)


func _update_follow_camera(delta: float) -> void:
	# Follow the interpolated render transform so camera motion does not inherit
	# fixed-step jitter from the RigidBody3D. This is presentation-only.
	var boat_transform := _boat.get_global_transform_interpolated()
	var target_position := boat_transform.origin + _camera_follow_offset_world
	var blend := 1.0 - exp(-CAMERA_FOLLOW_RESPONSE * maxf(delta, 0.0))
	_camera.global_position = _camera.global_position.lerp(target_position, blend)
	_camera.look_at(boat_transform.origin + CAMERA_FOCUS_OFFSET, Vector3.UP)


func _update_underwater_camera(delta: float) -> void:
	var boat_transform := _boat.get_global_transform_interpolated()
	var snapshot: Dictionary = _boat.call("get_debug_snapshot")
	var focus_local: Vector3 = snapshot.get("rudder_center_local_m", Vector3(0.0, -0.88, 3.18)) + _inspection_pan_local
	# Keep the view slightly aft and below the real hydrodynamic rudder point.
	var pitch_cos := cos(_inspection_pitch_rad)
	var local_offset := Vector3(
		sin(_inspection_yaw_rad) * pitch_cos,
		sin(_inspection_pitch_rad),
		cos(_inspection_yaw_rad) * pitch_cos
	) * _inspection_radius_m
	var focus_world := boat_transform * focus_local
	var desired_position := boat_transform * (focus_local + local_offset)
	var blend := 1.0 - exp(-INSPECTION_FOLLOW_RESPONSE * maxf(delta, 0.0))
	_camera.global_position = _camera.global_position.lerp(desired_position, blend)
	_look_at_inspection_target(focus_world)


func _handle_inspection_mouse_input(event: InputEvent) -> bool:
	if _camera_mode != CameraMode.UNDERWATER:
		return false
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_RIGHT:
			_inspection_orbit_dragging = button.pressed
			get_viewport().set_input_as_handled()
			return true
		elif button.button_index == MOUSE_BUTTON_MIDDLE:
			_inspection_pan_dragging = button.pressed
			get_viewport().set_input_as_handled()
			return true
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_UP:
			if _pointer_is_over_debug_panel(button.position):
				return false
			_inspection_radius_m = maxf(INSPECTION_RADIUS_MIN_M, _inspection_radius_m - 0.5)
			get_viewport().set_input_as_handled()
			return true
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if _pointer_is_over_debug_panel(button.position):
				return false
			_inspection_radius_m = minf(INSPECTION_RADIUS_MAX_M, _inspection_radius_m + 0.5)
			get_viewport().set_input_as_handled()
			return true
	elif event is InputEventMouseMotion and _inspection_orbit_dragging:
		var orbit_motion := event as InputEventMouseMotion
		_inspection_yaw_rad = wrapf(_inspection_yaw_rad - orbit_motion.relative.x * 0.008, -PI, PI)
		_inspection_pitch_rad = clampf(_inspection_pitch_rad + orbit_motion.relative.y * 0.006, -0.65, 0.45)
		get_viewport().set_input_as_handled()
		return true
	elif event is InputEventMouseMotion and _inspection_pan_dragging:
		var pan_motion := event as InputEventMouseMotion
		var pixels_to_metres := _inspection_radius_m * INSPECTION_PAN_SENSITIVITY
		var screen_plane_shift_world := (
			-_camera.global_basis.x * pan_motion.relative.x
			-_camera.global_basis.y * pan_motion.relative.y
		) * pixels_to_metres
		var boat_basis := _boat.get_global_transform_interpolated().basis
		_inspection_pan_local += boat_basis.inverse() * screen_plane_shift_world
		_inspection_pan_local = _inspection_pan_local.limit_length(INSPECTION_PAN_LIMIT_M)
		get_viewport().set_input_as_handled()
		return true
	return false


func _pointer_is_over_debug_panel(position: Vector2) -> bool:
	var debug_layer := get_node_or_null("DebugPanel")
	var panel: Control = null
	if debug_layer != null:
		panel = debug_layer.find_child("SailboatLabDebugPanelContent", true, false) as Control
	return panel != null and panel.get_global_rect().has_point(position)


func _input(event: InputEvent) -> void:
	if _handle_inspection_mouse_input(event):
		return
	if not event is InputEventKey:
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo or key_event.alt_pressed or key_event.ctrl_pressed or key_event.meta_pressed:
		return
	if key_event.physical_keycode == KEY_C and not key_event.shift_pressed:
		cycle_camera_mode()
		_mark_shortcut_handled()
	elif key_event.physical_keycode == KEY_BACKSPACE and not key_event.shift_pressed:
		# Reloading the standalone lab restores the boat, local wind and wave test
		# controls, camera mode, water presentation, and UI together.
		get_tree().reload_current_scene()
		_mark_shortcut_handled()


func _mark_shortcut_handled() -> void:
	var viewport := get_viewport()
	if viewport != null:
		viewport.set_input_as_handled()


func cycle_camera_mode() -> void:
	set_camera_mode((_camera_mode + 1) % CameraMode.size())


func set_camera_mode(mode: int) -> void:
	_camera_mode = clampi(mode, CameraMode.FOLLOW, CameraMode.UNDERWATER)
	_inspection_orbit_dragging = false
	_inspection_pan_dragging = false
	if _camera_mode == CameraMode.FIXED and _camera != null:
		_camera.global_transform = _fixed_camera_global_transform
	elif _camera_mode == CameraMode.UNDERWATER and _camera != null:
		# Reset to a predictable view behind and below the stern whenever selected.
		_inspection_yaw_rad = 0.0
		_inspection_pitch_rad = -0.25
		_inspection_pan_local = Vector3.ZERO
		_camera.global_transform = _underwater_camera_transform()


func _underwater_camera_transform() -> Transform3D:
	var snapshot: Dictionary = _boat.call("get_debug_snapshot")
	var focus_local: Vector3 = snapshot.get("rudder_center_local_m", Vector3(0.0, -0.88, 3.18)) + _inspection_pan_local
	var pitch_cos := cos(_inspection_pitch_rad)
	var local_offset := Vector3(
		sin(_inspection_yaw_rad) * pitch_cos,
		sin(_inspection_pitch_rad),
		cos(_inspection_yaw_rad) * pitch_cos
	) * _inspection_radius_m
	var boat_transform := _boat.get_global_transform_interpolated()
	var camera_transform := Transform3D(Basis.IDENTITY, boat_transform * (focus_local + local_offset))
	_camera.global_transform = camera_transform
	_look_at_inspection_target(boat_transform * focus_local)
	return _camera.global_transform


func _look_at_inspection_target(target_world: Vector3) -> void:
	var direction := (target_world - _camera.global_position).normalized()
	var up_direction := Vector3.UP
	if absf(direction.dot(up_direction)) > 0.98:
		up_direction = Vector3.FORWARD
	_camera.look_at(target_world, up_direction)


func get_camera_mode() -> int:
	return _camera_mode


func get_camera_mode_label() -> String:
	match _camera_mode:
		CameraMode.FOLLOW:
			return "平滑跟随"
		CameraMode.FIXED:
			return "固定实验室视角"
		CameraMode.UNDERWATER:
			return "水下结构检查"
	return "未知"


## Compatibility query retained for existing lab checks and controls.
func is_camera_follow_enabled() -> bool:
	return _camera_mode == CameraMode.FOLLOW


func set_camera_follow_enabled(enabled: bool) -> void:
	set_camera_mode(CameraMode.FOLLOW if enabled else CameraMode.FIXED)


func _on_polar_boat_scene_change_requested(scene_path: String) -> void:
	if not _replace_lab_boat(scene_path):
		return
	var polar_runner := get_node_or_null("PolarTestRunner") as PolarTestRunner
	if polar_runner != null:
		polar_runner.set_boat_instance(_boat)
	var debug_panel := get_node_or_null("DebugPanel")
	if debug_panel != null and debug_panel.has_method("set_boat_reference"):
		debug_panel.call("set_boat_reference", _boat)
	if _wave_sampler != null:
		_wave_sampler.set_phase_anchor_node(_boat)


func _replace_lab_boat(scene_path: String) -> bool:
	var packed := load(scene_path) as PackedScene
	if packed == null:
		push_warning("Polar scene selection is not a PackedScene: %s" % scene_path)
		return false
	var replacement := packed.instantiate() as Node3D
	if replacement == null:
		push_warning("Polar scene must have a Node3D root: %s" % scene_path)
		return false
	for method_name in ["get_navigation_snapshot", "get_s1_c4_diagnostic_snapshot", "get_debug_snapshot", "set_lab_test_wind"]:
		if not replacement.has_method(method_name):
			push_warning("Polar scene is missing the sailboat test API '%s': %s" % [method_name, scene_path])
			replacement.free()
			return false
	var previous := _boat
	var previous_transform := previous.global_transform
	previous.name = "RetiredSailboatBody"
	if previous is RigidBody3D:
		(previous as RigidBody3D).collision_layer = 0
		(previous as RigidBody3D).collision_mask = 0
		(previous as RigidBody3D).freeze = true
		(previous as RigidBody3D).set_process(false)
		(previous as RigidBody3D).set_physics_process(false)
	replacement.name = "SailboatBody"
	if _has_property(replacement, "wave_sampler_path"):
		replacement.set("wave_sampler_path", ^"../WaveSampler")
	if _has_property(replacement, "wind_field_path"):
		replacement.set("wind_field_path", ^"../WindField")
	if _has_property(replacement, "auto_reset_on_ready"):
		replacement.set("auto_reset_on_ready", true)
	if _has_property(replacement, "keyboard_controls_enabled"):
		replacement.set("keyboard_controls_enabled", true)
	add_child(replacement)
	move_child(replacement, 0)
	replacement.global_transform = previous_transform
	_boat = replacement
	previous.queue_free()
	return true


func _has_property(object: Object, property_name: String) -> bool:
	for property in object.get_property_list():
		if str(property.get("name", "")) == property_name:
			return true
	return false


func set_dynamic_waves_enabled(enabled: bool) -> void:
	_dynamic_water_selected = enabled
	_boat.call("set_dynamic_waves_enabled", enabled)
	_apply_water_visibility()


func set_water_display_mode(mode: int) -> void:
	_water_display_mode = clampi(mode, WaterDisplayMode.NORMAL, WaterDisplayMode.HIDDEN)
	_apply_water_display_mode()


func get_water_display_mode() -> int:
	return _water_display_mode


func get_water_display_mode_label() -> String:
	match _water_display_mode:
		WaterDisplayMode.NORMAL:
			return "正常海面"
		WaterDisplayMode.TRANSLUCENT:
			return "半透明海面"
		WaterDisplayMode.HIDDEN:
			return "隐藏海面"
	return "未知"


func _isolate_lab_water_materials() -> void:
	var shared_shader_material := _dynamic_water.material_override as ShaderMaterial
	if shared_shader_material != null:
		# Duplicate only the material instance. Keep the shader and textures shared,
		# while shader parameters remain private to this lab scene.
		_lab_water_material = shared_shader_material.duplicate(false) as ShaderMaterial
		if _lab_water_material != null:
			_dynamic_water.material_override = _lab_water_material
			_wave_sampler.water_material = _lab_water_material
			_bathymetry_manager.water_material = _lab_water_material
	var shared_static_material := _static_water.material_override as BaseMaterial3D
	if shared_static_material != null:
		_lab_static_material = shared_static_material.duplicate(false) as BaseMaterial3D
		if _lab_static_material != null:
			_normal_static_albedo = _lab_static_material.albedo_color
			_normal_static_transparency = _lab_static_material.transparency
			_static_water.material_override = _lab_static_material


func _apply_water_display_mode() -> void:
	if _lab_water_material != null:
		var opacity := 0.25 if _water_display_mode == WaterDisplayMode.TRANSLUCENT else 1.0
		_lab_water_material.set_shader_parameter("debug_visual_alpha_scale", opacity)
	if _lab_static_material != null:
		if _water_display_mode == WaterDisplayMode.TRANSLUCENT:
			_lab_static_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			var static_alpha := _normal_static_albedo.a * 0.25
			_lab_static_material.albedo_color = Color(_normal_static_albedo, static_alpha)
		else:
			_lab_static_material.transparency = _normal_static_transparency
			_lab_static_material.albedo_color = _normal_static_albedo
	_apply_water_visibility()


func _apply_water_visibility() -> void:
	var show_water := _water_display_mode != WaterDisplayMode.HIDDEN
	_dynamic_water.visible = show_water and _dynamic_water_selected
	_static_water.visible = show_water and not _dynamic_water_selected
