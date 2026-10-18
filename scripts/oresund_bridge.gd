class_name OresundBridge
extends Node3D

## GPS-anchored, streamed greybox of the Øresund Bridge.
## All horizontal placement comes from the bundled OSM support/coastline data.
## The existing project has no runtime floating-origin service; call
## reproject_for_georeference_change() after changing the shared GeoReference.

const HIGH_BRIDGE_START_M := 3014.0
const HIGH_BRIDGE_END_M := 4106.0
const SPATIAL_CELL_LENGTH_M := 500.0
const LOWER_DECK_WIDTH_M := 20.0
const LOWER_DECK_THICKNESS_M := 1.2
const ROAD_DECK_SOFFIT_OFFSET_M := 6.8
const ROAD_DECK_TOP_OFFSET_M := 9.2
const LOD_NEAR := 0
const LOD_MID := 1
const LOD_FAR := 2
const LOD_HIDDEN := -1

@export var georeference: GeoReference
@export_file("*.json") var layout_data_path := "res://resources/oresund_bridge_layout.json"
@export_node_path("Node3D") var player_boat_path := NodePath("../PlayerBoat/MotionRoot")
@export_node_path("Node") var wave_sampler_path := NodePath("../WaveSampler")
@export_node_path("Node") var navigation_depth_provider_path := NodePath("../NavigationDepthProvider")
@export_range(500.0, 8000.0, 100.0) var near_lod_radius_m := 3500.0
@export_range(4000.0, 25000.0, 500.0) var mid_lod_radius_m := 15000.0
@export_range(15000.0, 70000.0, 1000.0) var far_lod_radius_m := 45000.0
@export_range(0.1, 2.0, 0.1) var lod_update_interval_seconds := 0.5
@export var developer_tools_enabled := true

@export_category("Optional GLB replacement sockets")
## A replacement scene is anchored to the OSM pylon footprint; the GPS layout
## and collision location stay independent of the model asset.
@export var pylon_visual_scene: PackedScene
@export var pylon_visual_scale := Vector3.ONE
@export var pylon_visual_rotation_degrees := Vector3.ZERO
@export var pier_visual_scene: PackedScene
@export var pier_visual_scale := Vector3.ONE
@export var pier_visual_rotation_degrees := Vector3.ZERO

@onready var _segments_root: Node3D = $BridgeSegments
@onready var _peberholm_root: Node3D = $PeberholmOutline
@onready var _debug_root: Node3D = $DebugMarkers
@onready var _debug_layer: CanvasLayer = $DebugLayer

var _boat: Node3D
var _wave_sampler: Node
var _navigation_depth_provider: Node
var _layout: Dictionary = {}
var _pier_records: Array[Dictionary] = []
var _pylon_records: Array[Dictionary] = []
var _pylon_groups: Array[Dictionary] = []
var _pier_runtime: Array[Dictionary] = []
var _pylon_runtime: Array[Dictionary] = []
var _centerline: Array[Vector3] = []
var _centerline_stations := PackedFloat32Array()
var _cells: Array[Dictionary] = []
var _malmo_approach_cells: Array[Dictionary] = []
var _peberholm_approach_cells: Array[Dictionary] = []
var _malmo_approach_config: Dictionary = {}
var _peberholm_approach_config: Dictionary = {}
var _total_length_m := 0.0
var _malmo_approach_length_m := 0.0
var _malmo_approach_ramp_length_m := 0.0
var _malmo_approach_target_underside_y := 0.0
var _malmo_approach_start_slope := 0.0
var _peberholm_approach_length_m := 0.0
var _peberholm_approach_ramp_length_m := 0.0
var _peberholm_approach_target_underside_y := 0.0
var _peberholm_approach_start_slope := 0.0
var _peberholm_flora_removed_count := 0
var _sea_level_y := 0.0
var _endpoint_extension_m := 0.0
var _near_material: StandardMaterial3D
var _far_material: StandardMaterial3D
var _road_material: StandardMaterial3D
var _rail_material: StandardMaterial3D
var _concrete_material: StandardMaterial3D
var _foundation_material: StandardMaterial3D
var _cable_material: StandardMaterial3D
var _island_outline_material: StandardMaterial3D
var _portal_material: StandardMaterial3D
var _high_span_root: Node3D
var _high_span_lod := LOD_HIDDEN
var _debug_panel: PanelContainer
var _debug_label: Label
var _lod_elapsed := 0.0
var _debug_enabled := false
var _teleport_index := -1
var _last_teleport_name := "未使用"


func _ready() -> void:
	if georeference == null:
		push_error("OresundBridge: GeoReference is required.")
		return
	_boat = get_node_or_null(player_boat_path) as Node3D
	_wave_sampler = get_node_or_null(wave_sampler_path)
	_navigation_depth_provider = get_node_or_null(navigation_depth_provider_path)
	_update_sea_reference()
	_make_materials()
	if not _load_layout():
		return
	_build_centerline()
	_build_support_runtime_data()
	_build_spatial_cells()
	_build_malmo_approach_cells()
	_build_peberholm_approach_cells()
	_build_peberholm_outline()
	_build_debug_markers()
	_build_debug_panel()
	_update_lods()


func _process(delta: float) -> void:
	_lod_elapsed += delta
	if _lod_elapsed >= lod_update_interval_seconds:
		_lod_elapsed = fmod(_lod_elapsed, lod_update_interval_seconds)
		if not is_instance_valid(_boat):
			_boat = get_node_or_null(player_boat_path) as Node3D
		_update_lods()
	if _debug_enabled:
		_update_debug_panel()


func _unhandled_key_input(event: InputEvent) -> void:
	if not developer_tools_enabled or not _developer_tools_available():
		return
	if not event is InputEventKey:
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo or key_event.physical_keycode != KEY_F5:
		return
	if key_event.shift_pressed:
		_teleport_to_next_test_location()
	else:
		_debug_enabled = not _debug_enabled
		_debug_root.visible = _debug_enabled
		_debug_panel.visible = _debug_enabled
		if _debug_enabled:
			_update_debug_panel()
	get_viewport().set_input_as_handled()


## Call this after changing the shared GeoReference (for example in a future
## origin-rebase service). Source coordinates stay WGS84 and are reprojected.
func reproject_for_georeference_change() -> void:
	if georeference == null:
		return
	_update_sea_reference()
	_clear_children(_segments_root)
	_clear_children(_peberholm_root)
	_clear_children(_debug_root)
	_centerline.clear()
	_centerline_stations.clear()
	_cells.clear()
	_malmo_approach_cells.clear()
	_peberholm_approach_cells.clear()
	_malmo_approach_config.clear()
	_peberholm_approach_config.clear()
	_malmo_approach_length_m = 0.0
	_malmo_approach_ramp_length_m = 0.0
	_peberholm_approach_length_m = 0.0
	_peberholm_approach_ramp_length_m = 0.0
	_peberholm_flora_removed_count = 0
	_pier_runtime.clear()
	_pylon_runtime.clear()
	_high_span_root = null
	_high_span_lod = LOD_HIDDEN
	_build_centerline()
	_build_support_runtime_data()
	_build_spatial_cells()
	_build_malmo_approach_cells()
	_build_peberholm_approach_cells()
	_build_peberholm_outline()
	_build_debug_markers()
	_update_lods()


func get_debug_snapshot() -> Dictionary:
	var near_count := 0
	var mid_count := 0
	var far_count := 0
	var hidden_count := 0
	for cell in _cells:
		match int(cell.get("lod", LOD_HIDDEN)):
			LOD_NEAR:
				near_count += 1
			LOD_MID:
				mid_count += 1
			LOD_FAR:
				far_count += 1
			_:
				hidden_count += 1
	var approach_near_count := 0
	var approach_mid_count := 0
	var approach_far_count := 0
	var approach_hidden_count := 0
	for cell in _malmo_approach_cells:
		match int(cell.get("lod", LOD_HIDDEN)):
			LOD_NEAR:
				approach_near_count += 1
			LOD_MID:
				approach_mid_count += 1
			LOD_FAR:
				approach_far_count += 1
			_:
				approach_hidden_count += 1
	var start_geo := georeference.world_to_geodetic(_centerline[0]) if not _centerline.is_empty() else Vector3.ZERO
	var end_geo := georeference.world_to_geodetic(_centerline[-1]) if not _centerline.is_empty() else Vector3.ZERO
	var approach_supports_variant: Variant = _malmo_approach_config.get("supports", [])
	var approach_support_count: int = approach_supports_variant.size() if approach_supports_variant is Array else 0
	var peberholm_approach_near_count := 0
	var peberholm_approach_mid_count := 0
	var peberholm_approach_far_count := 0
	var peberholm_approach_hidden_count := 0
	for cell in _peberholm_approach_cells:
		match int(cell.get("lod", LOD_HIDDEN)):
			LOD_NEAR:
				peberholm_approach_near_count += 1
			LOD_MID:
				peberholm_approach_mid_count += 1
			LOD_FAR:
				peberholm_approach_far_count += 1
			_:
				peberholm_approach_hidden_count += 1
	var peberholm_approach_supports_variant: Variant = _peberholm_approach_config.get("supports", [])
	var peberholm_approach_support_count: int = peberholm_approach_supports_variant.size() if peberholm_approach_supports_variant is Array else 0
	return {
		"bridge_length_m": _total_length_m,
		"navigation_clearance_m": float(_layout.get("official_facts", {}).get("navigation_clearance_m", 57.0)),
		"pylon_count": _pylon_runtime.size(),
		"pier_count": _pier_runtime.size(),
		"near_cells": near_count,
		"mid_cells": mid_count,
		"far_cells": far_count,
		"hidden_cells": hidden_count,
		"malmo_approach_length_m": _malmo_approach_length_m,
		"malmo_approach_ramp_length_m": _malmo_approach_ramp_length_m,
		"malmo_approach_cell_count": _malmo_approach_cells.size(),
		"malmo_approach_support_count": approach_support_count,
		"malmo_approach_near_cells": approach_near_count,
		"malmo_approach_mid_cells": approach_mid_count,
		"malmo_approach_far_cells": approach_far_count,
		"malmo_approach_hidden_cells": approach_hidden_count,
		"peberholm_approach_length_m": _peberholm_approach_length_m,
		"peberholm_approach_ramp_length_m": _peberholm_approach_ramp_length_m,
		"peberholm_approach_target_underside_y": _peberholm_approach_target_underside_y,
		"peberholm_approach_road_surface_y": _peberholm_approach_target_underside_y + ROAD_DECK_TOP_OFFSET_M,
		"peberholm_approach_cell_count": _peberholm_approach_cells.size(),
		"peberholm_approach_support_count": peberholm_approach_support_count,
		"peberholm_approach_near_cells": peberholm_approach_near_count,
		"peberholm_approach_mid_cells": peberholm_approach_mid_count,
		"peberholm_approach_far_cells": peberholm_approach_far_count,
		"peberholm_approach_hidden_cells": peberholm_approach_hidden_count,
		"peberholm_flora_removed_count": _peberholm_flora_removed_count,
		"peberholm_entry_portal_world": _peberholm_approach_position(maxf(_peberholm_approach_length_m - float(_peberholm_approach_config.get("portal_distance_from_end_m", 40.0)), 0.0)) if _peberholm_approach_length_m > 0.0 else Vector3.ZERO,
		"high_span_lod": _lod_name(_high_span_lod),
		"sea_level_y": _sea_level_y,
		"endpoint_extension_m": _endpoint_extension_m,
		"start_latitude_deg": start_geo.x,
		"start_longitude_deg": start_geo.y,
		"end_latitude_deg": end_geo.x,
		"end_longitude_deg": end_geo.y,
		"last_teleport": _last_teleport_name,
	}


