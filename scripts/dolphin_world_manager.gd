class_name DolphinWorldManager
extends Node3D

## Local world authority and client-only rendering for the small Öresund dolphin pod.
## A future server adapter can replace the local adapter without changing F3/F4.

const LOCAL_AUTHORITY_SCRIPT := preload("res://scripts/dolphin_local_authority.gd")
const DOLPHIN_VISUAL_SCRIPT := preload("res://scripts/dolphin_visual.gd")
const DOLPHIN_SCENE := preload("res://assets/fishes/dolphin_optimized.glb")
const MICRO_SPLASH_POOL_SIZE := 4
const IMPACT_SPLASH_POOL_SIZE := 4
const SURFACE_SPLASH_MIN_INTERVAL := 2.8
const SURFACE_SPLASH_MAX_INTERVAL := 4.5

@export_category("World authority")
@export var world_seed := DolphinLocalAuthority.DEFAULT_SEED
@export_node_path("Node") var bathymetry_path := NodePath("../BathymetryManager")
@export_node_path("Node3D") var boat_path := NodePath("../PlayerBoat/MotionRoot")
@export_node_path("Node") var wave_sampler_path := NodePath("../WaveSampler")
@export_category("Presentation")
@export_range(500.0, 4000.0, 100.0) var visual_activation_radius_m := 1800.0
@export_range(2.2, 3.0, 0.05) var average_visual_length_m := 2.65
@export_range(0.25, 0.40, 0.01) var natural_encounter_probability := 0.32
@export_category("Follow behavior")
@export_range(0.0, 10.0, 0.25) var follow_max_catchup_bonus_mps := 5.0
@export_range(8.0, 60.0, 1.0) var follow_catchup_full_distance_m := 28.0
@export_range(0.5, 10.0, 0.1) var follow_acceleration_mps2 := 4.0

var _bathymetry: BathymetryManager
var _georeference: GeoReference
var _boat: Node3D
var _wave_sampler: WaveSampler
var _authority: DolphinAuthorityAdapter
var _visuals: Dictionary = {}
var _micro_splash_pool: Array[GPUParticles3D] = []
var _impact_splash_pool: Array[GPUParticles3D] = []
var _splash_in_use: Dictionary = {}
var _splash_expiry_clock: Dictionary = {}
var _splash_cursor := {"micro": 0, "impact": 0}
var _surface_contact_samples: Dictionary = {}
var _surface_splash_next_time: Dictionary = {}
var _leap_splash_latches: Dictionary = {}
var _splash_rng := RandomNumberGenerator.new()
var _simulation_clock := 0.0
var _micro_splash_emissions := 0
var _impact_splash_emissions := 0
var _surface_contact_count := 0
var _ready_for_updates := false


func _ready() -> void:
	add_to_group("dolphin_world_manager")
	_bathymetry = get_node_or_null(bathymetry_path) as BathymetryManager
	_boat = get_node_or_null(boat_path) as Node3D
	_wave_sampler = get_node_or_null(wave_sampler_path) as WaveSampler
	_georeference = _bathymetry.georeference if _bathymetry != null else null
	if _bathymetry == null or _georeference == null:
		push_warning("DolphinWorldManager disabled: bathymetry or GeoReference is unavailable.")
		return
	_authority = LOCAL_AUTHORITY_SCRIPT.new() as DolphinAuthorityAdapter
	if _authority == null or not _authority.initialize(_bathymetry, _georeference, world_seed):
		push_warning("DolphinWorldManager could not initialize the local authority.")
		return
	_authority.set_natural_encounter_probability(natural_encounter_probability)
	_authority.configure_follow_motion(follow_max_catchup_bonus_mps, follow_catchup_full_distance_m, follow_acceleration_mps2)
	_splash_rng.seed = world_seed ^ 0xD01F1A
	_build_splash_pool()
	_ready_for_updates = true


