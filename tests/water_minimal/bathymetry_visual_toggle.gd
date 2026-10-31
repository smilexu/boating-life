extends Node

## F6 toggles only the water material's visible bathymetry effects.
## The loaded texture and wave parameters remain unchanged for comparison.

var _bathymetry_manager: Node
var _water_material: ShaderMaterial
var _initial_depth_color_enabled := true
var _initial_shallow_transparency_enabled := false
var _bathymetry_visuals_enabled := true


func _ready() -> void:
	_bathymetry_manager = get_parent().get_node_or_null("BathymetryManager")
	if _bathymetry_manager == null:
		push_error("BathymetryVisualToggle needs BathymetryManager.")
		return
	_water_material = _bathymetry_manager.get("water_material") as ShaderMaterial
	if _water_material == null:
		push_error("BathymetryVisualToggle needs the water ShaderMaterial.")
		return
	call_deferred("_capture_initial_state")


func _capture_initial_state() -> void:
	_initial_depth_color_enabled = bool(_water_material.get_shader_parameter("enable_depth_color"))
	_initial_shallow_transparency_enabled = bool(_water_material.get_shader_parameter("shallow_transparency_enabled"))
	_bathymetry_visuals_enabled = _initial_depth_color_enabled or _initial_shallow_transparency_enabled
	_apply_bathymetry_visual_state()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.physical_keycode:
		KEY_F5:
			_set_diagnostic_mode(0)
		KEY_F6:
			_bathymetry_visuals_enabled = not _bathymetry_visuals_enabled
			_apply_bathymetry_visual_state()
		KEY_F7:
			_set_diagnostic_mode(6)
		KEY_F8:
			_set_diagnostic_mode(2)
		KEY_F11:
			_set_diagnostic_mode(3)
		KEY_F12:
			_set_diagnostic_mode(13)
		_:
			return
	get_viewport().set_input_as_handled()


func _set_diagnostic_mode(mode: int) -> void:
	if _bathymetry_manager == null or _water_material == null:
		return
	_bathymetry_manager.set("water_diagnostic_mode", mode)
	_water_material.set_shader_parameter("water_diagnostic_mode", mode)
	print("Water diagnostic mode: %d" % mode)


func _apply_bathymetry_visual_state() -> void:
	if _bathymetry_manager == null or _water_material == null:
		return
	_bathymetry_manager.call(
		"set_depth_color_enabled",
		_bathymetry_visuals_enabled and _initial_depth_color_enabled
	)
	_water_material.set_shader_parameter(
		"shallow_transparency_enabled",
		_bathymetry_visuals_enabled and _initial_shallow_transparency_enabled
	)
	print("Bathymetry water visuals: %s (F6 toggles)" % ("ON" if _bathymetry_visuals_enabled else "OFF"))
