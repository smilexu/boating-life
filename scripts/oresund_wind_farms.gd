extends Node3D
class_name OresundWindFarms

## Two location-anchored offshore wind farms rendered with shared MultiMeshes.

const WindTurbineModel := preload("res://scripts/offshore_wind_turbine_model.gd")
const ROTOR_PHASE_STEP := 2.399963229728653
const SEA_LEVEL_Y := 0.0
const DEBUG_FARM_ORDER := ["lillgrund", "middelgrunden"]
const MAX_DYNAMIC_LIGHTED_TURBINES := 4

@export var georeference: GeoReference
@export_file("*.json") var layout_data_path := "res://resources/oresund_wind_farms.json"
@export_node_path("Node3D") var player_boat_path := NodePath("../PlayerBoat/MotionRoot")
@export_node_path("Node") var day_night_controller_path := NodePath("../DayNightVisualController")
@export var developer_tools_enabled := true
@export_range(100.0, 10000.0, 100.0) var debug_observation_offset_m := 500.0
@export_range(50.0, 110.0, 1.0) var hub_height_m := 65.0
@export_range(30.0, 60.0, 0.5) var rotor_radius_m := 46.5
@export_range(5.0, 20.0, 0.5) var foundation_depth_m := 12.0
@export_range(0.0, 1.0, 0.01) var rotor_speed_radians_per_second := 0.14
@export_range(1000.0, 12000.0, 250.0) var near_lod_radius_m := 4000.0
@export_range(10000.0, 90000.0, 1000.0) var far_visible_radius_m := 60000.0
@export_range(0.1, 2.0, 0.1) var visibility_update_interval_seconds := 0.6
@export_range(0.02, 0.2, 0.01) var rotor_update_interval_seconds := 0.06
@export var red_night_beacons_enabled := true
@export_range(0.0, 2.0, 0.05) var beacon_emission_energy := 1.1
@export_range(0.0, 4.0, 0.05) var beacon_fill_light_energy := 1.2
@export_range(1.0, 200.0, 1.0) var beacon_fill_light_range_m := 80.0
@export var platform_night_lights_enabled := true
@export_range(0.0, 1.5, 0.05) var platform_light_emission_energy := 0.6
@export_range(0.0, 4.0, 0.05) var platform_fill_light_energy := 0.7
@export_range(1.0, 150.0, 1.0) var platform_fill_light_range_m := 45.0
@export_range(0.0, 359.0, 1.0) var default_rotor_bearing_degrees := 225.0

var _boat: Node3D
var _day_night_controller: Node
var _records: Array[Dictionary] = []
var _near_indices := PackedInt32Array()
var _far_indices := PackedInt32Array()
var _active_indices := PackedInt32Array()
var _near_base_renderer: MultiMeshInstance3D
var _near_rotor_renderer: MultiMeshInstance3D
var _far_base_renderer: MultiMeshInstance3D
var _far_rotor_renderer: MultiMeshInstance3D
var _beacon_renderer: MultiMeshInstance3D
var _platform_light_renderer: MultiMeshInstance3D
var _beacon_material: StandardMaterial3D
var _platform_light_material: StandardMaterial3D
var _dynamic_lamp_pairs: Array[Dictionary] = []
var _visibility_elapsed := 0.0
var _rotor_elapsed := 0.0
var _night_elapsed := 0.0
var _rotor_angle := 0.0
var _night_factor := 0.0
var _farm_counts: Dictionary = {}
var _debug_teleport_index := -1
var _last_debug_teleport_farm := ""


func _ready() -> void:
	if georeference == null:
		push_error("OresundWindFarms: GeoReference is required.")
		set_process(false)
		return
	_boat = get_node_or_null(player_boat_path) as Node3D
	_day_night_controller = get_node_or_null(day_night_controller_path)
	if not _load_layout():
		set_process(false)
		return
	_build_shared_renderers()
	_create_dynamic_light_pool()
	_update_night_lighting(true)
	_update_lod()
	_update_rotor_transforms()
	print("OresundWindFarms: %d turbines loaded (Lillgrund %d, Middelgrunden %d)." % [
		_records.size(),
		int(_farm_counts.get("lillgrund", 0)),
		int(_farm_counts.get("middelgrunden", 0)),
	])


