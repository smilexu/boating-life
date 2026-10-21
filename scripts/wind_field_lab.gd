extends Node3D

const WindFieldScript := preload("res://scripts/wind_field.gd")
const WindPanelScript := preload("res://scripts/wind_field_debug_panel.gd")

const FIELD_HALF_SIZE_M := 300.0
const TARGET_REFRESH_SECONDS := 0.15
const CALM_ARROW_COLOR := Color(0.28, 0.78, 0.86)
const STRONG_ARROW_COLOR := Color(1.0, 0.66, 0.28)


static func arrow_basis_for_wind(wind: Vector3) -> Basis:
	var horizontal := Vector3(wind.x, 0.0, wind.z)
	if horizontal.length_squared() <= 0.000001:
		return Basis.IDENTITY
	return Basis.looking_at(horizontal.normalized(), Vector3.UP)


static func grid_sample_position(origin: Vector3, row: int, column: int, grid_count: int, half_size_m: float = 300.0) -> Vector3:
	var safe_count := maxi(grid_count, 1)
	var spacing := half_size_m * 2.0 / float(maxi(safe_count - 1, 1))
	var half_index := float(safe_count - 1) * 0.5
	return origin + Vector3((float(column) - half_index) * spacing, 0.0, (float(row) - half_index) * spacing)


var _wind_field: WindField
var _visual_origin: Node3D
var _camera: Camera3D
var _sample_marker: MeshInstance3D
var _sock_pivot: Node3D
var _sock_bag: Node3D
var _wind_multimesh: MultiMesh
var _grid_count := 7
var _arrow_length_scale := 5.0
var _target_refresh_elapsed := 0.0
var _target_winds: Array[Vector3] = []
var _displayed_winds: Array[Vector3] = []
var _sample_world_position := Vector3.ZERO
var _smoothed_sock_wind := Vector3.ZERO


func _ready() -> void:
	_wind_field = WindFieldScript.new() as WindField
	_wind_field.name = "WindField"
	_wind_field.mean_wind_speed_mps = 8.0
	_wind_field.mean_wind_from_degrees = 245.0
	_wind_field.gust_strength_mps = 3.0
	_wind_field.gust_time_scale_seconds = 18.0
	_wind_field.gust_space_scale_meters = 350.0
	_wind_field.random_seed = 74291
	add_child(_wind_field)
	_build_lab_scene()
	_build_wind_arrow_array()
	_build_wind_sock()
	var panel := WindPanelScript.new() as CanvasLayer
	panel.name = "WindFieldLabPanel"
	panel.wind_field_path = NodePath("../WindField")
	panel.sample_source_path = NodePath("")
	panel.start_visible = true
	panel.start_test_clock = true
	panel.allow_f12_toggle = false
	panel.sample_east_m = 0.0
	panel.sample_north_m = 0.0
	panel.sample_location_changed.connect(_on_sample_location_changed)
	panel.visualization_settings_changed.connect(_on_visualization_settings_changed)
	add_child(panel)
	_on_sample_location_changed(Vector3.ZERO)
	_on_visualization_settings_changed(_grid_count, _arrow_length_scale)


func _process(delta: float) -> void:
	if _wind_field == null or _wind_multimesh == null:
		return
	_target_refresh_elapsed += delta
	if _target_refresh_elapsed >= TARGET_REFRESH_SECONDS:
		_target_refresh_elapsed = fposmod(_target_refresh_elapsed, TARGET_REFRESH_SECONDS)
		_sample_target_winds()
	_update_arrow_instances(delta)
	_update_wind_sock(delta)


func _build_lab_scene() -> void:
	var environment_node := WorldEnvironment.new()
	environment_node.name = "WorldEnvironment"
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.035, 0.075, 0.095)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.46, 0.57, 0.62)
	environment.ambient_light_energy = 0.8
	environment_node.environment = environment
	add_child(environment_node)

	_visual_origin = Node3D.new()
	_visual_origin.name = "SampleCenteredWindField"
	add_child(_visual_origin)
	_camera = Camera3D.new()
	_camera.name = "LabCamera"
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = 720.0
	_camera.position = Vector3(0.0, 760.0, 0.0)
	_visual_origin.add_child(_camera)
	_camera.look_at(Vector3.ZERO, Vector3(0.0, 0.0, -1.0))
	_camera.current = true

	var ground := MeshInstance3D.new()
	ground.name = "TestPlane"
	var plane := PlaneMesh.new()
	plane.size = Vector2(700.0, 700.0)
	ground.mesh = plane
	ground.position.y = -0.2
	var ground_material := StandardMaterial3D.new()
	ground_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ground_material.albedo_color = Color(0.055, 0.115, 0.135)
	ground.material_override = ground_material
	_visual_origin.add_child(ground)

	var grid := MeshInstance3D.new()
	grid.name = "EastNorthGrid"
	grid.mesh = _make_grid_mesh()
	var grid_material := StandardMaterial3D.new()
	grid_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	grid_material.albedo_color = Color(0.22, 0.36, 0.39, 0.72)
	grid_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	grid.material_override = grid_material
	grid.position.y = 0.05
	_visual_origin.add_child(grid)

	_add_compass_label("N", Vector3(0.0, 1.0, -320.0))
	_add_compass_label("E", Vector3(320.0, 1.0, 0.0))
	_add_compass_label("S", Vector3(0.0, 1.0, 320.0))
	_add_compass_label("W", Vector3(-320.0, 1.0, 0.0))
	_add_compass_label("NORTH / −Z", Vector3(-270.0, 1.0, -320.0), 32)
	_add_compass_label("EAST / +X", Vector3(270.0, 1.0, -320.0), 32)


