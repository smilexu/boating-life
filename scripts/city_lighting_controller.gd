extends Node3D
class_name CityLightingController

const WINDOW_OVERLAY_SHADER: Shader = preload("res://shaders/city_window_emission_overlay.gdshader")
const FAR_LIGHT_CARD_SHADER: Shader = preload("res://shaders/city_far_light_cards.gdshader")
const SETTINGS_PATH := "user://malmo_city_lighting.cfg"
const UPDATE_INTERVAL_SECONDS := 0.2

enum ForcedMode {
	AUTO,
	DAY,
	TWILIGHT,
	NIGHT,
}

@export var window_profiles: Array[CityWindowLightingProfile] = []
@export_range(250.0, 10000.0, 100.0) var lighting_visibility_distance_m := 4000.0
@export_range(100.0, 2000.0, 50.0) var near_window_full_distance_m := 650.0
@export_range(200.0, 3000.0, 50.0) var near_window_fade_end_m := 1300.0
@export_range(1500.0, 10000.0, 100.0) var far_proxy_fade_start_m := 5000.0
@export_range(2000.0, 12000.0, 100.0) var far_proxy_max_distance_m := 7000.0
@export_range(80.0, 165.0, 1.0) var turning_torso_beacon_height_m := 160.0
@export_range(0.0, 8.0, 0.1) var turning_torso_beacon_emission := 2.2
@export_range(2.0, 10.0, 0.25) var street_lamp_height_m := 5.25
@export_range(0.0, 3.0, 0.05) var street_lamp_emission_strength := 0.9
@export_range(0.0, 2.0, 0.05) var plaza_light_energy := 0.9
@export_range(5.0, 32.0, 1.0) var plaza_light_range_m := 17.0
@export_range(0.0, 1.0, 0.01) var turning_torso_contour_energy := 0.18
@export_range(0.5, 5.0, 0.1) var far_city_light_radius_m := 1.35
@export_range(0.0, 8.0, 0.1) var far_city_light_emission_strength := 3.2
@export var streetlight_positions_en: Array[Vector2] = [
	Vector2(-58.0, 100.0), Vector2(-12.0, 100.0), Vector2(36.0, 100.0), Vector2(84.0, 100.0),
	Vector2(-70.0, -100.0), Vector2(-24.0, -100.0), Vector2(24.0, -100.0), Vector2(72.0, -100.0),
]
@export var plaza_light_positions_en: Array[Vector2] = [
	Vector2(0.0, -25.0), Vector2(-30.0, 22.0), Vector2(30.0, 22.0),
]

var _city_root: Node3D
var _day_night_controller: Node
var _world_time_manager: Node
var _window_overlays: Array[Dictionary] = []
var _street_lights: Array[OmniLight3D] = []
var _contour_lights: Array[SpotLight3D] = []
var _pole_instances: MultiMeshInstance3D
var _lamp_head_instances: MultiMeshInstance3D
var _far_city_light_instances: MultiMeshInstance3D
var _street_head_material: StandardMaterial3D
var _far_city_light_material: StandardMaterial3D
var _turning_torso_beacon_material: StandardMaterial3D
var _turning_torso_beacon: MeshInstance3D
var _enabled := true
var _master_window_intensity := 1.0
var _density_override := -1.0
var _turning_torso_intensity := 1.0
var _residential_intensity := 1.0
var _office_intensity := 1.0
var _street_intensity := 1.0
var _contour_intensity := 0.2
var _forced_mode := ForcedMode.AUTO
var _debug_mask_view := false
var _elapsed := 0.0
var _last_night_factor := -1.0
var _last_late_night_factor := -1.0
var _last_distance_visible := false
var _last_near_window_factor := -1.0
var _last_far_proxy_factor := -1.0
var _last_camera_distance_m := -1.0


func _ready() -> void:
	add_to_group("city_lighting_controller")
	set_process(false)