func _process(delta: float) -> void:
	_rotor_angle = fmod(_rotor_angle + delta * rotor_speed_radians_per_second, TAU)
	_rotor_elapsed += delta
	_visibility_elapsed += delta
	_night_elapsed += delta
	if _rotor_elapsed >= rotor_update_interval_seconds:
		_rotor_elapsed = fmod(_rotor_elapsed, rotor_update_interval_seconds)
		_update_rotor_transforms()
	if _visibility_elapsed >= visibility_update_interval_seconds:
		_visibility_elapsed = fmod(_visibility_elapsed, visibility_update_interval_seconds)
		if not is_instance_valid(_boat):
			_boat = get_node_or_null(player_boat_path) as Node3D
		_update_lod()
	if _night_elapsed >= 0.25:
		_night_elapsed = fmod(_night_elapsed, 0.25)
		_update_night_lighting()


func _unhandled_key_input(event: InputEvent) -> void:
	if not developer_tools_enabled or not _developer_tools_available():
		return
	if event is not InputEventKey or not event.pressed or event.echo:
		return
	if event.physical_keycode != KEY_F6 or event.shift_pressed or event.ctrl_pressed or event.alt_pressed or event.meta_pressed:
		return
	debug_teleport_to_next_farm()
	get_viewport().set_input_as_handled()


func debug_teleport_to_next_farm() -> void:
	if not is_instance_valid(_boat) or _records.is_empty():
		_boat = get_node_or_null(player_boat_path) as Node3D
	if not is_instance_valid(_boat):
		push_warning("OresundWindFarms: cannot teleport; player boat is unavailable.")
		return
	_debug_teleport_index = posmod(_debug_teleport_index + 1, DEBUG_FARM_ORDER.size())
	var farm_id: String = DEBUG_FARM_ORDER[_debug_teleport_index]
	var farm_center_local := _get_farm_center_local(farm_id)
	if not is_finite(farm_center_local.y):
		push_warning("OresundWindFarms: no turbine positions found for %s." % farm_id)
		return
	var center_world := to_global(farm_center_local)
	var east_direction := global_transform.basis.x
	east_direction.y = 0.0
	east_direction = east_direction.normalized() if east_direction.length_squared() > 0.001 else Vector3.RIGHT
	var destination := center_world + east_direction * debug_observation_offset_m
	destination.y = SEA_LEVEL_Y
	var desired_forward := center_world - destination
	desired_forward.y = 0.0
	desired_forward = desired_forward.normalized()
	if _boat.has_method("disengage_autopilot"):
		_boat.call("disengage_autopilot")
	if _boat.has_method("set_port_docked"):
		_boat.call("set_port_docked", false)
	_boat.global_position = destination
	_boat.global_rotation.y = atan2(-desired_forward.x, -desired_forward.z)
	if _boat.get("speed_mps") != null:
		_boat.set("speed_mps", 0.0)
	if _boat.get("is_motion_paused") != null:
		_boat.set("is_motion_paused", false)
	_last_debug_teleport_farm = farm_id
	_update_lod()
	print("Wind farm debug teleport: %s · %.0f m offshore" % [farm_id.capitalize(), debug_observation_offset_m])


func _developer_tools_available() -> bool:
	return Engine.is_editor_hint() or OS.has_feature("debug")


func _get_farm_center_local(farm_id: String) -> Vector3:
	var total := Vector3.ZERO
	var count := 0
	for record in _records:
		if str(record.get("farm_id", "")) != farm_id:
			continue
		var position: Vector3 = record["position"]
		total += position
		count += 1
	return total / float(count) if count > 0 else Vector3(0.0, INF, 0.0)


