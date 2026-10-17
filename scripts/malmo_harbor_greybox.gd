extends Node3D

## Phase 1 Malmö harbour greybox. All layout offsets are in east/north metres
## relative to a documented WGS84 test anchor; no boat or ocean physics are added.

signal port_docked(port_id: String)
signal port_undocked(port_id: String)
signal port_services_requested(port_id: String)

@export_category("References")
@export var georeference: GeoReference
@export var service_config: PortServiceConfig
@export var port_definition: PortDefinition
@export_node_path("Node3D") var boat_path := NodePath("../PlayerBoat/MotionRoot")
@export_node_path("Node") var bathymetry_path := NodePath("../BathymetryManager")
@export_node_path("Node") var navigation_depth_provider_path := NodePath("../NavigationDepthProvider")
@export_node_path("CanvasLayer") var service_controller_path := NodePath("PortServiceController")
@export_node_path("Node") var economy_manager_path := NodePath("../CargoEconomyManager")

@export_category("Test placement")
@export var port_id := "malmo_greybox_v1"
@export_range(55.0, 56.0, 0.00001) var port_latitude_deg := 55.619
@export_range(12.0, 13.5, 0.00001) var port_longitude_deg := 12.977
@export var test_offset_east_north_m := Vector2.ZERO
@export_range(-180.0, 180.0, 1.0) var layout_rotation_degrees := 0.0
@export var debug_teleport_action := "port_debug_teleport"
@export var depth_override_id_prefix := "malmo"

@export_category("Port coordinates · east/north metres from anchor")
@export var entrance_offset_east_north_m := Vector2(-95.0, 0.0)
@export var approach_offset_east_north_m := Vector2(-260.0, 0.0)
@export var departure_offset_east_north_m := Vector2(-360.0, 0.0)
@export var berth_offset_east_north_m := Vector2(-80.5, 7.3)
@export var service_offset_east_north_m := Vector2(-32.0, 8.0)
@export_range(-180.0, 180.0, 1.0) var berth_heading_degrees := -90.0

@export_category("Greybox dimensions · metres")
@export_range(20.0, 80.0, 1.0) var entrance_width_m := 40.0
@export_range(60.0, 180.0, 1.0) var breakwater_length_m := 100.0
@export_range(3.0, 12.0, 0.5) var breakwater_width_m := 6.0
@export_range(50.0, 180.0, 1.0) var main_quay_length_m := 130.0
@export_range(4.0, 14.0, 0.5) var main_quay_width_m := 10.0
@export_range(25.0, 90.0, 1.0) var main_pier_length_m := 63.0
@export_range(3.0, 10.0, 0.5) var pier_width_m := 6.5
@export_range(12.0, 36.0, 1.0) var berth_length_m := 22.0
@export_range(7.0, 18.0, 0.5) var berth_width_m := 10.5
@export_range(4.0, 15.0, 0.5) var berth_interaction_radius_m := 8.7
@export_range(0.0, 3.0, 0.1) var docking_speed_threshold_mps := 0.8
@export_range(5.0, 45.0, 1.0) var docking_heading_tolerance_degrees := 20.0
@export_range(0.1, 2.0, 0.05) var hull_clearance_m := 0.5
@export_range(0.5, 3.0, 0.1) var quay_top_y_m := 1.5
@export_range(0.5, 3.0, 0.1) var pier_top_y_m := 1.25
@export_range(0.0, 2.0, 0.05) var visual_lat_alignment_m := 0.5
@export var show_debug_by_default := false
@export var developer_tools_enabled := true

@export_category("Gameplay-only depth polygons · unverified")
@export var enable_gameplay_depth_overrides := true
@export_range(0.5, 30.0, 0.1) var entrance_channel_depth_m := 4.5
@export_range(0.5, 20.0, 0.1) var basin_depth_m := 3.0
@export_range(0.5, 15.0, 0.1) var berth_depth_m := 1.6

const DEFAULT_BOAT_LENGTH_M := 5.263
const DEFAULT_BOAT_BEAM_M := 2.327
const QUAY_CENTER_EAST_M := -50.0
const MAIN_PIER_CENTER_EAST_M := -81.5
const AUX_PIER_CENTER_EAST_M := -77.0
const WAREHOUSE_CENTER_EAST_M := -32.0
const WAREHOUSE_CENTER_NORTH_M := 22.0
const BREAKWATER_CENTER_EAST_M := -145.0
const BREAKWATER_HALF_SEPARATION_M := 20.0
const FALLBACK_PILE_BOTTOM_Y_M := -4.0

const ACTION_INTERACT := "port_interact"
const ACTION_OPEN_SERVICES := "port_open_services"
const ACTION_DEBUG_TELEPORT := "port_debug_teleport"
const ACTION_DEBUG_TOGGLE := "port_debug_toggle"

var _boat: BoatController
var _bathymetry: BathymetryManager
var _depth_provider: NavigationDepthProvider
var _service_controller: PortServiceController
var _economy_manager: CargoEconomyManager
var _route_manager: PortRouteManager
var _display_name := "Port"
var _world_anchor := Vector3.ZERO
var _entrance_position := Vector3.ZERO
var _approach_position := Vector3.ZERO
var _departure_position := Vector3.ZERO
var _berth_position := Vector3.ZERO
var _service_position := Vector3.ZERO
var _debug_root: Node3D
var _prompt_layer: CanvasLayer
var _prompt_panel: PanelContainer
var _prompt_label: Label
var _debug_panel: PanelContainer
var _debug_label: Label
var _dev_delivery_button: Button
var _debug_enabled := false
var _docked := false
var _paused_before_docking := false
var _external_interaction_active := false
var _ui_elapsed := 0.0
var _materials: Dictionary = {}
var _berth_depth_cache: Dictionary = {}
var _depth_cache_elapsed := 0.0


