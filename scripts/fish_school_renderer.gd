class_name FishSchoolRenderer
extends Node3D

## Client-side display of nearby shared school resources. School steering and
## fish transforms are sampled at a low rate; visible MultiMesh transforms are
## interpolated every render frame. Body sway remains in the vertex shader.

const SWIM_SHADER := preload("res://shaders/fish_swim.gdshader")
const SURFACE_ACTIVITY_SCRIPT := preload("res://scripts/fish_surface_activity.gd")
const MAX_SURFACE_FISH_REVEAL_SCHOOLS := 8
const AUTHORITY_SCHOOL_DRIFT_SCALE := 0.16
const SCHOOL_MOTION_VISUAL_RESPONSE := 8.0
const SCHOOL_MOTION_CORRECTION_DECAY := 1.25
const SURFACE_FISH_TURN_SPEED_FACTOR := 0.60
const SURFACE_FISH_ACCELERATION_FACTOR := 0.60

@export_range(100.0, 2400.0, 50.0) var render_radius_m := 1200.0
@export_range(50, 700, 10) var maximum_visible_fish := 360
@export_range(0.05, 0.5, 0.01) var movement_update_interval := 0.16
@export_range(1.0, 30.0, 1.0) var boat_exclusion_radius_m := 5.0
@export var animation_enabled := true
@export var smooth_motion_enabled := true
@export_category("Stickleback disturbance")
@export_range(10.0, 100.0, 1.0) var stickleback_alert_radius_m := 48.0
@export_range(5.0, 40.0, 1.0) var stickleback_scatter_radius_m := 18.0
@export_range(0.05, 0.8, 0.01) var stickleback_alert_threshold := 0.20
@export_range(0.2, 0.95, 0.01) var stickleback_scatter_threshold := 0.56
@export_range(0.05, 0.6, 0.01) var stickleback_scatter_exit_threshold := 0.28
@export_range(3.0, 8.0, 0.25) var stickleback_regroup_min_seconds := 6.0
@export_range(8.0, 16.0, 0.25) var stickleback_regroup_max_seconds := 12.0
@export_range(1.0, 8.0, 0.25) var stickleback_scatter_radius_extension_m := 4.0
@export var disturbance_source_group := "fish_disturbance_source"
@export_category("Needlefish and herring disturbance")
@export_range(5.0, 30.0, 1.0) var surface_fish_alert_radius_m := 15.0
@export_range(4.0, 20.0, 1.0) var surface_fish_scatter_radius_m := 10.0
@export_range(2.0, 12.0, 1.0) var surface_fish_emergency_radius_m := 5.0
@export_range(2.0, 10.0, 0.5) var surface_fish_scatter_extension_m := 5.0
@export_range(100.0, 5000.0, 100.0) var observation_search_radius_m := 5000.0
@export_range(250.0, 3000.0, 250.0) var preferred_observation_search_radius_m := 1500.0

var _manager: FishResourceManager
var _bathymetry: BathymetryManager
var _seabed_manager: ShallowSeabedManager
var _boat: Node3D
var _wave_sampler: WaveSampler
var _profiles: Array[FishSpeciesProfile] = []
var _species_visuals: Dictionary = {}
var _individual_states: Dictionary = {}
var _elapsed := 0.0
var _animation_clock := 0.0
var _revision_seen := -1
var _visible_fish_count := 0
var _last_update_ms := 0.0
var _last_ai_update_ms := 0.0
var _last_multimesh_submit_ms := 0.0
var _last_visual_update_ms := 0.0
var _movement_tick_count := 0
var _visual_transition_duration := 0.16
var _observation_camera: Camera3D
var _return_camera: Camera3D
var _observation_school_id := ""
var _authoritative_disturbance_snapshot: Array[Dictionary] = []
var _has_authoritative_disturbance_snapshot := false
var _last_disturbance_positions: Dictionary = {}
var _school_render_states: Dictionary = {}
var _surface_school_motion_states: Dictionary = {}
var _logical_school_counts := {"needlefish": 0, "herring": 0}
var _visual_school_counts := {"needlefish": 0, "herring": 0}
var _near_surface_school_count := 0
var _surface_activity: Node
var _surface_school_records: Array[Dictionary] = []
var _surface_reveal_candidates: Array[Dictionary] = []
var _water_material: ShaderMaterial
var _surface_reveal_spheres := PackedVector4Array()


func _ready() -> void:
	visible = true


func configure(manager: FishResourceManager, bathymetry: BathymetryManager, boat: Node3D, wave_sampler: WaveSampler, profiles: Array[FishSpeciesProfile], seabed_manager: ShallowSeabedManager = null) -> void:
	_manager = manager
	_bathymetry = bathymetry
	_seabed_manager = seabed_manager
	_boat = boat
	_wave_sampler = wave_sampler
	_profiles = profiles.duplicate()
	_water_material = bathymetry.water_material if bathymetry != null else null
	_surface_reveal_spheres.resize(MAX_SURFACE_FISH_REVEAL_SCHOOLS)
	_build_species_visuals()
	_surface_activity = SURFACE_ACTIVITY_SCRIPT.new()
	_surface_activity.name = "FishSurfaceActivity"
	add_child(_surface_activity)
	_surface_activity.call("configure", _wave_sampler, _boat)
	_revision_seen = manager.get_state_revision()


func set_animation_enabled(enabled: bool) -> void:
	animation_enabled = enabled
	for record in _species_visuals.values():
		var material: ShaderMaterial = record["material"]
		material.set_shader_parameter("animation_enabled", enabled)


func set_smooth_motion_enabled(enabled: bool) -> void:
	smooth_motion_enabled = enabled
	if not smooth_motion_enabled:
		_render_visible_fish(1.0)


## Debug-only underwater view for inspecting real school instances at their
## ecological depth. It changes neither authority state nor water rendering.
func begin_observation(school_id: String) -> bool:
	if _manager == null:
		return false
	var school := _manager.get_school(school_id)
	if school.is_empty():
		return false
	var species_id := str(school.get("species_id", ""))
	if species_id in ["needlefish", "herring"] and float(school.get("activity_depth_m", 99.0)) > 6.0:
		return false
	if _observation_camera == null:
		_return_camera = get_viewport().get_camera_3d()
		_observation_camera = Camera3D.new()
		_observation_camera.name = "FishObservationCamera"
		_observation_camera.fov = 52.0
		_observation_camera.near = 0.05
		_observation_camera.far = 180.0
		_observation_camera.cull_mask = 0xFFFFF
		add_child(_observation_camera)
	_observation_school_id = school_id
	_update_observation_camera(school)
	_observation_camera.make_current()
	return true


func end_observation() -> void:
	if _observation_camera == null:
		return
	if is_instance_valid(_return_camera) and _return_camera.is_inside_tree():
		_return_camera.make_current()
	elif _manager != null and _manager.get_boat() != null:
		var boat_parent := _manager.get_boat().get_parent()
		var fallback_camera := boat_parent.get_node_or_null("FollowCameraRig/Camera3D") as Camera3D if boat_parent != null else null
		if fallback_camera != null:
			fallback_camera.make_current()
	_observation_camera.queue_free()
	_observation_camera = null
	_return_camera = null
	_observation_school_id = ""


func is_observation_active() -> bool:
	return _observation_camera != null and is_instance_valid(_observation_camera)


func get_observation_school_id() -> String:
	return _observation_school_id


## A network adapter can feed the same shared threat snapshot to every client.
## Each item contains `id`, `world_position` and `velocity` as Vector3 values or
## three-number arrays. Calling this with an empty list means no current threats.
func set_authoritative_disturbance_snapshot(sources: Array[Dictionary]) -> void:
	_authoritative_disturbance_snapshot.clear()
	for source in sources:
		_authoritative_disturbance_snapshot.append(source.duplicate(true))
	_has_authoritative_disturbance_snapshot = true


## Used by the local single-player authority or when no server snapshot is set.
func use_local_disturbance_sources() -> void:
	_authoritative_disturbance_snapshot.clear()
	_has_authoritative_disturbance_snapshot = false


func get_school_visual_debug(school_id: String) -> Dictionary:
	if _manager == null:
		return {}
	var school := _manager.get_school(school_id)
	if school.is_empty():
		return {}
	var profile := _manager.get_species_profile(str(school.get("species_id", "")))
	var position_values: Array = school.get("world_position", [])
	if profile == null or position_values.size() < 3:
		return {}
	var school_position := Vector3(float(position_values[0]), 0.0, float(position_values[2]))
	var depth_m := float(school.get("depth_m", 0.0))
	var activity_depth_m := float(school.get("activity_depth_m", _vertical_depth_offset(profile, depth_m, 0.0)))
	var surface_height := _surface_height(school_position)
	var fish_count := 0
	var state_counts: Dictionary = {}
	var total_visual_length := 0.0
	var total_surface_depth := 0.0
	var total_threat_level := 0.0
	for key_variant in _individual_states.keys():
		var key := str(key_variant)
		if not key.begins_with(school_id + ":"):
			continue
		var state: Dictionary = _individual_states[key_variant]
		fish_count += 1
		total_visual_length += float(state.get("visual_length_m", profile.target_visual_length_m))
		var state_name := str(state.get("disturbance_state", state.get("behavior_state", "unknown"))) if profile.species_id == "three_spined_stickleback" else str(state.get("behavior_state", "unknown"))
		state_counts[state_name] = int(state_counts.get(state_name, 0)) + 1
		total_threat_level += float(state.get("threat_level", 0.0))
		var transform: Transform3D = state.get("visual_to_transform", Transform3D.IDENTITY)
		total_surface_depth += surface_height - transform.origin.y
	var visible_in_school := _visible_count_for_school(school_id, str(school.get("species_id", "")))
	var average_depth := total_surface_depth / float(fish_count) if fish_count > 0 else activity_depth_m
	if profile.species_id in ["needlefish", "herring"] and fish_count == 0:
		average_depth = activity_depth_m
	return {
		"school_population": int(school.get("population", 0)),
		"visible_fish": visible_in_school,
		"visualized_fish": fish_count,
		"average_visual_length_m": total_visual_length / float(fish_count) if fish_count > 0 else profile.target_visual_length_m,
		"depth_from_surface_m": average_depth,
		"bathymetry_depth_m": depth_m,
		"activity_depth_m": average_depth,
		"surface_activity_state": str(school.get("surface_activity_state", "unknown")),
		"activity_label": str(school.get("surface_activity_state", school.get("movement_state", "cruise"))) if profile.species_id in ["needlefish", "herring"] else str(school.get("movement_state", "cruise")),
		"render_state": _render_state_for_activity_depth(average_depth) if profile.species_id in ["needlefish", "herring"] else "visual",
		"seabed_clearance_m": maxf(0.0, depth_m - average_depth),
		"behavior_counts": state_counts,
		"average_threat_level": total_threat_level / float(fish_count) if fish_count > 0 else 0.0,
		"habitat_region": str(school.get("habitat_region", "unknown")),
	}


