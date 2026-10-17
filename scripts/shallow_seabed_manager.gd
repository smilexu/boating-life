class_name ShallowSeabedManager
extends Node3D

## Streams deterministic, chart-derived 0–9 m seabed tiles around the player.
## The extra mesh below the 6 m visibility limit is only a hidden fade margin;
## it does not change bathymetry or navigation depth.

const CACHE_LIMIT := 24
const SCAN_CACHE_LIMIT := 512
const INVALID_TILE := Vector2i(-2147483647, -2147483647)
const REEF_CLUSTER_SEED := 92841
const SEAGRASS_GENERATOR := preload("res://scripts/shallow_seagrass_generator.gd")
const SEAGRASS_SHADER := preload("res://shaders/shallow_seagrass_sway.gdshader")
const SEAGRASS_LAYOUT_VERSION := 2
const SEAGRASS_MESH_STYLE_VERSION := 2
const SEAGRASS_SEED := 771903
const SEAGRASS_PATCH_CELL_M := 22.0
const SEAGRASS_INSTANCE_SPACING_M := 0.17
const SEAGRASS_ENV_SAMPLE_M := 4.0
const SEAGRASS_CANDIDATES_PER_SLICE := 64
const MAX_SEAGRASS_SLICES_PER_FRAME := 256
const SEAGRASS_VARIANT_COUNT := 4
const SEAGRASS_BATCH_COUNT := 9

@export_category("References")
@export var georeference: GeoReference
@export_node_path("Node") var bathymetry_manager_path := NodePath("../BathymetryManager")
@export_node_path("Node3D") var player_boat_path := NodePath("../PlayerBoat/MotionRoot")
@export var water_material: ShaderMaterial
@export var seabed_material: ShaderMaterial
@export var reef_asset_library: ShallowReefAssetLibrary

@export_category("Streaming")
@export var system_enabled := true
@export_range(32.0, 512.0, 16.0) var tile_size_m := 128.0
@export_range(64.0, 500.0, 16.0) var near_radius_m := 300.0
@export_range(200.0, 1200.0, 16.0) var far_radius_m := 600.0
@export_range(64.0, 1400.0, 16.0) var unload_radius_m := 704.0
@export_range(1.0, 60.0, 1.0) var coarse_scan_spacing_m := 32.0
@export_range(1, 4, 1) var generation_jobs_per_frame := 1
@export_range(8, 64, 1) var mesh_depth_limit_m := 9.0
@export_range(0.0, 2.0, 0.05) var water_surface_above_lat_m := 0.5

@export_category("Geometry LOD")
@export_range(8.0, 32.0, 1.0) var near_vertex_spacing_m := 16.0
@export_range(16.0, 64.0, 1.0) var far_vertex_spacing_m := 32.0
@export_range(8.0, 64.0, 4.0) var lod_hysteresis_m := 32.0
@export_range(0.0, 0.4, 0.01) var broad_relief_amplitude_m := 0.15
@export_range(0.0, 0.15, 0.01) var fine_relief_amplitude_m := 0.04

@export_category("Reef Clusters")
@export var enable_reefs := true
@export var enable_reef_clusters := true
@export var enable_reef_fill_stones := true
@export var show_reef_cluster_debug := false
@export_range(0.2, 6.0, 0.1) var maximum_rock_depth_m := 5.8
@export_range(0.0, 1.0, 0.05) var rock_density_near := 1.0
@export_range(0.0, 1.0, 0.05) var rock_density_far := 0.32
@export_range(24.0, 64.0, 2.0) var reef_cluster_cell_spacing_m := 36.0
@export_range(0.0, 16.0, 0.5) var reef_cluster_center_jitter_m := 8.0
@export_range(0.0, 1.0, 0.02) var reef_cluster_base_chance := 0.08
@export_range(0.0, 1.0, 0.02) var reef_cluster_rocky_chance := 0.48
@export var small_cluster_radius_m := Vector2(1.0, 3.0)
@export var medium_cluster_radius_m := Vector2(3.0, 6.0)
@export var large_cluster_radius_m := Vector2(5.0, 8.0)
@export_range(1, 3, 1) var maximum_cluster_modules := 2
@export_range(0, 4, 1) var maximum_fill_stones_per_cluster := 2

@export_category("Seagrass Meadows")
@export var enable_seagrass := true
@export var enable_seagrass_sway := true
@export_enum("Sparse:0", "Normal:1", "Dense:2") var seagrass_density_preset := 1
@export_range(0.6, 1.6, 0.05) var seagrass_ecology_coverage_scale := 1.0
@export_range(0.4, 1.5, 0.05) var seagrass_render_density_scale := 1.0
@export_range(16.0, 60.0, 1.0) var seagrass_visible_radius_m := 35.0
@export_range(0.0, 0.5, 0.01) var seagrass_sway_strength := 0.12
@export var seagrass_flow_direction := Vector2(0.92, 0.38)
@export_range(0.0, 1.5, 0.05) var seagrass_flow_speed := 0.18
@export_range(1.0, 12.0, 0.5) var seagrass_generation_budget_ms := 6.0
@export var show_seagrass_distribution := false

@export_category("Developer Controls")
@export var show_chunk_bounds := false
@export var show_statistics := false
@export var show_lod_debug := false

var _bathymetry: BathymetryManager
var _boat: Node3D
var _reef_asset_cache: Array[Dictionary] = []
var _pending_scan: Array[Dictionary] = []
var _pending_build: Array[Dictionary] = []
var _requested_tiles: Dictionary = {}
var _scan_cache: Dictionary = {}
var _scan_cache_lru: Array[Vector2i] = []
var _loaded_tiles: Dictionary = {}
var _mesh_cache: Dictionary = {}
var _mesh_cache_lru: Array[Vector3i] = []
var _last_center_tile := INVALID_TILE
var _runtime_enabled := false
var _runtime_reefs_enabled := false
var _runtime_bounds_enabled := false
var _runtime_statistics_enabled := false
var _runtime_lod_debug := false
var _runtime_clusters_enabled := false
var _runtime_fill_enabled := false
var _runtime_cluster_debug := false
var _stats_label: Label
var _stats_layer: CanvasLayer
var _refresh_elapsed := 0.0
var _stats_elapsed := 0.0
var _last_build_ms := 0.0
var _average_build_ms := 0.0
var _completed_builds := 0
var _debug_rocks_count := 0
var _seagrass_meshes_near: Array[Mesh] = []
var _seagrass_meshes_far: Array[Mesh] = []
var _seagrass_mesh_heights_near: PackedFloat32Array = PackedFloat32Array()
var _seagrass_mesh_heights_far: PackedFloat32Array = PackedFloat32Array()
var _seagrass_mesh_triangles_near: PackedInt32Array = PackedInt32Array()
var _seagrass_mesh_triangles_far: PackedInt32Array = PackedInt32Array()
var _seagrass_algae_mesh: Mesh
var _seagrass_algae_height := 0.42
var _seagrass_algae_triangles := 0
var _seagrass_material: ShaderMaterial
var _seagrass_jobs: Dictionary = {}
var _seagrass_job_queue: Array[Vector2i] = []
var _fish_eelgrass_weight_cache: Dictionary = {}
var _fish_eelgrass_cache_coverage_scale := -1.0
var _seagrass_refresh_elapsed := 0.0
var _last_seagrass_focus := Vector2(INF, INF)
var _seagrass_revision := 0
var _runtime_seagrass_enabled := false
var _runtime_seagrass_sway := false
var _runtime_seagrass_density_preset := -1
var _runtime_seagrass_coverage_scale := -1.0
var _runtime_seagrass_render_scale := -1.0
var _runtime_seagrass_debug := false
var _last_seagrass_build_ms := 0.0
var _average_seagrass_build_ms := 0.0
var _completed_seagrass_builds := 0
var _last_seagrass_slice_ms := 0.0
var _maximum_seagrass_slice_ms := 0.0
var _last_seagrass_finish_ms := 0.0
var _maximum_seagrass_finish_ms := 0.0


func _ready() -> void:
	_bathymetry = get_node_or_null(bathymetry_manager_path) as BathymetryManager
	_boat = get_node_or_null(player_boat_path) as Node3D
	if water_material == null and _bathymetry != null:
		water_material = _bathymetry.water_material
	if georeference == null and _bathymetry != null:
		georeference = _bathymetry.georeference
	if _bathymetry == null or _boat == null or georeference == null:
		push_error("ShallowSeabedManager requires BathymetryManager, GeoReference and PlayerBoat/MotionRoot.")
		system_enabled = false
		return
	if not _bathymetry.data_available:
		push_warning("Shallow seabed is disabled because the offline EMODnet grid is unavailable.")
		system_enabled = false
		return
	if seabed_material == null:
		push_error("ShallowSeabedManager needs its shallow seabed ShaderMaterial resource.")
		system_enabled = false
		return
	water_material.set_shader_parameter("shallow_surface_above_lat_m", water_surface_above_lat_m)

	_reef_asset_cache = ShallowReefGenerator.load_asset_cache(reef_asset_library)
	_create_seagrass_resources()
	_build_statistics_ui()
	_runtime_enabled = system_enabled
	_runtime_reefs_enabled = enable_reefs
	_runtime_bounds_enabled = show_chunk_bounds
	_runtime_statistics_enabled = show_statistics
	_runtime_lod_debug = show_lod_debug
	_runtime_clusters_enabled = enable_reef_clusters
	_runtime_fill_enabled = enable_reef_fill_stones
	_runtime_cluster_debug = show_reef_cluster_debug
	_runtime_seagrass_enabled = enable_seagrass
	_runtime_seagrass_sway = enable_seagrass_sway
	_runtime_seagrass_density_preset = seagrass_density_preset
	_runtime_seagrass_coverage_scale = seagrass_ecology_coverage_scale
	_runtime_seagrass_render_scale = seagrass_render_density_scale
	_runtime_seagrass_debug = show_seagrass_distribution
	seabed_material.set_shader_parameter("show_lod_debug", show_lod_debug)
	if _runtime_enabled:
		visible = true
		_refresh_requested_tiles()
		_refresh_seagrass_stream(true)
	var start_depth: Dictionary = _bathymetry.get_depth_at_world_position(_boat.global_position)
	var start_geo := georeference.world_to_geodetic(Vector3(_boat.global_position.x, 0.0, _boat.global_position.z))
	print("[ShallowSeabed] start GPS %.5f N, %.5f E · depth %s" % [start_geo.x, start_geo.y, _depth_text(start_depth)])


func _process(delta: float) -> void:
	_sync_runtime_options()
	if not _runtime_enabled or _boat == null:
		return
	_refresh_elapsed += delta
	if _refresh_elapsed >= 0.5:
		_refresh_elapsed = fmod(_refresh_elapsed, 0.5)
		var current_tile := _get_boat_tile()
		if current_tile != _last_center_tile:
			_refresh_requested_tiles()
		_refresh_seagrass_stream(false)
	_process_generation_queue()
	_process_seagrass_generation()
	_stats_elapsed += delta
	if _stats_elapsed >= 0.25:
		_stats_elapsed = fmod(_stats_elapsed, 0.25)
		_update_statistics_text()


func _unhandled_key_input(event: InputEvent) -> void:
	if event is not InputEventKey or not event.pressed or event.echo:
		return
	if event.physical_keycode == KEY_F6:
		_toggle_water_transparency()
	elif event.physical_keycode == KEY_F7 and not event.shift_pressed and not event.ctrl_pressed:
		system_enabled = not system_enabled
		_sync_runtime_options()
	elif event.physical_keycode == KEY_F8:
		if event.shift_pressed:
			show_chunk_bounds = not show_chunk_bounds
		elif event.ctrl_pressed:
			enable_reefs = not enable_reefs
		elif event.alt_pressed:
			show_lod_debug = not show_lod_debug
		else:
			show_statistics = not show_statistics
		_sync_runtime_options()
	elif event.physical_keycode == KEY_F9:
		if event.ctrl_pressed:
			enable_reef_fill_stones = not enable_reef_fill_stones
		elif event.alt_pressed:
			show_reef_cluster_debug = not show_reef_cluster_debug
		else:
			enable_reef_clusters = not enable_reef_clusters
		_sync_runtime_options()
	elif event.physical_keycode == KEY_F11:
		if event.shift_pressed:
			enable_seagrass_sway = not enable_seagrass_sway
		elif event.ctrl_pressed:
			seagrass_density_preset = posmod(seagrass_density_preset + 1, 3)
		elif event.alt_pressed:
			show_seagrass_distribution = not show_seagrass_distribution
		else:
			enable_seagrass = not enable_seagrass
		_sync_runtime_options()


