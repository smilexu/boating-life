@tool
extends Marker3D

## Adds an obvious, editor-only handle for positioning the boat exhaust outlet.
## The scene's Marker3D transform remains the actual particle spawn location.

const EDITOR_GIZMO_NAME := "EditorOnlyOutletHandle"
const BOAT_MODEL_FRAME_SCALE := 6.647381


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	if get_node_or_null(EDITOR_GIZMO_NAME) != null:
		return
	_add_editor_handle()


func _add_editor_handle() -> void:
	var handle := Node3D.new()
	handle.name = EDITOR_GIZMO_NAME
	# Cancel the parent BoatModelFrame's import scale so the handle is a useful
	# real-world size in the editor viewport.
	handle.scale = Vector3.ONE / BOAT_MODEL_FRAME_SCALE
	add_child(handle)

	var handle_material := StandardMaterial3D.new()
	handle_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	handle_material.albedo_color = Color(1.0, 0.24, 0.055, 1.0)

	var outlet := MeshInstance3D.new()
	outlet.name = "OutletPoint"
	var sphere := SphereMesh.new()
	sphere.radius = 0.075
	sphere.height = 0.15
	sphere.radial_segments = 16
	sphere.rings = 8
	outlet.mesh = sphere
	outlet.material_override = handle_material
	handle.add_child(outlet)

	var crossbar_x := MeshInstance3D.new()
	crossbar_x.name = "CrossbarX"
	var x_mesh := BoxMesh.new()
	x_mesh.size = Vector3(0.28, 0.018, 0.018)
	crossbar_x.mesh = x_mesh
	crossbar_x.material_override = handle_material
	handle.add_child(crossbar_x)

	var crossbar_z := MeshInstance3D.new()
	crossbar_z.name = "CrossbarZ"
	var z_mesh := BoxMesh.new()
	z_mesh.size = Vector3(0.018, 0.018, 0.28)
	crossbar_z.mesh = z_mesh
	crossbar_z.material_override = handle_material
	handle.add_child(crossbar_z)

	var label := Label3D.new()
	label.name = "OutletLabel"
	label.text = "SMOKE OUTLET · DRAG"
	label.position = Vector3(0.0, 0.16, 0.0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 32
	label.pixel_size = 0.005
	label.modulate = Color(1.0, 0.83, 0.58, 1.0)
	label.outline_size = 4
	handle.add_child(label)