func _visible_count_for_school(school_id: String, species_id: String) -> int:
	var visual: Dictionary = _species_visuals.get(species_id, {})
	if visual.is_empty():
		return 0
	var count := 0
	for key in visual.get("instance_keys", []):
		if str(key).begins_with(school_id + ":"):
			count += 1
	return count


func get_render_statistics() -> Dictionary:
	var triangles := 0
	var visible_fish := 0
	for record in _species_visuals.values():
		var renderer: MultiMeshInstance3D = record["renderer"]
		if not visible or not renderer.is_visible_in_tree():
			continue
		var multimesh: MultiMesh = record["multimesh"]
		var mesh: Mesh = record["mesh"]
		var per_fish := 0
		for surface in range(mesh.get_surface_count()):
			var arrays: Array = mesh.surface_get_arrays(surface)
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			per_fish += indices.size() / 3 if not indices.is_empty() else mesh.surface_get_array_len(surface) / 3
		triangles += per_fish * multimesh.visible_instance_count
		visible_fish += multimesh.visible_instance_count
	return {
		"visible_fish": visible_fish,
		"triangles": triangles,
		"multimesh_batches": _species_visuals.size(),
		"last_update_ms": _last_update_ms,
		"ai_update_ms": _last_ai_update_ms,
		"multimesh_submit_ms": _last_multimesh_submit_ms,
		"visual_update_ms": _last_visual_update_ms,
		"movement_tick_count": _movement_tick_count,
		"movement_update_hz": 1.0 / maxf(movement_update_interval, 0.001),
		"logical_needlefish_schools": int(_logical_school_counts.get("needlefish", 0)),
		"visual_needlefish_schools": int(_visual_school_counts.get("needlefish", 0)),
		"logical_herring_schools": int(_logical_school_counts.get("herring", 0)),
		"visual_herring_schools": int(_visual_school_counts.get("herring", 0)),
		"near_surface_schools": _near_surface_school_count,
		"surface_ripple_count": int(_surface_activity.call("get_active_ripple_count")) if _surface_activity != null else 0,
		"smooth_motion_enabled": smooth_motion_enabled,
	}


func get_motion_timing_snapshot() -> Dictionary:
	return {
		"movement_tick_count": _movement_tick_count,
		"movement_update_hz": 1.0 / maxf(movement_update_interval, 0.001),
		"ai_update_ms": _last_ai_update_ms,
		"multimesh_submit_ms": _last_multimesh_submit_ms,
		"visual_update_ms": _last_visual_update_ms,
		"smooth_motion_enabled": smooth_motion_enabled,
	}


func _process(delta: float) -> void:
	if _manager == null or _boat == null:
		return
	_animation_clock += delta
	if is_observation_active():
		var observed_school := _manager.get_school(_observation_school_id)
		if observed_school.is_empty():
			end_observation()
		else:
			_update_observation_camera(observed_school)
	_elapsed += delta
	var ticked := false
	if _elapsed >= movement_update_interval:
		var step := _elapsed
		_elapsed = fmod(_elapsed, movement_update_interval)
		var start_usec := Time.get_ticks_usec()
		_update_visible_fish(step)
		_last_ai_update_ms = float(Time.get_ticks_usec() - start_usec) / 1000.0
		_visual_transition_duration = maxf(step, 0.001)
		_movement_tick_count += 1
		ticked = true
	if smooth_motion_enabled or ticked:
		var alpha := 1.0
		if smooth_motion_enabled:
			alpha = clampf(_elapsed / maxf(_visual_transition_duration, 0.001), 0.0, 1.0)
		var submit_start_usec := Time.get_ticks_usec()
		_render_visible_fish(alpha)
		_last_multimesh_submit_ms = float(Time.get_ticks_usec() - submit_start_usec) / 1000.0
		_last_visual_update_ms = _last_multimesh_submit_ms
	_last_update_ms = _last_ai_update_ms + _last_multimesh_submit_ms


func _update_observation_camera(school: Dictionary) -> void:
	if _observation_camera == null or _manager == null:
		return
	var position_data: Array = school.get("world_position", [])
	if position_data.size() != 3:
		return
	var school_position := Vector3(float(position_data[0]), 0.0, float(position_data[2]))
	var profile := _manager.get_species_profile(str(school.get("species_id", "")))
	var bathymetry_depth := maxf(0.1, float(school.get("depth_m", 0.1)))
	if _bathymetry != null:
		var sample := _bathymetry.get_depth_at_world_position(school_position)
		if bool(sample.get("valid", false)):
			bathymetry_depth = float(sample.get("depth_m", bathymetry_depth))
	var surface_height := _surface_height(school_position)
	var fish_depth := bathymetry_depth * 0.30 if profile == null else _vertical_depth_offset(profile, bathymetry_depth, 0.0)
	if str(school.get("species_id", "")) in ["needlefish", "herring"]:
		fish_depth = float(school.get("activity_depth_m", fish_depth))
	var target := Vector3(school_position.x, surface_height - fish_depth, school_position.z)
	var state_position_sum := Vector3.ZERO
	var state_position_count := 0
	for key_variant in _individual_states.keys():
		var key := str(key_variant)
		if not key.begins_with(_observation_school_id + ":"):
			continue
		var state: Dictionary = _individual_states[key_variant]
		var transform: Transform3D = state.get("visual_to_transform", Transform3D.IDENTITY)
		state_position_sum += transform.origin
		state_position_count += 1
	if state_position_count > 0:
		target = state_position_sum / float(state_position_count)
	var heading := float(school.get("direction_radians", 0.0))
	var forward := Vector3(cos(heading), 0.0, sin(heading)).normalized()
	var is_stickleback := str(school.get("species_id", "")) == "three_spined_stickleback"
	var horizontal_distance := 2.7 if is_stickleback else (8.0 if str(school.get("species_id", "")) == "herring" else 6.5)
	var camera_lift := 0.35 if is_stickleback else 1.7
	if is_stickleback:
		_observation_camera.fov = 58.0
	var camera_position: Vector3
	if is_stickleback:
		# The debug boat now sits over this shallow school. Observe from the side
		# of its keel so the hull does not fill the underwater view.
		var side := Vector3(-forward.z, 0.0, forward.x)
		camera_position = target + side * 6.5 + Vector3.UP * camera_lift
	else:
		camera_position = target - forward * horizontal_distance + Vector3.UP * camera_lift
	# Keep the observer underwater even for near-surface species.
	camera_position.y = minf(camera_position.y, surface_height - 0.35)
	_observation_camera.global_position = camera_position
	_observation_camera.look_at(target, Vector3.UP)


func _get_disturbance_sources(delta: float) -> Array[Dictionary]:
	if _has_authoritative_disturbance_snapshot:
		return _authoritative_disturbance_snapshot.duplicate(false)
	var candidates: Array[Node3D] = []
	if is_instance_valid(_boat):
		candidates.append(_boat)
	for candidate in get_tree().get_nodes_in_group(disturbance_source_group):
		var source := candidate as Node3D
		if source != null and source != _boat and not candidates.has(source):
			candidates.append(source)
	var result: Array[Dictionary] = []
	var active_ids: Dictionary = {}
	for source in candidates:
		if not is_instance_valid(source) or not source.is_inside_tree():
			continue
		var source_id := str(source.get_instance_id())
		active_ids[source_id] = true
		var position := source.global_position
		var velocity := Vector3.ZERO
		if source.has_method("get_fish_disturbance_snapshot"):
			var snapshot: Dictionary = source.call("get_fish_disturbance_snapshot")
			position = _snapshot_vector3(snapshot.get("world_position", position), position)
			velocity = _snapshot_vector3(snapshot.get("velocity", Vector3.ZERO), Vector3.ZERO)
		elif source is CharacterBody3D:
			velocity = (source as CharacterBody3D).velocity
		elif source is RigidBody3D:
			velocity = (source as RigidBody3D).linear_velocity
		elif source == _boat:
			var speed := _get_numeric_node_property(source, "speed_mps", 0.0)
			var forward := -source.global_transform.basis.z
			forward.y = 0.0
			velocity = forward.normalized() * speed
		else:
			var previous: Vector3 = _last_disturbance_positions.get(source_id, position)
			var displacement := position - previous
			if delta > 0.0001 and displacement.length() <= 20.0:
				velocity = displacement / delta
		_last_disturbance_positions[source_id] = position
		result.append({"id": source_id, "world_position": position, "velocity": velocity})
	for source_id_variant in _last_disturbance_positions.keys():
		if not active_ids.has(str(source_id_variant)):
			_last_disturbance_positions.erase(source_id_variant)
	return result


func _get_numeric_node_property(node: Object, property_name: String, fallback: float) -> float:
	for property_info in node.get_property_list():
		if str(property_info.get("name", "")) != property_name:
			continue
		var value: Variant = node.get(property_name)
		if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
			return float(value)
	return fallback