func get_navigation_gate_snapshot() -> Dictionary:
	var midpoint_station := (_high_bridge_start_m() + _high_bridge_end_m()) * 0.5
	var gate_center := _position_at_station(midpoint_station)
	var west_center := _group_world_position("main_pylon_west")
	var east_center := _group_world_position("main_pylon_east")
	var vessel_height := 0.0
	if _boat != null and _boat.has_method("get_vessel_dimensions_m"):
		# BoatController returns dimensions as (length, beam, height), not a
		# world-space position vector. Height therefore occupies the z component.
		vessel_height = float((_boat.call("get_vessel_dimensions_m") as Vector3).z)
	var clearance := float(_layout.get("official_facts", {}).get("navigation_clearance_m", 57.0))
	return {
		"center": gate_center,
		"west_pylon_group": west_center,
		"east_pylon_group": east_center,
		"pylon_group_separation_m": _horizontal_distance(west_center, east_center),
		"clearance_m": clearance,
		"vessel_height_m": vessel_height,
		"nominal_vertical_clearance_margin_m": clearance - vessel_height,
		"osm_pier_count_inside_free_span": _count_piers_between_pylon_groups(),
	}


func _load_layout() -> bool:
	if not FileAccess.file_exists(layout_data_path):
		push_error("OresundBridge: layout data file not found: %s" % layout_data_path)
		return false
	var file := FileAccess.open(layout_data_path, FileAccess.READ)
	if file == null:
		push_error("OresundBridge: could not read layout data: %s" % layout_data_path)
		return false
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary or int(parsed.get("schema_version", -1)) != 1:
		push_error("OresundBridge: invalid layout schema.")
		return false
	_layout = parsed
	for item in _layout.get("piers", []):
		if item is Dictionary:
			_pier_records.append(item)
	for item in _layout.get("pylons", []):
		if item is Dictionary:
			_pylon_records.append(item)
	for item in _layout.get("pylon_groups", []):
		if item is Dictionary:
			_pylon_groups.append(item)
	if _pier_records.is_empty() or _pylon_records.size() != 4 or _pylon_groups.size() != 2:
		push_error("OresundBridge: layout data is missing OSM support geometry.")
		return false
	return true


func _update_sea_reference() -> void:
	_sea_level_y = 0.0
	if _wave_sampler != null and _wave_sampler.has_method("get_mean_water_height"):
		_sea_level_y = float(_wave_sampler.call("get_mean_water_height"))


func _make_materials() -> void:
	_near_material = _make_material(Color("#879095"))
	_far_material = _make_material(Color("#788187"))
	_road_material = _make_material(Color("#4c555b"))
	_rail_material = _make_material(Color("#3e464b"))
	_concrete_material = _make_material(Color("#a7aaab"))
	_foundation_material = _make_material(Color("#727a7d"))
	_cable_material = _make_material(Color("#777f83"))
	_island_outline_material = _make_material(Color("#a59f8d"), true)
	_portal_material = _make_material(Color("#20282d"), true)