func _process(delta: float) -> void:
	if not _ready_for_updates or _authority == null:
		return
	_simulation_clock += delta
	for snapshot in _authority.get_dolphin_snapshots():
		var dolphin_position := _snapshot_position(snapshot)
		_authority.set_surface_height_reference(str(snapshot.get("dolphin_id", "")), _sample_water_height(dolphin_position))
	if is_instance_valid(_boat):
		var boat_speed := float(_boat.get("speed_mps"))
		if bool(_boat.get("is_motion_paused")):
			boat_speed = 0.0
		_authority.update(delta, _boat.global_position, -_boat.global_transform.basis.z, boat_speed)
	else:
		_authority.update(delta, Vector3.ZERO, Vector3.FORWARD, 0.0)
	var snapshots := _authority.get_dolphin_snapshots()
	_update_visuals(snapshots, delta)
	_update_splash_pool_lifecycle()


func get_map_snapshot() -> Array[Dictionary]:
	return _authority.get_map_snapshot() if _authority != null else []


func get_authority_snapshot() -> Dictionary:
	if _authority == null:
		return {}
	var snapshot := _authority.create_snapshot()
	snapshot["authority_source"] = _authority.authority_source_name()
	snapshot["authoritative_timestamp"] = int(Time.get_unix_time_from_system())
	return snapshot


func apply_authority_snapshot(snapshot: Dictionary) -> bool:
	if _authority == null or int(snapshot.get("state_revision", -1)) < _authority.get_state_revision():
		return false
	return _authority.restore_snapshot(snapshot)


func set_authority_adapter(adapter: DolphinAuthorityAdapter) -> bool:
	if adapter == null or _bathymetry == null or _georeference == null:
		return false
	_authority = adapter
	var initialized := _authority.initialize(_bathymetry, _georeference, world_seed)
	if initialized:
		_authority.set_natural_encounter_probability(natural_encounter_probability)
		_authority.configure_follow_motion(follow_max_catchup_bonus_mps, follow_catchup_full_distance_m, follow_acceleration_mps2)
	return initialized


func request_follow_event(boat_position: Vector3, boat_forward: Vector3, duration_seconds: float = 60.0) -> bool:
	return _authority != null and _authority.request_follow_event(boat_position, boat_forward, duration_seconds, false)


## F3-only helper: it moves the boat to a safe observation location when needed;
## it never moves or creates an animal. The active camera remains the boat camera.
func debug_summon_follow(boat: Node3D) -> Dictionary:
	if _authority == null or not is_instance_valid(boat):
		return {"accepted": false, "reason": "海豚管理器或船只不可用。"}
	var map_data := _authority.get_map_snapshot()
	if map_data.is_empty():
		return {"accepted": false, "reason": "当前没有可用海豚实体。"}
	var position_data: Array = map_data[0].get("world_position", [])
	if position_data.size() != 3:
		return {"accepted": false, "reason": "海豚位置数据不可用。"}
	var pod_position := Vector3(float(position_data[0]), boat.global_position.y, float(position_data[2]))
	var boat_distance := Vector2(boat.global_position.x - pod_position.x, boat.global_position.z - pod_position.z).length()
	if boat_distance > 90.0:
		var destination := _find_debug_boat_position(pod_position, boat.global_position.y)
		if not bool(destination.get("valid", false)):
			return {"accepted": false, "reason": "活动海域附近没有找到足够深的安全观察位置。"}
		boat.set("speed_mps", 0.0)
		boat.set("is_autopilot", false)
		boat.set("is_motion_paused", false)
		boat.global_position = destination["position"]
		var toward_pod := Vector3(pod_position.x - boat.global_position.x, 0.0, pod_position.z - boat.global_position.z).normalized()
		boat.global_rotation.y = atan2(-toward_pod.x, -toward_pod.z)
		var wake := boat.get_node_or_null("VisualRoot/WakeSystem")
		if wake != null and wake.has_method("reset_wake"):
			wake.call("reset_wake")
	if not _authority.request_follow_event(boat.global_position, -boat.global_transform.basis.z, 75.0, true):
		return {"accepted": false, "reason": "海豚正忙于当前行为，请稍等片刻再试。"}
	return {"accepted": true, "teleported_boat": boat_distance > 90.0, "pod_distance_m": boat.global_position.distance_to(pod_position)}


func trigger_debug_leap() -> bool:
	return _authority != null and _authority.request_leap()