func _ready() -> void:
	_debug_enabled = show_debug_by_default
	_apply_port_definition()
	_boat = get_node_or_null(boat_path) as BoatController
	_bathymetry = get_node_or_null(bathymetry_path) as BathymetryManager
	_depth_provider = get_node_or_null(navigation_depth_provider_path) as NavigationDepthProvider
	_service_controller = get_node_or_null(service_controller_path) as PortServiceController
	_economy_manager = get_node_or_null(economy_manager_path) as CargoEconomyManager
	_route_manager = get_node_or_null("../PortRouteManager") as PortRouteManager
	if georeference == null:
		push_error("GreyboxPort: GeoReference is required.")
		set_process(false)
		return
	if _boat == null:
		push_error("GreyboxPort: player BoatController was not found.")
		set_process(false)
		return

	var anchor: Vector3 = georeference.geodetic_to_world(port_latitude_deg, port_longitude_deg, 0.0)
	_world_anchor = Vector3(anchor.x + test_offset_east_north_m.x, 0.0, anchor.z - test_offset_east_north_m.y)
	global_position = _world_anchor
	global_rotation.y = deg_to_rad(layout_rotation_degrees)
	_entrance_position = _world_anchor + _offset_to_world(entrance_offset_east_north_m)
	_approach_position = _world_anchor + _offset_to_world(approach_offset_east_north_m)
	_departure_position = _world_anchor + _offset_to_world(departure_offset_east_north_m)
	_berth_position = _world_anchor + _offset_to_world(berth_offset_east_north_m)
	_service_position = _world_anchor + _offset_to_world(service_offset_east_north_m)
	_register_gameplay_depth_areas()
	_build_materials()
	_build_harbour()
	_build_debug_markers()
	_build_ui()
	refresh_berth_depth_cache()
	set_process(true)


func _exit_tree() -> void:
	_unregister_gameplay_depth_areas()


func _process(delta: float) -> void:
	_depth_cache_elapsed += delta
	if _depth_cache_elapsed >= 0.5:
		_depth_cache_elapsed = fmod(_depth_cache_elapsed, 0.5)
		refresh_berth_depth_cache()
	_ui_elapsed += delta
	if _ui_elapsed < 0.08:
		return
	_ui_elapsed = fmod(_ui_elapsed, 0.08)
	var status := get_docking_diagnostics()
	_update_prompt(status)
	if _debug_enabled:
		_update_debug_label(status)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(ACTION_OPEN_SERVICES) and not event.is_echo():
		if _docked and request_open_services():
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(ACTION_INTERACT) and not event.is_echo():
		if _docked:
			# E remains the legacy undock key after closing the menu, but is inert
			# while the service overlay is open.
			if _service_controller != null and _service_controller.is_menu_open():
				get_viewport().set_input_as_handled()
			elif request_undock():
				get_viewport().set_input_as_handled()
		else:
			if request_dock():
				get_viewport().set_input_as_handled()
		return
	if not developer_tools_enabled:
		return
	if event.is_action_pressed(ACTION_DEBUG_TOGGLE) and not event.is_echo():
		_debug_enabled = not _debug_enabled
		_debug_root.visible = _debug_enabled
		_debug_panel.visible = _debug_enabled
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(debug_teleport_action) and not event.is_echo():
		teleport_to_approach()
		get_viewport().set_input_as_handled()


func is_docked() -> bool:
	return _docked


func get_service_config() -> PortServiceConfig:
	return service_config


func get_port_display_name() -> String:
	return _display_name


func request_open_services() -> bool:
	if not _docked:
		return false
	port_services_requested.emit(port_id)
	return true


func get_docking_diagnostics() -> Dictionary:
	if _boat == null:
		return {"can_dock": false, "near_berth": false, "docked": _docked}
	var offset := _boat.global_position - _berth_position
	var distance := Vector2(offset.x, offset.z).length()
	var heading_radians := deg_to_rad(get_effective_berth_heading_degrees())
	var expected_forward := Basis(Vector3.UP, heading_radians) * Vector3.FORWARD
	var actual_forward := -_boat.global_transform.basis.z
	actual_forward.y = 0.0
	actual_forward = actual_forward.normalized()
	var side_direction := expected_forward.cross(Vector3.UP).normalized()
	var along_distance := offset.dot(expected_forward)
	var side_distance := offset.dot(side_direction)
	var boat_length := _boat.get_vessel_length_m() if _boat != null else DEFAULT_BOAT_LENGTH_M
	var boat_beam := _boat.get_vessel_beam_m() if _boat != null else DEFAULT_BOAT_BEAM_M
	var allowed_along := maxf(0.0, berth_length_m * 0.5 - boat_length * 0.5 - hull_clearance_m)
	var allowed_side := maxf(0.0, berth_width_m * 0.5 - boat_beam * 0.5 - hull_clearance_m)
	var heading_error := rad_to_deg(expected_forward.angle_to(actual_forward))
	var position_ok := (
		absf(along_distance) <= allowed_along
		and absf(side_distance) <= allowed_side
		and distance <= berth_interaction_radius_m
	)
	var speed_ok := absf(_boat.speed_mps) <= docking_speed_threshold_mps
	var heading_ok := heading_error <= docking_heading_tolerance_degrees
	var berth_depth_status := _berth_depth_cache
	var depth_ok := bool(berth_depth_status.get("depth_ok", false))
	var can_dock := position_ok and speed_ok and heading_ok and depth_ok and not _external_interaction_active and not _docked
	var current_depth := _depth_provider.evaluate_world_position(_boat.global_position, _boat.get_current_draft_m()) if _depth_provider != null and _boat.get_current_draft_m() >= 0.0 else {"valid": false, "status": NavigationDepthProvider.STATUS_UNKNOWN}
	return {
		"port_id": port_id,
		"distance_m": distance,
		"along_distance_m": along_distance,
		"side_distance_m": side_distance,
		"heading_error_degrees": heading_error,
		"speed_mps": _boat.speed_mps,
		"position_ok": position_ok,
		"speed_ok": speed_ok,
		"heading_ok": heading_ok,
		"depth_ok": depth_ok,
		"depth_status": str(berth_depth_status.get("status", NavigationDepthProvider.STATUS_UNKNOWN)),
		"depth_reason": str(berth_depth_status.get("reason", "泊位水深未知")),
		"berth_depth_samples": berth_depth_status.get("samples", []),
		"current_depth": current_depth,
		"draft_m": _boat.get_current_draft_m(),
		"interaction_available": not _external_interaction_active,
		"near_berth": distance <= maxf(berth_interaction_radius_m + 8.0, 18.0),
		"can_dock": can_dock,
		"docked": _docked,
	}


