extends MeshInstance3D
## Builds the SailboatLab's static, double-sided Bermuda mainsail once at startup.
## The parent SailPivot alone controls trim rotation; this mesh has no physics role.

const HEAD := Vector3(0.0, 4.45, 0.04)
const TACK := Vector3(0.0, 0.08, 0.0)
const CLEW := Vector3(0.0, 0.08, 4.65)


func _ready() -> void:
	if mesh != null:
		return
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	# Duplicate the triangle with reversed winding and normals so both sides shade
	# correctly without transparency or a second MeshInstance3D.
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		HEAD, TACK, CLEW,
		HEAD, CLEW, TACK,
	])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([
		Vector3.RIGHT, Vector3.RIGHT, Vector3.RIGHT,
		Vector3.LEFT, Vector3.LEFT, Vector3.LEFT,
	])
	# The first winding faces +X, matching the front-side normals above; the
	# second winding faces -X for the reverse side.
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 2, 1, 3, 4, 5])
	var triangle := ArrayMesh.new()
	triangle.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = triangle