func get_debug_status() -> Dictionary:
	var snapshots: Array[Dictionary] = []
	if _authority != null:
		snapshots = _authority.get_dolphin_snapshots()
	var surface_count := 0
	var leap_count := 0
	var leap_debug: Dictionary = {}
	for snapshot in snapshots:
		if str(snapshot.get("behavior_state", "")) in ["surface_approach", "surface"]:
			surface_count += 1
		elif str(snapshot.get("behavior_state", "")) == "leap":
			leap_count += 1
			var visual: DolphinVisual = _visuals.get(str(snapshot.get("dolphin_id", ""))) as DolphinVisual
			if visual != null and leap_debug.is_empty():
				leap_debug = visual.get_motion_debug()
	var follow_leaps: Dictionary = _authority.get_follow_leap_status() if _authority is DolphinLocalAuthority else {}
	var follow_speed_thresholds: Dictionary = _authority.get_follow_speed_thresholds() if _authority is DolphinLocalAuthority else {}
	var scheduled_leaps := int(follow_leaps.get("started", 0)) + int(follow_leaps.get("remaining", 0))
	var active_splash_count := 0
	for emitter in _splash_in_use.keys():
		if bool(_splash_in_use[emitter]):
			active_splash_count += 1
	return {
		"authority": _authority.authority_source_name() if _authority != null else "Unavailable",
		"population": snapshots.size(),
		"rendered": _visuals.size(),
		"following": _authority.is_following() if _authority is DolphinLocalAuthority else false,
		"follow_mode": _authority.get_follow_mode() if _authority is DolphinLocalAuthority else "inactive",
		"follow_orbit_enter_mps": float(follow_speed_thresholds.get("orbit_enter_mps", 0.0)),
		"follow_cruise_resume_mps": float(follow_speed_thresholds.get("cruise_resume_mps", 0.0)),
		"follow_mode_transition_seconds": float(follow_speed_thresholds.get("transition_seconds", 0.0)),
		"follow_remaining": _authority.get_follow_remaining() if _authority is DolphinLocalAuthority else 0.0,
		"surface_count": surface_count,
		"leap_count": leap_count,
		"follow_leaps_started": int(follow_leaps.get("started", 0)),
		"follow_leaps_completed": int(follow_leaps.get("completed", 0)),
		"follow_leaps_scheduled": scheduled_leaps,
		"follow_leaps_remaining": int(follow_leaps.get("remaining", 0)),
		"follow_next_leap_in": float(follow_leaps.get("next_in", -1.0)),
		"leap_motion": leap_debug,
		"micro_splash_emissions": _micro_splash_emissions,
		"impact_splash_emissions": _impact_splash_emissions,
		"surface_contact_count": _surface_contact_count,
		"active_splash_emitters": active_splash_count,
	}


func get_surface_reveal_candidates() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not is_instance_valid(_boat) or _authority == null:
		return result
	for snapshot in _authority.get_dolphin_snapshots():
		var depth := float(snapshot.get("activity_depth_m", 99.0))
		if depth > 6.0:
			continue
		var pos := _snapshot_position(snapshot)
		var distance_squared := Vector2(pos.x - _boat.global_position.x, pos.z - _boat.global_position.z).length_squared()
		if distance_squared > 90.0 * 90.0:
			continue
		var weight := 1.0 - smoothstep(1.2, 5.8, depth)
		if weight > 0.01:
			result.append({
				"distance_squared": distance_squared,
				"position": Vector3(pos.x, 0.0, pos.z),
				"radius": 18.0,
				"weight": weight * 0.78,
			})
	return result


func _update_visuals(snapshots: Array[Dictionary], delta: float) -> void:
	var boat_position := _boat.global_position if is_instance_valid(_boat) else Vector3.ZERO
	var active_ids: Dictionary = {}
	for snapshot in snapshots:
		var dolphin_id := str(snapshot.get("dolphin_id", ""))
		var position := _snapshot_position(snapshot)
		var distance := Vector2(position.x - boat_position.x, position.z - boat_position.z).length()
		if distance <= visual_activation_radius_m:
			active_ids[dolphin_id] = true
			if not _visuals.has(dolphin_id):
				_create_visual(snapshot)
			if _visuals.has(dolphin_id):
				var visual: DolphinVisual = _visuals[dolphin_id]
				var wave_height := _sample_water_height(position)
				visual.set_snapshot(snapshot)
				visual.advance_visual(delta, _simulation_clock, wave_height)
				_update_water_contact_effects(dolphin_id, visual, str(snapshot.get("behavior_state", "swim")), distance)
		elif _surface_contact_samples.has(dolphin_id):
			_surface_contact_samples.erase(dolphin_id)
			_surface_splash_next_time.erase(dolphin_id)
			_leap_splash_latches.erase(dolphin_id)
	for dolphin_id in _visuals.keys():
		if not active_ids.has(dolphin_id):
			(_visuals[dolphin_id] as Node3D).queue_free()
			_visuals.erase(dolphin_id)