func set_external_interaction_active(active: bool) -> void:
	_external_interaction_active = active


func get_port_configuration() -> Dictionary:
	return {
		"port_id": port_id,
		"display_name": _display_name,
		"port_position": _world_anchor,
		"entrance_position": _entrance_position,
		"approach_position": _approach_position,
		"departure_position": _departure_position,
		"berth_position": _berth_position,
		"service_interaction_position": _service_position,
		"berth_heading_degrees": get_effective_berth_heading_degrees(),
		"berth_interaction_radius_m": berth_interaction_radius_m,
		"geo_position": Vector2(port_latitude_deg, port_longitude_deg),
		"environment_configuration": port_definition.environment_configuration if port_definition != null else {},
	}


func get_effective_berth_heading_degrees() -> float:
	return wrapf(layout_rotation_degrees + berth_heading_degrees, -180.0, 180.0)


func request_dock() -> bool:
	refresh_berth_depth_cache()
	if not bool(get_docking_diagnostics().get("can_dock", false)):
		return false
	_dock()
	return true


func request_undock() -> bool:
	if not _docked:
		return false
	_undock()
	return true


func refresh_berth_depth_cache() -> Dictionary:
	_berth_depth_cache = _evaluate_berth_depth()
	return _berth_depth_cache.duplicate(true)


func get_berth_depth_status() -> Dictionary:
	return _berth_depth_cache.duplicate(true)


func teleport_to_approach() -> void:
	if _boat == null:
		return
	if _docked:
		_undock()
	_boat.is_autopilot = false
	_boat.speed_mps = 0.0
	_boat.is_motion_paused = false
	_boat.global_position = _approach_position
	_boat.global_rotation.y = deg_to_rad(get_effective_berth_heading_degrees())


func _dock() -> void:
	if _boat == null:
		return
	_paused_before_docking = _boat.is_motion_paused
	_boat.speed_mps = 0.0
	_boat.set_port_docked(true)
	_docked = true
	port_docked.emit(port_id)


func _undock() -> void:
	if _boat == null:
		_docked = false
		return
	_boat.set_port_docked(false)
	_boat.is_motion_paused = _paused_before_docking
	_boat.speed_mps = 0.0
	_docked = false
	port_undocked.emit(port_id)


func _apply_port_definition() -> void:
	if port_definition == null:
		_display_name = service_config.display_name if service_config != null else port_id
		return
	port_id = str(port_definition.port_id)
	_display_name = port_definition.display_name
	port_latitude_deg = port_definition.latitude_deg
	port_longitude_deg = port_definition.longitude_deg
	layout_rotation_degrees = port_definition.layout_rotation_degrees
	entrance_offset_east_north_m = port_definition.entrance_offset_east_north_m
	approach_offset_east_north_m = port_definition.approach_offset_east_north_m
	departure_offset_east_north_m = port_definition.departure_offset_east_north_m
	service_offset_east_north_m = port_definition.service_offset_east_north_m
	if port_definition.service_config != null:
		service_config = port_definition.service_config
	depth_override_id_prefix = port_definition.depth_override_id_prefix
	var berth := port_definition.get_primary_berth()
	if not berth.is_empty():
		var berth_offset: Variant = berth.get("offset_east_north_m", berth_offset_east_north_m)
		if berth_offset is Vector2:
			berth_offset_east_north_m = berth_offset
		berth_heading_degrees = float(berth.get("heading_degrees", berth_heading_degrees))
		berth_length_m = float(berth.get("length_m", berth_length_m))
		berth_width_m = float(berth.get("width_m", berth_width_m))
		berth_interaction_radius_m = float(berth.get("interaction_radius_m", berth_interaction_radius_m))
		docking_speed_threshold_mps = float(berth.get("docking_speed_threshold_mps", docking_speed_threshold_mps))
		docking_heading_tolerance_degrees = float(berth.get("heading_tolerance_degrees", docking_heading_tolerance_degrees))
		hull_clearance_m = float(berth.get("hull_clearance_m", hull_clearance_m))
		berth_depth_m = float(berth.get("depth_m", berth_depth_m))
	entrance_channel_depth_m = float(port_definition.get_depth_override("entrance_channel").get("depth_m", entrance_channel_depth_m))
	basin_depth_m = float(port_definition.get_depth_override("basin").get("depth_m", basin_depth_m))
	berth_depth_m = float(port_definition.get_depth_override("berth").get("depth_m", berth_depth_m))


func _offset_to_world(offset_east_north: Vector2, y: float = 0.0) -> Vector3:
	return Basis(Vector3.UP, deg_to_rad(layout_rotation_degrees)) * Vector3(offset_east_north.x, y, -offset_east_north.y)


func _world_to_local_offset(world_position: Vector3) -> Vector3:
	return Basis(Vector3.UP, deg_to_rad(layout_rotation_degrees)).inverse() * (world_position - _world_anchor)


func _local_position_to_world(local_position: Vector3) -> Vector3:
	return _world_anchor + Basis(Vector3.UP, deg_to_rad(layout_rotation_degrees)) * local_position


func _rotate_local_east_north(point: Vector2) -> Vector2:
	var rotated := Basis(Vector3.UP, deg_to_rad(layout_rotation_degrees)) * Vector3(point.x, 0.0, -point.y)
	return Vector2(rotated.x, -rotated.z)


func _rotate_polygon(polygon: PackedVector2Array) -> PackedVector2Array:
	var result := PackedVector2Array()
	for point in polygon:
		result.append(_rotate_local_east_north(point))
	return result


