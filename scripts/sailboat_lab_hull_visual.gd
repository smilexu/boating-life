extends Node3D
## Creates low-poly visual hull and deck meshes once. This node does not alter collision or physics.

const HULL_SECTIONS := [
	{"z": -3.9, "half_beam": 0.035},
	{"z": -3.0, "half_beam": 0.46},
	{"z": -1.65, "half_beam": 0.98},
	{"z": 0.2, "half_beam": 1.22},
	{"z": 2.75, "half_beam": 1.25},
	{"z": 3.9, "half_beam": 1.18},
]
const HULL_TOP_Y := 0.46
const HULL_CHINE_Y := -0.16
const HULL_KEEL_Y := -0.50


func _ready() -> void:
	var hull := get_node_or_null("Hull") as MeshInstance3D
	var deck := get_node_or_null("Deck") as MeshInstance3D
	if hull != null:
		hull.mesh = _build_hull_mesh()
	if deck != null:
		deck.mesh = _build_deck_mesh()


func _build_hull_mesh() -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for index in range(HULL_SECTIONS.size() - 1):
		var first: Dictionary = HULL_SECTIONS[index]
		var second: Dictionary = HULL_SECTIONS[index + 1]
		var z0 := float(first["z"])
		var z1 := float(second["z"])
		var beam0 := float(first["half_beam"])
		var beam1 := float(second["half_beam"])
		var right_top0 := Vector3(beam0, HULL_TOP_Y, z0)
		var right_top1 := Vector3(beam1, HULL_TOP_Y, z1)
		var right_chine0 := Vector3(beam0 * 0.25, HULL_CHINE_Y, z0)
		var right_chine1 := Vector3(beam1 * 0.25, HULL_CHINE_Y, z1)
		var keel0 := Vector3(0.0, HULL_KEEL_Y, z0)
		var keel1 := Vector3(0.0, HULL_KEEL_Y, z1)
		_add_quad(surface, right_top0, right_top1, right_chine1, right_chine0)
		_add_quad(surface, right_chine0, right_chine1, keel1, keel0)

		var left_top0 := Vector3(-beam0, HULL_TOP_Y, z0)
		var left_top1 := Vector3(-beam1, HULL_TOP_Y, z1)
		var left_chine0 := Vector3(-beam0 * 0.25, HULL_CHINE_Y, z0)
		var left_chine1 := Vector3(-beam1 * 0.25, HULL_CHINE_Y, z1)
		_add_quad(surface, left_top0, left_chine0, left_chine1, left_top1)
		_add_quad(surface, left_chine0, keel0, keel1, left_chine1)

	var bow: Dictionary = HULL_SECTIONS[0]
	var bow_beam := float(bow["half_beam"])
	_add_triangle(
		surface,
		Vector3(-bow_beam, HULL_TOP_Y, float(bow["z"])),
		Vector3(bow_beam, HULL_TOP_Y, float(bow["z"])),
		Vector3(0.0, HULL_KEEL_Y, float(bow["z"]))
	)
	var stern: Dictionary = HULL_SECTIONS[HULL_SECTIONS.size() - 1]
	var stern_beam := float(stern["half_beam"])
	_add_triangle(
		surface,
		Vector3(-stern_beam, HULL_TOP_Y, float(stern["z"])),
		Vector3(0.0, HULL_KEEL_Y, float(stern["z"])),
		Vector3(stern_beam, HULL_TOP_Y, float(stern["z"]))
	)
	surface.generate_normals()
	return surface.commit()


func _build_deck_mesh() -> ArrayMesh:
	var outline := PackedVector2Array([
		Vector2(0.0, -3.86),
		Vector2(0.42, -3.02),
		Vector2(0.92, -1.66),
		Vector2(1.16, 0.2),
		Vector2(1.19, 2.74),
		Vector2(1.10, 3.74),
		Vector2(-1.10, 3.74),
		Vector2(-1.19, 2.74),
		Vector2(-1.16, 0.2),
		Vector2(-0.92, -1.66),
		Vector2(-0.42, -3.02),
	])
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var center := Vector3(0.0, 0.0, 0.0)
	for index in range(outline.size()):
		var first := outline[index]
		var second := outline[(index + 1) % outline.size()]
		_add_triangle(
			surface,
			center,
			Vector3(second.x, 0.0, second.y),
			Vector3(first.x, 0.0, first.y)
		)
	surface.generate_normals()
	return surface.commit()


func _add_quad(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	_add_triangle(surface, a, b, c)
	_add_triangle(surface, a, c, d)


func _add_triangle(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	surface.add_vertex(a)
	surface.add_vertex(b)
	surface.add_vertex(c)
