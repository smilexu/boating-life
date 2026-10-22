extends MeshInstance3D
## Subdivided visual Bermuda mainsail. The boom pivot controls trim; the shader
## only adds cloth billow and never participates in physics or collision.

const CLOTH_SHADER := preload("res://shaders/sail_cloth.gdshader")
const SMILE_TEXTURE := preload("res://assets/boats/nordic28/sail_logo_smile.png")
const ROWS := 26
const COLUMNS := 10
const MAIN_MAX_BILLOW_M := 0.16

var _head := Vector3(0.0, 4.45, 0.04)
var _tack := Vector3(0.0, 0.08, 0.0)
var _clew := Vector3(0.0, 0.08, 4.65)
var _cloth_material: ShaderMaterial


func _ready() -> void:
	extra_cull_margin = 0.25
	if mesh == null:
		_rebuild_mesh()
	_ensure_cloth_material()
	_set_normal()


func configure(head_from_pivot: Vector3, tack_from_pivot: Vector3, clew_from_pivot: Vector3) -> void:
	_head = head_from_pivot
	_tack = tack_from_pivot
	_clew = clew_from_pivot
	_rebuild_mesh()
	_ensure_cloth_material()
	_set_normal()


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
	_cloth_material.set_shader_parameter("slack_amount", 0.018 * (1.0 - speed_factor))
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
		"logo_texture": SMILE_TEXTURE.resource_path,
		"maximum_billow_m": MAIN_MAX_BILLOW_M,
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
	var plane_normal := _plane_normal(_head, _tack, _clew)
	for row in range(ROWS + 1):
		var height_fraction := float(row) / float(ROWS)
		var luff_point := _tack.lerp(_head, height_fraction)
		var leech_point := _clew.lerp(_head, height_fraction)
		for column in range(COLUMNS + 1):
			var chord_fraction := float(column) / float(COLUMNS)
			var index := row * (COLUMNS + 1) + column
			vertices[index] = luff_point.lerp(leech_point, chord_fraction)
			normals[index] = plane_normal
			var tangent := _plane_tangent(luff_point, leech_point, plane_normal)
			var bitangent := plane_normal.cross(tangent)
			var luff_direction := (_head - _tack).normalized()
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
	_cloth_material.set_shader_parameter("sail_logo", SMILE_TEXTURE)
	_cloth_material.set_shader_parameter("logo_center", Vector2(0.5, 0.58))
	_cloth_material.set_shader_parameter("logo_size", Vector2(0.98, 0.25))
	_cloth_material.set_shader_parameter("wireframe_grid", Vector2(COLUMNS, ROWS))
	_cloth_material.set_shader_parameter("maximum_billow_m", MAIN_MAX_BILLOW_M)
	_cloth_material.set_shader_parameter("sail_normal_local", Vector3.RIGHT)
	material_override = _cloth_material


func _set_normal() -> void:
	if _cloth_material == null:
		return
	_cloth_material.set_shader_parameter("sail_normal_local", _plane_normal(_head, _tack, _clew))


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
		tangent = _clew - _tack
		tangent -= plane_normal * tangent.dot(plane_normal)
	return tangent.normalized() if tangent.length_squared() >= 0.000001 else Vector3.FORWARD


func _finite_vector(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)
