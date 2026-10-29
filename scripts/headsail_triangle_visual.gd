extends MeshInstance3D
## Subdivided, shader-billowed Jib. Head and Tack remain fixed while a
## barycentric endpoint offset follows the existing actual sheet angle.

const AERO_MATH := preload("res://scripts/sailboat_aero_math.gd")
const CLOTH_SHADER := preload("res://shaders/sail_cloth.gdshader")
const ROWS := 20
const COLUMNS := 8
const JIB_MAX_BILLOW_M := 0.13

var _head_local := Vector3(0.0, 4.95, -0.75)
var _tack_local := Vector3(0.0, 0.65, -3.55)
var _neutral_clew_local := Vector3(0.0, 0.65, -1.15)
var _last_angle_rad := INF
var _last_geometry_angle_rad := INF
var _deployment := 1.0
var _current_clew_local := Vector3.ZERO
var _aero_enabled := true
var _partial_mesh_active := false
var _cloth_material: ShaderMaterial
var _furled_fabric: MeshInstance3D


func _ready() -> void:
	extra_cull_margin = 0.22
	if mesh == null:
		_rebuild_mesh()
	_current_clew_local = _neutral_clew_local
	_ensure_cloth_material()
	_create_furled_fabric()
	set_sheet_angle(0.0)


func configure(head: Vector3, tack: Vector3, neutral_clew: Vector3) -> void:
	_head_local = head
	_tack_local = tack
	_neutral_clew_local = neutral_clew
	_last_angle_rad = INF
	_last_geometry_angle_rad = INF
	_rebuild_mesh()
	_ensure_cloth_material()
	_current_clew_local = _neutral_clew_local
	_update_furled_fabric()
	set_sheet_angle(0.0)


func set_sheet_angle(angle_rad: float) -> void:
	if not is_finite(angle_rad) or is_equal_approx(angle_rad, _last_angle_rad):
		return
	_last_angle_rad = angle_rad
	if _cloth_material == null:
		return
	if _deployment >= 0.999:
		var clew := get_clew_for_angle(angle_rad)
		_current_clew_local = clew
		_cloth_material.set_shader_parameter("clew_delta_local", clew - _neutral_clew_local)
		_cloth_material.set_shader_parameter("sail_normal_local", _plane_normal(_head_local, _tack_local, clew))


func set_deployment(value: float, angle_rad: float) -> void:
	if not is_finite(value) or not is_finite(angle_rad):
		return
	var safe_deployment := clampf(value, 0.0, 1.0)
	var angle_changed := not is_finite(_last_geometry_angle_rad) or absf(angle_rad - _last_geometry_angle_rad) >= 0.004
	var deployment_changed := absf(safe_deployment - _deployment) >= 0.003
	var no_open_cloth := safe_deployment <= 0.001 and _deployment <= 0.001
	if not deployment_changed and not angle_changed and (mesh != null or no_open_cloth):
		if safe_deployment >= 0.999:
			_current_clew_local = get_clew_for_angle(angle_rad)
		return
	_deployment = safe_deployment
	_last_angle_rad = angle_rad
	_last_geometry_angle_rad = angle_rad
	var full_clew := get_clew_for_angle(angle_rad)
	if _deployment >= 0.999:
		if _partial_mesh_active:
			_rebuild_mesh_for_clew(_neutral_clew_local)
			_partial_mesh_active = false
		_current_clew_local = full_clew
		if _cloth_material != null:
			_cloth_material.set_shader_parameter("clew_delta_local", full_clew - _neutral_clew_local)
			_cloth_material.set_shader_parameter("sail_normal_local", _plane_normal(_head_local, _tack_local, full_clew))
	else:
		var luff_projection := _closest_point_on_segment(full_clew, _head_local, _tack_local)
		var partial_clew := luff_projection.lerp(full_clew, _deployment)
		if _deployment > 0.001 and (partial_clew.distance_squared_to(_current_clew_local) >= 0.000004 or not _partial_mesh_active):
			_rebuild_mesh_for_clew(partial_clew)
			_partial_mesh_active = true
		_current_clew_local = partial_clew
		if _deployment <= 0.001:
			_current_clew_local = luff_projection
			mesh = null
		if _cloth_material != null:
			_cloth_material.set_shader_parameter("clew_delta_local", Vector3.ZERO)
			_cloth_material.set_shader_parameter("sail_normal_local", _plane_normal(_head_local, _tack_local, partial_clew))
	_refresh_furl_visibility()
	_update_furled_fabric()


func get_clew_for_angle(angle_rad: float) -> Vector3:
	return AERO_MATH.headsail_clew_from_sheet(_tack_local, _neutral_clew_local, angle_rad)