func _disturbance_strength_at(fish_world_xz: Vector2, sources: Array[Dictionary]) -> float:
	var strongest := 0.0
	for source in sources:
		var source_position := _snapshot_vector3(source.get("world_position", source.get("position", Vector3.ZERO)), Vector3.ZERO)
		var source_velocity := _snapshot_vector3(source.get("velocity", Vector3.ZERO), Vector3.ZERO)
		var to_fish := fish_world_xz - Vector2(source_position.x, source_position.z)
		var distance := to_fish.length()
		var direct_pressure := 1.0 - smoothstep(stickleback_scatter_radius_m * 0.55, stickleback_scatter_radius_m * 1.25, distance)
		var speed := Vector2(source_velocity.x, source_velocity.z).length()
		if speed <= 0.35:
			strongest = maxf(strongest, direct_pressure)
			continue
		var velocity_xz := Vector2(source_velocity.x, source_velocity.z)
		var direction_to_fish := to_fish.normalized()
		var closing_speed := maxf(0.0, velocity_xz.dot(direction_to_fish))
		var approach_strength := smoothstep(0.15, 3.0, closing_speed)
		var distance_signal := (1.0 - smoothstep(0.0, stickleback_alert_radius_m, distance)) * approach_strength * 0.62
		var time_to_closest := clampf(to_fish.dot(velocity_xz) / maxf(velocity_xz.length_squared(), 0.001), 0.0, 5.0)
		var closest_distance := (to_fish - velocity_xz * time_to_closest).length()
		var path_signal := (1.0 - smoothstep(stickleback_scatter_radius_m * 0.65, stickleback_alert_radius_m, closest_distance)) * approach_strength * (0.25 + 0.75 * (1.0 - time_to_closest / 5.0)) * 0.78
		strongest = maxf(strongest, maxf(direct_pressure, maxf(distance_signal, path_signal)))
	return clampf(strongest, 0.0, 1.0)


func _surface_fish_threat(fish_world_xz: Vector2, sources: Array[Dictionary]) -> Dictionary:
	var alert_strength := 0.0
	var scatter_strength := 0.0
	for source in sources:
		var source_position := _snapshot_vector3(source.get("world_position", source.get("position", Vector3.ZERO)), Vector3.ZERO)
		var source_velocity := _snapshot_vector3(source.get("velocity", Vector3.ZERO), Vector3.ZERO)
		var velocity := Vector2(source_velocity.x, source_velocity.z)
		var to_fish := fish_world_xz - Vector2(source_position.x, source_position.z)
		var distance := to_fish.length()
		var speed := velocity.length()
		var alert_radius := surface_fish_alert_radius_m + minf(speed * 0.35, 5.0)
		var scatter_radius := surface_fish_scatter_radius_m + minf(speed * 0.25, 4.0)
		var emergency_radius := surface_fish_emergency_radius_m + minf(speed * 0.15, 2.0)
		var effective_distance := distance
		if speed > 0.45:
			var time_to_closest := clampf(to_fish.dot(velocity) / maxf(velocity.length_squared(), 0.001), 0.0, 1.5)
			var closest_distance := (to_fish - velocity * time_to_closest).length()
			var predicted_distance := closest_distance + minf(speed * 0.3, 3.0)
			effective_distance = minf(distance, predicted_distance)
		var alert := 1.0 - smoothstep(alert_radius, alert_radius + 3.0, effective_distance)
		var scatter := 1.0 - smoothstep(emergency_radius, scatter_radius, effective_distance)
		alert_strength = maxf(alert_strength, alert)
		scatter_strength = maxf(scatter_strength, scatter)
	return {"alert": clampf(alert_strength, 0.0, 1.0), "scatter": clampf(scatter_strength, 0.0, 1.0)}


func _surface_fish_escape_direction(fish_world_xz: Vector2, local_offset: Vector2, state: Dictionary, sources: Array[Dictionary]) -> Vector2:
	var combined := Vector2.ZERO
	var total_weight := 0.0
	var bias := float(state.get("escape_bias_radians", 0.0))
	for source in sources:
		var source_position := _snapshot_vector3(source.get("world_position", source.get("position", Vector3.ZERO)), Vector3.ZERO)
		var source_velocity := _snapshot_vector3(source.get("velocity", Vector3.ZERO), Vector3.ZERO)
		var velocity := Vector2(source_velocity.x, source_velocity.z)
		var away := fish_world_xz - Vector2(source_position.x, source_position.z)
		var distance := away.length()
		var weight := 1.0 - smoothstep(surface_fish_alert_radius_m + 5.0, surface_fish_alert_radius_m + 10.0, distance)
		if weight <= 0.001:
			continue
		var away_direction := away.normalized()
		if away_direction.length_squared() < 0.001:
			away_direction = local_offset.normalized()
		if velocity.length() > 0.45:
			var path_side := Vector2(-velocity.normalized().y, velocity.normalized().x)
			var side_sign := signf(velocity.cross(away_direction))
			if absf(side_sign) < 0.1:
				side_sign = signf(sin(float(state.get("phase", 0.0)) * TAU + bias))
			var direction := (away_direction * 0.38 + path_side * side_sign * 0.84 + velocity.normalized() * 0.12).normalized()
			combined += direction.rotated(bias) * weight
		else:
			var local_spread := local_offset.normalized().rotated(bias) * 0.30
			combined += (away_direction * 0.78 + local_spread).normalized() * weight
		total_weight += weight
	if total_weight > 0.001 and combined.length_squared() > 0.01:
		return combined.normalized()
	return local_offset.normalized()


func _fish_escape_direction(fish_world_xz: Vector2, local_offset: Vector2, state: Dictionary, sources: Array[Dictionary]) -> Vector2:
	var combined := Vector2.ZERO
	var total_weight := 0.0
	var strongest_direction := Vector2.ZERO
	var strongest_weight := 0.0
	for source in sources:
		var source_position := _snapshot_vector3(source.get("world_position", source.get("position", Vector3.ZERO)), Vector3.ZERO)
		var source_velocity := _snapshot_vector3(source.get("velocity", Vector3.ZERO), Vector3.ZERO)
		var away := fish_world_xz - Vector2(source_position.x, source_position.z)
		var distance := away.length()
		var away_direction := away.normalized()
		if away_direction.length_squared() < 0.001:
			var escape_angle := float(state.get("phase", 0.0)) * TAU + float(state.get("escape_bias_radians", 0.0))
			away_direction = Vector2(cos(escape_angle), sin(escape_angle))
		var weight := 1.0 - smoothstep(0.0, stickleback_alert_radius_m, distance)
		if weight <= 0.001:
			continue
		var velocity_xz := Vector2(source_velocity.x, source_velocity.z)
		var desired := away_direction * 0.72
		if velocity_xz.length() > 0.6:
			var side := Vector2(-velocity_xz.y, velocity_xz.x).normalized()
			var side_sign := signf(away_direction.dot(side))
			if absf(side_sign) < 0.1:
				var phase_value := float(state.get("phase", 0.0)) * TAU + float(state.get("escape_bias_radians", 0.0))
				side_sign = signf(sin(phase_value))
			desired = away_direction * 0.38 + side * side_sign * 0.86 + velocity_xz.normalized() * 0.12
		else:
			desired += local_offset.normalized() * 0.28
		desired = desired.normalized().rotated(float(state.get("escape_bias_radians", 0.0)))
		combined += desired * weight
		total_weight += weight
		if weight > strongest_weight:
			strongest_weight = weight
			strongest_direction = desired
	if total_weight > 0.001 and combined.length_squared() > 0.01:
		return combined.normalized()
	if strongest_direction.length_squared() > 0.01:
		return strongest_direction
	return local_offset.normalized()


func _build_species_visuals() -> void:
	for child in get_children():
		child.queue_free()
	_species_visuals.clear()
	for profile in _profiles:
		var packed := ResourceLoader.load(profile.model_path) as PackedScene
		if packed == null:
			push_error("Fish model failed to load: %s" % profile.model_path)
			continue
		var source_root: Node = packed.instantiate()
		var mesh_nodes: Array[Node] = source_root.find_children("*", "MeshInstance3D", true, false)
		if mesh_nodes.is_empty():
			push_error("Fish model has no MeshInstance3D: %s" % profile.model_path)
			source_root.free()
			continue
		var mesh_instance := mesh_nodes[0] as MeshInstance3D
		var fish_mesh := mesh_instance.mesh
		if fish_mesh == null or fish_mesh.get_surface_count() == 0:
			push_error("Fish model has an empty mesh: %s" % profile.model_path)
			source_root.free()
			continue
		var model_transform := _get_transform_relative_to(mesh_instance, source_root)
		var base_material := fish_mesh.surface_get_material(0) as BaseMaterial3D
		if base_material == null:
			base_material = mesh_instance.get_active_material(0) as BaseMaterial3D
		var albedo_texture: Texture2D = base_material.albedo_texture if base_material != null else null
		var tint := base_material.albedo_color if base_material != null else Color.WHITE
		var fish_material := ShaderMaterial.new()
		fish_material.shader = SWIM_SHADER
		fish_material.set_shader_parameter("albedo_texture", albedo_texture)
		fish_material.set_shader_parameter("tint", tint)
		fish_material.set_shader_parameter("model_head_x", profile.model_head_x)
		fish_material.set_shader_parameter("model_head_sign", -1.0 if profile.model_forward_axis == 1 else 1.0)
		fish_material.set_shader_parameter("model_length", 1.2)
		fish_material.set_shader_parameter("wave_amplitude", profile.body_wave_amplitude_m * 1.2 / maxf(profile.target_visual_length_m, 0.05))
		fish_material.set_shader_parameter("tail_frequency_hz", profile.tail_frequency_hz)
		fish_material.set_shader_parameter("surface_roughness", profile.visual_roughness)
		fish_material.set_shader_parameter("animation_enabled", animation_enabled)
		if profile.species_id == "three_spined_stickleback":
			var mesh_bounds := fish_mesh.get_aabb()
			fish_material.set_shader_parameter("use_stickleback_body_tones", true)
			fish_material.set_shader_parameter("dorsal_center_z", mesh_bounds.position.z + mesh_bounds.size.z * 0.5)
			fish_material.set_shader_parameter("dorsal_half_span", maxf(mesh_bounds.size.z * 0.5, 0.001))
			# Subtle albedo shaping only: normal scene lighting still controls day/night response.
			fish_material.set_shader_parameter("dorsal_tint_multiplier", Color(0.68, 0.76, 0.82))
			fish_material.set_shader_parameter("belly_tint_multiplier", Color(1.24, 1.28, 1.32))
			fish_material.set_shader_parameter("side_tint_multiplier", Color(1.16, 1.18, 1.20))
			fish_material.set_shader_parameter("dorsal_tone_strength", 0.32)
			fish_material.set_shader_parameter("belly_tone_strength", 0.42)
			fish_material.set_shader_parameter("side_tone_strength", 0.22)
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.use_custom_data = true
		multimesh.mesh = fish_mesh
		multimesh.instance_count = 0
		var renderer := MultiMeshInstance3D.new()
		renderer.name = "%sMultiMesh" % profile.species_id
		renderer.multimesh = multimesh
		renderer.material_override = fish_material
		renderer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(renderer)
		_species_visuals[profile.species_id] = {
			"profile": profile,
			"mesh": fish_mesh,
			"multimesh": multimesh,
			"material": fish_material,
			"model_transform": model_transform,
			"renderer": renderer,
			"instance_keys": [],
		}
		source_root.free()


