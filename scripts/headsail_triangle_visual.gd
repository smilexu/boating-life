extends MeshInstance3D
## Tiny double-sided Jib mesh. Head/Tack remain fixed; the Clew moves along the
## same sheet angle used by the SailboatLab aerodynamic chord. No cloth physics.

const AERO_MATH := preload("res://scripts/sailboat_aero_math.gd")

var _head_local := Vector3(0.0, 4.95, -0.75)
var _tack_local := Vector3(0.0, 0.65, -3.55)
var _neutral_clew_local := Vector3(0.0, 0.65, -1.15)
var _last_angle_rad := INF
var _dynamic_mesh: ArrayMesh


func configure(head: Vector3, tack: Vector3, neutral_clew: Vector3) -> void:
	_head_local = head
	_tack_local = tack
	_neutral_clew_local = neutral_clew
	_last_angle_rad = INF
	if is_inside_tree():
		_build_mesh()


func set_sheet_angle(angle_rad: float) -> void:
	if not is_finite(angle_rad) or is_equal_approx(angle_rad, _last_angle_rad):
		return
	_last_angle_rad = angle_rad
	if _dynamic_mesh == null:
		_build_mesh()
		return
	var points := _vertices_for_angle(angle_rad)
	_dynamic_mesh.surface_update_vertex_region(0, 0, points.to_byte_array())


func get_vertices_for_angle(angle_rad: float) -> PackedVector3Array:
	return _vertices_for_angle(angle_rad)


func _ready() -> void:
	_build_mesh()
	set_sheet_angle(0.0)


func _build_mesh() -> void:
	var points := _vertices_for_angle(0.0)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = points
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	_dynamic_mesh = ArrayMesh.new()
	_dynamic_mesh.add_surface_from_arrays(
		Mesh.PRIMITIVE_TRIANGLES,
		arrays,
		[],
		{},
		Mesh.ARRAY_FLAG_USE_DYNAMIC_UPDATE
	)
	mesh = _dynamic_mesh


func _vertices_for_angle(angle_rad: float) -> PackedVector3Array:
	var clew := AERO_MATH.headsail_clew_from_sheet(_tack_local, _neutral_clew_local, angle_rad)
	# StandardMaterial culling is disabled; one triangle is sufficient and keeps
	# the runtime vertex update contiguous and tiny (three Vector3 values).
	return PackedVector3Array([_head_local, _tack_local, clew])