func _create_visual(snapshot: Dictionary) -> void:
	var visual := DOLPHIN_VISUAL_SCRIPT.new() as DolphinVisual
	var index := int(snapshot.get("index", 0))
	var length := average_visual_length_m + float(index % 3 - 1) * 0.12
	var phase := float(index) * 1.37
	if not visual.configure(DOLPHIN_SCENE, snapshot, length, phase):
		visual.free()
		push_warning("Could not create dolphin visual for %s." % str(snapshot.get("dolphin_id", "")))
		return
	visual.name = "Dolphin_%02d" % (index + 1)
	add_child(visual)
	_visuals[str(snapshot["dolphin_id"])] = visual


func _sample_water_height(position: Vector3) -> float:
	if _wave_sampler == null:
		return 0.0
	var sample := _wave_sampler.sample_surface(Vector3(position.x, 0.0, position.z), _wave_sampler.wave_time_seconds)
	return float(sample.get("height", 0.0))


func _find_debug_boat_position(pod_position: Vector3, boat_y: float) -> Dictionary:
	for radius in [85.0, 100.0, 120.0]:
		for index in range(16):
			var angle := TAU * float(index) / 16.0
			var candidate := Vector3(pod_position.x + cos(angle) * radius, boat_y, pod_position.z + sin(angle) * radius)
			var depth_sample := _bathymetry.get_depth_at_world_position(candidate)
			if bool(depth_sample.get("valid", false)) and float(depth_sample.get("depth_m", 0.0)) >= 10.0:
				return {"valid": true, "position": candidate, "depth_m": float(depth_sample["depth_m"])}
	return {"valid": false}


func _snapshot_position(snapshot: Dictionary) -> Vector3:
	var values: Array = snapshot.get("world_position", [])
	if values.size() < 3:
		return Vector3.ZERO
	return Vector3(float(values[0]), 0.0, float(values[2]))


func _build_splash_pool() -> void:
	var droplet_mesh := SphereMesh.new()
	droplet_mesh.radius = 0.04
	droplet_mesh.height = 0.08
	droplet_mesh.radial_segments = 8
	droplet_mesh.rings = 4
	var droplet_material := StandardMaterial3D.new()
	droplet_material.albedo_color = Color(0.84, 0.89, 0.90, 1.0)
	# Alpha-blended particles were sorted behind the project's transparent water
	# and became effectively invisible. Lit opaque droplets render reliably;
	# the shared scale curve tapers them to zero over their short lifetime.
	droplet_material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	droplet_material.roughness = 0.55
	droplet_material.metallic = 0.0
	droplet_material.vertex_color_use_as_albedo = true
	droplet_mesh.material = droplet_material
	var color_ramp := _make_splash_color_ramp()
	var scale_curve := _make_splash_scale_curve()
	var micro_material := _make_splash_process_material(color_ramp, scale_curve, 0.045, 0.75, 1.8, 58.0, Vector3(0.0, -8.8, 0.0), 0.95, 1.7)
	var impact_material := _make_splash_process_material(color_ramp, scale_curve, 0.07, 1.1, 3.4, 72.0, Vector3(0.0, -8.2, 0.0), 1.15, 2.2)
	for index in range(MICRO_SPLASH_POOL_SIZE):
		_create_splash_emitter(_micro_splash_pool, "DolphinMicroSplash_%d" % index, 8, 0.5, droplet_mesh, micro_material)
	for index in range(IMPACT_SPLASH_POOL_SIZE):
		_create_splash_emitter(_impact_splash_pool, "DolphinEntrySplash_%d" % index, 26, 0.72, droplet_mesh, impact_material)