func _make_material(color: Color, unshaded: bool = false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.92
	if unshaded:
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return material


func _build_centerline() -> void:
	var core: Array[Vector3] = []
	for anchor in _layout.get("centerline_anchors", []):
		if not anchor is Dictionary:
			continue
		var point := georeference.geodetic_to_world(float(anchor.get("latitude", 0.0)), float(anchor.get("longitude", 0.0)))
		point.y = _sea_level_y
		core.append(point)
	if core.size() < 3:
		push_error("OresundBridge: centerline requires at least three OSM anchors.")
		return
	var core_length := 0.0
	for index in range(core.size() - 1):
		core_length += _horizontal_distance(core[index], core[index + 1])
	var target_length := float(_layout.get("official_facts", {}).get("bridge_length_m", 7845.0))
	_endpoint_extension_m = maxf(0.0, (target_length - core_length) * 0.5)
	var first_direction := _horizontal_direction(core[0], core[1])
	var last_direction := _horizontal_direction(core[-2], core[-1])
	_centerline.append(core[0] - first_direction * _endpoint_extension_m)
	for point in core:
		_centerline.append(point)
	_centerline.append(core[-1] + last_direction * _endpoint_extension_m)
	_centerline_stations.append(0.0)
	_total_length_m = 0.0
	for index in range(_centerline.size() - 1):
		_total_length_m += _horizontal_distance(_centerline[index], _centerline[index + 1])
		_centerline_stations.append(_total_length_m)
	if absf(_total_length_m - target_length) > 2.0:
		push_warning("OresundBridge: projected OSM alignment differs from official bridge length by %.1f m." % (_total_length_m - target_length))


func _build_support_runtime_data() -> void:
	for record in _pier_records:
		var position := _geo_position(record)
		var projection := _project_to_centerline(position)
		var tangent := _tangent_at_station(float(projection.get("station_m", 0.0)))
		var dimensions := _support_footprint_dimensions(record, position, tangent, Vector2(11.0, 8.0))
		_pier_runtime.append({
			"record": record,
			"position": position,
			"station_m": float(projection.get("station_m", 0.0)),
			"width_m": dimensions.x,
			"length_m": dimensions.y,
			"tangent": tangent,
		})
	for record in _pylon_records:
		var position := _geo_position(record)
		var projection := _project_to_centerline(position)
		var tangent := _tangent_at_station(float(projection.get("station_m", 0.0)))
		var dimensions := _support_footprint_dimensions(record, position, tangent, Vector2(12.0, 10.0))
		_pylon_runtime.append({
			"record": record,
			"position": position,
			"station_m": float(projection.get("station_m", 0.0)),
			"width_m": dimensions.x,
			"length_m": dimensions.y,
			"tangent": tangent,
	})


func _geo_position(record: Dictionary) -> Vector3:
	var position := georeference.geodetic_to_world(float(record.get("latitude", 0.0)), float(record.get("longitude", 0.0)))
	position.y = _sea_level_y
	return position


func _support_footprint_dimensions(record: Dictionary, center: Vector3, tangent: Vector3, fallback: Vector2) -> Vector2:
	var footprint: Variant = record.get("footprint_lat_lon", [])
	if not footprint is Array or footprint.is_empty():
		return fallback
	var right := Vector3.UP.cross(tangent).normalized()
	var across_min := INF
	var across_max := -INF
	var along_min := INF
	var along_max := -INF
	for coordinate in footprint:
		if not coordinate is Array or coordinate.size() < 2:
			continue
		var point := georeference.geodetic_to_world(float(coordinate[0]), float(coordinate[1]))
		var offset := Vector3(point.x - center.x, 0.0, point.z - center.z)
		var across := offset.dot(right)
		var along := offset.dot(tangent)
		across_min = minf(across_min, across)
		across_max = maxf(across_max, across)
		along_min = minf(along_min, along)
		along_max = maxf(along_max, along)
	if not is_finite(across_min) or not is_finite(along_min):
		return fallback
	return Vector2(maxf(across_max - across_min, 4.0), maxf(along_max - along_min, 4.0))


func _build_spatial_cells() -> void:
	var cell_count := ceili(_total_length_m / SPATIAL_CELL_LENGTH_M)
	for index in range(cell_count):
		var station_start := float(index) * SPATIAL_CELL_LENGTH_M
		var station_end := minf(station_start + SPATIAL_CELL_LENGTH_M, _total_length_m)
		var cell_node := Node3D.new()
		cell_node.name = "BridgeCell_%02d" % index
		_segments_root.add_child(cell_node)
		_cells.append({
			"node": cell_node,
			"start_m": station_start,
			"end_m": station_end,
			"lod": LOD_HIDDEN,
			"runtime_root": null,
		})
	_high_span_root = Node3D.new()
	_high_span_root.name = "HighBridgeCore"
	_segments_root.add_child(_high_span_root)


func _build_malmo_approach_cells() -> void:
	var config_variant: Variant = _layout.get("malmo_visible_approach", {})
	if not config_variant is Dictionary or config_variant.is_empty():
		return
	_malmo_approach_config = config_variant
	_malmo_approach_length_m = maxf(float(_malmo_approach_config.get("length_m", 0.0)), 0.0)
	_malmo_approach_ramp_length_m = clampf(
		float(_malmo_approach_config.get("ramp_length_m", _malmo_approach_length_m)),
		0.0,
		_malmo_approach_length_m
	)
	if _malmo_approach_length_m <= 0.0 or _malmo_approach_ramp_length_m <= 0.0:
		push_warning("OresundBridge: Malmö visual approach has invalid length data; skipping it.")
		_malmo_approach_config.clear()
		_malmo_approach_length_m = 0.0
		_malmo_approach_ramp_length_m = 0.0
		return
	var road_surface_height := float(_malmo_approach_config.get("target_road_surface_above_water_m", 0.0))
	_malmo_approach_target_underside_y = _sea_level_y + road_surface_height - ROAD_DECK_TOP_OFFSET_M
	var assumptions: Dictionary = _layout.get("graybox_assumptions", {})
	var clearance := float(_layout.get("official_facts", {}).get("navigation_clearance_m", 57.0))
	var low_at_east := float(assumptions.get("approach_end_underside_above_water_m", 10.0))
	var east_length := maxf(_total_length_m - _high_bridge_end_m(), 1.0)
	_malmo_approach_start_slope = (low_at_east - clearance) / east_length
	var cell_count := ceili(_malmo_approach_length_m / SPATIAL_CELL_LENGTH_M)
	for index in range(cell_count):
		var station_start := float(index) * SPATIAL_CELL_LENGTH_M
		var station_end := minf(station_start + SPATIAL_CELL_LENGTH_M, _malmo_approach_length_m)
		var cell_node := Node3D.new()
		cell_node.name = "MalmoVisualApproachCell_%02d" % index
		_segments_root.add_child(cell_node)
		_malmo_approach_cells.append({
			"node": cell_node,
			"start_m": station_start,
			"end_m": station_end,
			"lod": LOD_HIDDEN,
			"runtime_root": null,
		})


func _build_peberholm_approach_cells() -> void:
	var config_variant: Variant = _layout.get("peberholm_visible_approach", {})
	if not config_variant is Dictionary or config_variant.is_empty():
		return
	_peberholm_approach_config = config_variant
	_peberholm_approach_length_m = maxf(float(_peberholm_approach_config.get("length_m", 0.0)), 0.0)
	_peberholm_approach_ramp_length_m = clampf(
		float(_peberholm_approach_config.get("ramp_length_m", _peberholm_approach_length_m)),
		0.0,
		_peberholm_approach_length_m
	)
	if _peberholm_approach_length_m <= 0.0 or _peberholm_approach_ramp_length_m <= 0.0:
		push_warning("OresundBridge: Peberholm visual approach has invalid length data; skipping it.")
		_peberholm_approach_config.clear()
		_peberholm_approach_length_m = 0.0
		_peberholm_approach_ramp_length_m = 0.0
		return
	var road_surface_height := float(_peberholm_approach_config.get("target_road_surface_above_water_m", 3.1))
	_peberholm_approach_target_underside_y = _sea_level_y + road_surface_height - ROAD_DECK_TOP_OFFSET_M
	var assumptions: Dictionary = _layout.get("graybox_assumptions", {})
	var clearance := float(_layout.get("official_facts", {}).get("navigation_clearance_m", 57.0))
	var approach_start_underside := float(assumptions.get("approach_start_underside_above_water_m", 10.0))
	_peberholm_approach_start_slope = -(clearance - approach_start_underside) / maxf(_high_bridge_start_m(), 1.0)
	var cell_count := ceili(_peberholm_approach_length_m / SPATIAL_CELL_LENGTH_M)
	for index in range(cell_count):
		var distance_start := float(index) * SPATIAL_CELL_LENGTH_M
		var distance_end := minf(distance_start + SPATIAL_CELL_LENGTH_M, _peberholm_approach_length_m)
		var cell_node := Node3D.new()
		cell_node.name = "PeberholmVisibleApproachCell_%02d" % index
		_segments_root.add_child(cell_node)
		_peberholm_approach_cells.append({
			"node": cell_node,
			"start_m": distance_start,
			"end_m": distance_end,
			"lod": LOD_HIDDEN,
			"runtime_root": null,
		})
	_apply_peberholm_flora_clearance()


func _apply_peberholm_flora_clearance() -> void:
	var flora := get_node_or_null("../OresundRegion/PeberholmLowVegetation")
	if flora == null or not flora.has_method("remove_corridor_instances"):
		return
	var start := _peberholm_approach_position(0.0)
	var finish := _peberholm_approach_position(_peberholm_approach_length_m)
	_peberholm_flora_removed_count = int(flora.call("remove_corridor_instances", start, finish, 18.0))


func _build_peberholm_outline() -> void:
	var island: Dictionary = _layout.get("peberholm", {})
	var coordinates: Variant = island.get("outline_lat_lon", [])
	if not coordinates is Array or coordinates.size() < 3:
		return
	var line_mesh := ImmediateMesh.new()
	line_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, _island_outline_material)
	for coordinate in coordinates:
		if not coordinate is Array or coordinate.size() < 2:
			continue
		var point := georeference.geodetic_to_world(float(coordinate[0]), float(coordinate[1]))
		point.y = _sea_level_y + 1.0
		line_mesh.surface_add_vertex(point)
	if coordinates[0] is Array and coordinates[0].size() >= 2:
		var first := georeference.geodetic_to_world(float(coordinates[0][0]), float(coordinates[0][1]))
		first.y = _sea_level_y + 1.0
		line_mesh.surface_add_vertex(first)
	line_mesh.surface_end()
	var outline := MeshInstance3D.new()
	outline.name = "Peberholm_OSM_Coastline_Outline"
	outline.mesh = line_mesh
	# Survey overlay, not part of the bridge or island. F3 island diagnosis
	# enables it explicitly; do not draw this Y=+1m line through normal water.
	outline.visible = false
	_peberholm_root.add_child(outline)


func _build_debug_markers() -> void:
	var debug_material := _make_material(Color("#ffd27a"), true)
	var gate := _position_at_station((_high_bridge_start_m() + _high_bridge_end_m()) * 0.5)
	_add_debug_marker("NavigationGate", gate + Vector3.UP * 1.5, "主航道 · 57 m", debug_material, 2.0)
	for group in _pylon_groups:
		var name := str(group.get("group_id", "Pylon"))
		var position := _group_world_position(name)
		_add_debug_marker(name, position + Vector3.UP * 2.0, name, debug_material, 2.2)
	if not _centerline.is_empty():
		_add_debug_marker("PeberholmEndpoint", _centerline[0] + Vector3.UP * 2.0, "Peberholm 端", debug_material, 1.5)
		_add_debug_marker("SwedenEndpoint", _centerline[-1] + Vector3.UP * 2.0, "Lernacken 端", debug_material, 1.5)
		if _peberholm_approach_length_m > 0.0:
			var portal_distance := maxf(_peberholm_approach_length_m - float(_peberholm_approach_config.get("portal_distance_from_end_m", 40.0)), 0.0)
			_add_debug_marker("PeberholmGroundEntry", _peberholm_approach_position(portal_distance) + Vector3.UP * 2.0, "Peberholm 地面入口", debug_material, 1.5)
	_debug_root.visible = _debug_enabled


func _add_debug_marker(marker_name: String, position: Vector3, text: String, material: StandardMaterial3D, radius: float) -> void:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = marker_name
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	mesh_instance.mesh = sphere
	mesh_instance.material_override = material
	mesh_instance.position = position
	_debug_root.add_child(mesh_instance)
	var label := Label3D.new()
	label.name = "%s_Label" % marker_name
	label.text = text
	label.position = position + Vector3.UP * (radius + 2.0)
	label.font_size = 48
	label.outline_size = 8
	label.modulate = Color("#ffe0a5")
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_debug_root.add_child(label)


func _build_debug_panel() -> void:
	_debug_panel = PanelContainer.new()
	_debug_panel.name = "BridgeDebugPanel"
	_debug_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_debug_panel.position = Vector2(18.0, 90.0)
	_debug_panel.custom_minimum_size = Vector2(470.0, 0.0)
	_debug_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_debug_panel.add_theme_stylebox_override("panel", _make_debug_style())
	_debug_layer.add_child(_debug_panel)
	_debug_label = Label.new()
	_debug_label.add_theme_color_override("font_color", Color("#e4efed"))
	_debug_label.add_theme_font_size_override("font_size", 15)
	_debug_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_debug_panel.add_child(_debug_label)
	_debug_panel.visible = false


func _make_debug_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.015, 0.055, 0.07, 0.9)
	style.set_corner_radius_all(8)
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 10.0
	style.content_margin_bottom = 10.0
	return style


func _update_lods() -> void:
	if _boat == null or _centerline.is_empty():
		return
	var boat_position := _boat.global_position
	for index in range(_cells.size()):
		var cell: Dictionary = _cells[index]
		var distance := _distance_to_station_range(boat_position, float(cell["start_m"]), float(cell["end_m"]))
		var lod := _lod_for_distance(distance)
		if lod != int(cell.get("lod", LOD_HIDDEN)):
			_set_cell_lod(index, lod)
	for index in range(_malmo_approach_cells.size()):
		var cell: Dictionary = _malmo_approach_cells[index]
		var distance := _distance_to_malmo_approach_range(boat_position, float(cell["start_m"]), float(cell["end_m"]))
		var lod := _lod_for_distance(distance)
		if lod != int(cell.get("lod", LOD_HIDDEN)):
			_set_malmo_approach_cell_lod(index, lod)
	for index in range(_peberholm_approach_cells.size()):
		var cell: Dictionary = _peberholm_approach_cells[index]
		var distance := _distance_to_peberholm_approach_range(boat_position, float(cell["start_m"]), float(cell["end_m"]))
		var lod := _lod_for_distance(distance)
		if lod != int(cell.get("lod", LOD_HIDDEN)):
			_set_peberholm_approach_cell_lod(index, lod)
	var high_distance := _distance_to_station_range(boat_position, _high_bridge_start_m(), _high_bridge_end_m())
	var high_lod := _lod_for_distance(high_distance)
	if high_lod != _high_span_lod:
		_set_high_span_lod(high_lod)