func get_debug_snapshot() -> Dictionary:
	return {
		"total_turbines": _records.size(),
		"lillgrund_turbines": int(_farm_counts.get("lillgrund", 0)),
		"middelgrunden_turbines": int(_farm_counts.get("middelgrunden", 0)),
		"near_lod_turbines": _near_indices.size(),
		"far_lod_turbines": _far_indices.size(),
		"visible_turbines": _active_indices.size(),
		"near_lod_radius_m": near_lod_radius_m,
		"far_visible_radius_m": far_visible_radius_m,
		"rotor_speed_radians_per_second": rotor_speed_radians_per_second,
		"night_factor": _night_factor,
		"last_debug_teleport_farm": _last_debug_teleport_farm,
		"next_debug_teleport_farm": DEBUG_FARM_ORDER[posmod(_debug_teleport_index + 1, DEBUG_FARM_ORDER.size())],
		"debug_observation_offset_m": debug_observation_offset_m,
		"dynamic_lighted_turbine_limit": MAX_DYNAMIC_LIGHTED_TURBINES,
		"dynamic_lighted_turbine_count": _dynamic_lamp_pairs.size(),
		"dynamic_light_node_count": _dynamic_lamp_pairs.size() * 3,
		"beacon_emission_energy": beacon_emission_energy,
		"beacon_fill_light_energy": beacon_fill_light_energy,
		"beacon_fill_light_range_m": beacon_fill_light_range_m,
		"platform_night_lights_enabled": platform_night_lights_enabled,
		"platform_light_emission_energy": platform_light_emission_energy,
		"platform_fill_light_energy": platform_fill_light_energy,
		"platform_fill_light_range_m": platform_fill_light_range_m,
		"render_batches": 6,
	}


func _load_layout() -> bool:
	if not FileAccess.file_exists(layout_data_path):
		push_error("OresundWindFarms: layout data not found: %s" % layout_data_path)
		return false
	var file := FileAccess.open(layout_data_path, FileAccess.READ)
	if file == null:
		push_error("OresundWindFarms: could not read layout data: %s" % layout_data_path)
		return false
	var data: Variant = JSON.parse_string(file.get_as_text())
	if not data is Dictionary or not data.get("farms", []) is Array:
		push_error("OresundWindFarms: invalid layout schema.")
		return false
	for farm_value in data["farms"]:
		if not farm_value is Dictionary:
			continue
		var farm: Dictionary = farm_value
		var farm_id := str(farm.get("id", ""))
		var positions: Variant = farm.get("turbine_positions_wgs84", [])
		var expected_count := int(farm.get("turbine_count", -1))
		if farm_id.is_empty() or not positions is Array or positions.size() != expected_count:
			push_error("OresundWindFarms: invalid turbine list for %s." % farm_id)
			return false
		_farm_counts[farm_id] = positions.size()
		var heading_degrees := float(farm.get("rotor_bearing_degrees", default_rotor_bearing_degrees))
		var yaw := deg_to_rad(180.0 - heading_degrees)
		for local_index in range(positions.size()):
			var point_value: Variant = positions[local_index]
			if not point_value is Dictionary:
				push_error("OresundWindFarms: invalid WGS84 position in %s." % farm_id)
				return false
			var point: Dictionary = point_value
			var latitude := float(point.get("latitude_deg", INF))
			var longitude := float(point.get("longitude_deg", INF))
			if not is_finite(latitude) or not is_finite(longitude):
				push_error("OresundWindFarms: invalid latitude/longitude in %s." % farm_id)
				return false
			var local_position := to_local(georeference.geodetic_to_world(latitude, longitude, 0.0))
			# The game ocean is a flat Y=0 plane; preserve GeoReference east/north,
			# but seat each visual turbine on that shared sea datum.
			local_position.y = SEA_LEVEL_Y
			var phase_seed := _records.size() + 1
			_records.append({
				"farm_id": farm_id,
				"turbine_id": str(point.get("node_id", "%s_%02d" % [farm_id, local_index + 1])),
				"position": local_position,
				"yaw": yaw,
				"phase": fmod(float(phase_seed) * ROTOR_PHASE_STEP, TAU),
			})
	return int(_farm_counts.get("lillgrund", 0)) == 48 and int(_farm_counts.get("middelgrunden", 0)) == 20