func get_debug_stats() -> Dictionary:
	var triangle_count := 0
	var active_chunk_count := 0
	var rock_count := 0
	var reef_triangle_count := 0
	var cluster_count := 0
	var batch_count := 0
	var asset_counts: Dictionary = {}
	var module_instances := 0
	var single_instances := 0
	var module_envelope_m3 := 0.0
	var single_envelope_m3 := 0.0
	var eelgrass_instances := 0
	var algae_instances := 0
	var seagrass_triangles := 0
	var seagrass_batches := 0
	var seagrass_patch_count := 0
	var seagrass_view_area_m2 := 0.0
	var seagrass_core_area_m2 := 0.0
	var seagrass_patch_area_m2 := 0.0
	var seagrass_canopy_area_m2 := 0.0
	for tile_data in _loaded_tiles.values():
		if not is_instance_valid(tile_data.get("root")):
			continue
		active_chunk_count += 1
		triangle_count += int(tile_data.get("triangles", 0))
		if _runtime_reefs_enabled:
			rock_count += int(tile_data.get("rocks", 0))
			reef_triangle_count += int(tile_data.get("reef_triangles", 0))
			cluster_count += int(tile_data.get("reef_clusters", 0))
			batch_count += int(tile_data.get("reef_batches", 0))
			for asset_id in tile_data.get("asset_instances", {}).keys():
				asset_counts[asset_id] = int(asset_counts.get(asset_id, 0)) + int(tile_data["asset_instances"][asset_id])
			var reef_payload: Dictionary = tile_data.get("bundle", {}).get("reef_payload", {})
			module_instances += int(reef_payload.get("module_instances", 0))
			single_instances += int(reef_payload.get("single_instances", 0))
			module_envelope_m3 += float(reef_payload.get("module_envelope_m3", 0.0))
			single_envelope_m3 += float(reef_payload.get("single_envelope_m3", 0.0))
		var grass_payload: Dictionary = tile_data.get("bundle", {}).get("seagrass_payload", {})
		eelgrass_instances += int(grass_payload.get("eelgrass_instances", 0))
		algae_instances += int(grass_payload.get("algae_instances", 0))
		seagrass_triangles += int(grass_payload.get("triangles", 0))
		seagrass_batches += int(grass_payload.get("batches", 0))
		seagrass_patch_count += int(grass_payload.get("patch_count", 0))
		seagrass_view_area_m2 += float(grass_payload.get("view_area_m2", 0.0))
		seagrass_core_area_m2 += float(grass_payload.get("core_area_m2", 0.0))
		seagrass_patch_area_m2 += float(grass_payload.get("patch_area_m2", 0.0))
		seagrass_canopy_area_m2 += float(grass_payload.get("canopy_area_m2", 0.0))
	var meadow_coverage := 100.0 * seagrass_core_area_m2 / maxf(seagrass_view_area_m2, 0.001)
	var canopy_coverage := 100.0 * (1.0 - exp(-seagrass_canopy_area_m2 / maxf(seagrass_patch_area_m2, 0.001)))
	var density_targets := _density_targets()
	return {
		"enabled": _runtime_enabled,
		"loaded_chunks": _loaded_tiles.size(),
		"active_chunks": active_chunk_count,
		"loaded_triangles": triangle_count,
		"rock_instances": rock_count,
		"reef_triangles": reef_triangle_count,
		"reef_clusters": cluster_count,
		"reef_batches": batch_count,
		"asset_instances": asset_counts,
		"module_instances": module_instances,
		"single_instances": single_instances,
		"module_envelope_m3": module_envelope_m3,
		"single_envelope_m3": single_envelope_m3,
		"module_envelope_share": module_envelope_m3 / maxf(module_envelope_m3 + single_envelope_m3, 0.0001),
		"seagrass_enabled": _runtime_seagrass_enabled,
		"seagrass_sway_enabled": _runtime_seagrass_sway,
		"seagrass_density_preset": _runtime_seagrass_density_preset,
		"seagrass_layout_version": SEAGRASS_LAYOUT_VERSION,
		"seagrass_mesh_style_version": SEAGRASS_MESH_STYLE_VERSION,
		"seagrass_instances": eelgrass_instances + algae_instances,
		"eelgrass_instances": eelgrass_instances,
		"algae_instances": algae_instances,
		"seagrass_triangles": seagrass_triangles,
		"seagrass_batches": seagrass_batches,
		"seagrass_patches": seagrass_patch_count,
		"seagrass_estimated_meadow_coverage_percent": meadow_coverage,
		"seagrass_estimated_canopy_coverage_percent": canopy_coverage,
		"seagrass_estimated_patch_extent_percent": 100.0 * seagrass_patch_area_m2 / maxf(seagrass_view_area_m2, 0.001),
		"seagrass_target_edge_density_per_m2": density_targets.x,
		"seagrass_target_core_density_per_m2": density_targets.y,
		"seagrass_patch_area_m2": seagrass_patch_area_m2,
		"seagrass_estimated_core_area_m2": seagrass_core_area_m2,
		"seagrass_generated_density_per_patch_m2": float(eelgrass_instances) / maxf(seagrass_patch_area_m2, 0.001),
		"seagrass_visible_radius_m": seagrass_visible_radius_m,
		"seagrass_builds_pending": _seagrass_job_queue.size(),
		"seagrass_last_build_ms": _last_seagrass_build_ms,
		"seagrass_average_build_ms": _average_seagrass_build_ms,
		"seagrass_last_slice_ms": _last_seagrass_slice_ms,
		"seagrass_maximum_slice_ms": _maximum_seagrass_slice_ms,
		"seagrass_last_finish_ms": _last_seagrass_finish_ms,
		"seagrass_maximum_finish_ms": _maximum_seagrass_finish_ms,
		"seagrass_generation_budget_ms": seagrass_generation_budget_ms,
		"glb_assets_loaded": _count_loaded_reef_assets(),
		"pending_tiles": _pending_scan.size() + _pending_build.size() + _seagrass_job_queue.size(),
		"last_chunk_build_ms": _last_build_ms,
		"average_chunk_build_ms": _average_build_ms,
		"near_lod_chunks": _count_lod_chunks(0),
		"far_lod_chunks": _count_lod_chunks(1),
	}


## Read-only ecology context for client fish behavior. It reuses the exact
## deterministic eelgrass patch layout and already-generated reef cluster data.
## These hints only steer local visuals; they never move authority school anchors.
func get_fish_habitat_context(world_position: Vector3, activity_radius_m: float = 4.2) -> Dictionary:
	if not is_equal_approx(_fish_eelgrass_cache_coverage_scale, seagrass_ecology_coverage_scale):
		_fish_eelgrass_weight_cache.clear()
		_fish_eelgrass_cache_coverage_scale = seagrass_ecology_coverage_scale
	var east := world_position.x
	var north := -world_position.z
	var center_weight := _fish_eelgrass_weight_at(east, north)
	var edge_direction := Vector2.ZERO
	var edge_strength := 0.0
	if center_weight >= 0.62:
		var best_weight := center_weight
		var radius := maxf(activity_radius_m, 2.0)
		for sample_index in range(8):
			var angle := TAU * float(sample_index) / 8.0
			var direction := Vector2(cos(angle), sin(angle))
			var sample_weight := _fish_eelgrass_weight_at(east + direction.x * radius, north + direction.y * radius)
			if sample_weight < best_weight:
				best_weight = sample_weight
				edge_direction = direction
		if edge_direction.length_squared() > 0.0:
			edge_strength = clampf((center_weight - best_weight - 0.06) * 1.8, 0.0, 1.0)
	var reef_clusters := get_nearby_reef_clusters(world_position, activity_radius_m + 8.0)
	return {
		"eelgrass_weight": center_weight,
		"edge_direction": Vector3(edge_direction.x, 0.0, -edge_direction.y),
		"edge_strength": edge_strength,
		"reef_clusters": reef_clusters,
	}


## Returns nearby deterministic cluster centers from the active seabed tiles.
## Positions are world-space and include the generated placement radius.
func get_nearby_reef_clusters(world_position: Vector3, radius_m: float) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var focus := Vector2(world_position.x, -world_position.z)
	for tile_data in _loaded_tiles.values():
		var payload: Dictionary = tile_data.get("bundle", {}).get("reef_payload", {})
		for record in payload.get("cluster_debug", []):
			var east := float(record.get("east", 0.0))
			var north := float(record.get("north", 0.0))
			var cluster_radius := float(record.get("radius", 1.0))
			if Vector2(east, north).distance_to(focus) > radius_m + cluster_radius:
				continue
			result.append({
				"world_position": Vector3(east, float(record.get("ground_y", 0.0)), -north),
				"radius_m": cluster_radius,
			})
	return result


func _fish_eelgrass_weight_at(east: float, north: float) -> float:
	const CACHE_CELL_M := 8.0
	var cell := Vector2i(floori(east / CACHE_CELL_M), floori(north / CACHE_CELL_M))
	if _fish_eelgrass_weight_cache.has(cell):
		return float(_fish_eelgrass_weight_cache[cell])
	var sample_east := (float(cell.x) + 0.5) * CACHE_CELL_M
	var sample_north := (float(cell.y) + 0.5) * CACHE_CELL_M
	var patches := SEAGRASS_GENERATOR.build_patch_centers(
		sample_east - 40.0, sample_north - 40.0,
		sample_east + 40.0, sample_north + 40.0,
		SEAGRASS_PATCH_CELL_M, SEAGRASS_SEED, seagrass_ecology_coverage_scale
	)
	var lookup := SEAGRASS_GENERATOR.build_patch_lookup(patches)
	var weight := SEAGRASS_GENERATOR.patch_weight(sample_east, sample_north, lookup, SEAGRASS_PATCH_CELL_M, seagrass_ecology_coverage_scale)
	if _fish_eelgrass_weight_cache.size() >= 4096:
		_fish_eelgrass_weight_cache.clear()
	_fish_eelgrass_weight_cache[cell] = weight
	return weight


func _create_seagrass_resources() -> void:
	_seagrass_material = ShaderMaterial.new()
	_seagrass_material.shader = SEAGRASS_SHADER
	_seagrass_material.set_shader_parameter("sway_enabled", enable_seagrass_sway)
	_seagrass_material.set_shader_parameter("current_direction", seagrass_flow_direction.normalized())
	_seagrass_material.set_shader_parameter("current_speed", seagrass_flow_speed)
	_seagrass_material.set_shader_parameter("sway_strength", seagrass_sway_strength)
	_seagrass_meshes_near.clear()
	_seagrass_meshes_far.clear()
	_seagrass_mesh_heights_near = PackedFloat32Array()
	_seagrass_mesh_heights_far = PackedFloat32Array()
	_seagrass_mesh_triangles_near = PackedInt32Array()
	_seagrass_mesh_triangles_far = PackedInt32Array()
	for variant_index in range(SEAGRASS_VARIANT_COUNT):
		var near_data: Dictionary = SEAGRASS_GENERATOR.create_eelgrass_variant(variant_index, false)
		var far_data: Dictionary = SEAGRASS_GENERATOR.create_eelgrass_variant(variant_index, true)
		_seagrass_meshes_near.append(near_data["mesh"])
		_seagrass_meshes_far.append(far_data["mesh"])
		_seagrass_mesh_heights_near.append(float(near_data["max_height"]))
		_seagrass_mesh_heights_far.append(float(far_data["max_height"]))
		_seagrass_mesh_triangles_near.append(int(near_data["triangles"]))
		_seagrass_mesh_triangles_far.append(int(far_data["triangles"]))
	var algae_data: Dictionary = SEAGRASS_GENERATOR.create_rock_algae_mesh()
	_seagrass_algae_mesh = algae_data["mesh"]
	_seagrass_algae_height = float(algae_data["max_height"])
	_seagrass_algae_triangles = int(algae_data["triangles"])


func _current_seagrass_focus() -> Vector2:
	var camera := get_viewport().get_camera_3d()
	var position := camera.global_position if camera != null else _boat.global_position
	return Vector2(position.x, -position.z)


func _refresh_seagrass_stream(force: bool) -> void:
	if _boat == null:
		return
	var focus := _current_seagrass_focus()
	if not force and _last_seagrass_focus.distance_to(focus) < 8.0:
		return
	_last_seagrass_focus = focus
	if force:
		_seagrass_revision += 1
		_seagrass_jobs.clear()
		_seagrass_job_queue.clear()
	if not _runtime_seagrass_enabled or not _runtime_enabled:
		for tile_data in _loaded_tiles.values():
			_clear_tile_seagrass(tile_data)
		return
	var desired: Array[Dictionary] = []
	var desired_keys: Dictionary = {}
	for tile_key_variant in _loaded_tiles.keys():
		var key: Vector2i = tile_key_variant
		var tile_data: Dictionary = _loaded_tiles[key]
		var east_min := float(key.x) * tile_size_m
		var north_min := float(key.y) * tile_size_m
		var closest_east := clampf(focus.x, east_min, east_min + tile_size_m)
		var closest_north := clampf(focus.y, north_min, north_min + tile_size_m)
		var distance := Vector2(focus.x - closest_east, focus.y - closest_north).length()
		if distance <= seagrass_visible_radius_m + 0.5:
			desired.append({"key": key, "distance": distance, "tile_data": tile_data})
			desired_keys[key] = true
		else:
			_clear_tile_seagrass(tile_data)
	for job_key_variant in _seagrass_jobs.keys():
		var job_key: Vector2i = job_key_variant
		if not desired_keys.has(job_key):
			_seagrass_jobs.erase(job_key)
			_seagrass_job_queue.erase(job_key)
	desired.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["distance"]) < float(b["distance"]))
	for entry in desired:
		_queue_seagrass_tile(entry["key"], focus)