func _set_malmo_approach_cell_lod(index: int, lod: int) -> void:
	var cell: Dictionary = _malmo_approach_cells[index]
	var previous: Variant = cell.get("runtime_root")
	if previous is Node and is_instance_valid(previous):
		previous.queue_free()
	cell["runtime_root"] = null
	cell["lod"] = lod
	if lod != LOD_HIDDEN:
		var root := Node3D.new()
		root.name = "LOD_%s" % _lod_name(lod)
		(cell["node"] as Node3D).add_child(root)
		cell["runtime_root"] = root
		_build_malmo_approach_cell_visual(root, float(cell["start_m"]), float(cell["end_m"]), lod)
	_malmo_approach_cells[index] = cell


func _set_peberholm_approach_cell_lod(index: int, lod: int) -> void:
	var cell: Dictionary = _peberholm_approach_cells[index]
	var previous: Variant = cell.get("runtime_root")
	if previous is Node and is_instance_valid(previous):
		previous.queue_free()
	cell["runtime_root"] = null
	cell["lod"] = lod
	if lod != LOD_HIDDEN:
		var root := Node3D.new()
		root.name = "LOD_%s" % _lod_name(lod)
		(cell["node"] as Node3D).add_child(root)
		cell["runtime_root"] = root
		_build_peberholm_approach_cell_visual(root, float(cell["start_m"]), float(cell["end_m"]), lod)
	_peberholm_approach_cells[index] = cell


func _lod_for_distance(distance: float) -> int:
	if distance <= near_lod_radius_m:
		return LOD_NEAR
	if distance <= mid_lod_radius_m:
		return LOD_MID
	if distance <= far_lod_radius_m:
		return LOD_FAR
	return LOD_HIDDEN


func _set_cell_lod(index: int, lod: int) -> void:
	var cell: Dictionary = _cells[index]
	var previous: Variant = cell.get("runtime_root")
	if previous is Node and is_instance_valid(previous):
		previous.queue_free()
	cell["runtime_root"] = null
	cell["lod"] = lod
	if lod != LOD_HIDDEN:
		var root := Node3D.new()
		root.name = "LOD_%s" % _lod_name(lod)
		(cell["node"] as Node3D).add_child(root)
		cell["runtime_root"] = root
		_build_cell_visual(root, float(cell["start_m"]), float(cell["end_m"]), lod)
	_cells[index] = cell


func _build_cell_visual(root: Node3D, station_start: float, station_end: float, lod: int) -> void:
	var spacing := 42.0 if lod == LOD_NEAR else (105.0 if lod == LOD_MID else 260.0)
	var station := station_start
	var support_index := 0
	while station < station_end - 0.01:
		var next_station := minf(station + spacing, station_end)
		var start := _position_at_station(station)
		var finish := _position_at_station(next_station)
		var underside_start := _underside_height_at_station(station)
		var underside_end := _underside_height_at_station(next_station)
		var lower_start := Vector3(start.x, underside_start + LOWER_DECK_THICKNESS_M * 0.5, start.z)
		var lower_end := Vector3(finish.x, underside_end + LOWER_DECK_THICKNESS_M * 0.5, finish.z)
		var upper_start := Vector3(start.x, underside_start + 8.0, start.z)
		var upper_end := Vector3(finish.x, underside_end + 8.0, finish.z)
		var lower_material := _rail_material if lod == LOD_FAR else _near_material
		_add_box_segment(root, lower_start, lower_end, LOWER_DECK_WIDTH_M, LOWER_DECK_THICKNESS_M, lower_material, "LowerDeck", lod == LOD_NEAR)
		_add_box_segment(root, upper_start, upper_end, 24.0, 2.4, _road_material, "RoadDeck", lod == LOD_NEAR)
		if lod == LOD_NEAR:
			var tangent := _horizontal_direction(start, finish)
			var right := Vector3.UP.cross(tangent).normalized()
			_add_box_segment(root, upper_start + right * 11.4 + Vector3.UP * 1.4, upper_end + right * 11.4 + Vector3.UP * 1.4, 0.35, 1.2, _foundation_material, "RoadGuard", false)
			_add_box_segment(root, upper_start - right * 11.4 + Vector3.UP * 1.4, upper_end - right * 11.4 + Vector3.UP * 1.4, 0.35, 1.2, _foundation_material, "RoadGuard", false)
		if lod != LOD_FAR:
			for pier in _pier_runtime:
				var pier_station := float(pier["station_m"])
				if pier_station >= station and pier_station < next_station and (lod == LOD_NEAR or support_index % 2 == 0):
					_add_pier(root, pier, lod == LOD_NEAR)
					support_index += 1
		station = next_station
	_build_interlayer_supports(root, station_start, station_end, lod)


func _build_malmo_approach_cell_visual(root: Node3D, distance_start: float, distance_end: float, lod: int) -> void:
	var spacing := 42.0 if lod == LOD_NEAR else (105.0 if lod == LOD_MID else 260.0)
	var distance := distance_start
	while distance < distance_end - 0.01:
		var next_distance := minf(distance + spacing, distance_end)
		var start := _malmo_approach_position(distance)
		var finish := _malmo_approach_position(next_distance)
		var underside_start := _malmo_approach_underside_height(distance)
		var underside_end := _malmo_approach_underside_height(next_distance)
		var lower_start := Vector3(start.x, underside_start + LOWER_DECK_THICKNESS_M * 0.5, start.z)
		var lower_end := Vector3(finish.x, underside_end + LOWER_DECK_THICKNESS_M * 0.5, finish.z)
		var upper_start := Vector3(start.x, underside_start + 8.0, start.z)
		var upper_end := Vector3(finish.x, underside_end + 8.0, finish.z)
		var lower_material := _rail_material if lod == LOD_FAR else _near_material
		_add_box_segment(root, lower_start, lower_end, LOWER_DECK_WIDTH_M, LOWER_DECK_THICKNESS_M, lower_material, "MalmoApproachLowerDeck", lod == LOD_NEAR)
		_add_box_segment(root, upper_start, upper_end, 24.0, 2.4, _road_material, "MalmoApproachRoadDeck", lod == LOD_NEAR)
		if lod == LOD_NEAR:
			var tangent := _horizontal_direction(start, finish)
			var right := Vector3.UP.cross(tangent).normalized()
			_add_box_segment(root, upper_start + right * 11.4 + Vector3.UP * 1.4, upper_end + right * 11.4 + Vector3.UP * 1.4, 0.35, 1.2, _foundation_material, "MalmoApproachRoadGuard", false)
			_add_box_segment(root, upper_start - right * 11.4 + Vector3.UP * 1.4, upper_end - right * 11.4 + Vector3.UP * 1.4, 0.35, 1.2, _foundation_material, "MalmoApproachRoadGuard", false)
		distance = next_distance
	_build_malmo_approach_interlayer_supports(root, distance_start, distance_end, lod)
	_build_malmo_approach_piers(root, distance_start, distance_end, lod)
	var ramp_end := _malmo_approach_ramp_length_m
	if ramp_end >= distance_start and ramp_end <= distance_end:
		_add_malmo_approach_land_abutment(root, ramp_end)


func _build_peberholm_approach_cell_visual(root: Node3D, distance_start: float, distance_end: float, lod: int) -> void:
	var spacing := 42.0 if lod == LOD_NEAR else (105.0 if lod == LOD_MID else 260.0)
	var distance := distance_start
	while distance < distance_end - 0.01:
		var next_distance := minf(distance + spacing, distance_end)
		var start := _peberholm_approach_position(distance)
		var finish := _peberholm_approach_position(next_distance)
		var underside_start := _peberholm_approach_underside_height(distance)
		var underside_end := _peberholm_approach_underside_height(next_distance)
		var lower_start := Vector3(start.x, underside_start + LOWER_DECK_THICKNESS_M * 0.5, start.z)
		var lower_end := Vector3(finish.x, underside_end + LOWER_DECK_THICKNESS_M * 0.5, finish.z)
		var upper_start := Vector3(start.x, underside_start + 8.0, start.z)
		var upper_end := Vector3(finish.x, underside_end + 8.0, finish.z)
		var lower_material := _rail_material if lod == LOD_FAR else _near_material
		_add_box_segment(root, lower_start, lower_end, LOWER_DECK_WIDTH_M, LOWER_DECK_THICKNESS_M, lower_material, "PeberholmApproachLowerDeck", lod == LOD_NEAR)
		_add_box_segment(root, upper_start, upper_end, 24.0, 2.4, _road_material, "PeberholmApproachRoadDeck", lod == LOD_NEAR)
		if lod == LOD_NEAR and minf(underside_start + ROAD_DECK_TOP_OFFSET_M, underside_end + ROAD_DECK_TOP_OFFSET_M) > 5.0:
			var tangent := _horizontal_direction(start, finish)
			var right := Vector3.UP.cross(tangent).normalized()
			_add_box_segment(root, upper_start + right * 11.4 + Vector3.UP * 1.4, upper_end + right * 11.4 + Vector3.UP * 1.4, 0.35, 1.2, _foundation_material, "PeberholmApproachRoadGuard", false)
			_add_box_segment(root, upper_start - right * 11.4 + Vector3.UP * 1.4, upper_end - right * 11.4 + Vector3.UP * 1.4, 0.35, 1.2, _foundation_material, "PeberholmApproachRoadGuard", false)
		distance = next_distance
	_build_peberholm_approach_interlayer_supports(root, distance_start, distance_end, lod)
	_build_peberholm_approach_piers(root, distance_start, distance_end, lod)
	var portal_distance := maxf(_peberholm_approach_length_m - float(_peberholm_approach_config.get("portal_distance_from_end_m", 40.0)), 0.0)
	if portal_distance >= distance_start - 0.01 and portal_distance < distance_end + 0.01:
		_add_peberholm_ground_entry_portal(root, portal_distance)