func get_vertices_for_angle(angle_rad: float) -> PackedVector3Array:
	var full_clew := get_clew_for_angle(angle_rad)
	var clew := full_clew if _deployment >= 0.999 else _closest_point_on_segment(full_clew, _head_local, _tack_local).lerp(full_clew, _deployment)
	var vertices := PackedVector3Array()
	vertices.resize((ROWS + 1) * (COLUMNS + 1))
	for row in range(ROWS + 1):
		var height_fraction := float(row) / float(ROWS)
		var luff_point := _tack_local.lerp(_head_local, height_fraction)
		var leech_point := clew.lerp(_head_local, height_fraction)
		for column in range(COLUMNS + 1):
			var index := row * (COLUMNS + 1) + column
			vertices[index] = luff_point.lerp(leech_point, float(column) / float(COLUMNS))
	return vertices


func set_cloth_state(
	airflow_local_mps: Vector3,
	airflow_speed_mps: float,
	sheet_efficiency: float,
	animation_phase: float
) -> void:
	if _cloth_material == null:
		return
	var safe_speed := airflow_speed_mps if is_finite(airflow_speed_mps) else 0.0
	var speed_factor := smoothstep(0.5, 5.0, maxf(safe_speed, 0.0))
	var efficiency := clampf(sheet_efficiency, 0.0, 1.0) if is_finite(sheet_efficiency) else 0.0
	_cloth_material.set_shader_parameter("airflow_local", airflow_local_mps if _finite_vector(airflow_local_mps) else Vector3.ZERO)
	_cloth_material.set_shader_parameter("sail_fill", speed_factor * efficiency)
	_cloth_material.set_shader_parameter("flutter_amount", speed_factor * (1.0 - efficiency))
	_cloth_material.set_shader_parameter("slack_amount", 0.016 * (1.0 - speed_factor))
	_cloth_material.set_shader_parameter("animation_phase", animation_phase)


func set_visual_options(billow_enabled: bool, wireframe_enabled: bool, logo_enabled: bool) -> void:
	if _cloth_material == null:
		return
	_cloth_material.set_shader_parameter("billow_enabled", billow_enabled)
	_cloth_material.set_shader_parameter("wireframe_enabled", wireframe_enabled)
	_cloth_material.set_shader_parameter("logo_enabled", logo_enabled)


func get_visual_snapshot() -> Dictionary:
	return {
		"rows": ROWS,
		"columns": COLUMNS,
		"vertex_count": (ROWS + 1) * (COLUMNS + 1),
		"triangle_count": ROWS * COLUMNS * 2,
		"cloth_material": _cloth_material != null,
		"maximum_billow_m": JIB_MAX_BILLOW_M,
		"neutral_area_m2": AERO_MATH.triangular_sail_area_m2(_head_local, _tack_local, _neutral_clew_local),
		"deployment": _deployment,
		"geometric_area_m2": AERO_MATH.triangular_sail_area_m2(_head_local, _tack_local, _current_clew_local),
		"last_clew_local_m": _current_clew_local,
		"furled_fabric_visible": _furled_fabric != null and _furled_fabric.visible,
	}


func _rebuild_mesh() -> void:
	_rebuild_mesh_for_clew(_neutral_clew_local)


func _rebuild_mesh_for_clew(clew_position: Vector3) -> void:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var tangents := PackedFloat32Array()
	var uvs := PackedVector2Array()
	vertices.resize((ROWS + 1) * (COLUMNS + 1))
	normals.resize(vertices.size())
	tangents.resize(vertices.size() * 4)
	uvs.resize(vertices.size())
	var normal := _plane_normal(_head_local, _tack_local, clew_position)
	for row in range(ROWS + 1):
		var height_fraction := float(row) / float(ROWS)
		var luff_point := _tack_local.lerp(_head_local, height_fraction)
		var leech_point := clew_position.lerp(_head_local, height_fraction)
		for column in range(COLUMNS + 1):
			var chord_fraction := float(column) / float(COLUMNS)
			var index := row * (COLUMNS + 1) + column
			vertices[index] = luff_point.lerp(leech_point, chord_fraction)
			normals[index] = normal
			var tangent := _plane_tangent(luff_point, leech_point, normal)
			var bitangent := normal.cross(tangent)
			var luff_direction := (_head_local - _tack_local).normalized()
			var handedness := 1.0 if bitangent.dot(luff_direction) >= 0.0 else -1.0
			tangents[index * 4] = tangent.x
			tangents[index * 4 + 1] = tangent.y
			tangents[index * 4 + 2] = tangent.z
			tangents[index * 4 + 3] = handedness
			uvs[index] = Vector2(chord_fraction, height_fraction)
	var indices := PackedInt32Array()
	indices.resize(ROWS * COLUMNS * 6)
	var index_cursor := 0
	for row in range(ROWS):
		for column in range(COLUMNS):
			var lower_left := row * (COLUMNS + 1) + column
			var lower_right := lower_left + 1
			var upper_left := lower_left + COLUMNS + 1
			var upper_right := upper_left + 1
			indices[index_cursor] = lower_left
			indices[index_cursor + 1] = upper_left
			indices[index_cursor + 2] = lower_right
			indices[index_cursor + 3] = lower_right
			indices[index_cursor + 4] = upper_left
			indices[index_cursor + 5] = upper_right
			index_cursor += 6
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TANGENT] = tangents
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var cloth_mesh := ArrayMesh.new()
	cloth_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = cloth_mesh