func _build_shared_renderers() -> void:
	var model: Dictionary = WindTurbineModel.build_meshes(hub_height_m, rotor_radius_m, foundation_depth_m)
	var custom_bounds := _calculate_custom_aabb()
	var instance_count := _records.size()
	_near_base_renderer = _create_multimesh_renderer("TurbinesNearBase", model["base_near"], model["base_material"], instance_count, custom_bounds)
	_near_rotor_renderer = _create_multimesh_renderer("TurbinesNearRotors", model["rotor_near"], model["rotor_material"], instance_count, custom_bounds)
	_far_base_renderer = _create_multimesh_renderer("TurbinesFarBase", model["base_far"], model["base_material"], instance_count, custom_bounds)
	_far_rotor_renderer = _create_multimesh_renderer("TurbinesFarRotors", model["rotor_far"], model["rotor_material"], instance_count, custom_bounds)
	_beacon_material = model["beacon_material"] as StandardMaterial3D
	_beacon_renderer = _create_multimesh_renderer("TurbineNightBeacons", model["beacon"], _beacon_material, instance_count, custom_bounds)
	_platform_light_material = model["platform_light_material"] as StandardMaterial3D
	_platform_light_renderer = _create_multimesh_renderer("TurbinePlatformLights", model["platform_light"], _platform_light_material, instance_count * 2, custom_bounds)


func _create_dynamic_light_pool() -> void:
	for index in range(MAX_DYNAMIC_LIGHTED_TURBINES):
		var beacon := _create_fill_light("BeaconFillLight_%02d" % index, Color("#E6514A"), beacon_fill_light_energy, beacon_fill_light_range_m)
		var platform_left := _create_fill_light("PlatformAmberFillLeft_%02d" % index, Color("#E8B76B"), platform_fill_light_energy, platform_fill_light_range_m)
		var platform_right := _create_fill_light("PlatformAmberFillRight_%02d" % index, Color("#E8B76B"), platform_fill_light_energy, platform_fill_light_range_m)
		_dynamic_lamp_pairs.append({
			"beacon": beacon,
			"platform_left": platform_left,
			"platform_right": platform_right,
		})


func _create_fill_light(node_name: String, color: Color, energy: float, range_m: float) -> OmniLight3D:
	var light := OmniLight3D.new()
	light.name = node_name
	light.light_color = color
	light.light_energy = energy
	light.omni_range = range_m
	light.light_specular = 0.08
	light.shadow_enabled = false
	light.visible = false
	add_child(light)
	return light


func _create_multimesh_renderer(node_name: String, mesh: Mesh, material: Material, count: int, bounds: AABB) -> MultiMeshInstance3D:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = count
	multimesh.visible_instance_count = 0
	var renderer := MultiMeshInstance3D.new()
	renderer.name = node_name
	renderer.multimesh = multimesh
	renderer.material_override = material
	renderer.custom_aabb = bounds
	renderer.visible = false
	add_child(renderer)
	return renderer


func _calculate_custom_aabb() -> AABB:
	if _records.is_empty():
		return AABB(Vector3(-1.0, -foundation_depth_m, -1.0), Vector3(2.0, hub_height_m + rotor_radius_m + foundation_depth_m, 2.0))
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for record in _records:
		var position: Vector3 = record["position"]
		min_x = minf(min_x, position.x)
		max_x = maxf(max_x, position.x)
		min_z = minf(min_z, position.z)
		max_z = maxf(max_z, position.z)
	var margin := rotor_radius_m + 8.0
	var min_y := -foundation_depth_m - 2.0
	var max_y := hub_height_m + rotor_radius_m + 5.0
	return AABB(Vector3(min_x - margin, min_y, min_z - margin), Vector3(max_x - min_x + margin * 2.0, max_y - min_y, max_z - min_z + margin * 2.0))