func _queue_seagrass_tile(key: Vector2i, focus: Vector2) -> void:
	if not _runtime_seagrass_enabled or not _loaded_tiles.has(key) or _seagrass_jobs.has(key):
		return
	var tile_data: Dictionary = _loaded_tiles[key]
	var tile_root := tile_data.get("root") as Node3D
	if not is_instance_valid(tile_root):
		return
	var east_min := float(key.x) * tile_size_m
	var north_min := float(key.y) * tile_size_m
	var north_max := north_min + tile_size_m
	var radius := seagrass_visible_radius_m + 0.5
	var area_east_min := maxf(east_min, focus.x - radius)
	var area_east_max := minf(east_min + tile_size_m, focus.x + radius)
	var area_north_min := maxf(north_min, focus.y - radius)
	var area_north_max := minf(north_max, focus.y + radius)
	if area_east_max <= area_east_min or area_north_max <= area_north_min:
		return
	var spacing := SEAGRASS_INSTANCE_SPACING_M
	var x_min := floori(area_east_min / spacing) - 1
	var x_max := ceili(area_east_max / spacing) + 1
	var z_min := floori(area_north_min / spacing) - 1
	var z_max := ceili(area_north_max / spacing) + 1
	var patches: Array[Dictionary] = SEAGRASS_GENERATOR.build_patch_centers(
		area_east_min, area_north_min, area_east_max, area_north_max,
		SEAGRASS_PATCH_CELL_M, SEAGRASS_SEED, seagrass_ecology_coverage_scale
	)
	var buckets: Array[Dictionary] = []
	for _index in range(SEAGRASS_BATCH_COUNT):
		buckets.append({"transforms": [], "colors": [], "custom": []})
	var job := {
		"revision": _seagrass_revision,
		"key": key,
		"focus": focus,
		"tile_east_min": east_min,
		"tile_north_min": north_min,
		"tile_north_max": north_max,
		"area_east_min": area_east_min,
		"area_east_max": area_east_max,
		"area_north_min": area_north_min,
		"area_north_max": area_north_max,
		"x_min": x_min,
		"x_max": x_max,
		"z_min": z_min,
		"z_max": z_max,
		"row": z_min,
		"column": x_min,
		"patches": patches,
		"patch_lookup": SEAGRASS_GENERATOR.build_patch_lookup(patches),
		"buckets": buckets,
		"environment_cache": {},
		"reef_centers": _collect_nearby_reef_centers(focus),
		"view_samples": 0,
		"core_samples": 0,
		"covered_samples": 0,
		"eelgrass_instances": 0,
		"algae_instances": 0,
		"signature_hash": 0,
		"cpu_usec": 0,
	}
	_seagrass_jobs[key] = job
	_seagrass_job_queue.append(key)


func _process_seagrass_generation() -> void:
	if _seagrass_job_queue.is_empty():
		return
	var slice_started_usec := Time.get_ticks_usec()
	var budget_usec := int(seagrass_generation_budget_ms * 1000.0)
	var slices_processed := 0
	while not _seagrass_job_queue.is_empty() and slices_processed < MAX_SEAGRASS_SLICES_PER_FRAME:
		if slices_processed > 0 and Time.get_ticks_usec() - slice_started_usec >= budget_usec:
			break
		var key: Vector2i = _seagrass_job_queue.pop_front()
		if not _seagrass_jobs.has(key):
			continue
		var job: Dictionary = _seagrass_jobs[key]
		if not _loaded_tiles.has(key) or int(job["revision"]) != _seagrass_revision:
			_seagrass_jobs.erase(key)
			continue
		if bool(job.get("scan_complete", false)):
			var completed_focus: Vector2 = job["focus"]
			_finish_seagrass_job(key, job)
			_seagrass_jobs.erase(key)
			slices_processed += 1
			var current_focus := _current_seagrass_focus()
			if completed_focus.distance_to(current_focus) >= 8.0:
				_queue_seagrass_tile(key, current_focus)
			break
		var row_start_usec := Time.get_ticks_usec()
		_process_seagrass_candidate_slice(job, SEAGRASS_CANDIDATES_PER_SLICE)
		job["cpu_usec"] = int(job["cpu_usec"]) + Time.get_ticks_usec() - row_start_usec
		slices_processed += 1
		if int(job["row"]) > int(job["z_max"]):
			job["scan_complete"] = true
			_seagrass_jobs[key] = job
			_seagrass_job_queue.append(key)
			break
		else:
			_seagrass_job_queue.append(key)
	_last_seagrass_slice_ms = float(Time.get_ticks_usec() - slice_started_usec) / 1000.0
	_maximum_seagrass_slice_ms = maxf(_maximum_seagrass_slice_ms, _last_seagrass_slice_ms)


func _process_seagrass_candidate_slice(job: Dictionary, maximum_candidates: int) -> void:
	var row := int(job["row"])
	var column_start := int(job["column"])
	var column_end := mini(int(job["x_max"]), column_start + maximum_candidates - 1)
	var focus: Vector2 = job["focus"]
	var key: Vector2i = job["key"]
	var density_values := _density_targets()
	var maximum_density := float(density_values[1]) * seagrass_render_density_scale
	var early_eel_probability := clampf(maximum_density / 35.0, 0.0, 1.0)
	var focus_east := focus.x
	var focus_north := focus.y
	var visible_radius_squared := seagrass_visible_radius_m * seagrass_visible_radius_m
	for column in range(column_start, column_end + 1):
		var north := (float(row) + 0.5) * SEAGRASS_INSTANCE_SPACING_M
		north += (SEAGRASS_GENERATOR.hash01(column, row, SEAGRASS_SEED + 1) - 0.5) * SEAGRASS_INSTANCE_SPACING_M * 0.70
		if north < float(job["area_north_min"]) or north > float(job["area_north_max"]):
			continue
		var east := (float(column) + 0.5) * SEAGRASS_INSTANCE_SPACING_M
		east += (SEAGRASS_GENERATOR.hash01(column, row, SEAGRASS_SEED + 2) - 0.5) * SEAGRASS_INSTANCE_SPACING_M * 0.70
		if east < float(job["area_east_min"]) or east > float(job["area_east_max"]):
			continue
		if not _point_is_in_tile(east, north, float(job["tile_east_min"]), float(job["tile_north_min"]), float(job["tile_north_max"])):
			continue
		var offset_east := east - focus_east
		var offset_north := north - focus_north
		var distance_squared := offset_east * offset_east + offset_north * offset_north
		if distance_squared > visible_radius_squared:
			continue
		job["view_samples"] = int(job["view_samples"]) + 1
		var patch_weight := SEAGRASS_GENERATOR.patch_weight(
			east, north, job["patch_lookup"], SEAGRASS_PATCH_CELL_M, seagrass_ecology_coverage_scale
		)
		if patch_weight > 0.03:
			job["covered_samples"] = int(job["covered_samples"]) + 1
		if patch_weight >= 0.76:
			job["core_samples"] = int(job["core_samples"]) + 1
		var eel_roll := SEAGRASS_GENERATOR.hash01(column, row, SEAGRASS_SEED + 21)
		var near_reef := _within_reef_algae_radius(east, north, job["reef_centers"], 4.2)
		var algae_roll := SEAGRASS_GENERATOR.hash01(column, row, SEAGRASS_SEED + 22)
		var potential_eelgrass := patch_weight > 0.03 and eel_roll <= early_eel_probability
		if not potential_eelgrass and (not near_reef or algae_roll > 0.16):
			continue
		var environment := _vegetation_environment(job, east, north)
		if not bool(environment.get("valid", false)):
			continue
		var depth := float(environment["depth_m"])
		var slope := float(environment["slope"])
		var weights: Color = environment["weights"]
		var ground_y := float(environment["height_m"])
		var normal: Vector3 = environment["normal"]
		var depth_factor := _eelgrass_depth_suitability(depth)
		var slope_factor := 1.0 - smoothstep(0.07, 0.22, slope) * 0.82
		var habitat_factor := clampf(weights.r + weights.g * 0.66 - weights.b * 0.88, 0.0, 1.0)
		var distance := sqrt(distance_squared)
		if patch_weight > 0.03 and depth_factor > 0.0 and habitat_factor > 0.04 and slope_factor > 0.04:
			var edge_density := float(density_values[0])
			var core_density := float(density_values[1])
			var core_weight := pow(smoothstep(0.02, 0.96, patch_weight), 0.82)
			var target_density := lerpf(edge_density, core_density, core_weight)
			var lod_multiplier := 1.0 if distance <= 15.0 else 0.82
			var spawn_probability := clampf(target_density / 35.0 * seagrass_render_density_scale * lod_multiplier * habitat_factor * depth_factor * slope_factor, 0.0, 1.0)
			if eel_roll <= spawn_probability:
				_add_seagrass_instance(job, east, north, ground_y, depth, normal, distance, column, row, false)
		var rocky_factor := clampf(weights.b * 1.2 + (0.22 if near_reef else 0.0), 0.0, 1.0)
		if near_reef and depth_factor > 0.0 and rocky_factor > 0.18 and algae_roll < 1.75 / 35.0 * rocky_factor * depth_factor:
			_add_seagrass_instance(job, east, north, ground_y, depth, normal, distance, column, row, true)
	if column_end >= int(job["x_max"]):
		job["row"] = row + 1
		job["column"] = int(job["x_min"])
	else:
		job["column"] = column_end + 1


func _density_targets() -> Vector2:
	match seagrass_density_preset:
		0:
			return Vector2(4.0, 8.0)
		2:
			return Vector2(12.0, 35.0)
		_:
			return Vector2(8.0, 20.0)


func _eelgrass_depth_suitability(depth: float) -> float:
	if depth < 0.48 or depth >= 6.0:
		return 0.0
	if depth < 0.9:
		return smoothstep(0.48, 0.9, depth) * 0.55
	if depth <= 3.0:
		return 1.0
	if depth <= 5.0:
		return lerpf(1.0, 0.18, smoothstep(3.0, 5.0, depth))
	return 0.18 * (1.0 - smoothstep(5.0, 6.0, depth))


func _vegetation_environment(job: Dictionary, east: float, north: float) -> Dictionary:
	var cache: Dictionary = job["environment_cache"]
	var spacing := SEAGRASS_ENV_SAMPLE_M
	var cache_key := Vector2i(floori(east / spacing), floori(north / spacing))
	if cache.has(cache_key):
		return cache[cache_key]
	var sample_east := (float(cache_key.x) + 0.5) * spacing
	var sample_north := (float(cache_key.y) + 0.5) * spacing
	var ground := _sample_ground(sample_east, sample_north)
	if not bool(ground.get("valid", false)):
		cache[cache_key] = {"valid": false}
		return cache[cache_key]
	var depth := float(ground["depth_m"])
	if depth < 0.48 or depth >= 6.0:
		cache[cache_key] = {"valid": false}
		return cache[cache_key]
	var slope := _candidate_slope(sample_east, sample_north, depth)
	var weights := _material_weights(sample_east, sample_north, depth, slope, 0)
	var normal := _candidate_normal(sample_east, sample_north)
	cache[cache_key] = {
		"valid": true,
		"depth_m": depth,
		"height_m": float(ground["height_m"]),
		"slope": slope,
		"weights": weights,
		"normal": normal,
	}
	return cache[cache_key]