func _ensure_cloth_material() -> void:
	if _cloth_material != null:
		material_override = _cloth_material
		return
	_cloth_material = ShaderMaterial.new()
	_cloth_material.shader = CLOTH_SHADER
	_cloth_material.set_shader_parameter("cloth_color", Color("#f3f0e7"))
	_cloth_material.set_shader_parameter("seam_color", Color("#d5d2c9"))
	_cloth_material.set_shader_parameter("reinforcement_color", Color("#e9e5da"))
	_cloth_material.set_shader_parameter("logo_enabled", false)
	_cloth_material.set_shader_parameter("wireframe_grid", Vector2(COLUMNS, ROWS))
	_cloth_material.set_shader_parameter("maximum_billow_m", JIB_MAX_BILLOW_M)
	_cloth_material.set_shader_parameter("sail_normal_local", _plane_normal(_head_local, _tack_local, _neutral_clew_local))
	material_override = _cloth_material


func set_aero_enabled(value: bool) -> void:
	if _aero_enabled == value:
		return
	_aero_enabled = value
	_refresh_furl_visibility()


func _refresh_furl_visibility() -> void:
	visible = _aero_enabled
	if _furled_fabric != null:
		_furled_fabric.visible = _aero_enabled and _deployment < 0.999


func _closest_point_on_segment(point: Vector3, start: Vector3, end: Vector3) -> Vector3:
	var segment := end - start
	var length_squared := segment.length_squared()
	if length_squared <= 0.000001:
		return start
	var amount := clampf((point - start).dot(segment) / length_squared, 0.0, 1.0)
	return start + segment * amount


func _create_furled_fabric() -> void:
	if _furled_fabric != null:
		return
	_furled_fabric = MeshInstance3D.new()
	_furled_fabric.name = "ForestayFurledCloth"
	var roll := CylinderMesh.new()
	roll.height = maxf(_head_local.distance_to(_tack_local), 0.1)
	roll.top_radius = 0.04
	roll.bottom_radius = 0.04
	roll.radial_segments = 8
	_furled_fabric.mesh = roll
	var cloth_material := StandardMaterial3D.new()
	cloth_material.albedo_color = Color("#e7e1d3")
	cloth_material.roughness = 0.9
	_furled_fabric.material_override = cloth_material
	add_child(_furled_fabric)
	_update_furled_fabric()


func _update_furled_fabric() -> void:
	if _furled_fabric == null:
		return
	var luff := _head_local - _tack_local
	if luff.length_squared() < 0.000001:
		_furled_fabric.visible = false
		return
	var cylinder := _furled_fabric.mesh as CylinderMesh
	if cylinder != null:
		cylinder.height = luff.length()
		var radius := 0.022 + (1.0 - _deployment) * 0.025
		cylinder.top_radius = radius
		cylinder.bottom_radius = radius
	_furled_fabric.position = (_head_local + _tack_local) * 0.5
	_furled_fabric.basis = Basis(Quaternion(Vector3.UP, luff.normalized()))
	_furled_fabric.visible = _aero_enabled and _deployment < 0.999


func _plane_normal(head: Vector3, tack: Vector3, clew: Vector3) -> Vector3:
	var normal := (head - tack).cross(clew - tack)
	if normal.length_squared() < 0.000001:
		return Vector3.RIGHT
	normal = normal.normalized()
	return -normal if normal.x < 0.0 else normal


func _plane_tangent(luff_point: Vector3, leech_point: Vector3, plane_normal: Vector3) -> Vector3:
	var tangent := leech_point - luff_point
	tangent -= plane_normal * tangent.dot(plane_normal)
	if tangent.length_squared() < 0.000001:
		tangent = _neutral_clew_local - _tack_local
		tangent -= plane_normal * tangent.dot(plane_normal)
	return tangent.normalized() if tangent.length_squared() >= 0.000001 else Vector3.FORWARD


func _finite_vector(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)