func _build_peberholm_approach_interlayer_supports(parent: Node3D, distance_start: float, distance_end: float, lod: int) -> void:
	var support_spacing := 126.0 if lod == LOD_NEAR else (252.0 if lod == LOD_MID else SPATIAL_CELL_LENGTH_M)
	var beam_spacing := 105.0 if lod == LOD_NEAR else (210.0 if lod == LOD_MID else SPATIAL_CELL_LENGTH_M)
	var side_offset := LOWER_DECK_WIDTH_M * 0.5 - 0.7
	var beam_distance := distance_start
	while beam_distance < distance_end - 0.01:
		var next_beam_distance := minf(beam_distance + beam_spacing, distance_end)
		var start := _peberholm_approach_position(beam_distance)
		var finish := _peberholm_approach_position(next_beam_distance)
		var right := Vector3.UP.cross(_peberholm_approach_tangent()).normalized()
		for side_sign in [-1.0, 1.0]:
			var side := float(side_sign) * side_offset
			var lower_start := Vector3(start.x, _peberholm_approach_underside_height(beam_distance) + LOWER_DECK_THICKNESS_M, start.z) + right * side
			var lower_end := Vector3(finish.x, _peberholm_approach_underside_height(next_beam_distance) + LOWER_DECK_THICKNESS_M, finish.z) + right * side
			var upper_start := Vector3(start.x, _peberholm_approach_underside_height(beam_distance) + ROAD_DECK_SOFFIT_OFFSET_M, start.z) + right * side
			var upper_end := Vector3(finish.x, _peberholm_approach_underside_height(next_beam_distance) + ROAD_DECK_SOFFIT_OFFSET_M, finish.z) + right * side
			_add_box_segment(parent, lower_start, lower_end, 0.45, 0.45, _foundation_material, "PeberholmApproachLowerBeam", false)
			_add_box_segment(parent, upper_start, upper_end, 0.45, 0.45, _foundation_material, "PeberholmApproachRoadBeam", false)
		beam_distance = next_beam_distance
	var support_distance := ceilf(distance_start / support_spacing) * support_spacing
	while support_distance < distance_end - 0.01:
		var position := _peberholm_approach_position(support_distance)
		var lower_top := _peberholm_approach_underside_height(support_distance) + LOWER_DECK_THICKNESS_M
		var road_bottom := _peberholm_approach_underside_height(support_distance) + ROAD_DECK_SOFFIT_OFFSET_M
		var post_height := road_bottom - lower_top
		if post_height > 0.1:
			var yaw := float(_peberholm_approach_tangent().signed_angle_to(Vector3.FORWARD, Vector3.UP))
			for side_sign in [-1.0, 1.0]:
				var post_position := Vector3(position.x, (lower_top + road_bottom) * 0.5, position.z) + Vector3.UP.cross(_peberholm_approach_tangent()).normalized() * float(side_sign) * side_offset
				_add_oriented_box(parent, "PeberholmApproachInterlayerSupport", post_position, Vector3(0.45, post_height, 0.45), yaw, _foundation_material, false)
		support_distance += support_spacing


func _build_peberholm_approach_piers(parent: Node3D, distance_start: float, distance_end: float, lod: int) -> void:
	if lod == LOD_FAR:
		return
	var supports_variant: Variant = _peberholm_approach_config.get("supports", [])
	if not supports_variant is Array:
		return
	for support_variant in supports_variant:
		if not support_variant is Dictionary:
			continue
		var support: Dictionary = support_variant
		var station := float(support.get("station_m", -1.0))
		if station < distance_start - 0.01 or station >= distance_end - 0.01:
			continue
		_add_peberholm_approach_pier(parent, station, float(support.get("ground_height_above_water_m", 0.0)), lod == LOD_NEAR)


func _add_peberholm_approach_pier(parent: Node3D, distance: float, ground_height_above_water: float, with_collision: bool) -> void:
	var deck_bottom := _peberholm_approach_underside_height(distance)
	var ground_y := _sea_level_y + ground_height_above_water
	var height := deck_bottom - ground_y
	if height < 0.2:
		return
	var center := _peberholm_approach_position(distance)
	var yaw := float(_peberholm_approach_tangent().signed_angle_to(Vector3.FORWARD, Vector3.UP))
	var support_suffix := "%04dm" % roundi(distance)
	var pier_size := Vector3(11.0, height, 8.0)
	_add_oriented_box(parent, "PeberholmApproachShorePier_%s" % support_suffix, Vector3(center.x, (deck_bottom + ground_y) * 0.5, center.z), pier_size, yaw, _concrete_material, false)
	_add_oriented_box(parent, "PeberholmApproachShorePierFooting_%s" % support_suffix, Vector3(center.x, ground_y - 1.5, center.z), Vector3(18.0, 3.0, 15.0), yaw, _foundation_material, false)
	if with_collision:
		var body := StaticBody3D.new()
		body.name = "PeberholmApproachShorePier_%s_Collision" % support_suffix
		body.position = Vector3(center.x, (deck_bottom + ground_y) * 0.5, center.z)
		body.rotation.y = yaw
		parent.add_child(body)
		var collider := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = pier_size
		collider.shape = shape
		body.add_child(collider)


func _add_peberholm_ground_entry_portal(parent: Node3D, portal_distance: float) -> void:
	var center := _peberholm_approach_position(portal_distance)
	var tangent := _peberholm_approach_tangent()
	var yaw := float(tangent.signed_angle_to(Vector3.FORWARD, Vector3.UP))
	var road_top := _peberholm_approach_target_underside_y + ROAD_DECK_TOP_OFFSET_M
	var opening_height := 5.7
	var opening_center_y := road_top + opening_height * 0.5
	var side_offset := 13.8
	for side_sign in [-1.0, 1.0]:
		_add_oriented_box(parent, "PeberholmGroundEntryPortalJamb", Vector3(center.x, opening_center_y, center.z) + Vector3.UP.cross(tangent).normalized() * float(side_sign) * side_offset, Vector3(2.8, opening_height, 3.2), yaw, _concrete_material, false)
	_add_oriented_box(parent, "PeberholmGroundEntryPortalHeader", Vector3(center.x, road_top + opening_height + 1.1, center.z), Vector3(30.4, 2.2, 3.2), yaw, _concrete_material, false)
	var dark_center := _peberholm_approach_position(portal_distance + 2.0)
	_add_oriented_box(parent, "PeberholmGroundEntryPortalMouth", Vector3(dark_center.x, opening_center_y, dark_center.z), Vector3(24.0, opening_height, 0.25), yaw, _portal_material, false)
	var wing_start_distance := maxf(portal_distance - float(_peberholm_approach_config.get("retaining_wall_length_m", 180.0)), 0.0)
	var wing_start := _peberholm_approach_position(wing_start_distance)
	var wing_end := _peberholm_approach_position(portal_distance)
	var right := Vector3.UP.cross(tangent).normalized()
	var wall_center_y := _sea_level_y + float(_peberholm_approach_config.get("terminal_ground_height_above_water_m", 3.0)) + 1.5
	for side_sign in [-1.0, 1.0]:
		var wing_offset := right * float(side_sign) * 16.5
		_add_box_segment(
			parent,
			Vector3(wing_start.x, wall_center_y, wing_start.z) + wing_offset,
			Vector3(wing_end.x, wall_center_y, wing_end.z) + wing_offset,
			1.6,
			3.0,
			_foundation_material,
			"PeberholmGroundEntryRetainingWing",
			false
		)


func _build_malmo_approach_interlayer_supports(parent: Node3D, distance_start: float, distance_end: float, lod: int) -> void:
	var support_spacing := 126.0 if lod == LOD_NEAR else (252.0 if lod == LOD_MID else SPATIAL_CELL_LENGTH_M)
	var beam_spacing := 105.0 if lod == LOD_NEAR else (210.0 if lod == LOD_MID else SPATIAL_CELL_LENGTH_M)
	var side_offset := LOWER_DECK_WIDTH_M * 0.5 - 0.7
	var beam_distance := distance_start
	while beam_distance < distance_end - 0.01:
		var next_beam_distance := minf(beam_distance + beam_spacing, distance_end)
		var start := _malmo_approach_position(beam_distance)
		var finish := _malmo_approach_position(next_beam_distance)
		var tangent := _horizontal_direction(start, finish)
		var right := Vector3.UP.cross(tangent).normalized()
		for side_sign in [-1.0, 1.0]:
			var side := float(side_sign) * side_offset
			var lower_start := Vector3(start.x, _malmo_approach_underside_height(beam_distance) + LOWER_DECK_THICKNESS_M, start.z) + right * side
			var lower_end := Vector3(finish.x, _malmo_approach_underside_height(next_beam_distance) + LOWER_DECK_THICKNESS_M, finish.z) + right * side
			var upper_start := Vector3(start.x, _malmo_approach_underside_height(beam_distance) + ROAD_DECK_SOFFIT_OFFSET_M, start.z) + right * side
			var upper_end := Vector3(finish.x, _malmo_approach_underside_height(next_beam_distance) + ROAD_DECK_SOFFIT_OFFSET_M, finish.z) + right * side
			_add_box_segment(parent, lower_start, lower_end, 0.45, 0.45, _foundation_material, "MalmoApproachLowerLongitudinalBeam", false)
			_add_box_segment(parent, upper_start, upper_end, 0.45, 0.45, _foundation_material, "MalmoApproachRoadLongitudinalBeam", false)
		beam_distance = next_beam_distance
	var support_distance := ceilf(distance_start / support_spacing) * support_spacing
	while support_distance < distance_end - 0.01:
		var position := _malmo_approach_position(support_distance)
		var tangent := _malmo_approach_tangent()
		var right := Vector3.UP.cross(tangent).normalized()
		var lower_top := _malmo_approach_underside_height(support_distance) + LOWER_DECK_THICKNESS_M
		var road_bottom := _malmo_approach_underside_height(support_distance) + ROAD_DECK_SOFFIT_OFFSET_M
		var post_height := road_bottom - lower_top
		if post_height > 0.1:
			var post_yaw := float(tangent.signed_angle_to(Vector3.FORWARD, Vector3.UP))
			for side_sign in [-1.0, 1.0]:
				var post_position := Vector3(position.x, (lower_top + road_bottom) * 0.5, position.z) + right * float(side_sign) * side_offset
				_add_oriented_box(parent, "MalmoApproachInterlayerSupport", post_position, Vector3(0.45, post_height, 0.45), post_yaw, _foundation_material, false)
		support_distance += support_spacing


