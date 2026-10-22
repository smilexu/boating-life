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
var _cloth_material: ShaderMaterial


func _ready() -> void:
	extra_cull_margin = 0.22
	if mesh == null:
		_rebuild_mesh()
	_ensure_cloth_material()
	set_sheet_angle(0.0)


func configure(head: Vector3, tack: Vector3, neutral_clew: Vector3) -> void:
	_head_local = head
	_tack_local = tack
	_neutral_clew_local = neutral_clew
	_last_angle_rad = INF
	_rebuild_mesh()
	_ensure_cloth_material()
	set_sheet_angle(0.0)


func set_sheet_angle(angle_rad: float) -> void:
	if not is_finite(angle_rad) or is_equal_approx(angle_rad, _last_angle_rad):
		return
	_last_angle_rad = angle_rad
	if _cloth_material == null:
		return
	var clew := get_clew_for_angle(angle_rad)
	_cloth_material.set_shader_parameter("clew_delta_local", clew - _neutral_clew_local)
	_cloth_material.set_shader_parameter("sail_normal_local", _plane_normal(_head_local, _tack_local, clew))


func get_clew_for_angle(angle_rad: float) -> Vector3:
	return AERO_MATH.headsail_clew_from_sheet(_tack_local, _neutral_clew_local, angle_rad)


func get_vertices_for_angle(angle_rad: float) -> PackedVector3Array:
	var clew := get_clew_for_angle(angle_rad)
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
		"last_clew_local_m": get_clew_for_angle(_last_angle_rad if is_finite(_last_angle_rad) else 0.0),
	}


func _rebuild_mesh() -> void:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var tangents := PackedFloat32Array()
	var uvs := PackedVector2Array()
	vertices.resize((ROWS + 1) * (COLUMNS + 1))
	normals.resize(vertices.size())
	tangents.resize(vertices.size() * 4)
	uvs.resize(vertices.size())
	var normal := _plane_normal(_head_local, _tack_local, _neutral_clew_local)
	for row in range(ROWS + 1):
		var height_fraction := float(row) / float(ROWS)
		var luff_point := _tack_local.lerp(_head_local, height_fraction)
		var leech_point := _neutral_clew_local.lerp(_head_local, height_fraction)
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