func _update_visible_fish(delta: float) -> void:
	var schools := _manager.get_schools_near(_boat.global_position, render_radius_m)
	var disturbance_sources := _get_disturbance_sources(delta)
	var observation_id := _observation_school_id if is_observation_active() else ""
	schools.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_id := str(a.get("school_id", ""))
		var b_id := str(b.get("school_id", ""))
		if a_id == observation_id:
			return b_id != observation_id
		if b_id == observation_id:
			return false
		var a_position: Array = a.get("world_position", [])
		var b_position: Array = b.get("world_position", [])
		if a_position.size() < 3 or b_position.size() < 3:
			return a_id < b_id
		var a_distance := Vector2(float(a_position[0]) - _boat.global_position.x, float(a_position[2]) - _boat.global_position.z).length_squared()
		var b_distance := Vector2(float(b_position[0]) - _boat.global_position.x, float(b_position[2]) - _boat.global_position.z).length_squared()
		return a_distance < b_distance
	)
	var fish_by_species: Dictionary = {}
	# Fish within a school share a small area. Cache the DTM result per 4 m
	# world-space cell to avoid repeating interpolation and coastline checks for
	# every fish on every visual update.
	var depth_sample_cache: Dictionary = {}
	var surface_sample_cache: Dictionary = {}
	var remaining_total := maximum_visible_fish
	_logical_school_counts = {"needlefish": 0, "herring": 0}
	_visual_school_counts = {"needlefish": 0, "herring": 0}
	_near_surface_school_count = 0
	_surface_school_records.clear()
	_surface_reveal_candidates.clear()
	for profile in _profiles:
		fish_by_species[profile.species_id] = []
	var time_now := _animation_clock
	var active_surface_motion_ids: Dictionary = {}
	for school in schools:
		var species_id := str(school["species_id"])
		if not fish_by_species.has(species_id) or not _species_visuals.has(species_id):
			continue
		var profile: FishSpeciesProfile = _species_visuals[species_id]["profile"]
		var surface_layer_fish := species_id in ["needlefish", "herring"]
		var activity_depth := float(school.get("activity_depth_m", _vertical_depth_offset(profile, float(school.get("depth_m", 0.0)), 0.0)))
		if surface_layer_fish:
			var school_id := str(school.get("school_id", ""))
			var was_visual := bool(_school_render_states.get(school_id, activity_depth <= 6.0))
			var remains_visual := activity_depth <= (6.35 if was_visual else 5.65)
			_school_render_states[school_id] = remains_visual
			if remains_visual:
				_visual_school_counts[species_id] = int(_visual_school_counts[species_id]) + 1
				active_surface_motion_ids[school_id] = true
				school = _smooth_surface_school_snapshot(school)
			else:
				_logical_school_counts[species_id] = int(_logical_school_counts[species_id]) + 1
				_surface_school_motion_states.erase(school_id)
				continue
			var activity_state := str(school.get("surface_activity_state", ""))
			if activity_depth <= 2.0 and activity_state in ["near_surface", "ascending", "descending"]:
				_near_surface_school_count += 1
		if remaining_total <= 0:
			continue
		var max_for_species := maxi(12, int(float(maximum_visible_fish) * _species_share(species_id)))
		var array: Array = fish_by_species[species_id]
		var allowed := mini(int(school["population"]), mini(max_for_species - array.size(), remaining_total))
		if allowed <= 0:
			continue
		var fish_records := _build_school_fish(school, profile, allowed, delta, time_now, depth_sample_cache, surface_sample_cache, disturbance_sources)
		array.append_array(fish_records)
		fish_by_species[species_id] = array
		remaining_total -= fish_records.size()
		if surface_layer_fish and not fish_records.is_empty() and activity_depth <= 6.0:
			var school_position := Vector3(float(school["world_position"][0]), 0.0, float(school["world_position"][2]))
			var school_distance_squared := Vector2(school_position.x - _boat.global_position.x, school_position.z - _boat.global_position.z).length_squared()
			var reveal_weight := 1.0 - smoothstep(2.0, 5.8, activity_depth)
			if school_distance_squared <= 90.0 * 90.0 and reveal_weight > 0.01:
				_surface_reveal_candidates.append({
					"distance_squared": school_distance_squared,
					"position": school_position,
					"radius": _school_wander_radius(profile) + surface_fish_scatter_extension_m + 2.0,
					"weight": reveal_weight,
				})
		if surface_layer_fish and not fish_records.is_empty() and activity_depth <= 2.0:
			var activity_state := str(school.get("surface_activity_state", ""))
			if activity_state in ["near_surface", "ascending", "descending"]:
				_surface_school_records.append({
					"school_id": str(school.get("school_id", "")),
					"species_id": species_id,
					"world_position": Vector3(float(school["world_position"][0]), 0.0, float(school["world_position"][2])),
					"population": int(school.get("population", 0)),
					"activity_depth_m": activity_depth,
					"activity_state": activity_state,
				})
	for school_id_variant in _surface_school_motion_states.keys():
		if not active_surface_motion_ids.has(str(school_id_variant)):
			_surface_school_motion_states.erase(school_id_variant)
	_visible_fish_count = maximum_visible_fish - remaining_total
	var active_keys: Dictionary = {}
	for profile in _profiles:
		var records: Array = fish_by_species.get(profile.species_id, [])
		var visual: Dictionary = _species_visuals.get(profile.species_id, {})
		if visual.is_empty():
			continue
		var multimesh: MultiMesh = visual["multimesh"]
		var instance_keys: Array[String] = []
		instance_keys.resize(records.size())
		for index in range(records.size()):
			var record: Dictionary = records[index]
			var individual_key := str(record["individual_key"])
			instance_keys[index] = individual_key
			active_keys[individual_key] = true
		if multimesh.instance_count != records.size():
			multimesh.instance_count = records.size()
		multimesh.visible_instance_count = records.size()
		visual["instance_keys"] = instance_keys
		_species_visuals[profile.species_id] = visual
	for key in _individual_states.keys():
		if not active_keys.has(key):
			_individual_states.erase(key)
	if _surface_activity != null:
		_surface_activity.call("set_active_schools", _surface_school_records)
	_update_surface_fish_reveal()


## The local world authority advances each shared school anchor in an 8-second
## simulation step. Rendered fish already interpolate their local motion at
## 0.16-second intervals, but without this client-only predictor every member
## inherits the authority anchor's periodic step. Extrapolate using the same
## drift convention, then decay any snapshot correction without writing it
## back to the shared FishSchoolState.
func _smooth_surface_school_snapshot(school: Dictionary) -> Dictionary:
	var school_id := str(school.get("school_id", ""))
	var authority_position := _snapshot_vector3(school.get("world_position", []), Vector3.ZERO)
	authority_position.y = 0.0
	var heading := float(school.get("direction_radians", 0.0))
	var authority_speed := maxf(0.0, float(school.get("movement_speed_mps", 0.0))) * AUTHORITY_SCHOOL_DRIFT_SCALE
	var desired_velocity := Vector3(cos(heading), 0.0, -sin(heading)) * authority_speed
	var now := _animation_clock
	var motion: Dictionary = _surface_school_motion_states.get(school_id, {})
	if motion.is_empty():
		motion = {
			"authority_position": authority_position,
			"authority_sample_clock": now,
			"velocity": desired_velocity,
			"prediction_offset": Vector3.ZERO,
			"visual_position": authority_position,
			"last_update_clock": now,
		}
		_surface_school_motion_states[school_id] = motion
		var initial := school.duplicate()
		initial["world_position"] = [authority_position.x, authority_position.y, authority_position.z]
		return initial

	var delta := clampf(now - float(motion.get("last_update_clock", now)), 0.0, 0.5)
	var last_authority_position: Vector3 = motion.get("authority_position", authority_position)
	var last_sample_clock := float(motion.get("authority_sample_clock", now))
	var velocity: Vector3 = motion.get("velocity", desired_velocity)
	var prediction_offset: Vector3 = motion.get("prediction_offset", Vector3.ZERO)
	var authority_age := maxf(0.0, now - last_sample_clock)
	var predicted_before_sample := last_authority_position + velocity * authority_age + prediction_offset
	if authority_position.distance_squared_to(last_authority_position) > 0.0001:
		var observed_delta := authority_position - last_authority_position
		var observed_interval := maxf(authority_age, 0.5)
		var observed_velocity := observed_delta / observed_interval
		var velocity_limit := maxf(0.08, authority_speed * 1.8 + 0.04)
		if observed_velocity.length() > velocity_limit:
			observed_velocity = observed_velocity.normalized() * velocity_limit
		# The sample's average is useful for course changes, while the latest
		# heading keeps the prediction responsive to the next authority step.
		velocity = observed_velocity.lerp(desired_velocity, 0.30)
		prediction_offset = predicted_before_sample - authority_position
		# Large errors indicate an explicit state relocation or stale local cache;
		# do not drag a school across the ocean to hide a real state correction.
		if prediction_offset.length() > 8.0:
			prediction_offset = Vector3.ZERO
		last_authority_position = authority_position
		last_sample_clock = now

	var velocity_blend := 1.0 - exp(-delta * 1.5)
	velocity = velocity.lerp(desired_velocity, velocity_blend)
	prediction_offset *= exp(-delta / SCHOOL_MOTION_CORRECTION_DECAY)
	authority_age = minf(maxf(0.0, now - last_sample_clock), 10.0)
	var predicted_position := last_authority_position + velocity * authority_age + prediction_offset
	var visual_position: Vector3 = motion.get("visual_position", predicted_position)
	visual_position = visual_position.lerp(predicted_position, 1.0 - exp(-delta * SCHOOL_MOTION_VISUAL_RESPONSE))
	motion["authority_position"] = last_authority_position
	motion["authority_sample_clock"] = last_sample_clock
	motion["velocity"] = velocity
	motion["prediction_offset"] = prediction_offset
	motion["visual_position"] = visual_position
	motion["last_update_clock"] = now
	_surface_school_motion_states[school_id] = motion
	var smoothed := school.duplicate()
	smoothed["world_position"] = [visual_position.x, visual_position.y, visual_position.z]
	return smoothed