func _build_malmo_approach_piers(parent: Node3D, distance_start: float, distance_end: float, lod: int) -> void:
	if lod == LOD_FAR:
		return
	var supports_variant: Variant = _malmo_approach_config.get("supports", [])
	if not supports_variant is Array:
		return
	for support_variant in supports_variant:
		if not support_variant is Dictionary:
			continue
		var support: Dictionary = support_variant
		var station := float(support.get("station_m", -1.0))
		if station < distance_start - 0.01 or station >= distance_end - 0.01:
			continue
		_add_malmo_approach_pier(parent, station, float(support.get("ground_height_above_water_m", 0.0)), lod == LOD_NEAR)


func _add_malmo_approach_pier(parent: Node3D, distance: float, ground_height_above_water: float, with_collision: bool) -> void:
	var deck_bottom := _malmo_approach_underside_height(distance)
	var ground_y := _sea_level_y + ground_height_above_water
	var height := deck_bottom - ground_y
	if height < 0.2:
		return
	var center := _malmo_approach_position(distance)
	var tangent := _malmo_approach_tangent()
	var yaw := float(tangent.signed_angle_to(Vector3.FORWARD, Vector3.UP))
	var pier_size := Vector3(11.0, height, 8.0)
	_add_oriented_box(parent, "MalmoApproachShorePier", Vector3(center.x, (deck_bottom + ground_y) * 0.5, center.z), pier_size, yaw, _concrete_material, false)
	_add_oriented_box(parent, "MalmoApproachShorePierFooting", Vector3(center.x, ground_y - 1.5, center.z), Vector3(18.0, 3.0, 15.0), yaw, _foundation_material, false)
	if with_collision:
		var body := StaticBody3D.new()
		body.name = "MalmoApproachShorePier_Collision"
		body.position = Vector3(center.x, (deck_bottom + ground_y) * 0.5, center.z)
		body.rotation.y = yaw
		parent.add_child(body)
		var collider := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = pier_size
		collider.shape = shape
		body.add_child(collider)


func _add_malmo_approach_land_abutment(parent: Node3D, distance: float) -> void:
	var position := _malmo_approach_position(distance)
	var deck_bottom := _malmo_approach_underside_height(distance)
	var yaw := float(_malmo_approach_tangent().signed_angle_to(Vector3.FORWARD, Vector3.UP))
	_add_oriented_box(
		parent,
		"MalmoApproachBuriedLandAbutment",
		Vector3(position.x, deck_bottom + ROAD_DECK_TOP_OFFSET_M * 0.5, position.z),
		Vector3(LOWER_DECK_WIDTH_M, ROAD_DECK_TOP_OFFSET_M, 3.0),
		yaw,
		_concrete_material,
		false
	)


func _build_interlayer_supports(parent: Node3D, station_start: float, station_end: float, lod: int) -> void:
	var support_spacing := 126.0 if lod == LOD_NEAR else (252.0 if lod == LOD_MID else SPATIAL_CELL_LENGTH_M)
	var beam_spacing := 105.0 if lod == LOD_NEAR else (210.0 if lod == LOD_MID else SPATIAL_CELL_LENGTH_M)
	var side_offset := LOWER_DECK_WIDTH_M * 0.5 - 0.7
	var beam_station := station_start
	while beam_station < station_end - 0.01:
		var next_beam_station := minf(beam_station + beam_spacing, station_end)
		var start := _position_at_station(beam_station)
		var finish := _position_at_station(next_beam_station)
		var start_right := Vector3.UP.cross(_tangent_at_station(beam_station)).normalized()
		var end_right := Vector3.UP.cross(_tangent_at_station(next_beam_station)).normalized()
		for side_sign in [-1.0, 1.0]:
			var side := float(side_sign) * side_offset
			var lower_start := Vector3(start.x, _underside_height_at_station(beam_station) + LOWER_DECK_THICKNESS_M, start.z) + start_right * side
			var lower_end := Vector3(finish.x, _underside_height_at_station(next_beam_station) + LOWER_DECK_THICKNESS_M, finish.z) + end_right * side
			var upper_start := Vector3(start.x, _underside_height_at_station(beam_station) + ROAD_DECK_SOFFIT_OFFSET_M, start.z) + start_right * side
			var upper_end := Vector3(finish.x, _underside_height_at_station(next_beam_station) + ROAD_DECK_SOFFIT_OFFSET_M, finish.z) + end_right * side
			_add_box_segment(parent, lower_start, lower_end, 0.45, 0.45, _foundation_material, "LowerDeckLongitudinalBeam", false)
			_add_box_segment(parent, upper_start, upper_end, 0.45, 0.45, _foundation_material, "RoadDeckLongitudinalBeam", false)
		beam_station = next_beam_station
	var support_station := ceilf(station_start / support_spacing) * support_spacing
	while support_station < station_end - 0.01:
		var position := _position_at_station(support_station)
		var tangent := _tangent_at_station(support_station)
		var right := Vector3.UP.cross(tangent).normalized()
		var lower_top := _underside_height_at_station(support_station) + LOWER_DECK_THICKNESS_M
		var road_bottom := _underside_height_at_station(support_station) + ROAD_DECK_SOFFIT_OFFSET_M
		var post_height := road_bottom - lower_top
		var post_yaw := float(tangent.signed_angle_to(Vector3.FORWARD, Vector3.UP))
		for side_sign in [-1.0, 1.0]:
			var post_position := Vector3(position.x, (lower_top + road_bottom) * 0.5, position.z) + right * float(side_sign) * side_offset
			_add_oriented_box(parent, "InterlayerSupport", post_position, Vector3(0.45, post_height, 0.45), post_yaw, _foundation_material, false)
		support_station += support_spacing


func _add_box_segment(parent: Node3D, start: Vector3, finish: Vector3, width: float, height: float, material: Material, node_name: String, with_collision: bool) -> void:
	var direction := finish - start
	var segment_length := maxf(direction.length(), 0.1)
	var midpoint := (start + finish) * 0.5
	var size := Vector3(maxf(width, 0.1), maxf(height, 0.1), segment_length + 0.6)
	var box := BoxMesh.new()
	box.size = size
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = box
	instance.material_override = material
	instance.position = midpoint
	parent.add_child(instance)
	instance.look_at(midpoint + direction.normalized(), Vector3.UP)
	if with_collision:
		var body := StaticBody3D.new()
		body.name = "%s_Collision" % node_name
		body.position = midpoint
		parent.add_child(body)
		body.look_at(midpoint + direction.normalized(), Vector3.UP)
		var shape := CollisionShape3D.new()
		var box_shape := BoxShape3D.new()
		box_shape.size = size
		shape.shape = box_shape
		body.add_child(shape)


func _add_pier(parent: Node3D, pier: Dictionary, with_collision: bool) -> void:
	var record: Dictionary = pier["record"]
	var center: Vector3 = pier["position"]
	var deck_bottom := _underside_height_at_station(float(pier["station_m"]))
	var bed_y := _sea_level_y - float(_layout.get("graybox_assumptions", {}).get("pier_bed_extension_m", 25.0))
	var height := maxf(deck_bottom - bed_y, 4.0)
	var size := Vector3(float(pier["width_m"]), height, float(pier["length_m"]))
	var pier_yaw := float((pier["tangent"] as Vector3).signed_angle_to(Vector3.FORWARD, Vector3.UP))
	if pier_visual_scene != null:
		var anchor := Node3D.new()
		anchor.name = "Pier_%s_GLB_Anchor" % str(record.get("way_id", "OSM"))
		anchor.position = Vector3(center.x, _sea_level_y, center.z)
		anchor.rotation.y = pier_yaw
		parent.add_child(anchor)
		var visual := pier_visual_scene.instantiate() as Node3D
		if visual != null:
			visual.scale = pier_visual_scale
			visual.rotation_degrees = pier_visual_rotation_degrees
			anchor.add_child(visual)
	else:
		_add_oriented_box(parent, "Pier_%s" % str(record.get("way_id", "OSM")), Vector3(center.x, (deck_bottom + bed_y) * 0.5, center.z), size, pier_yaw, _concrete_material, false)
	var foundation_size := Vector3(size.x + 7.0, 3.0, size.z + 7.0)
	_add_oriented_box(parent, "PierFoundation_%s" % str(record.get("way_id", "OSM")), Vector3(center.x, _sea_level_y - 2.0, center.z), foundation_size, pier_yaw, _foundation_material, false)
	if with_collision:
		var body := StaticBody3D.new()
		body.name = "Pier_%s_Collision" % str(record.get("way_id", "OSM"))
		body.position = Vector3(center.x, (deck_bottom + bed_y) * 0.5, center.z)
		body.rotation.y = pier_yaw
		parent.add_child(body)
		var collider := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		collider.shape = shape
		body.add_child(collider)


func _add_oriented_box(parent: Node3D, node_name: String, position: Vector3, size: Vector3, yaw: float, material: Material, with_collision: bool) -> void:
	var box := BoxMesh.new()
	box.size = size
	var mesh := MeshInstance3D.new()
	mesh.name = node_name
	mesh.mesh = box
	mesh.material_override = material
	mesh.position = position
	mesh.rotation.y = yaw
	parent.add_child(mesh)
	if not with_collision:
		return
	var body := StaticBody3D.new()
	body.name = "%s_Collision" % node_name
	body.position = position
	body.rotation.y = yaw
	parent.add_child(body)
	var collider := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collider.shape = shape
	body.add_child(collider)