func _add_seagrass_instance(job: Dictionary, east: float, north: float, ground_y: float, depth: float, normal: Vector3, distance: float, grid_east: int, grid_north: int, algae: bool) -> void:
	var is_far := distance > 15.0
	var variant_index := posmod(int(SEAGRASS_GENERATOR.hash01(grid_east, grid_north, SEAGRASS_SEED + (51 if algae else 41)) * float(SEAGRASS_VARIANT_COUNT)), SEAGRASS_VARIANT_COUNT)
	var mesh_height := _seagrass_algae_height
	if not algae:
		mesh_height = _seagrass_mesh_heights_far[variant_index] if is_far else _seagrass_mesh_heights_near[variant_index]
	var random_height_scale := 0.82 + SEAGRASS_GENERATOR.hash01(grid_east, grid_north, SEAGRASS_SEED + 61) * 0.40
	var clearance_height := minf(0.86, depth - 0.42)
	var height_scale := minf(random_height_scale, clearance_height / maxf(mesh_height, 0.001))
	if height_scale < 0.42:
		return
	var scale_jitter := 0.82 + SEAGRASS_GENERATOR.hash01(grid_east, grid_north, SEAGRASS_SEED + 62) * 0.36
	if is_far:
		scale_jitter *= 1.08
	var scale := Vector3(scale_jitter, height_scale, scale_jitter)
	var yaw := SEAGRASS_GENERATOR.hash01(grid_east, grid_north, SEAGRASS_SEED + 63) * TAU
	var basis := _reef_placement_basis(normal, yaw, scale)
	var local_position := Vector3(
		east - float(job["tile_east_min"]),
		ground_y,
		float(job["tile_north_max"]) - north
	)
	var transform := Transform3D(basis, local_position)
	var red_tint := 0.88 + SEAGRASS_GENERATOR.hash01(grid_east, grid_north, SEAGRASS_SEED + 64) * 0.20
	var green_tint := 0.91 + SEAGRASS_GENERATOR.hash01(grid_east, grid_north, SEAGRASS_SEED + 65) * 0.16
	var blue_tint := 0.76 + SEAGRASS_GENERATOR.hash01(grid_east, grid_north, SEAGRASS_SEED + 66) * 0.18
	var instance_color := Color(red_tint, green_tint, blue_tint, 1.0)
	var custom := Color(
		SEAGRASS_GENERATOR.hash01(grid_east, grid_north, SEAGRASS_SEED + 71),
		SEAGRASS_GENERATOR.hash01(grid_east, grid_north, SEAGRASS_SEED + 72),
		SEAGRASS_GENERATOR.hash01(grid_east, grid_north, SEAGRASS_SEED + 73),
		SEAGRASS_GENERATOR.hash01(grid_east, grid_north, SEAGRASS_SEED + 74)
	)
	var bucket_index := 8 if algae else variant_index + (4 if is_far else 0)
	var bucket: Dictionary = job["buckets"][bucket_index]
	bucket["transforms"].append(transform)
	bucket["colors"].append(instance_color)
	bucket["custom"].append(custom)
	if algae:
		job["algae_instances"] = int(job["algae_instances"]) + 1
	else:
		job["eelgrass_instances"] = int(job["eelgrass_instances"]) + 1
	var signature_seed := SEAGRASS_SEED + bucket_index * 97 + (83 if algae else 0)
	job["signature_hash"] = int(job["signature_hash"]) ^ int(SEAGRASS_GENERATOR.hash01(grid_east, grid_north, signature_seed) * 2147483647.0)


func _collect_nearby_reef_centers(focus: Vector2) -> Array[Vector2]:
	var centers: Array[Vector2] = []
	for tile_data in _loaded_tiles.values():
		var payload: Dictionary = tile_data.get("bundle", {}).get("reef_payload", {})
		for record in payload.get("cluster_debug", []):
			var position := Vector2(float(record.get("east", 0.0)), float(record.get("north", 0.0)))
			if position.distance_to(focus) <= seagrass_visible_radius_m + 6.0:
				centers.append(position)
	return centers


func _within_reef_algae_radius(east: float, north: float, centers: Array[Vector2], radius: float) -> bool:
	var limit_squared := radius * radius
	for center in centers:
		var dx := center.x - east
		var dz := center.y - north
		if dx * dx + dz * dz <= limit_squared:
			return true
	return false


func _finish_seagrass_job(key: Vector2i, job: Dictionary) -> void:
	if not _loaded_tiles.has(key) or int(job["revision"]) != _seagrass_revision:
		return
	var started_usec := Time.get_ticks_usec()
	var tile_data: Dictionary = _loaded_tiles[key]
	var tile_root := tile_data.get("root") as Node3D
	if not is_instance_valid(tile_root):
		return
	var old_grass := tile_root.get_node_or_null("Seagrass")
	if old_grass != null:
		old_grass.queue_free()
	var grass_root := Node3D.new()
	grass_root.name = "Seagrass"
	tile_root.add_child(grass_root)
	var triangles := 0
	var batches := 0
	for bucket_index in range(SEAGRASS_BATCH_COUNT):
		var bucket: Dictionary = job["buckets"][bucket_index]
		var transforms: Array = bucket["transforms"]
		if transforms.is_empty():
			continue
		var mesh: Mesh
		var label: String
		if bucket_index < 4:
			mesh = _seagrass_meshes_near[bucket_index]
			label = "Eelgrass_Near_%d" % bucket_index
			triangles += transforms.size() * _seagrass_mesh_triangles_near[bucket_index]
		elif bucket_index < 8:
			var variant := bucket_index - 4
			mesh = _seagrass_meshes_far[variant]
			label = "Eelgrass_Far_%d" % variant
			triangles += transforms.size() * _seagrass_mesh_triangles_far[variant]
		else:
			mesh = _seagrass_algae_mesh
			label = "Rock_Algae"
			triangles += transforms.size() * _seagrass_algae_triangles
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.use_colors = true
		multimesh.use_custom_data = true
		multimesh.mesh = mesh
		multimesh.instance_count = transforms.size()
		for instance_index in range(transforms.size()):
			multimesh.set_instance_transform(instance_index, transforms[instance_index])
			multimesh.set_instance_color(instance_index, bucket["colors"][instance_index])
			multimesh.set_instance_custom_data(instance_index, bucket["custom"][instance_index])
		var instance := MultiMeshInstance3D.new()
		instance.name = label
		instance.multimesh = multimesh
		instance.material_override = _seagrass_material
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		instance.custom_aabb = AABB(Vector3(-2.0, -10.0, -2.0), Vector3(tile_size_m + 4.0, 12.0, tile_size_m + 4.0))
		grass_root.add_child(instance)
		batches += 1
	var patch_centers: Array[Dictionary] = job["patches"]
	if _runtime_seagrass_debug:
		_add_seagrass_patch_guides(grass_root, key, patch_centers)
	var view_area := float(job["view_samples"]) * SEAGRASS_INSTANCE_SPACING_M * SEAGRASS_INSTANCE_SPACING_M
	var core_area := float(job["core_samples"]) * SEAGRASS_INSTANCE_SPACING_M * SEAGRASS_INSTANCE_SPACING_M
	var canopy_area := float(job["eelgrass_instances"]) * 0.055 + float(job["algae_instances"]) * 0.012
	var patch_area := float(job["covered_samples"]) * SEAGRASS_INSTANCE_SPACING_M * SEAGRASS_INSTANCE_SPACING_M
	var patch_count := 0
	for patch in patch_centers:
		if _point_is_in_tile(float(patch["east"]), float(patch["north"]), float(job["tile_east_min"]), float(job["tile_north_min"]), float(job["tile_north_max"])):
			patch_count += 1
	var payload := {
		"layout_version": SEAGRASS_LAYOUT_VERSION,
		"seed": SEAGRASS_SEED,
		"layout_signature": str(int(job["signature_hash"])),
		"eelgrass_instances": int(job["eelgrass_instances"]),
		"algae_instances": int(job["algae_instances"]),
		"triangles": triangles,
		"batches": batches,
		"patch_count": patch_count,
		"view_area_m2": view_area,
		"core_area_m2": core_area,
		"patch_area_m2": patch_area,
		"canopy_area_m2": canopy_area,
		"covered_samples": int(job["covered_samples"]),
	}
	var bundle: Dictionary = tile_data["bundle"]
	bundle["seagrass_payload"] = payload
	tile_data["bundle"] = bundle
	tile_data["seagrass_instances"] = payload["eelgrass_instances"] + payload["algae_instances"]
	tile_data["seagrass_triangles"] = triangles
	tile_data["seagrass_batches"] = batches
	_last_seagrass_finish_ms = float(Time.get_ticks_usec() - started_usec) / 1000.0
	_maximum_seagrass_finish_ms = maxf(_maximum_seagrass_finish_ms, _last_seagrass_finish_ms)
	_last_seagrass_build_ms = float(int(job["cpu_usec"]) + Time.get_ticks_usec() - started_usec) / 1000.0
	_completed_seagrass_builds += 1
	_average_seagrass_build_ms += (_last_seagrass_build_ms - _average_seagrass_build_ms) / float(_completed_seagrass_builds)


func _clear_tile_seagrass(tile_data: Dictionary) -> void:
	var root := tile_data.get("root") as Node3D
	if is_instance_valid(root):
		var grass := root.get_node_or_null("Seagrass")
		if grass != null:
			grass.queue_free()
	var bundle: Dictionary = tile_data.get("bundle", {})
	bundle["seagrass_payload"] = _empty_seagrass_payload()
	tile_data["bundle"] = bundle
	tile_data["seagrass_instances"] = 0
	tile_data["seagrass_triangles"] = 0
	tile_data["seagrass_batches"] = 0


func _empty_seagrass_payload() -> Dictionary:
	return {
		"layout_version": SEAGRASS_LAYOUT_VERSION,
		"seed": SEAGRASS_SEED,
		"layout_signature": "0",
		"eelgrass_instances": 0,
		"algae_instances": 0,
		"triangles": 0,
		"batches": 0,
		"patch_count": 0,
		"view_area_m2": 0.0,
		"core_area_m2": 0.0,
		"patch_area_m2": 0.0,
		"canopy_area_m2": 0.0,
		"covered_samples": 0,
	}


func _add_seagrass_patch_guides(parent: Node3D, key: Vector2i, patches: Array[Dictionary]) -> void:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.36, 0.95, 0.52, 0.88)
	material.no_depth_test = true
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	var east_min := float(key.x) * tile_size_m
	var north_min := float(key.y) * tile_size_m
	var north_max := north_min + tile_size_m
	var focus := _last_seagrass_focus
	for patch in patches:
		var center_east := float(patch["east"])
		var center_north := float(patch["north"])
		if Vector2(center_east - focus.x, center_north - focus.y).length() > seagrass_visible_radius_m + 34.0:
			continue
		var color := Color(0.35, 0.98, 0.5, 0.9)
		if String(patch["type"]) == "medium":
			color = Color(0.9, 0.76, 0.22, 0.9)
		elif String(patch["type"]) == "large":
			color = Color(0.98, 0.43, 0.24, 0.92)
		var previous := Vector3.ZERO
		for segment in range(49):
			var angle := TAU * float(segment) / 48.0
			var along := cos(angle) * float(patch["major"])
			var across := sin(angle) * float(patch["minor"])
			var rotation := float(patch["angle"])
			var world_east := center_east + along * cos(rotation) - across * sin(rotation)
			var world_north := center_north + along * sin(rotation) + across * cos(rotation)
			var point := Vector3(world_east - east_min, -0.2, north_max - world_north)
			if segment > 0:
				mesh.surface_set_color(color)
				mesh.surface_add_vertex(previous)
				mesh.surface_add_vertex(point)
			previous = point
	mesh.surface_end()
	if mesh.get_surface_count() == 0:
		return
	var guide := MeshInstance3D.new()
	guide.name = "SeagrassPatchGuides"
	guide.mesh = mesh
	guide.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(guide)


func _remove_seagrass_patch_guides() -> int:
	var removed_count := 0
	for tile_data in _loaded_tiles.values():
		var tile_root := tile_data.get("root") as Node3D
		if not is_instance_valid(tile_root):
			continue
		var grass_root := tile_root.get_node_or_null("Seagrass") as Node3D
		if grass_root == null:
			continue
		var guide := grass_root.get_node_or_null("SeagrassPatchGuides") as MeshInstance3D
		if guide != null:
			guide.visible = false
			guide.queue_free()
			removed_count += 1
	return removed_count


func _sync_runtime_options() -> void:
	if _runtime_enabled != system_enabled:
		_runtime_enabled = system_enabled
		visible = _runtime_enabled
		if _runtime_enabled:
			_last_center_tile = INVALID_TILE
			_refresh_requested_tiles()
		else:
			_pending_scan.clear()
			_pending_build.clear()
			_requested_tiles.clear()
			for key in _loaded_tiles.keys():
				_release_tile(key, true)
	var reef_layout_changed := _runtime_clusters_enabled != enable_reef_clusters or _runtime_fill_enabled != enable_reef_fill_stones
	var reef_visibility_changed := _runtime_reefs_enabled != enable_reefs
	_runtime_clusters_enabled = enable_reef_clusters
	_runtime_fill_enabled = enable_reef_fill_stones
	_runtime_reefs_enabled = enable_reefs
	if reef_visibility_changed or reef_layout_changed:
		_rebuild_active_reefs(true)
	var cluster_debug_changed := _runtime_cluster_debug != show_reef_cluster_debug
	_runtime_cluster_debug = show_reef_cluster_debug
	if cluster_debug_changed and not (reef_visibility_changed or reef_layout_changed):
		_rebuild_active_reefs(false)
	var seagrass_enabled_changed := _runtime_seagrass_enabled != enable_seagrass
	var seagrass_layout_changed := (
		_runtime_seagrass_density_preset != seagrass_density_preset
		or not is_equal_approx(_runtime_seagrass_coverage_scale, seagrass_ecology_coverage_scale)
		or not is_equal_approx(_runtime_seagrass_render_scale, seagrass_render_density_scale)
	)
	var seagrass_debug_changed := _runtime_seagrass_debug != show_seagrass_distribution
	var seagrass_sway_changed := _runtime_seagrass_sway != enable_seagrass_sway
	_runtime_seagrass_enabled = enable_seagrass
	_runtime_seagrass_density_preset = seagrass_density_preset
	_runtime_seagrass_coverage_scale = seagrass_ecology_coverage_scale
	_runtime_seagrass_render_scale = seagrass_render_density_scale
	_runtime_seagrass_debug = show_seagrass_distribution
	_runtime_seagrass_sway = enable_seagrass_sway
	if seagrass_debug_changed and not _runtime_seagrass_debug:
		_remove_seagrass_patch_guides()
	if _seagrass_material != null:
		if seagrass_sway_changed:
			_seagrass_material.set_shader_parameter("sway_enabled", enable_seagrass_sway)
		if _seagrass_material.get_shader_parameter("current_direction") != seagrass_flow_direction.normalized():
			_seagrass_material.set_shader_parameter("current_direction", seagrass_flow_direction.normalized())
		if not is_equal_approx(float(_seagrass_material.get_shader_parameter("current_speed")), seagrass_flow_speed):
			_seagrass_material.set_shader_parameter("current_speed", seagrass_flow_speed)
		if not is_equal_approx(float(_seagrass_material.get_shader_parameter("sway_strength")), seagrass_sway_strength):
			_seagrass_material.set_shader_parameter("sway_strength", seagrass_sway_strength)
	if seagrass_enabled_changed and not _runtime_seagrass_enabled:
		_seagrass_jobs.clear()
		_seagrass_job_queue.clear()
		for tile_data in _loaded_tiles.values():
			_clear_tile_seagrass(tile_data)
	elif seagrass_enabled_changed or seagrass_layout_changed or seagrass_debug_changed or reef_visibility_changed or reef_layout_changed:
		_refresh_seagrass_stream(true)
	if _runtime_bounds_enabled != show_chunk_bounds:
		_runtime_bounds_enabled = show_chunk_bounds
		for tile_data in _loaded_tiles.values():
			_set_tile_bounds_visible(tile_data, _runtime_bounds_enabled)
	if _runtime_statistics_enabled != show_statistics:
		_runtime_statistics_enabled = show_statistics
		if _stats_layer != null:
			_stats_layer.visible = _runtime_statistics_enabled
	if _runtime_lod_debug != show_lod_debug:
		_runtime_lod_debug = show_lod_debug
		if seabed_material != null:
			seabed_material.set_shader_parameter("show_lod_debug", _runtime_lod_debug)