func _register_gameplay_depth_areas() -> void:
	if _depth_provider == null or not enable_gameplay_depth_overrides:
		return
	var route := entrance_offset_east_north_m - approach_offset_east_north_m
	var direction := route.normalized()
	var side := Vector2(-direction.y, direction.x)
	var half_width := entrance_width_m * 0.5 + 3.0
	var channel_polygon := PackedVector2Array([
		approach_offset_east_north_m - side * half_width,
		entrance_offset_east_north_m - side * half_width,
		entrance_offset_east_north_m + side * half_width,
		approach_offset_east_north_m + side * half_width,
	])
	_depth_provider.register_polygon_override(
		"%s_entrance_channel_v1" % depth_override_id_prefix, _world_anchor, _rotate_polygon(channel_polygon), entrance_channel_depth_m, 100,
		"GAME_SURFACE_REFERENCE", _depth_override_source("entrance_channel")
	)
	var basin_polygon := PackedVector2Array([
		Vector2(-116.0, -25.0), Vector2(-47.0, -25.0),
		Vector2(-47.0, 25.0), Vector2(-116.0, 25.0),
	])
	_depth_provider.register_polygon_override(
		"%s_basin_v1" % depth_override_id_prefix, _world_anchor, _rotate_polygon(basin_polygon), basin_depth_m, 110,
		"GAME_SURFACE_REFERENCE", _depth_override_source("basin")
	)
	var berth_forward_local := Basis(Vector3.UP, deg_to_rad(berth_heading_degrees)) * Vector3.FORWARD
	var berth_side_local := berth_forward_local.cross(Vector3.UP).normalized()
	var berth_forward_en := Vector2(berth_forward_local.x, -berth_forward_local.z)
	var berth_side_en := Vector2(berth_side_local.x, -berth_side_local.z)
	var berth_center := berth_offset_east_north_m
	var half_berth_length := berth_length_m * 0.5 + 3.0
	var half_berth_width := berth_width_m * 0.5 + 3.0
	var berth_polygon := PackedVector2Array([
		berth_center - berth_forward_en * half_berth_length - berth_side_en * half_berth_width,
		berth_center + berth_forward_en * half_berth_length - berth_side_en * half_berth_width,
		berth_center + berth_forward_en * half_berth_length + berth_side_en * half_berth_width,
		berth_center - berth_forward_en * half_berth_length + berth_side_en * half_berth_width,
	])
	_depth_provider.register_polygon_override(
		"%s_berth_v1" % depth_override_id_prefix, _world_anchor, _rotate_polygon(berth_polygon), berth_depth_m, 120,
		"GAME_SURFACE_REFERENCE", _depth_override_source("berth")
	)


func _depth_override_source(area_name: String) -> String:
	if port_definition != null:
		var config := port_definition.get_depth_override(area_name)
		if config.has("source"):
			return str(config["source"])
	return "Gameplay-configured depth (unverified)"


func _unregister_gameplay_depth_areas() -> void:
	if _depth_provider == null:
		return
	_depth_provider.remove_depth_override("%s_entrance_channel_v1" % depth_override_id_prefix)
	_depth_provider.remove_depth_override("%s_basin_v1" % depth_override_id_prefix)
	_depth_provider.remove_depth_override("%s_berth_v1" % depth_override_id_prefix)


func _evaluate_berth_depth() -> Dictionary:
	var draft := _boat.get_current_draft_m() if _boat != null else -1.0
	var margin := _depth_provider.safety_margin_m if _depth_provider != null else 0.0
	var samples: Array[Dictionary] = []
	var worst_status := NavigationDepthProvider.STATUS_SAFE
	var depth_ok := draft >= 0.0 and _depth_provider != null
	var sample_offsets := [
		["中心", 0.0, 0.0],
		["船首侧", 6.0, 0.0],
		["船尾侧", -6.0, 0.0],
		["左舷侧", 0.0, 3.0],
		["右舷侧", 0.0, -3.0],
	]
	var berth_forward := Basis(Vector3.UP, deg_to_rad(get_effective_berth_heading_degrees())) * Vector3.FORWARD
	var berth_side := berth_forward.cross(Vector3.UP).normalized()
	for item in sample_offsets:
		var position := _berth_position + berth_forward * float(item[1]) + berth_side * float(item[2])
		var evaluation: Dictionary
		if _depth_provider != null and draft >= 0.0:
			evaluation = _depth_provider.evaluate_world_position(position, draft)
		else:
			evaluation = NavigationDepthProvider.evaluate_depth_sample({"valid": false, "data_state": "no_data", "reason": "No provider or draft profile"}, maxf(draft, 0.0), margin)
		var status := str(evaluation.get("status", NavigationDepthProvider.STATUS_UNKNOWN))
		if status != NavigationDepthProvider.STATUS_SAFE:
			depth_ok = false
			worst_status = NavigationDepthProvider.worse_status(worst_status, status)
		samples.append({"name": str(item[0]), "world_position": position, "evaluation": evaluation})
	var reason := "泊位各采样点满足吃水与安全余量"
	if not depth_ok:
		if worst_status == NavigationDepthProvider.STATUS_UNSAFE:
			reason = "泊位水深低于当前吃水"
		elif worst_status == NavigationDepthProvider.STATUS_CAUTION:
			reason = "泊位水深未达到安全余量，拒绝靠泊"
		else:
			reason = "泊位存在未知/非水域采样点，拒绝靠泊"
	return {"depth_ok": depth_ok, "status": worst_status, "reason": reason, "samples": samples, "draft_m": draft, "safety_margin_m": margin}