func _update_surface_fish_reveal() -> void:
	if _water_material == null:
		return
	_surface_reveal_candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["distance_squared"]) < float(b["distance_squared"])
	)
	_surface_reveal_spheres.fill(Vector4.ZERO)
	var reveal_count := mini(_surface_reveal_candidates.size(), MAX_SURFACE_FISH_REVEAL_SCHOOLS)
	for index in range(reveal_count):
		var candidate: Dictionary = _surface_reveal_candidates[index]
		var position: Vector3 = candidate["position"]
		_surface_reveal_spheres[index] = Vector4(position.x, position.z, float(candidate["radius"]), float(candidate["weight"]))
	_water_material.set_shader_parameter("surface_fish_reveal_spheres", _surface_reveal_spheres)
	_water_material.set_shader_parameter("surface_fish_reveal_count", reveal_count)


func _render_visible_fish(alpha: float) -> void:
	var blend := clampf(alpha, 0.0, 1.0)
	for profile in _profiles:
		var visual: Dictionary = _species_visuals.get(profile.species_id, {})
		if visual.is_empty():
			continue
		var renderer: MultiMeshInstance3D = visual["renderer"]
		if not visible or not renderer.is_visible_in_tree():
			continue
		var multimesh: MultiMesh = visual["multimesh"]
		var instance_keys: Array = visual["instance_keys"]
		for index in range(instance_keys.size()):
			var state: Dictionary = _individual_states.get(instance_keys[index], {})
			if state.is_empty() or not bool(state.get("visual_initialized", false)):
				continue
			var from_transform: Transform3D = state["visual_from_transform"]
			var to_transform: Transform3D = state["visual_to_transform"]
			var from_custom: Color = state["visual_from_custom"]
			var to_custom: Color = state["visual_to_custom"]
			var transform := interpolate_visual_transform(from_transform, to_transform, blend) if smooth_motion_enabled else to_transform
			var custom := from_custom.lerp(to_custom, blend) if smooth_motion_enabled else to_custom
			multimesh.set_instance_transform(index, transform)
			multimesh.set_instance_custom_data(index, custom)


static func interpolate_visual_transform(from_transform: Transform3D, to_transform: Transform3D, weight: float) -> Transform3D:
	var blend := clampf(weight, 0.0, 1.0)
	var from_rotation := from_transform.basis.orthonormalized().get_rotation_quaternion()
	var to_rotation := to_transform.basis.orthonormalized().get_rotation_quaternion()
	var rotation := from_rotation.slerp(to_rotation, blend).normalized()
	var scale := from_transform.basis.get_scale().lerp(to_transform.basis.get_scale(), blend)
	var basis := Basis(rotation).scaled(scale)
	return Transform3D(basis, from_transform.origin.lerp(to_transform.origin, blend))


## GLB exports do not share a forward axis. This maps the model's configured
## nose axis onto the fish's actual world travel direction.
static func basis_for_model_heading(world_direction: Vector3, model_forward_axis: int) -> Basis:
	var forward := Vector3(world_direction.x, 0.0, world_direction.z).normalized()
	if forward.length_squared() < 0.0001:
		forward = Vector3.FORWARD
	var model_x_forward := -forward if model_forward_axis == 1 else forward
	return Basis(model_x_forward, Vector3.UP, model_x_forward.cross(Vector3.UP).normalized())


## Shared helper for a future server adapter: interpolate two snapshots in the
## authority's timestamp domain, regardless of how irregularly they arrived.
## Optional world_velocity enables only a short, bounded prediction past the
## newest sample. It does not write back to authority state.
static func interpolate_authoritative_school_motion(previous: Dictionary, latest: Dictionary, sample_timestamp: float, max_extrapolation_seconds: float = 0.25) -> Dictionary:
	if previous.is_empty() or latest.is_empty():
		return latest.duplicate(true)
	var previous_timestamp := float(previous.get("authoritative_timestamp", previous.get("last_updated_unix", 0.0)))
	var latest_timestamp := float(latest.get("authoritative_timestamp", latest.get("last_updated_unix", 0.0)))
	var previous_position := _snapshot_vector3(previous.get("world_position", []), Vector3.ZERO)
	var latest_position := _snapshot_vector3(latest.get("world_position", []), previous_position)
	var duration := latest_timestamp - previous_timestamp
	if duration <= 0.0001:
		return latest.duplicate(true)
	var result := latest.duplicate(true)
	var position := previous_position.lerp(latest_position, clampf((sample_timestamp - previous_timestamp) / duration, 0.0, 1.0))
	var previous_heading := float(previous.get("direction_radians", 0.0))
	var latest_heading := float(latest.get("direction_radians", previous_heading))
	var heading := lerp_angle(previous_heading, latest_heading, clampf((sample_timestamp - previous_timestamp) / duration, 0.0, 1.0))
	if sample_timestamp > latest_timestamp:
		var velocity := _snapshot_vector3(latest.get("world_velocity", []), Vector3.ZERO)
		var prediction_seconds := minf(sample_timestamp - latest_timestamp, maxf(max_extrapolation_seconds, 0.0))
		position += velocity * prediction_seconds
	result["world_position"] = [position.x, position.y, position.z]
	result["direction_radians"] = heading
	result["authoritative_timestamp"] = sample_timestamp
	return result


static func _snapshot_vector3(value: Variant, fallback: Vector3) -> Vector3:
	if value is Vector3:
		return value
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return fallback