func _set_high_span_lod(lod: int) -> void:
	_clear_children(_high_span_root)
	_high_span_lod = lod
	if lod == LOD_HIDDEN:
		return
	for pylon in _pylon_runtime:
		_add_pylon(_high_span_root, pylon, lod == LOD_NEAR)
	for group in _pylon_groups:
		_add_pylon_crossbeams(_high_span_root, group)
	if lod == LOD_NEAR:
		_add_stay_cables(_high_span_root)


func _add_pylon(parent: Node3D, pylon: Dictionary, with_collision: bool) -> void:
	var record: Dictionary = pylon["record"]
	var position: Vector3 = pylon["position"]
	var pylon_height := float(_layout.get("official_facts", {}).get("pylon_height_m", 203.5))
	var pylon_yaw := atan2(-float((pylon["tangent"] as Vector3).x), -float((pylon["tangent"] as Vector3).z))
	var tower: Node3D
	if pylon_visual_scene != null:
		var anchor := Node3D.new()
		anchor.name = "Pylon_%s_GLB_Anchor" % str(record.get("way_id", "OSM"))
		anchor.position = Vector3(position.x, _sea_level_y, position.z)
		anchor.rotation.y = pylon_yaw
		parent.add_child(anchor)
		var visual := pylon_visual_scene.instantiate() as Node3D
		if visual != null:
			visual.name = "Pylon_%s_GLB" % str(record.get("way_id", "OSM"))
			visual.scale = pylon_visual_scale
			visual.rotation_degrees = pylon_visual_rotation_degrees
			anchor.add_child(visual)
			tower = anchor
	else:
		var pylon_mesh := CylinderMesh.new()
		pylon_mesh.top_radius = 3.0
		pylon_mesh.bottom_radius = 6.2
		pylon_mesh.height = pylon_height
		pylon_mesh.radial_segments = 4
		var greybox := MeshInstance3D.new()
		greybox.name = "Pylon_%s" % str(record.get("way_id", "OSM"))
		greybox.mesh = pylon_mesh
		greybox.material_override = _concrete_material
		greybox.position = Vector3(position.x, _sea_level_y + pylon_height * 0.5, position.z)
		greybox.rotation.y = deg_to_rad(45.0)
		parent.add_child(greybox)
		tower = greybox
	if with_collision:
		var body := StaticBody3D.new()
		body.name = "Pylon_%s_Collision" % str(record.get("way_id", "OSM"))
		body.position = Vector3(position.x, _sea_level_y + pylon_height * 0.5, position.z)
		body.rotation.y = pylon_yaw
		parent.add_child(body)
		var collider := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(12.4, pylon_height + 25.0, 12.4)
		collider.shape = shape
		collider.position.y = -12.5
		body.add_child(collider)


func _add_pylon_crossbeams(parent: Node3D, group: Dictionary) -> void:
	var ids: Variant = group.get("support_way_ids", [])
	if not ids is Array or ids.size() != 2:
		return
	var first := _pylon_position_by_id(int(ids[0]))
	var second := _pylon_position_by_id(int(ids[1]))
	if first == Vector3.INF or second == Vector3.INF:
		return
	for beam_height in [68.0, 155.0]:
		_add_box_segment(parent, first + Vector3.UP * beam_height, second + Vector3.UP * beam_height, 5.0, 4.0, _concrete_material, "PylonCrossbeam", false)


func _add_stay_cables(parent: Node3D) -> void:
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.045
	cylinder.bottom_radius = 0.045
	cylinder.height = 1.0
	cylinder.radial_segments = 4
	var transforms: Array[Transform3D] = []
	var high_start := _high_bridge_start_m()
	var high_end := _high_bridge_end_m()
	for pylon in _pylon_runtime:
		var station := float(pylon["station_m"])
		for side in [-1.0, 1.0]:
			var available := (high_end - station) if side > 0.0 else (station - high_start)
			var max_distance := clampf(available - 8.0, 30.0, 490.0)
			for index in range(20):
				var fraction := float(index + 1) / 20.0
				var target_station := clampf(station + side * lerpf(32.0, max_distance, fraction), high_start + 5.0, high_end - 5.0)
				var deck_position := _position_at_station(target_station)
				var pylon_position: Vector3 = pylon["position"]
				var start_height := lerpf(104.0, 197.0, fraction)
				var start := Vector3(pylon_position.x, _sea_level_y + start_height, pylon_position.z)
				var finish := Vector3(deck_position.x, _underside_height_at_station(target_station) + 9.2, deck_position.z)
				var delta := finish - start
				var length := delta.length()
				if length <= 1.0:
					continue
				var rotation := Quaternion(Vector3.UP, delta / length)
				var basis := Basis(rotation).scaled(Vector3(1.0, length, 1.0))
				transforms.append(Transform3D(basis, (start + finish) * 0.5))
	if transforms.is_empty():
		return
	var multi_mesh := MultiMesh.new()
	multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	multi_mesh.mesh = cylinder
	multi_mesh.instance_count = transforms.size()
	for index in range(transforms.size()):
		multi_mesh.set_instance_transform(index, transforms[index])
	var cables := MultiMeshInstance3D.new()
	cables.name = "StayCables_80Pairs_Graybox"
	cables.multimesh = multi_mesh
	cables.material_override = _cable_material
	parent.add_child(cables)


func _position_at_station(station: float) -> Vector3:
	if _centerline.is_empty():
		return Vector3.ZERO
	var target := clampf(station, 0.0, _total_length_m)
	for index in range(_centerline_stations.size() - 1):
		var start_station := _centerline_stations[index]
		var end_station := _centerline_stations[index + 1]
		if target <= end_station or index == _centerline_stations.size() - 2:
			var blend := clampf((target - start_station) / maxf(end_station - start_station, 0.001), 0.0, 1.0)
			var position := _centerline[index].lerp(_centerline[index + 1], blend)
			position.y = _sea_level_y
			return position
	return _centerline[-1]


func _malmo_approach_tangent() -> Vector3:
	return _tangent_at_station(_total_length_m)


func _malmo_approach_position(distance: float) -> Vector3:
	var endpoint := _position_at_station(_total_length_m)
	return endpoint + _malmo_approach_tangent() * clampf(distance, 0.0, _malmo_approach_length_m)


func _peberholm_approach_tangent() -> Vector3:
	return -_tangent_at_station(0.0)


func _peberholm_approach_position(distance: float) -> Vector3:
	var endpoint := _position_at_station(0.0)
	return endpoint + _peberholm_approach_tangent() * clampf(distance, 0.0, _peberholm_approach_length_m)


func _tangent_at_station(station: float) -> Vector3:
	if _centerline.size() < 2:
		return Vector3.FORWARD
	var target := clampf(station, 0.0, _total_length_m)
	for index in range(_centerline_stations.size() - 1):
		if target <= _centerline_stations[index + 1] or index == _centerline_stations.size() - 2:
			return _horizontal_direction(_centerline[index], _centerline[index + 1])
	return _horizontal_direction(_centerline[-2], _centerline[-1])


func _project_to_centerline(position: Vector3) -> Dictionary:
	var best_distance := INF
	var best_station := 0.0
	for index in range(_centerline.size() - 1):
		var start := _centerline[index]
		var finish := _centerline[index + 1]
		var segment := Vector2(finish.x - start.x, finish.z - start.z)
		var length_squared := segment.length_squared()
		if length_squared <= 0.001:
			continue
		var offset := Vector2(position.x - start.x, position.z - start.z)
		var blend := clampf(offset.dot(segment) / length_squared, 0.0, 1.0)
		var projected := start.lerp(finish, blend)
		var distance := _horizontal_distance(position, projected)
		if distance < best_distance:
			best_distance = distance
			best_station = _centerline_stations[index] + sqrt(length_squared) * blend
	return {"distance_m": best_distance, "station_m": best_station}


func _distance_to_station_range(position: Vector3, station_start: float, station_end: float) -> float:
	var nearest := INF
	var station := station_start
	while station < station_end:
		var next_station := minf(station + 80.0, station_end)
		var start := _position_at_station(station)
		var finish := _position_at_station(next_station)
		var segment := Vector2(finish.x - start.x, finish.z - start.z)
		var offset := Vector2(position.x - start.x, position.z - start.z)
		var length_squared := segment.length_squared()
		var blend := clampf(offset.dot(segment) / length_squared, 0.0, 1.0) if length_squared > 0.001 else 0.0
		var closest := start.lerp(finish, blend)
		nearest = minf(nearest, _horizontal_distance(position, closest))
		station = next_station
	if is_inf(nearest):
		return _horizontal_distance(position, _position_at_station(station_start))
	return nearest


func _distance_to_malmo_approach_range(position: Vector3, distance_start: float, distance_end: float) -> float:
	var start := _malmo_approach_position(distance_start)
	var finish := _malmo_approach_position(distance_end)
	var segment := Vector2(finish.x - start.x, finish.z - start.z)
	var offset := Vector2(position.x - start.x, position.z - start.z)
	var length_squared := segment.length_squared()
	var blend := clampf(offset.dot(segment) / length_squared, 0.0, 1.0) if length_squared > 0.001 else 0.0
	return _horizontal_distance(position, start.lerp(finish, blend))


func _distance_to_peberholm_approach_range(position: Vector3, distance_start: float, distance_end: float) -> float:
	var start := _peberholm_approach_position(distance_start)
	var finish := _peberholm_approach_position(distance_end)
	var segment := Vector2(finish.x - start.x, finish.z - start.z)
	var offset := Vector2(position.x - start.x, position.z - start.z)
	var length_squared := segment.length_squared()
	var blend := clampf(offset.dot(segment) / length_squared, 0.0, 1.0) if length_squared > 0.001 else 0.0
	return _horizontal_distance(position, start.lerp(finish, blend))