func _build_materials() -> void:
	_materials["concrete"] = _make_material(Color(0.44, 0.49, 0.48))
	_materials["concrete_top"] = _make_material(Color(0.61, 0.64, 0.59))
	_materials["breakwater"] = _make_material(Color(0.31, 0.37, 0.38))
	_materials["breakwater_cap"] = _make_material(Color(0.39, 0.44, 0.43))
	_materials["pier"] = _make_material(Color(0.43, 0.51, 0.51))
	_materials["pile"] = _make_material(Color(0.28, 0.34, 0.35))
	_materials["fender"] = _make_material(Color(0.13, 0.18, 0.19))
	_materials["bollard"] = _make_material(Color(0.86, 0.62, 0.24))
	_materials["warehouse"] = _make_material(Color(0.62, 0.42, 0.30))
	_materials["roof"] = _make_material(Color(0.27, 0.32, 0.34))
	_materials["door"] = _make_material(Color(0.25, 0.29, 0.30))
	_materials["red"] = _make_material(Color(0.82, 0.18, 0.16))
	_materials["green"] = _make_material(Color(0.16, 0.62, 0.40))
	_materials["berth"] = _make_material(Color(0.94, 0.77, 0.34))
	_materials["service"] = _make_material(Color(0.27, 0.73, 0.82))
	_materials["debug"] = _make_unshaded_material(Color(0.25, 0.95, 0.96))


func _make_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.88
	material.metallic = 0.0
	return material


func _make_unshaded_material(color: Color) -> StandardMaterial3D:
	var material := _make_material(color)
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return material


func _build_harbour() -> void:
	var quay_center := Vector3(QUAY_CENTER_EAST_M, 0.0, 0.0)
	_add_box("MainQuayWall", quay_center + Vector3(0.0, (quay_top_y_m - 4.2) * 0.5, 0.0), Vector3(main_quay_width_m, quay_top_y_m + 4.2, main_quay_length_m), _materials["concrete"])
	_add_box("MainQuayDeck", quay_center + Vector3(0.0, quay_top_y_m - 0.04, 0.0), Vector3(main_quay_width_m + 0.4, 0.12, main_quay_length_m + 0.4), _materials["concrete_top"])
	_build_breakwaters()
	_build_piers()
	_build_warehouse()
	_build_quay_fittings()
	_build_entrance_markers()
	_build_berth_markers()
	var service_local := _world_to_local_offset(_service_position)
	_add_sphere("ServiceMarker", service_local + Vector3(0.0, 1.6, 0.0), 0.85, _materials["service"])
	_add_label3d("服务点 / SERVICE", service_local + Vector3(0.0, 3.0, 0.0), Color(0.65, 0.94, 1.0))


func _build_breakwaters() -> void:
	var length := breakwater_length_m
	var center_x := BREAKWATER_CENTER_EAST_M
	var center_y := (quay_top_y_m - 3.8) * 0.5
	var height := quay_top_y_m + 3.8
	var half_gap := maxf(entrance_width_m * 0.5 + breakwater_width_m * 0.5, BREAKWATER_HALF_SEPARATION_M)
	for sign_value in [-1.0, 1.0]:
		var z := float(sign_value) * half_gap
		_add_box("Breakwater_%s" % str(sign_value), Vector3(center_x, center_y, z), Vector3(length, height, breakwater_width_m), _materials["breakwater"])
		var cap_count := 8
		for index in range(cap_count):
			var fraction := (float(index) + 0.5) / float(cap_count) - 0.5
			var cap_x := center_x + fraction * (length - 4.0)
			_add_box("BreakwaterCap_%s_%d" % [str(sign_value), index], Vector3(cap_x, quay_top_y_m + 0.05, z), Vector3(length / float(cap_count) - 0.4, 0.25, breakwater_width_m + 0.6), _materials["breakwater_cap"])


func _build_piers() -> void:
	var main_deck_center := Vector3(MAIN_PIER_CENTER_EAST_M, pier_top_y_m - 0.25, 0.0)
	_add_box("MainFingerPier", main_deck_center, Vector3(main_pier_length_m, 0.5, pier_width_m), _materials["pier"])
	var main_start_x := MAIN_PIER_CENTER_EAST_M - main_pier_length_m * 0.5 + 5.0
	for pile_index in range(4):
		var east := main_start_x + float(pile_index) * ((main_pier_length_m - 10.0) / 3.0)
		for side in [-1.0, 1.0]:
			_add_pile("MainPierPile_%d_%s" % [pile_index, str(side)], east, float(side) * (pier_width_m * 0.5 - 0.7), pier_top_y_m - 0.5)

	var aux_length := 48.0
	var aux_width := 5.5
	var aux_center := Vector3(AUX_PIER_CENTER_EAST_M, pier_top_y_m - 0.32, 27.0)
	_add_box("AuxiliaryPier", aux_center, Vector3(aux_length, 0.42, aux_width), _materials["pier"])
	for pile_index in range(4):
		var east := AUX_PIER_CENTER_EAST_M - aux_length * 0.5 + 4.0 + float(pile_index) * ((aux_length - 8.0) / 3.0)
		for side in [-1.0, 1.0]:
			_add_pile("AuxPierPile_%d_%s" % [pile_index, str(side)], east, 27.0 + float(side) * (aux_width * 0.5 - 0.6), pier_top_y_m - 0.42)


func _add_pile(node_name: String, east: float, south: float, deck_underside_y: float) -> void:
	var world_position := _local_position_to_world(Vector3(east, 0.0, south))
	var bottom_y := FALLBACK_PILE_BOTTOM_Y_M
	if _bathymetry != null:
		var depth_sample: Dictionary = _bathymetry.get_depth_at_world_position(world_position)
		if bool(depth_sample.get("valid", false)):
			bottom_y = -float(depth_sample.get("depth_m", 3.5)) - visual_lat_alignment_m
	var pile_height := maxf(deck_underside_y - bottom_y, 0.35)
	var pile_center_y := (deck_underside_y + bottom_y) * 0.5
	_add_cylinder(node_name, Vector3(east, pile_center_y, south), pile_height, 0.42, 0.42, _materials["pile"], 10)