func _make_splash_process_material(color_ramp: GradientTexture1D, scale_curve: CurveTexture, radius: float, velocity_min: float, velocity_max: float, spread_degrees: float, gravity: Vector3, scale_min: float, scale_max: float) -> ParticleProcessMaterial:
	var material := ParticleProcessMaterial.new()
	material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	material.emission_sphere_radius = radius
	material.direction = Vector3.UP
	material.spread = spread_degrees
	material.initial_velocity_min = velocity_min
	material.initial_velocity_max = velocity_max
	material.gravity = gravity
	material.scale_min = scale_min
	material.scale_max = scale_max
	material.scale_curve = scale_curve
	material.color = Color.WHITE
	material.color_ramp = color_ramp
	return material


func _make_splash_color_ramp() -> GradientTexture1D:
	var gradient := Gradient.new()
	gradient.set_color(0, Color(0.94, 0.97, 0.98, 1.0))
	gradient.add_point(0.28, Color(0.88, 0.92, 0.93, 1.0))
	gradient.add_point(0.70, Color(0.78, 0.84, 0.85, 1.0))
	gradient.set_color(gradient.get_point_count() - 1, Color(0.70, 0.77, 0.79, 1.0))
	var texture := GradientTexture1D.new()
	texture.gradient = gradient
	return texture


func _make_splash_scale_curve() -> CurveTexture:
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.75))
	curve.add_point(Vector2(0.18, 1.0))
	curve.add_point(Vector2(0.72, 0.72))
	curve.add_point(Vector2(1.0, 0.0))
	var texture := CurveTexture.new()
	texture.curve = curve
	return texture


func _create_splash_emitter(pool: Array[GPUParticles3D], emitter_name: String, amount: int, lifetime: float, droplet_mesh: SphereMesh, process_material: ParticleProcessMaterial) -> void:
	var particles := GPUParticles3D.new()
	particles.name = emitter_name
	particles.amount = amount
	particles.lifetime = lifetime
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.local_coords = false
	particles.emitting = false
	particles.visible = false
	particles.visibility_aabb = AABB(Vector3(-3.5, -1.5, -3.5), Vector3(7.0, 5.0, 7.0))
	particles.draw_pass_1 = droplet_mesh
	particles.process_material = process_material
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(particles)
	pool.append(particles)
	_splash_in_use[particles.get_instance_id()] = false