func _underside_height_at_station(station: float) -> float:
	var assumptions: Dictionary = _layout.get("graybox_assumptions", {})
	var low_at_west := float(assumptions.get("approach_start_underside_above_water_m", 10.0))
	var low_at_east := float(assumptions.get("approach_end_underside_above_water_m", 10.0))
	var clearance := float(_layout.get("official_facts", {}).get("navigation_clearance_m", 57.0))
	if station <= HIGH_BRIDGE_START_M:
		return _sea_level_y + lerpf(low_at_west, clearance, clampf(station / HIGH_BRIDGE_START_M, 0.0, 1.0))
	if station <= HIGH_BRIDGE_END_M:
		return _sea_level_y + clearance
	var east_length := maxf(_total_length_m - HIGH_BRIDGE_END_M, 1.0)
	return _sea_level_y + lerpf(clearance, low_at_east, clampf((station - HIGH_BRIDGE_END_M) / east_length, 0.0, 1.0))


func _malmo_approach_underside_height(distance: float) -> float:
	var start_height := _underside_height_at_station(_total_length_m)
	if distance >= _malmo_approach_ramp_length_m:
		return _malmo_approach_target_underside_y
	var t := clampf(distance / maxf(_malmo_approach_ramp_length_m, 0.001), 0.0, 1.0)
	var end_height := _malmo_approach_target_underside_y
	var start_tangent_scaled := _malmo_approach_start_slope * _malmo_approach_ramp_length_m
	var start_basis := 2.0 * t * t * t - 3.0 * t * t + 1.0
	var start_tangent_basis := t * t * t - 2.0 * t * t + t
	var end_basis := -2.0 * t * t * t + 3.0 * t * t
	return start_basis * start_height + start_tangent_basis * start_tangent_scaled + end_basis * end_height


func _peberholm_approach_underside_height(distance: float) -> float:
	var start_height := _underside_height_at_station(0.0)
	if distance >= _peberholm_approach_ramp_length_m:
		return _peberholm_approach_target_underside_y
	var t := clampf(distance / maxf(_peberholm_approach_ramp_length_m, 0.001), 0.0, 1.0)
	var end_height := _peberholm_approach_target_underside_y
	var start_tangent_scaled := _peberholm_approach_start_slope * _peberholm_approach_ramp_length_m
	var start_basis := 2.0 * t * t * t - 3.0 * t * t + 1.0
	var start_tangent_basis := t * t * t - 2.0 * t * t + t
	var end_basis := -2.0 * t * t * t + 3.0 * t * t
	return start_basis * start_height + start_tangent_basis * start_tangent_scaled + end_basis * end_height


func _group_world_position(group_id: String) -> Vector3:
	for group in _pylon_groups:
		if str(group.get("group_id", "")) == group_id:
			var position := georeference.geodetic_to_world(float(group.get("latitude", 0.0)), float(group.get("longitude", 0.0)))
			position.y = _sea_level_y
			return position
	return Vector3.INF


func _pylon_position_by_id(way_id: int) -> Vector3:
	for pylon in _pylon_runtime:
		if int((pylon["record"] as Dictionary).get("way_id", -1)) == way_id:
			return pylon["position"]
	return Vector3.INF


func _high_bridge_start_m() -> float:
	return minf(HIGH_BRIDGE_START_M, _total_length_m)


func _high_bridge_end_m() -> float:
	return minf(HIGH_BRIDGE_END_M, _total_length_m)


func _count_piers_in_station_range(start_m: float, end_m: float) -> int:
	var count := 0
	for pier in _pier_runtime:
		var station := float(pier["station_m"])
		if station >= start_m and station <= end_m:
			count += 1
	return count


func _count_piers_between_pylon_groups() -> int:
	var west := _project_to_centerline(_group_world_position("main_pylon_west"))
	var east := _project_to_centerline(_group_world_position("main_pylon_east"))
	var start_station := minf(float(west.get("station_m", 0.0)), float(east.get("station_m", 0.0)))
	var end_station := maxf(float(west.get("station_m", 0.0)), float(east.get("station_m", 0.0)))
	return _count_piers_in_station_range(start_station + 5.0, end_station - 5.0)


func _horizontal_direction(start: Vector3, finish: Vector3) -> Vector3:
	var direction := finish - start
	direction.y = 0.0
	return direction.normalized() if direction.length_squared() > 0.001 else Vector3.FORWARD


func _horizontal_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _lod_name(lod: int) -> String:
	match lod:
		LOD_NEAR:
			return "近"
		LOD_MID:
			return "中"
		LOD_FAR:
			return "远"
		_:
			return "未加载"


func _clear_children(parent: Node) -> void:
	if parent == null:
		return
	for child in parent.get_children():
		parent.remove_child(child)
		child.queue_free()


func _developer_tools_available() -> bool:
	return Engine.is_editor_hint() or OS.has_feature("debug")


func _teleport_to_next_test_location() -> void:
	if _boat == null or _centerline.is_empty():
		return
	_teleport_index = (_teleport_index + 1) % 3
	var gate_station := (_high_bridge_start_m() + _high_bridge_end_m()) * 0.5
	var gate_center := _position_at_station(gate_station)
	var tangent := _tangent_at_station(gate_station)
	var destination := gate_center
	var desired_forward := tangent
	match _teleport_index:
		0:
			destination = gate_center
			desired_forward = tangent
		1:
			var malmo_endpoint := _position_at_station(_total_length_m)
			var malmo_tangent := _tangent_at_station(_total_length_m)
			destination = _find_endpoint_observation_position(malmo_endpoint, malmo_tangent)
			desired_forward = _horizontal_direction(destination, malmo_endpoint)
		_:
			var peberholm_endpoint := _position_at_station(0.0)
			var peberholm_tangent := _tangent_at_station(0.0)
			destination = _find_endpoint_observation_position(peberholm_endpoint, peberholm_tangent)
			desired_forward = _horizontal_direction(destination, peberholm_endpoint)
	_last_teleport_name = ["主桥跨中观察点", "Malmö 桥端观察点", "Peberholm 桥端观察点"][_teleport_index]
	destination.y = _sea_level_y
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
	_debug_enabled = true
	_debug_root.visible = true
	_debug_panel.visible = true
	_update_lods()
	_update_debug_panel()


func _find_endpoint_observation_position(endpoint: Vector3, tangent: Vector3) -> Vector3:
	var across := Vector3(-tangent.z, 0.0, tangent.x).normalized()
	if across.length_squared() < 0.001:
		across = Vector3.RIGHT
	var fallback := endpoint + across * 650.0
	if _navigation_depth_provider == null or not _navigation_depth_provider.has_method("query_world_position"):
		return fallback
	var offsets := [150.0, 225.0, 300.0, 400.0, 525.0, 650.0, 800.0]
	for distance_value in offsets:
		var distance := float(distance_value)
		var positive: Vector3 = endpoint + across * distance
		var negative: Vector3 = endpoint - across * distance
		positive.y = _sea_level_y
		negative.y = _sea_level_y
		var positive_sample: Dictionary = _navigation_depth_provider.call("query_world_position", positive)
		var negative_sample: Dictionary = _navigation_depth_provider.call("query_world_position", negative)
		var positive_is_water := bool(positive_sample.get("valid", false)) and str(positive_sample.get("data_state", "")) == "water"
		var negative_is_water := bool(negative_sample.get("valid", false)) and str(negative_sample.get("data_state", "")) == "water"
		if positive_is_water and negative_is_water:
			return positive if float(positive_sample.get("depth_m", 0.0)) >= float(negative_sample.get("depth_m", 0.0)) else negative
		if positive_is_water:
			return positive
		if negative_is_water:
			return negative
	return fallback


func _update_debug_panel() -> void:
	if _debug_label == null:
		return
	var snapshot := get_debug_snapshot()
	var gate := get_navigation_gate_snapshot()
	var boat_geo := georeference.world_to_geodetic(_boat.global_position) if _boat != null else Vector3.ZERO
	_debug_label.text = (
		"Øresund Bridge · GPS 灰盒 V1\n"
		+ "船位 %.5f°N, %.5f°E · 海平面 Y %.2f m\n" % [boat_geo.x, boat_geo.y, _sea_level_y]
		+ "距离段 LOD：近 %d · 中 %d · 远 %d · 未加载 %d · 主桥塔 %s\n" % [int(snapshot["near_cells"]), int(snapshot["mid_cells"]), int(snapshot["far_cells"]), int(snapshot["hidden_cells"]), str(snapshot["high_span_lod"])]
		+ "长度 %.0f m · 桥墩 %d · 桥塔 %d · 主航道净空 %.1f m\n" % [_total_length_m, _pier_runtime.size(), _pylon_runtime.size(), float(gate["clearance_m"])]
		+ "主塔组间距 %.1f m · 自由跨内桥墩 %d · 本船高度 %.1f m · 名义余量 %.1f m\n" % [float(gate["pylon_group_separation_m"]), int(gate["osm_pier_count_inside_free_span"]), float(gate["vessel_height_m"]), float(gate["nominal_vertical_clearance_margin_m"])]
		+ "端点延伸估算 %.1f m / 端 · 最近测试定位：%s\n" % [_endpoint_extension_m, _last_teleport_name]
		+ "Peberholm 引桥 %.0f m · 坡道 %.0f m · 支墩 %d · 植被让道 %d 株\n" % [_peberholm_approach_length_m, _peberholm_approach_ramp_length_m, int((_peberholm_approach_config.get("supports", []) as Array).size()) if _peberholm_approach_config.get("supports", []) is Array else 0, _peberholm_flora_removed_count]
		+ "F5 显示/隐藏桥梁诊断标记 · Shift+F5 循环定位 (主桥跨中 → Malmö 端 → Peberholm 端)\n"
		+ "© OpenStreetMap contributors · ODbL-1.0 · 垂直基准采用游戏静水面解释"
	)