func _refresh_requested_tiles() -> void:
	if not _runtime_enabled or _boat == null:
		return
	_last_center_tile = _get_boat_tile()
	_pending_scan.clear()
	_pending_build.clear()
	_requested_tiles.clear()
	var boat_east_north := Vector2(_boat.global_position.x, -_boat.global_position.z)
	var half_tile_diagonal := tile_size_m * sqrt(0.5)
	var tile_search_radius := ceili((unload_radius_m + half_tile_diagonal) / tile_size_m)
	var candidate_tiles: Array[Dictionary] = []
	for y in range(_last_center_tile.y - tile_search_radius, _last_center_tile.y + tile_search_radius + 1):
		for x in range(_last_center_tile.x - tile_search_radius, _last_center_tile.x + tile_search_radius + 1):
			var key := Vector2i(x, y)
			var center := Vector2((float(x) + 0.5) * tile_size_m, (float(y) + 0.5) * tile_size_m)
			var distance := center.distance_to(boat_east_north)
			if distance > far_radius_m + half_tile_diagonal:
				continue
			var lod := _choose_lod(key, distance)
			_requested_tiles[key] = lod
			candidate_tiles.append({"key": key, "lod": lod, "distance": distance})
	candidate_tiles.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["distance"]) < float(b["distance"]))
	for request in candidate_tiles:
		_queue_tile_if_needed(request["key"], int(request["lod"]))

	var loaded_keys: Array = _loaded_tiles.keys()
	for key_value in loaded_keys:
		var key: Vector2i = key_value
		var center := Vector2((float(key.x) + 0.5) * tile_size_m, (float(key.y) + 0.5) * tile_size_m)
		var distance := center.distance_to(boat_east_north)
		if distance > unload_radius_m + half_tile_diagonal:
			_release_tile(key, true)
			_requested_tiles.erase(key)
		elif not _requested_tiles.has(key):
			var existing_lod := int(_loaded_tiles[key].get("lod", 1))
			_requested_tiles[key] = existing_lod


func _queue_tile_if_needed(key: Vector2i, lod: int) -> void:
	if _loaded_tiles.has(key) and int(_loaded_tiles[key].get("lod", -1)) == lod:
		return
	var cache_key := Vector3i(key.x, key.y, lod)
	if _mesh_cache.has(cache_key):
		_pending_build.append({"key": key, "lod": lod})
		return
	if _scan_cache.has(key):
		_touch_scan_cache(key)
		if bool(_scan_cache[key]):
			_pending_build.append({"key": key, "lod": lod})
		return
	_pending_scan.append({"key": key, "lod": lod})


func _choose_lod(key: Vector2i, distance: float) -> int:
	var previous_lod := -1
	if _loaded_tiles.has(key):
		previous_lod = int(_loaded_tiles[key].get("lod", -1))
	elif _requested_tiles.has(key):
		previous_lod = int(_requested_tiles[key])
	if previous_lod == 0:
		return 0 if distance <= near_radius_m + lod_hysteresis_m else 1
	if previous_lod == 1:
		return 0 if distance < near_radius_m - lod_hysteresis_m else 1
	return 0 if distance < near_radius_m else 1


func _process_generation_queue() -> void:
	var job_budget := maxi(generation_jobs_per_frame, 1)
	while job_budget > 0:
		job_budget -= 1
		if not _pending_scan.is_empty():
			_process_one_scan()
			continue
		if not _pending_build.is_empty():
			_process_one_build()
			continue
		break


func _process_one_scan() -> void:
	var request: Dictionary = _pending_scan.pop_front()
	var key: Vector2i = request["key"]
	if not _request_is_current(key, int(request["lod"])):
		return
	var has_shallow_water := _tile_has_shallow_water(key)
	_cache_scan_result(key, has_shallow_water)
	if has_shallow_water:
		_pending_build.append(request)


func _process_one_build() -> void:
	var request: Dictionary = _pending_build.pop_front()
	var key: Vector2i = request["key"]
	var lod := int(request["lod"])
	if not _request_is_current(key, lod):
		return
	var cache_key := Vector3i(key.x, key.y, lod)
	var bundle: Dictionary
	if _mesh_cache.has(cache_key):
		bundle = _take_cached_bundle(cache_key)
	else:
		var start_usec := Time.get_ticks_usec()
		bundle = _build_tile_bundle(key, lod)
		_last_build_ms = float(Time.get_ticks_usec() - start_usec) / 1000.0
		_completed_builds += 1
		_average_build_ms += (_last_build_ms - _average_build_ms) / float(_completed_builds)
	if bundle.is_empty() or bundle.get("mesh") == null:
		return
	_attach_tile(key, lod, bundle)


func _request_is_current(key: Vector2i, lod: int) -> bool:
	return _runtime_enabled and _requested_tiles.has(key) and int(_requested_tiles[key]) == lod


func _cache_scan_result(key: Vector2i, has_shallow_water: bool) -> void:
	_scan_cache[key] = has_shallow_water
	_touch_scan_cache(key)
	while _scan_cache_lru.size() > SCAN_CACHE_LIMIT:
		var oldest: Vector2i = _scan_cache_lru.pop_front()
		_scan_cache.erase(oldest)


func _touch_scan_cache(key: Vector2i) -> void:
	_scan_cache_lru.erase(key)
	_scan_cache_lru.append(key)


func _tile_has_shallow_water(key: Vector2i) -> bool:
	var east_min := float(key.x) * tile_size_m
	var north_min := float(key.y) * tile_size_m
	var samples := ceili(tile_size_m / coarse_scan_spacing_m)
	var spacing := tile_size_m / float(samples)
	for z_index in range(samples + 1):
		var north := north_min + float(z_index) * spacing
		for x_index in range(samples + 1):
			var east := east_min + float(x_index) * spacing
			var sample: Dictionary = _sample_depth(east, north)
			if bool(sample.get("valid", false)) and float(sample.get("depth_m", INF)) <= mesh_depth_limit_m:
				return true
	return false


func _build_tile_bundle(key: Vector2i, lod: int) -> Dictionary:
	var east_min := float(key.x) * tile_size_m
	var north_min := float(key.y) * tile_size_m
	var north_max := north_min + tile_size_m
	var step := near_vertex_spacing_m if lod == 0 else far_vertex_spacing_m
	var segments := roundi(tile_size_m / step)
	if segments <= 0 or not is_equal_approx(float(segments) * step, tile_size_m):
		push_error("Tile size must be divisible by the selected seabed LOD spacing.")
		return {}
	var width := segments + 1
	var vertex_count := width * width
	var heights := PackedFloat32Array()
	var depths := PackedFloat32Array()
	var validity := PackedByteArray()
	heights.resize(vertex_count)
	depths.resize(vertex_count)
	validity.resize(vertex_count)

	for row in range(width):
		var north := north_max - float(row) * step
		for column in range(width):
			var east := east_min + float(column) * step
			var sample := _sample_tile_vertex(key, east, north, row, column, segments, step, lod)
			var index := row * width + column
			if bool(sample.get("valid", false)):
				depths[index] = float(sample["depth_m"])
				heights[index] = float(sample["height_m"])
				validity[index] = 1
			else:
				depths[index] = mesh_depth_limit_m + 1.0
				heights[index] = -mesh_depth_limit_m
				validity[index] = 0

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	vertices.resize(vertex_count)
	normals.resize(vertex_count)
	colors.resize(vertex_count)
	uvs.resize(vertex_count)
	for row in range(width):
		for column in range(width):
			var index := row * width + column
			var east := east_min + float(column) * step
			var north := north_max - float(row) * step
			vertices[index] = Vector3(float(column) * step, heights[index], float(row) * step)
			uvs[index] = Vector2(east, north) * 0.06
			normals[index] = _vertex_normal(key, east, north, row, column, segments, width, step, heights, validity, lod)
			if validity[index] == 1:
				var slope := _grid_slope(row, column, width, step, heights, validity)
				colors[index] = _material_weights(east, north, depths[index], slope, lod)
			else:
				colors[index] = Color(1.0, 0.0, 0.0, 1.0 if lod == 0 else 0.0)
	if lod == 0:
		_constrain_near_edge_colors(colors, depths, validity, width, segments)

	var indices := PackedInt32Array()
	var triangle_count := 0
	for row in range(segments):
		for column in range(segments):
			var north_west := row * width + column
			var south_west := north_west + width
			var north_east := north_west + 1
			var south_east := south_west + 1
			if _triangle_is_valid([north_west, south_west, north_east], depths, validity):
				# Godot front-face winding for a top-facing X/Z grid is clockwise
				# when viewed from +Y. Keep the supplied finite-difference normals up.
				indices.append_array(PackedInt32Array([north_west, north_east, south_west]))
				triangle_count += 1
			if _triangle_is_valid([north_east, south_west, south_east], depths, validity):
				indices.append_array(PackedInt32Array([north_east, south_east, south_west]))
				triangle_count += 1
	if triangle_count == 0:
		return {}

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var reef_payload := _build_reef_payload(key, lod, east_min, north_min, north_max) if enable_reefs else _empty_reef_payload()
	var rock_count := _reef_payload_instance_count(reef_payload)
	return {
		"mesh": mesh,
		"triangles": triangle_count,
		"rocks": rock_count,
		"reef_payload": reef_payload,
		"seagrass_payload": _empty_seagrass_payload(),
		"lod": lod,
	}


func _sample_tile_vertex(
	key: Vector2i,
	east: float,
	north: float,
	row: int,
	column: int,
	segments: int,
	step: float,
	lod: int
) -> Dictionary:
	if lod != 0:
		return _sample_ground(east, north)
	var is_vertical_edge := column == 0 or column == segments
	var is_horizontal_edge := row == 0 or row == segments
	var anchor_step := far_vertex_spacing_m
	if is_vertical_edge and row % 2 != 0:
		var low_north := floorf(north / anchor_step) * anchor_step
		var high_north := low_north + anchor_step
		var t := clampf((north - low_north) / anchor_step, 0.0, 1.0)
		return _lerp_ground_samples(_sample_ground(east, low_north), _sample_ground(east, high_north), t)
	if is_horizontal_edge and column % 2 != 0:
		var low_east := floorf(east / anchor_step) * anchor_step
		var high_east := low_east + anchor_step
		var t := clampf((east - low_east) / anchor_step, 0.0, 1.0)
		return _lerp_ground_samples(_sample_ground(low_east, north), _sample_ground(high_east, north), t)
	return _sample_ground(east, north)


func _lerp_ground_samples(a: Dictionary, b: Dictionary, weight: float) -> Dictionary:
	if not bool(a.get("valid", false)) or not bool(b.get("valid", false)):
		return {"valid": false}
	return {
		"valid": true,
		"depth_m": lerpf(float(a["depth_m"]), float(b["depth_m"]), weight),
		"height_m": lerpf(float(a["height_m"]), float(b["height_m"]), weight),
	}


