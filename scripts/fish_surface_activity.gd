class_name FishSurfaceActivity
extends Node3D

## One nearby, batched ripple field for schools close to the mean water surface.
## The field is visual-only and never changes school/resource state.

const RIPPLE_SHADER := preload("res://shaders/fish_surface_ripple.gdshader")
const MAX_RIPPLES := 72
const MAX_SCHOOLS := 12
const UPDATE_INTERVAL := 0.12
const VISIBLE_RADIUS_M := 90.0

var _wave_sampler: WaveSampler
var _boat: Node3D
var _multimesh_instance: MultiMeshInstance3D
var _multimesh: MultiMesh
var _ripple_records: Array[Dictionary] = []
var _active_ripple_count := 0
var _elapsed := 0.0


func _ready() -> void:
	_build_batch()


func configure(wave_sampler: WaveSampler, boat: Node3D) -> void:
	_wave_sampler = wave_sampler
	_boat = boat


func set_active_schools(schools: Array[Dictionary]) -> void:
	_ripple_records.clear()
	if not is_instance_valid(_boat):
		_active_ripple_count = 0
		return
	var eligible_schools: Array[Dictionary] = []
	for school in schools:
		var position: Vector3 = school.get("world_position", Vector3.ZERO)
		var distance := Vector2(position.x - _boat.global_position.x, position.z - _boat.global_position.z).length()
		if distance > VISIBLE_RADIUS_M:
			continue
		var depth := maxf(0.0, float(school.get("activity_depth_m", 99.0)))
		if depth > 2.0:
			continue
		var strength := _depth_strength(depth)
		if strength <= 0.01:
			continue
		eligible_schools.append({
			"distance_squared": distance * distance,
			"school_id": str(school.get("school_id", "")),
			"species_id": str(school.get("species_id", "")),
			"world_position": position,
			"strength": strength,
			"population": int(school.get("population", 0)),
		})
	eligible_schools.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["distance_squared"]) < float(b["distance_squared"])
	)
	var selected_schools := 0
	for school in eligible_schools:
		if selected_schools >= MAX_SCHOOLS or _ripple_records.size() >= MAX_RIPPLES:
			break
		var position: Vector3 = school["world_position"]
		var strength := float(school["strength"])
		var species_id := str(school["species_id"])
		var population := int(school["population"])
		var ripple_count := clampi(roundi(float(population) / 12.0), 3, 8) if species_id == "herring" else (2 if species_id == "needlefish" and population >= 6 else 1)
		var rng := RandomNumberGenerator.new()
		rng.seed = str(school["school_id"]).hash()
		for index in range(ripple_count):
			if _ripple_records.size() >= MAX_RIPPLES:
				break
			var angle := TAU * float(index) / float(ripple_count) + rng.randf_range(-0.38, 0.38)
			var offset_radius := rng.randf_range(0.35, 2.0)
			var diameter := rng.randf_range(2.2, 4.4)
			var phase := rng.randf()
			var speed := rng.randf()
			_ripple_records.append({
				"school_id": str(school["school_id"]),
				"anchor": position,
				"offset": Vector2(cos(angle), sin(angle)) * offset_radius,
				"scale": diameter * 0.5,
				"custom": Color(phase, speed, strength, rng.randf()),
			})
		selected_schools += 1
	_active_ripple_count = _ripple_records.size()
	_multimesh.visible_instance_count = _active_ripple_count
	_multimesh_instance.visible = _active_ripple_count > 0
	_update_wave_positions(true)


func get_active_ripple_count() -> int:
	return _active_ripple_count


func _process(delta: float) -> void:
	if _active_ripple_count <= 0 or not is_instance_valid(_boat):
		return
	_elapsed += delta
	if _elapsed >= UPDATE_INTERVAL:
		_elapsed = fmod(_elapsed, UPDATE_INTERVAL)
		_update_wave_positions(false)


func _build_batch() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(2.0, 2.0)
	plane.subdivide_width = 1
	plane.subdivide_depth = 1
	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_multimesh.use_custom_data = true
	_multimesh.mesh = plane
	_multimesh.instance_count = MAX_RIPPLES
	_multimesh.visible_instance_count = 0
	_multimesh.custom_aabb = AABB(Vector3(-120.0, -6.0, -120.0), Vector3(240.0, 18.0, 240.0))
	var material := ShaderMaterial.new()
	material.shader = RIPPLE_SHADER
	_multimesh_instance = MultiMeshInstance3D.new()
	_multimesh_instance.name = "SurfaceRippleBatch"
	_multimesh_instance.multimesh = _multimesh
	_multimesh_instance.material_override = material
	_multimesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_multimesh_instance.visible = false
	add_child(_multimesh_instance)


func _update_wave_positions(force: bool) -> void:
	if _wave_sampler == null or _active_ripple_count <= 0:
		return
	_multimesh_instance.global_position = _boat.global_position
	var wave_time := _wave_sampler.wave_time_seconds
	for index in range(_active_ripple_count):
		var record: Dictionary = _ripple_records[index]
		var anchor: Vector3 = record["anchor"]
		var offset: Vector2 = record["offset"]
		var ripple_xz := Vector3(anchor.x + offset.x, 0.0, anchor.z + offset.y)
		var sample := _wave_sampler.sample_surface(ripple_xz, wave_time)
		var world_position := Vector3(ripple_xz.x, float(sample.get("height", anchor.y)) + 0.035, ripple_xz.z)
		var local_position := world_position - _boat.global_position
		var size := float(record["scale"])
		var basis := Basis(Vector3.UP, atan2(offset.y, offset.x)).scaled(Vector3(size, 1.0, size))
		_multimesh.set_instance_transform(index, Transform3D(basis, local_position))
		if force or index >= _multimesh.visible_instance_count:
			_multimesh.set_instance_custom_data(index, record["custom"])


func _depth_strength(depth: float) -> float:
	if depth <= 0.5:
		return 1.0
	if depth <= 1.2:
		return lerpf(0.82, 0.58, smoothstep(0.5, 1.2, depth))
	return lerpf(0.58, 0.16, smoothstep(1.2, 2.0, depth))