func _add_compass_label(text: String, label_position: Vector3, font_size: int = 48) -> void:
	var label := Label3D.new()
	label.text = text
	label.position = label_position
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = font_size
	label.pixel_size = 0.08
	label.modulate = Color(0.78, 0.89, 0.88)
	_visual_origin.add_child(label)


func _make_grid_mesh() -> Mesh:
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for meter in range(-300, 301, 25):
		var major := meter % 100 == 0
		var y := 0.03 if major else 0.0
		mesh.surface_add_vertex(Vector3(float(meter), y, -300.0))
		mesh.surface_add_vertex(Vector3(float(meter), y, 300.0))
		mesh.surface_add_vertex(Vector3(-300.0, y, float(meter)))
		mesh.surface_add_vertex(Vector3(300.0, y, float(meter)))
	mesh.surface_end()
	return mesh


func _build_wind_arrow_array() -> void:
	var marker := MeshInstance3D.new()
	marker.name = "SamplePosition"
	var marker_mesh := SphereMesh.new()
	marker_mesh.radius = 2.0
	marker_mesh.height = 4.0
	marker.mesh = marker_mesh
	var marker_material := StandardMaterial3D.new()
	marker_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	marker_material.albedo_color = Color(0.98, 0.78, 0.34)
	marker.material_override = marker_material
	marker.position.y = 0.75
	_visual_origin.add_child(marker)
	_sample_marker = marker

	var arrow_instance := MultiMeshInstance3D.new()
	arrow_instance.name = "WindVectorArray"
	arrow_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var multi_mesh := MultiMesh.new()
	multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	multi_mesh.use_colors = true
	multi_mesh.mesh = _make_arrow_mesh()
	multi_mesh.custom_aabb = AABB(Vector3(-330.0, -1.0, -330.0), Vector3(660.0, 8.0, 660.0))
	arrow_instance.multimesh = multi_mesh
	var arrow_material := StandardMaterial3D.new()
	arrow_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	arrow_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	arrow_material.vertex_color_use_as_albedo = true
	arrow_instance.material_override = arrow_material
	_visual_origin.add_child(arrow_instance)
	_wind_multimesh = multi_mesh


func _make_arrow_mesh() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var p0 := Vector3(0.0, 0.0, -1.0)
	var p1 := Vector3(-0.25, 0.0, -0.48)
	var p2 := Vector3(-0.075, 0.0, -0.48)
	var p3 := Vector3(-0.075, 0.0, 0.24)
	var p4 := Vector3(0.075, 0.0, 0.24)
	var p5 := Vector3(0.075, 0.0, -0.48)
	var p6 := Vector3(0.25, 0.0, -0.48)
	for triangle in [[p0, p1, p2], [p0, p2, p3], [p0, p3, p4], [p0, p4, p5], [p0, p5, p6]]:
		for vertex in triangle:
			vertices.append(vertex)
			normals.append(Vector3.UP)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _build_wind_sock() -> void:
	var pole := MeshInstance3D.new()
	pole.name = "WindSockPole"
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.09
	pole_mesh.bottom_radius = 0.15
	pole_mesh.height = 6.0
	pole.mesh = pole_mesh
	pole.position = Vector3(0.0, 3.0, 0.0)
	var pole_material := StandardMaterial3D.new()
	pole_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pole_material.albedo_color = Color(0.74, 0.78, 0.73)
	pole.material_override = pole_material
	_visual_origin.add_child(pole)

	_sock_pivot = Node3D.new()
	_sock_pivot.name = "WindSockPivot"
	_sock_pivot.position = Vector3(0.0, 5.9, 0.0)
	_visual_origin.add_child(_sock_pivot)
	_sock_bag = Node3D.new()
	_sock_bag.name = "ProceduralWindSock"
	_sock_pivot.add_child(_sock_bag)
	var segment_count := 5
	var segment_length := 1.25
	for index in range(segment_count):
		var segment := MeshInstance3D.new()
		segment.name = "SockSegment%d" % index
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = lerpf(0.23, 0.07, float(index + 1) / segment_count)
		cylinder.bottom_radius = lerpf(0.23, 0.07, float(index) / segment_count)
		cylinder.height = segment_length
		cylinder.radial_segments = 8
		segment.mesh = cylinder
		segment.position.z = -(float(index) + 0.5) * segment_length
		segment.rotation.x = -PI * 0.5
		var sock_material := StandardMaterial3D.new()
		sock_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		sock_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		sock_material.albedo_color = Color(0.92, 0.84, 0.64) if index % 2 == 0 else Color(0.94, 0.43, 0.20)
		segment.material_override = sock_material
		_sock_bag.add_child(segment)