func _sample_ground(east: float, north: float) -> Dictionary:
	var depth_data := _sample_depth(east, north)
	if not bool(depth_data.get("valid", false)):
		return {"valid": false}
	var depth_m := float(depth_data.get("depth_m", INF))
	if depth_m < 0.0:
		return {"valid": false}
	var relief := _visual_relief(east, north)
	return {
		"valid": true,
		"depth_m": depth_m,
		"height_m": -(depth_m + water_surface_above_lat_m) + relief,
	}


func _sample_depth(east: float, north: float) -> Dictionary:
	return _bathymetry.get_depth_at_world_position(Vector3(east, 0.0, -north))


func _visual_relief(east: float, north: float) -> float:
	var broad := _value_noise(east, north, 0.0045, 811) - 0.5
	var fine := _value_noise(east, north, 0.022, 227) - 0.5
	return broad * 2.0 * broad_relief_amplitude_m + fine * 2.0 * fine_relief_amplitude_m


func _vertex_normal(
	key: Vector2i,
	east: float,
	north: float,
	row: int,
	column: int,
	segments: int,
	width: int,
	step: float,
	heights: PackedFloat32Array,
	validity: PackedByteArray,
	lod: int
) -> Vector3:
	if validity[row * width + column] == 0:
		return Vector3.UP
	var is_vertical_edge := column == 0 or column == segments
	var is_horizontal_edge := row == 0 or row == segments
	if lod == 0 and (is_vertical_edge or is_horizontal_edge):
		var anchor_step := far_vertex_spacing_m
		if is_vertical_edge and row % 2 != 0:
			var low_north := floorf(north / anchor_step) * anchor_step
			var t := clampf((north - low_north) / anchor_step, 0.0, 1.0)
			var low_normal := _world_edge_normal(east, low_north, anchor_step)
			var high_normal := _world_edge_normal(east, low_north + anchor_step, anchor_step)
			return low_normal.lerp(high_normal, t).normalized()
		if is_horizontal_edge and column % 2 != 0:
			var low_east := floorf(east / anchor_step) * anchor_step
			var t := clampf((east - low_east) / anchor_step, 0.0, 1.0)
			var low_normal := _world_edge_normal(low_east, north, anchor_step)
			var high_normal := _world_edge_normal(low_east + anchor_step, north, anchor_step)
			return low_normal.lerp(high_normal, t).normalized()
		return _world_edge_normal(east, north, anchor_step)

	var center := heights[row * width + column]
	var left := center
	var right := center
	var north_height := center
	var south := center
	var left_valid := column > 0 and validity[row * width + column - 1] == 1
	var right_valid := column < segments and validity[row * width + column + 1] == 1
	var north_valid := row > 0 and validity[(row - 1) * width + column] == 1
	var south_valid := row < segments and validity[(row + 1) * width + column] == 1
	if left_valid:
		left = heights[row * width + column - 1]
	if right_valid:
		right = heights[row * width + column + 1]
	if north_valid:
		north_height = heights[(row - 1) * width + column]
	if south_valid:
		south = heights[(row + 1) * width + column]
	var x_distance := step * (2.0 if left_valid and right_valid else 1.0)
	var z_distance := step * (2.0 if north_valid and south_valid else 1.0)
	var derivative_east := (right - left) / maxf(x_distance, 0.001)
	var derivative_south := (south - north_height) / maxf(z_distance, 0.001)
	return Vector3(-derivative_east, 1.0, -derivative_south).normalized()


func _world_edge_normal(east: float, north: float, step: float) -> Vector3:
	var center := _sample_height_or_zero(east, north)
	var east_plus := _sample_height_or_center(east + step, north, center)
	var east_minus := _sample_height_or_center(east - step, north, center)
	var north_plus := _sample_height_or_center(east, north + step, center)
	var north_minus := _sample_height_or_center(east, north - step, center)
	var d_east := (east_plus - east_minus) / (2.0 * step)
	var d_north := (north_plus - north_minus) / (2.0 * step)
	return Vector3(-d_east, 1.0, d_north).normalized()


func _sample_height_or_zero(east: float, north: float) -> float:
	var sample := _sample_ground(east, north)
	return float(sample.get("height_m", 0.0)) if bool(sample.get("valid", false)) else 0.0


func _sample_height_or_center(east: float, north: float, center: float) -> float:
	var sample := _sample_ground(east, north)
	return float(sample.get("height_m", center)) if bool(sample.get("valid", false)) else center


func _grid_slope(row: int, column: int, width: int, step: float, heights: PackedFloat32Array, validity: PackedByteArray) -> float:
	var index := row * width + column
	var center := heights[index]
	var left := center
	var right := center
	var north_height := center
	var south := center
	if column > 0 and validity[index - 1] == 1:
		left = heights[index - 1]
	if column + 1 < width and validity[index + 1] == 1:
		right = heights[index + 1]
	if row > 0 and validity[index - width] == 1:
		north_height = heights[index - width]
	if row + 1 < width and validity[index + width] == 1:
		south = heights[index + width]
	var d_east := absf(right - left) / maxf(step * 2.0, 0.001)
	var d_south := absf(south - north_height) / maxf(step * 2.0, 0.001)
	return sqrt(d_east * d_east + d_south * d_south)


func _material_weights(east: float, north: float, depth: float, slope: float, lod: int) -> Color:
	var geology := _value_noise(east, north, 0.0036, 501) * 0.62 + _value_noise(east, north, 0.010, 793) * 0.38
	var slope_rock := smoothstep(0.012, 0.055, slope)
	var rock := clampf(smoothstep(0.57, 0.78, geology) * 0.63 + slope_rock * 0.40, 0.0, 0.86)
	var patch := _value_noise(east, north, 0.006, 1987)
	var mud_zone := smoothstep(2.8, 6.2, depth)
	var mud := clampf(mud_zone * (0.20 + 0.28 * (1.0 - patch)) * (1.0 - rock), 0.0, 0.62)
	var sand := maxf(1.0 - rock - mud, 0.0)
	var sum_weights := maxf(sand + mud + rock, 0.001)
	return Color(sand / sum_weights, mud / sum_weights, rock / sum_weights, 1.0 if lod == 0 else 0.0)


func _constrain_near_edge_colors(colors: PackedColorArray, depths: PackedFloat32Array, validity: PackedByteArray, width: int, segments: int) -> void:
	for row in range(width):
		for column in range(width):
			var on_vertical := column == 0 or column == segments
			var on_horizontal := row == 0 or row == segments
			var lower_index := -1
			var upper_index := -1
			var current_index := row * width + column
			if on_vertical and row % 2 != 0:
				lower_index = (row - 1) * width + column
				upper_index = (row + 1) * width + column
			elif on_horizontal and column % 2 != 0:
				lower_index = row * width + column - 1
				upper_index = row * width + column + 1
			if lower_index >= 0 and validity[lower_index] == 1 and validity[upper_index] == 1:
				colors[current_index] = colors[lower_index].lerp(colors[upper_index], 0.5)
				depths[current_index] = lerpf(depths[lower_index], depths[upper_index], 0.5)


func _triangle_is_valid(indices: Array[int], depths: PackedFloat32Array, validity: PackedByteArray) -> bool:
	for index in indices:
		if validity[index] == 0 or depths[index] > mesh_depth_limit_m:
			return false
	return true


func _candidate_slope(east: float, north: float, center_depth: float) -> float:
	const sample_offset := 12.0
	var east_plus := _sample_depth(east + sample_offset, north)
	var east_minus := _sample_depth(east - sample_offset, north)
	var north_plus := _sample_depth(east, north + sample_offset)
	var north_minus := _sample_depth(east, north - sample_offset)
	var d_east := 0.0
	var d_north := 0.0
	if bool(east_plus.get("valid", false)) and bool(east_minus.get("valid", false)):
		d_east = (float(east_plus["depth_m"]) - float(east_minus["depth_m"])) / (sample_offset * 2.0)
	elif bool(east_plus.get("valid", false)):
		d_east = (float(east_plus["depth_m"]) - center_depth) / sample_offset
	elif bool(east_minus.get("valid", false)):
		d_east = (center_depth - float(east_minus["depth_m"])) / sample_offset
	if bool(north_plus.get("valid", false)) and bool(north_minus.get("valid", false)):
		d_north = (float(north_plus["depth_m"]) - float(north_minus["depth_m"])) / (sample_offset * 2.0)
	elif bool(north_plus.get("valid", false)):
		d_north = (float(north_plus["depth_m"]) - center_depth) / sample_offset
	elif bool(north_minus.get("valid", false)):
		d_north = (center_depth - float(north_minus["depth_m"])) / sample_offset
	return sqrt(d_east * d_east + d_north * d_north)


func _build_reef_payload(key: Vector2i, lod: int, east_min: float, north_min: float, north_max: float) -> Dictionary:
	return _build_cluster_reef_payload(key, lod, east_min, north_min, north_max)


func _empty_reef_payload() -> Dictionary:
	return {
		"asset_records": [],
		"cluster_debug": [],
		"cluster_count": 0,
		"asset_instances": {},
		"triangles": 0,
		"batches": 0,
		"instance_count": 0,
	}


func _build_cluster_reef_payload(key: Vector2i, lod: int, east_min: float, north_min: float, north_max: float) -> Dictionary:
	var definitions: Array[ShallowReefAssetDefinition] = []
	if reef_asset_library != null:
		definitions = reef_asset_library.definitions
	var asset_records: Array = []
	for _definition in definitions:
		asset_records.append([])
	var cluster_debug: Array[Dictionary] = []
	var cluster_count := 0
	if not enable_reef_clusters:
		return _finalize_reef_payload(asset_records, cluster_debug, 0)

	var spacing := maxf(reef_cluster_cell_spacing_m, 24.0)
	var max_radius := maxf(large_cluster_radius_m.y, medium_cluster_radius_m.y)
	var search_margin := max_radius * 1.25 + 3.0
	var cell_east_min := floori((east_min - search_margin) / spacing)
	var cell_east_max := floori((east_min + tile_size_m + search_margin) / spacing)
	var cell_north_min := floori((north_min - search_margin) / spacing)
	var cell_north_max := floori((north_max + search_margin) / spacing)
	var lod_density := rock_density_near if lod == 0 else rock_density_far
	for cell_north in range(cell_north_min, cell_north_max + 1):
		for cell_east in range(cell_east_min, cell_east_max + 1):
			var center_east := (float(cell_east) + 0.5 + (_hash01(cell_east, cell_north, REEF_CLUSTER_SEED + 1) - 0.5) * (reef_cluster_center_jitter_m / spacing)) * spacing
			var center_north := (float(cell_north) + 0.5 + (_hash01(cell_east, cell_north, REEF_CLUSTER_SEED + 2) - 0.5) * (reef_cluster_center_jitter_m / spacing)) * spacing
			if center_east < east_min - search_margin or center_east > east_min + tile_size_m + search_margin:
				continue
			if center_north < north_min - search_margin or center_north > north_max + search_margin:
				continue
			var depth_sample := _sample_depth(center_east, center_north)
			if not bool(depth_sample.get("valid", false)):
				continue
			var center_depth := float(depth_sample.get("depth_m", INF))
			if center_depth < 0.45 or center_depth > maximum_rock_depth_m:
				continue
			var slope := _candidate_slope(center_east, center_north, center_depth)
			var rockiness := _reef_rockiness(center_east, center_north, slope)
			var mud_weight := smoothstep(2.8, 6.2, center_depth) * 0.38 * (1.0 - rockiness)
			var chance := (reef_cluster_base_chance + reef_cluster_rocky_chance * rockiness) * lod_density * (1.0 - 0.72 * mud_weight)
			if _hash01(cell_east, cell_north, REEF_CLUSTER_SEED + 3) > chance:
				continue
			var radius := _cluster_radius(cell_east, cell_north, rockiness)
			var center_ground := _sample_ground(center_east, center_north)
			if not bool(center_ground.get("valid", false)):
				continue
			if _point_is_in_tile(center_east, center_north, east_min, north_min, north_max):
				cluster_count += 1
				cluster_debug.append({"east": center_east, "north": center_north, "ground_y": float(center_ground["height_m"]), "radius": radius})
			var module_count := _cluster_module_count(cell_east, cell_north, rockiness, radius)
			for module_index in range(module_count):
				var module_offset := _cluster_piece_offset(cell_east, cell_north, module_index, module_count, radius, 401)
				_add_reef_piece(
					asset_records, definitions, ShallowReefAssetDefinition.Role.REEF_MODULE,
					center_east + module_offset.x, center_north + module_offset.y,
					cell_east, cell_north, module_index, lod, east_min, north_min, north_max, slope, true
				)

			if enable_reef_fill_stones and maximum_fill_stones_per_cluster > 0:
				var fill_count := mini(maximum_fill_stones_per_cluster, 2 + int(round(rockiness * float(maximum_fill_stones_per_cluster - 2))))
				if lod != 0:
					fill_count = mini(fill_count, 2)
				for fill_index in range(fill_count):
					var fill_offset := _cluster_piece_offset(cell_east, cell_north, fill_index, fill_count, radius, 907)
					var angle := atan2(fill_offset.y, fill_offset.x)
					var spread := Vector2(cos(angle), sin(angle)) * (radius * (0.58 + _hash01(cell_east, cell_north, 1001 + fill_index) * 0.52))
					_add_reef_piece(
						asset_records, definitions, ShallowReefAssetDefinition.Role.SINGLE_STONE,
						center_east + spread.x, center_north + spread.y,
						cell_east, cell_north, 100 + fill_index, lod, east_min, north_min, north_max, slope, false
					)

	return _finalize_reef_payload(asset_records, cluster_debug, cluster_count)