func configure(city_root: Node3D, day_night_controller: Node) -> void:
	if _city_root != null:
		return
	_city_root = city_root
	_day_night_controller = day_night_controller
	_world_time_manager = get_node_or_null("/root/WorldTimeManager")
	_load_debug_settings()
	_build_window_overlays()
	_build_turning_torso_beacon()
	_build_street_lighting()
	_build_far_city_lights()
	_apply_lighting_state(true)
	set_process(true)


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < UPDATE_INTERVAL_SECONDS:
		return
	_elapsed = fmod(_elapsed, UPDATE_INTERVAL_SECONDS)
	_apply_lighting_state(false)


func _build_window_overlays() -> void:
	_window_overlays.clear()
	for profile in window_profiles:
		if profile == null or profile.window_rank_mask == null or profile.building_node_name.is_empty():
			continue
		var building := _city_root.get_node_or_null(NodePath(profile.building_node_name)) as Node3D
		if building == null:
			building = _city_root.find_child(profile.building_node_name, true, false) as Node3D
		if building == null:
			push_warning("City lighting could not find building '%s'." % profile.building_node_name)
			continue
		var mesh_instances: Array[MeshInstance3D] = []
		_collect_mesh_instances(building, mesh_instances)
		var attached_surface_count := 0
		for mesh_instance in mesh_instances:
			if mesh_instance.mesh == null:
				continue
			for surface_index in range(mesh_instance.mesh.get_surface_count()):
				var source_material := mesh_instance.get_active_material(surface_index) as BaseMaterial3D
				if source_material == null:
					continue
				var local_material := source_material.duplicate(true) as BaseMaterial3D
				if local_material == null:
					continue
				var overlay := ShaderMaterial.new()
				overlay.shader = WINDOW_OVERLAY_SHADER
				overlay.set_shader_parameter("window_rank_mask", profile.window_rank_mask)
				overlay.set_shader_parameter("warm_window_color", _color_to_vec3(profile.warm_window_color))
				overlay.set_shader_parameter("secondary_window_color", _color_to_vec3(profile.secondary_window_color))
				overlay.set_shader_parameter("secondary_color_ratio", profile.secondary_color_ratio)
				overlay.set_shader_parameter("pattern_offset", profile.pattern_offset)
				var previous_pass := local_material.next_pass
				overlay.next_pass = previous_pass
				var far_proxy: ShaderMaterial
				if profile.far_proxy_mask != null:
					far_proxy = ShaderMaterial.new()
					far_proxy.shader = FAR_LIGHT_CARD_SHADER
					far_proxy.set_shader_parameter("far_proxy_mask", profile.far_proxy_mask)
					far_proxy.set_shader_parameter("warm_window_color", _color_to_vec3(profile.warm_window_color))
					far_proxy.set_shader_parameter("secondary_window_color", _color_to_vec3(profile.secondary_window_color))
					far_proxy.set_shader_parameter("secondary_color_ratio", profile.secondary_color_ratio)
					far_proxy.set_shader_parameter("pattern_offset", profile.pattern_offset)
					far_proxy.next_pass = previous_pass
				local_material.next_pass = overlay
				mesh_instance.set_surface_override_material(surface_index, local_material)
				_window_overlays.append({
					"material": overlay,
					"profile": profile,
					"far_material": far_proxy,
					"previous_pass": previous_pass,
				})
				attached_surface_count += 1
		if attached_surface_count == 0:
			push_warning("City lighting found no BaseMaterial3D surfaces on '%s'." % profile.building_node_name)


func _build_turning_torso_beacon() -> void:
	var sphere := SphereMesh.new()
	sphere.radius = 0.95
	sphere.height = 1.9
	sphere.radial_segments = 8
	sphere.rings = 4
	_turning_torso_beacon_material = StandardMaterial3D.new()
	_turning_torso_beacon_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_turning_torso_beacon_material.albedo_color = Color("b42620")
	_turning_torso_beacon_material.emission_enabled = true
	_turning_torso_beacon_material.emission = Color("ff342b")
	_turning_torso_beacon_material.emission_energy_multiplier = 0.0
	_turning_torso_beacon = MeshInstance3D.new()
	_turning_torso_beacon.name = "TurningTorsoFarRedBeacon"
	_turning_torso_beacon.mesh = sphere
	_turning_torso_beacon.material_override = _turning_torso_beacon_material
	_turning_torso_beacon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_turning_torso_beacon.position = _position_en(Vector2.ZERO, turning_torso_beacon_height_m)
	add_child(_turning_torso_beacon)