func _update_lod() -> void:
	var observer := to_local(_boat.global_position) if is_instance_valid(_boat) else Vector3.ZERO
	_near_indices.clear()
	_far_indices.clear()
	_active_indices.clear()
	for index in range(_records.size()):
		var position: Vector3 = _records[index]["position"]
		var distance := Vector2(position.x - observer.x, position.z - observer.z).length()
		if distance <= near_lod_radius_m:
			_near_indices.append(index)
			_active_indices.append(index)
		elif distance <= far_visible_radius_m:
			_far_indices.append(index)
			_active_indices.append(index)
	_pack_base_instances(_near_base_renderer, _near_indices)
	_pack_base_instances(_far_base_renderer, _far_indices)
	_pack_beacon_instances()
	_pack_platform_lights()
	_update_dynamic_light_pool(observer)
	_update_rotor_transforms()


func _update_dynamic_light_pool(observer: Vector3) -> void:
	if _dynamic_lamp_pairs.is_empty():
		return
	var candidates := _near_indices.duplicate()
	for pair_value in _dynamic_lamp_pairs:
		var pair: Dictionary = pair_value
		if candidates.is_empty():
			_set_light_pair_visible(pair, false)
			continue
		var nearest_candidate_position := 0
		var nearest_distance_squared := INF
		for candidate_position in range(candidates.size()):
			var turbine_index := int(candidates[candidate_position])
			var turbine_position: Vector3 = _records[turbine_index]["position"]
			var distance_squared := Vector2(turbine_position.x - observer.x, turbine_position.z - observer.z).length_squared()
			if distance_squared < nearest_distance_squared:
				nearest_distance_squared = distance_squared
				nearest_candidate_position = candidate_position
		var selected_index := int(candidates[nearest_candidate_position])
		candidates.remove_at(nearest_candidate_position)
		var record: Dictionary = _records[selected_index]
		var heading_basis := Basis(Vector3.UP, float(record["yaw"]))
		var base_position: Vector3 = record["position"]
		var beacon_light := pair["beacon"] as OmniLight3D
		var platform_left := pair["platform_left"] as OmniLight3D
		var platform_right := pair["platform_right"] as OmniLight3D
		beacon_light.position = base_position + heading_basis * Vector3(0.0, hub_height_m + 2.25, -2.1)
		platform_left.position = base_position + heading_basis * Vector3(-2.35, 4.48, 1.85)
		platform_right.position = base_position + heading_basis * Vector3(2.35, 4.48, 1.85)
		_set_light_pair_visible(pair, _night_factor > 0.04)


func _set_light_pair_visible(pair: Dictionary, should_be_visible: bool) -> void:
	(pair["beacon"] as OmniLight3D).visible = should_be_visible and red_night_beacons_enabled
	var platform_lights_enabled := should_be_visible and platform_night_lights_enabled
	(pair["platform_left"] as OmniLight3D).visible = platform_lights_enabled
	(pair["platform_right"] as OmniLight3D).visible = platform_lights_enabled


func _pack_base_instances(renderer: MultiMeshInstance3D, indices: PackedInt32Array) -> void:
	if not is_instance_valid(renderer):
		return
	var multimesh := renderer.multimesh
	multimesh.visible_instance_count = indices.size()
	for packed_index in range(indices.size()):
		var record: Dictionary = _records[indices[packed_index]]
		var position: Vector3 = record["position"]
		var basis := Basis(Vector3.UP, float(record["yaw"]))
		multimesh.set_instance_transform(packed_index, Transform3D(basis, position))
	renderer.visible = not indices.is_empty()


func _pack_beacon_instances() -> void:
	if not is_instance_valid(_beacon_renderer):
		return
	var multimesh := _beacon_renderer.multimesh
	multimesh.visible_instance_count = _active_indices.size()
	for packed_index in range(_active_indices.size()):
		var record: Dictionary = _records[_active_indices[packed_index]]
		var base_basis := Basis(Vector3.UP, float(record["yaw"]))
		var position: Vector3 = record["position"] + base_basis * Vector3(0.0, hub_height_m + 2.25, -2.1)
		multimesh.set_instance_transform(packed_index, Transform3D(base_basis, position))
	_beacon_renderer.visible = red_night_beacons_enabled and _night_factor > 0.04 and not _active_indices.is_empty()