func _add_reef_piece(
	asset_records: Array,
	definitions: Array[ShallowReefAssetDefinition],
	role: ShallowReefAssetDefinition.Role,
	east: float,
	north: float,
	cluster_cell_east: int,
	cluster_cell_north: int,
	piece_index: int,
	lod: int,
	east_min: float,
	north_min: float,
	north_max: float,
	cluster_slope: float,
	is_module: bool
) -> void:
	if not _point_is_in_tile(east, north, east_min, north_min, north_max):
		return
	var ground := _sample_ground(east, north)
	if not bool(ground.get("valid", false)):
		return
	var depth := float(ground.get("depth_m", INF))
	if depth < 0.45 or depth > maximum_rock_depth_m:
		return
	var slope := _candidate_slope(east, north, depth)
	var effective_slope := maxf(cluster_slope * 0.35, slope)
	var selected_index := _choose_reef_asset(definitions, role, effective_slope, lod, cluster_cell_east, cluster_cell_north, piece_index)
	if selected_index < 0 or selected_index >= _reef_asset_cache.size():
		return
	if not bool(_reef_asset_cache[selected_index].get("loaded", false)):
		return
	var definition: ShallowReefAssetDefinition = definitions[selected_index]
	var target_height := lerpf(definition.target_height_min_m, definition.target_height_max_m, _hash01(cluster_cell_east, cluster_cell_north, 1371 + piece_index))
	var burial_fraction := definition.burial_fraction
	var target_bounds: AABB = _reef_asset_cache[selected_index]["bounds"]
	var safe_height := maxf(-float(ground["height_m"]) - 0.35, 0.12)
	target_height = minf(target_height, safe_height)
	if target_bounds.size.y <= 0.001 or target_height < 0.12:
		return
	if definition != null and effective_slope > definition.maximum_placement_slope:
		return
	var scale_jitter := 0.10 if is_module else 0.18
	var scale_x_factor := 1.0 + (_hash01(cluster_cell_east, cluster_cell_north, 1401 + piece_index) - 0.5) * scale_jitter * 2.0
	var scale_z_factor := 1.0 + (_hash01(cluster_cell_east, cluster_cell_north, 1431 + piece_index) - 0.5) * scale_jitter * 2.0
	var scale := Vector3(scale_x_factor, 1.0, scale_z_factor)
	var normal := _candidate_normal(east, north)
	var yaw := _hash01(cluster_cell_east, cluster_cell_north, 1471 + piece_index) * TAU
	var basis := _reef_placement_basis(normal, yaw, scale * (target_height / maxf(target_bounds.size.y, 0.001)))
	var center_xz := Vector3(target_bounds.get_center().x, 0.0, target_bounds.get_center().z)
	var centered_bounds := AABB(target_bounds.position - center_xz, target_bounds.size)
	var transformed_bounds := ShallowReefGenerator._transformed_aabb(centered_bounds, Transform3D(basis, Vector3.ZERO))
	var burial_depth := target_height * burial_fraction
	var origin_y := float(ground["height_m"]) - burial_depth - transformed_bounds.position.y
	var transform := Transform3D(basis, Vector3(east - east_min, origin_y, north_max - north))
	var tint := 0.91 + _hash01(cluster_cell_east, cluster_cell_north, 1531 + piece_index) * 0.15
	var color := Color(tint, tint * (0.98 + _hash01(cluster_cell_east, cluster_cell_north, 1537 + piece_index) * 0.04), tint * (0.92 + _hash01(cluster_cell_east, cluster_cell_north, 1543 + piece_index) * 0.08), 1.0)
	asset_records[selected_index].append({
		"transform": transform,
		"color": color,
		"center_offset": Transform3D(Basis.IDENTITY, -center_xz),
	})


func _choose_reef_asset(
	definitions: Array[ShallowReefAssetDefinition],
	role: ShallowReefAssetDefinition.Role,
	slope: float,
	lod: int,
	cell_east: int,
	cell_north: int,
	piece_index: int
) -> int:
	var total_weight := 0.0
	for index in range(definitions.size()):
		var definition := definitions[index]
		if definition == null or not definition.enabled or definition.role != role or definition.selection_weight <= 0.0:
			continue
		if index >= _reef_asset_cache.size() or not bool(_reef_asset_cache[index].get("loaded", false)):
			continue
		if slope > definition.maximum_placement_slope or (lod != 0 and not definition.allow_far_lod):
			continue
		total_weight += definition.selection_weight
	if total_weight <= 0.0:
		return -1
	var roll := _hash01(cell_east, cell_north, 1601 + piece_index) * total_weight
	for index in range(definitions.size()):
		var definition := definitions[index]
		if definition == null or not definition.enabled or definition.role != role or definition.selection_weight <= 0.0:
			continue
		if index >= _reef_asset_cache.size() or not bool(_reef_asset_cache[index].get("loaded", false)):
			continue
		if slope > definition.maximum_placement_slope or (lod != 0 and not definition.allow_far_lod):
			continue
		roll -= definition.selection_weight
		if roll <= 0.0:
			return index
	return -1


func _reef_rockiness(east: float, north: float, slope: float) -> float:
	var geology := _value_noise(east, north, 0.0036, 501) * 0.62 + _value_noise(east, north, 0.010, 793) * 0.38
	var slope_rock := smoothstep(0.012, 0.055, slope)
	return clampf(smoothstep(0.54, 0.78, geology) * 0.72 + slope_rock * 0.32, 0.0, 1.0)


func _cluster_radius(cell_east: int, cell_north: int, rockiness: float) -> float:
	var tier := _hash01(cell_east, cell_north, REEF_CLUSTER_SEED + 5)
	var radius_range: Vector2
	if rockiness < 0.28 or tier < 0.12:
		radius_range = small_cluster_radius_m
	elif rockiness < 0.62 or tier < 0.58:
		radius_range = medium_cluster_radius_m
	else:
		radius_range = large_cluster_radius_m
	return lerpf(radius_range.x, radius_range.y, _hash01(cell_east, cell_north, REEF_CLUSTER_SEED + 6))


func _cluster_module_count(cell_east: int, cell_north: int, rockiness: float, radius: float) -> int:
	var count := 1
	if maximum_cluster_modules > 1 and radius >= large_cluster_radius_m.x and rockiness > 0.52:
		if _hash01(cell_east, cell_north, REEF_CLUSTER_SEED + 7) < 0.58:
			count += 1
	if maximum_cluster_modules > 2 and count > 1 and radius >= large_cluster_radius_m.x + 2.0 and rockiness > 0.76:
		if _hash01(cell_east, cell_north, REEF_CLUSTER_SEED + 8) < 0.35:
			count += 1
	return mini(count, maximum_cluster_modules)


func _cluster_piece_offset(cell_east: int, cell_north: int, piece_index: int, piece_count: int, radius: float, seed: int) -> Vector2:
	if piece_index == 0 or piece_count <= 1:
		return Vector2.ZERO
	var angle := _hash01(cell_east, cell_north, REEF_CLUSTER_SEED + seed + piece_index * 13) * TAU
	var radial := radius * (0.16 + _hash01(cell_east, cell_north, REEF_CLUSTER_SEED + seed + piece_index * 29) * 0.24)
	return Vector2(cos(angle), sin(angle)) * radial


func _candidate_normal(east: float, north: float) -> Vector3:
	const OFFSET := 8.0
	var east_plus := _sample_ground(east + OFFSET, north)
	var east_minus := _sample_ground(east - OFFSET, north)
	var north_plus := _sample_ground(east, north + OFFSET)
	var north_minus := _sample_ground(east, north - OFFSET)
	if not bool(east_plus.get("valid", false)) or not bool(east_minus.get("valid", false)) or not bool(north_plus.get("valid", false)) or not bool(north_minus.get("valid", false)):
		return Vector3.UP
	var gradient_east := (float(east_plus["height_m"]) - float(east_minus["height_m"])) / (OFFSET * 2.0)
	var gradient_north := (float(north_plus["height_m"]) - float(north_minus["height_m"])) / (OFFSET * 2.0)
	return Vector3(-gradient_east, 1.0, gradient_north).normalized()


func _reef_placement_basis(normal: Vector3, yaw: float, scale: Vector3) -> Basis:
	var up := normal.normalized()
	var forward := Vector3.FORWARD.rotated(Vector3.UP, yaw)
	forward = (forward - up * forward.dot(up)).normalized()
	if forward.length_squared() < 0.001:
		forward = Vector3.FORWARD
	var right := forward.cross(up).normalized()
	forward = up.cross(right).normalized()
	return Basis(right * scale.x, up * scale.y, -forward * scale.z)


func _point_is_in_tile(east: float, north: float, east_min: float, north_min: float, north_max: float) -> bool:
	return east >= east_min and east < east_min + tile_size_m and north >= north_min and north < north_max


func _finalize_reef_payload(asset_records: Array, cluster_debug: Array, cluster_count: int) -> Dictionary:
	var asset_instances: Dictionary = {}
	var triangles := 0
	var batches := 0
	var instance_count := 0
	var module_instances := 0
	var single_instances := 0
	var module_envelope_m3 := 0.0
	var single_envelope_m3 := 0.0
	for index in range(mini(asset_records.size(), _reef_asset_cache.size())):
		var records: Array = asset_records[index]
		if records.is_empty():
			continue
		var entry: Dictionary = _reef_asset_cache[index]
		var definition: ShallowReefAssetDefinition = entry["definition"]
		asset_instances[String(definition.asset_id)] = records.size()
		triangles += records.size() * int(entry.get("total_triangles", 0))
		batches += int(entry.get("parts", []).size())
		instance_count += records.size()
		var envelope: AABB = entry.get("bounds", AABB())
		var envelope_volume := envelope.size.x * envelope.size.y * envelope.size.z
		for record in records:
			var placement: Transform3D = record["transform"]
			var transformed_envelope_volume := envelope_volume * absf(placement.basis.determinant())
			if definition.role == ShallowReefAssetDefinition.Role.REEF_MODULE:
				module_instances += 1
				module_envelope_m3 += transformed_envelope_volume
			else:
				single_instances += 1
				single_envelope_m3 += transformed_envelope_volume
	return {
		"asset_records": asset_records,
		"cluster_debug": cluster_debug,
		"cluster_count": cluster_count,
		"asset_instances": asset_instances,
		"triangles": triangles,
		"batches": batches,
		"instance_count": instance_count,
		"module_instances": module_instances,
		"single_instances": single_instances,
		"module_envelope_m3": module_envelope_m3,
		"single_envelope_m3": single_envelope_m3,
	}


func _reef_payload_instance_count(payload: Dictionary) -> int:
	return int(payload.get("instance_count", 0))


func _attach_tile(key: Vector2i, lod: int, bundle: Dictionary) -> void:
	bundle["seagrass_payload"] = _empty_seagrass_payload()
	if _loaded_tiles.has(key):
		var previous: Dictionary = _loaded_tiles[key]
		_cache_bundle(key, int(previous["lod"]), previous["bundle"])
		previous["root"].visible = false
		previous["root"].queue_free()
		_loaded_tiles.erase(key)
	var east_min := float(key.x) * tile_size_m
	var north_min := float(key.y) * tile_size_m
	var north_max := north_min + tile_size_m
	var tile_root := Node3D.new()
	tile_root.name = "Seabed_%d_%d_%s" % [key.x, key.y, "Near" if lod == 0 else "Far"]
	tile_root.position = to_local(Vector3(east_min, 0.0, -north_max))
	add_child(tile_root)
	var seabed := MeshInstance3D.new()
	seabed.name = "SeabedMesh"
	seabed.mesh = bundle["mesh"]
	seabed.material_override = seabed_material
	seabed.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	tile_root.add_child(seabed)
	var rocks_root := Node3D.new()
	rocks_root.name = "Reefs"
	tile_root.add_child(rocks_root)
	var reef_metrics := _attach_reef_payload(rocks_root, key, bundle.get("reef_payload", _empty_reef_payload()))
	if _runtime_bounds_enabled:
		_add_chunk_bounds(tile_root)
	_loaded_tiles[key] = {
		"root": tile_root,
		"lod": lod,
		"triangles": int(bundle["triangles"]),
		"rocks": int(reef_metrics["instances"]),
		"reef_triangles": int(reef_metrics["triangles"]),
		"reef_clusters": int(bundle.get("reef_payload", {}).get("cluster_count", 0)),
		"reef_batches": int(reef_metrics["batches"]),
		"asset_instances": reef_metrics["instances_by_asset"],
		"key": key,
		"bundle": bundle,
		"seagrass_instances": 0,
		"seagrass_triangles": 0,
		"seagrass_batches": 0,
	}
	if _runtime_seagrass_enabled:
		_queue_seagrass_tile(key, _current_seagrass_focus())