func _build_warehouse() -> void:
	var center := Vector3(WAREHOUSE_CENTER_EAST_M, 4.55, -WAREHOUSE_CENTER_NORTH_M)
	_add_box("WarehouseBody", center, Vector3(22.0, 8.1, 28.0), _materials["warehouse"])
	var roof_y := 9.95
	_add_box("WarehouseRoofWest", Vector3(WAREHOUSE_CENTER_EAST_M - 6.0, roof_y, -WAREHOUSE_CENTER_NORTH_M), Vector3(13.0, 0.55, 29.0), _materials["roof"], deg_to_rad(11.0))
	_add_box("WarehouseRoofEast", Vector3(WAREHOUSE_CENTER_EAST_M + 6.0, roof_y, -WAREHOUSE_CENTER_NORTH_M), Vector3(13.0, 0.55, 29.0), _materials["roof"], deg_to_rad(-11.0))
	_add_box("WarehouseDoor", Vector3(WAREHOUSE_CENTER_EAST_M - 11.12, 2.75, -WAREHOUSE_CENTER_NORTH_M), Vector3(0.16, 4.5, 5.0), _materials["door"])


func _build_quay_fittings() -> void:
	for index in range(7):
		var south := -48.0 + float(index) * 16.0
		_add_cylinder("QuayBollard_%d" % index, Vector3(QUAY_CENTER_EAST_M + main_quay_width_m * 0.5 - 0.6, quay_top_y_m + 0.35, south), 0.7, 0.24, 0.24, _materials["bollard"], 10)
	for index in range(8):
		var south := -49.0 + float(index) * 14.0
		_add_box("QuayFender_%d" % index, Vector3(QUAY_CENTER_EAST_M - main_quay_width_m * 0.5 - 0.08, 0.15, south), Vector3(0.32, 1.2, 1.8), _materials["fender"])
	for index in range(5):
		var east := MAIN_PIER_CENTER_EAST_M - main_pier_length_m * 0.5 + float(index) * ((main_pier_length_m - 6.0) / 4.0)
		_add_cylinder("PierBollard_%d" % index, Vector3(east, pier_top_y_m + 0.25, -pier_width_m * 0.5 + 0.45), 0.5, 0.2, 0.2, _materials["bollard"], 10)


func _build_entrance_markers() -> void:
	var half_gap := entrance_width_m * 0.5
	var entrance_local := Vector3(entrance_offset_east_north_m.x, 0.0, -entrance_offset_east_north_m.y)
	for side in [-1.0, 1.0]:
		var marker_local := entrance_local + Vector3(0.0, 0.0, float(side) * half_gap)
		var color_key := "red" if side < 0.0 else "green"
		_add_cylinder("EntranceBeaconPole_%s" % str(side), marker_local + Vector3(0.0, 1.2, 0.0), 3.2, 0.16, 0.2, _materials[color_key], 10)
		_add_sphere("EntranceBeaconTop_%s" % str(side), marker_local + Vector3(0.0, 3.0, 0.0), 0.48, _materials[color_key])
	_add_label3d("入口 / ENTRANCE", entrance_local + Vector3(0.0, 5.0, 0.0), Color(1.0, 0.89, 0.62))


func _build_berth_markers() -> void:
	var berth_local := _world_to_local_offset(_berth_position)
	var forward := Basis(Vector3.UP, deg_to_rad(berth_heading_degrees)) * Vector3.FORWARD
	var side := forward.cross(Vector3.UP).normalized()
	var half_length := berth_length_m * 0.5
	var half_width := berth_width_m * 0.5
	var corners: Array[Vector3] = []
	for along in [-half_length, half_length]:
		for lateral in [-half_width, half_width]:
			corners.append(berth_local + forward * float(along) + side * float(lateral))
	for index in range(corners.size()):
		var corner := corners[index]
		_add_cylinder("BerthCorner_%d" % index, corner + Vector3(0.0, 1.1, 0.0), 2.2, 0.16, 0.22, _materials["berth"], 10)
	_add_label3d("泊位 P1", berth_local + Vector3(0.0, 3.1, 0.0), Color(1.0, 0.91, 0.62))
	_add_sphere("BerthCenterMarker", berth_local + Vector3(0.0, 0.55, 0.0), 0.42, _materials["berth"])


func _build_debug_markers() -> void:
	_debug_root = Node3D.new()
	_debug_root.name = "PortDebugMarkers"
	add_child(_debug_root)
	_debug_root.visible = _debug_enabled
	var entrance_local := _world_to_local_offset(_entrance_position)
	var approach_local := _world_to_local_offset(_approach_position)
	var berth_local := _world_to_local_offset(_berth_position)
	_add_sphere("DebugEntrance", entrance_local + Vector3(0.0, 1.8, 0.0), 1.0, _materials["debug"], _debug_root)
	_add_label3d("入口中心", entrance_local + Vector3(0.0, 5.0, 0.0), Color.CYAN, _debug_root)
	_add_sphere("DebugApproach", approach_local + Vector3(0.0, 1.8, 0.0), 0.75, _materials["debug"], _debug_root)
	_add_label3d("P 测试起点", approach_local + Vector3(0.0, 4.0, 0.0), Color.CYAN, _debug_root)
	_add_sphere("DebugBerth", berth_local + Vector3(0.0, 0.8, 0.0), 0.7, _materials["debug"], _debug_root)
	_add_label3d("泊位交互中心", berth_local + Vector3(0.0, 4.5, 0.0), Color.CYAN, _debug_root)
	_add_interaction_ring(berth_local)
	_add_approach_line(approach_local, entrance_local, berth_local)


func _add_interaction_ring(center: Vector3) -> void:
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for index in range(65):
		var angle := TAU * float(index) / 64.0
		mesh.surface_add_vertex(Vector3(cos(angle) * berth_interaction_radius_m, 0.18, sin(angle) * berth_interaction_radius_m))
	mesh.surface_end()
	mesh.surface_set_material(0, _materials["debug"])
	var instance := MeshInstance3D.new()
	instance.name = "BerthInteractionRadius"
	instance.mesh = mesh
	instance.position = center
	_debug_root.add_child(instance)