func _pack_platform_lights() -> void:
	if not is_instance_valid(_platform_light_renderer):
		return
	var multimesh := _platform_light_renderer.multimesh
	multimesh.visible_instance_count = _near_indices.size() * 2
	for packed_index in range(_near_indices.size()):
		var record: Dictionary = _records[_near_indices[packed_index]]
		var base_basis := Basis(Vector3.UP, float(record["yaw"]))
		var base_position: Vector3 = record["position"]
		for light_index in range(2):
			var side := -1.0 if light_index == 0 else 1.0
			var offset := base_basis * Vector3(side * 2.35, 4.48, 1.85)
			multimesh.set_instance_transform(packed_index * 2 + light_index, Transform3D(base_basis, base_position + offset))
	_platform_light_renderer.visible = platform_night_lights_enabled and _night_factor > 0.04 and not _near_indices.is_empty()


func _update_rotor_transforms() -> void:
	_update_rotor_group(_near_rotor_renderer, _near_indices, false)
	_update_rotor_group(_far_rotor_renderer, _far_indices, true)


func _update_rotor_group(renderer: MultiMeshInstance3D, indices: PackedInt32Array, far_lod: bool) -> void:
	if not is_instance_valid(renderer):
		return
	var multimesh := renderer.multimesh
	multimesh.visible_instance_count = indices.size()
	for packed_index in range(indices.size()):
		var record: Dictionary = _records[indices[packed_index]]
		var heading_basis := Basis(Vector3.UP, float(record["yaw"]))
		var rotor_angle := _rotor_angle + float(record["phase"])
		var spin_basis := Basis(Vector3.BACK, rotor_angle)
		var hub_offset_z := 2.4 if not far_lod else 2.1
		var position: Vector3 = record["position"] + heading_basis * Vector3(0.0, hub_height_m, hub_offset_z)
		var rotor_basis := heading_basis * spin_basis
		multimesh.set_instance_transform(packed_index, Transform3D(rotor_basis, position))
	renderer.visible = not indices.is_empty()


func _update_night_lighting(force: bool = false) -> void:
	var daylight := 1.0
	if is_instance_valid(_day_night_controller) and _day_night_controller.has_method("get_daylight_strength"):
		daylight = clampf(float(_day_night_controller.call("get_daylight_strength")), 0.0, 1.0)
	var next_night_factor := 1.0 - smoothstep(0.08, 0.82, daylight)
	if not force and absf(next_night_factor - _night_factor) < 0.015:
		return
	_night_factor = next_night_factor
	if _beacon_material != null:
		_beacon_material.emission_energy_multiplier = beacon_emission_energy * _night_factor
	if _platform_light_material != null:
		_platform_light_material.emission_energy_multiplier = platform_light_emission_energy * _night_factor
	for pair_value in _dynamic_lamp_pairs:
		var pair: Dictionary = pair_value
		(pair["beacon"] as OmniLight3D).light_energy = beacon_fill_light_energy * _night_factor
		(pair["platform_left"] as OmniLight3D).light_energy = platform_fill_light_energy * _night_factor
		(pair["platform_right"] as OmniLight3D).light_energy = platform_fill_light_energy * _night_factor
	if is_instance_valid(_beacon_renderer):
		_beacon_renderer.visible = red_night_beacons_enabled and _night_factor > 0.04 and not _active_indices.is_empty()
	if is_instance_valid(_platform_light_renderer):
		_platform_light_renderer.visible = platform_night_lights_enabled and _night_factor > 0.04 and not _near_indices.is_empty()
	for pair_value in _dynamic_lamp_pairs:
		var pair: Dictionary = pair_value
		_set_light_pair_visible(pair, _night_factor > 0.04)