func _release_tile(key: Vector2i, cache: bool) -> void:
	if not _loaded_tiles.has(key):
		return
	_seagrass_jobs.erase(key)
	_seagrass_job_queue.erase(key)
	var data: Dictionary = _loaded_tiles[key]
	if cache:
		_cache_bundle(key, int(data["lod"]), data["bundle"])
	if is_instance_valid(data.get("root")):
		data["root"].queue_free()
	_loaded_tiles.erase(key)


func _cache_bundle(key: Vector2i, lod: int, bundle: Dictionary) -> void:
	var cache_key := Vector3i(key.x, key.y, lod)
	_mesh_cache[cache_key] = bundle
	_mesh_cache_lru.erase(cache_key)
	_mesh_cache_lru.append(cache_key)
	while _mesh_cache_lru.size() > CACHE_LIMIT:
		var oldest: Vector3i = _mesh_cache_lru.pop_front()
		_mesh_cache.erase(oldest)


func _take_cached_bundle(cache_key: Vector3i) -> Dictionary:
	_mesh_cache_lru.erase(cache_key)
	_mesh_cache_lru.append(cache_key)
	return _mesh_cache[cache_key]


func _rebuild_active_reefs(rebuild_payload: bool) -> void:
	if rebuild_payload:
		_mesh_cache.clear()
		_mesh_cache_lru.clear()
	for tile_data in _loaded_tiles.values():
		var root := tile_data["root"] as Node3D
		var key: Vector2i = tile_data.get("key", INVALID_TILE)
		var lod := int(tile_data.get("lod", 1))
		var bundle: Dictionary = tile_data["bundle"]
		if rebuild_payload and key != INVALID_TILE:
			var east_min := float(key.x) * tile_size_m
			var north_min := float(key.y) * tile_size_m
			var north_max := north_min + tile_size_m
			bundle["reef_payload"] = _build_reef_payload(key, lod, east_min, north_min, north_max) if enable_reefs else _empty_reef_payload()
			bundle["rocks"] = _reef_payload_instance_count(bundle["reef_payload"])
			bundle["seagrass_payload"] = _empty_seagrass_payload()
			tile_data["bundle"] = bundle
		var old_reefs := root.get_node_or_null("Reefs")
		if old_reefs != null:
			old_reefs.queue_free()
		var reefs_root := Node3D.new()
		reefs_root.name = "Reefs"
		root.add_child(reefs_root)
		var metrics := _attach_reef_payload(reefs_root, key, bundle.get("reef_payload", _empty_reef_payload()))
		tile_data["rocks"] = int(metrics["instances"])
		tile_data["reef_triangles"] = int(metrics["triangles"])
		tile_data["reef_clusters"] = int(bundle.get("reef_payload", {}).get("cluster_count", 0))
		tile_data["reef_batches"] = int(metrics["batches"])
		tile_data["asset_instances"] = metrics["instances_by_asset"]
	if rebuild_payload and _runtime_seagrass_enabled:
		_refresh_seagrass_stream(true)


func _attach_reef_payload(parent: Node3D, key: Vector2i, payload: Dictionary) -> Dictionary:
	var metrics := {"instances": 0, "triangles": 0, "batches": 0, "instances_by_asset": {}}
	if not _runtime_reefs_enabled:
		return metrics
	var asset_result := ShallowReefGenerator.add_glb_chunk_multimeshes(
		parent, _reef_asset_cache, payload.get("asset_records", []), true, tile_size_m
	)
	metrics["instances"] = int(asset_result["instances"])
	metrics["triangles"] = int(asset_result["triangles"])
	metrics["batches"] = int(asset_result["batches"])
	metrics["instances_by_asset"] = asset_result["instances_by_asset"]
	if _runtime_cluster_debug:
		var east_min := float(key.x) * tile_size_m
		var north_max := float(key.y + 1) * tile_size_m
		ShallowReefGenerator.add_cluster_debug_mesh(parent, payload.get("cluster_debug", []), east_min, north_max, tile_size_m)
	return metrics


func _count_loaded_reef_assets() -> int:
	var count := 0
	for entry in _reef_asset_cache:
		if bool(entry.get("loaded", false)):
			count += 1
	return count


func _add_chunk_bounds(tile_root: Node3D) -> void:
	if tile_root.get_node_or_null("DebugBounds") != null:
		return
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.76, 0.88, 0.38, 0.85)
	material.no_depth_test = true
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	var x0 := 0.0
	var x1 := tile_size_m
	var z0 := 0.0
	var z1 := tile_size_m
	var y0 := 0.20
	var y1 := -mesh_depth_limit_m
	var corners := [
		Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(x0, y0, z1),
		Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(x0, y1, z1),
	]
	var edges := PackedInt32Array([0, 1, 1, 2, 2, 3, 3, 0, 4, 5, 5, 6, 6, 7, 7, 4, 0, 4, 1, 5, 2, 6, 3, 7])
	for edge_index in range(0, edges.size(), 2):
		mesh.surface_add_vertex(corners[edges[edge_index]])
		mesh.surface_add_vertex(corners[edges[edge_index + 1]])
	mesh.surface_end()
	var bounds := MeshInstance3D.new()
	bounds.name = "DebugBounds"
	bounds.mesh = mesh
	bounds.visible = _runtime_bounds_enabled
	bounds.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	tile_root.add_child(bounds)


func _set_tile_bounds_visible(tile_data: Dictionary, bounds_visible: bool) -> void:
	var root: Node3D = tile_data["root"]
	var bounds := root.get_node_or_null("DebugBounds") as MeshInstance3D
	if bounds_visible and bounds == null:
		_add_chunk_bounds(root)
	elif bounds != null:
		bounds.visible = bounds_visible


func _toggle_water_transparency() -> void:
	if water_material == null:
		return
	var currently_enabled := bool(water_material.get_shader_parameter("shallow_transparency_enabled"))
	water_material.set_shader_parameter("shallow_transparency_enabled", not currently_enabled)
	print("[ShallowSeabed] Shallow water transmission: %s" % ("ON" if not currently_enabled else "OFF"))


func _build_statistics_ui() -> void:
	_stats_layer = CanvasLayer.new()
	_stats_layer.name = "ShallowSeabedDebugLayer"
	_stats_layer.layer = 12
	_stats_layer.visible = show_statistics
	add_child(_stats_layer)
	var panel := PanelContainer.new()
	panel.name = "StatisticsPanel"
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.offset_left = -500.0
	panel.offset_top = 16.0
	panel.offset_right = -16.0
	panel.offset_bottom = 386.0
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.018, 0.065, 0.082, 0.92)
	style.border_color = Color(0.36, 0.68, 0.66, 0.82)
	style.set_border_width_all(1)
	style.set_corner_radius_all(7)
	style.set_content_margin_all(10.0)
	panel.add_theme_stylebox_override("panel", style)
	_stats_layer.add_child(panel)
	_stats_label = Label.new()
	_stats_label.add_theme_color_override("font_color", Color(0.88, 0.94, 0.89))
	_stats_label.add_theme_font_size_override("font_size", 12)
	panel.add_child(_stats_label)


func _update_statistics_text() -> void:
	if _stats_label == null or not _runtime_statistics_enabled:
		return
	var stats := get_debug_stats()
	_stats_label.text = "SHALLOW SEABED · %s\n" % ("ON" if bool(stats["enabled"]) else "OFF")
	_stats_label.text += "Chunks %d active / %d · near %d / far %d\n" % [stats["active_chunks"], stats["loaded_chunks"], stats["near_lod_chunks"], stats["far_lod_chunks"]]
	_stats_label.text += "Seabed tris %d · queued %d\n" % [stats["loaded_triangles"], stats["pending_tiles"]]
	_stats_label.text += "GLB reefs · %d groups · %d modules + %d singles\n" % [stats["reef_clusters"], stats["module_instances"], stats["single_instances"]]
	_stats_label.text += "Reef instances %d · %d batches\n" % [stats["rock_instances"], stats["reef_batches"]]
	_stats_label.text += "Reef tris %d · GLB assets %d/8\n" % [stats["reef_triangles"], stats["glb_assets_loaded"]]
	_stats_label.text += _asset_counts_text(stats["asset_instances"])
	_stats_label.text += "Eelgrass %d · algae %d · patches %d · %d tris\n" % [stats["eelgrass_instances"], stats["algae_instances"], stats["seagrass_patches"], stats["seagrass_triangles"]]
	_stats_label.text += "Core %.0f%% · patch extent %.0f%% · canopy in patches est. %.0f%%\n" % [stats["seagrass_estimated_meadow_coverage_percent"], stats["seagrass_estimated_patch_extent_percent"], stats["seagrass_estimated_canopy_coverage_percent"]]
	_stats_label.text += "Density target %.0f/%.0f · generated %.1f/m² · patch %.0f m²\n" % [stats["seagrass_target_edge_density_per_m2"], stats["seagrass_target_core_density_per_m2"], stats["seagrass_generated_density_per_patch_m2"], stats["seagrass_patch_area_m2"]]
	_stats_label.text += "Grass view radius %.0fm · layout v%d · builds queued %d\n" % [stats["seagrass_visible_radius_m"], stats["seagrass_layout_version"], stats["seagrass_builds_pending"]]
	_stats_label.text += "Grass %s · sway %s · %s · tile CPU %.0f ms avg\n" % ["ON" if stats["seagrass_enabled"] else "OFF", "ON" if stats["seagrass_sway_enabled"] else "OFF", _seagrass_density_name(int(stats["seagrass_density_preset"])), stats["seagrass_average_build_ms"]]
	_stats_label.text += "Grass slice %.1f/%.1f ms · finish max %.1f · budget %.1f\n" % [stats["seagrass_last_slice_ms"], stats["seagrass_maximum_slice_ms"], stats["seagrass_maximum_finish_ms"], stats["seagrass_generation_budget_ms"]]
	_stats_label.text += "Build %.2f ms last · %.2f ms avg\n" % [stats["last_chunk_build_ms"], stats["average_chunk_build_ms"]]
	_stats_label.text += "F6 water · F7 seabed · F8 stats · Shift+F8 bounds\nCtrl+F8 reefs · Alt+F8 LOD · F9 reef groups\nCtrl+F9 fill stones · Alt+F9 cluster guides\nF11 grass · Shift+F11 sway · Ctrl+F11 density · Alt+F11 guides"


func _seagrass_density_name(preset: int) -> String:
	match preset:
		0:
			return "Sparse"
		2:
			return "Dense"
		_:
			return "Normal"


func _asset_counts_text(counts: Dictionary) -> String:
	if counts.is_empty():
		return "Assets: none\n"
	var short_names := {
		"rock_small_round": "small",
		"rock_medium_round": "medium",
		"rock_flat": "flat",
		"rock_irregular": "irregular",
		"reef_two_rocks": "two",
		"reef_three_rocks": "three",
		"reef_low_bedrock": "bedrock",
		"reef_layered_slabs": "slabs",
	}
	var parts: Array[String] = []
	for asset_id in short_names.keys():
		var count := int(counts.get(asset_id, 0))
		if count > 0:
			parts.append("%s %d" % [short_names[asset_id], count])
	var split_index := mini(parts.size(), 4)
	var first_line := "Assets: " + " · ".join(parts.slice(0, split_index))
	var second_line := " · ".join(parts.slice(split_index))
	if second_line.is_empty():
		return first_line + "\n"
	return first_line + "\n         " + second_line + "\n"


func _get_boat_tile() -> Vector2i:
	var east := _boat.global_position.x
	var north := -_boat.global_position.z
	return Vector2i(floori(east / tile_size_m), floori(north / tile_size_m))


func _count_lod_chunks(lod: int) -> int:
	var count := 0
	for tile_data in _loaded_tiles.values():
		if int(tile_data.get("lod", -1)) == lod:
			count += 1
	return count


func _depth_text(depth_data: Dictionary) -> String:
	if not bool(depth_data.get("valid", false)):
		return "unknown"
	return "%.2f m LAT" % float(depth_data.get("depth_m", -1.0))


func _value_noise(east: float, north: float, frequency: float, seed: int) -> float:
	var px := east * frequency
	var py := north * frequency
	var ix := floori(px)
	var iy := floori(py)
	var tx := px - float(ix)
	var ty := py - float(iy)
	tx = tx * tx * (3.0 - 2.0 * tx)
	ty = ty * ty * (3.0 - 2.0 * ty)
	var a := _hash01(ix, iy, seed)
	var b := _hash01(ix + 1, iy, seed)
	var c := _hash01(ix, iy + 1, seed)
	var d := _hash01(ix + 1, iy + 1, seed)
	return lerpf(lerpf(a, b, tx), lerpf(c, d, tx), ty)


func _hash01(x: int, y: int, seed: int) -> float:
	var value := sin(float(x) * 127.1 + float(y) * 311.7 + float(seed) * 74.7) * 43758.5453
	return value - floor(value)