func _add_approach_line(approach: Vector3, entrance: Vector3, berth: Vector3) -> void:
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	mesh.surface_add_vertex(approach + Vector3(0.0, 0.35, 0.0))
	mesh.surface_add_vertex(entrance + Vector3(0.0, 0.35, 0.0))
	mesh.surface_add_vertex(berth + Vector3(0.0, 0.35, 0.0))
	mesh.surface_end()
	mesh.surface_set_material(0, _materials["debug"])
	var instance := MeshInstance3D.new()
	instance.name = "ApproachGuide"
	instance.mesh = mesh
	_debug_root.add_child(instance)


func _build_ui() -> void:
	_prompt_layer = CanvasLayer.new()
	_prompt_layer.name = "HarbourInteractionUI"
	_prompt_layer.layer = 18
	add_child(_prompt_layer)
	_prompt_panel = PanelContainer.new()
	_prompt_panel.name = "DockingPrompt"
	_prompt_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_prompt_panel.offset_left = -230.0
	_prompt_panel.offset_right = 230.0
	_prompt_panel.offset_top = -142.0
	_prompt_panel.offset_bottom = -76.0
	_prompt_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prompt_panel.add_theme_stylebox_override("panel", _make_panel_style(Color(0.025, 0.075, 0.09, 0.9)))
	_prompt_layer.add_child(_prompt_panel)
	_prompt_label = Label.new()
	_prompt_label.name = "DockingPromptLabel"
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_prompt_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_prompt_label.add_theme_font_size_override("font_size", 19)
	_prompt_label.add_theme_color_override("font_color", Color(0.92, 0.97, 0.97))
	_prompt_panel.add_child(_prompt_label)
	_prompt_panel.visible = false

	_debug_panel = PanelContainer.new()
	_debug_panel.name = "PortDebugPanel"
	_debug_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_debug_panel.position = Vector2(20.0, 88.0)
	_debug_panel.custom_minimum_size = Vector2(420.0, 0.0)
	_debug_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_debug_panel.add_theme_stylebox_override("panel", _make_panel_style(Color(0.025, 0.075, 0.09, 0.88)))
	_prompt_layer.add_child(_debug_panel)
	var debug_content := VBoxContainer.new()
	debug_content.add_theme_constant_override("separation", 6)
	_debug_panel.add_child(debug_content)
	_debug_label = Label.new()
	_debug_label.name = "PortDebugLabel"
	_debug_label.add_theme_font_size_override("font_size", 14)
	_debug_label.add_theme_color_override("font_color", Color(0.83, 0.94, 0.94))
	_debug_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_debug_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	debug_content.add_child(_debug_label)
	_dev_delivery_button = Button.new()
	_dev_delivery_button.name = "SimulateDeliveryButton"
	_dev_delivery_button.text = "开发测试：模拟目的港交货"
	_dev_delivery_button.tooltip_text = "使用独立开发存档和临时目的港上下文；不改变当前港口位置。"
	_dev_delivery_button.visible = developer_tools_enabled and (OS.has_feature("editor") or OS.has_feature("debug"))
	_dev_delivery_button.pressed.connect(_on_dev_delivery_pressed)
	debug_content.add_child(_dev_delivery_button)
	_debug_panel.visible = _debug_enabled