func _update_water_contact_effects(dolphin_id: String, visual: DolphinVisual, behavior: String, boat_distance: float) -> void:
	var body_bounds := visual.get_body_world_y_bounds()
	var body_center := visual.global_position
	var body_water_height := _sample_water_height(body_center)
	var leading_point := visual.get_body_front_world_point()
	var leading_water_height := _sample_water_height(leading_point)
	var top_gap := body_bounds.y - body_water_height
	var bottom_gap := body_bounds.x - body_water_height
	var current_sample := {
		"leading_point": leading_point,
		"leading_water_height": leading_water_height,
		"top_gap": top_gap,
		"bottom_gap": bottom_gap,
		"body_water_height": body_water_height,
		"behavior": behavior,
	}
	var previous: Dictionary = _surface_contact_samples.get(dolphin_id, {})
	if behavior == "leap" and str(previous.get("behavior", "")) != "leap":
		# A leap may begin between render frames. Reset per-leap event latches,
		# but leave the movement controller and trajectory untouched.
		_leap_splash_latches[dolphin_id] = {"exit_emitted": false, "entry_emitted": false}
		previous = current_sample.duplicate()
		previous["top_gap"] = minf(top_gap, -0.001)
		previous["bottom_gap"] = maxf(bottom_gap, 0.001)
		previous["behavior"] = "leap_start"
	if not previous.is_empty():
		var previous_top_gap := float(previous["top_gap"])
		var previous_bottom_gap := float(previous["bottom_gap"])
		var previous_behavior := str(previous.get("behavior", ""))
		var leap_latches: Dictionary = _leap_splash_latches.get(dolphin_id, {"exit_emitted": false, "entry_emitted": false})
		if behavior == "leap" and previous_top_gap <= 0.0 and top_gap > 0.0 and not bool(leap_latches.get("exit_emitted", false)):
			_emit_body_crossing_splash(visual.global_position, body_water_height, false)
			leap_latches["exit_emitted"] = true
		elif behavior in ["leap", "diving"] and previous_behavior in ["leap", "diving"] and previous_bottom_gap > 0.0 and bottom_gap <= 0.0 and not bool(leap_latches.get("entry_emitted", false)):
			_emit_body_crossing_splash(visual.global_position, body_water_height, true)
			leap_latches["entry_emitted"] = true
		elif behavior == "diving" and previous_behavior == "leap" and bottom_gap <= 0.0 and top_gap >= 0.0 and not bool(leap_latches.get("entry_emitted", false)):
			# State transitions can land between samples at the water contact.
			_emit_body_crossing_splash(visual.global_position, body_water_height, true)
			leap_latches["entry_emitted"] = true
		_leap_splash_latches[dolphin_id] = leap_latches
	_surface_contact_samples[dolphin_id] = current_sample

	if boat_distance > 90.0 or behavior not in ["surface_approach", "surface", "following", "orbiting"]:
		return
	var body_touches_water := body_bounds.x <= body_water_height + 0.08 and body_bounds.y >= body_water_height - 0.08
	if not body_touches_water:
		return
	_surface_contact_count += 1
	var next_time := float(_surface_splash_next_time.get(dolphin_id, -1.0))
	if next_time < 0.0:
		_surface_splash_next_time[dolphin_id] = _simulation_clock + _splash_rng.randf_range(0.3, 0.8)
	elif _simulation_clock >= next_time:
		var center_position := visual.global_position
		# The ocean surface occludes particles spawned almost exactly on the plane.
		# Lift the emitter just enough that the droplets begin visibly above it.
		center_position.y = body_water_height + 0.25
		_emit_splash(center_position, false)
		_surface_splash_next_time[dolphin_id] = _simulation_clock + _splash_rng.randf_range(SURFACE_SPLASH_MIN_INTERVAL, SURFACE_SPLASH_MAX_INTERVAL)



func _emit_body_crossing_splash(body_position: Vector3, water_height: float, impact: bool) -> void:
	var splash_position := body_position
	# Keep the horizontal contact point from WaveSampler, but start the particle
	# burst above the opaque water surface so the droplets are not hidden at birth.
	splash_position.y = water_height + (0.34 if impact else 0.25)
	_emit_splash(splash_position, impact)


func _emit_splash(position: Vector3, impact: bool) -> void:
	var pool := _impact_splash_pool if impact else _micro_splash_pool
	if pool.is_empty():
		return
	var pool_key := "impact" if impact else "micro"
	var start_index := int(_splash_cursor[pool_key])
	for offset in range(pool.size()):
		var index := (start_index + offset) % pool.size()
		var particles := pool[index]
		var instance_id := particles.get_instance_id()
		if bool(_splash_in_use.get(instance_id, false)):
			continue
		_splash_cursor[pool_key] = (index + 1) % pool.size()
		_splash_in_use[instance_id] = true
		_splash_expiry_clock[instance_id] = _simulation_clock + particles.lifetime + 0.12
		particles.global_position = position
		particles.visible = true
		particles.restart()
		particles.emitting = true
		if impact:
			_impact_splash_emissions += 1
		else:
			_micro_splash_emissions += 1
		return


func _update_splash_pool_lifecycle() -> void:
	# GPUParticles3D.is_emitting() only describes particle emission, not the
	# remaining lifetime of particles already spawned. Releasing on that signal
	# hides one-shot sprays almost immediately, so retire them after their lifetime.
	for emitter in _splash_in_use.keys():
		if not bool(_splash_in_use[emitter]):
			continue
		if _simulation_clock < float(_splash_expiry_clock.get(emitter, INF)):
			continue
		var particles := instance_from_id(int(emitter)) as GPUParticles3D
		if particles == null:
			_splash_in_use[emitter] = false
			_splash_expiry_clock.erase(emitter)
			continue
		_release_splash_emitter(particles)


func _release_splash_emitter(particles: GPUParticles3D) -> void:
	if not is_instance_valid(particles):
		return
	_splash_in_use[particles.get_instance_id()] = false
	_splash_expiry_clock.erase(particles.get_instance_id())
	particles.emitting = false
	particles.visible = false