func _build_school_fish(school: Dictionary, profile: FishSpeciesProfile, count: int, delta: float, time_now: float, depth_sample_cache: Dictionary, surface_sample_cache: Dictionary = {}, disturbance_sources: Array[Dictionary] = []) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var school_id := str(school["school_id"])
	var school_position := Vector3(float(school["world_position"][0]), 0.0, float(school["world_position"][2]))
	var group_heading := float(school["direction_radians"])
	var group_forward := Vector2(cos(group_heading), sin(group_heading))
	var boat_delta := Vector2(_boat.global_position.x - school_position.x, _boat.global_position.z - school_position.z)
	var boat_distance := boat_delta.length()
	var active_disturbance_sources := disturbance_sources
	if active_disturbance_sources.is_empty():
		active_disturbance_sources = _get_disturbance_sources(delta)
	var school_depth := maxf(0.1, float(school["depth_m"]))
	# All members remain within a few metres of the school anchor. One shared
	# Gerstner sample preserves coherent height while avoiding a full inverse
	# wave solve for every individual fish.
	var school_surface_height := _surface_height(school_position)
	var habitat_context: Dictionary = {}
	if profile.species_id == "three_spined_stickleback" and _seabed_manager != null:
		habitat_context = _seabed_manager.get_fish_habitat_context(school_position, profile.school_activity_radius_m)
	var local_offsets: Array[Vector2] = []
	var local_velocities: Array[Vector2] = []
	var keys: Array[String] = []
	var phases: Array[float] = []
	var behavior_states: Array[String] = []
	for index in range(count):
		var individual_key := "%s:%d" % [school_id, index]
		if not _individual_states.has(individual_key):
			_individual_states[individual_key] = _create_individual_state(
				int(school["seed"]), index, profile,
				float(school.get("activity_depth_m", profile.target_visual_length_m))
			)
		var state: Dictionary = _individual_states[individual_key]
		var offset: Vector2 = state["local_position"]
		local_offsets.append(offset)
		local_velocities.append(state["velocity"])
		keys.append(individual_key)
		phases.append(float(state["phase"]))
		behavior_states.append(str(state["behavior_state"]))
	var grid := _build_neighbor_grid(local_offsets) if profile.species_id in ["herring", "three_spined_stickleback"] else {}
	var base_speed := float(school["movement_speed_mps"])
	var forward_bias := 0.20 if profile.species_id == "needlefish" else (0.06 if profile.species_id == "herring" else (0.08 if profile.species_id == "three_spined_stickleback" else 0.0))
	for index in range(count):
		var individual_key := keys[index]
		var state: Dictionary = _individual_states[individual_key]
		var offset: Vector2 = local_offsets[index]
		var velocity: Vector2 = local_velocities[index]
		var state_timer := float(state["state_timer"]) - delta
		var behavior := behavior_states[index]
		var epoch := int(state["behavior_epoch"])
		var regroup_remaining := float(state.get("regroup_remaining", 0.0))
		var regroup_duration := float(state.get("regroup_duration", 0.0))
		var disturbance_state := str(state.get("disturbance_state", "cruising"))
		var is_fleeing := false
		var threat_level := 0.0
		if profile.species_id == "three_spined_stickleback":
			var fish_world_xz := Vector2(school_position.x + offset.x, school_position.z + offset.y)
			var incoming_threat := clampf(_disturbance_strength_at(fish_world_xz, active_disturbance_sources) * float(state.get("reaction_sensitivity", 1.0)), 0.0, 1.0)
			var previous_threat := float(state.get("threat_level", 0.0))
			var response_rate := 4.0 if incoming_threat > previous_threat else 0.85
			threat_level = move_toward(previous_threat, incoming_threat, response_rate * delta)
			var previous_disturbance_state := disturbance_state
			var peak_threat := maxf(float(state.get("peak_threat", 0.0)), threat_level)
			if threat_level >= stickleback_scatter_threshold or (previous_disturbance_state == "scattering" and threat_level > stickleback_scatter_exit_threshold):
				disturbance_state = "scattering"
				regroup_remaining = 0.0
				regroup_duration = 0.0
				state["peak_threat"] = peak_threat
				if previous_disturbance_state != "scattering":
					state["depth_target_m"] = _choose_stickleback_depth_target(profile, int(state["random_seed"]), epoch + 1, true)
			elif previous_disturbance_state == "scattering":
				disturbance_state = "recovering"
				var population_factor := clampf(float(school.get("population", 0)) * 0.10, 0.0, 1.0)
				regroup_duration = lerpf(stickleback_regroup_min_seconds, stickleback_regroup_max_seconds, clampf(peak_threat + population_factor * 0.2, 0.0, 1.0))
				regroup_remaining = regroup_duration
				state["peak_threat"] = 0.0
				state["depth_target_m"] = _choose_stickleback_depth_target(profile, int(state["random_seed"]), epoch + 1, false)
			elif threat_level >= stickleback_alert_threshold:
				disturbance_state = "alert"
				regroup_remaining = 0.0
				regroup_duration = 0.0
				state["peak_threat"] = peak_threat
			elif previous_disturbance_state == "recovering" and regroup_remaining > 0.0:
				disturbance_state = "recovering"
				regroup_remaining = maxf(0.0, regroup_remaining - delta)
			else:
				disturbance_state = "cruising"
				regroup_remaining = 0.0
				regroup_duration = 0.0
				state["peak_threat"] = 0.0
			if disturbance_state == "cruising" and state_timer <= 0.0:
				epoch += 1
				behavior = _choose_behavior(profile.species_id, int(state["random_seed"]), epoch)
				state_timer = _behavior_duration(profile.species_id, int(state["random_seed"]), epoch)
				state["routine_behavior"] = behavior
				# Small, infrequent depth changes keep ordinary cruising from looking
				# locked to one horizontal plane. Movement remains gradual below.
				state["depth_target_m"] = _choose_stickleback_depth_target(profile, int(state["random_seed"]), epoch, false)
			else:
				behavior = str(state.get("routine_behavior", "cruise"))
			match disturbance_state:
				"alert": behavior = "alert"
				"scattering": behavior = "flee"
				"recovering": behavior = "regrouping"
			is_fleeing = disturbance_state == "scattering"
			state["disturbance_state"] = disturbance_state
			state["threat_level"] = threat_level
			state["regroup_remaining"] = regroup_remaining
			state["regroup_duration"] = regroup_duration
		else:
			if profile.species_id in ["needlefish", "herring"]:
				var fish_world_xz := Vector2(school_position.x + offset.x, school_position.z + offset.y)
				var threat := _surface_fish_threat(fish_world_xz, active_disturbance_sources)
				var incoming_threat := clampf(float(threat.get("alert", 0.0)) * float(state.get("reaction_sensitivity", 1.0)), 0.0, 1.0)
				var scatter_strength := clampf(float(threat.get("scatter", 0.0)) * float(state.get("reaction_sensitivity", 1.0)), 0.0, 1.0)
				var previous_state := str(state.get("surface_disturbance_state", "cruising"))
				var recovery_remaining := float(state.get("surface_recovery_remaining", 0.0))
				if scatter_strength >= 0.12 or (previous_state == "scattering" and scatter_strength >= 0.06):
					disturbance_state = "scattering"
					recovery_remaining = 0.0
				elif previous_state == "scattering":
					disturbance_state = "recovering"
					recovery_remaining = lerpf(3.5, 6.5, clampf(float(state.get("reaction_sensitivity", 1.0)) - 0.90, 0.0, 1.0))
				elif incoming_threat >= 0.16:
					disturbance_state = "alert"
					recovery_remaining = 0.0
				elif previous_state == "recovering" and recovery_remaining > 0.0:
					disturbance_state = "recovering"
					recovery_remaining = maxf(0.0, recovery_remaining - delta)
				else:
					disturbance_state = "cruising"
					recovery_remaining = 0.0
					if state_timer <= 0.0:
						epoch += 1
						behavior = _choose_behavior(profile.species_id, int(state["random_seed"]), epoch)
						state_timer = _behavior_duration(profile.species_id, int(state["random_seed"]), epoch)
				match disturbance_state:
					"alert": behavior = "alert"
					"scattering": behavior = "flee"
					"recovering": behavior = "regrouping"
				is_fleeing = disturbance_state == "scattering"
				threat_level = maxf(incoming_threat, scatter_strength)
				state["surface_disturbance_state"] = disturbance_state
				state["surface_recovery_remaining"] = recovery_remaining
				state["surface_threat_level"] = threat_level
			else:
				is_fleeing = boat_distance < _species_flee_radius(profile.species_id)
				if is_fleeing:
					behavior = "flee"
				elif state_timer <= 0.0:
					epoch += 1
					behavior = _choose_behavior(profile.species_id, int(state["random_seed"]), epoch)
					state_timer = _behavior_duration(profile.species_id, int(state["random_seed"]), epoch)
		var separation := Vector2.ZERO
		var alignment := Vector2.ZERO
		var neighbor_center := Vector2.ZERO
		var cohesion_neighbor_count := 0
		if profile.species_id in ["herring", "three_spined_stickleback"]:
			var search_cells := 2 if profile.species_id == "three_spined_stickleback" and disturbance_state in ["alert", "scattering", "recovering"] else 1
			var neighbors := _neighbors_for_index(index, local_offsets, local_velocities, grid, search_cells)
			for neighbor_index in neighbors:
				if neighbor_index == index:
					continue
				var difference := offset - local_offsets[neighbor_index]
				var distance := difference.length()
				var separation_distance := 1.7 if profile.species_id == "herring" else (0.32 if profile.species_id == "three_spined_stickleback" else 0.48)
				if distance > 0.001 and distance < separation_distance:
					separation += difference.normalized() * (separation_distance - distance)
				var alignment_radius := 3.2 if profile.species_id == "three_spined_stickleback" and disturbance_state == "recovering" else (2.3 if profile.species_id == "herring" else 1.65)
				if distance < alignment_radius:
					alignment += local_velocities[neighbor_index]
				if profile.species_id == "three_spined_stickleback" and disturbance_state in ["alert", "recovering"] and distance < 6.5:
					neighbor_center += local_offsets[neighbor_index]
					cohesion_neighbor_count += 1
				elif profile.species_id == "herring" and disturbance_state in ["alert", "recovering"] and distance < 5.5:
					neighbor_center += local_offsets[neighbor_index]
					cohesion_neighbor_count += 1
			if neighbors.size() > 1:
				alignment = alignment / float(neighbors.size() - 1)
		var anchor: Vector2 = state["formation_anchor"]
		var cohesion_strength := 0.23 if profile.species_id == "herring" else (0.42 if profile.species_id == "three_spined_stickleback" else 0.13)
		if profile.species_id in ["needlefish", "herring"]:
			match disturbance_state:
				"alert": cohesion_strength = 0.14 if profile.species_id == "herring" else 0.08
				"scattering": cohesion_strength = 0.035
				"recovering": cohesion_strength = 0.31 if profile.species_id == "herring" else 0.20
		var cohesion := (anchor - offset) * cohesion_strength
		var recovery_progress := 0.0
		if profile.species_id == "three_spined_stickleback":
			if disturbance_state == "alert":
				cohesion = (anchor - offset) * 0.22
				if cohesion_neighbor_count > 0:
					cohesion += (neighbor_center / float(cohesion_neighbor_count) - offset) * 0.28
			elif disturbance_state == "scattering":
				cohesion = (anchor - offset) * 0.08
			elif disturbance_state == "recovering":
				recovery_progress = 1.0 - clampf(regroup_remaining / maxf(regroup_duration, 0.01), 0.0, 1.0)
				cohesion = (anchor - offset) * lerpf(0.12, 0.30, recovery_progress)
				if cohesion_neighbor_count > 0:
					cohesion += (neighbor_center / float(cohesion_neighbor_count) - offset) * lerpf(0.28, 0.72, recovery_progress)
		var acceleration := group_forward * (base_speed * forward_bias) + cohesion + separation * 0.9
		if profile.species_id == "herring":
			var alignment_weight := 0.24 if disturbance_state == "cruising" else (0.15 if disturbance_state in ["alert", "scattering"] else 0.34)
			acceleration += (alignment - velocity) * alignment_weight
			if disturbance_state == "recovering" and cohesion_neighbor_count > 0:
				var nearby_center := neighbor_center / float(cohesion_neighbor_count)
				acceleration += (nearby_center - offset) * 0.22
		elif profile.species_id == "three_spined_stickleback":
			var alignment_weight := 0.10 if disturbance_state == "cruising" else (0.20 if disturbance_state == "alert" else (0.34 if disturbance_state == "recovering" else 0.08))
			acceleration += (alignment - velocity) * alignment_weight
			var edge_direction: Vector3 = habitat_context.get("edge_direction", Vector3.ZERO)
			acceleration += Vector2(edge_direction.x, edge_direction.z) * base_speed * 0.24 * float(habitat_context.get("edge_strength", 0.0))
			var current_world_xz := Vector2(school_position.x + offset.x, school_position.z + offset.y)
			acceleration += _reef_edge_steering(current_world_xz, habitat_context.get("reef_clusters", []), state, base_speed)
			if disturbance_state == "alert":
				var alert_direction := _fish_escape_direction(current_world_xz, offset, state, active_disturbance_sources)
				acceleration += alert_direction * base_speed * threat_level * 0.28
		if profile.species_id in ["needlefish", "herring"]:
			var current_world_position := Vector2(school_position.x + offset.x, school_position.z + offset.y)
			if disturbance_state == "alert":
				var alert_direction := _surface_fish_escape_direction(current_world_position, offset, state, active_disturbance_sources)
				acceleration += alert_direction * base_speed * threat_level * 0.20
			elif disturbance_state == "scattering":
				var escape_direction := _surface_fish_escape_direction(current_world_position, offset, state, active_disturbance_sources)
				var individual_spread := (offset.normalized() + Vector2(-velocity.y, velocity.x).normalized() * float(state.get("escape_bias_radians", 0.0))).normalized()
				var escape_strength := 1.20 if profile.species_id == "herring" else 1.55
				acceleration += (escape_direction * 0.82 + individual_spread * 0.18).normalized() * base_speed * escape_strength
			elif disturbance_state == "recovering" and profile.species_id == "needlefish":
				acceleration += (anchor - offset) * 0.15
		if profile.species_id == "three_spined_stickleback" and disturbance_state == "scattering":
			var fish_world_xz := Vector2(school_position.x + offset.x, school_position.z + offset.y)
			var flee_direction := _fish_escape_direction(fish_world_xz, offset, state, active_disturbance_sources)
			if flee_direction.length_squared() > 0.01:
				var dispersal := offset.normalized() * 0.25
				var flee_acceleration := base_speed * (1.25 + threat_level * 0.85)
				acceleration += (flee_direction + dispersal).normalized() * flee_acceleration
		elif is_fleeing and profile.species_id not in ["needlefish", "herring"]:
			var flee_direction := Vector2(school_position.x - _boat.global_position.x, school_position.z - _boat.global_position.z).normalized()
			if flee_direction.length_squared() > 0.01:
				acceleration += flee_direction * base_speed * 2.8
		if behavior == "turn":
			acceleration += Vector2(-velocity.y, velocity.x) * float(state["turn_bias"])
		elif behavior == "burst":
			acceleration += group_forward * (base_speed * 1.5)
		elif behavior == "hover" or behavior == "idle":
			acceleration -= velocity * 0.45
		var previous_speed := velocity.length()
		velocity += acceleration * delta
		if profile.species_id in ["needlefish", "herring"] and not is_fleeing:
			var accelerated_speed := velocity.length()
			if accelerated_speed > previous_speed and velocity.length_squared() > 0.0001:
				# Keep ordinary speed increases from the burst and schooling forces
				# at 60% of their previous per-tick gain. Emergency fleeing remains
				# unaffected so boat avoidance still has enough response.
				var reduced_speed := lerpf(previous_speed, accelerated_speed, SURFACE_FISH_ACCELERATION_FACTOR)
				velocity = velocity.normalized() * reduced_speed
		var speed_limit := base_speed * _behavior_speed_scale(behavior)
		if behavior == "turn" and profile.species_id in ["needlefish", "herring"]:
			# Their previous turn cap was 0.75x cruise speed. Keep the turn
			# readable and reduce that cap to about 60% of its previous value.
			speed_limit *= SURFACE_FISH_TURN_SPEED_FACTOR
		elif behavior == "burst" and profile.species_id in ["needlefish", "herring"]:
			# Burst speed is limited to 60% of the previous burst cap.
			speed_limit *= SURFACE_FISH_ACCELERATION_FACTOR
		if is_fleeing:
			speed_limit = maxf(speed_limit, base_speed * (1.55 + threat_level * 0.80 if profile.species_id == "three_spined_stickleback" else 2.6))
		if velocity.length() > speed_limit and speed_limit > 0.01:
			velocity = velocity.normalized() * speed_limit
		if velocity.length() < base_speed * 0.20 and behavior != "idle" and behavior != "hover":
			velocity = group_forward * base_speed * 0.3
		velocity = _limit_velocity_turn(local_velocities[index], velocity, profile.species_id, delta, is_fleeing)
		offset += velocity * delta
		var base_activity_radius := _school_wander_radius(profile)
		var expansion := 0.0
		if profile.species_id == "three_spined_stickleback":
			if disturbance_state == "scattering":
				expansion = stickleback_scatter_radius_extension_m * clampf(threat_level, 0.4, 1.0)
			elif disturbance_state == "recovering":
				expansion = stickleback_scatter_radius_extension_m * clampf(regroup_remaining / maxf(regroup_duration, 0.01), 0.0, 1.0)
		elif profile.species_id in ["needlefish", "herring"]:
			if disturbance_state == "scattering":
				expansion = surface_fish_scatter_extension_m * (1.25 if profile.species_id == "herring" else 0.85)
			elif disturbance_state == "recovering":
				var remaining_recovery := float(state.get("surface_recovery_remaining", 0.0))
				expansion = surface_fish_scatter_extension_m * clampf(remaining_recovery / 6.5, 0.0, 1.0) * 0.65
		var activity_radius := base_activity_radius + expansion
		var wander_radius := activity_radius
		if offset.length() > wander_radius:
			offset = offset.normalized() * wander_radius
		var world_xz := Vector2(school_position.x, school_position.z) + Vector2(offset.x, offset.y)
		# The authority already constrains the school centre to valid water. A
		# small species-specific radius keeps client-only fish in the same habitat
		# without issuing a CPU bathymetry query for every fish every update.
		var habitat_radius := activity_radius
		if offset.length() > habitat_radius:
			offset = anchor
			velocity = -velocity * 0.35
		var local_water_position := Vector3(world_xz.x, 0.0, world_xz.y)
		var local_depth_data := _get_cached_depth_sample(local_water_position, depth_sample_cache)
		if not bool(local_depth_data.get("valid", false)):
			continue
		var local_depth := float(local_depth_data.get("depth_m", school_depth))
		var local_surface_height := school_surface_height
		if profile.species_id == "three_spined_stickleback":
			local_surface_height = _get_cached_surface_height(local_water_position, surface_sample_cache)
		var visual_length_m := float(state.get("visual_length_m", profile.target_visual_length_m))
		var clearance := minf(0.30, maxf(0.08, visual_length_m * 0.70))
		if local_depth < clearance * 2.0:
			continue
		var depth_offset := _vertical_depth_offset(profile, local_depth, float(state["depth_variation"]))
		var position_y: float
		if profile.species_id == "three_spined_stickleback":
			var bottom_clearance := maxf(0.12, visual_length_m * 0.22)
			var minimum_depth := maxf(0.32, profile.near_surface_depth_m.x)
			var maximum_swim_depth := local_depth - bottom_clearance
			if local_depth < profile.minimum_water_column_m or maximum_swim_depth < minimum_depth:
				continue
			var target_depth := clampf(float(state.get("depth_target_m", profile.preferred_swim_depth_m.x)), minimum_depth, maximum_swim_depth)
			var current_depth := float(state.get("swim_depth_m", target_depth))
			current_depth = move_toward(current_depth, target_depth, profile.vertical_move_speed_mps * delta)
			var depth_bob := sin(time_now * 0.68 + float(state["phase"]) * TAU) * 0.035
			depth_offset = clampf(current_depth + depth_bob, minimum_depth, maximum_swim_depth)
			state["swim_depth_m"] = current_depth
			state["depth_target_m"] = target_depth
			position_y = local_surface_height - depth_offset
		elif profile.species_id in ["needlefish", "herring"]:
			var bottom_clearance := maxf(0.42, minf(0.9, visual_length_m * 0.30))
			var maximum_swim_depth := maxf(0.30, local_depth - bottom_clearance)
			var target_depth := float(school.get("activity_depth_m", depth_offset)) + float(state["depth_variation"]) * 0.16
			target_depth = clampf(target_depth, 0.30, maximum_swim_depth)
			var current_depth := clampf(float(state.get("swim_depth_m", target_depth)), 0.30, maximum_swim_depth)
			current_depth = move_toward(current_depth, target_depth, profile.activity_vertical_speed_mps * delta)
			var depth_bob := sin(time_now * 0.38 + float(state["phase"]) * TAU) * 0.035
			depth_offset = clampf(current_depth + depth_bob, 0.30, maximum_swim_depth)
			state["swim_depth_m"] = current_depth
			state["depth_target_m"] = target_depth
			position_y = local_surface_height - depth_offset
		else:
			position_y = local_surface_height - depth_offset + float(state["vertical_offset"])
			position_y = clampf(position_y, local_surface_height - local_depth + clearance, local_surface_height - clearance)
		var position := Vector3(world_xz.x, position_y, world_xz.y)
		var boat_clearance := 0.65 if profile.species_id == "three_spined_stickleback" else boat_exclusion_radius_m
		if profile.species_id == "three_spined_stickleback" and (is_fleeing or (_observation_school_id == school_id and is_observation_active())):
			boat_clearance = 0.0
		if Vector2(position.x - _boat.global_position.x, position.z - _boat.global_position.z).length() < boat_clearance:
			continue
		var direction := velocity.normalized() if velocity.length_squared() > 0.0001 else group_forward
		var forward := Vector3(direction.x, 0.0, direction.y).normalized()
		var fish_basis := basis_for_model_heading(forward, profile.model_forward_axis)
		var visual: Dictionary = _species_visuals[profile.species_id]
		var model_transform: Transform3D = visual["model_transform"]
		var local_model_basis: Basis = model_transform.basis
		var fish_scale := visual_length_m / 1.2
		var transform_basis := fish_basis * local_model_basis * Basis.from_scale(Vector3.ONE * fish_scale)
		var model_offset := fish_basis * model_transform.origin * fish_scale
		var transform := Transform3D(transform_basis, position + model_offset)
		var speed_factor := clampf(velocity.length() / maxf(base_speed, 0.1), 0.0, 2.5)
		var custom := Color(
			phases[index],
			float(state["amplitude_variation"]),
			clampf(0.75 + speed_factor * 0.20, 0.65, 1.3),
			float(state["color_variation"])
		)
		var previous_transform: Transform3D = state.get("visual_to_transform", transform)
		var previous_custom: Color = state.get("visual_to_custom", custom)
		if not bool(state.get("visual_initialized", false)) or not smooth_motion_enabled:
			previous_transform = transform
			previous_custom = custom
		state["visual_from_transform"] = previous_transform
		state["visual_to_transform"] = transform
		state["visual_from_custom"] = previous_custom
		state["visual_to_custom"] = custom
		state["visual_initialized"] = true
		result.append({"transform": transform, "custom": custom, "individual_key": individual_key})
		state["local_position"] = offset
		state["velocity"] = velocity
		state["state_timer"] = state_timer
		state["behavior_state"] = behavior
		state["behavior_epoch"] = epoch
		if profile.species_id == "three_spined_stickleback":
			state["routine_behavior"] = str(state.get("routine_behavior", behavior))
			state["disturbance_state"] = disturbance_state
			state["threat_level"] = threat_level
			state["regroup_remaining"] = regroup_remaining
			state["regroup_duration"] = regroup_duration
		elif profile.species_id in ["needlefish", "herring"]:
			state["disturbance_state"] = disturbance_state
			state["threat_level"] = threat_level
		state["depth_variation"] = float(state["depth_variation"])
		state["is_fleeing"] = is_fleeing
		_individual_states[individual_key] = state
	return result