func _make_panel_style(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	style.content_margin_left = 16.0
	style.content_margin_top = 9.0
	style.content_margin_right = 16.0
	style.content_margin_bottom = 9.0
	return style


func _update_prompt(status: Dictionary) -> void:
	if _docked:
		var menu_open := _service_controller != null and _service_controller.is_menu_open()
		_prompt_panel.visible = not menu_open
		_prompt_label.text = "已靠泊 · 按 E 离泊 · 按 F 打开港口服务" if not menu_open else ""
		return
	if not bool(status.get("near_berth", false)):
		_prompt_panel.visible = false
		return
	_prompt_panel.visible = true
	if bool(status.get("can_dock", false)):
		_prompt_label.text = "泊位 P1 · 按 E 靠泊"
		return
	var reasons := PackedStringArray()
	if not bool(status.get("position_ok", false)):
		reasons.append("驶入泊位范围")
	if not bool(status.get("speed_ok", false)):
		reasons.append("减速至 %.1f m/s 以下" % docking_speed_threshold_mps)
	if not bool(status.get("heading_ok", false)):
		reasons.append("调整船首方向")
	if not bool(status.get("depth_ok", false)):
		reasons.append(str(status.get("depth_reason", "检查泊位水深")))
	if not bool(status.get("interaction_available", false)):
		reasons.append("完成当前交互")
	_prompt_label.text = "靠泊条件：" + " · ".join(reasons)


func _update_debug_label(status: Dictionary) -> void:
	var gps := Vector3.ZERO
	if _boat != null and georeference != null:
		gps = georeference.world_to_geodetic(_boat.global_position)
	var can_dock := "满足" if bool(status.get("can_dock", false)) else "不满足"
	var dock_state := "已靠泊" if _docked else "未靠泊"
	var current_depth: Dictionary = status.get("current_depth", {})
	var current_depth_text := "未知"
	if bool(current_depth.get("valid", false)):
		current_depth_text = "%.2f m · %s · %s" % [
			float(current_depth.get("depth_m", 0.0)),
			str(current_depth.get("source", "Unknown")),
			str(current_depth.get("quality", "Unknown")),
		]
	else:
		current_depth_text += " · %s" % str(current_depth.get("reason", "No valid data"))
	var sample_lines := PackedStringArray()
	for sample in status.get("berth_depth_samples", []):
		var evaluation: Dictionary = sample.get("evaluation", {})
		var value_text := "%.2f m" % float(evaluation.get("depth_m", 0.0)) if bool(evaluation.get("valid", false)) else "未知"
		var source_text := str(evaluation.get("source", "No valid depth source"))
		var reason_text := " · %s" % str(evaluation.get("reason", "")) if not bool(evaluation.get("valid", false)) else ""
		sample_lines.append("%s：%s · %s · %s%s" % [
			str(sample.get("name", "采样点")), value_text,
			str(evaluation.get("status", NavigationDepthProvider.STATUS_UNKNOWN)), source_text, reason_text,
		])
	var berth_water := "\n".join(sample_lines)
	var cargo_snapshot := _boat.get_cargo_debug_snapshot() if _boat != null else {}
	var model_dimensions: Vector3 = cargo_snapshot.get("model_dimensions_m", Vector3.ZERO)
	var cargo_debug_text := "船型 %s · 模型 %.2f × %.2f × %.2f m (长×宽×高)\n" % [
		str(cargo_snapshot.get("vessel_name", "未配置")),
		float(model_dimensions.x), float(model_dimensions.y), float(model_dimensions.z),
	]
	cargo_debug_text += "货柜 %d · 空间 %d/%d · 载重 %.0f/%.0f kg · 当前计算吃水 %.2f m\n" % [
		int(cargo_snapshot.get("container_count", 0)),
		int(cargo_snapshot.get("used_space_units", 0)),
		int(cargo_snapshot.get("space_capacity_units", 0)),
		float(cargo_snapshot.get("cargo_weight_kg", 0.0)),
		float(cargo_snapshot.get("max_cargo_weight_kg", 0.0)),
		float(cargo_snapshot.get("current_draft_m", -1.0)),
	]
	cargo_debug_text += "载货视觉下沉 %.2f m\n" % float(cargo_snapshot.get("visual_cargo_sink_m", 0.0))
	if _economy_manager != null:
		var economy_snapshot := _economy_manager.get_debug_snapshot()
		cargo_debug_text += "钱包 %s · 进行中合同 %d/%d\n" % [
			str(economy_snapshot.get("wallet_balance_text", "€0.00")),
			int(economy_snapshot.get("active_contract_count", 0)),
			int(economy_snapshot.get("active_contract_limit", 0)),
		]
		for contract_card in _economy_manager.get_active_contracts():
			var contract := contract_card.get("definition") as CargoContractDefinition
			var contract_state: Dictionary = contract_card.get("state", {})
			if contract != null:
				cargo_debug_text += "合同 %s · %s · 货物 ID %s\n" % [
					str(contract.contract_id), str(contract_state.get("status", "")),
					", ".join(PackedStringArray(contract_state.get("cargo_instance_ids", []))),
				]
	var route_summary := ""
	if _route_manager != null and _boat != null and _boat.draft_profile != null:
		route_summary = "\n预设航线 (G 显示)：\n%s\n" % _route_manager.get_debug_summary(_boat.draft_profile.cruise_speed_mps)
	_debug_label.text = (
		"%s Greybox · %s\n" % [_display_name, port_id]
		+ "船位 %.5f°N, %.5f°E · ENU (%.1f, %.1f) m\n" % [gps.x, gps.y, _boat.global_position.x, _boat.global_position.z]
		+ "入口 ENU (%.1f, %.1f) · 泊位中心 ENU (%.1f, %.1f)\n" % [_entrance_position.x, _entrance_position.z, _berth_position.x, _berth_position.z]
		+ "船速 %.2f m/s · 泊位距离 %.1f m\n" % [float(status.get("speed_mps", 0.0)), float(status.get("distance_m", 0.0))]
		+ "方向偏差 %.1f° (容差 %.1f°) · 靠泊条件 %s\n" % [float(status.get("heading_error_degrees", 0.0)), docking_heading_tolerance_degrees, can_dock]
		+ "当前位置水深：%s · 吃水 %.2f m · 安全余量 %.2f m\n" % [current_depth_text, float(status.get("draft_m", -1.0)), _depth_provider.safety_margin_m if _depth_provider != null else 0.0]
		+ cargo_debug_text
		+ route_summary
		+ "泊位水深 %s · %s\n%s\n" % [str(status.get("depth_status", NavigationDepthProvider.STATUS_UNKNOWN)), str(status.get("depth_reason", "Unknown")), berth_water]
		+ "状态 %s · 入口宽 %.0f m · 泊位 %.0f × %.1f m\n" % [dock_state, entrance_width_m, berth_length_m, berth_width_m]
		+ "E 靠泊/离泊 · %s 测试定位 · O 港口标记 · G 航线标记 · F12 货柜测试\n" % ("P" if debug_teleport_action == ACTION_DEBUG_TELEPORT else "K")
	)
	if _dev_delivery_button != null:
		_dev_delivery_button.visible = _debug_enabled and developer_tools_enabled and (OS.has_feature("editor") or OS.has_feature("debug")) and _economy_manager != null and not _economy_manager.get_active_contracts().is_empty()


func _on_dev_delivery_pressed() -> void:
	if not developer_tools_enabled or _economy_manager == null:
		return
	var result := _economy_manager.simulate_first_active_delivery_for_development()
	if not bool(result.get("accepted", false)):
		push_warning("[CargoEconomy] %s" % str(result.get("message", "模拟交货失败")))
	else:
		print("[CargoEconomy] %s" % str(result.get("message", "模拟交货完成")))


func _add_box(node_name: String, center: Vector3, size: Vector3, material: Material, rotation_z: float = 0.0, parent: Node3D = self) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = material
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.position = center
	instance.rotation.z = rotation_z
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(instance)
	return instance


func _add_cylinder(node_name: String, center: Vector3, height: float, top_radius: float, bottom_radius: float, material: Material, radial_segments: int = 12, parent: Node3D = self) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.height = height
	mesh.top_radius = top_radius
	mesh.bottom_radius = bottom_radius
	mesh.radial_segments = radial_segments
	mesh.material = material
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.position = center
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(instance)
	return instance


func _add_sphere(node_name: String, center: Vector3, radius: float, material: Material, parent: Node3D = self) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 12
	mesh.rings = 6
	mesh.material = material
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.position = center
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(instance)
	return instance


func _add_label3d(text_value: String, at: Vector3, color: Color, parent: Node3D = self) -> void:
	var label := Label3D.new()
	label.text = text_value
	label.position = at
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 48
	label.outline_size = 8
	label.modulate = color
	label.no_depth_test = true
	parent.add_child(label)