func _collect_mesh_instances(node: Node, output: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		output.append(node as MeshInstance3D)
	for child in node.get_children():
		_collect_mesh_instances(child, output)


func _build_street_lighting() -> void:
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.07
	pole_mesh.bottom_radius = 0.12
	pole_mesh.height = street_lamp_height_m - 0.35
	var pole_material := StandardMaterial3D.new()
	pole_material.albedo_color = Color("454d4e")
	pole_material.roughness = 0.72
	_pole_instances = _make_multimesh_instances("StreetLampPoles", pole_mesh, pole_material, streetlight_positions_en.size())
	var pole_multi := _pole_instances.multimesh
	for index in range(streetlight_positions_en.size()):
		var position := _position_en(streetlight_positions_en[index], 0.82 + pole_mesh.height * 0.5)
		pole_multi.set_instance_transform(index, Transform3D(Basis.IDENTITY, position))

	var head_mesh := BoxMesh.new()
	head_mesh.size = Vector3(0.64, 0.18, 0.38)
	_street_head_material = StandardMaterial3D.new()
	_street_head_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_street_head_material.albedo_color = Color("372b20")
	_street_head_material.emission_enabled = true
	_street_head_material.emission = Color("f4c88f")
	_street_head_material.emission_energy_multiplier = 0.0
	_lamp_head_instances = _make_multimesh_instances("StreetLampHeads", head_mesh, _street_head_material, streetlight_positions_en.size())
	var head_multi := _lamp_head_instances.multimesh
	for index in range(streetlight_positions_en.size()):
		var position := _position_en(streetlight_positions_en[index], 0.82 + street_lamp_height_m - 0.08)
		position.x += 0.25
		head_multi.set_instance_transform(index, Transform3D(Basis.IDENTITY, position))

	for index in range(plaza_light_positions_en.size()):
		var light := OmniLight3D.new()
		light.name = "PlazaLight_%02d" % index
		light.light_color = Color("ffe1bd")
		light.light_energy = 0.0
		light.omni_range = plaza_light_range_m
		light.omni_attenuation = 1.35
		light.shadow_enabled = false
		light.position = _position_en(plaza_light_positions_en[index], 4.2)
		add_child(light)
		_street_lights.append(light)

	for index in range(2):
		var contour := SpotLight3D.new()
		contour.name = "TurningTorsoSoftUplight_%02d" % index
		contour.light_color = Color("fff0dc")
		contour.light_energy = 0.0
		contour.spot_range = 95.0
		contour.spot_angle = 35.0
		contour.spot_attenuation = 1.45
		contour.shadow_enabled = false
		contour.position = _position_en(Vector2(-5.0 if index == 0 else 5.0, 0.0), 1.0)
		contour.rotation.x = deg_to_rad(90.0)
		add_child(contour)
		_contour_lights.append(contour)


func _make_multimesh_instances(node_name: String, mesh: Mesh, material: Material, instance_count: int) -> MultiMeshInstance3D:
	var multi_mesh := MultiMesh.new()
	multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	multi_mesh.mesh = mesh
	multi_mesh.instance_count = instance_count
	var instance := MultiMeshInstance3D.new()
	instance.name = node_name
	instance.multimesh = multi_mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.visibility_range_end = lighting_visibility_distance_m
	instance.visibility_range_end_margin = 100.0
	add_child(instance)
	return instance


func _build_far_city_lights() -> void:
	var glow_mesh := SphereMesh.new()
	glow_mesh.radius = far_city_light_radius_m
	glow_mesh.height = far_city_light_radius_m * 2.0
	glow_mesh.radial_segments = 8
	glow_mesh.rings = 4
	_far_city_light_material = StandardMaterial3D.new()
	_far_city_light_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_far_city_light_material.albedo_color = Color("ffe4c3")
	_far_city_light_material.emission_enabled = true
	_far_city_light_material.emission = Color("ffd5a6")
	_far_city_light_material.emission_energy_multiplier = 0.0
	_far_city_light_instances = _make_multimesh_instances(
		"FarWarmCityLightPoints",
		glow_mesh,
		_far_city_light_material,
		streetlight_positions_en.size()
	)
	_far_city_light_instances.visibility_range_end = far_proxy_max_distance_m
	_far_city_light_instances.visibility_range_end_margin = 250.0
	var multi := _far_city_light_instances.multimesh
	for index in range(streetlight_positions_en.size()):
		var position := _position_en(streetlight_positions_en[index], 0.82 + street_lamp_height_m - 0.08)
		position.x += 0.25
		multi.set_instance_transform(index, Transform3D(Basis.IDENTITY, position))
	_far_city_light_instances.visible = false


func _position_en(position_east_north: Vector2, height: float) -> Vector3:
	if _city_root != null and _city_root.has_method("get_local_position_en"):
		return _city_root.call("get_local_position_en", position_east_north, height)
	return Vector3(position_east_north.x, height, -position_east_north.y)


func _apply_lighting_state(force: bool) -> void:
	if _city_root == null:
		return
	var camera_distance := _get_camera_distance_m()
	var detail_distance_visible := camera_distance <= lighting_visibility_distance_m
	var near_window_factor := 1.0 - smoothstep(near_window_full_distance_m, near_window_fade_end_m, camera_distance)
	var far_proxy_factor := smoothstep(near_window_full_distance_m, near_window_fade_end_m, camera_distance)
	far_proxy_factor *= 1.0 - smoothstep(far_proxy_fade_start_m, far_proxy_max_distance_m, camera_distance)
	var distance_visible := detail_distance_visible or far_proxy_factor > 0.0
	var solar_night_factor := _get_solar_night_factor()
	var mode_night_factor := solar_night_factor
	match _forced_mode:
		ForcedMode.DAY:
			mode_night_factor = 0.0
		ForcedMode.TWILIGHT:
			mode_night_factor = 0.58
		ForcedMode.NIGHT:
			mode_night_factor = 1.0
	var night_factor := mode_night_factor if _enabled and distance_visible else 0.0
	var late_night_factor := _get_late_night_factor()
	if _forced_mode == ForcedMode.TWILIGHT:
		late_night_factor = 0.0
	var state_changed := force \
		or absf(night_factor - _last_night_factor) >= 0.005 \
		or absf(late_night_factor - _last_late_night_factor) >= 0.005 \
		or absf(near_window_factor - _last_near_window_factor) >= 0.005 \
		or absf(far_proxy_factor - _last_far_proxy_factor) >= 0.005 \
		or distance_visible != _last_distance_visible \
		or absf(camera_distance - _last_camera_distance_m) >= 10.0
	if not state_changed:
		return
	_last_night_factor = night_factor
	_last_late_night_factor = late_night_factor
	_last_distance_visible = distance_visible
	_last_near_window_factor = near_window_factor
	_last_far_proxy_factor = far_proxy_factor
	_last_camera_distance_m = camera_distance
	for entry in _window_overlays:
		var material: ShaderMaterial = entry["material"]
		var profile: CityWindowLightingProfile = entry["profile"]
		var far_material: ShaderMaterial = entry["far_material"]
		var previous_pass: Material = entry["previous_pass"]
		var occupancy := lerpf(profile.evening_lit_ratio, profile.late_night_lit_ratio, late_night_factor)
		if _density_override >= 0.0:
			occupancy = _density_override
		material.set_shader_parameter("occupancy", occupancy)
		material.set_shader_parameter("night_factor", night_factor * near_window_factor)
		material.set_shader_parameter("emission_strength", profile.emission_strength * _master_window_intensity * _get_category_intensity(profile.kind))
		material.set_shader_parameter("debug_mask_view", _debug_mask_view)
		var use_far_proxy := far_material != null and _enabled and night_factor > 0.0 and far_proxy_factor > 0.0 and not _debug_mask_view
		material.next_pass = far_material if use_far_proxy else previous_pass
		if far_material != null:
			far_material.set_shader_parameter("occupancy", occupancy)
			far_material.set_shader_parameter("night_factor", night_factor)
			far_material.set_shader_parameter("distance_fade", far_proxy_factor)
			far_material.set_shader_parameter("emission_strength", profile.far_proxy_emission_strength * _master_window_intensity * _get_category_intensity(profile.kind))
	for light in _street_lights:
		light.light_energy = plaza_light_energy * _street_intensity * night_factor * float(detail_distance_visible)
	if _street_head_material != null:
		_street_head_material.emission_energy_multiplier = street_lamp_emission_strength * _street_intensity * night_factor * float(detail_distance_visible)
	if _far_city_light_material != null:
		_far_city_light_material.emission_energy_multiplier = far_city_light_emission_strength * _street_intensity * night_factor * far_proxy_factor
	if _far_city_light_instances != null:
		_far_city_light_instances.visible = _enabled and night_factor > 0.0 and far_proxy_factor > 0.0
	if _pole_instances != null:
		_pole_instances.visible = detail_distance_visible and _enabled
	if _lamp_head_instances != null:
		_lamp_head_instances.visible = detail_distance_visible and _enabled
	for light in _contour_lights:
		light.light_energy = turning_torso_contour_energy * _contour_intensity * night_factor * float(detail_distance_visible)
	if _turning_torso_beacon_material != null:
		_turning_torso_beacon_material.emission_energy_multiplier = turning_torso_beacon_emission * night_factor * far_proxy_factor
	if _turning_torso_beacon != null:
		_turning_torso_beacon.visible = _enabled and night_factor > 0.0 and far_proxy_factor > 0.0


func _get_solar_night_factor() -> float:
	if _day_night_controller == null or not is_instance_valid(_day_night_controller):
		return 0.0
	var elevation := float(_day_night_controller.call("get_sun_elevation_degrees"))
	return 1.0 - smoothstep(-6.0, 2.0, elevation)


func _get_late_night_factor() -> float:
	if _world_time_manager == null or not is_instance_valid(_world_time_manager):
		return 0.0
	var cycle: Dictionary = _world_time_manager.call("get_cycle_time_dictionary")
	var hour := float(cycle.get("hour", 0)) + float(cycle.get("minute", 0)) / 60.0
	if hour >= 22.0:
		return smoothstep(22.0, 23.5, hour)
	if hour < 5.0:
		return 1.0
	if hour < 7.0:
		return 1.0 - smoothstep(5.0, 7.0, hour)
	return 0.0


func _get_camera_distance_m() -> float:
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera == null or _city_root == null:
		return 0.0
	return camera.global_position.distance_to(_city_root.global_position)


func _get_category_intensity(kind: int) -> float:
	match kind:
		CityWindowLightingProfile.BuildingKind.LANDMARK:
			return _turning_torso_intensity
		CityWindowLightingProfile.BuildingKind.OFFICE:
			return _office_intensity
		_:
			return _residential_intensity


func set_lighting_enabled(value: bool) -> void:
	_enabled = value
	_apply_lighting_state(true)


func set_master_window_intensity(value: float) -> void:
	_master_window_intensity = clampf(value, 0.0, 3.0)
	_apply_lighting_state(true)


func set_density_override(enabled: bool, value: float) -> void:
	_density_override = clampf(value, 0.0, 0.8) if enabled else -1.0
	_apply_lighting_state(true)


func set_category_intensity(category: String, value: float) -> void:
	match category:
		"turning_torso":
			_turning_torso_intensity = clampf(value, 0.0, 3.0)
		"residential":
			_residential_intensity = clampf(value, 0.0, 3.0)
		"office":
			_office_intensity = clampf(value, 0.0, 3.0)
	_apply_lighting_state(true)


func set_street_lighting_intensity(value: float) -> void:
	_street_intensity = clampf(value, 0.0, 3.0)
	_apply_lighting_state(true)


func set_contour_intensity(value: float) -> void:
	_contour_intensity = clampf(value, 0.0, 2.0)
	_apply_lighting_state(true)


func set_forced_mode(value: int) -> void:
	_forced_mode = clampi(value, ForcedMode.AUTO, ForcedMode.NIGHT)
	_apply_lighting_state(true)


func set_debug_mask_view(value: bool) -> void:
	_debug_mask_view = value
	_apply_lighting_state(true)


func get_debug_state() -> Dictionary:
	var mode_names := ["自动昼夜", "强制白天", "强制黄昏", "强制夜晚"]
	var cycle: Dictionary = _world_time_manager.call("get_cycle_time_dictionary") if _world_time_manager != null else {}
	var hour := int(cycle.get("hour", 0))
	var minute := int(cycle.get("minute", 0))
	var night_state := "关闭"
	if _enabled and _last_night_factor > 0.0:
		night_state = "开启 · %.0f%%" % (_last_night_factor * 100.0)
	return {
		"enabled": _enabled,
		"master_window_intensity": _master_window_intensity,
		"density_override": _density_override,
		"turning_torso_intensity": _turning_torso_intensity,
		"residential_intensity": _residential_intensity,
		"office_intensity": _office_intensity,
		"street_intensity": _street_intensity,
		"contour_intensity": _contour_intensity,
		"forced_mode": _forced_mode,
		"mode_name": mode_names[_forced_mode],
		"night_factor": _last_night_factor,
		"camera_distance_m": _last_camera_distance_m,
		"near_window_factor": _last_near_window_factor,
		"far_proxy_factor": _last_far_proxy_factor,
		"night_state": night_state,
		"local_time": "%02d:%02d" % [hour, minute],
		"overlay_surfaces": _window_overlays.size(),
		"visible": _last_distance_visible,
		"debug_mask_view": _debug_mask_view,
		"density_text": "自动" if _density_override < 0.0 else "%.0f%%" % (_density_override * 100.0),
	}


func save_debug_settings() -> bool:
	var config := ConfigFile.new()
	config.set_value("lighting", "enabled", _enabled)
	config.set_value("lighting", "master_window_intensity", _master_window_intensity)
	config.set_value("lighting", "density_override", _density_override)
	config.set_value("lighting", "turning_torso_intensity", _turning_torso_intensity)
	config.set_value("lighting", "residential_intensity", _residential_intensity)
	config.set_value("lighting", "office_intensity", _office_intensity)
	config.set_value("lighting", "street_intensity", _street_intensity)
	config.set_value("lighting", "contour_intensity", _contour_intensity)
	return config.save(SETTINGS_PATH) == OK


func reset_debug_defaults() -> void:
	_enabled = true
	_master_window_intensity = 1.0
	_density_override = -1.0
	_turning_torso_intensity = 1.0
	_residential_intensity = 1.0
	_office_intensity = 1.0
	_street_intensity = 1.0
	_contour_intensity = 0.2
	_forced_mode = ForcedMode.AUTO
	_apply_lighting_state(true)


func _load_debug_settings() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK:
		return
	_enabled = bool(config.get_value("lighting", "enabled", _enabled))
	_master_window_intensity = clampf(float(config.get_value("lighting", "master_window_intensity", _master_window_intensity)), 0.0, 3.0)
	_density_override = clampf(float(config.get_value("lighting", "density_override", _density_override)), -1.0, 0.8)
	_turning_torso_intensity = clampf(float(config.get_value("lighting", "turning_torso_intensity", _turning_torso_intensity)), 0.0, 3.0)
	_residential_intensity = clampf(float(config.get_value("lighting", "residential_intensity", _residential_intensity)), 0.0, 3.0)
	_office_intensity = clampf(float(config.get_value("lighting", "office_intensity", _office_intensity)), 0.0, 3.0)
	_street_intensity = clampf(float(config.get_value("lighting", "street_intensity", _street_intensity)), 0.0, 3.0)
	_contour_intensity = clampf(float(config.get_value("lighting", "contour_intensity", _contour_intensity)), 0.0, 2.0)


func _color_to_vec3(color: Color) -> Vector3:
	return Vector3(color.r, color.g, color.b)