func _get_cached_surface_height(world_position: Vector3, cache: Dictionary) -> float:
	const SAMPLE_CELL_M := 4.0
	var cell := Vector2i(floori(world_position.x / SAMPLE_CELL_M), floori(world_position.z / SAMPLE_CELL_M))
	if cache.has(cell):
		return float(cache[cell])
	var sample_position := Vector3((float(cell.x) + 0.5) * SAMPLE_CELL_M, 0.0, (float(cell.y) + 0.5) * SAMPLE_CELL_M)
	var height := _surface_height(sample_position)
	cache[cell] = height
	return height


func _reef_edge_steering(world_xz: Vector2, reef_clusters: Array, state: Dictionary, base_speed: float) -> Vector2:
	var steering := Vector2.ZERO
	for cluster in reef_clusters:
		var cluster_position: Vector3 = cluster.get("world_position", Vector3.ZERO)
		var delta := world_xz - Vector2(cluster_position.x, cluster_position.z)
		var distance := delta.length()
		var radius := maxf(0.7, float(cluster.get("radius_m", 1.0)) * 0.68)
		if distance < 0.001 or distance > radius + 2.0:
			continue
		var radial := delta / distance
		if distance < radius:
			steering += radial * ((radius - distance) * base_speed * 0.7)
		else:
			var tangent := Vector2(-radial.y, radial.x) * signf(float(state.get("turn_bias", 1.0)))
			steering += tangent * base_speed * 0.06 * (1.0 - clampf((distance - radius) / 2.0, 0.0, 1.0))
	return steering