func _sample_target_winds() -> void:
	for row in range(_grid_count):
		for column in range(_grid_count):
			var index := row * _grid_count + column
			var world_position := grid_sample_position(_visual_origin.global_position, row, column, _grid_count, FIELD_HALF_SIZE_M)
			_target_winds[index] = _wind_field.get_wind_at(world_position)


func _update_arrow_instances(delta: float) -> void:
	var spacing := FIELD_HALF_SIZE_M * 2.0 / float(maxi(_grid_count - 1, 1))
	var blend := 1.0 - exp(-maxf(delta, 0.0) * 5.0)
	for row in range(_grid_count):
		for column in range(_grid_count):
			var index := row * _grid_count + column
			_displayed_winds[index] = _displayed_winds[index].lerp(_target_winds[index], blend)
			var wind := _displayed_winds[index]
			var speed := Vector2(wind.x, wind.z).length()
			var local_position := grid_sample_position(Vector3.ZERO, row, column, _grid_count, FIELD_HALF_SIZE_M) + Vector3.UP * 0.75
			var length_m := clampf(speed * _arrow_length_scale, 0.01, spacing * 0.8)
			var horizontal_direction := Vector3(wind.x, 0.0, wind.z)
			var transform := Transform3D.IDENTITY
			if horizontal_direction.length_squared() > 0.000001 and speed > 0.01:
				var basis := arrow_basis_for_wind(wind)
				basis = basis.scaled(Vector3(length_m * 0.24, 1.0, length_m))
				transform = Transform3D(basis, local_position)
			else:
				transform = Transform3D(Basis.IDENTITY.scaled(Vector3(0.001, 0.001, 0.001)), local_position)
			_wind_multimesh.set_instance_transform(index, transform)
			var color_weight := clampf(speed / 15.0, 0.0, 1.0)
			_wind_multimesh.set_instance_color(index, CALM_ARROW_COLOR.lerp(STRONG_ARROW_COLOR, color_weight))


func _update_wind_sock(delta: float) -> void:
	var wind := _wind_field.get_wind_at(_sample_world_position)
	_smoothed_sock_wind = _smoothed_sock_wind.lerp(wind, 1.0 - exp(-maxf(delta, 0.0) * 2.8))
	var horizontal := Vector3(_smoothed_sock_wind.x, 0.0, _smoothed_sock_wind.z)
	var speed := horizontal.length()
	var extension := smoothstep(0.4, 8.0, speed)
	var desired_direction := Vector3.DOWN.lerp(horizontal.normalized(), extension).normalized() if speed > 0.001 else Vector3.DOWN
	var look_up := Vector3.FORWARD if absf(desired_direction.dot(Vector3.UP)) > 0.95 else Vector3.UP
	_sock_pivot.basis = Basis.looking_at(desired_direction, look_up)
	_sock_bag.scale.z = lerpf(0.16, 1.0, extension)


func _on_sample_location_changed(world_position: Vector3) -> void:
	_sample_world_position = world_position
	if _visual_origin == null:
		return
	_visual_origin.global_position = Vector3(world_position.x, 0.0, world_position.z)
	if _camera != null:
		_camera.position = Vector3(0.0, 760.0, 0.0)
		_camera.look_at(Vector3.ZERO, Vector3(0.0, 0.0, -1.0))
	if _sample_marker != null:
		_sample_marker.position = Vector3(0.0, 0.75, 0.0)
	if not _target_winds.is_empty():
		_sample_target_winds()


func _on_visualization_settings_changed(grid_count: int, meters_per_mps: float) -> void:
	_grid_count = clampi(grid_count, 3, 17)
	if _grid_count % 2 == 0:
		_grid_count += 1
	_arrow_length_scale = clampf(meters_per_mps, 1.0, 20.0)
	if _wind_multimesh == null:
		return
	var instance_count := _grid_count * _grid_count
	_wind_multimesh.instance_count = instance_count
	_target_winds.clear()
	_displayed_winds.clear()
	_target_winds.resize(instance_count)
	_displayed_winds.resize(instance_count)
	for index in range(instance_count):
		_target_winds[index] = Vector3.ZERO
		_displayed_winds[index] = Vector3.ZERO
	_sample_target_winds()
	_update_arrow_instances(1.0)
