extends Node3D

## Four-point visual float response. This node only offsets and tilts VisualRoot;
## BoatController remains responsible for navigation position and heading.

const SAMPLE_NAMES := ["FL", "FR", "RL", "RR"]

@export_category("Wave Response")
@export_range(0.0, 2.0, 0.05) var buoyancy_strength := 1.0
@export_range(1.0, 20.0, 0.5) var pitch_limit_degrees := 8.0
@export_range(1.0, 20.0, 0.5) var roll_limit_degrees := 6.0
@export_range(0.1, 3.0, 0.05) var response_speed_hz := 0.85
@export_range(0.5, 1.5, 0.05) var damping_ratio := 0.92

@export_category("Sample Points")
@export_range(0.5, 2.5, 0.05) var fore_sample_distance := 1.65
@export_range(0.5, 2.5, 0.05) var aft_sample_distance := 1.55
@export_range(0.25, 1.2, 0.05) var half_beam := 0.72

@export_category("Debug")
@export var debug_show_samples := false:
	set(value):
		debug_show_samples = value
		if is_inside_tree() and _motion_root != null:
			_set_debug_visible(value)

var _motion_root: Node3D
var _wave_sampler: WaveSampler
var _sample_offsets: Array[Vector3] = []
var _debug_markers: Array[Node3D] = []
var _debug_labels: Array[Label3D] = []

var _heave := 0.0
var _heave_velocity := 0.0
var _pitch := 0.0
var _pitch_velocity := 0.0
var _roll := 0.0
var _roll_velocity := 0.0


func _ready() -> void:
	_motion_root = get_parent() as Node3D
	_wave_sampler = get_tree().get_first_node_in_group("wave_sampler") as WaveSampler
	_heave = position.y
	_build_sample_offsets()
	if _wave_sampler == null:
		push_warning("BoatBuoyancy: no WaveSampler found; visual float response is disabled.")
		set_physics_process(false)
		return
	_set_debug_visible(debug_show_samples)


func _process(delta: float) -> void:
	if _motion_root == null or _wave_sampler == null:
		return

	var heights := PackedFloat32Array()
	var world_points: Array[Vector3] = []
	var samples: Array[Dictionary] = []
	for local_offset in _sample_offsets:
		var point_world := _motion_root.global_transform * local_offset
		var sample := _wave_sampler.sample_surface(point_world, _wave_sampler.wave_time_seconds)
		var height := float(sample["height"])
		heights.append(height)
		world_points.append(Vector3(point_world.x, height, point_world.z))
		samples.append(sample)

	var front_height := (heights[0] + heights[1]) * 0.5
	var rear_height := (heights[2] + heights[3]) * 0.5
	var left_height := (heights[0] + heights[2]) * 0.5
	var right_height := (heights[1] + heights[3]) * 0.5
	var mean_height := (front_height + rear_height) * 0.5

	var target_heave := (mean_height - _motion_root.global_position.y) * buoyancy_strength
	var target_pitch := atan2(
		(front_height - rear_height) * buoyancy_strength,
		fore_sample_distance + aft_sample_distance
	)
	target_pitch = clampf(target_pitch, -deg_to_rad(pitch_limit_degrees), deg_to_rad(pitch_limit_degrees))
	var target_roll := atan2(
		(right_height - left_height) * buoyancy_strength,
		half_beam * 2.0
	)
	target_roll = clampf(target_roll, -deg_to_rad(roll_limit_degrees), deg_to_rad(roll_limit_degrees))

	var step_count := mini(maxi(1, ceili(delta * 60.0)), 8)
	var step_delta := delta / float(step_count)
	for _step in range(step_count):
		var heave_state := _spring_step(_heave, _heave_velocity, target_heave, step_delta)
		_heave = heave_state.x
		_heave_velocity = heave_state.y
		var pitch_state := _spring_step(_pitch, _pitch_velocity, target_pitch, step_delta)
		_pitch = pitch_state.x
		_pitch_velocity = pitch_state.y
		var roll_state := _spring_step(_roll, _roll_velocity, target_roll, step_delta)
		_roll = roll_state.x
		_roll_velocity = roll_state.y

	position.y = _heave
	rotation = Vector3(_pitch, 0.0, _roll)
	if debug_show_samples:
		_update_debug_markers(world_points, heights)


func _build_sample_offsets() -> void:
	_sample_offsets = [
		Vector3(-half_beam, 0.0, -fore_sample_distance),
		Vector3(half_beam, 0.0, -fore_sample_distance),
		Vector3(-half_beam, 0.0, aft_sample_distance),
		Vector3(half_beam, 0.0, aft_sample_distance),
	]


func _spring_step(current: float, velocity: float, target: float, delta: float) -> Vector2:
	var omega := TAU * response_speed_hz
	var acceleration := omega * omega * (target - current) - 2.0 * damping_ratio * omega * velocity
	velocity += acceleration * delta
	current += velocity * delta
	return Vector2(current, velocity)


func _set_debug_visible(visible: bool) -> void:
	if visible and _debug_markers.is_empty():
		_create_debug_markers()
	for marker in _debug_markers:
		marker.visible = visible


func _create_debug_markers() -> void:
	var colors := [Color(0.25, 0.9, 1.0), Color(1.0, 0.58, 0.25), Color(0.25, 0.9, 1.0), Color(1.0, 0.58, 0.25)]
	for index in range(SAMPLE_NAMES.size()):
		var marker := Node3D.new()
		marker.name = "WaveSample_%s" % SAMPLE_NAMES[index]
		_motion_root.add_child(marker)

		var sphere := MeshInstance3D.new()
		var sphere_mesh := SphereMesh.new()
		sphere_mesh.radius = 0.09
		sphere_mesh.height = 0.18
		sphere.mesh = sphere_mesh
		var sphere_material := StandardMaterial3D.new()
		sphere_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		sphere_material.albedo_color = colors[index]
		sphere.material_override = sphere_material
		marker.add_child(sphere)

		var label := Label3D.new()
		label.name = "HeightLabel"
		label.position = Vector3(0.0, 0.16, 0.0)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.font_size = 24
		label.pixel_size = 0.008
		label.modulate = colors[index]
		label.outline_size = 4
		label.outline_modulate = Color(0.02, 0.05, 0.08, 1.0)
		marker.add_child(label)

		_debug_markers.append(marker)
		_debug_labels.append(label)


func _update_debug_markers(world_points: Array[Vector3], heights: PackedFloat32Array) -> void:
	for index in range(_debug_markers.size()):
		_debug_markers[index].position = _motion_root.to_local(world_points[index])
		_debug_labels[index].text = "%s  %+.2f m" % [SAMPLE_NAMES[index], heights[index]]