func _get_cached_depth_sample(world_position: Vector3, cache: Dictionary) -> Dictionary:
	if _bathymetry == null:
		return {"valid": false, "reason": "No BathymetryManager"}
	const SAMPLE_CELL_M := 4.0
	var cell := Vector2i(floori(world_position.x / SAMPLE_CELL_M), floori(world_position.z / SAMPLE_CELL_M))
	if cache.has(cell):
		return cache[cell]
	var sample_position := Vector3((float(cell.x) + 0.5) * SAMPLE_CELL_M, 0.0, (float(cell.y) + 0.5) * SAMPLE_CELL_M)
	var sample := _bathymetry.get_depth_at_world_position(sample_position)
	cache[cell] = sample
	return sample


func _get_transform_relative_to(node: Node3D, ancestor: Node) -> Transform3D:
	var result := node.transform
	var current: Node = node.get_parent()
	while current != null and current != ancestor:
		var current_3d := current as Node3D
		if current_3d != null:
			result = current_3d.transform * result
		current = current.get_parent()
	return result


func _create_individual_state(school_seed: int, index: int, profile: FishSpeciesProfile, initial_activity_depth_m: float = -1.0) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = FishLocalAuthority.hash32(school_seed, index, 81231 + profile.species_index * 71)
	var school_radius := _school_wander_radius(profile)
	var radius := sqrt(rng.randf()) * school_radius
	if profile.species_id == "three_spined_stickleback":
		var ring_roll := rng.randf()
		if ring_roll < 0.74:
			radius = sqrt(rng.randf()) * school_radius * 0.25
		elif ring_roll < 0.96:
			radius = lerpf(school_radius * 0.25, school_radius * 0.52, rng.randf())
		else:
			radius = lerpf(school_radius * 0.48, school_radius * 0.65, rng.randf())
	var angle := rng.randf_range(-PI, PI)
	var anchor := Vector2(cos(angle), sin(angle)) * radius
	var initial_speed := rng.randf_range(profile.movement_speed_min_mps, profile.movement_speed_max_mps) * (0.22 if profile.species_id == "three_spined_stickleback" else 0.38)
	var visual_length := _choose_visual_length(profile, rng)
	var initial_depth := profile.target_visual_length_m
	if profile.species_id in ["needlefish", "herring"]:
		initial_depth = maxf(0.3, initial_activity_depth_m if initial_activity_depth_m >= 0.0 else profile.surface_activity_depth_m.x)
	var initial_behavior := "schooling" if profile.species_id == "herring" else (_choose_behavior(profile.species_id, school_seed + index, 0) if profile.species_id == "three_spined_stickleback" else "cruise")
	if profile.species_id == "three_spined_stickleback":
		initial_depth = _choose_stickleback_depth_target(profile, rng.randi(), 0, false)
	return {
		"local_position": anchor,
		"formation_anchor": anchor,
		"velocity": Vector2(cos(angle), sin(angle)) * initial_speed,
		"phase": rng.randf(),
		"amplitude_variation": rng.randf(),
		"color_variation": rng.randf_range(-0.4, 0.4),
		"depth_variation": rng.randf_range(-0.55, 0.55),
		"vertical_offset": rng.randf_range(-0.25, 0.25),
		"random_seed": rng.randi(),
		"state_timer": rng.randf_range(1.0, 5.0),
		"behavior_epoch": 0,
		"behavior_state": initial_behavior,
		"routine_behavior": initial_behavior,
		"disturbance_state": "cruising",
		"threat_level": 0.0,
		"surface_disturbance_state": "cruising",
		"surface_recovery_remaining": 0.0,
		"surface_threat_level": 0.0,
		"peak_threat": 0.0,
		"regroup_remaining": 0.0,
		"regroup_duration": 0.0,
		"reaction_sensitivity": rng.randf_range(0.90, 1.12),
		"escape_bias_radians": rng.randf_range(-0.22, 0.22),
		"turn_bias": rng.randf_range(-0.8, 0.8),
		"speed": profile.movement_speed_min_mps,
		"visual_length_m": visual_length,
		"swim_depth_m": initial_depth,
		"depth_target_m": initial_depth,
		"is_fleeing": false,
	}


func _choose_visual_length(profile: FishSpeciesProfile, rng: RandomNumberGenerator) -> float:
	if profile.species_id == "three_spined_stickleback":
		var roll := rng.randf()
		if roll < 0.12:
			return rng.randf_range(0.16, 0.19)
		if roll < 0.86:
			return rng.randf_range(0.19, 0.21)
		return rng.randf_range(0.21, 0.23)
	var length := profile.target_visual_length_m
	if profile.visual_length_range_m.x > 0.0 and profile.visual_length_range_m.y > profile.visual_length_range_m.x:
		length = rng.randf_range(profile.visual_length_range_m.x, profile.visual_length_range_m.y)
	if profile.species_id in ["needlefish", "herring"]:
		length *= profile.visual_scale_multiplier
	return length


func _choose_stickleback_depth_target(profile: FishSpeciesProfile, seed: int, epoch: int, fleeing: bool) -> float:
	var rng := RandomNumberGenerator.new()
	rng.seed = FishLocalAuthority.hash32(seed, epoch, 9371)
	if fleeing:
		return rng.randf_range(profile.flee_swim_depth_m.x, profile.flee_swim_depth_m.y)
	if rng.randf() < profile.near_surface_visit_probability:
		return rng.randf_range(profile.near_surface_depth_m.x, profile.near_surface_depth_m.y)
	return rng.randf_range(profile.preferred_swim_depth_m.x, profile.preferred_swim_depth_m.y)


func _school_wander_radius(profile: FishSpeciesProfile) -> float:
	if profile.species_id == "three_spined_stickleback":
		return profile.school_activity_radius_m
	return 6.5 if profile.species_id == "herring" else (5.2 if profile.species_id == "needlefish" else 2.4)


func _build_neighbor_grid(positions: Array[Vector2]) -> Dictionary:
	var grid: Dictionary = {}
	for index in range(positions.size()):
		var key := Vector2i(floori(positions[index].x / 2.0), floori(positions[index].y / 2.0))
		if not grid.has(key):
			grid[key] = []
		grid[key].append(index)
	return grid


func _neighbors_for_index(index: int, positions: Array[Vector2], velocities: Array[Vector2], grid: Dictionary, search_cells: int = 1) -> Array[int]:
	var key := Vector2i(floori(positions[index].x / 2.0), floori(positions[index].y / 2.0))
	var result: Array[int] = []
	for y in range(key.y - search_cells, key.y + search_cells + 1):
		for x in range(key.x - search_cells, key.x + search_cells + 1):
			for neighbor in grid.get(Vector2i(x, y), []):
				result.append(int(neighbor))
	return result


func _vertical_depth_offset(profile: FishSpeciesProfile, depth: float, variation: float) -> float:
	match profile.vertical_layer:
		"surface":
			return clampf(1.2 + variation * 0.9, 0.6, minf(3.4, maxf(0.6, depth - 0.4)))
		"near_bottom":
			return maxf(0.45, depth - 0.85 - variation * 0.25)
		_:
			return clampf(depth * 0.30 + variation * 1.4, 1.2, minf(13.0, maxf(1.2, depth - 0.45)))


func _surface_height(position: Vector3) -> float:
	if _wave_sampler == null:
		return 0.0
	var time := _wave_sampler.wave_time_seconds
	return float(_wave_sampler.sample_surface(position, time).get("height", 0.0))


func _render_state_for_activity_depth(depth_m: float) -> String:
	return "visual" if depth_m <= 6.0 else "logical"


func _species_share(species_id: String) -> float:
	match species_id:
		"herring": return 0.57
		"needlefish": return 0.25
		_: return 0.18


func _species_flee_radius(species_id: String) -> float:
	match species_id:
		"needlefish": return surface_fish_scatter_radius_m
		"herring": return surface_fish_scatter_radius_m
		_: return 24.0


func _choose_behavior(species_id: String, seed: int, epoch: int) -> String:
	var roll := FishLocalAuthority.hash01(seed, epoch, 5519)
	if species_id == "herring":
		return "turn" if roll < 0.12 else "schooling"
	if species_id == "needlefish":
		if roll < 0.11: return "burst"
		if roll < 0.25: return "turn"
		return "cruise"
	if species_id == "three_spined_stickleback":
		if roll < 0.27: return "hover"
		if roll < 0.51: return "turn"
		if roll < 0.57: return "burst"
		return "cruise"
	if roll < 0.22: return "idle"
	if roll < 0.40: return "turn"
	if roll < 0.49: return "burst"
	return "cruise"


func _behavior_duration(species_id: String, seed: int, epoch: int) -> float:
	var value := FishLocalAuthority.hash01(seed, epoch, 947)
	return lerpf(3.0, 8.0, value) if species_id == "herring" else lerpf(1.3, 6.0, value)


func _behavior_speed_scale(state: String) -> float:
	match state:
		"idle", "hover": return 0.22
		"alert": return 1.22
		"burst", "flee": return 2.15
		"regrouping": return 1.05
		"turn": return 0.75
		_: return 1.0


func _limit_velocity_turn(previous_velocity: Vector2, next_velocity: Vector2, species_id: String, delta: float, fleeing: bool) -> Vector2:
	if previous_velocity.length_squared() < 0.0001 or next_velocity.length_squared() < 0.0001:
		return next_velocity
	var turn_rate := 1.15 if species_id == "herring" else (1.7 if species_id == "needlefish" else (1.35 if species_id == "three_spined_stickleback" else 2.2))
	if fleeing:
		turn_rate *= 1.8
	var max_turn := turn_rate * maxf(delta, 0.0)
	var angle_delta := wrapf(next_velocity.angle() - previous_velocity.angle(), -PI, PI)
	if absf(angle_delta) <= max_turn:
		return next_velocity
	return previous_velocity.normalized().rotated(signf(angle_delta) * max_turn) * next_velocity.length()
