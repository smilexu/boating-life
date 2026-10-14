@tool
class_name WaveSampler
extends Node

## CPU counterpart to the surface-displacement section in sea_water.gdshader.
## Wave settings and strength are also written to the shader from this node, so
## the boat and visible sea use the same parameters and shared time value.

const MAX_SHADER_WAVES := 8
const TIME_WRAP_SECONDS := 3600.0
const INVERSE_ITERATIONS := 4

@export_node_path("Node3D") var ocean_path := NodePath("../Ocean")

@export var wave_settings: SeaWaveSettings:
	set(value):
		wave_settings = value
		_apply_wave_parameters()

@export var water_material: ShaderMaterial:
	set(value):
		water_material = value
		_apply_wave_parameters()

@export_range(0.0, 2.0, 0.05) var wave_strength := 1.25:
	set(value):
		wave_strength = value
		_apply_wave_parameters()

var wave_time_seconds := 0.0
var _ocean: Node3D


func _enter_tree() -> void:
	add_to_group("wave_sampler")


func _ready() -> void:
	_ocean = get_node_or_null(ocean_path) as Node3D
	_apply_wave_parameters()


func _process(delta: float) -> void:
	if Engine.is_editor_hint() or water_material == null:
		return

	wave_time_seconds = fposmod(wave_time_seconds + delta, TIME_WRAP_SECONDS)
	water_material.set_shader_parameter("WaveTime", wave_time_seconds)


## `world_position.xz` is a world-space position on the undeformed water plane.
## The sampler inverts Gerstner horizontal displacement before returning height
## and the shader's approximate normal at that world-space location.
func sample_surface(world_position: Vector3, sample_time_seconds: float) -> Dictionary:
	var water_y := _get_water_plane_y()
	if wave_settings == null or wave_settings.waves.is_empty():
		return {"height": water_y, "normal": Vector3.UP, "displacement": Vector3.ZERO}

	var effective_time := sample_time_seconds
	if water_material != null and bool(water_material.get_shader_parameter("freeze_time")):
		effective_time = 0.0

	var target_xz := Vector2(world_position.x, world_position.z)
	var source_xz := target_xz
	for _iteration in range(INVERSE_ITERATIONS):
		var field := _calculate_wave_field(source_xz, effective_time)
		var fade := _vertex_wave_fade(source_xz, water_y)
		var displacement: Vector3 = field["displacement"]
		source_xz = target_xz - Vector2(displacement.x, displacement.z) * fade

	var final_field := _calculate_wave_field(source_xz, effective_time)
	var final_fade := _vertex_wave_fade(source_xz, water_y)
	var final_displacement: Vector3 = final_field["displacement"] * final_fade
	var wave_normal: Vector3 = final_field["normal"].normalized()
	var final_normal := Vector3.UP.lerp(wave_normal, final_fade).normalized()
	return {
		"height": water_y + final_displacement.y,
		"normal": final_normal,
		"displacement": final_displacement,
		"source_xz": source_xz,
	}


func _calculate_wave_field(source_xz: Vector2, sample_time_seconds: float) -> Dictionary:
	var wave_count := mini(wave_settings.waves.size(), MAX_SHADER_WAVES)
	var displacement := Vector3.ZERO
	var normal_sum := Vector3.ZERO
	if wave_count == 0:
		return {"displacement": displacement, "normal": Vector3.UP}

	for index in range(wave_count):
		var wave: GerstnerWave = wave_settings.waves[index]
		var direction_radians := deg_to_rad(wave.direction_degrees)
		var direction := Vector2(sin(direction_radians), cos(direction_radians))
		var phase_radians := deg_to_rad(wave.phase_degrees)
		var steepness := wave.steepness * wave_strength
		var amplitude := wave.amplitude * wave_strength
		var theta := (
			TAU * wave.frequency * direction.dot(source_xz)
			+ wave.speed * (sample_time_seconds + phase_radians)
		)
		var cosine := cos(theta)
		var sine := sin(theta)

		# Matches P_DEG: steepness drives vertical height; amplitude scales
		# horizontal particle displacement as well as the normal calculation.
		displacement.x += steepness * amplitude * direction.x * cosine
		displacement.y += steepness * sine
		displacement.z += steepness * amplitude * direction.y * cosine

		# Matches N_DEG from the water shader before its final normalization.
		normal_sum.x += -direction.x * wave.frequency * amplitude * cosine
		normal_sum.y += 1.0 - steepness * wave.frequency * amplitude * sine
		normal_sum.z += -direction.y * wave.frequency * amplitude * cosine

	var divisor := float(wave_count)
	return {"displacement": displacement / divisor, "normal": normal_sum / divisor}


func _vertex_wave_fade(source_xz: Vector2, water_y: float) -> float:
	if water_material == null:
		return 1.0
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return 1.0

	var fade_min := float(water_material.get_shader_parameter("vertex_wave_fade_min"))
	var fade_max := float(water_material.get_shader_parameter("vertex_wave_fade_max"))
	if fade_max <= fade_min:
		return 1.0
	var base_position := Vector3(source_xz.x, water_y, source_xz.y)
	var camera_distance := base_position.distance_to(camera.global_position)
	var blend := clampf((camera_distance - fade_min) / (fade_max - fade_min), 0.0, 1.0)
	return 1.0 - blend * blend * (3.0 - 2.0 * blend)


func _get_water_plane_y() -> float:
	return _ocean.global_position.y if _ocean != null else 0.0


func _apply_wave_parameters() -> void:
	if wave_settings == null or water_material == null:
		return

	var count := mini(wave_settings.waves.size(), MAX_SHADER_WAVES)
	var steepnesses := PackedFloat32Array()
	var amplitudes := PackedFloat32Array()
	var directions := PackedFloat32Array()
	var frequencies := PackedFloat32Array()
	var speeds := PackedFloat32Array()
	var phases := PackedFloat32Array()
	for index in range(count):
		var wave: GerstnerWave = wave_settings.waves[index]
		steepnesses.append(wave.steepness * wave_strength)
		amplitudes.append(wave.amplitude * wave_strength)
		directions.append(wave.direction_degrees)
		frequencies.append(wave.frequency)
		speeds.append(wave.speed)
		phases.append(wave.phase_degrees)

	water_material.set_shader_parameter("WaveCount", count)
	water_material.set_shader_parameter("WaveSteepnesses", steepnesses)
	water_material.set_shader_parameter("WaveAmplitudes", amplitudes)
	water_material.set_shader_parameter("WaveDirectionsDegrees", directions)
	water_material.set_shader_parameter("WaveFrequencies", frequencies)
	water_material.set_shader_parameter("WaveSpeeds", speeds)
	water_material.set_shader_parameter("WavePhases", phases)
	water_material.set_shader_parameter("WaveTime", wave_time_seconds)
