class_name CoastTransitionLoader
extends Node3D

## Loads the offline, OSM-matched coast transition mesh. The builder scans and
## triangulates terrain boundaries once; this node does no per-frame work.

@export_file("*.bin") var mesh_path := "res://assets/terrain/processed/oresund_terrain/coast_transition.bin"
@export_file("*.json") var metadata_path := "res://assets/terrain/processed/oresund_terrain/coast_transition.json"

var _diagnostics: Dictionary = {"status": "pending"}
var _mesh_instance: MeshInstance3D


func _ready() -> void:
	_load_transition_mesh()


func get_diagnostics() -> Dictionary:
	return _diagnostics.duplicate(true)


func _load_transition_mesh() -> void:
	if not FileAccess.file_exists(mesh_path):
		_fail("Prebuilt coast transition mesh is missing. Run tools/terrain/build_coast_support.py.")
		return
	var file := FileAccess.open(mesh_path, FileAccess.READ)
	if file == null:
		_fail("Could not open coast transition mesh: %s" % mesh_path)
		return
	var data := file.get_buffer(file.get_length())
	if data.size() < 16 or data.slice(0, 4).get_string_from_ascii() != "OZCT":
		_fail("Coast transition mesh has an invalid header.")
		return
	var version := int(data.decode_u32(4))
	var vertex_count := int(data.decode_u32(8))
	var index_count := int(data.decode_u32(12))
	var expected_size := 16 + vertex_count * 40 + index_count * 4
	if version != 1 or vertex_count < 3 or index_count < 3 or index_count % 3 != 0 or data.size() != expected_size:
		_fail("Coast transition mesh counts or version are invalid.")
		return
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	vertices.resize(vertex_count)
	normals.resize(vertex_count)
	colors.resize(vertex_count)
	var offset := 16
	for index in range(vertex_count):
		vertices[index] = Vector3(data.decode_float(offset), data.decode_float(offset + 4), data.decode_float(offset + 8))
		normals[index] = Vector3(data.decode_float(offset + 12), data.decode_float(offset + 16), data.decode_float(offset + 20))
		colors[index] = Color(data.decode_float(offset + 24), data.decode_float(offset + 28), data.decode_float(offset + 32), data.decode_float(offset + 36))
		offset += 40
	var indices := PackedInt32Array()
	indices.resize(index_count)
	for index in range(index_count):
		var vertex_index := int(data.decode_u32(offset))
		if vertex_index >= vertex_count:
			_fail("Coast transition mesh references a missing vertex.")
			return
		indices[index] = vertex_index
		offset += 4
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "OresundCoastTransitionMesh"
	_mesh_instance.mesh = mesh
	_mesh_instance.material_override = _make_material()
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(_mesh_instance)
	_diagnostics = _load_metadata()
	_diagnostics["status"] = "loaded"
	_diagnostics["vertex_count"] = vertex_count
	_diagnostics["triangle_count"] = index_count / 3
	_diagnostics["mesh_bytes"] = data.size()
	print("[CoastTransitionLoader] Loaded %d terrain-mask-matched coast edges as %d static triangles (%.2f MiB)." % [
		int(_diagnostics.get("matched_coast_edge_count", 0)),
		index_count / 3,
		float(data.size()) / (1024.0 * 1024.0),
	])


func _load_metadata() -> Dictionary:
	if not FileAccess.file_exists(metadata_path):
		return {"status": "metadata_missing"}
	var file := FileAccess.open(metadata_path, FileAccess.READ)
	if file == null:
		return {"status": "metadata_unreadable"}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary or int(parsed.get("schema_version", -1)) != 1:
		return {"status": "metadata_invalid"}
	return parsed.duplicate(true)


func _make_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.WHITE
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.96
	material.metallic = 0.0
	material.cull_mode = BaseMaterial3D.CULL_BACK
	return material


func _fail(message: String) -> void:
	_diagnostics = {"status": "failed", "reason": message}
	push_warning("CoastTransitionLoader: %s" % message)
